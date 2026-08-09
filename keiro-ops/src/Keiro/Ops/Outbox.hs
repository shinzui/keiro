-- | Operational adapters for the Keiro outbox and dispatch dead letters.
--
-- Mutations and previews use only the public owning-library operations required
-- by ADR 28; this module never reaches into either schema directly.
module Keiro.Ops.Outbox
  ( Command (..),
    ListOptions (..),
    commandParser,
    isMutation,
    runCommand,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.Encoding.Error qualified as Text.Error
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.DeadLetter
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (durationReader)
import Keiro.Ops.Render
import Keiro.Outbox
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..), StreamName (..))
import Options.Applicative hiding (action, value)
import Options.Applicative qualified as Opt

data ListOptions = ListOptions
  { source :: !Text,
    status :: !(Maybe OutboxStatus),
    destination :: !(Maybe Text),
    limit :: !Int
  }
  deriving stock (Eq, Show)

data Command
  = Backlog
  | List !ListOptions
  | Show !OutboxId
  | RequeueStuck !NominalDiffTime !Int
  | GcSent !NominalDiffTime
  | MaintenancePass
  | DispatchDeadLetters !Text !Int
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "backlog" (info (pure Backlog) (progDesc "Count claimable outbox rows"))
        <> command "list" (info listParser (progDesc "List outbox rows for a source"))
        <> command "show" (info (Show <$> outboxIdArgument) (progDesc "Inspect one outbox row"))
        <> command "requeue-stuck" (info requeueParser (progDesc "Preview or reclaim stale publishing rows"))
        <> command "gc-sent" (info gcParser (progDesc "Preview or delete retained sent rows"))
        <> command "maintenance-pass" (info (pure MaintenancePass) (progDesc "Preview or run one default outbox maintenance pass"))
        <> command
          "dead-letters"
          (info (hsubparser (command "list" (info deadLettersParser (progDesc "List rejected process-manager or router dispatches")))) (progDesc "Inspect rejected process-manager or router dispatches"))
    )
  where
    listParser =
      List
        <$> ( ListOptions
                <$> textOption "source" "SOURCE" "Producing bounded-context source"
                <*> optional (option statusReader (long "status" <> metavar "STATUS" <> help "pending, publishing, sent, failed, or dead"))
                <*> optional (textOption "destination" "DESTINATION" "Destination filter")
                <*> option positiveIntReader (long "limit" <> metavar "N" <> Opt.value 100 <> showDefault <> help "Maximum rows")
            )
    requeueParser =
      RequeueStuck
        <$> option durationReader (long "older-than" <> metavar "DURATION" <> Opt.value 300 <> showDefaultWith (const "5m") <> help "Minimum publishing age")
        <*> option positiveIntReader (long "max-attempts" <> metavar "N" <> Opt.value 10 <> showDefault <> help "Attempt ceiling; exhausted rows become dead")
    gcParser =
      GcSent
        <$> option durationReader (long "older-than" <> metavar "DURATION" <> Opt.value 2592000 <> showDefaultWith (const "30d") <> help "Sent-row retention age")
    deadLettersParser =
      DispatchDeadLetters
        <$> textOption "dispatcher" "NAME" "Process-manager or router dispatcher name"
        <*> option positiveIntReader (long "limit" <> metavar "N" <> Opt.value 100 <> showDefault <> help "Maximum rows")

textOption :: String -> String -> String -> Parser Text
textOption name metavarText helpText =
  Text.pack <$> strOption (long name <> metavar metavarText <> help helpText)

outboxIdArgument :: Parser OutboxId
outboxIdArgument =
  OutboxId <$> argument uuidReader (metavar "OUTBOX_ID")

uuidReader :: ReadM UUID.UUID
uuidReader = eitherReader $ \raw -> maybe (Left "expected a UUID") Right (UUID.fromString raw)

statusReader :: ReadM OutboxStatus
statusReader = eitherReader (firstText . parseStatus . Text.pack)
  where
    firstText = either (Left . Text.unpack) Right

positiveIntReader :: ReadM Int
positiveIntReader = eitherReader $ \raw ->
  case reads raw of
    [(n, "")] | n > 0 -> Right n
    _ -> Left "expected a positive integer"

