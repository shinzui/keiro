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
    VersionedAbandonResult (..),
    beginVersionedRebuild,
    beginVersionedRebuildTx,
    applyVersionedReplayEvent,
    applyVersionedReplayEventTx,
    verifyVersionedCandidate,
    verifyVersionedCandidateTx,
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
    contrazip8,
  )
import Control.Monad (foldM)
import Data.ByteString qualified as ByteString
import Data.Functor (($>))
import Data.Int (Int32)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Connection (qualifyTable)
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
    targetIdText,
  )
import Keiro.Projection.Catalog qualified as Catalog
import Keiro.ReadModel.Rebuild.Group
  ( RebuildRunId,
    rebuildRunIdText,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.HistoryRetention
  ( HistoryRetentionLease (..),
    HistoryRetentionLeaseHandle (..),
    HistoryRetentionLeaseId (..),
    HistoryRetentionLeaseRequest,
    HistoryRetentionReleaseResult (..),
    acquireHistoryRetentionLeaseTx,
    historyRetentionLeaseOwnerText,
    mkHistoryRetentionLeaseOwner,
    releaseHistoryRetentionLeaseTx,
  )
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx

data VersionedTargetMode
  = ApplicationProvisioned
  | RestrictedClone
  deriving stock (Eq, Ord, Show, Generic)

data VersionedRebuildRequest = VersionedRebuildRequest
  { rebuildRunId :: !RebuildRunId,
    rebuildGroupId :: !RebuildGroupId,
    servingRevisionId :: !ProjectionRevisionId,
    candidateRevisionId :: !ProjectionRevisionId,
    servingTargets :: !PhysicalTargets,
    targetMode :: !VersionedTargetMode,
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
  | VersionedRetentionReleaseFailed !RebuildRunId !Text
  | VersionedReplayDecodeFailed !RebuildRunId !Text !ReplayDecodeError
  | VersionedCandidateVerificationFailed !RebuildRunId !Text !Text
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
    candidateText :: !Text,
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
                Just run -> resumeExisting request group run
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

candidateExecutionContext ::
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  Tx.Transaction (Either VersionedRebuildError (ProjectionRevision, PhysicalTargets))
candidateExecutionContext catalog runId = do
  persisted <- Tx.statement (rebuildRunIdText runId) lookupVersionedRunStmt
  case persisted of
    Nothing -> pure (Left (VersionedRunIdentityConflict runId "versioned run does not exist"))
    Just run
      | run ^. #persistedRunStatus /= "running" ->
          pure
            ( Left
                ( VersionedPersistedLifecycleInvalid
                    runId
                    ("candidate execution requires running, found " <> run ^. #persistedRunStatus)
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
                else pure $
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
      | run ^. #persistedRunStatus /= "running"
          || groupStatus /= "rebuilding-versioned"
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
  PersistedGroup ->
  PersistedRun ->
  Tx.Transaction (Either VersionedRebuildError VersionedRebuildHandle)
resumeExisting request group run
  | run ^. #persistedGroupId /= rebuildGroupIdText (request ^. #rebuildGroupId) = conflict "group differs"
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
            candidateText = projectionRevisionIdText (request ^. #candidateRevisionId),
            thresholdValue = request ^. #cutoverThreshold,
            timeoutValue = request ^. #cutoverLockTimeoutMs,
            leaseUuid = leaseId,
            leaseOwnerText = historyRetentionLeaseOwnerText (lease ^. #owner),
            protectedPosition = protected,
            leaseExpiry = lease ^. #expiresAt,
            leaseRenewal = lease ^. #renewedAt
          }
        insertVersionedRunStmt

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
      ($1, $2, $3, $4, 'versioned-contract-v1:' || $4,
       'keiro/versioned-rebuild/v1', $10, 500, 'running', 'versioned',
       $5, $6, $7, $8, $9, $10, $11, $12)
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
            value ^. #candidateText,
            value ^. #thresholdValue,
            value ^. #timeoutValue,
            value ^. #leaseUuid
          ),
          ( value ^. #leaseOwnerText,
            value ^. #protectedPosition,
            value ^. #leaseExpiry,
            value ^. #leaseRenewal
          )
        )
    )
    ( contrazip2
        ( contrazip8
            textParam
            textParam
            textParam
            textParam
            textParam
            int8Param
            int8Param
            uuidParam
        )
        (contrazip4 textParam int8Param timestamptzParam timestamptzParam)
    )

lookupVersionedRunStmt :: Statement Text (Maybe PersistedRun)
lookupVersionedRunStmt =
  preparable
    """
    SELECT run_id, group_id, status, candidate_revision_id,
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
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

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
    SELECT runs.run_id, runs.group_id, runs.status, runs.candidate_revision_id,
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
        history_retention_released_at = COALESCE($2, now()),
        updated_at = now()
    WHERE run_id = $1 AND status = 'running' AND rebuild_mode = 'versioned'
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
      AND status = 'rebuilding-versioned'
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
