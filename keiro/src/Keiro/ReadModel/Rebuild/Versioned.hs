{-# OPTIONS_HADDOCK hide #-}

-- | Persisted schema-versioned projection target lifecycle.
module Keiro.ReadModel.Rebuild.Versioned
  ( VersionedTargetMode (..),
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
    beginVersionedRebuild,
    beginVersionedRebuildTx,
    applyVersionedReplayEvent,
    applyVersionedReplayEventTx,
    verifyVersionedCandidate,
    verifyVersionedCandidateTx,
    resumeVersionedRebuild,
    inspectVersionedRebuild,
    abandonVersionedRebuild,
    abandonVersionedRebuildTx,
  )
where

import Contravariant.Extras
  ( contrazip2,
    contrazip3,
    contrazip4,
    contrazip5,
    contrazip6,
    contrazip7,
  )
import Control.Monad (foldM)
import Data.ByteString qualified as ByteString
import Data.Functor (($>))
import Data.Int (Int32)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Data.Vector qualified as Vector
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Connection (qualifyTable, quoteIdentifier)
import Keiro.Prelude
import Keiro.Projection.Catalog
  ( PhysicalTargets,
    ProjectionRevision (..),
    ProjectionRevisionId,
    PromotionObjectKind (..),
    PromotionObjectName (..),
    QualifiedTable (..),
    RebuildGroupId,
    ReplayDecodeError,
    SourceId,
    SourceScope (..),
    TargetGenerationId (..),
    TargetId,
    TargetProvisioner (..),
    TargetProvisioningContext (..),
    TargetSchemaEvidence (..),
    TargetSchemaVersion (..),
    TargetSchemaViolation,
    ValidatedProjectionCatalog,
    catalogFingerprint,
    catalogFingerprintText,
    catalogInventory,
    catalogProjectionRevision,
    groupSliceFingerprint,
    groupSliceFingerprintText,
    mkPhysicalTargets,
    physicalTargetMap,
    projectionRevisionIdText,
    rebuildGroupIdText,
    sourceIdText,
    targetIdText,
  )
import Keiro.Projection.Catalog qualified as Catalog
import Keiro.ReadModel.Rebuild.Group
  ( RebuildRunId,
    groupPreparationFor,
    insertProjectionDedupBatchStmt,
    rebuildRunIdText,
    resetDeclaredSubscriptions,
  )
import Keiro.ReadModel.Rebuild.Runner
  ( AsyncDedupBackfill (..),
    collectAsyncDedupBackfill,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.HistoryRetention
  ( HistoryRetentionLease (..),
    HistoryRetentionLeaseDuration,
    HistoryRetentionLeaseHandle (..),
    HistoryRetentionLeaseId (..),
    HistoryRetentionLeaseRequest,
    HistoryRetentionReleaseResult (..),
    HistoryRetentionRenewalError,
    acquireHistoryRetentionLeaseTx,
    historyRetentionLeaseOwnerText,
    maxHistoryRetentionLeaseDuration,
    mkHistoryRetentionLeaseDuration,
    mkHistoryRetentionLeaseOwner,
    releaseHistoryRetentionLeaseTx,
    renewHistoryRetentionLeaseTx,
  )
import Kiroku.Store.Read qualified as Store
import Kiroku.Store.Subscription.Types (SubscriptionName)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx

data VersionedTargetMode
  = ApplicationProvisioned
  | RestrictedClone
  deriving stock (Eq, Ord, Show, Generic)

versionedRunnerFormat :: Text
versionedRunnerFormat = "keiro/versioned-rebuild/v2"

versionedContract :: Text -> ProjectionRevisionId -> Text
versionedContract slice revisionId =
  Text.intercalate
    ":"
    [ "versioned-contract-v2",
      slice,
      projectionRevisionIdText revisionId
    ]

data VersionedRebuildRequest = VersionedRebuildRequest
  { rebuildRunId :: !RebuildRunId,
    rebuildGroupId :: !RebuildGroupId,
    servingRevisionId :: !ProjectionRevisionId,
    candidateRevisionId :: !ProjectionRevisionId,
    servingTargets :: !PhysicalTargets,
    targetMode :: !VersionedTargetMode,
    replayPageSize :: !Int32,
    cutoverThreshold :: !Int64,
    cutoverLockTimeoutMs :: !Int64,
    retentionLeaseRequest :: !HistoryRetentionLeaseRequest,
    requestedBy :: !Text,
    requestReason :: !Text
  }
  deriving stock (Generic)

data VersionedRebuildError
  = VersionedGroupNotInCatalog !RebuildGroupId
  | VersionedRevisionNotInCatalog !ProjectionRevisionId
  | VersionedRevisionGroupMismatch !ProjectionRevisionId !RebuildGroupId
  | VersionedGroupUnregistered !RebuildGroupId
  | VersionedGroupSliceDrift !RebuildGroupId !Text !Text
  | VersionedGroupNotReady !RebuildGroupId !Text !(Maybe Text)
  | VersionedServingRevisionMismatch !RebuildGroupId !ProjectionRevisionId !ProjectionRevisionId
  | VersionedServingTargetSetMismatch !ProjectionRevisionId
  | VersionedServingTargetBindingMismatch !TargetId !QualifiedTable !QualifiedTable
  | VersionedInvalidCutoverThreshold !Int64
  | VersionedInvalidCutoverLockTimeout !Int64
  | VersionedInvalidReplayPageSize !Int32
  | VersionedCloneProvisioningUnavailable
  | VersionedRunIdentityConflict !RebuildRunId !Text
  | VersionedStagingNameCollision !TargetId !QualifiedTable !Int64
  | VersionedPhysicalRelationMissing !TargetId !QualifiedTable
  | VersionedRelationIdentityMismatch !TargetId !Int64 !Int64
  | VersionedSchemaValidationFailed !TargetId ![TargetSchemaViolation]
  | VersionedSchemaValidatorMissing !TargetId
  | VersionedPromotionEvidenceMismatch !TargetId ![PromotionObjectName] ![PromotionObjectName]
  | VersionedPersistedLifecycleInvalid !RebuildRunId !Text
  | VersionedRetentionOwnerInvalid !RebuildRunId
  | VersionedRetentionRenewalFailed !RebuildRunId !HistoryRetentionRenewalError
  | VersionedRetentionReleaseFailed !RebuildRunId !Text
  | VersionedReplayDecodeFailed !RebuildRunId !Text !ReplayDecodeError
  | VersionedCandidateVerificationFailed !RebuildRunId !Text !Text
  | VersionedReplayContractMismatch !RebuildRunId !Text !Text
  | VersionedReplayInvariantFailed !RebuildRunId !Text
  | VersionedPromotionCheckpointsMissing !RebuildRunId ![SubscriptionName]
  | VersionedObservedShapeMismatch !TargetId !Text !Text
  | VersionedRetiredNameCollision !TargetId !QualifiedTable !Int64
  deriving stock (Eq, Show, Generic)

data VersionedGenerationLifecycle
  = GenerationStaging
  | GenerationServing
  | GenerationRetired
  | GenerationDropped
  | UnknownGenerationLifecycle !Text
  deriving stock (Eq, Ord, Show, Generic)

data VersionedTargetGeneration = VersionedTargetGeneration
  { generationId :: !TargetGenerationId,
    targetId :: !TargetId,
    revisionId :: !ProjectionRevisionId,
    physicalTable :: !QualifiedTable,
    relationOid :: !Int64,
    schemaVersion :: !TargetSchemaVersion,
    expectedShapeId :: !Text,
    observedShapeFingerprint :: !Text,
    lifecycle :: !VersionedGenerationLifecycle
  }
  deriving stock (Eq, Show, Generic)

data VersionedLeaseEvidence = VersionedLeaseEvidence
  { leaseId :: !UUID,
    owner :: !Text,
    protectedThrough :: !GlobalPosition,
    expiresAt :: !UTCTime,
    renewedAt :: !UTCTime,
    releasedAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

data VersionedRebuildHandle = VersionedRebuildHandle
  { rebuildRunId :: !RebuildRunId,
    rebuildGroupId :: !RebuildGroupId,
    servingRevisionId :: !ProjectionRevisionId,
    candidateRevisionId :: !ProjectionRevisionId,
    servingEpoch :: !Int64,
    cutoverThreshold :: !Int64,
    cutoverLockTimeoutMs :: !Int64,
    lease :: !VersionedLeaseEvidence,
    candidateGenerations :: ![VersionedTargetGeneration]
  }
  deriving stock (Eq, Show, Generic)

data VersionedRebuildPhase
  = VersionedReplayRunning
  | VersionedCutoverPendingHead
  | VersionedCutoverReplaying
  | VersionedPromoted
  | VersionedFailed
  | VersionedAbandoned
  | UnknownVersionedRebuildPhase !Text !Text
  deriving stock (Eq, Ord, Show, Generic)

data VersionedSourceProgress = VersionedSourceProgress
  { sourceId :: !SourceId,
    sourceScope :: !SourceScope,
    cursorPosition :: !GlobalPosition,
    targetPosition :: !GlobalPosition,
    exhaustedThrough :: !(Maybe GlobalPosition),
    eventCount :: !Int64
  }
  deriving stock (Eq, Show, Generic)

data VersionedRebuildReport = VersionedRebuildReport
  { rebuildRunId :: !RebuildRunId,
    rebuildGroupId :: !RebuildGroupId,
    phase :: !VersionedRebuildPhase,
    servingRevisionId :: !ProjectionRevisionId,
    candidateRevisionId :: !ProjectionRevisionId,
    servingEpoch :: !Int64,
    capturedHead :: !GlobalPosition,
    replayPageSize :: !Int32,
    cutoverThreshold :: !Int64,
    cutoverLockTimeoutMs :: !Int64,
    lease :: !VersionedLeaseEvidence,
    sources :: ![VersionedSourceProgress],
    servingGenerations :: ![VersionedTargetGeneration],
    candidateGenerations :: ![VersionedTargetGeneration]
  }
  deriving stock (Eq, Show, Generic)

data VersionedAbandonResult = VersionedAbandonResult
  { rebuildRunId :: !RebuildRunId,
    rebuildGroupId :: !RebuildGroupId,
    alreadyAbandoned :: !Bool,
    droppedGenerations :: ![VersionedTargetGeneration]
  }
  deriving stock (Eq, Show, Generic)

data PersistedGroup = PersistedGroup
  { persistedSlice :: !Text,
    persistedStatus :: !Text,
    persistedActiveRun :: !(Maybe Text),
    persistedServingRevision :: !(Maybe Text),
    persistedServingEpoch :: !Int64
  }
  deriving stock (Eq, Show, Generic)

data PersistedRun = PersistedRun
  { persistedRunId :: !Text,
    persistedGroupId :: !Text,
    persistedCatalogFingerprint :: !Text,
    persistedGroupSliceFingerprint :: !Text,
    persistedContractFingerprint :: !Text,
    persistedRunnerFormat :: !Text,
    persistedCapturedHead :: !Int64,
    persistedPageSize :: !Int32,
    persistedRunStatus :: !Text,
    persistedCandidateRevision :: !Text,
    persistedCutoverThreshold :: !Int64,
    persistedCutoverLockTimeoutMs :: !Int64,
    persistedLeaseId :: !UUID,
    persistedLeaseOwner :: !Text,
    persistedProtectedThrough :: !Int64,
    persistedLeaseExpiresAt :: !UTCTime,
    persistedLeaseRenewedAt :: !UTCTime,
    persistedLeaseReleasedAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

data InsertRun = InsertRun
  { runText :: !Text,
    groupText :: !Text,
    catalogText :: !Text,
    sliceText :: !Text,
    contractText :: !Text,
    candidateText :: !Text,
    pageSizeValue :: !Int32,
    thresholdValue :: !Int64,
    timeoutValue :: !Int64,
    leaseUuid :: !UUID,
    leaseOwnerText :: !Text,
    protectedPosition :: !Int64,
    leaseExpiry :: !UTCTime,
    leaseRenewal :: !UTCTime
  }
  deriving stock (Generic)

data InsertGeneration = InsertGeneration
  { generationUuid :: !UUID,
    generationGroup :: !Text,
    generationTarget :: !Text,
    generationRevision :: !Text,
    generationSchema :: !Text,
    generationRelation :: !Text,
    generationOid :: !Int64,
    generationSchemaVersion :: !Text,
    generationExpectedShape :: !Text,
    generationObservedShape :: !Text,
    generationSnapshot :: !Text,
    generationRun :: !(Maybe Text),
    generationLifecycle :: !Text
  }
  deriving stock (Generic)

data VersionedSourcePage = VersionedSourcePage
  { pageSource :: !VersionedSourceProgress,
    pageEvents :: ![RecordedEvent],
    pageProvesExhaustion :: !Bool
  }
  deriving stock (Generic)

data VersionedRoutedEvent = VersionedRoutedEvent
  { routedSourceId :: !SourceId,
    routedEvent :: !RecordedEvent
  }
  deriving stock (Generic)

beginVersionedRebuild ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  VersionedRebuildRequest ->
  Eff es (Either VersionedRebuildError VersionedRebuildHandle)
beginVersionedRebuild catalog request =
  runTransaction (beginVersionedRebuildTx catalog request)

beginVersionedRebuildTx ::
  ValidatedProjectionCatalog ->
  VersionedRebuildRequest ->
  Tx.Transaction (Either VersionedRebuildError VersionedRebuildHandle)
beginVersionedRebuildTx catalog request =
  case validateRequest catalog request of
    Left err -> pure (Left err)
    Right (servingRevision, candidateRevision, expectedServingTargets, slice) -> do
      groupRow <-
        Tx.statement
          (rebuildGroupIdText (request ^. #rebuildGroupId))
          lockVersionedGroupStmt
      case groupRow of
        Nothing -> condemned (VersionedGroupUnregistered (request ^. #rebuildGroupId))
        Just group
          | group ^. #persistedSlice /= slice ->
              condemned
                ( VersionedGroupSliceDrift
                    (request ^. #rebuildGroupId)
                    (group ^. #persistedSlice)
                    slice
                )
          | otherwise -> do
              existing <-
                Tx.statement
                  (rebuildRunIdText (request ^. #rebuildRunId))
                  lookupVersionedRunStmt
              case existing of
                Just run -> resumeExisting request slice group run
                Nothing ->
                  beginFresh
                    catalog
                    request
                    group
                    servingRevision
                    candidateRevision
                    expectedServingTargets
                    slice

-- | Apply one durable event through every adapter of the persisted candidate
-- revision, with the run's staging generations as its closed-world physical
-- target map. A stale or absent compiled revision fails before application SQL.
applyVersionedReplayEvent ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  RecordedEvent ->
  Eff es (Either VersionedRebuildError Int)
applyVersionedReplayEvent catalog runId recorded =
  runTransaction (applyVersionedReplayEventTx catalog runId recorded)

applyVersionedReplayEventTx ::
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  RecordedEvent ->
  Tx.Transaction (Either VersionedRebuildError Int)
applyVersionedReplayEventTx catalog runId recorded = do
  execution <- candidateExecutionContext catalog runId
  case execution of
    Left err -> condemned err
    Right (revision, targets) -> go 0 (revision ^. #replayAdapters)
      where
        go applied = \case
          [] -> pure (Right applied)
          adapter : rest -> do
            outcome <- (adapter ^. #runRevisionReplay) targets recorded
            case outcome of
              Left decodeError ->
                condemned
                  ( VersionedReplayDecodeFailed
                      runId
                      (adapter ^. #adapterId)
                      decodeError
                  )
              Right didApply -> go (if didApply then applied + 1 else applied) rest

-- | Run every application verification for the persisted candidate revision
-- against the staging generation map. This is independently callable so the
-- converging runner can execute it before the M5 cutover transaction.
verifyVersionedCandidate ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Eff es (Either VersionedRebuildError ())
verifyVersionedCandidate catalog runId =
  runTransaction (verifyVersionedCandidateTx catalog runId)

verifyVersionedCandidateTx ::
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Tx.Transaction (Either VersionedRebuildError ())
verifyVersionedCandidateTx catalog runId = do
  execution <- candidateExecutionContext catalog runId
  case execution of
    Left err -> condemned err
    Right (revision, targets) -> go (revision ^. #revisionVerifications)
      where
        go = \case
          [] -> pure (Right ())
          verification : rest -> do
            outcome <- (verification ^. #runRevisionVerification) targets
            case outcome of
              Left detail ->
                condemned
                  ( VersionedCandidateVerificationFailed
                      runId
                      (verification ^. #revisionVerificationId)
                      detail
                  )
              Right () -> go rest

inspectVersionedRebuild ::
  (Store :> es) =>
  RebuildRunId ->
  Eff es (Either VersionedRebuildError VersionedRebuildReport)
inspectVersionedRebuild runId = runTransaction $ do
  maybeRun <- Tx.statement (rebuildRunIdText runId) lookupVersionedRunStmt
  case maybeRun of
    Nothing -> pure (Left (VersionedRunIdentityConflict runId "versioned run does not exist"))
    Just run -> do
      maybeGroup <- Tx.statement (run ^. #persistedGroupId) readVersionedGroupStmt
      case maybeGroup of
        Nothing -> pure (Left (VersionedGroupUnregistered (parseGroupId (run ^. #persistedGroupId))))
        Just group -> do
          sourceRows <- Tx.statement (rebuildRunIdText runId) loadVersionedSourcesStmt
          servingRows <- Tx.statement (run ^. #persistedGroupId) loadServingGenerationsStmt
          candidateRows <- loadCandidateGenerations runId
          pure $ do
            servingText <-
              maybe
                (Left (VersionedPersistedLifecycleInvalid runId "serving revision is absent"))
                Right
                (group ^. #persistedServingRevision)
            pure
              VersionedRebuildReport
                { rebuildRunId = runId,
                  rebuildGroupId = parseGroupId (run ^. #persistedGroupId),
                  phase = parseVersionedPhase (run ^. #persistedRunStatus) (group ^. #persistedStatus),
                  servingRevisionId = parseRevisionId servingText,
                  candidateRevisionId = parseRevisionId (run ^. #persistedCandidateRevision),
                  servingEpoch = group ^. #persistedServingEpoch,
                  capturedHead = GlobalPosition (run ^. #persistedCapturedHead),
                  replayPageSize = run ^. #persistedPageSize,
                  cutoverThreshold = run ^. #persistedCutoverThreshold,
                  cutoverLockTimeoutMs = run ^. #persistedCutoverLockTimeoutMs,
                  lease = leaseEvidenceFor run,
                  sources = sourceRows,
                  servingGenerations = servingRows,
                  candidateGenerations = candidateRows
                }

leaseEvidenceFor :: PersistedRun -> VersionedLeaseEvidence
leaseEvidenceFor run =
  VersionedLeaseEvidence
    { leaseId = run ^. #persistedLeaseId,
      owner = run ^. #persistedLeaseOwner,
      protectedThrough = GlobalPosition (run ^. #persistedProtectedThrough),
      expiresAt = run ^. #persistedLeaseExpiresAt,
      renewedAt = run ^. #persistedLeaseRenewedAt,
      releasedAt = run ^. #persistedLeaseReleasedAt
    }

parseVersionedPhase :: Text -> Text -> VersionedRebuildPhase
parseVersionedPhase "running" "rebuilding-versioned" = VersionedReplayRunning
parseVersionedPhase "running" "cutover-versioned" = VersionedCutoverPendingHead
parseVersionedPhase "cutover" "cutover-versioned" = VersionedCutoverReplaying
parseVersionedPhase "promoted" "serving-versioned" = VersionedPromoted
parseVersionedPhase "failed" "failed-versioned" = VersionedFailed
parseVersionedPhase "abandoned" "serving-versioned" = VersionedAbandoned
parseVersionedPhase runStatus groupStatus = UnknownVersionedRebuildPhase runStatus groupStatus

-- | Advance one durable unit of versioned replay or cutover work. Every call
-- renews the original retention lease before mutation. The cutover fence and
-- final-head capture are deliberately separate durable phases, so a crash
-- between them resumes by recapturing the head while writers remain fenced.
resumeVersionedRebuild ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Eff es (Either VersionedRebuildError VersionedRebuildReport)
resumeVersionedRebuild catalog runId =
  inspectVersionedRebuild runId >>= \case
    Left err -> pure (Left err)
    Right report ->
      case validateVersionedReportContract catalog report of
        Left err -> pure (Left err)
        Right () -> advance report
  where
    advance report =
      case report ^. #phase of
        VersionedReplayRunning
          | allVersionedSourcesComplete (report ^. #sources) -> do
              visibleHead <- captureVersionedHead
              let GlobalPosition visible = visibleHead
                  GlobalPosition captured = report ^. #capturedHead
              if visible - captured > report ^. #cutoverThreshold
                then do
                  extended <-
                    runTransaction
                      (extendVersionedReplayHeadTx runId (expectedContract report) visibleHead)
                  case extended of
                    Left err -> pure (Left err)
                    Right () -> inspectVersionedRebuild runId
                else do
                  fenced <-
                    runTransaction
                      (enterVersionedCutoverTx runId (expectedContract report))
                  case fenced of
                    Left err -> pure (Left err)
                    Right () -> inspectVersionedRebuild runId
          | otherwise -> do
              applied <- applyNextVersionedChunk catalog report
              case applied of
                Left err -> pure (Left err)
                Right () -> inspectVersionedRebuild runId
        VersionedCutoverPendingHead -> do
          finalHead <- captureVersionedHead
          captured <-
            runTransaction
              (captureVersionedCutoverHeadTx runId (expectedContract report) finalHead)
          case captured of
            Left err -> pure (Left err)
            Right () -> inspectVersionedRebuild runId
        VersionedCutoverReplaying
          | allVersionedSourcesComplete (report ^. #sources) -> do
              backfill <-
                collectAsyncDedupBackfill
                  catalog
                  (report ^. #rebuildGroupId)
                  (report ^. #replayPageSize)
                  (report ^. #capturedHead)
              case backfill of
                Left missing -> pure (Left (VersionedPromotionCheckpointsMissing runId missing))
                Right redeliverySafety -> do
                  promoted <-
                    runTransaction
                      (promoteVersionedRebuildTx catalog runId (expectedContract report) redeliverySafety)
                  case promoted of
                    Left err -> pure (Left err)
                    Right () -> inspectVersionedRebuild runId
          | otherwise -> do
              applied <- applyNextVersionedChunk catalog report
              case applied of
                Left err -> pure (Left err)
                Right () -> inspectVersionedRebuild runId
        VersionedPromoted -> pure (Right report)
        VersionedFailed ->
          pure (Left (VersionedPersistedLifecycleInvalid runId "versioned run is failed and must be abandoned"))
        VersionedAbandoned ->
          pure (Left (VersionedPersistedLifecycleInvalid runId "versioned run was abandoned"))
        UnknownVersionedRebuildPhase runStatus groupStatus ->
          pure
            ( Left
                ( VersionedPersistedLifecycleInvalid
                    runId
                    ("run=" <> runStatus <> ", group=" <> groupStatus)
                )
            )

    expectedContract report =
      versionedContract
        (groupSliceText catalog (report ^. #rebuildGroupId))
        (report ^. #candidateRevisionId)

validateVersionedReportContract ::
  ValidatedProjectionCatalog ->
  VersionedRebuildReport ->
  Either VersionedRebuildError ()
validateVersionedReportContract catalog report = do
  revision <-
    maybe
      (Left (VersionedRevisionNotInCatalog (report ^. #candidateRevisionId)))
      Right
      (catalogProjectionRevision catalog (report ^. #candidateRevisionId))
  unless
    (revision ^. #rebuildGroup == report ^. #rebuildGroupId)
    (Left (VersionedRevisionGroupMismatch (report ^. #candidateRevisionId) (report ^. #rebuildGroupId)))
  void
    ( maybe
        (Left (VersionedGroupNotInCatalog (report ^. #rebuildGroupId)))
        Right
        (groupSliceFingerprint catalog (report ^. #rebuildGroupId))
    )

groupSliceText :: ValidatedProjectionCatalog -> RebuildGroupId -> Text
groupSliceText catalog groupId =
  maybe
    (error "validated versioned report group has no slice")
    groupSliceFingerprintText
    (groupSliceFingerprint catalog groupId)

allVersionedSourcesComplete :: [VersionedSourceProgress] -> Bool
allVersionedSourcesComplete =
  all (\source -> source ^. #exhaustedThrough == Just (source ^. #targetPosition))

captureVersionedHead :: (Store :> es) => Eff es GlobalPosition
captureVersionedHead = do
  events <- Store.readAllBackward (GlobalPosition 0) 1
  pure $ maybe (GlobalPosition 0) (^. #globalPosition) (events Vector.!? 0)

applyNextVersionedChunk ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  VersionedRebuildReport ->
  Eff es (Either VersionedRebuildError ())
applyNextVersionedChunk catalog report = do
  pages <- traverse (readVersionedSourcePage (report ^. #replayPageSize)) incomplete
  let ordered = versionedOrderedCandidates pages
      duplicates = duplicateVersionedPosition ordered
      horizon = versionedMergeHorizon pages
      chunk =
        Prelude.take
          (Prelude.fromIntegral (report ^. #replayPageSize))
          (Prelude.takeWhile ((<= horizon) . (^. #routedEvent . #globalPosition)) ordered)
  case duplicates of
    Just duplicate ->
      pure
        ( Left
            ( VersionedReplayInvariantFailed
                (report ^. #rebuildRunId)
                ("duplicate global position " <> renderGlobalPosition duplicate)
            )
        )
    Nothing ->
      runTransaction
        ( applyVersionedChunkTx
            catalog
            (report ^. #rebuildRunId)
            (versionedContract (groupSliceText catalog (report ^. #rebuildGroupId)) (report ^. #candidateRevisionId))
            pages
            chunk
        )
  where
    incomplete =
      [ source
      | source <- report ^. #sources,
        source ^. #exhaustedThrough /= Just (source ^. #targetPosition)
      ]

readVersionedSourcePage ::
  (Store :> es) =>
  Int32 ->
  VersionedSourceProgress ->
  Eff es VersionedSourcePage
readVersionedSourcePage pageSize source = do
  raw <-
    case source ^. #sourceScope of
      AllStreams -> Store.readAllForward (source ^. #cursorPosition) pageSize
      CategorySource category -> Store.readCategory category (source ^. #cursorPosition) pageSize
  let events = Vector.toList raw
      eligible = Prelude.takeWhile ((<= source ^. #targetPosition) . (^. #globalPosition)) events
      beyondTarget = Prelude.any ((> source ^. #targetPosition) . (^. #globalPosition)) events
      shortPage = Vector.length raw < Prelude.fromIntegral pageSize
      reachedTarget =
        not (null eligible)
          && Prelude.last eligible ^. #globalPosition == source ^. #targetPosition
  pure
    VersionedSourcePage
      { pageSource = source,
        pageEvents = eligible,
        pageProvesExhaustion = beyondTarget || shortPage || reachedTarget
      }

versionedOrderedCandidates :: [VersionedSourcePage] -> [VersionedRoutedEvent]
versionedOrderedCandidates =
  List.sortOn ((^. #globalPosition) . (^. #routedEvent))
    . concatMap
      ( \page ->
          [ VersionedRoutedEvent (page ^. #pageSource . #sourceId) event
          | event <- page ^. #pageEvents
          ]
      )

versionedMergeHorizon :: [VersionedSourcePage] -> GlobalPosition
versionedMergeHorizon pages = Prelude.minimum (versionedPageHorizon <$> pages)

versionedPageHorizon :: VersionedSourcePage -> GlobalPosition
versionedPageHorizon page
  | page ^. #pageProvesExhaustion = page ^. #pageSource . #targetPosition
  | otherwise =
      case page ^. #pageEvents of
        [] -> page ^. #pageSource . #cursorPosition
        events -> Prelude.last events ^. #globalPosition

duplicateVersionedPosition :: [VersionedRoutedEvent] -> Maybe GlobalPosition
duplicateVersionedPosition events =
  listToMaybe
    [ left ^. #routedEvent . #globalPosition
    | (left, right) <- List.zip events (Prelude.drop 1 events),
      left ^. #routedEvent . #globalPosition == right ^. #routedEvent . #globalPosition
    ]

renderGlobalPosition :: GlobalPosition -> Text
renderGlobalPosition (GlobalPosition position) = Text.pack (show position)

applyVersionedChunkTx ::
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Text ->
  [VersionedSourcePage] ->
  [VersionedRoutedEvent] ->
  Tx.Transaction (Either VersionedRebuildError ())
applyVersionedChunkTx catalog runId contract pages chunk = do
  renewed <- renewVersionedLeaseTx runId contract
  case renewed of
    Left err -> pure (Left err)
    Right () -> do
      active <- Tx.statement (rebuildRunIdText runId, contract) lockActiveVersionedReplayStmt
      if not active
        then condemned (VersionedPersistedLifecycleInvalid runId "run is not active for versioned replay")
        else do
          execution <- candidateExecutionContext catalog runId
          case execution of
            Left err -> condemned err
            Right (revision, targets) -> do
              applied <- applyEvents revision targets Map.empty chunk
              case applied of
                Left err -> condemned err
                Right adapterCounts -> do
                  advanced <- traverse advanceSource (Map.toList sourceAdvances)
                  if not (all id advanced)
                    then condemned (VersionedReplayInvariantFailed runId "source cursor changed concurrently")
                    else do
                      traverse_ advanceAdapter (Map.toList adapterCounts)
                      traverse_ completeSource completedSources
                      pure (Right ())
  where
    applyEvents _ _ counts [] = pure (Right counts)
    applyEvents revision targets counts (routed : rest) =
      applyAdapters targets counts routed (revision ^. #replayAdapters) >>= \case
        Left err -> pure (Left err)
        Right updated -> applyEvents revision targets updated rest

    applyAdapters _ counts _ [] = pure (Right counts)
    applyAdapters targets counts routed (adapter : rest) = do
      outcome <- (adapter ^. #runRevisionReplay) targets (routed ^. #routedEvent)
      let key = (sourceIdText (routed ^. #routedSourceId), adapter ^. #adapterId)
          (evaluations, applications) = Map.findWithDefault (0, 0) key counts
          evaluated = (evaluations + 1, applications)
      case outcome of
        Left decodeError ->
          pure (Left (VersionedReplayDecodeFailed runId (adapter ^. #adapterId) decodeError))
        Right didApply ->
          applyAdapters
            targets
            (Map.insert key (if didApply then (evaluations + 1, applications + 1) else evaluated) counts)
            routed
            rest

    sourceAdvances =
      Map.fromListWith
        combineAdvance
        [ ( sourceIdText (routed ^. #routedSourceId),
            (routed ^. #routedEvent . #globalPosition, 1 :: Int64)
          )
        | routed <- chunk
        ]

    combineAdvance (leftPosition, leftCount) (rightPosition, rightCount) =
      (Prelude.max leftPosition rightPosition, leftCount + rightCount)

    expectedCursors =
      Map.fromList
        [ (sourceIdText (page ^. #pageSource . #sourceId), page ^. #pageSource . #cursorPosition)
        | page <- pages
        ]

    advanceSource (sourceText, (GlobalPosition cursor, eventDelta)) =
      case Map.lookup sourceText expectedCursors of
        Nothing -> pure False
        Just (GlobalPosition expected) ->
          Tx.statement
            (rebuildRunIdText runId, sourceText, expected, cursor, eventDelta)
            advanceVersionedSourceStmt

    advanceAdapter ((sourceText, adapterId), (evaluations, applications)) =
      Tx.statement
        (rebuildRunIdText runId, sourceText, adapterId, evaluations, applications)
        advanceVersionedAdapterStmt

    consumedBySource =
      Map.fromListWith
        (+)
        [ (sourceIdText (routed ^. #routedSourceId), 1 :: Int)
        | routed <- chunk
        ]

    completedSources =
      [ page ^. #pageSource
      | page <- pages,
        page ^. #pageProvesExhaustion,
        Map.findWithDefault 0 (sourceIdText (page ^. #pageSource . #sourceId)) consumedBySource
          == Prelude.length (page ^. #pageEvents)
      ]

    completeSource source =
      let GlobalPosition target = source ^. #targetPosition
       in Tx.statement
            (rebuildRunIdText runId, sourceIdText (source ^. #sourceId), target)
            completeVersionedSourceStmt

renewVersionedLeaseTx ::
  RebuildRunId ->
  Text ->
  Tx.Transaction (Either VersionedRebuildError ())
renewVersionedLeaseTx runId contract = do
  maybeRun <- Tx.statement (rebuildRunIdText runId) lookupVersionedRunStmt
  case maybeRun of
    Nothing -> pure (Left (VersionedRunIdentityConflict runId "versioned run does not exist"))
    Just run
      | run ^. #persistedContractFingerprint /= contract ->
          pure (Left (VersionedReplayContractMismatch runId (run ^. #persistedContractFingerprint) contract))
      | run ^. #persistedRunnerFormat /= versionedRunnerFormat ->
          pure (Left (VersionedReplayContractMismatch runId (run ^. #persistedRunnerFormat) versionedRunnerFormat))
      | otherwise ->
          case mkHistoryRetentionLeaseOwner (run ^. #persistedLeaseOwner) of
            Left _ -> pure (Left (VersionedRetentionOwnerInvalid runId))
            Right owner -> do
              renewed <-
                renewHistoryRetentionLeaseTx
                  (HistoryRetentionLeaseHandle (HistoryRetentionLeaseId (run ^. #persistedLeaseId)) owner)
                  versionedRenewalDuration
              case renewed of
                Left renewalError -> do
                  Tx.statement
                    ( rebuildRunIdText runId,
                      "retention.renewal-failed",
                      Text.pack (show renewalError)
                    )
                    markVersionedRetentionFailureStmt
                  pure (Left (VersionedRetentionRenewalFailed runId renewalError))
                Right lease -> do
                  updated <-
                    Tx.statement
                      (rebuildRunIdText runId, lease ^. #expiresAt, lease ^. #renewedAt)
                      updateVersionedLeaseEvidenceStmt
                  if updated
                    then pure (Right ())
                    else condemned (VersionedPersistedLifecycleInvalid runId "lease renewal lost the active run")

versionedRenewalDuration :: HistoryRetentionLeaseDuration
versionedRenewalDuration =
  either
    (error . show)
    id
    (mkHistoryRetentionLeaseDuration maxHistoryRetentionLeaseDuration)

extendVersionedReplayHeadTx ::
  RebuildRunId ->
  Text ->
  GlobalPosition ->
  Tx.Transaction (Either VersionedRebuildError ())
extendVersionedReplayHeadTx runId contract (GlobalPosition newHead) = do
  renewed <- renewVersionedLeaseTx runId contract
  case renewed of
    Left err -> pure (Left err)
    Right () -> do
      extended <- Tx.statement (rebuildRunIdText runId, contract, newHead) extendVersionedReplayHeadStmt
      if extended
        then pure (Right ())
        else condemned (VersionedPersistedLifecycleInvalid runId "replay head could not be extended")

enterVersionedCutoverTx ::
  RebuildRunId ->
  Text ->
  Tx.Transaction (Either VersionedRebuildError ())
enterVersionedCutoverTx runId contract = do
  renewed <- renewVersionedLeaseTx runId contract
  case renewed of
    Left err -> pure (Left err)
    Right () -> do
      fenced <- Tx.statement (rebuildRunIdText runId, contract) enterVersionedCutoverStmt
      if fenced
        then pure (Right ())
        else condemned (VersionedPersistedLifecycleInvalid runId "cutover fence prerequisites are incomplete")

captureVersionedCutoverHeadTx ::
  RebuildRunId ->
  Text ->
  GlobalPosition ->
  Tx.Transaction (Either VersionedRebuildError ())
captureVersionedCutoverHeadTx runId contract (GlobalPosition finalHead) = do
  renewed <- renewVersionedLeaseTx runId contract
  case renewed of
    Left err -> pure (Left err)
    Right () -> do
      captured <- Tx.statement (rebuildRunIdText runId, contract, finalHead) captureVersionedCutoverHeadStmt
      if captured
        then pure (Right ())
        else condemned (VersionedPersistedLifecycleInvalid runId "final cutover head could not be captured")

promoteVersionedRebuildTx ::
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Text ->
  AsyncDedupBackfill ->
  Tx.Transaction (Either VersionedRebuildError ())
promoteVersionedRebuildTx catalog runId contract redeliverySafety = do
  renewed <- renewVersionedLeaseTx runId contract
  case renewed of
    Left err -> pure (Left err)
    Right () -> do
      locked <- Tx.statement (rebuildRunIdText runId, contract) lockActiveVersionedPromotionStmt
      if not locked
        then condemned (VersionedPersistedLifecycleInvalid runId "promotion prerequisites are incomplete")
        else do
          maybeRun <- Tx.statement (rebuildRunIdText runId) lookupVersionedRunStmt
          case maybeRun of
            Nothing -> condemned (VersionedRunIdentityConflict runId "versioned run vanished under promotion lock")
            Just run -> do
              maybeGroup <- Tx.statement (run ^. #persistedGroupId) readVersionedGroupStmt
              case maybeGroup >>= (^. #persistedServingRevision) of
                Nothing -> condemned (VersionedPersistedLifecycleInvalid runId "serving revision vanished under promotion lock")
                Just servingRevisionText ->
                  case ( catalogRevisionByText catalog servingRevisionText,
                         catalogRevisionByText catalog (run ^. #persistedCandidateRevision)
                       ) of
                    (Nothing, _) -> condemned (VersionedRevisionNotInCatalog (parseRevisionId servingRevisionText))
                    (_, Nothing) -> condemned (VersionedRevisionNotInCatalog (parseRevisionId (run ^. #persistedCandidateRevision)))
                    (Just servingRevision, Just candidateRevision) -> do
                      serving <- Tx.statement (run ^. #persistedGroupId) loadServingGenerationsStmt
                      candidate <- loadCandidateGenerations runId
                      case pairPromotionGenerations runId servingRevision candidateRevision serving candidate of
                        Left err -> condemned err
                        Right pairs -> do
                          Tx.statement (Text.pack (show (run ^. #persistedCutoverLockTimeoutMs))) setCutoverStatementTimeoutStmt
                          collisions <- traverse retiredRelationCollision pairs
                          case [err | Left err <- collisions] of
                            err : _ -> condemned err
                            [] -> do
                              lockPromotionRelations pairs
                              identities <- verifyGenerationIdentities (serving <> candidate)
                              case identities of
                                Left err -> condemned err
                                Right () -> do
                                  revalidated <- revalidatePromotionPairs servingRevision candidateRevision pairs
                                  case revalidated of
                                    Left err -> condemned err
                                    Right () -> do
                                      persistedObjectRows <- Tx.statement (rebuildRunIdText runId) loadPromotionObjectsStmt
                                      let persistedObjects = groupPromotionObjectRows persistedObjectRows
                                      let declaredObjects =
                                            [ ( targetIdText targetId,
                                                provisioner ^. #promotionObjectNames
                                              )
                                            | (targetId, provisioner) <- Map.toAscList (candidateRevision ^. #targetProvisioners),
                                              not (null (provisioner ^. #promotionObjectNames))
                                            ]
                                      if persistedObjects /= declaredObjects
                                        then condemned (VersionedPersistedLifecycleInvalid runId "persisted promotion object map differs from the candidate revision")
                                        else do
                                          verified <- runPromotionVerifications runId candidateRevision (candidateTargets pairs)
                                          case verified of
                                            Left err -> condemned err
                                            Right () -> do
                                              traverse_ (renamePromotionPair servingRevision candidateRevision) pairs
                                              traverse_ insertDedupBatch (dedupBatches (redeliverySafety ^. #backfillPairs))
                                              checkpoints <- reconcilePromotionCheckpoints catalog runId run (redeliverySafety ^. #backfillFloors)
                                              case checkpoints of
                                                Left err -> condemned err
                                                Right () -> do
                                                  owner <-
                                                    case mkHistoryRetentionLeaseOwner (run ^. #persistedLeaseOwner) of
                                                      Left _ -> condemned (VersionedRetentionOwnerInvalid runId)
                                                      Right value -> pure (Right value)
                                                  case owner of
                                                    Left err -> pure (Left err)
                                                    Right validatedOwner -> do
                                                      releaseResult <-
                                                        releaseHistoryRetentionLeaseTx
                                                          ( HistoryRetentionLeaseHandle
                                                              (HistoryRetentionLeaseId (run ^. #persistedLeaseId))
                                                              validatedOwner
                                                          )
                                                      case releaseEvidence releaseResult of
                                                        Left detail -> condemned (VersionedRetentionReleaseFailed runId detail)
                                                        Right releasedAt -> do
                                                          promotedRun <-
                                                            Tx.statement
                                                              (rebuildRunIdText runId, releasedAt)
                                                              markVersionedRunPromotedStmt
                                                          promotedGroup <-
                                                            Tx.statement
                                                              ( run ^. #persistedGroupId,
                                                                rebuildRunIdText runId,
                                                                run ^. #persistedCandidateRevision
                                                              )
                                                              finishVersionedPromotionGroupStmt
                                                          if promotedRun && promotedGroup
                                                            then pure (Right ())
                                                            else condemned (VersionedPersistedLifecycleInvalid runId "promotion metadata transition lost its locked row")
  where
    insertDedupBatch batch =
      void (Tx.statement (Prelude.unzip batch) insertProjectionDedupBatchStmt)

    retiredRelationCollision (_, serving, _) = do
      let retired = retiredTableFor serving
      resolveRelationOid retired <&> \case
        Nothing -> Right ()
        Just oid -> Left (VersionedRetiredNameCollision (serving ^. #targetId) retired oid)

pairPromotionGenerations ::
  RebuildRunId ->
  ProjectionRevision ->
  ProjectionRevision ->
  [VersionedTargetGeneration] ->
  [VersionedTargetGeneration] ->
  Either VersionedRebuildError [(TargetId, VersionedTargetGeneration, VersionedTargetGeneration)]
pairPromotionGenerations runId servingRevision candidateRevision serving candidate = do
  let servingById = Map.fromList [(generation ^. #targetId, generation) | generation <- serving]
      candidateById = Map.fromList [(generation ^. #targetId, generation) | generation <- candidate]
      expectedServing = Map.keysSet (servingRevision ^. #targetProvisioners)
      expectedCandidate = Map.keysSet (candidateRevision ^. #targetProvisioners)
  unless (expectedServing == expectedCandidate) (Left (VersionedServingTargetSetMismatch (servingRevision ^. #revisionId)))
  unless (Map.keysSet servingById == expectedServing) (Left (VersionedServingTargetSetMismatch (servingRevision ^. #revisionId)))
  unless (Map.keysSet candidateById == expectedCandidate) (Left (VersionedServingTargetSetMismatch (candidateRevision ^. #revisionId)))
  traverse
    ( \targetId -> do
        servingGeneration <- maybe (Left (VersionedServingTargetSetMismatch (servingRevision ^. #revisionId))) Right (Map.lookup targetId servingById)
        candidateGeneration <- maybe (Left (VersionedServingTargetSetMismatch (candidateRevision ^. #revisionId))) Right (Map.lookup targetId candidateById)
        unless (servingGeneration ^. #lifecycle == GenerationServing) (Left (VersionedPersistedLifecycleInvalid runId "serving generation is not serving"))
        unless (candidateGeneration ^. #lifecycle == GenerationStaging) (Left (VersionedPersistedLifecycleInvalid runId "candidate generation is not staging"))
        pure (targetId, servingGeneration, candidateGeneration)
    )
    (Map.keys servingById)

lockPromotionRelations :: [(TargetId, VersionedTargetGeneration, VersionedTargetGeneration)] -> Tx.Transaction ()
lockPromotionRelations pairs =
  for_ ordered $ \table ->
    Tx.sql
      ( Text.Encoding.encodeUtf8
          ( "LOCK TABLE "
              <> qualifyTable (table ^. #schemaName) (table ^. #tableName)
              <> " IN ACCESS EXCLUSIVE MODE"
          )
      )
  where
    ordered =
      List.sort
        . List.nub
        $ concatMap
          (\(_, serving, candidate) -> [serving ^. #physicalTable, candidate ^. #physicalTable])
          pairs

revalidatePromotionPairs ::
  ProjectionRevision ->
  ProjectionRevision ->
  [(TargetId, VersionedTargetGeneration, VersionedTargetGeneration)] ->
  Tx.Transaction (Either VersionedRebuildError ())
revalidatePromotionPairs servingRevision candidateRevision = foldM step (Right ())
  where
    step (Left err) _ = pure (Left err)
    step (Right ()) (targetId, serving, candidate) = do
      servingResult <- revalidate servingRevision serving (serving ^. #physicalTable) (serving ^. #physicalTable)
      case servingResult of
        Left err -> pure (Left err)
        Right () -> revalidate candidateRevision candidate (serving ^. #physicalTable) (candidate ^. #physicalTable)
      where
        revalidate revision generation servingTable stagingTable =
          case Map.lookup targetId (revision ^. #targetProvisioners) of
            Nothing -> pure (Left (VersionedServingTargetSetMismatch (revision ^. #revisionId)))
            Just provisioner -> do
              let context =
                    TargetProvisioningContext
                      targetId
                      (generation ^. #generationId)
                      servingTable
                      stagingTable
              validated <- validateProvisionedTarget targetId provisioner context (generation ^. #relationOid)
              pure $ case validated of
                Left err -> Left err
                Right evidence
                  | provisioner ^. #schemaVersion /= generation ^. #schemaVersion ->
                      Left (VersionedObservedShapeMismatch targetId (schemaVersionText (generation ^. #schemaVersion)) (schemaVersionText (provisioner ^. #schemaVersion)))
                  | provisioner ^. #expectedShapeId /= generation ^. #expectedShapeId ->
                      Left (VersionedObservedShapeMismatch targetId (generation ^. #expectedShapeId) (provisioner ^. #expectedShapeId))
                  | evidence ^. #observedShapeFingerprint /= generation ^. #observedShapeFingerprint ->
                      Left (VersionedObservedShapeMismatch targetId (generation ^. #observedShapeFingerprint) (evidence ^. #observedShapeFingerprint))
                  | otherwise -> Right ()

candidateTargets :: [(TargetId, VersionedTargetGeneration, VersionedTargetGeneration)] -> PhysicalTargets
candidateTargets pairs =
  either
    (error . show)
    id
    ( mkPhysicalTargets
        [targetId | (targetId, _, _) <- pairs]
        (Map.fromList [(targetId, candidate ^. #physicalTable) | (targetId, _, candidate) <- pairs])
    )

runPromotionVerifications ::
  RebuildRunId ->
  ProjectionRevision ->
  PhysicalTargets ->
  Tx.Transaction (Either VersionedRebuildError ())
runPromotionVerifications runId revision targets = go (revision ^. #revisionVerifications)
  where
    go [] = pure (Right ())
    go (verification : rest) = do
      result <- (verification ^. #runRevisionVerification) targets
      case result of
        Left detail ->
          pure
            ( Left
                ( VersionedCandidateVerificationFailed
                    runId
                    (verification ^. #revisionVerificationId)
                    detail
                )
            )
        Right () -> do
          Tx.statement
            (rebuildRunIdText runId, verification ^. #revisionVerificationId)
            markVersionedVerificationPassedStmt
          go rest

reconcilePromotionCheckpoints ::
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  PersistedRun ->
  [(Text, GlobalPosition)] ->
  Tx.Transaction (Either VersionedRebuildError ())
reconcilePromotionCheckpoints catalog runId run floors =
  case groupPreparationFor catalog (parseGroupId (run ^. #persistedGroupId)) of
    Nothing -> pure (Left (VersionedGroupNotInCatalog (parseGroupId (run ^. #persistedGroupId))))
    Just preparation
      | null floors -> pure (Right ())
      | otherwise -> do
          report <- resetDeclaredSubscriptions preparation (GlobalPosition (run ^. #persistedCapturedHead))
          let missing = Vector.toList (report ^. #missingSubscriptionNames)
          pure $
            if null missing
              then Right ()
              else Left (VersionedPromotionCheckpointsMissing runId missing)

renamePromotionPair ::
  ProjectionRevision ->
  ProjectionRevision ->
  (TargetId, VersionedTargetGeneration, VersionedTargetGeneration) ->
  Tx.Transaction ()
renamePromotionPair servingRevision candidateRevision (targetId, serving, candidate) = do
  let servingProvisioner = (servingRevision ^. #targetProvisioners) Map.! targetId
      candidateProvisioner = (candidateRevision ^. #targetProvisioners) Map.! targetId
      servingTable = serving ^. #physicalTable
      candidateTable = candidate ^. #physicalTable
      retiredTable = retiredTableFor serving
  for_ (List.zip [0 :: Int ..] (servingProvisioner ^. #promotionObjectNames)) $ \(objectOrder, object) ->
    renameServingObject servingTable object (retiredObjectName serving objectOrder)
  renameTable servingTable (retiredTable ^. #tableName)
  renameTable candidateTable (servingTable ^. #tableName)
  let promotedTable = QualifiedTable (candidateTable ^. #schemaName) (servingTable ^. #tableName)
  for_ (candidateProvisioner ^. #promotionObjectNames) $ \object ->
    renameCandidateObject promotedTable object
  Tx.statement
    ( generationUuidValue (serving ^. #generationId),
      retiredTable ^. #schemaName,
      retiredTable ^. #tableName
    )
    retireServingGenerationStmt
  Tx.statement
    ( generationUuidValue (candidate ^. #generationId),
      promotedTable ^. #schemaName,
      promotedTable ^. #tableName
    )
    promoteCandidateGenerationStmt

renameTable :: QualifiedTable -> Text -> Tx.Transaction ()
renameTable table newName =
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "ALTER TABLE "
            <> qualifyTable (table ^. #schemaName) (table ^. #tableName)
            <> " RENAME TO "
            <> quoteIdentifier newName
        )
    )

renameServingObject :: QualifiedTable -> PromotionObjectName -> Text -> Tx.Transaction ()
renameServingObject table object retiredName =
  case object ^. #objectKind of
    PromotionIndex -> renameSchemaObject "INDEX" (table ^. #schemaName) (object ^. #canonicalName) retiredName
    PromotionOwnedSequence -> renameSchemaObject "SEQUENCE" (table ^. #schemaName) (object ^. #canonicalName) retiredName
    PromotionConstraint -> renameConstraint table (object ^. #canonicalName) retiredName

renameCandidateObject :: QualifiedTable -> PromotionObjectName -> Tx.Transaction ()
renameCandidateObject table object =
  case object ^. #objectKind of
    PromotionIndex -> renameSchemaObject "INDEX" (table ^. #schemaName) (object ^. #generationName) (object ^. #canonicalName)
    PromotionOwnedSequence -> renameSchemaObject "SEQUENCE" (table ^. #schemaName) (object ^. #generationName) (object ^. #canonicalName)
    PromotionConstraint -> renameConstraint table (object ^. #generationName) (object ^. #canonicalName)

renameSchemaObject :: Text -> Text -> Text -> Text -> Tx.Transaction ()
renameSchemaObject kind schema oldName newName =
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "ALTER "
            <> kind
            <> " "
            <> qualifyTable schema oldName
            <> " RENAME TO "
            <> quoteIdentifier newName
        )
    )

renameConstraint :: QualifiedTable -> Text -> Text -> Tx.Transaction ()
renameConstraint table oldName newName =
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "ALTER TABLE "
            <> qualifyTable (table ^. #schemaName) (table ^. #tableName)
            <> " RENAME CONSTRAINT "
            <> quoteIdentifier oldName
            <> " TO "
            <> quoteIdentifier newName
        )
    )

retiredTableFor :: VersionedTargetGeneration -> QualifiedTable
retiredTableFor generation =
  QualifiedTable
    (generation ^. #physicalTable . #schemaName)
    ("keiro_r_" <> compactGenerationId (generation ^. #generationId))

retiredObjectName :: VersionedTargetGeneration -> Int -> Text
retiredObjectName generation objectOrder =
  "keiro_ro_"
    <> Text.take 40 (compactGenerationId (generation ^. #generationId))
    <> "_"
    <> Text.pack (show objectOrder)

compactGenerationId :: TargetGenerationId -> Text
compactGenerationId = Text.filter (/= '-') . UUID.toText . generationUuidValue

dedupBatches :: [(Text, UUID)] -> [[(Text, UUID)]]
dedupBatches [] = []
dedupBatches pairs =
  let (batch, rest) = Prelude.splitAt 10000 pairs
   in batch : dedupBatches rest

candidateExecutionContext ::
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Tx.Transaction (Either VersionedRebuildError (ProjectionRevision, PhysicalTargets))
candidateExecutionContext catalog runId = do
  persisted <- Tx.statement (rebuildRunIdText runId) lookupVersionedRunStmt
  case persisted of
    Nothing -> pure (Left (VersionedRunIdentityConflict runId "versioned run does not exist"))
    Just run
      | run ^. #persistedRunStatus `notElem` ["running", "cutover"] ->
          pure
            ( Left
                ( VersionedPersistedLifecycleInvalid
                    runId
                    ("candidate execution requires running or cutover, found " <> run ^. #persistedRunStatus)
                )
            )
      | otherwise ->
          case catalogRevisionByText catalog (run ^. #persistedCandidateRevision) of
            Nothing ->
              pure
                ( Left
                    ( VersionedRevisionNotInCatalog
                        (parseRevisionId (run ^. #persistedCandidateRevision))
                    )
                )
            Just revision -> do
              generations <- loadCandidateGenerations runId
              if any ((/= GenerationStaging) . (^. #lifecycle)) generations
                then
                  pure
                    ( Left
                        ( VersionedPersistedLifecycleInvalid
                            runId
                            "candidate execution requires only staging generations"
                        )
                    )
                else do
                  identities <- verifyGenerationIdentities generations
                  pure $ case identities of
                    Left err -> Left err
                    Right () ->
                      case mkPhysicalTargets
                        (Map.keys (revision ^. #targetProvisioners))
                        ( Map.fromList
                            [ (generation ^. #targetId, generation ^. #physicalTable)
                            | generation <- generations
                            ]
                        ) of
                        Left errors ->
                          Left (VersionedPersistedLifecycleInvalid runId (Text.pack (show errors)))
                        Right targets -> Right (revision, targets)

catalogRevisionByText :: ValidatedProjectionCatalog -> Text -> Maybe ProjectionRevision
catalogRevisionByText catalog wanted =
  List.find
    (\revision -> projectionRevisionIdText (revision ^. #revisionId) == wanted)
    (Catalog.catalogProjectionRevisions catalog)

abandonVersionedRebuild ::
  (Store :> es) =>
  RebuildRunId ->
  Eff es (Either VersionedRebuildError VersionedAbandonResult)
abandonVersionedRebuild runId =
  runTransaction (abandonVersionedRebuildTx runId)

abandonVersionedRebuildTx ::
  RebuildRunId ->
  Tx.Transaction (Either VersionedRebuildError VersionedAbandonResult)
abandonVersionedRebuildTx runId = do
  locked <- Tx.statement (rebuildRunIdText runId) lockVersionedRunForAbandonStmt
  case locked of
    Nothing -> condemned (VersionedRunIdentityConflict runId "versioned run does not exist")
    Just (run, groupStatus, activeRun)
      | run ^. #persistedRunStatus == "abandoned" -> do
          generations <- loadCandidateGenerations runId
          pure
            ( Right
                VersionedAbandonResult
                  { rebuildRunId = runId,
                    rebuildGroupId = parseGroupId (run ^. #persistedGroupId),
                    alreadyAbandoned = True,
                    droppedGenerations = generations
                  }
            )
      | run ^. #persistedRunStatus `notElem` ["running", "cutover", "failed"]
          || groupStatus `notElem` ["rebuilding-versioned", "cutover-versioned", "failed-versioned"]
          || activeRun /= Just (rebuildRunIdText runId) ->
          condemned
            ( VersionedPersistedLifecycleInvalid
                runId
                ("run=" <> run ^. #persistedRunStatus <> ", group=" <> groupStatus)
            )
      | otherwise -> do
          generations <- loadCandidateGenerations runId
          identityResult <- verifyGenerationIdentities generations
          case identityResult of
            Left err -> condemned err
            Right () -> do
              for_ generations $ \generation ->
                Tx.sql
                  ( Text.Encoding.encodeUtf8
                      ( "DROP TABLE "
                          <> qualifyTable
                            (generation ^. #physicalTable . #schemaName)
                            (generation ^. #physicalTable . #tableName)
                      )
                  )
              Tx.statement (rebuildRunIdText runId) markGenerationsDroppedStmt
              owner <-
                case mkHistoryRetentionLeaseOwner (run ^. #persistedLeaseOwner) of
                  Left _ -> condemned (VersionedRetentionOwnerInvalid runId)
                  Right value -> pure (Right value)
              case owner of
                Left err -> pure (Left err)
                Right validatedOwner -> do
                  releaseResult <-
                    releaseHistoryRetentionLeaseTx
                      ( HistoryRetentionLeaseHandle
                          (HistoryRetentionLeaseId (run ^. #persistedLeaseId))
                          validatedOwner
                      )
                  case releaseEvidence releaseResult of
                    Left detail -> condemned (VersionedRetentionReleaseFailed runId detail)
                    Right released -> do
                      updatedRun <-
                        Tx.statement
                          (rebuildRunIdText runId, released)
                          markVersionedRunAbandonedStmt
                      updatedGroup <-
                        Tx.statement
                          (run ^. #persistedGroupId, rebuildRunIdText runId)
                          restoreVersionedServingGroupStmt
                      if not updatedRun || not updatedGroup
                        then condemned (VersionedPersistedLifecycleInvalid runId "abandon transition lost its locked row")
                        else do
                          dropped <- loadCandidateGenerations runId
                          pure
                            ( Right
                                VersionedAbandonResult
                                  { rebuildRunId = runId,
                                    rebuildGroupId = parseGroupId (run ^. #persistedGroupId),
                                    alreadyAbandoned = False,
                                    droppedGenerations = dropped
                                  }
                            )

validateRequest ::
  ValidatedProjectionCatalog ->
  VersionedRebuildRequest ->
  Either
    VersionedRebuildError
    (ProjectionRevision, ProjectionRevision, Map TargetId QualifiedTable, Text)
validateRequest catalog request
  | request ^. #replayPageSize <= 0 =
      Left (VersionedInvalidReplayPageSize (request ^. #replayPageSize))
  | request ^. #cutoverThreshold < 0 =
      Left (VersionedInvalidCutoverThreshold (request ^. #cutoverThreshold))
  | request ^. #cutoverLockTimeoutMs <= 0 =
      Left (VersionedInvalidCutoverLockTimeout (request ^. #cutoverLockTimeoutMs))
  | request ^. #targetMode == RestrictedClone = Left VersionedCloneProvisioningUnavailable
  | otherwise = do
      serving <- findRevision (request ^. #servingRevisionId)
      candidate <- findRevision (request ^. #candidateRevisionId)
      ensureGroup serving
      ensureGroup candidate
      expected <-
        maybe
          (Left (VersionedGroupNotInCatalog (request ^. #rebuildGroupId)))
          Right
          (catalogServingTargets catalog (request ^. #rebuildGroupId))
      let supplied = physicalTargetMap (request ^. #servingTargets)
      unless
        (Map.keysSet supplied == Map.keysSet (serving ^. #targetProvisioners))
        (Left (VersionedServingTargetSetMismatch (request ^. #servingRevisionId)))
      for_ (Map.toAscList expected) $ \(targetId, table) ->
        case Map.lookup targetId supplied of
          Just suppliedTable
            | suppliedTable == table -> Right ()
            | otherwise -> Left (VersionedServingTargetBindingMismatch targetId table suppliedTable)
          Nothing -> Left (VersionedServingTargetSetMismatch (request ^. #servingRevisionId))
      slice <-
        maybe
          (Left (VersionedGroupNotInCatalog (request ^. #rebuildGroupId)))
          (Right . groupSliceFingerprintText)
          (groupSliceFingerprint catalog (request ^. #rebuildGroupId))
      pure (serving, candidate, expected, slice)
  where
    findRevision revisionId =
      maybe
        (Left (VersionedRevisionNotInCatalog revisionId))
        Right
        (catalogProjectionRevision catalog revisionId)
    ensureGroup revision =
      unless
        (revision ^. #rebuildGroup == request ^. #rebuildGroupId)
        ( Left
            ( VersionedRevisionGroupMismatch
                (revision ^. #revisionId)
                (request ^. #rebuildGroupId)
            )
        )

beginFresh ::
  ValidatedProjectionCatalog ->
  VersionedRebuildRequest ->
  PersistedGroup ->
  ProjectionRevision ->
  ProjectionRevision ->
  Map TargetId QualifiedTable ->
  Text ->
  Tx.Transaction (Either VersionedRebuildError VersionedRebuildHandle)
beginFresh catalog request group servingRevision candidateRevision expectedServingTargets slice = do
  readiness <- ensureFreshGroupReady request group
  case readiness of
    Left err -> condemned err
    Right legacyAdoption -> do
      servingRegistered <- registerRevision request slice (servingRevision ^. #revisionId)
      candidateRegistered <- registerRevision request slice (candidateRevision ^. #revisionId)
      if not servingRegistered || not candidateRegistered
        then condemned (VersionedGroupSliceDrift (request ^. #rebuildGroupId) "registered revision has stale group identity" slice)
        else do
          servingEvidence <-
            if legacyAdoption
              then adoptServingGenerations request servingRevision expectedServingTargets
              else verifyPersistedServingGenerations request
          case servingEvidence of
            Left err -> condemned err
            Right () -> do
              lease <- acquireHistoryRetentionLeaseTx (request ^. #retentionLeaseRequest)
              insertVersionedRun catalog request slice lease
              initializeVersionedProgress catalog request candidateRevision (lease ^. #protectedThrough)
              groupUpdated <-
                Tx.statement
                  ( rebuildGroupIdText (request ^. #rebuildGroupId),
                    rebuildRunIdText (request ^. #rebuildRunId),
                    projectionRevisionIdText (request ^. #servingRevisionId),
                    request ^. #requestedBy,
                    request ^. #requestReason
                  )
                  beginVersionedGroupStmt
              if not groupUpdated
                then condemned (VersionedGroupNotReady (request ^. #rebuildGroupId) (group ^. #persistedStatus) (group ^. #persistedActiveRun))
                else do
                  provisioned <- provisionCandidateGenerations request candidateRevision expectedServingTargets
                  case provisioned of
                    Left err -> condemned err
                    Right () -> loadHandle request

ensureFreshGroupReady ::
  VersionedRebuildRequest ->
  PersistedGroup ->
  Tx.Transaction (Either VersionedRebuildError Bool)
ensureFreshGroupReady request group =
  case group ^. #persistedStatus of
    "live"
      | isNothing (group ^. #persistedActiveRun)
          && isNothing (group ^. #persistedServingRevision) ->
          pure (Right True)
    "serving-versioned"
      | isNothing (group ^. #persistedActiveRun) ->
          case group ^. #persistedServingRevision of
            Just stored
              | stored == projectionRevisionIdText (request ^. #servingRevisionId) -> pure (Right False)
              | otherwise ->
                  pure
                    ( Left
                        ( VersionedServingRevisionMismatch
                            (request ^. #rebuildGroupId)
                            (request ^. #servingRevisionId)
                            (parseRevisionId stored)
                        )
                    )
            Nothing -> invalid
    _ -> invalid
  where
    invalid =
      pure
        ( Left
            ( VersionedGroupNotReady
                (request ^. #rebuildGroupId)
                (group ^. #persistedStatus)
                (group ^. #persistedActiveRun)
            )
        )

resumeExisting ::
  VersionedRebuildRequest ->
  Text ->
  PersistedGroup ->
  PersistedRun ->
  Tx.Transaction (Either VersionedRebuildError VersionedRebuildHandle)
resumeExisting request slice group run
  | run ^. #persistedGroupId /= rebuildGroupIdText (request ^. #rebuildGroupId) = conflict "group differs"
  | run ^. #persistedGroupSliceFingerprint /= slice = conflict "group slice differs"
  | run ^. #persistedContractFingerprint /= versionedContract slice (request ^. #candidateRevisionId) = conflict "replay contract differs"
  | run ^. #persistedRunnerFormat /= versionedRunnerFormat = conflict "runner format differs"
  | run ^. #persistedPageSize /= request ^. #replayPageSize = conflict "replay page size differs"
  | run ^. #persistedCandidateRevision /= projectionRevisionIdText (request ^. #candidateRevisionId) = conflict "candidate revision differs"
  | run ^. #persistedCutoverThreshold /= request ^. #cutoverThreshold = conflict "cutover threshold differs"
  | run ^. #persistedCutoverLockTimeoutMs /= request ^. #cutoverLockTimeoutMs = conflict "cutover lock timeout differs"
  | run ^. #persistedLeaseOwner /= requestedOwner = conflict "retention owner differs"
  | run ^. #persistedRunStatus /= "running" = conflict ("run status is " <> run ^. #persistedRunStatus)
  | group ^. #persistedStatus /= "rebuilding-versioned"
      || group ^. #persistedActiveRun /= Just (rebuildRunIdText (request ^. #rebuildRunId)) =
      conflict "group no longer names this active versioned run"
  | group ^. #persistedServingRevision /= Just (projectionRevisionIdText (request ^. #servingRevisionId)) =
      conflict "serving revision differs"
  | otherwise = loadHandle request
  where
    requestedOwner =
      historyRetentionLeaseOwnerText (request ^. #retentionLeaseRequest . #owner)
    conflict =
      pure . Left . VersionedRunIdentityConflict (request ^. #rebuildRunId)

adoptServingGenerations ::
  VersionedRebuildRequest ->
  ProjectionRevision ->
  Map TargetId QualifiedTable ->
  Tx.Transaction (Either VersionedRebuildError ())
adoptServingGenerations request revision targets =
  foldM step (Right ()) (Map.toAscList (revision ^. #targetProvisioners))
  where
    step (Left err) _ = pure (Left err)
    step (Right ()) (targetId, provisioner) = do
      let table = targets Map.! targetId
      resolved <- resolveRelationOid table
      case resolved of
        Nothing -> pure (Left (VersionedPhysicalRelationMissing targetId table))
        Just oid -> do
          let generationId = servingGenerationId request targetId table oid
              context = TargetProvisioningContext targetId generationId table table
          validated <- validateProvisionedTarget targetId provisioner context oid
          case validated of
            Left err -> pure (Left err)
            Right evidence -> do
              insertGeneration
                request
                targetId
                (revision ^. #revisionId)
                generationId
                table
                provisioner
                evidence
                Nothing
                "serving"
              pure (Right ())

verifyPersistedServingGenerations ::
  VersionedRebuildRequest ->
  Tx.Transaction (Either VersionedRebuildError ())
verifyPersistedServingGenerations request = do
  rows <-
    Tx.statement
      (rebuildGroupIdText (request ^. #rebuildGroupId))
      loadServingGenerationsStmt
  let expected = physicalTargetMap (request ^. #servingTargets)
      actual = Map.fromList [(generation ^. #targetId, generation) | generation <- rows]
  if Map.keysSet expected /= Map.keysSet actual
    then pure (Left (VersionedServingTargetSetMismatch (request ^. #servingRevisionId)))
    else foldM (check actual) (Right ()) (Map.toAscList expected)
  where
    check _ (Left err) _ = pure (Left err)
    check actual (Right ()) (targetId, table) =
      case Map.lookup targetId actual of
        Nothing -> pure (Left (VersionedServingTargetSetMismatch (request ^. #servingRevisionId)))
        Just generation
          | generation ^. #revisionId /= request ^. #servingRevisionId ->
              pure (Left (VersionedServingTargetSetMismatch (request ^. #servingRevisionId)))
          | generation ^. #physicalTable /= table ->
              pure (Left (VersionedServingTargetBindingMismatch targetId table (generation ^. #physicalTable)))
          | otherwise -> do
              resolved <- resolveRelationOid table
              pure $ case resolved of
                Nothing -> Left (VersionedPhysicalRelationMissing targetId table)
                Just oid
                  | oid /= generation ^. #relationOid ->
                      Left (VersionedRelationIdentityMismatch targetId (generation ^. #relationOid) oid)
                  | otherwise -> Right ()

provisionCandidateGenerations ::
  VersionedRebuildRequest ->
  ProjectionRevision ->
  Map TargetId QualifiedTable ->
  Tx.Transaction (Either VersionedRebuildError ())
provisionCandidateGenerations request revision servingTables =
  foldM step (Right ()) (Map.toAscList (revision ^. #targetProvisioners))
  where
    step (Left err) _ = pure (Left err)
    step (Right ()) (targetId, provisioner) = do
      let generationId = candidateGenerationId request targetId
          serving = servingTables Map.! targetId
          staging = QualifiedTable (serving ^. #schemaName) (generationRelationName generationId)
          context = TargetProvisioningContext targetId generationId serving staging
      existing <- resolveRelationOid staging
      case existing of
        Just oid -> pure (Left (VersionedStagingNameCollision targetId staging oid))
        Nothing -> do
          provisioner ^. #provisionTarget $ context
          resolved <- resolveRelationOid staging
          case resolved of
            Nothing -> pure (Left (VersionedPhysicalRelationMissing targetId staging))
            Just oid -> do
              validated <- validateProvisionedTarget targetId provisioner context oid
              case validated of
                Left err -> pure (Left err)
                Right evidence -> do
                  insertGeneration
                    request
                    targetId
                    (revision ^. #revisionId)
                    generationId
                    staging
                    provisioner
                    evidence
                    (Just (request ^. #rebuildRunId))
                    "staging"
                  Tx.statement
                    ( rebuildRunIdText (request ^. #rebuildRunId),
                      targetIdText targetId,
                      targetModeText (request ^. #targetMode),
                      generationUuidValue generationId
                    )
                    insertRunTargetStmt
                  for_ (List.zip [0 :: Int32 ..] (provisioner ^. #promotionObjectNames)) $ \(objectOrder, object) ->
                    Tx.statement
                      ( rebuildRunIdText (request ^. #rebuildRunId),
                        targetIdText targetId,
                        objectOrder,
                        promotionKindText (object ^. #objectKind),
                        object ^. #generationName,
                        object ^. #canonicalName
                      )
                      insertPromotionObjectStmt
                  pure (Right ())

validateProvisionedTarget ::
  TargetId ->
  TargetProvisioner ->
  TargetProvisioningContext ->
  Int64 ->
  Tx.Transaction (Either VersionedRebuildError TargetSchemaEvidence)
validateProvisionedTarget targetId provisioner context actualOid =
  case provisioner ^. #validateTarget of
    Nothing -> pure (Left (VersionedSchemaValidatorMissing targetId))
    Just validator ->
      validator context <&> \case
        Left violations -> Left (VersionedSchemaValidationFailed targetId violations)
        Right evidence
          | evidence ^. #relationOid /= actualOid ->
              Left (VersionedRelationIdentityMismatch targetId (evidence ^. #relationOid) actualOid)
          | evidence ^. #observedPromotionObjects /= provisioner ^. #promotionObjectNames ->
              Left
                ( VersionedPromotionEvidenceMismatch
                    targetId
                    (provisioner ^. #promotionObjectNames)
                    (evidence ^. #observedPromotionObjects)
                )
          | otherwise -> Right evidence

insertGeneration ::
  VersionedRebuildRequest ->
  TargetId ->
  ProjectionRevisionId ->
  TargetGenerationId ->
  QualifiedTable ->
  TargetProvisioner ->
  TargetSchemaEvidence ->
  Maybe RebuildRunId ->
  Text ->
  Tx.Transaction ()
insertGeneration request targetId revisionId generationId table provisioner evidence maybeRun lifecycle =
  Tx.statement
    InsertGeneration
      { generationUuid = generationUuidValue generationId,
        generationGroup = rebuildGroupIdText (request ^. #rebuildGroupId),
        generationTarget = targetIdText targetId,
        generationRevision = projectionRevisionIdText revisionId,
        generationSchema = table ^. #schemaName,
        generationRelation = table ^. #tableName,
        generationOid = evidence ^. #relationOid,
        generationSchemaVersion = schemaVersionText (provisioner ^. #schemaVersion),
        generationExpectedShape = provisioner ^. #expectedShapeId,
        generationObservedShape = evidence ^. #observedShapeFingerprint,
        generationSnapshot = evidence ^. #catalogSnapshot,
        generationRun = rebuildRunIdText <$> maybeRun,
        generationLifecycle = lifecycle
      }
    insertGenerationStmt

insertVersionedRun ::
  ValidatedProjectionCatalog ->
  VersionedRebuildRequest ->
  Text ->
  HistoryRetentionLease ->
  Tx.Transaction ()
insertVersionedRun catalog request slice lease =
  let HistoryRetentionLeaseId leaseId = lease ^. #leaseId
      GlobalPosition protected = lease ^. #protectedThrough
   in Tx.statement
        InsertRun
          { runText = rebuildRunIdText (request ^. #rebuildRunId),
            groupText = rebuildGroupIdText (request ^. #rebuildGroupId),
            catalogText = catalogFingerprintText (catalogFingerprint catalog),
            sliceText = slice,
            contractText = versionedContract slice (request ^. #candidateRevisionId),
            candidateText = projectionRevisionIdText (request ^. #candidateRevisionId),
            pageSizeValue = request ^. #replayPageSize,
            thresholdValue = request ^. #cutoverThreshold,
            timeoutValue = request ^. #cutoverLockTimeoutMs,
            leaseUuid = leaseId,
            leaseOwnerText = historyRetentionLeaseOwnerText (lease ^. #owner),
            protectedPosition = protected,
            leaseExpiry = lease ^. #expiresAt,
            leaseRenewal = lease ^. #renewedAt
          }
        insertVersionedRunStmt

initializeVersionedProgress ::
  ValidatedProjectionCatalog ->
  VersionedRebuildRequest ->
  ProjectionRevision ->
  GlobalPosition ->
  Tx.Transaction ()
initializeVersionedProgress catalog request revision (GlobalPosition target) = do
  traverse_ insertSource sources
  traverse_ insertAdapter indexedAdapters
  traverse_ insertVerification (revision ^. #revisionVerifications)
  where
    runText = rebuildRunIdText (request ^. #rebuildRunId)
    sources = versionedSourceSpecs catalog (request ^. #rebuildGroupId)
    indexedAdapters =
      [ (source, adapter, order)
      | (order, (source, adapter)) <-
          List.zip
            [0 :: Int32 ..]
            [ (source, adapter)
            | source <- sources,
              adapter <- revision ^. #replayAdapters
            ]
      ]

    insertSource (sourceId, scope) =
      let (scopeText, category) = encodeSourceScope scope
       in Tx.statement
            (runText, sourceIdText sourceId, scopeText, category, 0, target)
            insertVersionedSourceStmt

    insertAdapter ((sourceId, _), adapter, order) =
      Tx.statement
        (runText, sourceIdText sourceId, adapter ^. #adapterId, order)
        insertVersionedAdapterStmt

    insertVerification verification =
      Tx.statement
        ( runText,
          verification ^. #revisionVerificationId,
          Text.pack (show (verification ^. #revisionVerificationVersion))
        )
        insertVersionedVerificationStmt

versionedSourceSpecs :: ValidatedProjectionCatalog -> RebuildGroupId -> [(SourceId, SourceScope)]
versionedSourceSpecs catalog groupId =
  List.sortOn
    (sourceIdText . Prelude.fst)
    [ (source ^. #sourceId, source ^. #sourceScope)
    | source <- catalogInventory catalog ^. #inventorySources,
      source ^. #sourceId `elem` wantedSourceIds
    ]
  where
    wantedSourceIds =
      List.nub
        [ projection ^. #sourceId
        | projection <- catalogInventory catalog ^. #inventoryProjections,
          projection ^. #rebuildGroupId == groupId
        ]

encodeSourceScope :: SourceScope -> (Text, Maybe Text)
encodeSourceScope AllStreams = ("all", Nothing)
encodeSourceScope (CategorySource (CategoryName category)) = ("category", Just category)

registerRevision ::
  VersionedRebuildRequest ->
  Text ->
  ProjectionRevisionId ->
  Tx.Transaction Bool
registerRevision request slice revisionId =
  Tx.statement
    ( rebuildGroupIdText (request ^. #rebuildGroupId),
      projectionRevisionIdText revisionId,
      slice
    )
    ensureRevisionRegisteredStmt

loadHandle ::
  VersionedRebuildRequest ->
  Tx.Transaction (Either VersionedRebuildError VersionedRebuildHandle)
loadHandle request = do
  maybeRun <- Tx.statement (rebuildRunIdText (request ^. #rebuildRunId)) lookupVersionedRunStmt
  maybeGroup <- Tx.statement (rebuildGroupIdText (request ^. #rebuildGroupId)) readVersionedGroupStmt
  generations <- loadCandidateGenerations (request ^. #rebuildRunId)
  pure $ do
    run <- maybe (Left (VersionedPersistedLifecycleInvalid (request ^. #rebuildRunId) "run missing after begin")) Right maybeRun
    group <- maybe (Left (VersionedGroupUnregistered (request ^. #rebuildGroupId))) Right maybeGroup
    servingText <- maybe (Left (VersionedPersistedLifecycleInvalid (request ^. #rebuildRunId) "serving revision missing after begin")) Right (group ^. #persistedServingRevision)
    pure
      VersionedRebuildHandle
        { rebuildRunId = request ^. #rebuildRunId,
          rebuildGroupId = request ^. #rebuildGroupId,
          servingRevisionId = parseRevisionId servingText,
          candidateRevisionId = parseRevisionId (run ^. #persistedCandidateRevision),
          servingEpoch = group ^. #persistedServingEpoch,
          cutoverThreshold = run ^. #persistedCutoverThreshold,
          cutoverLockTimeoutMs = run ^. #persistedCutoverLockTimeoutMs,
          lease =
            VersionedLeaseEvidence
              { leaseId = run ^. #persistedLeaseId,
                owner = run ^. #persistedLeaseOwner,
                protectedThrough = GlobalPosition (run ^. #persistedProtectedThrough),
                expiresAt = run ^. #persistedLeaseExpiresAt,
                renewedAt = run ^. #persistedLeaseRenewedAt,
                releasedAt = run ^. #persistedLeaseReleasedAt
              },
          candidateGenerations = generations
        }

loadCandidateGenerations :: RebuildRunId -> Tx.Transaction [VersionedTargetGeneration]
loadCandidateGenerations runId =
  Tx.statement (rebuildRunIdText runId) loadCandidateGenerationsStmt

verifyGenerationIdentities ::
  [VersionedTargetGeneration] ->
  Tx.Transaction (Either VersionedRebuildError ())
verifyGenerationIdentities = foldM step (Right ())
  where
    step (Left err) _ = pure (Left err)
    step (Right ()) generation
      | generation ^. #lifecycle == GenerationDropped = pure (Right ())
      | otherwise = do
          actual <- resolveRelationOid (generation ^. #physicalTable)
          pure $ case actual of
            Nothing -> Left (VersionedPhysicalRelationMissing (generation ^. #targetId) (generation ^. #physicalTable))
            Just oid
              | oid /= generation ^. #relationOid ->
                  Left (VersionedRelationIdentityMismatch (generation ^. #targetId) (generation ^. #relationOid) oid)
              | otherwise -> Right ()

resolveRelationOid :: QualifiedTable -> Tx.Transaction (Maybe Int64)
resolveRelationOid table =
  Tx.statement (table ^. #schemaName, table ^. #tableName) resolveRelationOidStmt

releaseEvidence :: HistoryRetentionReleaseResult -> Either Text (Maybe UTCTime)
releaseEvidence = \case
  HistoryRetentionReleased lease -> Right (lease ^. #releasedAt)
  HistoryRetentionAlreadyReleased lease -> Right (lease ^. #releasedAt)
  HistoryRetentionReleaseExpired lease -> Right (lease ^. #releasedAt)
  HistoryRetentionReleaseUnknown -> Left "retention lease is unknown"
  HistoryRetentionReleaseOwnerMismatch -> Left "retention lease owner differs"

catalogServingTargets ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  Maybe (Map TargetId QualifiedTable)
catalogServingTargets catalog wantedGroup = do
  group <- List.find ((== wantedGroup) . (^. #rebuildGroupId)) (catalogInventory catalog ^. #inventoryGroups)
  let targetsById =
        Map.fromList
          [ (target ^. #targetId, target ^. #qualifiedTable)
          | target <- catalogInventory catalog ^. #inventoryTargets
          ]
  traverse (`Map.lookup` targetsById) (group ^. #orderedTargets)
    <&> Map.fromList
    . List.zip (group ^. #orderedTargets)

servingGenerationId ::
  VersionedRebuildRequest ->
  TargetId ->
  QualifiedTable ->
  Int64 ->
  TargetGenerationId
servingGenerationId request targetId table oid =
  deterministicGenerationId
    ( Text.intercalate
        "\NUL"
        [ "keiro/versioned-serving-generation/v1",
          rebuildGroupIdText (request ^. #rebuildGroupId),
          projectionRevisionIdText (request ^. #servingRevisionId),
          targetIdText targetId,
          table ^. #schemaName,
          table ^. #tableName,
          Text.pack (show oid)
        ]
    )

candidateGenerationId :: VersionedRebuildRequest -> TargetId -> TargetGenerationId
candidateGenerationId request targetId =
  deterministicGenerationId
    ( Text.intercalate
        "\NUL"
        [ "keiro/versioned-candidate-generation/v1",
          rebuildRunIdText (request ^. #rebuildRunId),
          rebuildGroupIdText (request ^. #rebuildGroupId),
          targetIdText targetId
        ]
    )

deterministicGenerationId :: Text -> TargetGenerationId
deterministicGenerationId seed =
  TargetGenerationId
    ( UUID.V5.generateNamed
        UUID.V5.namespaceURL
        (ByteString.unpack (Text.Encoding.encodeUtf8 seed))
    )

generationRelationName :: TargetGenerationId -> Text
generationRelationName generationId =
  "keiro_g_" <> Text.filter (/= '-') (UUID.toText (generationUuidValue generationId))

generationUuidValue :: TargetGenerationId -> UUID
generationUuidValue (TargetGenerationId value) = value

targetModeText :: VersionedTargetMode -> Text
targetModeText ApplicationProvisioned = "application"
targetModeText RestrictedClone = "clone"

promotionKindText :: PromotionObjectKind -> Text
promotionKindText PromotionIndex = "index"
promotionKindText PromotionConstraint = "constraint"
promotionKindText PromotionOwnedSequence = "owned-sequence"

parsePromotionKind :: Text -> PromotionObjectKind
parsePromotionKind "index" = PromotionIndex
parsePromotionKind "constraint" = PromotionConstraint
parsePromotionKind "owned-sequence" = PromotionOwnedSequence
parsePromotionKind other = error ("invalid persisted promotion object kind: " <> Text.unpack other)

groupPromotionObjectRows :: [(Text, PromotionObjectName)] -> [(Text, [PromotionObjectName])]
groupPromotionObjectRows [] = []
groupPromotionObjectRows ((targetId, promotionObject) : rest) =
  let (sameTarget, remaining) = List.span ((== targetId) . Prelude.fst) rest
   in (targetId, promotionObject : (Prelude.snd <$> sameTarget))
        : groupPromotionObjectRows remaining

schemaVersionText :: TargetSchemaVersion -> Text
schemaVersionText (TargetSchemaVersion value) = value

parseGenerationLifecycle :: Text -> VersionedGenerationLifecycle
parseGenerationLifecycle "staging" = GenerationStaging
parseGenerationLifecycle "serving" = GenerationServing
parseGenerationLifecycle "retired" = GenerationRetired
parseGenerationLifecycle "dropped" = GenerationDropped
parseGenerationLifecycle other = UnknownGenerationLifecycle other

parseGroupId :: Text -> RebuildGroupId
parseGroupId value =
  either (error . show) id (Catalog.mkRebuildGroupId value)

parseRevisionId :: Text -> ProjectionRevisionId
parseRevisionId value =
  either (error . show) id (Catalog.mkProjectionRevisionId value)

condemned :: VersionedRebuildError -> Tx.Transaction (Either VersionedRebuildError value)
condemned err = Tx.condemn $> Left err

lockVersionedGroupStmt :: Statement Text (Maybe PersistedGroup)
lockVersionedGroupStmt =
  preparable
    """
    SELECT slice_fingerprint, status, active_run_id, serving_revision_id, serving_epoch
    FROM keiro.keiro_projection_rebuild_groups
    WHERE group_id = $1
    FOR UPDATE
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe persistedGroupDecoder)

readVersionedGroupStmt :: Statement Text (Maybe PersistedGroup)
readVersionedGroupStmt =
  preparable
    """
    SELECT slice_fingerprint, status, active_run_id, serving_revision_id, serving_epoch
    FROM keiro.keiro_projection_rebuild_groups
    WHERE group_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe persistedGroupDecoder)

persistedGroupDecoder :: D.Row PersistedGroup
persistedGroupDecoder =
  PersistedGroup
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.int8)

ensureRevisionRegisteredStmt :: Statement (Text, Text, Text) Bool
ensureRevisionRegisteredStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_revisions
      (group_id, revision_id, group_slice_fingerprint)
    VALUES ($1, $2, $3)
    ON CONFLICT (group_id, revision_id) DO UPDATE
      SET updated_at = now()
    WHERE keiro.keiro_projection_revisions.group_slice_fingerprint = EXCLUDED.group_slice_fingerprint
    RETURNING TRUE
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

beginVersionedGroupStmt :: Statement (Text, Text, Text, Text, Text) Bool
beginVersionedGroupStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET status = 'rebuilding-versioned',
        active_run_id = $2,
        serving_revision_id = $3,
        reads_allowed = TRUE,
        writes_allowed = TRUE,
        requested_by = $4,
        request_reason = $5,
        started_at = now(),
        completed_at = NULL,
        failed_at = NULL,
        failure_code = NULL,
        failure_detail = NULL,
        updated_at = now()
    WHERE group_id = $1
      AND active_run_id IS NULL
      AND status IN ('live', 'serving-versioned')
    RETURNING TRUE
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

insertVersionedRunStmt :: Statement InsertRun ()
insertVersionedRunStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_runs
      (run_id, group_id, catalog_fingerprint, group_slice_fingerprint,
       contract_fingerprint, runner_format, captured_head, page_size, status,
       rebuild_mode, candidate_revision_id, cutover_threshold,
       cutover_lock_timeout_ms, history_retention_lease_id,
       history_retention_lease_owner, history_retention_protected_through,
       history_retention_expires_at, history_retention_renewed_at)
    VALUES
      ($1, $2, $3, $4, $5, 'keiro/versioned-rebuild/v2', $12, $7,
       'running', 'versioned', $6, $8, $9, $10, $11, $12, $13, $14)
    """
    insertRunEncoder
    D.noResult

insertRunEncoder :: E.Params InsertRun
insertRunEncoder =
  contramap
    ( \value ->
        ( ( value ^. #runText,
            value ^. #groupText,
            value ^. #catalogText,
            value ^. #sliceText,
            value ^. #contractText,
            value ^. #candidateText,
            value ^. #pageSizeValue
          ),
          ( value ^. #thresholdValue,
            value ^. #timeoutValue,
            value ^. #leaseUuid,
            value ^. #leaseOwnerText,
            value ^. #protectedPosition,
            value ^. #leaseExpiry,
            value ^. #leaseRenewal
          )
        )
    )
    ( contrazip2
        ( contrazip7
            textParam
            textParam
            textParam
            textParam
            textParam
            textParam
            int4Param
        )
        (contrazip7 int8Param int8Param uuidParam textParam int8Param timestamptzParam timestamptzParam)
    )

insertVersionedSourceStmt :: Statement (Text, Text, Text, Maybe Text, Int64, Int64) ()
insertVersionedSourceStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_sources
      (run_id, source_id, source_scope, category, cursor_position, target_position)
    VALUES ($1, $2, $3, $4, $5, $6)
    """
    (contrazip6 textParam textParam textParam nullableTextParam int8Param int8Param)
    D.noResult

insertVersionedAdapterStmt :: Statement (Text, Text, Text, Int32) ()
insertVersionedAdapterStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_adapters
      (run_id, source_id, projection_id, adapter_order)
    VALUES ($1, $2, $3, $4)
    """
    (contrazip4 textParam textParam textParam int4Param)
    D.noResult

insertVersionedVerificationStmt :: Statement (Text, Text, Text) ()
insertVersionedVerificationStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_verifications
      (run_id, verification_id, verification_version)
    VALUES ($1, $2, $3)
    """
    (contrazip3 textParam textParam textParam)
    D.noResult

lookupVersionedRunStmt :: Statement Text (Maybe PersistedRun)
lookupVersionedRunStmt =
  preparable
    """
    SELECT run_id, group_id, catalog_fingerprint, group_slice_fingerprint,
           contract_fingerprint, runner_format, captured_head, page_size,
           status, candidate_revision_id,
           cutover_threshold, cutover_lock_timeout_ms,
           history_retention_lease_id, history_retention_lease_owner,
           history_retention_protected_through, history_retention_expires_at,
           history_retention_renewed_at, history_retention_released_at
    FROM keiro.keiro_projection_rebuild_runs
    WHERE run_id = $1 AND rebuild_mode = 'versioned'
    """
    textParam
    (D.rowMaybe persistedRunDecoder)

persistedRunDecoder :: D.Row PersistedRun
persistedRunDecoder =
  PersistedRun
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.int4)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

lockActiveVersionedReplayStmt :: Statement (Text, Text) Bool
lockActiveVersionedReplayStmt =
  preparable
    """
    SELECT runs.run_id
    FROM keiro.keiro_projection_rebuild_runs AS runs
    JOIN keiro.keiro_projection_rebuild_groups AS groups
      ON groups.group_id = runs.group_id
    WHERE runs.run_id = $1
      AND runs.contract_fingerprint = $2
      AND runs.status IN ('running', 'cutover')
      AND groups.status IN ('rebuilding-versioned', 'cutover-versioned')
      AND groups.active_run_id = runs.run_id
      AND groups.slice_fingerprint = runs.group_slice_fingerprint
    FOR UPDATE OF runs, groups
    """
    (contrazip2 textParam textParam)
    (isJust <$> D.rowMaybe (D.column (D.nonNullable D.text)))

updateVersionedLeaseEvidenceStmt :: Statement (Text, UTCTime, UTCTime) Bool
updateVersionedLeaseEvidenceStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_runs
    SET history_retention_expires_at = $2,
        history_retention_renewed_at = $3,
        updated_at = now()
    WHERE run_id = $1
      AND rebuild_mode = 'versioned'
      AND status IN ('running', 'cutover')
    RETURNING TRUE
    """
    (contrazip3 textParam timestamptzParam timestamptzParam)
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

markVersionedRetentionFailureStmt :: Statement (Text, Text, Text) ()
markVersionedRetentionFailureStmt =
  preparable
    """
    WITH failed_run AS (
      UPDATE keiro.keiro_projection_rebuild_runs
      SET status = 'failed', failure_code = $2, failure_detail = $3,
          failed_at = now(), updated_at = now()
      WHERE run_id = $1
        AND rebuild_mode = 'versioned'
        AND status IN ('running', 'cutover')
      RETURNING group_id, run_id
    )
    UPDATE keiro.keiro_projection_rebuild_groups AS groups
    SET status = 'failed-versioned', reads_allowed = TRUE,
        writes_allowed = FALSE, failed_at = now(),
        failure_code = $2, failure_detail = $3, updated_at = now()
    FROM failed_run
    WHERE groups.group_id = failed_run.group_id
      AND groups.active_run_id = failed_run.run_id
      AND groups.status IN ('rebuilding-versioned', 'cutover-versioned')
    """
    (contrazip3 textParam textParam textParam)
    D.noResult

advanceVersionedSourceStmt :: Statement (Text, Text, Int64, Int64, Int64) Bool
advanceVersionedSourceStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_sources
    SET cursor_position = $4,
        event_count = event_count + $5,
        updated_at = now()
    WHERE run_id = $1 AND source_id = $2
      AND cursor_position = $3 AND exhausted_through IS NULL
      AND $4 >= $3 AND $4 <= target_position
    RETURNING TRUE
    """
    (contrazip5 textParam textParam int8Param int8Param int8Param)
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

advanceVersionedAdapterStmt :: Statement (Text, Text, Text, Int64, Int64) ()
advanceVersionedAdapterStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_adapters
    SET evaluation_count = evaluation_count + $4,
        apply_count = apply_count + $5,
        updated_at = now()
    WHERE run_id = $1 AND source_id = $2 AND projection_id = $3
    """
    (contrazip5 textParam textParam textParam int8Param int8Param)
    D.noResult

completeVersionedSourceStmt :: Statement (Text, Text, Int64) ()
completeVersionedSourceStmt =
  preparable
    """
    WITH completed AS (
      UPDATE keiro.keiro_projection_rebuild_sources
      SET exhausted_through = $3, updated_at = now()
      WHERE run_id = $1 AND source_id = $2
        AND target_position = $3 AND exhausted_through IS NULL
      RETURNING run_id, source_id
    )
    UPDATE keiro.keiro_projection_rebuild_adapters AS adapters
    SET completed_through = $3, updated_at = now()
    FROM completed
    WHERE adapters.run_id = completed.run_id
      AND adapters.source_id = completed.source_id
    """
    (contrazip3 textParam textParam int8Param)
    D.noResult

extendVersionedReplayHeadStmt :: Statement (Text, Text, Int64) Bool
extendVersionedReplayHeadStmt =
  preparable
    """
    WITH active_run AS (
      UPDATE keiro.keiro_projection_rebuild_runs AS runs
      SET captured_head = $3, updated_at = now()
      FROM keiro.keiro_projection_rebuild_groups AS groups
      WHERE runs.run_id = $1 AND runs.contract_fingerprint = $2
        AND runs.status = 'running'
        AND groups.group_id = runs.group_id
        AND groups.status = 'rebuilding-versioned'
        AND groups.active_run_id = runs.run_id
        AND $3 >= runs.captured_head
        AND NOT EXISTS (
          SELECT 1 FROM keiro.keiro_projection_rebuild_sources AS sources
          WHERE sources.run_id = runs.run_id
            AND sources.exhausted_through IS DISTINCT FROM sources.target_position
        )
      RETURNING runs.run_id
    ), extended AS (
      UPDATE keiro.keiro_projection_rebuild_sources AS sources
      SET target_position = $3,
          exhausted_through = CASE WHEN sources.cursor_position >= $3 THEN $3 ELSE NULL END,
          updated_at = now()
      FROM active_run
      WHERE sources.run_id = active_run.run_id
      RETURNING sources.run_id
    )
    SELECT EXISTS (SELECT 1 FROM active_run)
    """
    (contrazip3 textParam textParam int8Param)
    (D.singleRow (D.column (D.nonNullable D.bool)))

enterVersionedCutoverStmt :: Statement (Text, Text) Bool
enterVersionedCutoverStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups AS groups
    SET status = 'cutover-versioned', writes_allowed = FALSE, updated_at = now()
    FROM keiro.keiro_projection_rebuild_runs AS runs
    WHERE runs.run_id = $1 AND runs.contract_fingerprint = $2
      AND runs.status = 'running'
      AND groups.group_id = runs.group_id
      AND groups.status = 'rebuilding-versioned'
      AND groups.active_run_id = runs.run_id
      AND NOT EXISTS (
        SELECT 1 FROM keiro.keiro_projection_rebuild_sources AS sources
        WHERE sources.run_id = runs.run_id
          AND sources.exhausted_through IS DISTINCT FROM sources.target_position
      )
    RETURNING TRUE
    """
    (contrazip2 textParam textParam)
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

captureVersionedCutoverHeadStmt :: Statement (Text, Text, Int64) Bool
captureVersionedCutoverHeadStmt =
  preparable
    """
    WITH cutover_run AS (
      UPDATE keiro.keiro_projection_rebuild_runs AS runs
      SET status = 'cutover', captured_head = $3, updated_at = now()
      FROM keiro.keiro_projection_rebuild_groups AS groups
      WHERE runs.run_id = $1 AND runs.contract_fingerprint = $2
        AND runs.status = 'running'
        AND groups.group_id = runs.group_id
        AND groups.status = 'cutover-versioned'
        AND groups.active_run_id = runs.run_id
        AND $3 >= runs.captured_head
      RETURNING runs.run_id
    ), retargeted AS (
      UPDATE keiro.keiro_projection_rebuild_sources AS sources
      SET target_position = $3,
          exhausted_through = CASE WHEN sources.cursor_position >= $3 THEN $3 ELSE NULL END,
          updated_at = now()
      FROM cutover_run
      WHERE sources.run_id = cutover_run.run_id
      RETURNING sources.run_id
    )
    SELECT EXISTS (SELECT 1 FROM cutover_run)
    """
    (contrazip3 textParam textParam int8Param)
    (D.singleRow (D.column (D.nonNullable D.bool)))

lockActiveVersionedPromotionStmt :: Statement (Text, Text) Bool
lockActiveVersionedPromotionStmt =
  preparable
    """
    SELECT runs.run_id
    FROM keiro.keiro_projection_rebuild_runs AS runs
    JOIN keiro.keiro_projection_rebuild_groups AS groups
      ON groups.group_id = runs.group_id
    WHERE runs.run_id = $1 AND runs.contract_fingerprint = $2
      AND runs.status = 'cutover'
      AND groups.status = 'cutover-versioned'
      AND groups.active_run_id = runs.run_id
      AND NOT EXISTS (
        SELECT 1 FROM keiro.keiro_projection_rebuild_sources AS sources
        WHERE sources.run_id = runs.run_id
          AND sources.exhausted_through IS DISTINCT FROM sources.target_position
      )
    FOR UPDATE OF runs, groups
    """
    (contrazip2 textParam textParam)
    (isJust <$> D.rowMaybe (D.column (D.nonNullable D.text)))

setCutoverStatementTimeoutStmt :: Statement Text ()
setCutoverStatementTimeoutStmt =
  preparable
    "SELECT set_config('statement_timeout', $1, true)"
    textParam
    (() <$ D.singleRow (D.column (D.nonNullable D.text)))

loadPromotionObjectsStmt :: Statement Text [(Text, PromotionObjectName)]
loadPromotionObjectsStmt =
  preparable
    """
    SELECT target_id, object_kind, generation_name, canonical_name
    FROM keiro.keiro_projection_rebuild_promotion_objects
    WHERE run_id = $1
    ORDER BY target_id, object_order
    """
    textParam
    ( D.rowList
        ( (,)
            <$> D.column (D.nonNullable D.text)
            <*> ( PromotionObjectName
                    <$> (parsePromotionKind <$> D.column (D.nonNullable D.text))
                    <*> D.column (D.nonNullable D.text)
                    <*> D.column (D.nonNullable D.text)
                )
        )
    )

retireServingGenerationStmt :: Statement (UUID, Text, Text) ()
retireServingGenerationStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_target_generations
    SET lifecycle = 'retired', schema_name = $2, relation_name = $3,
        retired_at = now()
    WHERE generation_id = $1 AND lifecycle = 'serving'
    """
    (contrazip3 uuidParam textParam textParam)
    D.noResult

promoteCandidateGenerationStmt :: Statement (UUID, Text, Text) ()
promoteCandidateGenerationStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_target_generations
    SET lifecycle = 'serving', schema_name = $2, relation_name = $3,
        served_at = now()
    WHERE generation_id = $1 AND lifecycle = 'staging'
    """
    (contrazip3 uuidParam textParam textParam)
    D.noResult

markVersionedVerificationPassedStmt :: Statement (Text, Text) ()
markVersionedVerificationPassedStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_verifications
    SET status = 'passed', detail = NULL, completed_at = now()
    WHERE run_id = $1 AND verification_id = $2 AND status = 'pending'
    """
    (contrazip2 textParam textParam)
    D.noResult

markVersionedRunPromotedStmt :: Statement (Text, Maybe UTCTime) Bool
markVersionedRunPromotedStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_runs
    SET status = 'promoted', verified_at = now(), promoted_at = now(),
        history_retention_released_at = COALESCE($2, now()), updated_at = now()
    WHERE run_id = $1 AND rebuild_mode = 'versioned' AND status = 'cutover'
    RETURNING TRUE
    """
    (contrazip2 textParam nullableTimestamptzParam)
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

finishVersionedPromotionGroupStmt :: Statement (Text, Text, Text) Bool
finishVersionedPromotionGroupStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET status = 'serving-versioned', active_run_id = NULL,
        serving_revision_id = $3, serving_epoch = serving_epoch + 1,
        reads_allowed = TRUE, writes_allowed = TRUE,
        completed_at = now(), updated_at = now()
    WHERE group_id = $1 AND active_run_id = $2
      AND status = 'cutover-versioned'
    RETURNING TRUE
    """
    (contrazip3 textParam textParam textParam)
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

resolveRelationOidStmt :: Statement (Text, Text) (Maybe Int64)
resolveRelationOidStmt =
  preparable
    """
    SELECT classes.oid::bigint
    FROM pg_catalog.pg_class AS classes
    JOIN pg_catalog.pg_namespace AS namespaces
      ON namespaces.oid = classes.relnamespace
    WHERE namespaces.nspname = $1 AND classes.relname = $2
    """
    (contrazip2 textParam textParam)
    (D.rowMaybe (D.column (D.nonNullable D.int8)))

insertGenerationStmt :: Statement InsertGeneration ()
insertGenerationStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_target_generations
      (generation_id, group_id, target_id, revision_id, schema_name,
       relation_name, relation_oid, schema_version, expected_shape_id,
       observed_shape_fingerprint, observed_catalog_snapshot,
       created_by_run_id, lifecycle, served_at)
    VALUES
      ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
       CASE WHEN $13 = 'serving' THEN now() ELSE NULL END)
    """
    insertGenerationEncoder
    D.noResult

insertGenerationEncoder :: E.Params InsertGeneration
insertGenerationEncoder =
  contramap
    ( \value ->
        ( ( value ^. #generationUuid,
            value ^. #generationGroup,
            value ^. #generationTarget,
            value ^. #generationRevision,
            value ^. #generationSchema,
            value ^. #generationRelation,
            value ^. #generationOid
          ),
          ( value ^. #generationSchemaVersion,
            value ^. #generationExpectedShape,
            value ^. #generationObservedShape,
            value ^. #generationSnapshot,
            value ^. #generationRun,
            value ^. #generationLifecycle
          )
        )
    )
    ( contrazip2
        (contrazip7 uuidParam textParam textParam textParam textParam textParam int8Param)
        (contrazip6 textParam textParam textParam textParam nullableTextParam textParam)
    )

insertRunTargetStmt :: Statement (Text, Text, Text, UUID) ()
insertRunTargetStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_run_targets
      (run_id, target_id, target_mode, candidate_generation_id)
    VALUES ($1, $2, $3, $4)
    """
    (contrazip4 textParam textParam textParam uuidParam)
    D.noResult

insertPromotionObjectStmt :: Statement (Text, Text, Int32, Text, Text, Text) ()
insertPromotionObjectStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_promotion_objects
      (run_id, target_id, object_order, object_kind, generation_name, canonical_name)
    VALUES ($1, $2, $3, $4, $5, $6)
    """
    (contrazip6 textParam textParam int4Param textParam textParam textParam)
    D.noResult

loadCandidateGenerationsStmt :: Statement Text [VersionedTargetGeneration]
loadCandidateGenerationsStmt =
  preparable
    """
    SELECT generations.generation_id, generations.target_id,
           generations.revision_id, generations.schema_name,
           generations.relation_name, generations.relation_oid,
           generations.schema_version, generations.expected_shape_id,
           generations.observed_shape_fingerprint, generations.lifecycle
    FROM keiro.keiro_projection_rebuild_run_targets AS targets
    JOIN keiro.keiro_projection_target_generations AS generations
      ON generations.generation_id = targets.candidate_generation_id
    WHERE targets.run_id = $1
    ORDER BY targets.target_id
    """
    textParam
    (D.rowList generationDecoder)

loadServingGenerationsStmt :: Statement Text [VersionedTargetGeneration]
loadServingGenerationsStmt =
  preparable
    """
    SELECT generation_id, target_id, revision_id, schema_name, relation_name,
           relation_oid, schema_version, expected_shape_id,
           observed_shape_fingerprint, lifecycle
    FROM keiro.keiro_projection_target_generations
    WHERE group_id = $1 AND lifecycle = 'serving'
    ORDER BY target_id
    """
    textParam
    (D.rowList generationDecoder)

loadVersionedSourcesStmt :: Statement Text [VersionedSourceProgress]
loadVersionedSourcesStmt =
  preparable
    """
    SELECT source_id, source_scope, category, cursor_position,
           target_position, exhausted_through, event_count
    FROM keiro.keiro_projection_rebuild_sources
    WHERE run_id = $1
    ORDER BY source_id
    """
    textParam
    (D.rowList versionedSourceDecoder)

versionedSourceDecoder :: D.Row VersionedSourceProgress
versionedSourceDecoder =
  build
    <$> (parseSourceId <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
    <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
    <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
    <*> D.column (D.nonNullable D.int8)
  where
    build sourceId scope category cursorPosition targetPosition exhaustedThrough eventCount =
      VersionedSourceProgress
        { sourceId,
          sourceScope = parseSourceScope scope category,
          cursorPosition,
          targetPosition,
          exhaustedThrough,
          eventCount
        }

parseSourceId :: Text -> SourceId
parseSourceId value = either (error . show) id (Catalog.mkSourceId value)

parseSourceScope :: Text -> Maybe Text -> SourceScope
parseSourceScope "all" Nothing = AllStreams
parseSourceScope "category" (Just category) = CategorySource (CategoryName category)
parseSourceScope scope category = error ("invalid persisted versioned source scope: " <> show (scope, category))

generationDecoder :: D.Row VersionedTargetGeneration
generationDecoder =
  build
    <$> (TargetGenerationId <$> D.column (D.nonNullable D.uuid))
    <*> (parseTargetId <$> D.column (D.nonNullable D.text))
    <*> (parseRevisionId <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.int8)
    <*> (TargetSchemaVersion <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> (parseGenerationLifecycle <$> D.column (D.nonNullable D.text))
  where
    build generationId targetId revisionId schemaName tableName relationOid schemaVersion expectedShapeId observedShapeFingerprint lifecycle =
      VersionedTargetGeneration
        { generationId,
          targetId,
          revisionId,
          physicalTable = QualifiedTable schemaName tableName,
          relationOid,
          schemaVersion,
          expectedShapeId,
          observedShapeFingerprint,
          lifecycle
        }

parseTargetId :: Text -> TargetId
parseTargetId value = either (error . show) id (Catalog.mkTargetId value)

lockVersionedRunForAbandonStmt :: Statement Text (Maybe (PersistedRun, Text, Maybe Text))
lockVersionedRunForAbandonStmt =
  preparable
    """
    SELECT runs.run_id, runs.group_id, runs.catalog_fingerprint,
           runs.group_slice_fingerprint, runs.contract_fingerprint,
           runs.runner_format, runs.captured_head, runs.page_size,
           runs.status, runs.candidate_revision_id,
           runs.cutover_threshold, runs.cutover_lock_timeout_ms,
           runs.history_retention_lease_id, runs.history_retention_lease_owner,
           runs.history_retention_protected_through,
           runs.history_retention_expires_at,
           runs.history_retention_renewed_at,
           runs.history_retention_released_at,
           groups.status, groups.active_run_id
    FROM keiro.keiro_projection_rebuild_runs AS runs
    JOIN keiro.keiro_projection_rebuild_groups AS groups
      ON groups.group_id = runs.group_id
    WHERE runs.run_id = $1 AND runs.rebuild_mode = 'versioned'
    FOR UPDATE OF runs, groups
    """
    textParam
    ( D.rowMaybe
        ( (,,)
            <$> persistedRunDecoder
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
        )
    )

markGenerationsDroppedStmt :: Statement Text ()
markGenerationsDroppedStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_target_generations AS generations
    SET lifecycle = 'dropped', dropped_at = now()
    FROM keiro.keiro_projection_rebuild_run_targets AS targets
    WHERE targets.run_id = $1
      AND targets.candidate_generation_id = generations.generation_id
      AND generations.lifecycle = 'staging'
    """
    textParam
    D.noResult

markVersionedRunAbandonedStmt :: Statement (Text, Maybe UTCTime) Bool
markVersionedRunAbandonedStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_runs
    SET status = 'abandoned',
        abandoned_at = now(),
        failed_at = NULL,
        failure_code = NULL,
        failure_detail = NULL,
        failure_source_id = NULL,
        failure_projection_id = NULL,
        failure_position = NULL,
        history_retention_released_at = COALESCE($2, now()),
        updated_at = now()
    WHERE run_id = $1 AND status IN ('running', 'cutover', 'failed')
      AND rebuild_mode = 'versioned'
    RETURNING TRUE
    """
    (contrazip2 textParam nullableTimestamptzParam)
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

restoreVersionedServingGroupStmt :: Statement (Text, Text) Bool
restoreVersionedServingGroupStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET status = 'serving-versioned',
        active_run_id = NULL,
        reads_allowed = TRUE,
        writes_allowed = TRUE,
        completed_at = now(),
        updated_at = now()
    WHERE group_id = $1
      AND active_run_id = $2
      AND status IN ('rebuilding-versioned', 'cutover-versioned', 'failed-versioned')
    RETURNING TRUE
    """
    (contrazip2 textParam textParam)
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

nullableTextParam :: E.Params (Maybe Text)
nullableTextParam = E.param (E.nullable E.text)

int4Param :: E.Params Int32
int4Param = E.param (E.nonNullable E.int4)

int8Param :: E.Params Int64
int8Param = E.param (E.nonNullable E.int8)

uuidParam :: E.Params UUID
uuidParam = E.param (E.nonNullable E.uuid)

timestamptzParam :: E.Params UTCTime
timestamptzParam = E.param (E.nonNullable E.timestamptz)

nullableTimestamptzParam :: E.Params (Maybe UTCTime)
nullableTimestamptzParam = E.param (E.nullable E.timestamptz)