isMutation :: Command -> Bool
isMutation = \case
  Backlog -> False
  List {} -> False
  Show {} -> False
  DispatchDeadLetters {} -> False
  RequeueStuck {} -> True
  GcSent {} -> True
  MaintenancePass -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  Backlog -> runAction env countOutboxBacklog (Succeeded . countResult "outbox_backlog")
  List options -> runAction env (listOutbox options.source) (Succeeded . outboxListResult . applyListOptions options)
  Show outboxId -> runAction env (lookupOutbox outboxId) (Succeeded . maybe emptyResult (outboxListResult . pure))
  RequeueStuck olderThan maxAttempts -> runRequeue env olderThan maxAttempts
  GcSent olderThan -> runGc env olderThan
  MaintenancePass -> runMaintenance env
  DispatchDeadLetters dispatcher limit ->
    runAction env (listDispatchDeadLetters dispatcher) (Succeeded . dispatchListResult . take limit)

applyListOptions :: ListOptions -> [OutboxRow] -> [OutboxRow]
applyListOptions options =
  take options.limit
    . filter (maybe (const True) (\expected row -> row.status == expected) options.status)
    . filter (maybe (const True) (\expected row -> row.event.destination == expected) options.destination)

runRequeue :: OpsEnv -> NominalDiffTime -> Int -> IO OpsOutcome
runRequeue env olderThan maxAttempts = do
  now <- getCurrentTime
  if env.force
    then runAction env (requeueStuckOutbox maxAttempts olderThan now) $ \(requeued, deadLettered) ->
      Succeeded
        OpsResult
          { headers = ["requeued", "dead_lettered"],
            rows = [[showText requeued, showText deadLettered]],
            jsonValue = object ["requeued" .= requeued, "dead_lettered" .= deadLettered]
          }
    else runAction env (listStuckOutbox olderThan now) $ \rows ->
      PreviewRequired
        (outboxPreviewResult maxAttempts rows)
        (forceInvocation env ["outbox", "requeue-stuck", "--older-than", durationText olderThan, "--max-attempts", showText maxAttempts])

runGc :: OpsEnv -> NominalDiffTime -> IO OpsOutcome
runGc env olderThan = do
  now <- getCurrentTime
  if env.force
    then runAction env (garbageCollectSent olderThan now) (Succeeded . countResult "deleted")
    else runAction env (listSentOutboxGcCandidates olderThan now) $ \rows ->
      PreviewRequired
        (outboxListResult rows)
        (forceInvocation env ["outbox", "gc-sent", "--older-than", durationText olderThan])

runMaintenance :: OpsEnv -> IO OpsOutcome
runMaintenance env = do
  now <- getCurrentTime
  let options = defaultMaintenanceOptions
  if env.force
    then runAction env (outboxMaintenancePass options Nothing) $ \summary ->
      Succeeded
        OpsResult
          { headers = ["requeued", "dead_lettered", "backlog"],
            rows = [[showText summary.requeued, showText summary.deadLettered, showText summary.backlog]],
            jsonValue = object ["requeued" .= summary.requeued, "dead_lettered" .= summary.deadLettered, "backlog" .= summary.backlog]
          }
    else runAction env (listStuckOutbox options.publishingTimeout now) $ \rows ->
      PreviewRequired
        (outboxPreviewResult options.maxAttempts rows)
        (forceInvocation env ["outbox", "maintenance-pass"])

runAction :: OpsEnv -> Eff '[Store, Error StoreError, IOE] a -> (a -> OpsOutcome) -> IO OpsOutcome
runAction env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ either (Failed . Text.pack . show) onSuccess result

countResult :: Text -> Int -> OpsResult
countResult label count =
  OpsResult [label] [[showText count]] (object ["count" .= count, "metric" .= label])

outboxListResult :: [OutboxRow] -> OpsResult
outboxListResult outboxRows =
  OpsResult
    { headers = ["id", "source", "destination", "status", "attempts", "created_at", "last_error"],
      rows = map outboxRow outboxRows,
      jsonValue = Aeson.toJSON (map outboxJson outboxRows)
    }

outboxRow :: OutboxRow -> [Text]
outboxRow row =
  [ outboxIdText row.outboxId,
    row.event.source,
    row.event.destination,
    statusText row.status,
    showText row.attemptCount,
    timeText row.createdAt,
    maybe "" (truncateCell 120) row.lastError
  ]

