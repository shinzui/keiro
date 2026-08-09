module Keiro.Ops.Workflow
  ( AwakeableCommand (..),
    Command (..),
    GcOptions (..),
    InspectOptions (..),
    ListOptions (..),
    PayloadArg (..),
    ResumeHook,
    ResumeOptions (..),
    WorkflowRef (..),
    commandParser,
    commandParserWithResume,
    isMutation,
    runCommand,
    runCommandWithResume,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Codec (decodeRecorded)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (durationReader)
import Keiro.Ops.Render
import Keiro.Workflow.Awakeable (AwakeableId (..), cancelAwakeable, signalAwakeable)
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Child.Schema qualified as Child
import Keiro.Workflow.Gc qualified as Gc
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
    WorkflowJournalEvent (..),
    WorkflowName (..),
    awakeableAllocStepPrefix,
    cancelledStepName,
    completedStepName,
    continuedAsNewStepName,
    failedStepName,
    workflowGenerationStreamName,
    workflowJournalCodec,
  )
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read qualified as StoreRead
import Kiroku.Store.Types
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

commandParser :: Parser Command
commandParser = commandParserWithResume False

commandParserWithResume :: Bool -> Parser Command
commandParserWithResume includeResume =
  hsubparser
    ( command "list" (info (List <$> listOptionsParser) (progDesc "List workflow instances with stable keyset paging"))
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
    <*> option auto (long "limit" <> metavar "N" <> Optparse.value 100 <> showDefault <> help "Maximum rows to return")

inspectOptionsParser :: Parser InspectOptions
inspectOptionsParser =
  InspectOptions
    <$> workflowRefParser
    <*> optional (option generationReader (long "generation" <> metavar "N" <> help "Journal generation; defaults to current"))

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
                        <*> option auto (long "batch" <> metavar "N" <> Optparse.value 100 <> showDefault <> help "Maximum workflows to collect")
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

generationReader :: ReadM Int
generationReader = eitherReader $ \raw ->
  case reads raw of
    [(value, "")] | value >= 0 -> Right value
    _ -> Left "expected a non-negative generation"

positiveIntReader :: ReadM Int
positiveIntReader = eitherReader $ \raw ->
  case reads raw of
    [(value, "")] | value > 0 -> Right value
    _ -> Left "expected a positive integer"

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
    { headers = ["discovered", "resumed", "completed", "suspended", "unknown", "failed", "errors", "lease_skipped"],
      rows =
        [ map
            (Text.pack . show)
            [ summary.discovered,
              summary.resumed,
              summary.completed,
              summary.stillSuspended,
              summary.unknownName,
              summary.failed,
              summary.transientErrors,
              summary.leaseSkipped
            ]
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
            "lease_skipped" .= summary.leaseSkipped
          ]
    }

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
runShow env ref =
  runAction env action $ \case
    Nothing -> Failed (workflowLabel ref <> " was not found")
    Just details -> Succeeded (workflowDetailsResult details)
  where
    action = do
      instanceRow <- Instance.lookupInstance (refName ref) (refId ref)
      case instanceRow of
        Nothing -> pure Nothing
        Just row -> do
          children <- Child.lookupChildrenOfParent ref.workflowId ref.workflowName
          awakeables <- lookupWorkflowAwakeables ref
          pure (Just (row, children, awakeables))

runSteps :: OpsEnv -> InspectOptions -> IO OpsOutcome
runSteps env options =
  runAction env action (Succeeded . uncurry stepsResult)
  where
    action = do
      selectedGeneration <- resolveGeneration options
      steps <- WorkflowSchema.loadStepIndex (refName options.target) (refId options.target) selectedGeneration
      pure (selectedGeneration, steps)

runJournal :: OpsEnv -> InspectOptions -> IO OpsOutcome
runJournal env options =
  runAction env action $ \(selectedGeneration, recorded) ->
    case traverse decodeJournalView recorded of
      Left err -> Failed err
      Right views -> Succeeded (journalResult selectedGeneration views)
  where
    action = do
      selectedGeneration <- resolveGeneration options
      recorded <- readJournalEvents (workflowGenerationStreamName (refName options.target) (refId options.target) selectedGeneration)
      pure (selectedGeneration, recorded)

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

lookupWorkflowAwakeables :: (Store :> es) => WorkflowRef -> Eff es [Awakeable.AwakeableRow]
lookupWorkflowAwakeables ref = do
  current <- WorkflowSchema.currentGeneration (refName ref) (refId ref)
  stepIndexes <- traverse (WorkflowSchema.loadStepIndex (refName ref) (refId ref)) [0 .. current]
  catMaybes <$> traverse Awakeable.lookupAwakeable (awakeableIds stepIndexes)

awakeableIds :: [Map Text Value] -> [UUID]
awakeableIds indexes =
  Set.toAscList . Set.fromList $ do
    index <- indexes
    (stepName, value) <- Map.toList index
    if awakeableAllocStepPrefix `Text.isPrefixOf` stepName
      then case Aeson.fromJSON value of
        AesonTypes.Success (AwakeableId awakeableId) -> [awakeableId]
        AesonTypes.Error _ -> []
      else []

readJournalEvents :: (Store :> es) => StreamName -> Eff es [RecordedEvent]
readJournalEvents streamName = go (StreamVersion 0) []
  where
    pageSize = 256
    go cursor pages = do
      page <- StoreRead.readStreamForward streamName cursor pageSize
      if Vector.null page
        then pure (concat (reverse pages))
        else
          let nextCursor = (Vector.last page).streamVersion
           in go nextCursor (Vector.toList page : pages)

data JournalView = JournalView
  { eventId :: !Text,
    eventType :: !Text,
    streamVersion :: !Int64,
    globalPosition :: !Int64,
    stepName :: !Text,
    recordedAt :: !UTCTime,
    payload :: !Value
  }

decodeJournalView :: RecordedEvent -> Either Text JournalView
decodeJournalView recorded = do
  event <- firstShow (decodeRecorded workflowJournalCodec recorded)
  let (stepName, recordedAt, payload) = case event of
        StepRecorded name value timestamp -> (name, timestamp, value)
        WorkflowCompleted timestamp -> (completedStepName, timestamp, Aeson.Null)
        WorkflowCancelled timestamp -> (cancelledStepName, timestamp, Aeson.Null)
        WorkflowFailed reason timestamp -> (failedStepName, timestamp, Aeson.toJSON reason)
        WorkflowContinuedAsNew generation timestamp -> (continuedAsNewStepName, timestamp, Aeson.toJSON generation)
  pure
    JournalView
      { eventId = case recorded.eventId of EventId value -> UUID.toText value,
        eventType = case recorded.eventType of EventType value -> value,
        streamVersion = case recorded.streamVersion of StreamVersion value -> value,
        globalPosition = case recorded.globalPosition of GlobalPosition value -> value,
        stepName,
        recordedAt,
        payload
      }

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = \case
  Left err -> Left ("workflow journal decode failed: " <> Text.pack (show err))
  Right value -> Right value

workflowListResult :: [Instance.WorkflowInstanceRow] -> OpsResult
workflowListResult instances =
  OpsResult
    { headers = ["name", "id", "generation", "status", "attempts", "lease", "wake_after", "updated_at"],
      rows = map workflowListRow instances,
      jsonValue = Aeson.toJSON (map workflowInstanceJson instances)
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

workflowInstanceJson :: Instance.WorkflowInstanceRow -> Value
workflowInstanceJson row =
  object
    [ "workflow_id" .= row.workflowId,
      "workflow_name" .= row.workflowName,
      "generation" .= row.generation,
      "status" .= Instance.statusToText row.status,
      "attempts" .= row.attempts,
      "last_error" .= row.lastError,
      "next_attempt_at" .= row.nextAttemptAt,
      "wake_after" .= row.wakeAfter,
      "leased_by" .= row.leasedBy,
      "lease_expires_at" .= row.leaseExpiresAt,
      "created_at" .= row.createdAt,
      "updated_at" .= row.updatedAt,
      "completed_at" .= row.completedAt
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
          [ "instance" .= workflowInstanceJson row,
            "children" .= map childJson children,
            "awakeables" .= map awakeableJson awakeables
          ]
    }

childJson :: Child.ChildRow -> Value
childJson row =
  object
    [ "child_id" .= row.childId,
      "child_name" .= row.childName,
      "parent_id" .= row.parentId,
      "parent_name" .= row.parentName,
      "await_step" .= row.awaitStep,
      "status" .= Child.statusToText row.status,
      "result" .= row.result,
      "failure_reason" .= row.failureReason,
      "created_at" .= row.createdAt,
      "updated_at" .= row.updatedAt,
      "completed_at" .= row.completedAt
    ]

stepsResult :: Int -> Map Text Value -> OpsResult
stepsResult generation steps =
  OpsResult
    { headers = ["step", "result"],
      rows = [[name, truncateCell 120 (jsonText value)] | (name, value) <- Map.toAscList steps],
      jsonValue =
        object
          [ "generation" .= generation,
            "steps" .= [object ["step" .= name, "result" .= value] | (name, value) <- Map.toAscList steps]
          ]
    }

journalResult :: Int -> [JournalView] -> OpsResult
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
      jsonValue = object ["generation" .= generation, "events" .= map journalViewJson views]
    }

journalViewJson :: JournalView -> Value
journalViewJson view =
  object
    [ "event_id" .= view.eventId,
      "event_type" .= view.eventType,
      "stream_version" .= view.streamVersion,
      "global_position" .= view.globalPosition,
      "step_name" .= view.stepName,
      "recorded_at" .= view.recordedAt,
      "payload" .= view.payload
    ]

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
      jsonValue = awakeableJson row
    }

awakeableJson :: Awakeable.AwakeableRow -> Value
awakeableJson row =
  object
    [ "awakeable_id" .= UUID.toText row.awakeableId,
      "owner_workflow_name" .= row.ownerWorkflowName,
      "owner_workflow_id" .= row.ownerWorkflowId,
      "status" .= Awakeable.statusToText row.status,
      "payload" .= row.payload,
      "created_at" .= row.createdAt,
      "updated_at" .= row.updatedAt,
      "completed_at" .= row.completedAt
    ]

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
            "awakeable" .= fmap awakeableJson row
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
            "awakeable" .= fmap awakeableJson row
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
            "instance" .= fmap workflowInstanceJson row
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
