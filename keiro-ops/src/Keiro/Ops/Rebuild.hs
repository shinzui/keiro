-- | Catalog-backed projection rebuild commands.
--
-- Parsing, rendering, previews, and force policy live here; inventory and
-- rebuild semantics remain in 'ProjectionCatalogOperations'.
module Keiro.Ops.Rebuild
  ( Command (..),
    StartOptions (..),
    ResumeOptions (..),
    AbandonOptions (..),
    AdoptOptions (..),
    commandParser,
    isMutation,
    runCommand,
  )
where

import Data.Aeson qualified as Aeson
import Data.Int (Int32, Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (readBoundedIntegral)
import Keiro.Ops.Render
import Keiro.Projection.Catalog
  ( CatalogInventory (..),
    InventoryGroup (..),
    RebuildGroupId,
    mkRebuildGroupId,
    rebuildGroupIdText,
  )
import Keiro.Projection.Catalog.Operations
import Keiro.ReadModel.Rebuild
  ( GroupAdoptionClass (..),
    GroupLifecycleStatus (..),
    GroupRebuildMetadata (..),
    RebuildFailure (..),
    RebuildOptions (..),
    RebuildRequest (..),
    RebuildRunId,
    RebuildRunReport (..),
    defaultRebuildOptions,
    mkRebuildRunId,
    rebuildRunIdText,
  )
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (GlobalPosition (..))
import Options.Applicative hiding (action, value)
import Options.Applicative qualified as Optparse

data Command
  = List
  | Preview !RebuildGroupId
  | Start !StartOptions
  | Status !RebuildRunId
  | Resume !ResumeOptions
  | Abandon !AbandonOptions
  | Adopt !AdoptOptions
  deriving stock (Eq, Show)

data StartOptions = StartOptions
  { groupId :: !RebuildGroupId,
    runId :: !RebuildRunId,
    requestedBy :: !Text,
    reason :: !Text,
    replayFrom :: !GlobalPosition,
    pageSize :: !Int32
  }
  deriving stock (Eq, Show)

data ResumeOptions = ResumeOptions
  { runId :: !RebuildRunId,
    pageSize :: !Int32
  }
  deriving stock (Eq, Show)

data AbandonOptions = AbandonOptions
  { runId :: !RebuildRunId,
    failureCode :: !Text,
    failureDetail :: !Text
  }
  deriving stock (Eq, Show)

data AdoptOptions = AdoptOptions
  { groups :: !(NonEmpty RebuildGroupId)
  }
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "list" (info (pure List) (progDesc "List the mounted catalog's rebuild groups"))
        <> command "preview" (info (Preview <$> groupArgument) (progDesc "Preview one catalog group without mutation"))
        <> command "start" (info (Start <$> startOptionsParser) (progDesc "Preview or start one catalog rebuild"))
        <> command "status" (info (Status <$> runArgument) (progDesc "Inspect one catalog rebuild run"))
        <> command "resume" (info (Resume <$> resumeOptionsParser) (progDesc "Preview or resume one catalog rebuild run"))
        <> command "abandon" (info (Abandon <$> abandonOptionsParser) (progDesc "Preview or abandon one catalog rebuild run"))
        <> command "adopt" (info (Adopt <$> adoptOptionsParser) (progDesc "Preview or adopt catalog slice changes for the named groups"))
    )

startOptionsParser :: Parser StartOptions
startOptionsParser =
  StartOptions
    <$> groupArgument
    <*> runIdOption
    <*> textOption "requested-by" "IDENTITY" "Operator or automation identity"
    <*> textOption "reason" "TEXT" "Reason for this rebuild"
    <*> (GlobalPosition <$> option nonNegativeInt64Reader (long "from" <> metavar "POSITION" <> Optparse.value 0 <> showDefault <> help "Inclusive replay start position"))
    <*> option positiveInt32Reader (long "page-size" <> metavar "N" <> Optparse.value 500 <> showDefault <> help "Events fetched per replay page")

resumeOptionsParser :: Parser ResumeOptions
resumeOptionsParser =
  ResumeOptions
    <$> runArgument
    <*> option positiveInt32Reader (long "page-size" <> metavar "N" <> Optparse.value 500 <> showDefault <> help "Events fetched per replay page")

abandonOptionsParser :: Parser AbandonOptions
abandonOptionsParser =
  AbandonOptions
    <$> runArgument
    <*> textOption "code" "CODE" "Stable failure code"
    <*> textOption "detail" "TEXT" "Operator-visible failure detail"

adoptOptionsParser :: Parser AdoptOptions
adoptOptionsParser = AdoptOptions . NonEmpty.fromList <$> some groupArgument

