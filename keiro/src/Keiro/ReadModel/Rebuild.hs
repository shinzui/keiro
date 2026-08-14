-- | The supported offline read-model rebuild lifecycle.
--
-- New applications register a 'Keiro.Projection.Catalog.ValidatedProjectionCatalog'
-- with 'registerProjectionCatalog', call 'beginGroupRebuild' for one atomic
-- target group, replay through the dedicated catalog runner, and promote only
-- with its opaque 'GroupCompletionToken'. Preparation derives target reset,
-- dedup, and subscription state from the catalog; abandonment records evidence
-- and keeps the group fenced.
--
-- The following single-read-model checklist is the unmanaged compatibility
-- path for existing callers. It cannot coordinate multiple targets and accepts
-- caller-supplied projection names:
--
-- 1. Call 'Keiro.ReadModel.Schema.registerReadModel' once at projection startup.
--    Explicit registration makes misspelled or never-populated models fail with
--    'ReadModelUnregistered' instead of appearing healthy.
-- 2. Call 'startRebuild' with every feeding async projection name and the replay
--    position. It atomically fences live writers, takes queries offline, truncates
--    the data table, clears the named dedup keys, and resets the subscription
--    checkpoint for a model with a durable cursor. A cursorless inline model has
--    no checkpoint to reset and pairs this call with an empty projection-name
--    list. Both paths prevent live/replay interleaving and all-deduplicated
--    rebuilds.
-- 3. Replay through 'Keiro.Projection.applyAsyncProjectionUnfenced'. This is the
--    only apply path allowed to bypass the live-writer fence, while retaining
--    deduplication inside the designated rebuild.
-- 4. After replay catches up and application-specific verification succeeds, call
--    'finishRebuild' with the same projection names and replay position. Its
--    promotion guard refuses to serve a non-empty-log rebuild that applied no
--    events.
-- 5. If replay or verification fails, call 'abandonRebuild'. Queries remain
--    unavailable instead of exposing partial data; repair or restore the table
--    before beginning another rebuild.
--
-- Normal workers continue to call 'Keiro.Projection.applyAsyncProjection'. Its
-- registry lock fences them automatically while the model is rebuilding, but they
-- must not checkpoint an 'Keiro.Projection.AsyncFenced' event. For schema-changing
-- online reconstruction, use the schema-versioned target lifecycle exported below:
-- it keeps the serving revision live while replay populates application-provisioned
-- candidate generations and then promotes the complete group atomically.
module Keiro.ReadModel.Rebuild
  ( -- * Catalog rebuild groups
    preCanonicalRunSliceSentinel,
    RebuildRunId,
    mkRebuildRunId,
    rebuildRunIdText,
    RebuildRequest (..),
    RebuildFailure (..),
    GroupLifecycleStatus (..),
    GroupRebuildMetadata (..),
    CatalogRegistrationError (..),
    GroupAdoptionClass (..),
    RegistrationAdoptionAction (..),
    RegistrationAdoption (..),
    OrphanedRegistration (..),
    CatalogAdoptionPlan (..),
    CatalogAdoptionResult (..),
    CatalogAdoptionError (..),
    RebuildStartError (..),
    GroupTransitionError (..),
    ProjectionWriteFence (..),
    GroupPreparation (..),
    GroupRebuildHandle,
    groupRebuildHandleGroup,
    groupRebuildHandleRun,
    groupRebuildHandleSliceFingerprint,
    groupRebuildHandlePreparation,
    groupRebuildHandleResetCheckpointKeys,
    GroupCompletionToken,
    registerProjectionCatalog,
    previewCatalogAdoption,
    adoptCatalogGroups,
    lookupProjectionRebuildGroup,
    ServingPositionBasis (..),
    ProjectionGroupStatusV1 (..),
    listProjectionGroupStatuses,
    lookupProjectionGroupStatus,
    beginGroupRebuild,
    resetDeclaredSubscriptions,
    insertProjectionDedupBatchStmt,
    finishGroupRebuild,
    abandonGroupRebuild,

    -- * Schema-versioned target lifecycle
    VersionedTargetMode (..),
    VersionedRebuildRequest (..),
    VersionedRebuildError (..),
    VersionedGenerationLifecycle (..),
    VersionedTargetGeneration (..),
    VersionedLeaseEvidence (..),
    VersionedRebuildHandle (..),
    VersionedRebuildPhase (..),
    VersionedSourceProgress (..),
    VersionedRebuildReport (..),
    VersionedAbandonResult (..),
    VersionedRetiredGenerationPreview (..),
    VersionedRetiredDropResult (..),
    beginVersionedRebuild,
    applyVersionedReplayEvent,
    verifyVersionedCandidate,
    resumeVersionedRebuild,
    inspectVersionedRebuild,
    abandonVersionedRebuild,
    listVersionedRetiredGenerations,
    previewVersionedRetiredDrop,
    dropVersionedRetiredGeneration,

    -- * Targeted stream reprojection
    StreamReprojectionRequest (..),
    StreamReprojectionError (..),
    StreamReprojectionReport (..),
    reprojectStream,

    -- * Catalog history runner
    RebuildOptions (..),
    defaultRebuildOptions,
    CatalogRebuildError (..),
    RebuildRunStatus (..),
    RebuildFailureEvidence (..),
    RebuildSourceProgress (..),
    RebuildAdapterProgress (..),
    RebuildVerificationProgress (..),
    RebuildRunReport (..),
    AsyncDedupBackfill (..),
    collectAsyncDedupBackfill,
    startCatalogRebuild,
    resumeCatalogRebuild,
    inspectCatalogRebuild,
    abandonCatalogRebuild,

    -- * Unmanaged single-read-model compatibility
    RebuildError (..),
    startRebuild,
    finishRebuild,
    rebuild,
    promote,
    abandonRebuild,
  )
