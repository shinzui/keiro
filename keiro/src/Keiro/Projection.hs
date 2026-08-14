-- | Projections: turning a stream's events into read-side state.
--
-- Two flavors, trading consistency against coupling:
--
-- * An 'InlineProjection' runs in the /same/ transaction as the command that
--   produced the events, so the read model is updated atomically with the
--   append — never stale, but tied to the writer's transaction and latency.
--   'runCommandWithProjections' runs a command and applies a list of inline
--   projections to whatever it emits.
-- * An 'AsyncProjection' runs later from a subscription draining the event
--   log. It carries a 'subscriptionName' for checkpointing and an
--   'idempotencyKey' so redelivery is safe; 'applyAsyncProjection' performs
--   one application. This decouples the read model from the writer at the
--   cost of eventual consistency.
--
-- Both ultimately fold events into a SQL read model via a
-- 'Hasql.Transaction.Transaction'; the difference is only /when/ that
-- transaction runs.
module Keiro.Projection
  ( -- * Inline projections
    InlineProjection (..),
    runCommandWithProjections,
    runDomainCommandWithProjections,
    ProjectionCommandOutcome (..),
    runCommandWithCatalogProjections,
    DomainProjectionCommandOutcome (..),
    runDomainCommandWithCatalogProjections,

    -- * Asynchronous projections
    AsyncProjection (..),
    AsyncApplyOutcome (..),
    CatalogAsyncApplyOutcome (..),
    applyAsyncProjection,
    applyAsyncProjectionFromCatalog,
    applyAsyncProjectionUnfenced,
    pruneAsyncProjectionDedupBefore,
    countAsyncProjectionDedupForBefore,
    pruneAsyncProjectionDedupForBefore,
    recordProjectionGlobalPositionDistance,
    recordProjectionLag,
  )
where

import Contravariant.Extras (contrazip2)
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Stack (HasCallStack)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command
  ( CommandError,
    CommandResult,
    DomainCommandHandler,
    DomainCommandOutcome,
    DomainSqlCommandOutcome (..),
    RunCommandOptions,
    SqlCommandOutcome (..),
    SqlTransactionDecision (..),
    runCommandWithSqlEvents,
    runCommandWithSqlEventsControlled,
    runDomainCommandWithSqlEvents,
    runDomainCommandWithSqlEventsControlled,
  )
import Keiro.EventStream (EventStream)
import Keiro.EventStream.Validate (ValidatedEventStream)
import Keiro.Prelude
import Keiro.Projection.Catalog
  ( PhysicalTargets,
    ProjectionId,
    ProjectionRevisionId,
    ProjectionSet,
    RebuildGroupId,
    RevisionLiveHandler,
    SourceId,
    ValidatedProjectionCatalog,
    asyncProjectionRebuildGroup,
    catalogProjectionRevision,
    typedInlineProjectionsForGroup,
    typedProjectionRebuildGroups,
  )
import Keiro.Projection.Types
import Keiro.ReadModel (storeHeadPosition, subscriptionPositionFromInventory)
import Keiro.ReadModel.Rebuild.Group
  ( ProjectionWriteFence (..),
    RebuildRunId,
    lockProjectionGroupsTx,
  )
import Keiro.Stream (Stream)
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Telemetry qualified as Telemetry
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Subscription
  ( SubscriptionName (..),
    subscriptionCheckpointInventory,
  )
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude qualified

-- | The database-visible result of one asynchronous projection attempt.
data AsyncApplyOutcome
  = AsyncApplied
  | AsyncDuplicate
  | AsyncFenced
  deriving stock (Generic, Eq, Show)