groupArgument :: Parser RebuildGroupId
groupArgument = argument groupReader (metavar "GROUP")

runArgument :: Parser RebuildRunId
runArgument = argument runReader (metavar "RUN_ID")

runIdOption :: Parser RebuildRunId
runIdOption = option runReader (long "run-id" <> metavar "RUN_ID" <> help "Stable identity for this rebuild attempt")

textOption :: String -> String -> String -> Parser Text
textOption name metavarText helpText = Text.pack <$> strOption (long name <> metavar metavarText <> help helpText)

groupReader :: ReadM RebuildGroupId
groupReader = eitherReader (firstShow . mkRebuildGroupId . Text.pack)

runReader :: ReadM RebuildRunId
runReader = eitherReader (firstText . mkRebuildRunId . Text.pack)

firstShow :: (Show err) => Either err value -> Either String value
firstShow = either (Left . show) Right

firstText :: Either Text value -> Either String value
firstText = either (Left . Text.unpack) Right

nonNegativeInt64Reader :: ReadM Int64
nonNegativeInt64Reader = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just value | value >= 0 -> Right value
    _ -> Left "expected a non-negative global position"

positiveInt32Reader :: ReadM Int32
positiveInt32Reader = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just value | value > 0 -> Right value
    _ -> Left "expected a positive 32-bit integer"

isMutation :: Command -> Bool
isMutation = \case
  List -> False
  Preview {} -> False
  Status {} -> False
  Start {} -> True
  Resume {} -> True
  Abandon {} -> True
  Adopt {} -> True

runCommand :: OpsEnv -> ProjectionCatalogOperations -> Command -> IO OpsOutcome
runCommand env operations = \case
  List -> pure (Succeeded (inventoryResult (catalogInventoryReport operations)))
  Preview groupId ->
    runCatalogAction env (previewRegisteredGroupRebuild operations groupId) (Succeeded . registeredPreviewResult)
  Start options
    | env.force ->
        runCatalogAction env (startGroupRebuild operations options.groupId (startRebuildOptions options)) (Succeeded . runResult)
    | otherwise ->
        runCatalogAction env (previewRegisteredGroupRebuild operations options.groupId) $ \preview ->
          PreviewRequired (registeredPreviewResult preview) (forceInvocation env (startArguments options))
  Status runId ->
    runCatalogAction env (inspectGroupRebuild operations runId) (Succeeded . runResult)
  Resume options
    | env.force ->
        runCatalogAction env (resumeGroupRebuild operations options.runId (resumeRebuildOptions options)) (Succeeded . runResult)
    | otherwise ->
        runCatalogAction env (inspectGroupRebuild operations options.runId) $ \report ->
          PreviewRequired (runResult report) (forceInvocation env (resumeArguments options))
  Abandon options
    | env.force ->
        runCatalogAction
          env
          (abandonGroupRebuild operations options.runId (RebuildFailure options.failureCode options.failureDetail))
          (Succeeded . runResult)
    | otherwise ->
        runCatalogAction env (inspectGroupRebuild operations options.runId) $ \report ->
          PreviewRequired (runResult report) (forceInvocation env (abandonArguments options))
  Adopt options
    | env.force ->
        runCatalogAction env (adoptCatalogGroups operations options.groups) (Succeeded . adoptionOutcomeResult)
    | otherwise ->
        runCatalogAction env (Right <$> previewCatalogAdoption operations) $ \report ->
          PreviewRequired (adoptionPreviewResult report) (forceInvocation env (adoptArguments options))

startRebuildOptions :: StartOptions -> RebuildOptions
startRebuildOptions options =
  ( defaultRebuildOptions
      RebuildRequest
        { rebuildRunId = options.runId,
          requestedBy = options.requestedBy,
          requestReason = options.reason,
          replayFrom = options.replayFrom
        }
  )
    { replayPageSize = options.pageSize
    }

resumeRebuildOptions :: ResumeOptions -> RebuildOptions
resumeRebuildOptions options =
  ( defaultRebuildOptions
      RebuildRequest
        { rebuildRunId = options.runId,
          requestedBy = "keiro-ops",
          requestReason = "resume existing rebuild",
          replayFrom = GlobalPosition 0
        }
  )
    { replayPageSize = options.pageSize
    }

runCatalogAction ::
  OpsEnv ->
  Eff '[Store, Error StoreError, IOE] (Either CatalogOpsError value) ->
  (value -> OpsOutcome) ->
  IO OpsOutcome
runCatalogAction env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ case result of
    Left storeError -> Failed (Text.pack (show storeError))
    Right (Left catalogError) -> Failed (Text.pack (show catalogError))
    Right (Right value) -> onSuccess value

