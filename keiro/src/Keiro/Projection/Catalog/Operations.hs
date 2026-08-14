-- | Operator-neutral inventory and rebuild actions derived from one validated
-- projection catalog. This module deliberately contains no command parser,
-- renderer, confirmation policy, or database connection details.
module Keiro.Projection.Catalog.Operations
  ( ProjectionCatalogOperations,
    projectionCatalogOperations,
    CatalogInventoryReport (..),
    RebuildPreview (..),
    RegisteredRebuildPreview (..),
    CatalogAdoptionGroupPreview (..),
    CatalogAdoptionRegistrationPreview (..),
    CatalogAdoptionOrphanPreview (..),
    CatalogAdoptionReport (..),
    CatalogAdoptionOutcome (..),
    CatalogRunReport (..),
    CatalogVersionedStartOptions (..),
    CatalogVersionedRunReport (..),
    CatalogRetiredGenerationsReport (..),
    CatalogRetiredDropReport (..),
    CatalogExternalReadRetirementReport (..),
    CatalogStreamReprojectionPreview (..),
    CatalogStreamReprojectionReport (..),
    CatalogOpsError (..),
    catalogInventoryReport,
    previewGroupRebuild,
    previewRegisteredGroupRebuild,
    previewCatalogAdoption,
    adoptCatalogGroups,
    startGroupRebuild,
    inspectGroupRebuild,
    resumeGroupRebuild,
    abandonGroupRebuild,
    startVersionedGroupRebuild,
    inspectVersionedGroupRebuild,
    resumeVersionedGroupRebuild,
    abandonVersionedGroupRebuild,
    listRetiredGenerations,
    previewRetiredGenerationDrop,
    dropRetiredGeneration,
    inspectExternalReadContract,
    retireExternalReadContract,
    previewStreamReprojection,
    reprojectCatalogStream,
  )
where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Int (Int32)
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (DiffTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Keiro.Prelude
import Keiro.Projection.Catalog
import Keiro.ReadModel (HeadScope (..))
import Keiro.ReadModel.External qualified as External
import Keiro.ReadModel.Rebuild
  ( CatalogAdoptionError (..),
    CatalogRebuildError,
    GroupAdoptionClass (..),
    GroupLifecycleStatus (..),
    GroupRebuildMetadata,
    OrphanedRegistration (..),
    RebuildAdapterProgress,
    RebuildFailure,
    RebuildFailureEvidence,
    RebuildOptions,
    RebuildRunId,
    RebuildRunReport,
    RebuildRunStatus (..),
    RebuildSourceProgress,
    RebuildVerificationProgress,
    RegistrationAdoption (..),
    RegistrationAdoptionAction (..),
    StreamReprojectionError (..),
    StreamReprojectionReport,
    StreamReprojectionRequest (..),
    VersionedRebuildError,
    VersionedRebuildReport,
    VersionedRebuildRequest (..),
    VersionedRetiredDropResult,
    VersionedRetiredGenerationPreview,
    VersionedTargetGeneration,
    VersionedTargetMode,
    abandonCatalogRebuild,
    abandonVersionedRebuild,
    beginVersionedRebuild,
    dropVersionedRetiredGeneration,
    inspectCatalogRebuild,
    inspectVersionedRebuild,
    listVersionedRetiredGenerations,
    lookupProjectionGroupStatus,
    lookupProjectionRebuildGroup,
    preCanonicalRunSliceSentinel,
    previewVersionedRetiredDrop,
    rebuildRunIdText,
    reprojectStream,
    resumeCatalogRebuild,
    resumeVersionedRebuild,
    startCatalogRebuild,
  )
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Keiro.ReadModel.Rebuild.Stream (validateStreamReprojectionAdmission)
import Kiroku.Store qualified as Kiroku
import Kiroku.Store.Effect (Store)
import Kiroku.Store.HistoryRetention
  ( HistoryRetentionLeaseRequest (..),
    mkHistoryRetentionLeaseDuration,
    mkHistoryRetentionLeaseOwner,
    mkHistoryRetentionLeaseReason,
  )
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), StreamName (..), StreamVersion (..))

newtype ProjectionCatalogOperations = ProjectionCatalogOperations ValidatedProjectionCatalog
  deriving stock (Generic)

projectionCatalogOperations :: ValidatedProjectionCatalog -> ProjectionCatalogOperations
projectionCatalogOperations = ProjectionCatalogOperations

-- | Stable, JSON-friendly envelope for the complete heterogeneous inventory.
data CatalogInventoryReport = CatalogInventoryReport
  { reportSchema :: !Text,
    catalogFingerprint :: !Text,
    groupSlices :: ![(RebuildGroupId, Text)],
    inventory :: !CatalogInventory
  }
  deriving stock (Eq, Show, Generic)

