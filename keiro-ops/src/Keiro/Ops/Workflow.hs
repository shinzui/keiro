module Keiro.Ops.Workflow
  ( AwakeableCommand (..),
    Command (..),
    InspectionCommand (..),
    GcOptions (..),
    InspectOptions (..),
    ListOptions (..),
    PayloadArg (..),
    ResumeHook,
    ResumeOptions (..),
    WorkflowRef (..),
    commandParser,
    validateCommand,
    commandParserWithResume,
    isMutation,
    runCommand,
    runCommandWithResume,
    headerOutcome,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (NominalDiffTime, UTCTime, defaultTimeLocale, getCurrentTime, parseTimeM)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Inspection.Cursor (InspectionCursor, maxCursorBytes)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (cursorReader, durationReader, nonNegativeReader, positiveIntReader)
import Keiro.Ops.Render
import Keiro.Workflow.Awakeable (AwakeableId (..), cancelAwakeable, signalAwakeable)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Child.Schema qualified as Child
import Keiro.Workflow.Gc qualified as Gc
import Keiro.Workflow.Inspection qualified as Inspection
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Resume
  ( ResumeSummary (..),
    WorkflowRegistry,
    WorkflowResumeOptions,
    resumeWorkflowsOnceUpTo,
  )
import Keiro.Workflow.Schema qualified as WorkflowSchema
import Keiro.Workflow.Types
  ( WorkflowId (..),
    WorkflowName (..),
  )
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Options.Applicative hiding (action, value)
import Options.Applicative qualified as Optparse

data WorkflowRef = WorkflowRef
  { workflowName :: !Text,
    workflowId :: !Text
  }
  deriving stock (Eq, Show)

data ListOptions = ListOptions
  { statusFilters :: ![Instance.WorkflowStatus],
    workflowNameFilter :: !(Maybe Text),
    afterKey :: !(Maybe (Text, Text)),
    limit :: !Int
  }
  deriving stock (Eq, Show)

data InspectOptions = InspectOptions
  { target :: !WorkflowRef,
    generation :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

data PayloadArg = PayloadArg
  { rawPayload :: !Text,
    payload :: !Value
  }
  deriving stock (Eq, Show)

data GcOptions = GcOptions
  { retention :: !NominalDiffTime,
    batchSize :: !Int
  }
  deriving stock (Eq, Show)

data ResumeOptions = ResumeOptions
  { limit :: !Int
  }
  deriving stock (Eq, Show)

type ResumeHook =
  ( WorkflowRegistry '[Store, Error StoreError, IOE],
    WorkflowResumeOptions
  )

data AwakeableCommand
  = AwakeableShow !UUID
  | AwakeableSignal !UUID !PayloadArg
  | AwakeableCancel !UUID
  deriving stock (Eq, Show)

data Command
  = List !ListOptions
  | Inspect !InspectionCommand
  | Show !WorkflowRef
  | Steps !InspectOptions
  | Journal !InspectOptions
  | Awakeable !AwakeableCommand
  | Cancel !WorkflowRef
  | Resurrect !WorkflowRef
  | ReleaseLease !WorkflowRef
  | GcRunOnce !GcOptions
  | ResumeOnce !ResumeOptions
  deriving stock (Eq, Show)

data InspectionCommand
  = InspectList !Inspection.WorkflowListQuery
  | InspectHeader !WorkflowRef
  | InspectJournal !WorkflowRef !Inspection.DetailPageQuery
  | InspectSteps !WorkflowRef !Inspection.DetailPageQuery
  | InspectChildren !WorkflowRef !Inspection.OwnerPageQuery
  | InspectAwakeables !WorkflowRef !Inspection.OwnerPageQuery
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser = commandParserWithResume False

commandParserWithResume :: Bool -> Parser Command
commandParserWithResume includeResume =
  hsubparser
    ( command "list" (info (List <$> listOptionsParser) (progDesc "List workflow instances with stable keyset paging"))
        <> command "inspect" (info (Inspect <$> inspectionParser) (progDesc "Bounded workflow observation pages"))
        <> command "show" (info (Show <$> workflowRefParser) (progDesc "Show an instance, its children, and its awakeables"))
        <> command "steps" (info (Steps <$> inspectOptionsParser) (progDesc "Show the derived step index for one generation"))
        <> command "journal" (info (Journal <$> inspectOptionsParser) (progDesc "Decode one workflow journal generation in order"))
        <> command "awakeable" (info (Awakeable <$> awakeableCommandParser) (progDesc "Inspect, signal, or cancel an awakeable"))
        <> command "cancel" (info (Cancel <$> workflowRefParser) (progDesc "Preview or cancel a workflow at its next durable boundary"))
        <> command "resurrect" (info (Resurrect <$> workflowRefParser) (progDesc "Preview or resurrect a terminally failed workflow"))
        <> command "lease" (info leaseCommandParser (progDesc "Operate workflow instance leases"))
        <> command "gc" (info gcCommandParser (progDesc "Preview or run one workflow garbage-collection pass"))
        <> resumeCommand
    )
  where
    resumeCommand
      | includeResume =
          command
            "resume-once"
            ( info
                (ResumeOnce . ResumeOptions <$> option positiveIntReader (long "limit" <> metavar "N" <> Optparse.value 100 <> showDefault <> help "Maximum workflow instances to advance"))
                (progDesc "Preview or run one bounded application-registry resume pass")
            )
      | otherwise = mempty

listOptionsParser :: Parser ListOptions
listOptionsParser =
  ListOptions
    <$> many
      ( option
          workflowStatusReader
          (long "status" <> metavar "STATUS" <> help "Exact status; repeat to match more than one")
      )
    <*> optional (Text.pack <$> strOption (long "name" <> metavar "NAME" <> help "Exact workflow definition name"))
    <*> optional
      ( (,)
          <$> (Text.pack <$> strOption (long "after" <> metavar "NAME" <> help "Keyset cursor workflow name; followed by ID"))
          <*> (Text.pack <$> argument str (metavar "ID"))
      )
    <*> option positiveIntReader (long "limit" <> metavar "N" <> Optparse.value 100 <> showDefault <> help "Maximum rows to return")

inspectOptionsParser :: Parser InspectOptions
inspectOptionsParser =
  InspectOptions
    <$> workflowRefParser
    <*> optional (option (nonNegativeReader "expected a non-negative generation") (long "generation" <> metavar "N" <> help "Journal generation; defaults to current"))

inspectionParser :: Parser InspectionCommand
inspectionParser =
  hsubparser
    ( command "list" (info (InspectList <$> listQuery) (progDesc "Page workflow instances"))
        <> command "header" (info (InspectHeader <$> workflowRefParser) (progDesc "Read only the instance header"))
        <> command "journal" (info (InspectJournal <$> workflowRefParser <*> detailQuery) (progDesc "Page one journal generation"))
        <> command "steps" (info (InspectSteps <$> workflowRefParser <*> detailQuery) (progDesc "Page one generation's step index"))
        <> command "children" (info (InspectChildren <$> workflowRefParser <*> ownerQuery) (progDesc "Page child links"))
        <> command "awakeables" (info (InspectAwakeables <$> workflowRefParser <*> ownerQuery) (progDesc "Page allocated external promises"))
    )
  where
    limit = option positiveIntReader (long "limit" <> metavar "N" <> Optparse.value 100 <> help "Page size, at most 500")
    after = optional (option cursorReader (long "after" <> metavar "CURSOR"))
    detailQuery =
      Inspection.DetailPageQuery
        <$> optional (option (nonNegativeReader "expected a non-negative generation") (long "generation" <> metavar "N"))
        <*> limit
        <*> after
    ownerQuery = Inspection.OwnerPageQuery <$> limit <*> after
    listQuery =
      Inspection.WorkflowListQuery
        <$> (NonEmpty.nonEmpty <$> many (option statusClassReader (long "status-class" <> metavar "CLASS")))
        <*> optional (Text.pack <$> strOption (long "workflow-name" <> metavar "NAME"))
        <*> optional (option utcReader (long "created-since" <> metavar "UTC"))
        <*> optional (option utcReader (long "created-before" <> metavar "UTC"))
        <*> optional (option utcReader (long "updated-since" <> metavar "UTC"))
        <*> optional (option utcReader (long "updated-before" <> metavar "UTC"))
        <*> option orderingReader (long "ordering" <> metavar "key|created_desc" <> Optparse.value Inspection.ByKey)
        <*> limit
        <*> after
    statusClassReader = eitherReader $ \raw -> maybe (Left "expected running, retrying, sleeping, awaiting, completed, cancelled, or failed") Right (Inspection.statusClassFromText (Text.pack raw))
    orderingReader = eitherReader $ \case "key" -> Right Inspection.ByKey; "created_desc" -> Right Inspection.ByCreatedDesc; _ -> Left "expected key or created_desc"
    utcReader = eitherReader $ \raw -> maybe (Left "expected a UTC timestamp such as 2026-10-20T01:02:03Z") Right (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" raw)

workflowRefParser :: Parser WorkflowRef
workflowRefParser =
  WorkflowRef
    <$> (Text.pack <$> argument str (metavar "NAME"))
    <*> (Text.pack <$> argument str (metavar "ID"))

awakeableCommandParser :: Parser AwakeableCommand
awakeableCommandParser =
  hsubparser
    ( command "show" (info (AwakeableShow <$> uuidArgument) (progDesc "Show one awakeable"))
        <> command
          "signal"
          ( info
              (AwakeableSignal <$> uuidArgument <*> option payloadReader (long "payload" <> metavar "JSON" <> help "JSON completion payload"))
              (progDesc "Preview or signal a pending awakeable")
          )
        <> command "cancel" (info (AwakeableCancel <$> uuidArgument) (progDesc "Preview or cancel a pending awakeable"))
    )

leaseCommandParser :: Parser Command
leaseCommandParser =
  hsubparser
    (command "release" (info (ReleaseLease <$> workflowRefParser) (progDesc "Preview or forcibly release an instance lease")))

gcCommandParser :: Parser Command
gcCommandParser =
  hsubparser
    ( command
        "run-once"
        ( info
            ( GcRunOnce
                <$> ( GcOptions
                        <$> option durationReader (long "retention" <> metavar "DURATION" <> help "Minimum terminal age, such as 30d or 12h")
                        <*> option positiveIntReader (long "batch" <> metavar "N" <> Optparse.value 100 <> showDefault <> help "Maximum workflows to collect")
                    )
            )
            (progDesc "Preview or run one bounded garbage-collection pass")
        )
    )

uuidArgument :: Parser UUID
uuidArgument = argument uuidReader (metavar "UUID")

uuidReader :: ReadM UUID
uuidReader = eitherReader $ \raw ->
  maybe (Left "expected a UUID") Right (UUID.fromString raw)

payloadReader :: ReadM PayloadArg
payloadReader = eitherReader $ \raw ->
  let rawText = Text.pack raw
   in case Aeson.eitherDecodeStrict' (Text.Encoding.encodeUtf8 rawText) of
        Left err -> Left ("invalid JSON payload: " <> err)
        Right value -> Right (PayloadArg rawText value)

workflowStatusReader :: ReadM Instance.WorkflowStatus
workflowStatusReader = eitherReader $ \case
  "running" -> Right Instance.WfRunning
  "suspended" -> Right Instance.WfSuspended
  "completed" -> Right Instance.WfCompleted
  "cancelled" -> Right Instance.WfCancelled
  "failed" -> Right Instance.WfFailed
  _ -> Left "expected one of: running, suspended, completed, cancelled, failed"

isMutation :: Command -> Bool
isMutation = \case
  Inspect {} -> False
  List {} -> False
  Show {} -> False
  Steps {} -> False
  Journal {} -> False
  Awakeable (AwakeableShow {}) -> False
  Awakeable (AwakeableSignal {}) -> True
  Awakeable (AwakeableCancel {}) -> True
  Cancel {} -> True
  Resurrect {} -> True
  ReleaseLease {} -> True
  GcRunOnce {} -> True
  ResumeOnce {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand = runCommandWithResume Nothing

runCommandWithResume :: Maybe ResumeHook -> OpsEnv -> Command -> IO OpsOutcome
runCommandWithResume resumeHook env = \case
  Inspect inspection -> runInspection env inspection
  List options -> runList env options
  Show ref -> runShow env ref
  Steps options -> runSteps env options
  Journal options -> runJournal env options
  Awakeable awakeableCommand -> runAwakeable env awakeableCommand
  Cancel ref -> runCancel env ref
  Resurrect ref -> runResurrect env ref
  ReleaseLease ref -> runReleaseLease env ref
  GcRunOnce options -> runGc env options
  ResumeOnce options -> runResumeOnce resumeHook env options

runInspection :: OpsEnv -> InspectionCommand -> IO OpsOutcome
runInspection env = \case
  InspectList query -> page (Inspection.listWorkflowInstancesPage query)
  InspectHeader ref -> runAction env (Instance.lookupInstance (refName ref) (refId ref)) (headerOutcome ref)
  InspectJournal ref query -> page (Inspection.readWorkflowJournalPage (refName ref) (refId ref) query)
  InspectSteps ref query -> page (Inspection.loadStepIndexPage (refName ref) (refId ref) query)
  InspectChildren ref query -> page (Inspection.listWorkflowChildrenPage (refName ref) (refId ref) query)
  InspectAwakeables ref query -> page (Inspection.listWorkflowAwakeablesPage (refName ref) (refId ref) query)
  where
    page :: (Aeson.ToJSON a) => Eff '[Store, Error StoreError, IOE] (Either Inspection.InspectionError a) -> IO OpsOutcome
    page action = runAction env action (either inspectionFailure (Succeeded . jsonResult . Aeson.toJSON))
    jsonResult value = OpsResult ["result"] [[jsonText value]] value

-- | Canonical CLI and HTTP outcome for a freshly observed header.
headerOutcome :: WorkflowRef -> Maybe Instance.WorkflowInstanceRow -> OpsOutcome
headerOutcome ref = \case
  Nothing -> Failed (workflowLabel ref <> " was not found")
  Just row ->
    let value = Inspection.instanceToJson row
     in Succeeded (OpsResult ["result"] [[jsonText value]] value)

inspectionFailure :: Inspection.InspectionError -> OpsOutcome
inspectionFailure err = uncurry InspectionFailed (inspectionError err)

inspectionError :: Inspection.InspectionError -> (Text, Text)
inspectionError err = (code, message)
  where
    message = case err of
      Inspection.InspectionWorkLimitExceeded -> "workflow inspection exceeds " <> Text.pack (show Inspection.maxWideWorkflowCandidates) <> " wide-key candidates or " <> Text.pack (show Inspection.maxWideWorkflowKeyBytes) <> " key bytes"
      Inspection.CursorResultTooLarge -> "the continuation key exceeds the " <> Text.pack (show maxCursorBytes) <> "-byte cursor limit"
      _ -> Text.pack (show err)
    code = case err of
      Inspection.InvalidPageSize _ -> "invalid_page_size"
      Inspection.InvalidCursor _ -> "invalid_cursor"
      Inspection.CursorGenerationMismatch _ _ -> "cursor_generation_mismatch"
      Inspection.CursorResultTooLarge -> "inspection_result_too_large"
      Inspection.InspectionWorkLimitExceeded -> "inspection_result_too_large"

-- | Validate the owning library's inspection grammar without any SQL.
validateCommand :: Command -> Either (Text, Text) ()
validateCommand (Inspect command) = either (Left . inspectionError) Right $ case command of
  InspectList query -> Inspection.validateWorkflowListQuery query
  InspectHeader _ -> Right ()
  InspectJournal ref query -> Inspection.validateJournalQuery (refName ref) (refId ref) query
  InspectSteps ref query -> Inspection.validateStepQuery (refName ref) (refId ref) query
  InspectChildren ref query -> Inspection.validateChildQuery (refName ref) (refId ref) query
  InspectAwakeables ref query -> Inspection.validateAwakeableQuery (refName ref) (refId ref) query
validateCommand _ = Right ()

runResumeOnce :: Maybe ResumeHook -> OpsEnv -> ResumeOptions -> IO OpsOutcome
runResumeOnce Nothing _ _ =
  pure (Failed "workflow resume hook is not mounted")
runResumeOnce (Just (registry, resumeOptions)) env options
  | not env.force = do
      now <- getCurrentTime
      runAction env (take options.limit <$> WorkflowSchema.findUnfinishedWorkflowIds now) $ \candidates ->
        PreviewRequired
          (resumePreviewResult options.limit candidates)
          (forceInvocation env ["wf", "resume-once", "--limit", Text.pack (show options.limit)])
  | otherwise =
      runAction
        env
        (resumeWorkflowsOnceUpTo options.limit resumeOptions registry)
        (Succeeded . resumeSummaryResult)

resumePreviewResult :: Int -> [(Text, Text)] -> OpsResult
resumePreviewResult limit candidates =
  OpsResult
    { headers = ["name", "id"],
      rows = [[name, workflowId] | (workflowId, name) <- candidates],
      jsonValue =
        object
          [ "preview" .= True,
            "limit" .= limit,
            "candidates"
              .= [ object ["workflow_name" .= name, "workflow_id" .= workflowId]
                 | (workflowId, name) <- candidates
                 ]
          ]
    }

resumeSummaryResult :: ResumeSummary -> OpsResult
resumeSummaryResult summary =
  OpsResult
    { headers = ["discovered", "resumed", "completed", "suspended", "unknown", "failed", "errors", "lease_skipped", "advanced", "paced", "sleep_due", "unregistered"],
      rows =
        [ map (Text.pack . show) counts
            <> [renderUnregistered summary.unregisteredNames]
        ],
      jsonValue =
        object
          [ "discovered" .= summary.discovered,
            "resumed" .= summary.resumed,
            "completed" .= summary.completed,
            "still_suspended" .= summary.stillSuspended,
            "unknown_name" .= summary.unknownName,
            "failed" .= summary.failed,
            "transient_errors" .= summary.transientErrors,
            "lease_skipped" .= summary.leaseSkipped,
            "advanced" .= summary.advanced,
            "paced" .= summary.paced,
            "sleep_due" .= summary.sleepDue,
            "unregistered_names" .= Set.toAscList summary.unregisteredNames
          ]
    }
  where
    counts =
      [ summary.discovered,
        summary.resumed,
        summary.completed,
        summary.stillSuspended,
        summary.unknownName,
        summary.failed,
        summary.transientErrors,
        summary.leaseSkipped,
        summary.advanced,
        summary.paced,
        summary.sleepDue
      ]
    renderUnregistered names
      | Set.null names = "-"
      | otherwise = Text.intercalate "," (Set.toAscList names)

runList :: OpsEnv -> ListOptions -> IO OpsOutcome
runList env options =
  runAction env (Instance.listWorkflowInstances filters) (Succeeded . workflowListResult)
  where
    filters =
      Instance.WorkflowInstanceFilter
        (NonEmpty.nonEmpty options.statusFilters)
        options.workflowNameFilter
        options.afterKey
        options.limit

runShow :: OpsEnv -> WorkflowRef -> IO OpsOutcome
runShow env ref = runAction env action $ \case
  Left err -> inspectionFailure err
  Right Nothing -> Failed (workflowLabel ref <> " was not found")
  Right (Just details) -> Succeeded (workflowDetailsResult details)
  where
    action = do
      instanceRow <- Instance.lookupInstance (refName ref) (refId ref)
      case instanceRow of
        Nothing -> pure (Right Nothing)
        Just row -> do
          children <- drainPages (\cursor -> Inspection.listWorkflowChildrenPage (refName ref) (refId ref) (Inspection.OwnerPageQuery 500 cursor)) (.items) (.nextCursor)
          awakeables <- drainPages (\cursor -> Inspection.listWorkflowAwakeablesPage (refName ref) (refId ref) (Inspection.OwnerPageQuery 500 cursor)) (.items) (.nextCursor)
          pure ((\cs as -> Just (row, cs, as)) <$> children <*> awakeables)

runSteps :: OpsEnv -> InspectOptions -> IO OpsOutcome
runSteps env options = runAction env action $ \(gen, rows) -> either inspectionFailure (Succeeded . stepsResult gen) rows
  where
    action = do
      gen <- resolveGeneration options
      rows <- drainPages (\cursor -> Inspection.loadStepIndexPage (refName options.target) (refId options.target) (Inspection.DetailPageQuery (Just gen) 500 cursor)) (.items) (.nextCursor)
      pure (gen, rows)

runJournal :: OpsEnv -> InspectOptions -> IO OpsOutcome
runJournal env options = runAction env action $ \(gen, rows) -> either inspectionFailure (Succeeded . journalResult gen) rows
  where
    action = do
      gen <- resolveGeneration options
      rows <- drainPages (\cursor -> Inspection.readWorkflowJournalPage (refName options.target) (refId options.target) (Inspection.DetailPageQuery (Just gen) 500 cursor)) (.items) (.nextCursor)
      pure (gen, rows)

-- Compatibility commands intentionally drain pages. Bounded inspect commands
-- above invoke one library page only, and the HTTP deadline still bounds these.
drainPages :: (Maybe InspectionCursor -> Eff es (Either Inspection.InspectionError page)) -> (page -> [a]) -> (page -> Maybe InspectionCursor) -> Eff es (Either Inspection.InspectionError [a])
drainPages load items next = go Nothing []
  where
    go cursor chunks = do
      result <- load cursor
      case result of
        Left err -> pure (Left err)
        Right page -> case next page of
          Nothing -> pure (Right (concat (reverse (items page : chunks))))
          Just token -> go (Just token) (items page : chunks)

runAwakeable :: OpsEnv -> AwakeableCommand -> IO OpsOutcome
runAwakeable env = \case
  AwakeableShow awakeableId ->
    runAction env (Awakeable.lookupAwakeable awakeableId) $ \case
      Nothing -> Failed ("awakeable " <> UUID.toText awakeableId <> " was not found")
      Just row -> Succeeded (awakeableResult row)
  AwakeableSignal awakeableId payloadArg
    | not env.force ->
        runAction env (Awakeable.lookupAwakeable awakeableId) $ \row ->
          PreviewRequired
            (awakeablePreviewResult "signal" awakeableId row)
            (forceInvocation env ["wf", "awakeable", "signal", UUID.toText awakeableId, "--payload", payloadArg.rawPayload])
    | otherwise ->
        runAction env action $ \(transitioned, row) ->
          Succeeded (awakeableMutationResult "signal" awakeableId transitioned row)
    where
      action = do
        transitioned <- signalAwakeable (AwakeableId awakeableId) payloadArg.payload
        row <- Awakeable.lookupAwakeable awakeableId
        pure (transitioned, row)
  AwakeableCancel awakeableId
    | not env.force ->
        runAction env (Awakeable.lookupAwakeable awakeableId) $ \row ->
          PreviewRequired
            (awakeablePreviewResult "cancel" awakeableId row)
            (forceInvocation env ["wf", "awakeable", "cancel", UUID.toText awakeableId])
    | otherwise ->
        runAction env action $ \(transitioned, row) ->
          Succeeded (awakeableMutationResult "cancel" awakeableId transitioned row)
    where
      action = do
        transitioned <- cancelAwakeable (AwakeableId awakeableId)
        row <- Awakeable.lookupAwakeable awakeableId
        pure (transitioned, row)

runCancel :: OpsEnv -> WorkflowRef -> IO OpsOutcome
runCancel env ref
  | not env.force =
      runAction env preview $ \(row, journalExists) ->
        PreviewRequired
          (instancePreviewResult "cancel" ref (cancelPreviewDisposition row journalExists) row)
          (forceInvocation env ["wf", "cancel", ref.workflowName, ref.workflowId])
  | otherwise =
      runAction env (Instance.cancelWorkflow (refName ref) (refId ref)) $ \outcome ->
        Succeeded (workflowMutationResult "cancel" ref (cancelOutcomeText outcome))
  where
    preview = do
      row <- Instance.lookupInstance (refName ref) (refId ref)
      journalExists <- case row of
        Just _ -> pure True
        Nothing -> do
          generation <- WorkflowSchema.currentGeneration (refName ref) (refId ref)
          not . Map.null <$> WorkflowSchema.loadStepIndex (refName ref) (refId ref) generation
      pure (row, journalExists)

runResurrect :: OpsEnv -> WorkflowRef -> IO OpsOutcome
runResurrect env ref
  | not env.force =
      runAction env (Instance.lookupInstance (refName ref) (refId ref)) $ \row ->
        PreviewRequired
          (instancePreviewResult "resurrect" ref (resurrectPreviewDisposition row) row)
          (forceInvocation env ["wf", "resurrect", ref.workflowName, ref.workflowId])
  | otherwise =
      runAction env (Instance.resurrectFailedWorkflow (refName ref) (refId ref)) $ \outcome ->
        Succeeded (workflowMutationResult "resurrect" ref (resurrectOutcomeText outcome))

runReleaseLease :: OpsEnv -> WorkflowRef -> IO OpsOutcome
runReleaseLease env ref
  | not env.force =
      runAction env (Instance.lookupInstance (refName ref) (refId ref)) $ \row ->
        PreviewRequired
          (instancePreviewResult "lease release" ref (leasePreviewDisposition row) row)
          (forceInvocation env ["wf", "lease", "release", ref.workflowName, ref.workflowId])
  | otherwise =
      runAction env (Instance.forceReleaseInstanceLease (refName ref) (refId ref)) $ \released ->
        Succeeded (workflowMutationResult "lease release" ref (if released then "released" else "no_lease_released"))

runGc :: OpsEnv -> GcOptions -> IO OpsOutcome
runGc env options
  | not env.force = do
      now <- getCurrentTime
      runAction env (Gc.listWorkflowGcCandidates now policy) $ \candidates ->
        PreviewRequired
          (gcCandidatesResult candidates)
          ( forceInvocation
              env
              [ "wf",
                "gc",
                "run-once",
                "--retention",
                Text.pack (show (realToFrac options.retention :: Double)) <> "s",
                "--batch",
                Text.pack (show options.batchSize)
              ]
          )
  | otherwise = do
      now <- getCurrentTime
      runAction env (Gc.gcWorkflowsOnce now policy) (Succeeded . gcSummaryResult)
  where
    policy = Gc.WorkflowGcPolicy options.retention options.batchSize

runAction ::
  OpsEnv ->
  Eff '[Store, Error StoreError, IOE] a ->
  (a -> OpsOutcome) ->
  IO OpsOutcome
runAction env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ case result of
    Left storeError -> Failed (Text.pack (show storeError))
    Right value -> onSuccess value

resolveGeneration :: (Store :> es) => InspectOptions -> Eff es Int
resolveGeneration options =
  maybe
    (WorkflowSchema.currentGeneration (refName options.target) (refId options.target))
    pure
    options.generation

workflowListResult :: [Instance.WorkflowInstanceRow] -> OpsResult
workflowListResult instances =
  OpsResult
    { headers = ["name", "id", "generation", "status", "attempts", "lease", "wake_after", "updated_at"],
      rows = map workflowListRow instances,
      jsonValue = Aeson.toJSON (map Inspection.instanceToJson instances)
    }

workflowListRow :: Instance.WorkflowInstanceRow -> [Text]
workflowListRow row =
  [ row.workflowName,
    row.workflowId,
    Text.pack (show row.generation),
    Instance.statusToText row.status,
    Text.pack (show row.attempts),
    leaseText row,
    maybeTime row.wakeAfter,
    timeText row.updatedAt
  ]

workflowDetailsResult :: (Instance.WorkflowInstanceRow, [Child.ChildRow], [Awakeable.AwakeableRow]) -> OpsResult
workflowDetailsResult (row, children, awakeables) =
  OpsResult
    { headers = ["name", "id", "generation", "status", "attempts", "lease", "wake_after", "children", "awakeables"],
      rows =
        [ [ row.workflowName,
            row.workflowId,
            Text.pack (show row.generation),
            Instance.statusToText row.status,
            Text.pack (show row.attempts),
            leaseText row,
            maybeTime row.wakeAfter,
            Text.pack (show (length children)),
            Text.pack (show (length awakeables))
          ]
        ],
      jsonValue =
        object
          [ "instance" .= Inspection.instanceToJson row,
            "children" .= map Inspection.childToJson children,
            "awakeables" .= map Inspection.awakeableToJson awakeables
          ]
    }

stepsResult :: Int -> [WorkflowSchema.WorkflowStepRow] -> OpsResult
stepsResult generation steps =
  OpsResult
    { headers = ["step", "result"],
      rows = [[row.stepName, truncateCell 120 (jsonText row.result)] | row <- steps],
      jsonValue =
        object
          [ "generation" .= generation,
            "steps" .= map Inspection.stepToJson steps
          ]
    }

journalResult :: Int -> [Inspection.WorkflowJournalEntry] -> OpsResult
journalResult generation views =
  OpsResult
    { headers = ["version", "event_type", "step", "recorded_at", "payload"],
      rows =
        [ [ Text.pack (show view.streamVersion),
            view.eventType,
            view.stepName,
            timeText view.recordedAt,
            truncateCell 120 (jsonText view.payload)
          ]
        | view <- views
        ],
      jsonValue = object ["generation" .= generation, "events" .= map Inspection.journalEntryToJson views]
    }

awakeableResult :: Awakeable.AwakeableRow -> OpsResult
awakeableResult row =
  OpsResult
    { headers = ["id", "owner_name", "owner_id", "status", "payload", "updated_at"],
      rows =
        [ [ UUID.toText row.awakeableId,
            row.ownerWorkflowName,
            row.ownerWorkflowId,
            Awakeable.statusToText row.status,
            maybe "-" (truncateCell 120 . jsonText) row.payload,
            timeText row.updatedAt
          ]
        ],
      jsonValue = Inspection.awakeableToJson row
    }

awakeablePreviewResult :: Text -> UUID -> Maybe Awakeable.AwakeableRow -> OpsResult
awakeablePreviewResult operation awakeableId row =
  OpsResult
    { headers = ["operation", "id", "disposition", "status"],
      rows = [[operation, UUID.toText awakeableId, disposition, maybe "not_found" (Awakeable.statusToText . (.status)) row]],
      jsonValue =
        object
          [ "preview" .= True,
            "operation" .= operation,
            "disposition" .= disposition,
            "awakeable" .= fmap Inspection.awakeableToJson row
          ]
    }
  where
    disposition = case row of
      Nothing -> "not_found"
      Just found -> case found.status of
        Awakeable.Pending -> "would_mutate"
        Awakeable.Completed | operation == "signal" -> "would_repair_if_needed"
        _ -> "no_op"

awakeableMutationResult :: Text -> UUID -> Bool -> Maybe Awakeable.AwakeableRow -> OpsResult
awakeableMutationResult operation awakeableId transitioned row =
  OpsResult
    { headers = ["operation", "id", "outcome", "status"],
      rows = [[operation, UUID.toText awakeableId, outcome, maybe "not_found" (Awakeable.statusToText . (.status)) row]],
      jsonValue =
        object
          [ "operation" .= operation,
            "outcome" .= outcome,
            "transitioned" .= transitioned,
            "awakeable" .= fmap Inspection.awakeableToJson row
          ]
    }
  where
    outcome
      | transitioned = "transitioned"
      | otherwise = "not_transitioned"

instancePreviewResult :: Text -> WorkflowRef -> Text -> Maybe Instance.WorkflowInstanceRow -> OpsResult
instancePreviewResult operation ref disposition row =
  OpsResult
    { headers = ["operation", "name", "id", "disposition", "status"],
      rows = [[operation, ref.workflowName, ref.workflowId, disposition, maybe "not_found" (Instance.statusToText . (.status)) row]],
      jsonValue =
        object
          [ "preview" .= True,
            "operation" .= operation,
            "disposition" .= disposition,
            "target" .= object ["workflow_name" .= ref.workflowName, "workflow_id" .= ref.workflowId],
            "instance" .= fmap Inspection.instanceToJson row
          ]
    }

workflowMutationResult :: Text -> WorkflowRef -> Text -> OpsResult
workflowMutationResult operation ref outcome =
  OpsResult
    { headers = ["operation", "name", "id", "outcome"],
      rows = [[operation, ref.workflowName, ref.workflowId, outcome]],
      jsonValue =
        object
          [ "operation" .= operation,
            "workflow_name" .= ref.workflowName,
            "workflow_id" .= ref.workflowId,
            "outcome" .= outcome
          ]
    }

gcCandidatesResult :: [Gc.WorkflowGcCandidate] -> OpsResult
gcCandidatesResult candidates =
  OpsResult
    { headers = ["name", "id", "disposition"],
      rows = [[candidate.workflowName, candidate.workflowId, "would_collect"] | candidate <- candidates],
      jsonValue =
        object
          [ "preview" .= True,
            "candidates"
              .= [ object ["workflow_name" .= candidate.workflowName, "workflow_id" .= candidate.workflowId]
                 | candidate <- candidates
                 ]
          ]
    }

gcSummaryResult :: Gc.WorkflowGcSummary -> OpsResult
gcSummaryResult summary =
  OpsResult
    { headers = ["scanned", "deleted"],
      rows = [[Text.pack (show summary.scanned), Text.pack (show summary.deleted)]],
      jsonValue = object ["scanned" .= summary.scanned, "deleted" .= summary.deleted]
    }

cancelPreviewDisposition :: Maybe Instance.WorkflowInstanceRow -> Bool -> Text
cancelPreviewDisposition row journalExists = case row of
  Just found -> case found.status of
    Instance.WfRunning -> "would_cancel"
    Instance.WfSuspended -> "would_cancel"
    _ -> "already_terminal"
  Nothing
    | journalExists -> "would_cancel_journal_only_instance"
    | otherwise -> "not_found"

resurrectPreviewDisposition :: Maybe Instance.WorkflowInstanceRow -> Text
resurrectPreviewDisposition = \case
  Just row | row.status == Instance.WfFailed -> "would_resurrect"
  Just _ -> "not_failed"
  Nothing -> "not_found"

leasePreviewDisposition :: Maybe Instance.WorkflowInstanceRow -> Text
leasePreviewDisposition = \case
  Just row | Just _ <- row.leasedBy -> "would_release"
  Just _ -> "no_lease"
  Nothing -> "not_found"

cancelOutcomeText :: Instance.CancelWorkflowOutcome -> Text
cancelOutcomeText = \case
  Instance.WorkflowCancelRecorded -> "cancel_recorded"
  Instance.WorkflowAlreadyTerminal status -> "already_" <> Instance.statusToText status
  Instance.WorkflowCancelUnknown -> "not_found"

resurrectOutcomeText :: Instance.ResurrectOutcome -> Text
resurrectOutcomeText = \case
  Instance.WorkflowResurrected -> "resurrected"
  Instance.WorkflowNotFailed -> "not_failed"
  Instance.WorkflowNotFound -> "not_found"

refName :: WorkflowRef -> WorkflowName
refName = WorkflowName . (.workflowName)

refId :: WorkflowRef -> WorkflowId
refId = WorkflowId . (.workflowId)

workflowLabel :: WorkflowRef -> Text
workflowLabel ref = ref.workflowName <> "/" <> ref.workflowId

leaseText :: Instance.WorkflowInstanceRow -> Text
leaseText row = case row.leasedBy of
  Nothing -> "-"
  Just owner -> owner <> maybe "" ((" until " <>) . timeText) row.leaseExpiresAt

maybeTime :: Maybe UTCTime -> Text
maybeTime = maybe "-" timeText

timeText :: UTCTime -> Text
timeText = Text.pack . show

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments =
  Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags =
      ["--json" | env.outputMode == Json]
        <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"
