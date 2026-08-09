-- | Operational adapters for the Keiro inbox.
--
-- All state changes flow through 'Keiro.Inbox' as required by ADR 28.
module Keiro.Ops.Inbox
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
import Keiro.Inbox
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (durationReader)
import Keiro.Ops.Render
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))
import Options.Applicative hiding (action, value)
import Options.Applicative qualified as Opt

data ListOptions = ListOptions
  { source :: !Text,
    status :: !(Maybe InboxStatus),
    limit :: !Int
  }
  deriving stock (Eq, Show)

data Command
  = Backlog
  | List !ListOptions
  | Show !Text !Text
  | Gc !NominalDiffTime
  | MarkFailed !Text !Text !Text
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "backlog" (info (pure Backlog) (progDesc "Count processing and failed inbox rows"))
        <> command "list" (info listParser (progDesc "List inbox rows for a source"))
        <> command "show" (info showParser (progDesc "Inspect one inbox row"))
        <> command "gc" (info gcParser (progDesc "Preview or delete retained completed rows"))
        <> command "mark-failed" (info markFailedParser (progDesc "Preview or mark an inbox row permanently failed"))
    )
  where
    listParser =
      List
        <$> ( ListOptions
                <$> textOption "source" "SOURCE" "Producing bounded-context source"
                <*> optional (option statusReader (long "status" <> metavar "STATUS" <> help "processing, completed, or failed"))
                <*> option positiveIntReader (long "limit" <> metavar "N" <> Opt.value 100 <> showDefault <> help "Maximum rows")
            )
    showParser =
      Show
        <$> argument (Text.pack <$> str) (metavar "SOURCE")
        <*> argument (Text.pack <$> str) (metavar "MESSAGE_ID")
    gcParser =
      Gc
        <$> option durationReader (long "older-than" <> metavar "DURATION" <> Opt.value 2592000 <> showDefaultWith (const "30d") <> help "Completed-row retention age")
    markFailedParser =
      MarkFailed
        <$> argument (Text.pack <$> str) (metavar "SOURCE")
        <*> argument (Text.pack <$> str) (metavar "MESSAGE_ID")
        <*> textOption "reason" "TEXT" "Permanent-failure reason"

textOption :: String -> String -> String -> Parser Text
textOption name metavarText helpText = Text.pack <$> strOption (long name <> metavar metavarText <> help helpText)