-- | A pure, non-mutating description of one group rebuild. Every list is
-- selected from the validated catalog; no caller-supplied reset or handler list
-- can enter the report.
data RebuildPreview = RebuildPreview
  { reportSchema :: !Text,
    rebuildGroupId :: !RebuildGroupId,
    catalogFingerprint :: !Text,
    sliceFingerprint :: !Text,
    targets :: ![InventoryTarget],
    sources :: ![InventorySource],
    projections :: ![InventoryProjection],
    queryModels :: ![InventoryQueryModel],
    subscriptionResets :: ![InventorySubscription],
    dedupResets :: ![InventoryDedupKey],
    verifications :: ![(Text, Text)],
    lockScope :: ![RebuildGroupId],
    capturedHeadStrategy :: !Text,
    destructive :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | The pure preview plus an optional read-only lifecycle observation. A
-- missing row means the validated group has not been registered yet.
data RegisteredRebuildPreview = RegisteredRebuildPreview
  { reportSchema :: !Text,
    preview :: !RebuildPreview,
    registeredState :: !(Maybe GroupRebuildMetadata),
    registeredSliceMatches :: !(Maybe Bool)
  }
  deriving stock (Eq, Show, Generic)

data CatalogAdoptionGroupPreview = CatalogAdoptionGroupPreview
  { rebuildGroupId :: !RebuildGroupId,
    classification :: !GroupAdoptionClass,
    storedSlice :: !(Maybe Text),
    currentSlice :: !Text,
    inScope :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data CatalogAdoptionRegistrationPreview = CatalogAdoptionRegistrationPreview
  { registryName :: !Text,
    rebuildGroupId :: !RebuildGroupId,
    action :: !RegistrationAdoptionAction,
    inScope :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data CatalogAdoptionOrphanPreview = CatalogAdoptionOrphanPreview
  { registryName :: !Text,
    boundGroupId :: !RebuildGroupId,
    inScope :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data CatalogAdoptionReport = CatalogAdoptionReport
  { reportSchema :: !Text,
    catalogFingerprint :: !Text,
    requestedGroups :: ![RebuildGroupId],
    groups :: ![CatalogAdoptionGroupPreview],
    registrations :: ![CatalogAdoptionRegistrationPreview],
    orphanedRegistrations :: ![CatalogAdoptionOrphanPreview],
    removedGroups :: ![RebuildGroupId],
    outOfScopeChangedGroups :: ![RebuildGroupId]
  }
  deriving stock (Eq, Show, Generic)

data CatalogAdoptionOutcome = CatalogAdoptionOutcome
  { reportSchema :: !Text,
    adoptedGroups :: ![GroupRebuildMetadata],
    registrationOutcomes :: ![RegistrationAdoption],
    removedOrphans :: ![OrphanedRegistration]
  }
  deriving stock (Eq, Show, Generic)

-- | Versioned operations envelope around the runtime runner's structured
-- progress report.
data CatalogRunReport = CatalogRunReport
  { reportSchema :: !Text,
    run :: !RebuildRunReport
  }
  deriving stock (Eq, Show, Generic)

data CatalogVersionedStartOptions = CatalogVersionedStartOptions
  { rebuildRunId :: !RebuildRunId,
    rebuildGroupId :: !RebuildGroupId,
    servingRevisionId :: !ProjectionRevisionId,
    candidateRevisionId :: !ProjectionRevisionId,
    targetMode :: !VersionedTargetMode,
    replayPageSize :: !Int32,
    cutoverThreshold :: !Int64,
    cutoverLockTimeoutMs :: !Int64,
    retentionDuration :: !DiffTime,
    requestedBy :: !Text,
    requestReason :: !Text
  }
  deriving stock (Eq, Show, Generic)

data CatalogVersionedRunReport = CatalogVersionedRunReport
  { reportSchema :: !Text,
    run :: !VersionedRebuildReport
  }
  deriving stock (Eq, Show, Generic)

data CatalogRetiredGenerationsReport = CatalogRetiredGenerationsReport
  { reportSchema :: !Text,
    generations :: ![VersionedTargetGeneration]
  }
  deriving stock (Eq, Show, Generic)

data CatalogRetiredDropReport
  = CatalogRetiredDropPreview !VersionedRetiredGenerationPreview
  | CatalogRetiredDropOutcome !VersionedRetiredDropResult
  deriving stock (Eq, Show, Generic)

data CatalogExternalReadRetirementReport = CatalogExternalReadRetirementReport
  { reportSchema :: !Text,
    contractId :: !ExternalReadContractId,
    contractVersion :: !ExternalReadContractVersion,
    publicFunction :: !Text,
    currentState :: !Text,
    surfaceGeneration :: !Int,
    dependentObjects :: ![Text],
    executeGrants :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

data CatalogStreamReprojectionPreview = CatalogStreamReprojectionPreview
  { reportSchema :: !Text,
    rebuildGroupId :: !RebuildGroupId,
    projectionId :: !ProjectionId,
    streamName :: !StreamName,
    servingRevisionId :: !ProjectionRevisionId,
    targets :: ![InventoryTarget],
    affectedDedup :: ![InventoryDedupKey],
    streamVersion :: !(Maybe StreamVersion),
    softDeleted :: !Bool,
    truncateBefore :: !(Maybe StreamVersion),
    eligible :: !Bool,
    refusal :: !(Maybe Text),
    forceOperation :: !Text
  }
  deriving stock (Eq, Show, Generic)

data CatalogStreamReprojectionReport = CatalogStreamReprojectionReport
  { reportSchema :: !Text,
    repair :: !StreamReprojectionReport
  }
  deriving stock (Eq, Show, Generic)

data CatalogOpsError
  = CatalogOpsUnknownGroup !RebuildGroupId
  | CatalogOpsRunSliceMismatch !RebuildRunId !Text !Text
  | CatalogOpsAdoptionRefused !CatalogAdoptionError
  | CatalogOpsRebuildError !CatalogRebuildError
  | CatalogOpsVersionedError !VersionedRebuildError
  | CatalogOpsExternalReadRetirementError !External.ExternalReadRetirementError
  | CatalogOpsStreamReprojectionError !StreamReprojectionError
  | CatalogOpsInvalidVersionedRequest !Text
  deriving stock (Eq, Show, Generic)

catalogInventoryReport :: ProjectionCatalogOperations -> CatalogInventoryReport
catalogInventoryReport (ProjectionCatalogOperations catalog) =
  CatalogInventoryReport
    { reportSchema = "keiro/catalog-inventory/v2",
      catalogFingerprint = catalogFingerprintText (Keiro.Projection.Catalog.catalogFingerprint catalog),
      groupSlices =
        [ (groupId, sliceFor groupId)
        | groupId <- (^. #rebuildGroupId) <$> (catalogInventory catalog ^. #inventoryGroups)
        ],
      inventory = catalogInventory catalog
    }
  where
    sliceFor groupId =
      maybe
        (error "catalogInventoryReport: inventory group has no slice")
        groupSliceFingerprintText
        (Keiro.Projection.Catalog.groupSliceFingerprint catalog groupId)

previewGroupRebuild ::
  ProjectionCatalogOperations ->
  RebuildGroupId ->
  Either CatalogOpsError RebuildPreview
previewGroupRebuild (ProjectionCatalogOperations catalog) wantedGroup = do
  group <-
    maybe
      (Left (CatalogOpsUnknownGroup wantedGroup))
      Right
      (List.find ((== wantedGroup) . (^. #rebuildGroupId)) groups)
  pure
    RebuildPreview
      { reportSchema = "keiro/catalog-rebuild-preview/v2",
        rebuildGroupId = wantedGroup,
        catalogFingerprint = catalogFingerprintText (Keiro.Projection.Catalog.catalogFingerprint catalog),
        sliceFingerprint =
          maybe
            (error "previewGroupRebuild: inventory group has no slice")
            groupSliceFingerprintText
            (Keiro.Projection.Catalog.groupSliceFingerprint catalog wantedGroup),
        targets = groupTargets,
        sources = groupSources,
        projections = groupProjections,
        queryModels = filter ((== wantedGroup) . (^. #rebuildGroupId)) (inventory ^. #inventoryQueryModels),
        subscriptionResets = groupSubscriptions,
        dedupResets = groupDedupKeys,
        verifications = group ^. #verifications,
        lockScope = [wantedGroup],
        capturedHeadStrategy = "capture one immutable store head after acquiring the group fence",
        destructive = any ((== ClearBeforeReplay) . (^. #resetPolicy)) groupTargets
      }
  where
    inventory = catalogInventory catalog
    groups = inventory ^. #inventoryGroups
    groupTargets =
      mapMaybe
        (\targetId -> List.find ((== targetId) . (^. #targetId)) (inventory ^. #inventoryTargets))
        (maybe [] (^. #orderedTargets) (List.find ((== wantedGroup) . (^. #rebuildGroupId)) groups))
    groupProjections = filter ((== wantedGroup) . (^. #rebuildGroupId)) (inventory ^. #inventoryProjections)
    wantedSourceIds = List.nub (map (^. #sourceId) groupProjections)
    groupSources = filter ((`elem` wantedSourceIds) . (^. #sourceId)) (inventory ^. #inventorySources)
    asyncIdentities =
      [ (subscriptionId, dedupKeyId)
      | projection <- groupProjections,
        InventoryAsyncHandler _ subscriptionId dedupKeyId <- projection ^. #handlers
      ]
    wantedSubscriptionIds = List.nub (map fst asyncIdentities)
    wantedDedupIds = List.nub (map snd asyncIdentities)
    groupSubscriptions = filter ((`elem` wantedSubscriptionIds) . (^. #subscriptionId)) (inventory ^. #inventorySubscriptions)
    groupDedupKeys = filter ((`elem` wantedDedupIds) . (^. #dedupKeyId)) (inventory ^. #inventoryDedupKeys)

previewRegisteredGroupRebuild ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  RebuildGroupId ->
  Eff es (Either CatalogOpsError RegisteredRebuildPreview)
previewRegisteredGroupRebuild operations wantedGroup =
  case previewGroupRebuild operations wantedGroup of
    Left err -> pure (Left err)
    Right purePreview -> do
      state <- lookupProjectionRebuildGroup wantedGroup
      let expectedSlice = purePreview ^. #sliceFingerprint
      pure
        ( Right
            RegisteredRebuildPreview
              { reportSchema = "keiro/catalog-registered-rebuild-preview/v1",
                preview = purePreview,
                registeredState = state,
                registeredSliceMatches = ((== expectedSlice) . (^. #sliceFingerprint)) <$> state
              }
        )

previewCatalogAdoption ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  NonEmpty RebuildGroupId ->
  Eff es (Either CatalogOpsError CatalogAdoptionReport)
previewCatalogAdoption (ProjectionCatalogOperations catalog) wantedGroups =
  case List.find (`Set.notMember` catalogGroupIds) requested of
    Just groupId -> pure (Left (CatalogOpsAdoptionRefused (AdoptGroupNotInCatalog groupId)))
    Nothing -> do
      plan <- Rebuild.previewCatalogAdoption catalog
      pure
        ( Right
            CatalogAdoptionReport
              { reportSchema = "keiro/catalog-adoption-preview/v2",
                catalogFingerprint = catalogFingerprintText (Keiro.Projection.Catalog.catalogFingerprint catalog),
                requestedGroups = requested,
                groups = map (groupPreview catalog requestedSet) (plan ^. #groupStates),
                registrations = map (registrationPreview requestedSet) (plan ^. #registrations),
                orphanedRegistrations = map (orphanPreview requestedSet) (plan ^. #orphanedRegistrations),
                removedGroups = plan ^. #removedGroups,
                outOfScopeChangedGroups =
                  [ groupId
                  | (groupId, adoptionClass) <- plan ^. #groupStates,
                    changedAdoptionClass adoptionClass,
                    Set.notMember groupId requestedSet
                  ]
              }
        )
  where
    requested = List.sort (Set.toList requestedSet)
    requestedSet = Set.fromList (NonEmpty.toList wantedGroups)
    catalogGroupIds =
      Set.fromList
        (map (^. #rebuildGroupId) (catalogInventory catalog ^. #inventoryGroups))

adoptCatalogGroups ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  NonEmpty RebuildGroupId ->
  Eff es (Either CatalogOpsError CatalogAdoptionOutcome)
adoptCatalogGroups (ProjectionCatalogOperations catalog) groups =
  Rebuild.adoptCatalogGroups catalog groups <&> \case
    Left err -> Left (CatalogOpsAdoptionRefused err)
    Right result ->
      Right
        CatalogAdoptionOutcome
          { reportSchema = "keiro/catalog-adoption-outcome/v2",
            adoptedGroups = result ^. #adoptedGroups,
            registrationOutcomes = result ^. #registrationOutcomes,
            removedOrphans = result ^. #removedOrphans
          }

startGroupRebuild ::
  (IOE :> es, Store :> es) =>
  ProjectionCatalogOperations ->
  RebuildGroupId ->
  RebuildOptions ->
  Eff es (Either CatalogOpsError CatalogRunReport)
startGroupRebuild operations@(ProjectionCatalogOperations catalog) groupId options =
  case previewGroupRebuild operations groupId of
    Left err -> pure (Left err)
    Right _ -> wrapRun <$> startCatalogRebuild catalog groupId options

inspectGroupRebuild ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  RebuildRunId ->
  Eff es (Either CatalogOpsError CatalogRunReport)
inspectGroupRebuild (ProjectionCatalogOperations catalog) runId =
  inspectCatalogRebuild runId <&> \case
    Left err -> Left (CatalogOpsRebuildError err)
    Right report
      | report ^. #groupSliceFingerprint == preCanonicalRunSliceSentinel ->
          Right (catalogRunReport report)
      | otherwise ->
          case Keiro.Projection.Catalog.groupSliceFingerprint catalog (report ^. #rebuildGroupId) of
            Nothing -> Left (CatalogOpsUnknownGroup (report ^. #rebuildGroupId))
            Just currentSlice ->
              let expected = groupSliceFingerprintText currentSlice
                  actual = report ^. #groupSliceFingerprint
               in if actual == expected
                    then Right (catalogRunReport report)
                    else Left (CatalogOpsRunSliceMismatch runId expected actual)

resumeGroupRebuild ::
  (IOE :> es, Store :> es) =>
  ProjectionCatalogOperations ->
  RebuildRunId ->
  RebuildOptions ->
  Eff es (Either CatalogOpsError CatalogRunReport)
resumeGroupRebuild (ProjectionCatalogOperations catalog) runId options =
  wrapRun <$> resumeCatalogRebuild catalog runId options

abandonGroupRebuild ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  RebuildRunId ->
  RebuildFailure ->
  Eff es (Either CatalogOpsError CatalogRunReport)
abandonGroupRebuild (ProjectionCatalogOperations catalog) runId failure =
  wrapRun <$> abandonCatalogRebuild catalog runId failure

startVersionedGroupRebuild ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  CatalogVersionedStartOptions ->
  Eff es (Either CatalogOpsError CatalogVersionedRunReport)
startVersionedGroupRebuild operations@(ProjectionCatalogOperations catalog) options =
  case versionedRequestFor operations options of
    Left err -> pure (Left err)
    Right request ->
      beginVersionedRebuild catalog request >>= \case
        Left err -> pure (Left (CatalogOpsVersionedError err))
        Right _ -> inspectVersionedGroupRebuild operations (options ^. #rebuildRunId)

inspectVersionedGroupRebuild ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  RebuildRunId ->
  Eff es (Either CatalogOpsError CatalogVersionedRunReport)
inspectVersionedGroupRebuild (ProjectionCatalogOperations _) runId =
  inspectVersionedRebuild runId <&> mapVersionedRun

resumeVersionedGroupRebuild ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  RebuildRunId ->
  Eff es (Either CatalogOpsError CatalogVersionedRunReport)
resumeVersionedGroupRebuild (ProjectionCatalogOperations catalog) runId =
  resumeVersionedRebuild catalog runId <&> mapVersionedRun

abandonVersionedGroupRebuild ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  RebuildRunId ->
  Eff es (Either CatalogOpsError CatalogVersionedRunReport)
abandonVersionedGroupRebuild operations runId =
  abandonVersionedRebuild runId >>= \case
    Left err -> pure (Left (CatalogOpsVersionedError err))
    Right _ -> inspectVersionedGroupRebuild operations runId

listRetiredGenerations ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  Eff es CatalogRetiredGenerationsReport
listRetiredGenerations _ =
  CatalogRetiredGenerationsReport "keiro/catalog-retired-generations/v1"
    <$> listVersionedRetiredGenerations

previewRetiredGenerationDrop ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  TargetGenerationId ->
  Eff es (Either CatalogOpsError CatalogRetiredDropReport)
previewRetiredGenerationDrop (ProjectionCatalogOperations catalog) generationId =
  previewVersionedRetiredDrop catalog generationId
    <&> first CatalogOpsVersionedError
    <&> fmap CatalogRetiredDropPreview

dropRetiredGeneration ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  TargetGenerationId ->
  Eff es (Either CatalogOpsError CatalogRetiredDropReport)
dropRetiredGeneration (ProjectionCatalogOperations catalog) generationId =
  dropVersionedRetiredGeneration catalog generationId
    <&> first CatalogOpsVersionedError
    <&> fmap CatalogRetiredDropOutcome

inspectExternalReadContract ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  ExternalReadContractId ->
  ExternalReadContractVersion ->
  Eff es (Either CatalogOpsError CatalogExternalReadRetirementReport)
inspectExternalReadContract _ contractId contractVersion =
  External.previewExternalReadContractRetirement contractId contractVersion
    <&> first CatalogOpsExternalReadRetirementError
    <&> fmap (externalReadRetirementReport "keiro/catalog-external-read-inspection/v1")

retireExternalReadContract ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  ExternalReadContractId ->
  ExternalReadContractVersion ->
  Eff es (Either CatalogOpsError CatalogExternalReadRetirementReport)
retireExternalReadContract _ contractId contractVersion =
  External.retireExternalReadContract contractId contractVersion
    <&> first CatalogOpsExternalReadRetirementError
    <&> fmap (externalReadRetirementReport "keiro/catalog-external-read-retirement/v1")

previewStreamReprojection ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  StreamReprojectionRequest ->
  Eff es (Either CatalogOpsError CatalogStreamReprojectionPreview)
previewStreamReprojection (ProjectionCatalogOperations catalog) request =
  if request ^. #pageSize <= 0
    then
      pure
        ( Left
            ( CatalogOpsStreamReprojectionError
                (StreamReprojectionInvalidPageSize (request ^. #pageSize))
            )
        )
    else do
      metadata <- lookupProjectionRebuildGroup (request ^. #rebuildGroupId)
      status <- lookupProjectionGroupStatus (request ^. #rebuildGroupId)
      case status >>= (^. #servingRevisionId) of
        Nothing ->
          pure
            ( Left
                ( CatalogOpsStreamReprojectionError
                    ( case status of
                        Nothing -> StreamReprojectionGroupUnregistered (request ^. #rebuildGroupId)
                        Just observed ->
                          StreamReprojectionGroupUnavailable
                            (request ^. #rebuildGroupId)
                            (observed ^. #lifecyclePhase)
                            (observed ^. #readsAllowed)
                            (observed ^. #writesAllowed)
                    )
                )
            )
        Just revisionId ->
          case catalogProjectionRevision catalog revisionId of
            Nothing ->
              pure
                ( Left
                    ( CatalogOpsStreamReprojectionError
                        (StreamReprojectionServingRevisionUnavailable (request ^. #rebuildGroupId) revisionId)
                    )
                )
            Just _ ->
              case validateStreamReprojectionAdmission catalog request of
                Left err -> pure (Left (CatalogOpsStreamReprojectionError err))
                Right () ->
                  case catalogStreamScopedReplay catalog revisionId (request ^. #projectionId) of
                    Nothing ->
                      pure
                        ( Left
                            ( CatalogOpsStreamReprojectionError
                                (StreamReprojectionPolicyUnavailable revisionId (request ^. #projectionId))
                            )
                        )
                    Just policy -> do
                      streamInfo <- Kiroku.getStream (request ^. #streamName)
                      let inventory = catalogInventory catalog
                          wantedTargets = Set.fromList (NonEmpty.toList (policy ^. #streamOwnedTargets))
                          wantedDedup = Set.fromList (policy ^. #affectedAsyncDedup)
                          targets =
                            filter
                              ((`Set.member` wantedTargets) . (^. #targetId))
                              (inventory ^. #inventoryTargets)
                          dedup =
                            filter
                              ((`Set.member` wantedDedup) . (^. #dedupKeyId))
                              (inventory ^. #inventoryDedupKeys)
                          refusal = previewRefusal metadata status streamInfo
                      pure
                        ( Right
                            CatalogStreamReprojectionPreview
                              { reportSchema = "keiro/catalog-stream-reprojection-preview/v1",
                                rebuildGroupId = request ^. #rebuildGroupId,
                                projectionId = request ^. #projectionId,
                                streamName = request ^. #streamName,
                                servingRevisionId = revisionId,
                                targets,
                                affectedDedup = dedup,
                                streamVersion = (^. #version) <$> streamInfo,
                                softDeleted = maybe False (isJust . (^. #deletedAt)) streamInfo,
                                truncateBefore = (^. #truncateBefore) <$> streamInfo,
                                eligible = isNothing refusal,
                                refusal,
                                forceOperation =
                                  "rebuild reproject-stream "
                                    <> rebuildGroupIdText (request ^. #rebuildGroupId)
                                    <> " "
                                    <> projectionIdText (request ^. #projectionId)
                                    <> " "
                                    <> streamNameText (request ^. #streamName)
                                    <> " --force"
                              }
                        )
  where
    previewRefusal maybeMetadata maybeStatus streamInfo =
      case maybeStatus of
        Just observed
          | isJust (observed ^. #activeRunId) -> Just "active-rebuild"
          | not (sliceMatches maybeMetadata) -> Just "slice-drift"
          | observed ^. #lifecyclePhase /= "serving-versioned"
              || not (observed ^. #readsAllowed)
              || not (observed ^. #writesAllowed) ->
              Just "group-unavailable"
        _ -> case streamInfo of
          Nothing -> Just "stream-missing"
          Just info
            | isJust (info ^. #deletedAt) -> Just "stream-soft-deleted"
            | info ^. #truncateBefore > StreamVersion 0 -> Just "stream-truncated"
            | otherwise -> Nothing

    sliceMatches maybeMetadata =
      case (maybeMetadata, groupSliceFingerprint catalog (request ^. #rebuildGroupId)) of
        (Just registered, Just current) ->
          registered ^. #sliceFingerprint == groupSliceFingerprintText current
        _ -> False

    streamNameText (StreamName value) = value

reprojectCatalogStream ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  StreamReprojectionRequest ->
  Eff es (Either CatalogOpsError CatalogStreamReprojectionReport)
reprojectCatalogStream (ProjectionCatalogOperations catalog) request =
  reprojectStream catalog request
    <&> first CatalogOpsStreamReprojectionError
    <&> fmap (CatalogStreamReprojectionReport "keiro/catalog-stream-reprojection-outcome/v1")

externalReadRetirementReport :: Text -> External.ExternalReadRetirementPreview -> CatalogExternalReadRetirementReport
externalReadRetirementReport reportSchema retirement =
  CatalogExternalReadRetirementReport
    { reportSchema,
      contractId = retirement ^. #contractId,
      contractVersion = retirement ^. #contractVersion,
      publicFunction = retirement ^. #publicFunction,
      currentState = retirement ^. #currentState,
      surfaceGeneration = retirement ^. #surfaceGeneration,
      dependentObjects = retirement ^. #dependentObjects,
      executeGrants = retirement ^. #executeGrants
    }

mapVersionedRun ::
  Either VersionedRebuildError VersionedRebuildReport ->
  Either CatalogOpsError CatalogVersionedRunReport
mapVersionedRun =
  first CatalogOpsVersionedError
    . fmap (CatalogVersionedRunReport "keiro/catalog-versioned-rebuild-run/v1")

versionedRequestFor ::
  ProjectionCatalogOperations ->
  CatalogVersionedStartOptions ->
  Either CatalogOpsError VersionedRebuildRequest
versionedRequestFor (ProjectionCatalogOperations catalog) options = do
  servingRevision <-
    maybe
      (Left (CatalogOpsInvalidVersionedRequest "serving revision is absent from the catalog"))
      Right
      (catalogProjectionRevision catalog (options ^. #servingRevisionId))
  let inventoryTargets = catalogInventory catalog ^. #inventoryTargets
      bindings =
        Map.fromList
          [ (target ^. #targetId, target ^. #qualifiedTable)
          | target <- inventoryTargets
          ]
  servingTargets <-
    first (CatalogOpsInvalidVersionedRequest . Text.pack . show) $
      mkPhysicalTargets
        (Map.keys (servingRevision ^. #targetProvisioners))
        bindings
  owner <-
    first (CatalogOpsInvalidVersionedRequest . Text.pack . show) $
      mkHistoryRetentionLeaseOwner
        ("keiro-rebuild/" <> rebuildRunIdText (options ^. #rebuildRunId))
  reason <-
    first (CatalogOpsInvalidVersionedRequest . Text.pack . show) $
      mkHistoryRetentionLeaseReason (options ^. #requestReason)
  duration <-
    first (CatalogOpsInvalidVersionedRequest . Text.pack . show) $
      mkHistoryRetentionLeaseDuration (options ^. #retentionDuration)
  pure
    VersionedRebuildRequest
      { rebuildRunId = options ^. #rebuildRunId,
        rebuildGroupId = options ^. #rebuildGroupId,
        servingRevisionId = options ^. #servingRevisionId,
        candidateRevisionId = options ^. #candidateRevisionId,
        servingTargets,
        targetMode = options ^. #targetMode,
        replayPageSize = options ^. #replayPageSize,
        cutoverThreshold = options ^. #cutoverThreshold,
        cutoverLockTimeoutMs = options ^. #cutoverLockTimeoutMs,
        retentionLeaseRequest = HistoryRetentionLeaseRequest owner reason duration,
        requestedBy = options ^. #requestedBy,
        requestReason = options ^. #requestReason
      }

wrapRun :: Either CatalogRebuildError RebuildRunReport -> Either CatalogOpsError CatalogRunReport
wrapRun = \case
  Left err -> Left (CatalogOpsRebuildError err)
  Right report -> Right (catalogRunReport report)

catalogRunReport :: RebuildRunReport -> CatalogRunReport
catalogRunReport report =
  CatalogRunReport
    { reportSchema = "keiro/catalog-rebuild-run/v1",
      run = report
    }

instance Aeson.ToJSON CatalogInventoryReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "catalogFingerprint" Aeson..= (report ^. #catalogFingerprint),
        "groupSlices"
          Aeson..= [ Aeson.object
                       [ "groupId" Aeson..= rebuildGroupIdText groupId,
                         "sliceFingerprint" Aeson..= slice
                       ]
                   | (groupId, slice) <- report ^. #groupSlices
                   ],
        "inventory" Aeson..= inventoryValue (report ^. #inventory)
      ]

instance Aeson.ToJSON RebuildPreview where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "groupId" Aeson..= rebuildGroupIdText (report ^. #rebuildGroupId),
        "catalogFingerprint" Aeson..= (report ^. #catalogFingerprint),
        "sliceFingerprint" Aeson..= (report ^. #sliceFingerprint),
        "targets" Aeson..= map targetValue (report ^. #targets),
        "sources" Aeson..= map sourceValue (report ^. #sources),
        "projections" Aeson..= map projectionValue (report ^. #projections),
        "queryModels" Aeson..= map queryModelValue (report ^. #queryModels),
        "subscriptionResets" Aeson..= map subscriptionValue (report ^. #subscriptionResets),
        "dedupResets" Aeson..= map dedupValue (report ^. #dedupResets),
        "verifications" Aeson..= map verificationValue (report ^. #verifications),
        "lockScope" Aeson..= map rebuildGroupIdText (report ^. #lockScope),
        "capturedHeadStrategy" Aeson..= (report ^. #capturedHeadStrategy),
        "destructive" Aeson..= (report ^. #destructive)
      ]

instance Aeson.ToJSON RegisteredRebuildPreview where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "preview" Aeson..= (report ^. #preview),
        "registeredState" Aeson..= fmap groupMetadataValue (report ^. #registeredState),
        "registeredSliceMatches" Aeson..= (report ^. #registeredSliceMatches)
      ]

instance Aeson.ToJSON CatalogAdoptionReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "catalogFingerprint" Aeson..= (report ^. #catalogFingerprint),
        "requestedGroups" Aeson..= map rebuildGroupIdText (report ^. #requestedGroups),
        "groups" Aeson..= map adoptionGroupValue (report ^. #groups),
        "registrations" Aeson..= map adoptionRegistrationValue (report ^. #registrations),
        "orphanedRegistrations" Aeson..= map adoptionOrphanPreviewValue (report ^. #orphanedRegistrations),
        "removedGroups" Aeson..= map rebuildGroupIdText (report ^. #removedGroups),
        "outOfScopeChangedGroups" Aeson..= map rebuildGroupIdText (report ^. #outOfScopeChangedGroups)
      ]

instance Aeson.ToJSON CatalogAdoptionOutcome where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "adoptedGroups" Aeson..= map groupMetadataValue (report ^. #adoptedGroups),
        "registrationOutcomes" Aeson..= map registrationOutcomeValue (report ^. #registrationOutcomes),
        "removedOrphans" Aeson..= map removedOrphanValue (report ^. #removedOrphans)
      ]

instance Aeson.ToJSON CatalogRunReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "run" Aeson..= runValue (report ^. #run)
      ]

instance Aeson.ToJSON CatalogVersionedRunReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "run" Aeson..= versionedRunValue (report ^. #run)
      ]

instance Aeson.ToJSON CatalogRetiredGenerationsReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "generations" Aeson..= map versionedGenerationValue (report ^. #generations)
      ]

instance Aeson.ToJSON CatalogRetiredDropReport where
  toJSON = \case
    CatalogRetiredDropPreview previewReport ->
      Aeson.object
        [ "schema" Aeson..= ("keiro/catalog-retired-drop-preview/v1" :: Text),
          "generation" Aeson..= versionedGenerationValue (previewReport ^. #generation),
          "activeRunId" Aeson..= fmap rebuildRunIdText (previewReport ^. #activeRunId),
          "supportedReadContracts" Aeson..= (previewReport ^. #supportedReadContracts),
          "externalDependencies" Aeson..= (previewReport ^. #externalDependencies),
          "droppable" Aeson..= (previewReport ^. #droppable)
        ]
    CatalogRetiredDropOutcome outcome ->
      Aeson.object
        [ "schema" Aeson..= ("keiro/catalog-retired-drop-outcome/v1" :: Text),
          "generation" Aeson..= versionedGenerationValue (outcome ^. #generation),
          "alreadyDropped" Aeson..= (outcome ^. #alreadyDropped)
        ]

instance Aeson.ToJSON CatalogExternalReadRetirementReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "contractId" Aeson..= externalReadContractIdText (report ^. #contractId),
        "contractVersion" Aeson..= externalReadContractVersionValue (report ^. #contractVersion),
        "publicFunction" Aeson..= (report ^. #publicFunction),
        "currentState" Aeson..= (report ^. #currentState),
        "surfaceGeneration" Aeson..= (report ^. #surfaceGeneration),
        "dependentObjects" Aeson..= (report ^. #dependentObjects),
        "executeGrants" Aeson..= (report ^. #executeGrants)
      ]

instance Aeson.ToJSON CatalogStreamReprojectionPreview where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "groupId" Aeson..= rebuildGroupIdText (report ^. #rebuildGroupId),
        "projectionId" Aeson..= projectionIdText (report ^. #projectionId),
        "streamName" Aeson..= streamNameValue (report ^. #streamName),
        "servingRevisionId" Aeson..= projectionRevisionIdText (report ^. #servingRevisionId),
        "targets" Aeson..= map targetValue (report ^. #targets),
        "affectedDedup" Aeson..= map dedupValue (report ^. #affectedDedup),
        "streamVersion" Aeson..= fmap streamVersionValue (report ^. #streamVersion),
        "softDeleted" Aeson..= (report ^. #softDeleted),
        "truncateBefore" Aeson..= fmap streamVersionValue (report ^. #truncateBefore),
        "eligible" Aeson..= (report ^. #eligible),
        "refusal" Aeson..= (report ^. #refusal),
        "forceOperation" Aeson..= (report ^. #forceOperation)
      ]

instance Aeson.ToJSON CatalogStreamReprojectionReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "repair" Aeson..= streamReprojectionValue (report ^. #repair)
      ]

streamReprojectionValue :: StreamReprojectionReport -> Aeson.Value
streamReprojectionValue report =
  Aeson.object
    [ "groupId" Aeson..= rebuildGroupIdText (report ^. #rebuildGroupId),
      "projectionId" Aeson..= projectionIdText (report ^. #projectionId),
      "streamName" Aeson..= streamNameValue (report ^. #streamName),
      "servingRevisionId" Aeson..= projectionRevisionIdText (report ^. #servingRevisionId),
      "streamVersion" Aeson..= streamVersionValue (report ^. #streamVersion),
      "clearedRows"
        Aeson..= [ Aeson.object
                     [ "targetId" Aeson..= targetIdText (count ^. #targetId),
                       "rows" Aeson..= (count ^. #clearedRows)
                     ]
                 | count <- report ^. #clearedRows
                 ],
      "replayedEvents" Aeson..= (report ^. #replayedEvents),
      "appliedEvents" Aeson..= (report ^. #appliedEvents),
      "dedupInserted" Aeson..= (report ^. #dedupInserted),
      "dedupExisting" Aeson..= (report ^. #dedupExisting),
      "verified" Aeson..= (report ^. #verified)
    ]

streamNameValue :: StreamName -> Text
streamNameValue (StreamName value) = value

streamVersionValue :: StreamVersion -> Int64
streamVersionValue (StreamVersion value) = value

inventoryValue :: CatalogInventory -> Aeson.Value
inventoryValue catalog =
  Aeson.object
    [ "sources" Aeson..= map sourceValue (catalog ^. #inventorySources),
      "targets" Aeson..= map targetValue (catalog ^. #inventoryTargets),
      "groups" Aeson..= map groupValue (catalog ^. #inventoryGroups),
      "projections" Aeson..= map projectionValue (catalog ^. #inventoryProjections),
      "projectionRevisions" Aeson..= map projectionRevisionValue (catalog ^. #inventoryProjectionRevisions),
      "queryModels" Aeson..= map queryModelValue (catalog ^. #inventoryQueryModels),
      "subscriptions" Aeson..= map subscriptionValue (catalog ^. #inventorySubscriptions),
      "dedupKeys" Aeson..= map dedupValue (catalog ^. #inventoryDedupKeys)
    ]

projectionRevisionValue :: InventoryProjectionRevision -> Aeson.Value
projectionRevisionValue revision =
  Aeson.object
    [ "revisionId" Aeson..= projectionRevisionIdText (revision ^. #revisionId),
      "groupId" Aeson..= rebuildGroupIdText (revision ^. #rebuildGroupId),
      "targetProvisioners" Aeson..= map targetProvisionerValue (revision ^. #targetProvisioners),
      "liveHandlers" Aeson..= map revisionHandlerValue (revision ^. #liveHandlers),
      "replayAdapters" Aeson..= map revisionHandlerValue (revision ^. #replayAdapters),
      "verifications" Aeson..= map revisionHandlerValue (revision ^. #verifications),
      "streamScopedReplays" Aeson..= map streamScopedReplayValue (revision ^. #streamScopedReplays)
    ]

targetProvisionerValue :: InventoryTargetProvisioner -> Aeson.Value
targetProvisionerValue provisioner =
  Aeson.object
    [ "targetId" Aeson..= targetIdText (provisioner ^. #targetId),
      "provisionerId" Aeson..= (provisioner ^. #provisionerId),
      "provisionerVersion" Aeson..= (provisioner ^. #provisionerVersion),
      "schemaVersion" Aeson..= schemaVersionText (provisioner ^. #schemaVersion),
      "expectedShapeId" Aeson..= (provisioner ^. #expectedShapeId),
      "validatorId" Aeson..= (provisioner ^. #validatorId),
      "validatorVersion" Aeson..= (provisioner ^. #validatorVersion),
      "promotionObjects"
        Aeson..= [ Aeson.object
                     [ "kind" Aeson..= Text.pack (show (object ^. #objectKind)),
                       "generationName" Aeson..= (object ^. #generationName),
                       "canonicalName" Aeson..= (object ^. #canonicalName)
                     ]
                 | object <- provisioner ^. #promotionObjectNames
                 ]
    ]

revisionHandlerValue :: InventoryRevisionHandler -> Aeson.Value
revisionHandlerValue handler =
  Aeson.object
    [ "id" Aeson..= (handler ^. #handlerId),
      "version" Aeson..= (handler ^. #handlerVersion),
      "requiredTargets" Aeson..= map targetIdText (handler ^. #requiredTargets)
    ]

streamScopedReplayValue :: InventoryStreamScopedReplay -> Aeson.Value
streamScopedReplayValue replay =
  Aeson.object
    [ "projectionId" Aeson..= projectionIdText (replay ^. #projectionId),
      "ownedTargets" Aeson..= map targetIdText (replay ^. #ownedTargets),
      "clearer" Aeson..= identityValue (replay ^. #clearerId) (replay ^. #clearerVersion),
      "replay" Aeson..= identityValue (replay ^. #replayId) (replay ^. #replayVersion),
      "verification" Aeson..= identityValue (replay ^. #verificationId) (replay ^. #verificationVersion),
      "affectedAsyncDedup" Aeson..= map dedupKeyIdText (replay ^. #affectedAsyncDedup)
    ]
  where
    identityValue identityText identityVersion =
      Aeson.object
        [ "id" Aeson..= identityText,
          "version" Aeson..= identityVersion
        ]

sourceValue :: InventorySource -> Aeson.Value
sourceValue source =
  Aeson.object
    [ "sourceId" Aeson..= sourceIdText (source ^. #sourceId),
      "scope" Aeson..= sourceScopeValue (source ^. #sourceScope),
      "codecFingerprint" Aeson..= (source ^. #codecFingerprint)
    ]

sourceScopeValue :: SourceScope -> Aeson.Value
sourceScopeValue = \case
  AllStreams -> Aeson.object ["kind" Aeson..= ("all-streams" :: Text)]
  CategorySource (CategoryName category) ->
    Aeson.object
      [ "kind" Aeson..= ("category" :: Text),
        "category" Aeson..= category
      ]

targetValue :: InventoryTarget -> Aeson.Value
targetValue target =
  Aeson.object
    [ "targetId" Aeson..= targetIdText (target ^. #targetId),
      "table" Aeson..= qualifiedTableValue (target ^. #qualifiedTable),
      "resetPolicy" Aeson..= resetPolicyText (target ^. #resetPolicy),
      "dependsOn" Aeson..= map targetIdText (target ^. #dependsOn),
      "owner" Aeson..= projectionIdText (target ^. #owner)
    ]

qualifiedTableValue :: QualifiedTable -> Aeson.Value
qualifiedTableValue table =
  Aeson.object
    [ "schema" Aeson..= (table ^. #schemaName),
      "table" Aeson..= (table ^. #tableName)
    ]

resetPolicyText :: TargetResetPolicy -> Text
resetPolicyText = \case
  ClearBeforeReplay -> "clear-before-replay"
  PreserveAndReconcile -> "preserve-and-reconcile"

groupValue :: InventoryGroup -> Aeson.Value
groupValue group =
  Aeson.object
    [ "groupId" Aeson..= rebuildGroupIdText (group ^. #rebuildGroupId),
      "orderedTargets" Aeson..= map targetIdText (group ^. #orderedTargets),
      "verifications" Aeson..= map verificationValue (group ^. #verifications)
    ]

verificationValue :: (Text, Text) -> Aeson.Value
verificationValue (identity, version) =
  Aeson.object
    [ "id" Aeson..= identity,
      "version" Aeson..= version
    ]

projectionValue :: InventoryProjection -> Aeson.Value
projectionValue projection =
  Aeson.object
    [ "projectionId" Aeson..= projectionIdText (projection ^. #projectionId),
      "sourceId" Aeson..= sourceIdText (projection ^. #sourceId),
      "groupId" Aeson..= rebuildGroupIdText (projection ^. #rebuildGroupId),
      "ownedTargets" Aeson..= map targetIdText (projection ^. #ownedTargets),
      "replayPolicy" Aeson..= (projection ^. #replayDisposition),
      "handlers" Aeson..= map handlerValue (projection ^. #handlers)
    ]

handlerValue :: InventoryHandler -> Aeson.Value
handlerValue = \case
  InventoryInlineHandler name ->
    Aeson.object
      [ "kind" Aeson..= ("inline" :: Text),
        "name" Aeson..= name
      ]
  InventoryAsyncHandler name subscriptionId dedupKeyId ->
    Aeson.object
      [ "kind" Aeson..= ("async" :: Text),
        "name" Aeson..= name,
        "subscriptionId" Aeson..= subscriptionIdText subscriptionId,
        "dedupKeyId" Aeson..= dedupKeyIdText dedupKeyId
      ]

queryModelValue :: InventoryQueryModel -> Aeson.Value
queryModelValue queryModel =
  Aeson.object
    [ "queryModelId" Aeson..= queryModelIdText (queryModel ^. #queryModelId),
      "registryName" Aeson..= (queryModel ^. #registryName),
      "version" Aeson..= (queryModel ^. #version),
      "shapeHash" Aeson..= (queryModel ^. #shapeHash),
      "groupId" Aeson..= rebuildGroupIdText (queryModel ^. #rebuildGroupId),
      "observedTargets" Aeson..= map targetIdText (queryModel ^. #observedTargets),
      "freshness" Aeson..= queryFreshnessValue (queryModel ^. #freshness),
      "cursor" Aeson..= fmap queryCursorValue (queryModel ^. #cursor)
    ]

queryFreshnessValue :: InventoryQueryFreshness -> Aeson.Value
queryFreshnessValue InventoryImmediate =
  Aeson.object ["kind" Aeson..= ("immediate" :: Text)]
queryFreshnessValue (InventoryWaitForHead scope) =
  Aeson.object
    [ "kind" Aeson..= ("wait-for-head" :: Text),
      "scope" Aeson..= headScopeValue scope
    ]
queryFreshnessValue InventoryWaitForPosition =
  Aeson.object ["kind" Aeson..= ("wait-for-position" :: Text)]

headScopeValue :: HeadScope -> Aeson.Value
headScopeValue EntireVisibleLog =
  Aeson.object ["kind" Aeson..= ("entire-visible-log" :: Text)]
headScopeValue (CategoryVisibleHead category) =
  Aeson.object
    [ "kind" Aeson..= ("category-visible-head" :: Text),
      "category" Aeson..= category
    ]

queryCursorValue :: InventoryQueryCursor -> Aeson.Value
queryCursorValue queryCursor =
  Aeson.object
    [ "subscriptionId" Aeson..= subscriptionIdText (queryCursor ^. #subscriptionId),
      "subscriptionName" Aeson..= (queryCursor ^. #subscriptionName)
    ]

subscriptionValue :: InventorySubscription -> Aeson.Value
subscriptionValue subscription =
  Aeson.object
    [ "subscriptionId" Aeson..= subscriptionIdText (subscription ^. #subscriptionId),
      "name" Aeson..= (subscription ^. #subscriptionName),
      "sourceId" Aeson..= sourceIdText (subscription ^. #sourceId),
      "checkpointOnMissing" Aeson..= missingCheckpointPolicyText (subscription ^. #checkpointOnMissing)
    ]

dedupValue :: InventoryDedupKey -> Aeson.Value
dedupValue dedupKey =
  Aeson.object
    [ "dedupKeyId" Aeson..= dedupKeyIdText (dedupKey ^. #dedupKeyId),
      "name" Aeson..= (dedupKey ^. #dedupName)
    ]

groupMetadataValue :: GroupRebuildMetadata -> Aeson.Value
groupMetadataValue metadata =
  Aeson.object
    [ "groupId" Aeson..= rebuildGroupIdText (metadata ^. #rebuildGroupId),
      "sliceFingerprint" Aeson..= (metadata ^. #sliceFingerprint),
      "status" Aeson..= lifecycleStatusText (metadata ^. #status),
      "activeRunId" Aeson..= fmap rebuildRunIdText (metadata ^. #activeRunId),
      "requestedBy" Aeson..= (metadata ^. #requestedBy),
      "requestReason" Aeson..= (metadata ^. #requestReason),
      "startedAt" Aeson..= (metadata ^. #startedAt),
      "completedAt" Aeson..= (metadata ^. #completedAt),
      "failedAt" Aeson..= (metadata ^. #failedAt),
      "failureCode" Aeson..= (metadata ^. #failureCode),
      "failureDetail" Aeson..= (metadata ^. #failureDetail)
    ]

groupPreview :: ValidatedProjectionCatalog -> Set.Set RebuildGroupId -> (RebuildGroupId, GroupAdoptionClass) -> CatalogAdoptionGroupPreview
groupPreview catalog requestedSet (groupId, adoptionClass) =
  CatalogAdoptionGroupPreview
    { rebuildGroupId = groupId,
      classification = adoptionClass,
      storedSlice = case adoptionClass of
        AdoptionNew -> Nothing
        AdoptionUnchanged -> Just current
        AdoptionSliceChanged stored _ -> Just stored
        AdoptionStaleFormat stored -> Just stored,
      currentSlice = current,
      inScope = Set.member groupId requestedSet
    }
  where
    current =
      maybe
        (error "groupPreview: catalog inventory group has no slice")
        groupSliceFingerprintText
        (Keiro.Projection.Catalog.groupSliceFingerprint catalog groupId)

registrationPreview :: Set.Set RebuildGroupId -> RegistrationAdoption -> CatalogAdoptionRegistrationPreview
registrationPreview requestedSet registration =
  CatalogAdoptionRegistrationPreview
    { registryName = registration ^. #registryName,
      rebuildGroupId = registration ^. #rebuildGroupId,
      action = registration ^. #action,
      inScope = Set.member (registration ^. #rebuildGroupId) requestedSet
    }

orphanPreview :: Set.Set RebuildGroupId -> OrphanedRegistration -> CatalogAdoptionOrphanPreview
orphanPreview requestedSet orphan =
  CatalogAdoptionOrphanPreview
    { registryName = orphan ^. #registryName,
      boundGroupId = orphan ^. #boundGroupId,
      inScope = Set.member (orphan ^. #boundGroupId) requestedSet
    }

adoptionGroupValue :: CatalogAdoptionGroupPreview -> Aeson.Value
adoptionGroupValue group =
  Aeson.object
    [ "groupId" Aeson..= rebuildGroupIdText (group ^. #rebuildGroupId),
      "state" Aeson..= adoptionStateText (group ^. #classification),
      "storedSlice" Aeson..= (group ^. #storedSlice),
      "currentSlice" Aeson..= (group ^. #currentSlice),
      "inScope" Aeson..= (group ^. #inScope)
    ]

adoptionRegistrationValue :: CatalogAdoptionRegistrationPreview -> Aeson.Value
adoptionRegistrationValue registration =
  Aeson.object
    [ "name" Aeson..= (registration ^. #registryName),
      "groupId" Aeson..= rebuildGroupIdText (registration ^. #rebuildGroupId),
      "action" Aeson..= registrationActionText (registration ^. #action),
      "inScope" Aeson..= (registration ^. #inScope)
    ]

adoptionOrphanPreviewValue :: CatalogAdoptionOrphanPreview -> Aeson.Value
adoptionOrphanPreviewValue orphan =
  Aeson.object
    [ "name" Aeson..= (orphan ^. #registryName),
      "groupId" Aeson..= rebuildGroupIdText (orphan ^. #boundGroupId),
      "inScope" Aeson..= (orphan ^. #inScope)
    ]

registrationOutcomeValue :: RegistrationAdoption -> Aeson.Value
registrationOutcomeValue registration =
  Aeson.object
    [ "name" Aeson..= (registration ^. #registryName),
      "groupId" Aeson..= rebuildGroupIdText (registration ^. #rebuildGroupId),
      "outcome" Aeson..= registrationOutcomeText (registration ^. #action)
    ]

removedOrphanValue :: OrphanedRegistration -> Aeson.Value
removedOrphanValue orphan =
  Aeson.object
    [ "name" Aeson..= (orphan ^. #registryName),
      "groupId" Aeson..= rebuildGroupIdText (orphan ^. #boundGroupId),
      "outcome" Aeson..= ("orphaned-old-name" :: Text)
    ]

registrationActionText :: RegistrationAdoptionAction -> Text
registrationActionText = \case
  RegistrationUpdate -> "update"
  RegistrationInsert -> "insert"

registrationOutcomeText :: RegistrationAdoptionAction -> Text
registrationOutcomeText = \case
  RegistrationUpdate -> "adopted"
  RegistrationInsert -> "inserted"

changedAdoptionClass :: GroupAdoptionClass -> Bool
changedAdoptionClass = \case
  AdoptionSliceChanged {} -> True
  AdoptionStaleFormat {} -> True
  AdoptionNew -> False
  AdoptionUnchanged -> False

adoptionStateText :: GroupAdoptionClass -> Text
adoptionStateText = \case
  AdoptionNew -> "new"
  AdoptionUnchanged -> "unchanged"
  AdoptionSliceChanged {} -> "slice-changed"
  AdoptionStaleFormat {} -> "stale-format"

lifecycleStatusText :: GroupLifecycleStatus -> Text
lifecycleStatusText = \case
  GroupLive -> "live"
  GroupRebuilding -> "rebuilding"
  GroupFailed -> "failed"
  UnknownGroupStatus value -> value

versionedRunValue :: VersionedRebuildReport -> Aeson.Value
versionedRunValue report =
  Aeson.object
    [ "runId" Aeson..= rebuildRunIdText (report ^. #rebuildRunId),
      "groupId" Aeson..= rebuildGroupIdText (report ^. #rebuildGroupId),
      "phase" Aeson..= Text.pack (show (report ^. #phase)),
      "servingRevisionId" Aeson..= projectionRevisionIdText (report ^. #servingRevisionId),
      "candidateRevisionId" Aeson..= projectionRevisionIdText (report ^. #candidateRevisionId),
      "servingEpoch" Aeson..= (report ^. #servingEpoch),
      "capturedHead" Aeson..= globalPositionValue (report ^. #capturedHead),
      "pageSize" Aeson..= (report ^. #replayPageSize),
      "cutoverThreshold" Aeson..= (report ^. #cutoverThreshold),
      "cutoverLockTimeoutMs" Aeson..= (report ^. #cutoverLockTimeoutMs),
      "sources" Aeson..= map versionedSourceValue (report ^. #sources),
      "servingGenerations" Aeson..= map versionedGenerationValue (report ^. #servingGenerations),
      "candidateGenerations" Aeson..= map versionedGenerationValue (report ^. #candidateGenerations)
    ]

versionedSourceValue :: Rebuild.VersionedSourceProgress -> Aeson.Value
versionedSourceValue progress =
  Aeson.object
    [ "sourceId" Aeson..= sourceIdText (progress ^. #sourceId),
      "scope" Aeson..= sourceScopeValue (progress ^. #sourceScope),
      "cursor" Aeson..= globalPositionValue (progress ^. #cursorPosition),
      "target" Aeson..= globalPositionValue (progress ^. #targetPosition),
      "exhaustedThrough" Aeson..= fmap globalPositionValue (progress ^. #exhaustedThrough),
      "eventCount" Aeson..= (progress ^. #eventCount)
    ]

versionedGenerationValue :: VersionedTargetGeneration -> Aeson.Value
versionedGenerationValue generation =
  Aeson.object
    [ "generationId" Aeson..= generationIdText (generation ^. #generationId),
      "groupId" Aeson..= rebuildGroupIdText (generation ^. #rebuildGroupId),
      "targetId" Aeson..= targetIdText (generation ^. #targetId),
      "revisionId" Aeson..= projectionRevisionIdText (generation ^. #revisionId),
      "physicalTable" Aeson..= qualifiedTableValue (generation ^. #physicalTable),
      "relationOid" Aeson..= (generation ^. #relationOid),
      "schemaVersion" Aeson..= schemaVersionText (generation ^. #schemaVersion),
      "expectedShapeId" Aeson..= (generation ^. #expectedShapeId),
      "observedShapeFingerprint" Aeson..= (generation ^. #observedShapeFingerprint),
      "lifecycle" Aeson..= Text.pack (show (generation ^. #lifecycle))
    ]

generationIdText :: TargetGenerationId -> Text
generationIdText (TargetGenerationId value) = UUID.toText value

schemaVersionText :: TargetSchemaVersion -> Text
schemaVersionText (TargetSchemaVersion value) = value

runValue :: RebuildRunReport -> Aeson.Value
runValue report =
  Aeson.object
    [ "runId" Aeson..= rebuildRunIdText (report ^. #rebuildRunId),
      "groupId" Aeson..= rebuildGroupIdText (report ^. #rebuildGroupId),
      "catalogFingerprint" Aeson..= (report ^. #catalogFingerprint),
      "groupSliceFingerprint" Aeson..= (report ^. #groupSliceFingerprint),
      "contractFingerprint" Aeson..= (report ^. #contractFingerprint),
      "runnerFormat" Aeson..= (report ^. #runnerFormatVersion),
      "capturedHead" Aeson..= globalPositionValue (report ^. #capturedHead),
      "pageSize" Aeson..= (report ^. #configuredPageSize),
      "status" Aeson..= runStatusText (report ^. #runStatus),
      "failure" Aeson..= fmap failureValue (report ^. #failureEvidence),
      "sources" Aeson..= map sourceProgressValue (report ^. #sources),
      "adapters" Aeson..= map adapterProgressValue (report ^. #adapters),
      "verifications" Aeson..= map verificationProgressValue (report ^. #verifications)
    ]

runStatusText :: RebuildRunStatus -> Text
runStatusText = \case
  RebuildRunRunning -> "running"
  RebuildRunFailed -> "failed"
  RebuildRunVerified -> "verified"
  RebuildRunPromoted -> "promoted"
  UnknownRebuildRunStatus value -> value

failureValue :: RebuildFailureEvidence -> Aeson.Value
failureValue failure =
  Aeson.object
    [ "code" Aeson..= (failure ^. #failureCode),
      "detail" Aeson..= (failure ^. #failureDetail),
      "sourceId" Aeson..= fmap sourceIdText (failure ^. #failureSourceId),
      "projectionId" Aeson..= (failure ^. #failureProjectionId),
      "position" Aeson..= fmap globalPositionValue (failure ^. #failurePosition)
    ]

sourceProgressValue :: RebuildSourceProgress -> Aeson.Value
sourceProgressValue progress =
  Aeson.object
    [ "sourceId" Aeson..= sourceIdText (progress ^. #sourceId),
      "scope" Aeson..= sourceScopeValue (progress ^. #sourceScope),
      "cursor" Aeson..= globalPositionValue (progress ^. #cursorPosition),
      "target" Aeson..= globalPositionValue (progress ^. #targetPosition),
      "exhaustedThrough" Aeson..= fmap globalPositionValue (progress ^. #exhaustedThrough),
      "eventCount" Aeson..= (progress ^. #eventCount)
    ]

adapterProgressValue :: RebuildAdapterProgress -> Aeson.Value
adapterProgressValue progress =
  Aeson.object
    [ "sourceId" Aeson..= sourceIdText (progress ^. #sourceId),
      "projectionId" Aeson..= (progress ^. #projectionId),
      "order" Aeson..= (progress ^. #adapterOrder),
      "evaluationCount" Aeson..= (progress ^. #evaluationCount),
      "applyCount" Aeson..= (progress ^. #applyCount),
      "completedThrough" Aeson..= fmap globalPositionValue (progress ^. #completedThrough)
    ]

verificationProgressValue :: RebuildVerificationProgress -> Aeson.Value
verificationProgressValue progress =
  Aeson.object
    [ "id" Aeson..= (progress ^. #verificationId),
      "version" Aeson..= (progress ^. #verificationVersion),
      "status" Aeson..= (progress ^. #verificationStatus),
      "detail" Aeson..= (progress ^. #verificationDetail)
    ]

globalPositionValue :: GlobalPosition -> Int64
globalPositionValue (GlobalPosition value) = value
