{-# OPTIONS_HADDOCK hide #-}

-- | Transactional targeted repair for explicitly stream-scoped projections.
-- Applications own row selection and event semantics; Keiro owns admission,
-- locking, history completeness, ordering, rollback, and redelivery evidence.
module Keiro.ReadModel.Rebuild.Stream
  ( StreamReprojectionRequest (..),
    StreamReprojectionError (..),
    StreamReprojectionReport (..),
    validateStreamReprojectionAdmission,
    reprojectStream,
    reprojectStreamTx,
  )
where

import Data.Functor (($>))
import Data.Int (Int32)
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.UUID (UUID)
import Data.Vector qualified as Vector
import Effectful (Eff, (:>))
import Keiro.Prelude
import Keiro.Projection.Catalog
  ( CatalogAsyncDedupSpec (..),
    DedupKeyId,
    PhysicalTargets,
    ProjectionId,
    ProjectionRevisionId,
    RebuildGroupId,
    ReplayDecodeError,
    SourceId,
    SourceScope (..),
    StreamClearCount (..),
    StreamScopedReplay,
    TargetId,
    ValidatedProjectionCatalog,
    catalogAsyncIdempotencyKeys,
    catalogInventory,
    catalogStreamScopedReplay,
    resolvePhysicalTarget,
  )
import Keiro.ReadModel.Rebuild.Group
  ( ProjectionRepairFence (..),
    RebuildRunId,
    insertProjectionDedupBatchStmt,
    lockProjectionGroupForRepairTx,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.HistoryRetention
  ( StreamHistoryUnavailable,
    lockStreamHistoryForReplayTx,
    readStreamForwardTx,
  )
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types
  ( CategoryName (..),
    EventId (..),
    RecordedEvent,
    StreamName (..),
    StreamVersion (..),
  )
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude (any, filter, fromIntegral, last, length, map, not, null, zip, (+), (-), (||))
import Prelude qualified

data StreamReprojectionRequest = StreamReprojectionRequest
  { rebuildGroupId :: !RebuildGroupId,
    projectionId :: !ProjectionId,
    streamName :: !StreamName,
    pageSize :: !Int32,
    maxEvents :: !Int64
  }
  deriving stock (Eq, Show, Generic)

data StreamReprojectionError
  = StreamReprojectionInvalidPageSize !Int32
  | StreamReprojectionInvalidMaxEvents !Int64
  | StreamReprojectionEventLimitExceeded !StreamName !Int64 !Int64
  | StreamReprojectionGroupUnregistered !RebuildGroupId
  | StreamReprojectionActiveRebuild !RebuildGroupId !RebuildRunId
  | StreamReprojectionGroupUnavailable !RebuildGroupId !Text !Bool !Bool
  | StreamReprojectionSliceDrift !RebuildGroupId !Text !Text
  | StreamReprojectionServingRevisionUnavailable !RebuildGroupId !ProjectionRevisionId
  | StreamReprojectionServingBindingInvalid !RebuildGroupId !ProjectionRevisionId !Text
  | StreamReprojectionUnknownProjection !ProjectionId
  | StreamReprojectionProjectionGroupMismatch !ProjectionId !RebuildGroupId !RebuildGroupId
  | StreamReprojectionPolicyUnavailable !ProjectionRevisionId !ProjectionId
  | StreamReprojectionSourceMismatch !SourceId !StreamName
  | StreamReprojectionHistoryUnavailable !StreamHistoryUnavailable
  | StreamReprojectionSoftDeleted !StreamName
  | StreamReprojectionTruncated !StreamName !StreamVersion
  | StreamReprojectionForeignEvent !StreamName !StreamVersion
  | StreamReprojectionClearFailed !Text
  | StreamReprojectionClearEvidenceInvalid ![TargetId] ![TargetId]
  | StreamReprojectionDecodeFailed !StreamVersion !ReplayDecodeError
  | StreamReprojectionVerificationFailed !Text
  | StreamReprojectionDedupIdentityUnavailable !DedupKeyId
  | StreamReprojectionHistoryIncomplete !StreamVersion !StreamVersion
  deriving stock (Eq, Show, Generic)

data StreamReprojectionReport = StreamReprojectionReport
  { rebuildGroupId :: !RebuildGroupId,
    projectionId :: !ProjectionId,
    streamName :: !StreamName,
    servingRevisionId :: !ProjectionRevisionId,
    streamVersion :: !StreamVersion,
    maxEvents :: !Int64,
    clearedRows :: ![StreamClearCount],
    replayedEvents :: !Int64,
    appliedEvents :: !Int64,
    dedupInserted :: !Int64,
    dedupExisting :: !Int64,
    verified :: !Bool
  }
  deriving stock (Eq, Show, Generic)

reprojectStream ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  StreamReprojectionRequest ->
  Eff es (Either StreamReprojectionError StreamReprojectionReport)
reprojectStream catalog request =
  runTransaction (reprojectStreamTx catalog request)

reprojectStreamTx ::
  ValidatedProjectionCatalog ->
  StreamReprojectionRequest ->
  Tx.Transaction (Either StreamReprojectionError StreamReprojectionReport)
reprojectStreamTx catalog request
  | request ^. #pageSize <= 0 =
      pure (Left (StreamReprojectionInvalidPageSize (request ^. #pageSize)))
  | request ^. #maxEvents <= 0 =
      pure (Left (StreamReprojectionInvalidMaxEvents (request ^. #maxEvents)))
  | otherwise =
      case validateStreamReprojectionAdmission catalog request of
        Left err -> pure (Left err)
        Right () -> lockHistoryAndRepair
  where
    lockHistoryAndRepair = do
      lockedHistory <- lockStreamHistoryForReplayTx (request ^. #streamName)
      case lockedHistory of
        Left unavailable ->
          pure (Left (StreamReprojectionHistoryUnavailable unavailable))
        Right streamInfo
          | isJust (streamInfo ^. #deletedAt) ->
              pure (Left (StreamReprojectionSoftDeleted (request ^. #streamName)))
          | streamInfo ^. #truncateBefore > StreamVersion 0 ->
              pure
                ( Left
                    ( StreamReprojectionTruncated
                        (request ^. #streamName)
                        (streamInfo ^. #truncateBefore)
                    )
                )
          | streamEventCount streamInfo > request ^. #maxEvents ->
              pure
                ( Left
                    ( StreamReprojectionEventLimitExceeded
                        (request ^. #streamName)
                        (streamEventCount streamInfo)
                        (request ^. #maxEvents)
                    )
                )
          | otherwise -> lockGroupAndRepair streamInfo

    streamEventCount streamInfo =
      case streamInfo ^. #version of
        StreamVersion value -> value

    -- Catalog command writers append first and acquire the group shared lock in
    -- their continuation. Taking the stream guard before the exclusive group
    -- fence preserves that global order and lets an already-appended writer
    -- finish instead of forming a row-lock cycle.
    lockGroupAndRepair streamInfo = do
      locked <- lockProjectionGroupForRepairTx catalog (request ^. #rebuildGroupId)
      case locked of
        ProjectionRepairGroupUnregistered groupId ->
          pure (Left (StreamReprojectionGroupUnregistered groupId))
        ProjectionRepairActiveRebuild groupId runId ->
          pure (Left (StreamReprojectionActiveRebuild groupId runId))
        ProjectionRepairGroupUnavailable groupId status readsAllowed writesAllowed ->
          pure (Left (StreamReprojectionGroupUnavailable groupId status readsAllowed writesAllowed))
        ProjectionRepairSliceDrift groupId expected actual ->
          pure (Left (StreamReprojectionSliceDrift groupId expected actual))
        ProjectionRepairServingRevisionUnavailable groupId revisionId ->
          pure (Left (StreamReprojectionServingRevisionUnavailable groupId revisionId))
        ProjectionRepairServingBindingInvalid groupId revisionId detail ->
          pure (Left (StreamReprojectionServingBindingInvalid groupId revisionId detail))
        ProjectionRepairAllowed binding ->
          case binding ^. #writeRevisionId of
            Nothing ->
              pure
                ( Left
                    ( StreamReprojectionGroupUnavailable
                        (request ^. #rebuildGroupId)
                        "unversioned"
                        True
                        True
                    )
                )
            Just revisionId ->
              case catalogStreamScopedReplay catalog revisionId (request ^. #projectionId) of
                Nothing ->
                  pure (Left (StreamReprojectionPolicyUnavailable revisionId (request ^. #projectionId)))
                Just policy -> runPolicy streamInfo binding revisionId policy

    runPolicy streamInfo binding revisionId policy = do
      cleared <-
        (policy ^. #clearStreamRows)
          (binding ^. #writePhysicalTargets)
          (request ^. #streamName)
      case cleared of
        Left detail -> condemned (StreamReprojectionClearFailed detail)
        Right clearCounts ->
          case validateClearEvidence policy (binding ^. #writePhysicalTargets) clearCounts of
            Left err -> condemned err
            Right normalizedCounts ->
              case policyDedupSpecs catalog (request ^. #rebuildGroupId) policy of
                Left err -> condemned err
                Right dedupSpecs -> do
                  replayed <-
                    replayPages
                      policy
                      (binding ^. #writePhysicalTargets)
                      streamInfo
                      dedupSpecs
                      (StreamVersion 0)
                      0
                      0
                      0
                      0
                  case replayed of
                    Left err -> pure (Left err)
                    Right (replayedEvents, appliedEvents, inserted, existing) -> do
                      verification <-
                        (policy ^. #verifyStreamRows)
                          (binding ^. #writePhysicalTargets)
                          (request ^. #streamName)
                      case verification of
                        Left detail -> condemned (StreamReprojectionVerificationFailed detail)
                        Right () ->
                          pure
                            ( Right
                                StreamReprojectionReport
                                  { rebuildGroupId = request ^. #rebuildGroupId,
                                    projectionId = request ^. #projectionId,
                                    streamName = request ^. #streamName,
                                    servingRevisionId = revisionId,
                                    streamVersion = streamInfo ^. #version,
                                    maxEvents = request ^. #maxEvents,
                                    clearedRows = normalizedCounts,
                                    replayedEvents,
                                    appliedEvents,
                                    dedupInserted = inserted,
                                    dedupExisting = existing,
                                    verified = True
                                  }
                            )

    replayPages policy targets streamInfo dedupSpecs cursor replayed applied inserted existing = do
      page <-
        readStreamForwardTx
          (request ^. #streamName)
          cursor
          (request ^. #pageSize)
      if Vector.null page
        then
          if cursor == streamInfo ^. #version
            then pure (Right (replayed, applied, inserted, existing))
            else condemned (StreamReprojectionHistoryIncomplete (streamInfo ^. #version) cursor)
        else do
          let events = Vector.toList page
          case List.find (foreignEvent streamInfo) events of
            Just recorded ->
              condemned
                ( StreamReprojectionForeignEvent
                    (request ^. #streamName)
                    (recorded ^. #streamVersion)
                )
            Nothing -> do
              outcomes <- traverse ((policy ^. #replayStreamEvent) targets) events
              case firstDecodeFailure events outcomes of
                Just err -> condemned err
                Nothing -> do
                  let pairs = dedupPairs dedupSpecs events
                  insertedNow <-
                    if null pairs
                      then pure 0
                      else Tx.statement (Prelude.unzip pairs) insertProjectionDedupBatchStmt
                  let attempted = fromIntegral (length pairs)
                      appliedNow = fromIntegral (length (filter (== Right True) outcomes))
                      nextCursor = last events ^. #streamVersion
                  replayPages
                    policy
                    targets
                    streamInfo
                    dedupSpecs
                    nextCursor
                    (replayed + fromIntegral (length events))
                    (applied + appliedNow)
                    (inserted + insertedNow)
                    (existing + attempted - insertedNow)

    foreignEvent streamInfo recorded =
      recorded ^. #originalStreamId /= streamInfo ^. #id
        || recorded ^. #originalVersion /= recorded ^. #streamVersion

    firstDecodeFailure events outcomes =
      listToMaybe
        [ StreamReprojectionDecodeFailed (recorded ^. #streamVersion) decodeError
        | (recorded, Left decodeError) <- zip events outcomes
        ]

policySource ::
  ValidatedProjectionCatalog ->
  ProjectionId ->
  Maybe (SourceId, SourceScope)
policySource catalog wantedProjection = do
  projection <-
    List.find
      ((== wantedProjection) . (^. #projectionId))
      (catalogInventory catalog ^. #inventoryProjections)
  source <-
    List.find
      ((== projection ^. #sourceId) . (^. #sourceId))
      (catalogInventory catalog ^. #inventorySources)
  pure (source ^. #sourceId, source ^. #sourceScope)

streamMatchesSource :: SourceScope -> StreamName -> Bool
streamMatchesSource AllStreams _ = True
streamMatchesSource (CategorySource category) (StreamName name) =
  categoryText category == Text.takeWhile (/= '-') name
  where
    categoryText = \case
      CategoryName value -> value

validateClearEvidence ::
  StreamScopedReplay ->
  PhysicalTargets ->
  [StreamClearCount] ->
  Either StreamReprojectionError [StreamClearCount]
validateClearEvidence policy targets counts
  | expected /= actual
      || length actualList /= Set.size actual
      || any ((< 0) . (^. #clearedRows)) counts =
      Left
        ( StreamReprojectionClearEvidenceInvalid
            (Set.toAscList expected)
            actualList
        )
  | any (isNothing . (`resolvePhysicalTarget` targets)) actualList =
      Left
        ( StreamReprojectionClearEvidenceInvalid
            (Set.toAscList expected)
            actualList
        )
  | otherwise = Right (List.sortOn (^. #targetId) counts)
  where
    expected = Set.fromList (NonEmpty.toList (policy ^. #streamOwnedTargets))
    actualList = map (^. #targetId) counts
    actual = Set.fromList actualList

policyDedupSpecs ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  StreamScopedReplay ->
  Either StreamReprojectionError [CatalogAsyncDedupSpec]
policyDedupSpecs catalog groupId policy =
  traverse resolve (policy ^. #affectedAsyncDedup)
  where
    available = catalogAsyncIdempotencyKeys catalog groupId
    resolve dedupId =
      maybe
        (Left (StreamReprojectionDedupIdentityUnavailable dedupId))
        Right
        (List.find ((== dedupId) . (^. #specDedupKeyId)) available)

dedupPairs :: [CatalogAsyncDedupSpec] -> [RecordedEvent] -> [(Text, UUID)]
dedupPairs specs events =
  [ (spec ^. #specDedupName, eventIdToUuid ((spec ^. #specIdempotencyKey) recorded))
  | recorded <- events,
    spec <- specs
  ]

eventIdToUuid :: EventId -> UUID
eventIdToUuid (EventId value) = value

condemned :: StreamReprojectionError -> Tx.Transaction (Either StreamReprojectionError value)
condemned err = Tx.condemn $> Left err

-- | Validate the pure catalog and request facts shared by preview and force.
-- The mutation still revalidates all persisted lifecycle and history facts
-- under its transaction locks.
validateStreamReprojectionAdmission ::
  ValidatedProjectionCatalog ->
  StreamReprojectionRequest ->
  Either StreamReprojectionError ()
validateStreamReprojectionAdmission catalog request
  | request ^. #pageSize <= 0 =
      Left (StreamReprojectionInvalidPageSize (request ^. #pageSize))
  | request ^. #maxEvents <= 0 =
      Left (StreamReprojectionInvalidMaxEvents (request ^. #maxEvents))
  | otherwise = do
      projection <-
        maybe
          (Left (StreamReprojectionUnknownProjection (request ^. #projectionId)))
          Right
          ( List.find
              ((== request ^. #projectionId) . (^. #projectionId))
              (catalogInventory catalog ^. #inventoryProjections)
          )
      let declaredGroup = projection ^. #rebuildGroupId
          requestedGroup = request ^. #rebuildGroupId
      if declaredGroup /= requestedGroup
        then
          Left
            ( StreamReprojectionProjectionGroupMismatch
                (request ^. #projectionId)
                declaredGroup
                requestedGroup
            )
        else case policySource catalog (request ^. #projectionId) of
          Nothing -> Left (StreamReprojectionUnknownProjection (request ^. #projectionId))
          Just (sourceId, sourceScope)
            | not (streamMatchesSource sourceScope (request ^. #streamName)) ->
                Left (StreamReprojectionSourceMismatch sourceId (request ^. #streamName))
            | otherwise -> Right ()