-- | Result of a catalog-fenced inline command. A fenced result proves the
-- append transaction was rolled back, so neither its events nor any projection
-- SQL committed.
data ProjectionCommandOutcome target
  = ProjectionCommandApplied !(CommandResult target)
  | ProjectionCommandFenced !RebuildGroupId !RebuildRunId
  | ProjectionCommandGroupUnregistered !RebuildGroupId
  | ProjectionCommandServingRevisionUnavailable !RebuildGroupId !ProjectionRevisionId
  | ProjectionCommandServingBindingInvalid !RebuildGroupId !ProjectionRevisionId !Text
  | ProjectionCommandCatalogMismatch !SourceId
  deriving stock (Generic, Eq, Show)

-- | Outcome-aware counterpart to 'ProjectionCommandOutcome'. Successful
-- selected silent decisions are applied outcomes even though no projection
-- handler ran. Fence outcomes prove an accepted append was rolled back.
data DomainProjectionCommandOutcome target co rejection noOp
  = DomainProjectionCommandApplied !(DomainCommandOutcome target co rejection noOp)
  | DomainProjectionCommandFenced !RebuildGroupId !RebuildRunId
  | DomainProjectionCommandGroupUnregistered !RebuildGroupId
  | DomainProjectionCommandServingRevisionUnavailable !RebuildGroupId !ProjectionRevisionId
  | DomainProjectionCommandServingBindingInvalid !RebuildGroupId !ProjectionRevisionId !Text
  | DomainProjectionCommandCatalogMismatch !SourceId
  deriving stock (Generic, Eq, Show)

-- | Catalog-aware result of one asynchronous projection application.
data CatalogAsyncApplyOutcome
  = CatalogAsyncApplied
  | CatalogAsyncDuplicate
  | CatalogAsyncFenced !RebuildGroupId !RebuildRunId
  | CatalogAsyncGroupUnregistered !RebuildGroupId
  | CatalogAsyncServingRevisionUnavailable !RebuildGroupId !ProjectionRevisionId
  | CatalogAsyncServingBindingInvalid !RebuildGroupId !ProjectionRevisionId !Text
  | CatalogAsyncProjectionUnknown !ProjectionId
  deriving stock (Generic, Eq, Show)

-- | Run a command and apply every supplied 'InlineProjection' to the events
-- it emits, all inside the command's append transaction. A projection failure
-- aborts the whole transaction, so the events and the read-model update commit
-- together or not at all.
--
-- This compatibility runner does not consult catalog rebuild-group fences. New
-- managed callers should use 'runCommandWithCatalogProjections'.
runCommandWithProjections ::
  forall phi rs s ci co es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  ValidatedEventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  [InlineProjection co] ->
  Eff es (Either CommandError (CommandResult (EventStream phi rs s ci co)))