statusReader :: ReadM InboxStatus
statusReader = eitherReader (either (Left . Text.unpack) Right . parseInboxStatus . Text.pack)

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
  Gc {} -> True
  MarkFailed {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  Backlog -> runAction env countInboxBacklog (Succeeded . countResult "inbox_backlog")
  List options ->
    runAction env (listInbox options.source) $ \rows ->
      Succeeded (inboxListResult (take options.limit (filterByStatus options.status rows)))
  Show source messageId ->
    runAction env (lookupInbox source messageId) (Succeeded . maybe emptyResult (inboxListResult . pure))
  Gc olderThan -> runGc env olderThan
  MarkFailed source messageId reason -> runMarkFailed env source messageId reason

filterByStatus :: Maybe InboxStatus -> [InboxRow] -> [InboxRow]
filterByStatus Nothing = id
filterByStatus (Just expected) = filter ((== expected) . (.status))

runGc :: OpsEnv -> NominalDiffTime -> IO OpsOutcome
runGc env olderThan = do
  now <- getCurrentTime
  if env.force
    then runAction env (garbageCollectCompleted olderThan now) (Succeeded . countResult "deleted")
    else runAction env (listCompletedInboxGcCandidates olderThan now) $ \rows ->
      PreviewRequired
        (inboxListResult rows)
        (forceInvocation env ["inbox", "gc", "--older-than", durationText olderThan])

runMarkFailed :: OpsEnv -> Text -> Text -> Text -> IO OpsOutcome
runMarkFailed env source messageId reason
  | not env.force =
      runAction env (lookupInbox source messageId) $ \row ->
        PreviewRequired
          (markFailedPreview source messageId row)
          (forceInvocation env ["inbox", "mark-failed", source, messageId, "--reason", reason])
  | otherwise = do
      now <- getCurrentTime
      runAction
        env
        ( do
            runTransaction (markFailedTx source messageId reason now)
            lookupInbox source messageId
        )
        $ \row ->
          Succeeded (maybe emptyResult (inboxListResult . pure) row)

runAction :: OpsEnv -> Eff '[Store, Error StoreError, IOE] a -> (a -> OpsOutcome) -> IO OpsOutcome
runAction env action onSuccess = do
  result <- runStoreIO env.store action
  pure $ either (Failed . Text.pack . show) onSuccess result

countResult :: Text -> Int -> OpsResult
countResult label count = OpsResult [label] [[showText count]] (object ["metric" .= label, "count" .= count])

inboxListResult :: [InboxRow] -> OpsResult
inboxListResult inboxRows =
  OpsResult
    { headers = ["source", "message_id", "status", "attempts", "received_at", "last_error"],
      rows = map inboxRow inboxRows,
      jsonValue = Aeson.toJSON (map inboxJson inboxRows)
    }

inboxRow :: InboxRow -> [Text]
inboxRow row =
  [ row.source,
    row.dedupeKey,
    inboxStatusText row.status,
    showText row.attemptCount,
    timeText row.receivedAt,
    maybe "" (truncateCell 120) row.lastError
  ]

inboxJson :: InboxRow -> Value
inboxJson row =
  object
    [ "source" .= row.source,
      "dedupe_key" .= row.dedupeKey,
      "event" .= eventJson row.event,
      "kafka" .= fmap kafkaJson row.kafka,
      "status" .= inboxStatusText row.status,
      "attempt_count" .= row.attemptCount,
      "received_at" .= row.receivedAt,
      "completed_at" .= row.completedAt,
      "failed_at" .= row.failedAt,
      "last_error" .= row.lastError
    ]

eventJson :: IntegrationEvent -> Value
eventJson event =
  object
    [ "message_id" .= event.messageId,
      "source" .= event.source,
      "destination" .= event.destination,
      "key" .= event.key,
      "event_type" .= event.eventType,
      "schema_version" .= event.schemaVersion,
      "source_event_id" .= fmap eventIdText event.sourceEventId,
      "source_global_position" .= fmap globalPositionInt event.sourceGlobalPosition,
      "payload" .= payloadValue event,
      "occurred_at" .= event.occurredAt
    ]

kafkaJson :: KafkaDeliveryRef -> Value
kafkaJson ref = object ["topic" .= ref.topic, "partition" .= ref.partition, "offset" .= ref.offset]

payloadValue :: IntegrationEvent -> Value
payloadValue event =
  either
    (const (Aeson.String (Text.Encoding.decodeUtf8With Text.Error.lenientDecode event.payloadBytes)))
    id
    (Aeson.eitherDecodeStrict' event.payloadBytes)

markFailedPreview :: Text -> Text -> Maybe InboxRow -> OpsResult
markFailedPreview source messageId row =
  OpsResult
    { headers = ["source", "message_id", "current_status", "disposition"],
      rows = [[source, messageId, maybe "not_found" (inboxStatusText . (.status)) row, disposition]],
      jsonValue = object ["preview" .= True, "disposition" .= disposition, "inbox" .= fmap inboxJson row]
    }
  where
    disposition = maybe "not_found" (const "would_mark_failed") row

eventIdText :: EventId -> Text
eventIdText (EventId value) = UUID.toText value

globalPositionInt :: GlobalPosition -> Int64
globalPositionInt (GlobalPosition value) = value

timeText :: UTCTime -> Text
timeText = Text.pack . show

showText :: (Show a) => a -> Text
showText = Text.pack . show

durationText :: NominalDiffTime -> Text
durationText = showText . (realToFrac :: NominalDiffTime -> Double)

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments = Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags = ["--json" | env.outputMode == Json] <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"
