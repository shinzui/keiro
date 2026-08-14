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
    VersionedStartOptions (..),
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
import Data.Time (secondsToDiffTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (nonNegativeReader, readBoundedIntegral)
import Keiro.Ops.Render
import Keiro.Prelude ((&), (.~))
import Keiro.Projection.Catalog
  ( CatalogInventory (..),
    InventoryGroup (..),
    ProjectionRevisionId,
    QualifiedTable (..),
    RebuildGroupId,
    TargetGenerationId (..),
    mkProjectionRevisionId,
    mkRebuildGroupId,
    projectionRevisionIdText,
    rebuildGroupIdText,
    targetIdText,
  )
import Keiro.Projection.Catalog.Operations
import Keiro.ReadModel.Rebuild
  ( GroupAdoptionClass (..),
    GroupLifecycleStatus (..),
    GroupRebuildMetadata (..),
    OrphanedRegistration (..),
    RebuildFailure (..),
    RebuildOptions (..),
    RebuildRequest (..),
    RebuildRunId,
    RebuildRunReport (..),
    RegistrationAdoption (..),
    RegistrationAdoptionAction (..),
    VersionedRebuildReport (..),
    VersionedRetiredDropResult (..),
    VersionedRetiredGenerationPreview (..),
    VersionedTargetGeneration (..),
    VersionedTargetMode (..),
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
  | VersionedStart !VersionedStartOptions
  | VersionedStatus !RebuildRunId
  | VersionedResume !RebuildRunId
  | VersionedAbandon !RebuildRunId
  | Retired
  | DropRetired !TargetGenerationId
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

data VersionedStartOptions = VersionedStartOptions
  { groupId :: !RebuildGroupId,
    runId :: !RebuildRunId,
    servingRevisionId :: !ProjectionRevisionId,
    candidateRevisionId :: !ProjectionRevisionId,
    targetMode :: !VersionedTargetMode,
    requestedBy :: !Text,
    reason :: !Text,
    pageSize :: !Int32,
    cutoverThreshold :: !Int64,
    cutoverLockTimeoutMs :: !Int64,
    retentionSeconds :: !Int64
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
        <> command "versioned" (info versionedCommandParser (progDesc "Operate schema-versioned online rebuilds"))
        <> command "retired" (info (pure Retired) (progDesc "List retired target generations"))
        <> command "drop-retired" (info (DropRetired <$> generationArgument) (progDesc "Preview or drop one retired target generation"))
    )

versionedCommandParser :: Parser Command
versionedCommandParser =
  hsubparser
    ( command "start" (info (VersionedStart <$> versionedStartOptionsParser) (progDesc "Preview or start an online versioned rebuild"))
        <> command "status" (info (VersionedStatus <$> runArgument) (progDesc "Inspect an online versioned rebuild"))
        <> command "resume" (info (VersionedResume <$> runArgument) (progDesc "Preview or advance one durable online rebuild phase"))
        <> command "abandon" (info (VersionedAbandon <$> runArgument) (progDesc "Preview or abandon an online versioned rebuild"))
    )

versionedStartOptionsParser :: Parser VersionedStartOptions
versionedStartOptionsParser =
  VersionedStartOptions
    <$> groupArgument
    <*> runIdOption
    <*> option revisionReader (long "serving-revision" <> metavar "REVISION")
    <*> option revisionReader (long "candidate-revision" <> metavar "REVISION")
    <*> option targetModeReader (long "target-mode" <> metavar "application|clone" <> Optparse.value ApplicationProvisioned <> showDefaultWith (const "application"))
    <*> textOption "requested-by" "IDENTITY" "Operator or automation identity"
    <*> textOption "reason" "TEXT" "Reason for this rebuild"
    <*> option positiveInt32Reader (long "page-size" <> metavar "N" <> Optparse.value 500 <> showDefault)
    <*> option nonNegativeInt64Reader (long "cutover-threshold" <> metavar "POSITIONS" <> Optparse.value 1000 <> showDefault)
    <*> option positiveInt64Reader (long "lock-timeout-ms" <> metavar "MILLISECONDS" <> Optparse.value 5000 <> showDefault)
    <*> option positiveInt64Reader (long "retention-seconds" <> metavar "SECONDS" <> Optparse.value 3600 <> showDefault)

startOptionsParser :: Parser StartOptions
startOptionsParser =
  StartOptions
    <$> groupArgument
    <*> runIdOption
    <*> textOption "requested-by" "IDENTITY" "Operator or automation identity"
    <*> textOption "reason" "TEXT" "Reason for this rebuild"
    <*> (GlobalPosition <$> option (nonNegativeReader "expected a non-negative global position") (long "from" <> metavar "POSITION" <> Optparse.value 0 <> showDefault <> help "Inclusive replay start position"))
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

generationArgument :: Parser TargetGenerationId
generationArgument = argument generationReader (metavar "GENERATION_ID")

textOption :: String -> String -> String -> Parser Text
textOption name metavarText helpText = Text.pack <$> strOption (long name <> metavar metavarText <> help helpText)

groupReader :: ReadM RebuildGroupId
groupReader = eitherReader (firstShow . mkRebuildGroupId . Text.pack)

runReader :: ReadM RebuildRunId
runReader = eitherReader (firstText . mkRebuildRunId . Text.pack)

revisionReader :: ReadM ProjectionRevisionId
revisionReader = eitherReader (firstShow . mkProjectionRevisionId . Text.pack)

generationReader :: ReadM TargetGenerationId
generationReader = eitherReader $ \raw ->
  maybe (Left "expected a UUID target generation id") (Right . TargetGenerationId) (UUID.fromString raw)

targetModeReader :: ReadM VersionedTargetMode
targetModeReader = eitherReader $ \case
  "application" -> Right ApplicationProvisioned
  "clone" -> Right RestrictedClone
  _ -> Left "expected application or clone"

firstShow :: (Show err) => Either err value -> Either String value
firstShow = either (Left . show) Right

firstText :: Either Text value -> Either String value
firstText = either (Left . Text.unpack) Right

positiveInt32Reader :: ReadM Int32
positiveInt32Reader = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just value | value > 0 -> Right value
    _ -> Left "expected a positive 32-bit integer"

positiveInt64Reader :: ReadM Int64
positiveInt64Reader = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just value | value > 0 -> Right value
    _ -> Left "expected a positive 64-bit integer"

nonNegativeInt64Reader :: ReadM Int64
nonNegativeInt64Reader = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just value | value >= 0 -> Right value
    _ -> Left "expected a non-negative 64-bit integer"

isMutation :: Command -> Bool
isMutation = \case
  List -> False
  Preview {} -> False
  Status {} -> False
  Start {} -> True
  Resume {} -> True
  Abandon {} -> True
  Adopt {} -> True
  VersionedStart {} -> True
  VersionedStatus {} -> False
  VersionedResume {} -> True
  VersionedAbandon {} -> True
  Retired -> False
  DropRetired {} -> True

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
        runCatalogAction env (previewCatalogAdoption operations options.groups) $ \report ->
          PreviewRequired (adoptionPreviewResult report) (forceInvocation env (adoptArguments options))
  VersionedStart options
    | env.force ->
        runCatalogAction
          env
          (startVersionedGroupRebuild operations (catalogVersionedStartOptions options))
          (Succeeded . versionedRunResult)
    | otherwise ->
        runCatalogAction env (previewRegisteredGroupRebuild operations options.groupId) $ \preview ->
          PreviewRequired
            (registeredPreviewResult preview)
            (forceInvocation env (versionedStartArguments options))
  VersionedStatus runId ->
    runCatalogAction env (inspectVersionedGroupRebuild operations runId) (Succeeded . versionedRunResult)
  VersionedResume runId
    | env.force ->
        runCatalogAction env (resumeVersionedGroupRebuild operations runId) (Succeeded . versionedRunResult)
    | otherwise ->
        runCatalogAction env (inspectVersionedGroupRebuild operations runId) $ \report ->
          PreviewRequired (versionedRunResult report) (forceInvocation env (versionedResumeArguments runId))
  VersionedAbandon runId
    | env.force ->
        runCatalogAction env (abandonVersionedGroupRebuild operations runId) (Succeeded . versionedRunResult)
    | otherwise ->
        runCatalogAction env (inspectVersionedGroupRebuild operations runId) $ \report ->
          PreviewRequired (versionedRunResult report) (forceInvocation env (versionedAbandonArguments runId))
  Retired ->
    runCatalogValue env (listRetiredGenerations operations) (Succeeded . retiredGenerationsResult)
  DropRetired generationId
    | env.force ->
        runCatalogAction env (dropRetiredGeneration operations generationId) (Succeeded . retiredDropResult)
    | otherwise ->
        runCatalogAction env (previewRetiredGenerationDrop operations generationId) $ \report ->
          PreviewRequired
            (retiredDropResult report)
            (forceInvocation env (dropRetiredArguments generationId))

catalogVersionedStartOptions :: VersionedStartOptions -> CatalogVersionedStartOptions
catalogVersionedStartOptions options =
  CatalogVersionedStartOptions
    { rebuildRunId = options.runId,
      rebuildGroupId = options.groupId,
      servingRevisionId = options.servingRevisionId,
      candidateRevisionId = options.candidateRevisionId,
      targetMode = options.targetMode,
      replayPageSize = options.pageSize,
      cutoverThreshold = options.cutoverThreshold,
      cutoverLockTimeoutMs = options.cutoverLockTimeoutMs,
      retentionDuration = secondsToDiffTime (fromIntegral options.retentionSeconds),
      requestedBy = options.requestedBy,
      requestReason = options.reason
    }

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
    & #replayPageSize
    .~ options.pageSize

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
    & #replayPageSize
    .~ options.pageSize

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

runCatalogValue ::
  OpsEnv ->
  Eff '[Store, Error StoreError, IOE] value ->
  (value -> OpsOutcome) ->
  IO OpsOutcome
runCatalogValue env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ either (Failed . Text.pack . show) onSuccess result

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
    { headers = ["name", "kind", "state", "scope", "stored", "current"],
      rows =
        [ [ rebuildGroupIdText group.rebuildGroupId,
            "group",
            adoptionStateText group.classification,
            adoptionScopeText group.inScope,
            maybe "" id group.storedSlice,
            group.currentSlice
          ]
        | group <- report.groups
        ]
          <> [ [rebuildGroupIdText groupId, "group", "removed", "skip", "", ""]
             | groupId <- report.removedGroups
             ]
          <> [ [ registration.registryName,
                 "registration",
                 registrationActionText registration.action,
                 adoptionScopeText registration.inScope,
                 "",
                 ""
               ]
             | registration <- report.registrations
             ]
          <> [ [ orphan.registryName,
                 "registration",
                 "orphaned-old-name",
                 adoptionScopeText orphan.inScope,
                 rebuildGroupIdText orphan.boundGroupId,
                 ""
               ]
             | orphan <- report.orphanedRegistrations
             ]
          <> [["note", adoptionNote, "", "", "", ""]]
          <> warningRows,
      jsonValue = Aeson.toJSON report
    }
  where
    warningRows =
      [ [ "note",
          "warning: out-of-scope groups still drift and will fail startup registration until adopted: "
            <> renderGroupIds report.outOfScopeChangedGroups,
          "",
          "",
          "",
          ""
        ]
      | not (null report.outOfScopeChangedGroups)
      ]
        <> [ [ "note",
               "warning: requested groups not yet registered; --force will refuse: "
                 <> renderGroupIds requestedNewGroups,
               "",
               "",
               "",
               ""
             ]
           | not (null requestedNewGroups)
           ]
    requestedNewGroups =
      [ group.rebuildGroupId
      | group <- report.groups,
        group.inScope,
        group.classification == AdoptionNew
      ]

adoptionOutcomeResult :: CatalogAdoptionOutcome -> OpsResult
adoptionOutcomeResult outcome =
  OpsResult
    { headers = ["name", "kind", "outcome", "detail"],
      rows =
        [ [ rebuildGroupIdText metadata.rebuildGroupId,
            "group",
            lifecycleStatusText metadata.status,
            metadata.sliceFingerprint
          ]
        | metadata <- outcome.adoptedGroups
        ]
          <> [ [ registration.registryName,
                 "registration",
                 registrationOutcomeText registration.action,
                 rebuildGroupIdText registration.rebuildGroupId
               ]
             | registration <- outcome.registrationOutcomes
             ]
          <> [ [ orphan.registryName,
                 "registration",
                 "orphaned-old-name",
                 rebuildGroupIdText orphan.boundGroupId
               ]
             | orphan <- outcome.removedOrphans
             ],
      jsonValue = Aeson.toJSON outcome
    }

adoptionScopeText :: Bool -> Text
adoptionScopeText True = "adopt"
adoptionScopeText False = "skip"

registrationActionText :: RegistrationAdoptionAction -> Text
registrationActionText = \case
  RegistrationUpdate -> "update"
  RegistrationInsert -> "insert"

registrationOutcomeText :: RegistrationAdoptionAction -> Text
registrationOutcomeText = \case
  RegistrationUpdate -> "adopted"
  RegistrationInsert -> "inserted"

renderGroupIds :: [RebuildGroupId] -> Text
renderGroupIds = Text.intercalate ", " . map rebuildGroupIdText

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

versionedRunResult :: CatalogVersionedRunReport -> OpsResult
versionedRunResult report =
  OpsResult
    { headers = ["run", "group", "phase", "serving_revision", "candidate_revision", "epoch", "captured_head", "sources", "serving_generations", "candidate_generations"],
      rows =
        [ [ rebuildRunIdText run.rebuildRunId,
            rebuildGroupIdText run.rebuildGroupId,
            showText run.phase,
            projectionRevisionIdText run.servingRevisionId,
            projectionRevisionIdText run.candidateRevisionId,
            showText run.servingEpoch,
            globalPositionText run.capturedHead,
            showText (length run.sources),
            showText (length run.servingGenerations),
            showText (length run.candidateGenerations)
          ]
        ],
      jsonValue = Aeson.toJSON report
    }
  where
    run = report.run

retiredGenerationsResult :: CatalogRetiredGenerationsReport -> OpsResult
retiredGenerationsResult report =
  OpsResult
    { headers = ["generation", "group", "target", "revision", "table", "oid", "lifecycle"],
      rows = map generationRow report.generations,
      jsonValue = Aeson.toJSON report
    }

retiredDropResult :: CatalogRetiredDropReport -> OpsResult
retiredDropResult report =
  OpsResult
    { headers = ["generation", "group", "target", "revision", "table", "droppable", "blockers"],
      rows =
        case report of
          CatalogRetiredDropPreview preview ->
            [ generationSummaryRow preview.generation
                <> [ boolText preview.droppable,
                     Text.intercalate
                       ","
                       ( maybe [] (\runId -> ["active-run:" <> rebuildRunIdText runId]) preview.activeRunId
                           <> map ("read-contract:" <>) preview.supportedReadContracts
                           <> map ("postgres-dependency:" <>) preview.externalDependencies
                       )
                   ]
            ]
          CatalogRetiredDropOutcome outcome ->
            [ generationSummaryRow outcome.generation
                <> ["yes", if outcome.alreadyDropped then "already-dropped" else "dropped"]
            ],
      jsonValue = Aeson.toJSON report
    }

generationRow :: VersionedTargetGeneration -> [Text]
generationRow generation =
  generationSummaryRow generation
    <> [showText generation.relationOid, showText generation.lifecycle]

generationSummaryRow :: VersionedTargetGeneration -> [Text]
generationSummaryRow generation =
  [ generationIdText generation.generationId,
    rebuildGroupIdText generation.rebuildGroupId,
    targetIdText generation.targetId,
    projectionRevisionIdText generation.revisionId,
    generation.physicalTable.schemaName <> "." <> generation.physicalTable.tableName
  ]

generationIdText :: TargetGenerationId -> Text
generationIdText (TargetGenerationId value) = UUID.toText value

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

versionedStartArguments :: VersionedStartOptions -> [Text]
versionedStartArguments options =
  [ "rebuild",
    "versioned",
    "start",
    rebuildGroupIdText options.groupId,
    "--run-id",
    rebuildRunIdText options.runId,
    "--serving-revision",
    projectionRevisionIdText options.servingRevisionId,
    "--candidate-revision",
    projectionRevisionIdText options.candidateRevisionId,
    "--target-mode",
    case options.targetMode of
      ApplicationProvisioned -> "application"
      RestrictedClone -> "clone",
    "--requested-by",
    options.requestedBy,
    "--reason",
    options.reason,
    "--page-size",
    showText options.pageSize,
    "--cutover-threshold",
    showText options.cutoverThreshold,
    "--lock-timeout-ms",
    showText options.cutoverLockTimeoutMs,
    "--retention-seconds",
    showText options.retentionSeconds
  ]

versionedResumeArguments :: RebuildRunId -> [Text]
versionedResumeArguments runId =
  ["rebuild", "versioned", "resume", rebuildRunIdText runId]

versionedAbandonArguments :: RebuildRunId -> [Text]
versionedAbandonArguments runId =
  ["rebuild", "versioned", "abandon", rebuildRunIdText runId]

dropRetiredArguments :: TargetGenerationId -> [Text]
dropRetiredArguments generationId =
  ["rebuild", "drop-retired", generationIdText generationId]

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