inventoryResult :: CatalogInventoryReport -> OpsResult
inventoryResult report =
  OpsResult
    { headers = ["group", "targets", "verifications", "slice_fingerprint", "catalog_fingerprint"],
      rows =
        [ [ rebuildGroupIdText group.rebuildGroupId,
            showText (length group.orderedTargets),
            showText (length group.verifications),
            maybe "" id (lookup group.rebuildGroupId report.groupSlices),
            report.catalogFingerprint
          ]
        | group <- report.inventory.inventoryGroups
        ],
      jsonValue = Aeson.toJSON report
    }

registeredPreviewResult :: RegisteredRebuildPreview -> OpsResult
registeredPreviewResult report =
  OpsResult
    { headers = ["group", "targets", "subscriptions", "dedup_keys", "destructive", "registered", "slice_fingerprint", "registered_slice_matches"],
      rows =
        [ [ rebuildGroupIdText preview.rebuildGroupId,
            showText (length preview.targets),
            showText (length preview.subscriptionResets),
            showText (length preview.dedupResets),
            boolText preview.destructive,
            maybe "no" (const "yes") report.registeredState,
            preview.sliceFingerprint,
            maybe "" boolText report.registeredSliceMatches
          ]
        ],
      jsonValue = Aeson.toJSON report
    }
  where
    preview = report.preview

adoptionPreviewResult :: CatalogAdoptionReport -> OpsResult
adoptionPreviewResult report =
  OpsResult
    { headers = ["group", "state", "stored_slice", "current_slice"],
      rows =
        [ [ rebuildGroupIdText group.rebuildGroupId,
            adoptionStateText group.classification,
            maybe "" id group.storedSlice,
            group.currentSlice
          ]
        | group <- report.groups
        ]
          <> [ [rebuildGroupIdText groupId, "removed", "", ""]
             | groupId <- report.removedGroups
             ]
          <> [["note", adoptionNote, "", ""]],
      jsonValue = Aeson.toJSON report
    }

adoptionOutcomeResult :: CatalogAdoptionOutcome -> OpsResult
adoptionOutcomeResult outcome =
  OpsResult
    { headers = ["group", "status", "slice_fingerprint"],
      rows =
        [ [ rebuildGroupIdText metadata.rebuildGroupId,
            lifecycleStatusText metadata.status,
            metadata.sliceFingerprint
          ]
        | metadata <- outcome.adoptedGroups
        ],
      jsonValue = Aeson.toJSON outcome
    }

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

adoptionNote :: Text
adoptionNote =
  "adoption changes only keiro-owned registration metadata; run 'rebuild start' if the change invalidates persisted rows"

runResult :: CatalogRunReport -> OpsResult
runResult report =
  OpsResult
    { headers = ["run", "group", "status", "group_slice", "captured_head", "sources", "adapters", "verifications"],
      rows =
        [ [ rebuildRunIdText run.rebuildRunId,
            rebuildGroupIdText run.rebuildGroupId,
            Text.pack (show run.runStatus),
            run.groupSliceFingerprint,
            globalPositionText run.capturedHead,
            showText (length run.sources),
            showText (length run.adapters),
            showText (length run.verifications)
          ]
        ],
      jsonValue = Aeson.toJSON report
    }
  where
    run = report.run

startArguments :: StartOptions -> [Text]
startArguments options =
  [ "rebuild",
    "start",
    rebuildGroupIdText options.groupId,
    "--run-id",
    rebuildRunIdText options.runId,
    "--requested-by",
    options.requestedBy,
    "--reason",
    options.reason,
    "--from",
    globalPositionText options.replayFrom,
    "--page-size",
    showText options.pageSize
  ]

resumeArguments :: ResumeOptions -> [Text]
resumeArguments options =
  ["rebuild", "resume", rebuildRunIdText options.runId, "--page-size", showText options.pageSize]

abandonArguments :: AbandonOptions -> [Text]
abandonArguments options =
  [ "rebuild",
    "abandon",
    rebuildRunIdText options.runId,
    "--code",
    options.failureCode,
    "--detail",
    options.failureDetail
  ]

adoptArguments :: AdoptOptions -> [Text]
adoptArguments options =
  "rebuild" : "adopt" : map rebuildGroupIdText (NonEmpty.toList options.groups)

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments = Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags = ["--json" | env.outputMode == Json] <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"

globalPositionText :: GlobalPosition -> Text
globalPositionText (GlobalPosition value) = showText value

boolText :: Bool -> Text
boolText True = "yes"
boolText False = "no"

showText :: (Show value) => value -> Text
showText = Text.pack . show