where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text.Encoding qualified as TE
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.ReadModel
import Keiro.ReadModel.Rebuild.Group
import Keiro.ReadModel.Rebuild.Runner
import Keiro.ReadModel.Rebuild.Status
import Keiro.ReadModel.Rebuild.Stream
import Keiro.ReadModel.Rebuild.Versioned
import Kiroku.Store.Effect (Store)
import Kiroku.Store.SQL (visibleGlobalHeadPositionStmt)
import Kiroku.Store.Subscription.Checkpoint (resetSubscriptionCheckpointsTx)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | Why a rebuild could not be promoted.
data RebuildError
  = -- | The model name and current store head when a rebuild started before
    --       existing events but applied none of its feeding projections.
    RebuildProducedNoApplies !Text !GlobalPosition
  deriving stock (Generic, Eq, Show)

-- | Atomically take a model offline, truncate its data table, clear the dedup
-- keys for its feeding async projections, and, when it has a durable cursor,
-- reset every member of that subscription to the supplied replay position. A
-- cursorless model has no checkpoint to reset, so this deliberately skips the
-- reset; pair that inline-only shape with an empty projection-name list.
--
-- The registry transition runs first and holds the row lock that
-- 'Keiro.Projection.applyAsyncProjection' uses as its writer fence. PostgreSQL
-- keeps the table truncate transactional. Kiroku's ordinary checkpoint save is
-- monotonic, so this helper uses the owning library's explicitly named reset
-- transaction inside the same fence.
startRebuild ::
  (Store :> es) =>
  ReadModel q r ->
  [Text] ->
  GlobalPosition ->
  Eff es ReadModelMetadata
startRebuild readModel projectionNames replayFrom =
  runTransaction $ do
    metadata <- transitionReadModelTxFor readModel Rebuilding
    Tx.sql (TE.encodeUtf8 ("TRUNCATE TABLE " <> qualifiedTableName readModel))
    unless (null projectionNames) $
      Tx.statement projectionNames deleteProjectionDedupStmt
    case readModelCursorAuthority readModel of
      NoQueryCursor -> pure ()
      DurableQueryCursor cursor -> do
        _ <-
          resetSubscriptionCheckpointsTx
            (NonEmpty.singleton (SubscriptionName cursor))
            replayFrom
        pure ()
    pure metadata

-- | Promote a completed rebuild in the same transaction as its safety check.
--
-- When async projection names are supplied, a store head beyond @replayFrom@
-- requires at least one new dedup row. 'startRebuild' deleted those rows, so their
-- count is the model-independent number of projection applications during this
-- rebuild. An empty projection-name list denotes an inline-only model and skips
-- the guard because no async dedup rows can exist for it.
finishRebuild ::
  (Store :> es) =>
  ReadModel q r ->
  [Text] ->
  GlobalPosition ->
  Eff es (Either RebuildError ReadModelMetadata)
finishRebuild readModel projectionNames replayFrom =
  runTransaction $ do
    headPosition <- Tx.statement () visibleGlobalHeadPositionStmt
    applyCount <-
      if null projectionNames
        then pure 0
        else Tx.statement projectionNames countProjectionDedupStmt
    if null projectionNames || applyCount > 0 || headPosition <= replayFrom
      then Right <$> transitionReadModelTxFor readModel Live
      else pure (Left (RebuildProducedNoApplies (readModel ^. #name) headPosition))

-- | Low-level status transition only. It does not truncate data, reset dedup
-- keys or checkpoints, or establish the complete rebuild workflow. Use
-- 'startRebuild' for supported rebuilds.
rebuild :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
rebuild readModel =
  markRebuilding
    (readModel ^. #name)
    (readModel ^. #version)
    (readModel ^. #shapeHash)

-- | Low-level status transition only. It bypasses the empty-rebuild guard. Use
-- 'finishRebuild' to promote a supported rebuild.
promote :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
promote readModel =
  markLive
    (readModel ^. #name)
    (readModel ^. #version)
    (readModel ^. #shapeHash)

-- | Mark a model 'Abandoned', backing out of an in-progress rebuild.
abandonRebuild :: (Store :> es) => ReadModel q r -> Eff es ReadModelMetadata
abandonRebuild readModel =
  markAbandoned
    (readModel ^. #name)
    (readModel ^. #version)
    (readModel ^. #shapeHash)

transitionReadModelTxFor :: ReadModel q r -> ReadModelStatus -> Tx.Transaction ReadModelMetadata
transitionReadModelTxFor readModel status =
  transitionReadModelTx
    (readModel ^. #name)
    (readModel ^. #version)
    (readModel ^. #shapeHash)
    status

deleteProjectionDedupStmt :: Statement [Text] ()
deleteProjectionDedupStmt =
  preparable
    """
    DELETE FROM keiro.keiro_projection_dedup
    WHERE projection_name = ANY($1)
    """
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    D.noResult

countProjectionDedupStmt :: Statement [Text] Int64
countProjectionDedupStmt =
  preparable
    """
    SELECT count(*)
    FROM keiro.keiro_projection_dedup
    WHERE projection_name = ANY($1)
    """
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    (D.singleRow (D.column (D.nonNullable D.int8)))
