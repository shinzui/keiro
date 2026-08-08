-- | Operator-neutral inventory and rebuild actions derived from one validated
-- projection catalog. This module deliberately contains no command parser,
-- renderer, confirmation policy, or database connection details.
module Keiro.Projection.Catalog.Operations
  ( ProjectionCatalogOperations,
    projectionCatalogOperations,
    CatalogInventoryReport (..),
    RebuildPreview (..),
    RegisteredRebuildPreview (..),
    CatalogRunReport (..),
    CatalogOpsError (..),
    catalogInventoryReport,
    previewGroupRebuild,
    previewRegisteredGroupRebuild,
    startGroupRebuild,
    inspectGroupRebuild,
    resumeGroupRebuild,
    abandonGroupRebuild,
  )
where

import Data.Aeson qualified as Aeson
import Data.List qualified as List
import Data.Maybe (mapMaybe)
import Effectful (Eff, IOE, (:>))
import Keiro.Prelude
import Keiro.Projection.Catalog
import Keiro.ReadModel.Rebuild
  ( CatalogRebuildError,
    GroupLifecycleStatus (..),
    GroupRebuildMetadata,
    RebuildAdapterProgress,
    RebuildFailure,
    RebuildFailureEvidence,
    RebuildOptions,
    RebuildRunId,
    RebuildRunReport,
    RebuildRunStatus (..),
    RebuildSourceProgress,
    RebuildVerificationProgress,
    abandonCatalogRebuild,
    inspectCatalogRebuild,
    lookupProjectionRebuildGroup,
    rebuildRunIdText,
    resumeCatalogRebuild,
    startCatalogRebuild,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..))

newtype ProjectionCatalogOperations = ProjectionCatalogOperations ValidatedProjectionCatalog
  deriving stock (Generic)

projectionCatalogOperations :: ValidatedProjectionCatalog -> ProjectionCatalogOperations
projectionCatalogOperations = ProjectionCatalogOperations

-- | Stable, JSON-friendly envelope for the complete heterogeneous inventory.
data CatalogInventoryReport = CatalogInventoryReport
  { reportSchema :: !Text,
    catalogFingerprint :: !Text,
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
    registeredState :: !(Maybe GroupRebuildMetadata)
  }
  deriving stock (Eq, Show, Generic)

-- | Versioned operations envelope around the runtime runner's structured
-- progress report.
data CatalogRunReport = CatalogRunReport
  { reportSchema :: !Text,
    run :: !RebuildRunReport
  }
  deriving stock (Eq, Show, Generic)

data CatalogOpsError
  = CatalogOpsUnknownGroup !RebuildGroupId
  | CatalogOpsRebuildError !CatalogRebuildError
  deriving stock (Eq, Show, Generic)

catalogInventoryReport :: ProjectionCatalogOperations -> CatalogInventoryReport
catalogInventoryReport (ProjectionCatalogOperations catalog) =
  CatalogInventoryReport
    { reportSchema = "keiro/catalog-inventory/v1",
      catalogFingerprint = catalogFingerprintText (Keiro.Projection.Catalog.catalogFingerprint catalog),
      inventory = catalogInventory catalog
    }

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
      { reportSchema = "keiro/catalog-rebuild-preview/v1",
        rebuildGroupId = wantedGroup,
        catalogFingerprint = catalogFingerprintText (Keiro.Projection.Catalog.catalogFingerprint catalog),
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
      pure
        ( Right
            RegisteredRebuildPreview
              { reportSchema = "keiro/catalog-registered-rebuild-preview/v1",
                preview = purePreview,
                registeredState = state
              }
        )

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
inspectGroupRebuild _ runId = wrapRun <$> inspectCatalogRebuild runId

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

wrapRun :: Either CatalogRebuildError RebuildRunReport -> Either CatalogOpsError CatalogRunReport
wrapRun = \case
  Left err -> Left (CatalogOpsRebuildError err)
  Right report ->
    Right
      CatalogRunReport
        { reportSchema = "keiro/catalog-rebuild-run/v1",
          run = report
        }

instance Aeson.ToJSON CatalogInventoryReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "catalogFingerprint" Aeson..= (report ^. #catalogFingerprint),
        "inventory" Aeson..= inventoryValue (report ^. #inventory)
      ]

instance Aeson.ToJSON RebuildPreview where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "groupId" Aeson..= rebuildGroupIdText (report ^. #rebuildGroupId),
        "catalogFingerprint" Aeson..= (report ^. #catalogFingerprint),
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
        "registeredState" Aeson..= fmap groupMetadataValue (report ^. #registeredState)
      ]

instance Aeson.ToJSON CatalogRunReport where
  toJSON report =
    Aeson.object
      [ "schema" Aeson..= (report ^. #reportSchema),
        "run" Aeson..= runValue (report ^. #run)
      ]

inventoryValue :: CatalogInventory -> Aeson.Value
inventoryValue catalog =
  Aeson.object
    [ "sources" Aeson..= map sourceValue (catalog ^. #inventorySources),
      "targets" Aeson..= map targetValue (catalog ^. #inventoryTargets),
      "groups" Aeson..= map groupValue (catalog ^. #inventoryGroups),
      "projections" Aeson..= map projectionValue (catalog ^. #inventoryProjections),
      "queryModels" Aeson..= map queryModelValue (catalog ^. #inventoryQueryModels),
      "subscriptions" Aeson..= map subscriptionValue (catalog ^. #inventorySubscriptions),
      "dedupKeys" Aeson..= map dedupValue (catalog ^. #inventoryDedupKeys)
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
      "observedTargets" Aeson..= map targetIdText (queryModel ^. #observedTargets)
    ]

subscriptionValue :: InventorySubscription -> Aeson.Value
subscriptionValue subscription =
  Aeson.object
    [ "subscriptionId" Aeson..= subscriptionIdText (subscription ^. #subscriptionId),
      "name" Aeson..= (subscription ^. #subscriptionName),
      "sourceId" Aeson..= sourceIdText (subscription ^. #sourceId)
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
      "catalogFingerprint" Aeson..= (metadata ^. #catalogFingerprint),
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

lifecycleStatusText :: GroupLifecycleStatus -> Text
lifecycleStatusText = \case
  GroupLive -> "live"
  GroupRebuilding -> "rebuilding"
  GroupFailed -> "failed"
  UnknownGroupStatus value -> value

runValue :: RebuildRunReport -> Aeson.Value
runValue report =
  Aeson.object
    [ "runId" Aeson..= rebuildRunIdText (report ^. #rebuildRunId),
      "groupId" Aeson..= rebuildGroupIdText (report ^. #rebuildGroupId),
      "catalogFingerprint" Aeson..= (report ^. #catalogFingerprint),
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