runCommandWithProjections options eventStream targetStream command projections = do
  result <-
    runCommandWithSqlEvents
      options
      eventStream
      targetStream
      command
      ( \pairs _appendResult ->
          traverse_
            ( \projection ->
                traverse_
                  (\(event, recorded) -> (projection ^. #apply) event recorded)
                  pairs
            )
            projections
      )
  pure (fmap Prelude.fst result)

-- | Run a domain command and apply every supplied inline projection to an
-- accepted event batch in the append transaction. Typed rejection and no-op
-- decisions return directly without invoking any projection.
runDomainCommandWithProjections ::
  forall phi rs s ci co rejection noOp es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  [InlineProjection co] ->
  Eff es (Either CommandError (DomainCommandOutcome (EventStream phi rs s ci co) co rejection noOp))
runDomainCommandWithProjections options handler targetStream command projections = do
  outcome <-
    runDomainCommandWithSqlEvents
      options
      handler
      targetStream
      command
      ( \pairs _appendResult ->
          traverse_
            ( \projection ->
                traverse_
                  (\(event, recorded) -> (projection ^. #apply) event recorded)
                  pairs
            )
            projections
      )
  pure (fmap Prelude.fst outcome)

-- | Run a command through the typed source view derived from one validated
-- catalog. Every distinct rebuild group is locked in stable ID order inside the
-- append transaction before any projection handler runs. A rebuilding or failed
-- group condemns that transaction and returns a typed fence outcome.
runCommandWithCatalogProjections ::
  forall phi rs s ci co es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  ValidatedEventStream phi rs s ci co ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  ValidatedProjectionCatalog ->
  ProjectionSet co ->
  Eff es (Either CommandError (ProjectionCommandOutcome (EventStream phi rs s ci co)))
runCommandWithCatalogProjections options eventStream targetStream command catalog projectionSet = do
  if Prelude.null groups
    then pure (Right (ProjectionCommandCatalogMismatch (projectionSet ^. #projectionSource)))
    else do
      outcome <-
        runCommandWithSqlEventsControlled
          options
          eventStream
          targetStream
          command
          (\pairs _appendResult -> applyCatalogProjectionsTx catalog projectionSet groups pairs)
      pure (fmap toProjectionOutcome outcome)
  where
    groups = typedProjectionRebuildGroups catalog projectionSet

    toProjectionOutcome = \case
      SqlCommandNoOp result -> ProjectionCommandApplied result
      SqlCommandCommitted result _ -> ProjectionCommandApplied result
      SqlCommandRolledBack fence -> fenceOutcome fence

    fenceOutcome = \case
      ProjectionWritesAllowed _ ->
        error "runCommandWithCatalogProjections: rolled back with writes allowed"
      ProjectionWriteFenced groupId runId -> ProjectionCommandFenced groupId runId
      ProjectionWriteGroupUnregistered groupId -> ProjectionCommandGroupUnregistered groupId
      ProjectionServingRevisionUnavailable groupId revisionId ->
        ProjectionCommandServingRevisionUnavailable groupId revisionId
      ProjectionServingBindingInvalid groupId revisionId detail ->
        ProjectionCommandServingBindingInvalid groupId revisionId detail

-- | Domain-aware catalog projection runner. Accepted commands retain existing
-- catalog fence semantics. Typed rejection/no-op decisions invoke neither the
-- fence transaction nor projection handlers and carry no fabricated projection
-- result.
runDomainCommandWithCatalogProjections ::
  forall phi rs s ci co rejection noOp es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  ValidatedProjectionCatalog ->
  ProjectionSet co ->
  Eff es (Either CommandError (DomainProjectionCommandOutcome (EventStream phi rs s ci co) co rejection noOp))
runDomainCommandWithCatalogProjections options handler targetStream command catalog projectionSet = do
  if Prelude.null groups
    then pure (Right (DomainProjectionCommandCatalogMismatch (projectionSet ^. #projectionSource)))
    else do
      outcome <-
        runDomainCommandWithSqlEventsControlled
          options
          handler
          targetStream
          command
          (\pairs _appendResult -> applyCatalogProjectionsTx catalog projectionSet groups pairs)
      pure (fmap toProjectionOutcome outcome)
  where
    groups = typedProjectionRebuildGroups catalog projectionSet

    toProjectionOutcome = \case
      DomainSqlCommandSilent outcome -> DomainProjectionCommandApplied outcome
      DomainSqlCommandCommitted outcome _ -> DomainProjectionCommandApplied outcome
      DomainSqlCommandRolledBack fence -> fenceOutcome fence

    fenceOutcome = \case
      ProjectionWritesAllowed _ ->
        error "runDomainCommandWithCatalogProjections: rolled back with writes allowed"
      ProjectionWriteFenced groupId runId -> DomainProjectionCommandFenced groupId runId
      ProjectionWriteGroupUnregistered groupId -> DomainProjectionCommandGroupUnregistered groupId
      ProjectionServingRevisionUnavailable groupId revisionId ->
        DomainProjectionCommandServingRevisionUnavailable groupId revisionId
      ProjectionServingBindingInvalid groupId revisionId detail ->
        DomainProjectionCommandServingBindingInvalid groupId revisionId detail

applyCatalogProjectionsTx ::
  ValidatedProjectionCatalog ->
  ProjectionSet co ->
  [RebuildGroupId] ->
  [(co, RecordedEvent)] ->
  Tx.Transaction (SqlTransactionDecision ProjectionWriteFence)
applyCatalogProjectionsTx catalog projectionSet groups pairs = do
  fence <- lockProjectionGroupsTx catalog groups
  case fence of
    ProjectionWritesAllowed bindings -> do
      traverse_ applyBinding bindings
      pure (CommitSqlTransaction fence)
    _ -> pure (RollbackSqlTransaction fence)
  where
    applyBinding binding =
      case binding ^. #writeRevisionId of
        Nothing ->
          traverse_
            ( \projection ->
                traverse_
                  (\(event, recorded) -> (projection ^. #apply) event recorded)
                  pairs
            )
            (typedInlineProjectionsForGroup catalog projectionSet (binding ^. #writeGroupId))
        Just revisionId ->
          case catalogProjectionRevision catalog revisionId of
            Nothing -> error "applyCatalogProjectionsTx: locked revision disappeared from validated catalog"
            Just revision ->
              traverse_
                ( \handler ->
                    traverse_
                      (\(_, recorded) -> (handler ^. #runRevisionLive) (binding ^. #writePhysicalTargets) recorded)
                      pairs
                )
                (revision ^. #liveHandlers)

-- | Apply one event to a live 'AsyncProjection', returning a distinct outcome
-- for a successful application, a retained dedup key, or a rebuild fence.
--
-- The registry row is read with @FOR SHARE@ inside the same transaction as the
-- dedup insert and application. A missing row or any status other than @live@
-- returns 'AsyncFenced' without touching either table. A worker that receives
-- 'AsyncFenced' must not checkpoint past the event: fail or park the delivery and
-- retry after promotion. Ack-coupled Kiroku delivery preserves the checkpoint
-- when its handler does not acknowledge success.
--
-- This compatibility path consults only the legacy single-read-model registry.
-- Catalog-managed workers should use 'applyAsyncProjectionFromCatalog'.
--
-- The projection's 'idempotencyKey' is inserted into @keiro_projection_dedup@
-- inside the same transaction as 'applyRecorded'. When that insert conflicts,
-- the event was already applied within the retained dedup window and the update
-- is skipped. Use 'pruneAsyncProjectionDedupBefore' only for events older than
-- the subscription system can redeliver; pruning intentionally re-opens those
-- events for application if they are replayed later.
applyAsyncProjection :: AsyncProjection -> RecordedEvent -> Tx.Transaction AsyncApplyOutcome
applyAsyncProjection projection recorded = do
  status <-
    Tx.statement
      (projection ^. #readModelName)
      lockReadModelStatusStmt
  case status of
    Just "live" -> applyAsyncProjectionUnfenced projection recorded
    _ -> pure AsyncFenced

-- | Apply one async handler through its validated catalog identity and the same
-- rebuild-group row lock used by inline commands and rebuild preparation.
-- Fenced outcomes perform no dedup insert or target write; an ack-coupled worker
-- must therefore leave its subscription checkpoint unchanged.
applyAsyncProjectionFromCatalog ::
  ValidatedProjectionCatalog ->
  ProjectionId ->
  AsyncProjection ->
  RecordedEvent ->
  Tx.Transaction CatalogAsyncApplyOutcome
applyAsyncProjectionFromCatalog catalog projectionId projection recorded =
  case asyncProjectionRebuildGroup catalog projectionId (projection ^. #name) of
    Nothing -> pure (CatalogAsyncProjectionUnknown projectionId)
    Just groupId -> do
      fence <- lockProjectionGroupsTx catalog [groupId]
      case fence of
        ProjectionWritesAllowed [binding] -> do
          outcome <-
            case binding ^. #writeRevisionId of
              Nothing -> applyAsyncProjectionUnfenced projection recorded
              Just revisionId ->
                case catalogProjectionRevision catalog revisionId of
                  Nothing -> error "applyAsyncProjectionFromCatalog: locked revision disappeared from validated catalog"
                  Just revision ->
                    applyRevisionAsyncProjectionUnfenced
                      projection
                      (binding ^. #writePhysicalTargets)
                      (revision ^. #liveHandlers)
                      recorded
          pure $ case outcome of
            AsyncApplied -> CatalogAsyncApplied
            AsyncDuplicate -> CatalogAsyncDuplicate
            AsyncFenced ->
              error "applyAsyncProjectionUnfenced returned a fenced outcome"
        ProjectionWritesAllowed _ ->
          error "applyAsyncProjectionFromCatalog: one group lock returned an unexpected binding set"
        ProjectionWriteFenced fencedGroup runId ->
          pure (CatalogAsyncFenced fencedGroup runId)
        ProjectionWriteGroupUnregistered missingGroup ->
          pure (CatalogAsyncGroupUnregistered missingGroup)
        ProjectionServingRevisionUnavailable missingGroup revisionId ->
          pure (CatalogAsyncServingRevisionUnavailable missingGroup revisionId)
        ProjectionServingBindingInvalid invalidGroup revisionId detail ->
          pure (CatalogAsyncServingBindingInvalid invalidGroup revisionId detail)

applyRevisionAsyncProjectionUnfenced ::
  AsyncProjection ->
  PhysicalTargets ->
  [RevisionLiveHandler] ->
  RecordedEvent ->
  Tx.Transaction AsyncApplyOutcome
applyRevisionAsyncProjectionUnfenced projection physicalTargets handlers recorded = do
  inserted <-
    Tx.statement
      (projection ^. #name, eventIdToUuid ((projection ^. #idempotencyKey) recorded))
      insertProjectionDedupStmt
  if inserted
    then do
      traverse_ (\handler -> (handler ^. #runRevisionLive) physicalTargets recorded) handlers
      pure AsyncApplied
    else pure AsyncDuplicate

-- | Apply one event without consulting the read-model registry fence.
--
-- This is exclusively the rebuild replay entry point: it retains normal dedup
-- semantics while permitting the designated rebuilder to write while the model is
-- @rebuilding@. Live workers must use 'applyAsyncProjection'.
applyAsyncProjectionUnfenced :: AsyncProjection -> RecordedEvent -> Tx.Transaction AsyncApplyOutcome
applyAsyncProjectionUnfenced projection recorded = do
  inserted <-
    Tx.statement
      (projection ^. #name, eventIdToUuid ((projection ^. #idempotencyKey) recorded))
      insertProjectionDedupStmt
  if inserted
    then do
      (projection ^. #applyRecorded) recorded
      pure AsyncApplied
    else pure AsyncDuplicate

-- | Age out async-projection dedup rows older than the supplied timestamp.
--
-- Use this only beyond the subscription system's redelivery window; pruning
-- re-opens those events for application. It is not a rebuild reset. Supported
-- rebuilds use 'Keiro.ReadModel.Rebuild.startRebuild', which atomically deletes
-- only the named projections' keys while fencing writers and resetting the model.
-- Returns the number of rows pruned.
pruneAsyncProjectionDedupBefore :: (Store :> es) => UTCTime -> Eff es Int64
pruneAsyncProjectionDedupBefore cutoff =
  runTransaction
    $ Tx.statement cutoff pruneProjectionDedupBeforeStmt

-- | Count one projection's dedup rows older than a timestamp. This is the
-- read-only operator preview for 'pruneAsyncProjectionDedupForBefore'.
countAsyncProjectionDedupForBefore ::
  (Store :> es) =>
  Text ->
  UTCTime ->
  Eff es Int64
countAsyncProjectionDedupForBefore projectionName cutoff =
  runTransaction
    $ Tx.statement (projectionName, cutoff) countProjectionDedupForBeforeStmt

-- | Age out one named projection's dedup rows older than the supplied
-- timestamp. Scoping the mutation keeps unrelated projection redelivery
-- windows independent.
pruneAsyncProjectionDedupForBefore ::
  (Store :> es) =>
  Text ->
  UTCTime ->
  Eff es Int64
pruneAsyncProjectionDedupForBefore projectionName cutoff =
  runTransaction
    $ Tx.statement (projectionName, cutoff) pruneProjectionDedupForBeforeStmt

-- | Record the non-negative global position distance between the newest visible
-- event and the slowest durable member checkpoint for one async projection. A
-- global position is an opaque cursor, so this is not an exact count of relevant
-- events for filtered, category, or sharded consumers. Tail hard-deletion leaves
-- a caught-up projection at distance zero because an authoritative append
-- counter that includes deleted events is not actionable backlog.
--
-- There is no in-library polling drain loop today (the application drives
-- 'applyAsyncProjection' per event), so this is the entry point an application
-- calls once per drain pass after applying a batch. The preferred and legacy
-- gauges record the same value during the 0.11 compatibility interval.
recordProjectionGlobalPositionDistance ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  AsyncProjection ->
  Eff es ()
recordProjectionGlobalPositionDistance metrics projection = do
  inventory <- subscriptionCheckpointInventory
  visibleHead <- storeHeadPosition
  let checkpoint =
        fromMaybe (GlobalPosition 0)
          $ subscriptionPositionFromInventory
            (SubscriptionName (projection ^. #subscriptionName))
            inventory
      distance = globalPositionDistance visibleHead checkpoint
  Telemetry.recordProjectionGlobalPositionDistance metrics distance
  Telemetry.recordProjectionLag metrics distance

-- | Deprecated compatibility name for 'recordProjectionGlobalPositionDistance'.
{-# DEPRECATED recordProjectionLag "Use recordProjectionGlobalPositionDistance; the value is a global position distance, not an event count." #-}
recordProjectionLag ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  AsyncProjection ->
  Eff es ()
recordProjectionLag = recordProjectionGlobalPositionDistance

-- | The non-negative distance between two opaque global positions.
globalPositionDistance :: GlobalPosition -> GlobalPosition -> Int64
globalPositionDistance (GlobalPosition headP) (GlobalPosition checkP) = max 0 (headP Prelude.- checkP)

insertProjectionDedupStmt :: Statement (Text, UUID) Bool
insertProjectionDedupStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_dedup (projection_name, event_id)
    VALUES ($1, $2)
    ON CONFLICT (projection_name, event_id) DO NOTHING
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.uuid))
    )
    ((> 0) <$> D.rowsAffected)

lockReadModelStatusStmt :: Statement Text (Maybe Text)
lockReadModelStatusStmt =
  preparable
    """
    SELECT status
    FROM keiro.keiro_read_models
    WHERE name = $1
    FOR SHARE
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe (D.column (D.nonNullable D.text)))

pruneProjectionDedupBeforeStmt :: Statement UTCTime Int64
pruneProjectionDedupBeforeStmt =
  preparable
    """
    DELETE FROM keiro.keiro_projection_dedup
    WHERE applied_at < $1
    """
    (E.param (E.nonNullable E.timestamptz))
    D.rowsAffected

countProjectionDedupForBeforeStmt :: Statement (Text, UTCTime) Int64
countProjectionDedupForBeforeStmt =
  preparable
    """
    SELECT count(*)::bigint
    FROM keiro.keiro_projection_dedup
    WHERE projection_name = $1
      AND applied_at < $2
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    (D.singleRow (D.column (D.nonNullable D.int8)))

pruneProjectionDedupForBeforeStmt :: Statement (Text, UTCTime) Int64
pruneProjectionDedupForBeforeStmt =
  preparable
    """
    DELETE FROM keiro.keiro_projection_dedup
    WHERE projection_name = $1
      AND applied_at < $2
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.rowsAffected

eventIdToUuid :: EventId -> UUID
eventIdToUuid (EventId value) = value
