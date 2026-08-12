module Keiro.Ops.Timer
  ( Command (..),
    DrainOptions (..),
    StuckListOptions (..),
    TimerFire,
    commandParser,
    commandParserWithDrain,
    isMutation,
    runCommand,
    runCommandWithFire,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (durationReader, nonNegativeIntReader, positiveIntReader)
import Keiro.Ops.Render
import Keiro.Timer
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId (..))
import Options.Applicative hiding (action, value)
import Options.Applicative qualified as Optparse

data StuckListOptions = StuckListOptions
  { minAge :: !(Maybe NominalDiffTime),
    minAttempts :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

data DrainOptions = DrainOptions
  { limit :: !Int
  }
  deriving stock (Eq, Show)

type TimerFire = TimerRow -> Eff '[Store, Error StoreError, IOE] (Maybe EventId)

data Command
  = StuckList !StuckListOptions
  | Requeue !TimerId
  | Cancel !TimerId
  | DeadLetter !TimerId !Text
  | DrainOnce !DrainOptions
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser = commandParserWithDrain False

commandParserWithDrain :: Bool -> Parser Command
commandParserWithDrain includeDrain =
  hsubparser
    ( command
        "stuck"
        ( info
            stuckCommandParser
            (progDesc "Find timers left firing by an interrupted worker")
        )
        <> command
          "requeue"
          ( info
              (Requeue <$> timerIdArgument)
              (progDesc "Preview or return a stuck firing timer to the scheduled queue")
          )
        <> command
          "cancel"
          ( info
              (Cancel <$> timerIdArgument)
              (progDesc "Preview or withdraw a scheduled or firing timer permanently")
          )
        <> command
          "dead-letter"
          ( info
              ( DeadLetter
                  <$> timerIdArgument
                  <*> (Text.pack <$> strOption (long "reason" <> metavar "TEXT" <> help "Operator reason recorded with the terminal transition"))
              )
              (progDesc "Preview or abandon a scheduled or firing timer with a reason")
          )
        <> drainCommand
    )
  where
    drainCommand
      | includeDrain =
          command
            "drain-once"
            ( info
                (DrainOnce . DrainOptions <$> option positiveIntReader (long "limit" <> metavar "N" <> Optparse.value 100 <> showDefault <> help "Maximum due timers to dispatch"))
                (progDesc "Preview or run one bounded pass through the application timer-fire hook")
            )
      | otherwise = mempty

stuckCommandParser :: Parser Command
stuckCommandParser =
  hsubparser
    ( command
        "list"
        ( info
            ( StuckList
                <$> ( StuckListOptions
                        <$> optional (option durationReader (long "min-age" <> metavar "DURATION" <> help "Minimum time in firing, such as 5m or 1h"))
                        <*> optional (option nonNegativeIntReader (long "min-attempts" <> metavar "N" <> help "Minimum claim attempt count"))
                    )
            )
            (progDesc "List stuck timers; requeue transient failures, cancel obsolete work, or dead-letter poison work")
        )
    )

timerIdArgument :: Parser TimerId
timerIdArgument = TimerId <$> argument uuidReader (metavar "TIMER_ID")

uuidReader :: ReadM UUID
uuidReader = eitherReader $ \raw ->
  maybe (Left "expected a UUID timer id") Right (UUID.fromString raw)

isMutation :: Command -> Bool
isMutation = \case
  StuckList {} -> False
  Requeue {} -> True
  Cancel {} -> True
  DeadLetter {} -> True
  DrainOnce {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand = runCommandWithFire Nothing

runCommandWithFire :: Maybe TimerFire -> OpsEnv -> Command -> IO OpsOutcome
runCommandWithFire timerFire env = \case
  StuckList options -> runStuckList env options
  Requeue timerId -> runMutation env RequeueOperation timerId Nothing
  Cancel timerId -> runMutation env CancelOperation timerId Nothing
  DeadLetter timerId reason -> runMutation env DeadLetterOperation timerId (Just reason)
  DrainOnce options -> runDrainOnce timerFire env options

runDrainOnce :: Maybe TimerFire -> OpsEnv -> DrainOptions -> IO OpsOutcome
runDrainOnce Nothing _ _ = pure (Failed "timer fire hook is not mounted")
runDrainOnce (Just fire) env options = do
  now <- getCurrentTime
  if env.force
    then
      runAction
        env
        (drainDueTimersWith Nothing defaultTimerWorkerOptions now options.limit fire)
        (Succeeded . drainResult options.limit)
    else runAction env (countDueTimers now) $ \due ->
      PreviewRequired
        (drainPreviewResult options.limit due)
        (forceInvocation env ["timer", "drain-once", "--limit", Text.pack (show options.limit)])

drainPreviewResult :: Int -> Int -> OpsResult
drainPreviewResult limit due =
  OpsResult
    { headers = ["due", "limit", "would_process"],
      rows = [[showText due, showText limit, showText (min (toInteger due) (toInteger limit))]],
      jsonValue =
        object
          [ "preview" .= True,
            "due" .= due,
            "limit" .= limit,
            "would_process" .= min (toInteger due) (toInteger limit)
          ]
    }

drainResult :: Int -> Int -> OpsResult
drainResult limit processed =
  OpsResult
    { headers = ["limit", "processed"],
      rows = [[showText limit, showText processed]],
      jsonValue = object ["limit" .= limit, "processed" .= processed]
    }

showText :: (Show a) => a -> Text
showText = Text.pack . show

runStuckList :: OpsEnv -> StuckListOptions -> IO OpsOutcome
runStuckList env options = do
  now <- getCurrentTime
  runAction env (findStuckTimers now stuckFilter) (Succeeded . timerListResult)
  where
    stuckFilter = StuckTimerFilter options.minAge options.minAttempts

data TimerOperation
  = RequeueOperation
  | CancelOperation
  | DeadLetterOperation

runMutation :: OpsEnv -> TimerOperation -> TimerId -> Maybe Text -> IO OpsOutcome
runMutation env operation timerId reason
  | not env.force =
      runAction env (lookupTimer timerId) $ \row ->
        PreviewRequired
          (timerPreviewResult operation timerId row)
          (forceInvocation env (operationArguments operation timerId reason))
  | otherwise =
      runAction env action $ \(transitioned, row) ->
        Succeeded (timerMutationResult operation timerId transitioned row)
  where
    action = do
      transitioned <- case operation of
        RequeueOperation -> requeueStuckTimer timerId
        CancelOperation -> cancelTimer timerId
        DeadLetterOperation -> deadLetterTimer timerId (maybe "operator dead-letter" id reason)
      row <- lookupTimer timerId
      pure (transitioned, row)

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

timerListResult :: [TimerRow] -> OpsResult
timerListResult timers =
  OpsResult
    { headers = ["id", "manager", "correlation", "fire_at", "status", "attempts", "payload"],
      rows = map timerRow timers,
      jsonValue = Aeson.toJSON (map timerJson timers)
    }

timerRow :: TimerRow -> [Text]
timerRow row =
  [ timerIdText row.timerId,
    row.processManagerName,
    row.correlationId,
    timeText row.fireAt,
    timerStatusText row.status,
    Text.pack (show row.attempts),
    truncateCell 120 (jsonText row.payload)
  ]

timerJson :: TimerRow -> Value
timerJson row =
  object
    [ "timer_id" .= timerIdText row.timerId,
      "process_manager_name" .= row.processManagerName,
      "correlation_id" .= row.correlationId,
      "fire_at" .= row.fireAt,
      "payload" .= row.payload,
      "status" .= timerStatusText row.status,
      "attempts" .= row.attempts,
      "fired_event_id" .= fmap (\(EventId eventId) -> UUID.toText eventId) row.firedEventId
    ]

timerPreviewResult :: TimerOperation -> TimerId -> Maybe TimerRow -> OpsResult
timerPreviewResult operation timerId row =
  OpsResult
    { headers = ["operation", "id", "disposition", "status"],
      rows = [[operationText operation, timerIdText timerId, disposition, maybe "not_found" (timerStatusText . (.status)) row]],
      jsonValue =
        object
          [ "preview" .= True,
            "operation" .= operationText operation,
            "disposition" .= disposition,
            "timer" .= fmap timerJson row
          ]
    }
  where
    disposition = timerDisposition operation row

timerMutationResult :: TimerOperation -> TimerId -> Bool -> Maybe TimerRow -> OpsResult
timerMutationResult operation timerId transitioned row =
  OpsResult
    { headers = ["operation", "id", "outcome", "status"],
      rows = [[operationText operation, timerIdText timerId, outcome, maybe "not_found" (timerStatusText . (.status)) row]],
      jsonValue =
        object
          [ "operation" .= operationText operation,
            "outcome" .= outcome,
            "transitioned" .= transitioned,
            "timer" .= fmap timerJson row
          ]
    }
  where
    outcome
      | transitioned = "transitioned"
      | otherwise = "not_transitioned"

timerDisposition :: TimerOperation -> Maybe TimerRow -> Text
timerDisposition _ Nothing = "not_found"
timerDisposition operation (Just row) = case operation of
  RequeueOperation
    | row.status == Firing -> "would_requeue"
    | otherwise -> "not_firing"
  CancelOperation
    | row.status `elem` [Scheduled, Firing] -> "would_cancel"
    | otherwise -> "already_terminal"
  DeadLetterOperation
    | row.status `elem` [Scheduled, Firing] -> "would_dead_letter"
    | otherwise -> "already_terminal"

operationArguments :: TimerOperation -> TimerId -> Maybe Text -> [Text]
operationArguments operation timerId reason =
  ["timer", operationText operation, timerIdText timerId]
    <> case operation of
      DeadLetterOperation -> ["--reason", maybe "operator dead-letter" id reason]
      _ -> []

operationText :: TimerOperation -> Text
operationText = \case
  RequeueOperation -> "requeue"
  CancelOperation -> "cancel"
  DeadLetterOperation -> "dead-letter"

timerStatusText :: TimerStatus -> Text
timerStatusText = \case
  Scheduled -> "scheduled"
  Firing -> "firing"
  Fired -> "fired"
  Cancelled -> "cancelled"
  Dead -> "dead"

timerIdText :: TimerId -> Text
timerIdText (TimerId timerId) = UUID.toText timerId

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