outboxJson :: OutboxRow -> Value
outboxJson row =
  object
    [ "outbox_id" .= outboxIdText row.outboxId,
      "message_id" .= row.event.messageId,
      "source" .= row.event.source,
      "destination" .= row.event.destination,
      "key" .= row.event.key,
      "event_type" .= row.event.eventType,
      "schema_version" .= row.event.schemaVersion,
      "source_event_id" .= fmap eventIdText row.event.sourceEventId,
      "source_global_position" .= fmap globalPositionInt row.event.sourceGlobalPosition,
      "payload" .= payloadValue row.event,
      "status" .= statusText row.status,
      "attempt_count" .= row.attemptCount,
      "next_attempt_at" .= row.nextAttemptAt,
      "last_error" .= row.lastError,
      "published_at" .= row.publishedAt,
      "created_at" .= row.createdAt,
      "updated_at" .= row.updatedAt
    ]

payloadValue :: IntegrationEvent -> Value
payloadValue event =
  either
    (const (Aeson.String (Text.Encoding.decodeUtf8With Text.Error.lenientDecode event.payloadBytes)))
    id
    (Aeson.eitherDecodeStrict' event.payloadBytes)

outboxPreviewResult :: Int -> [OutboxRow] -> OpsResult
outboxPreviewResult maxAttempts outboxRows =
  OpsResult
    { headers = ["id", "current_status", "disposition", "attempts"],
      rows =
        [ [outboxIdText row.outboxId, statusText row.status, disposition row, showText row.attemptCount]
        | row <- outboxRows
        ],
      jsonValue =
        Aeson.toJSON
          [ object ["outbox" .= outboxJson row, "disposition" .= disposition row]
          | row <- outboxRows
          ]
    }
  where
    disposition row
      | row.attemptCount >= maxAttempts = "would_dead_letter"
      | otherwise = "would_requeue"

dispatchListResult :: [DispatchDeadLetterRecord] -> OpsResult
dispatchListResult records =
  OpsResult
    { headers = ["id", "kind", "dispatcher", "correlation", "target", "error", "attempts", "created_at"],
      rows = map dispatchRow records,
      jsonValue = Aeson.toJSON (map dispatchJson records)
    }

dispatchRow :: DispatchDeadLetterRecord -> [Text]
dispatchRow row =
  [ showText row.deadLetterId,
    dispatcherKindText row.dispatcherKind,
    row.dispatcherName,
    row.correlationId,
    streamNameText row.targetStreamName,
    row.errorClass <> ": " <> truncateCell 100 row.errorDetail,
    showText row.attemptCount,
    timeText row.createdAt
  ]

dispatchJson :: DispatchDeadLetterRecord -> Value
dispatchJson row =
  object
    [ "dead_letter_id" .= row.deadLetterId,
      "dispatcher_kind" .= dispatcherKindText row.dispatcherKind,
      "dispatcher_name" .= row.dispatcherName,
      "correlation_id" .= row.correlationId,
      "source_event_id" .= eventIdText row.sourceEventId,
      "source_global_position" .= globalPositionInt row.sourceGlobalPosition,
      "emit_index" .= row.emitIndex,
      "target_stream_name" .= streamNameText row.targetStreamName,
      "error_class" .= row.errorClass,
      "error_detail" .= row.errorDetail,
      "attempt_count" .= row.attemptCount,
      "created_at" .= row.createdAt
    ]

dispatcherKindText :: DispatcherKind -> Text
dispatcherKindText = \case
  DispatcherProcessManager -> "process_manager"
  DispatcherRouter -> "router"

outboxIdText :: OutboxId -> Text
outboxIdText (OutboxId value) = UUID.toText value

eventIdText :: EventId -> Text
eventIdText (EventId value) = UUID.toText value

globalPositionInt :: GlobalPosition -> Int64
globalPositionInt (GlobalPosition value) = value

streamNameText :: StreamName -> Text
streamNameText (StreamName value) = value

timeText :: UTCTime -> Text
timeText = Text.pack . show

showText :: (Show a) => a -> Text
showText = Text.pack . show

durationText :: NominalDiffTime -> Text
durationText = showText . (realToFrac :: NominalDiffTime -> Double)

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments =
  Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags =
      ["--json" | env.outputMode == Json]
        <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"
