-- | Operational adapters for Keiro PGMQ dead-letter queues.
--
-- The module uses the versioned Keiro PGMQ DLQ helpers and never queries PGMQ
-- tables itself, preserving ADR 1's envelope contract and ADR 28's ownership
-- boundary.
module Keiro.Ops.Pgmq
  ( Command (..),
    DlqCommand (..),
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
import Data.Text.IO qualified as Text.IO
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Parse (positiveIntReader, readBoundedIntegral)
import Keiro.Ops.Render
import Keiro.PGMQ
import Kiroku.Store.Connection (KirokuStore (..))
import Options.Applicative hiding (action, value)
import Options.Applicative qualified as Opt
import System.IO (hFlush, stdout)

data Command = Dlq !DlqCommand
  deriving stock (Eq, Show)

data DlqCommand
  = Read !Text !Int
  | Redrive !Text !Int
  | Archive !Text !(Maybe Int64) !Int
  | Purge !Text
  deriving stock (Eq, Show)

commandParser :: Parser Command
commandParser =
  Dlq
    <$> hsubparser
      (command "dlq" (info dlqParser (progDesc "Inspect and operate a Keiro PGMQ dead-letter queue")))

dlqParser :: Parser DlqCommand
dlqParser =
  hsubparser
    ( command "read" (info readParser (progDesc "Read and decode visible DLQ entries"))
        <> command "redrive" (info redriveParser (progDesc "Preview or move DLQ entries back to the main queue"))
        <> command "archive" (info archiveParser (progDesc "Preview or archive DLQ entries for retention"))
        <> command "purge" (info purgeParser (progDesc "Preview or permanently purge a DLQ"))
    )
  where
    readParser = Read <$> queueOption <*> limitOption 20
    redriveParser = Redrive <$> queueOption <*> limitOption 100
    archiveParser =
      Archive
        <$> queueOption
        <*> optional (option int64Reader (long "entry" <> metavar "MESSAGE_ID" <> help "Archive only this DLQ message id"))
        <*> limitOption 100
    purgeParser = Purge <$> queueOption

queueOption :: Parser Text
queueOption = Text.pack <$> strOption (long "queue" <> metavar "QUEUE" <> help "Logical Keiro job queue name")

limitOption :: Int -> Parser Int
limitOption defaultLimit = option positiveIntReader (long "limit" <> metavar "N" <> Opt.value defaultLimit <> showDefault <> help "Maximum entries")

int64Reader :: ReadM Int64
int64Reader = eitherReader $ \raw ->
  case readBoundedIntegral raw of
    Just n | n > 0 -> Right n
    _ -> Left "expected a positive message id"

isMutation :: Command -> Bool
isMutation (Dlq dlqCommand) = case dlqCommand of
  Read {} -> False
  Redrive {} -> True
  Archive {} -> True
  Purge {} -> True

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env (Dlq dlqCommand) = case dlqCommand of
  Read queue limit -> handlePgmq (runJobEff (pgmqRuntime env) (readDlq (rawJob queue) (fromIntegral limit))) (Succeeded . dlqListResult queue)
  Redrive queue limit -> runRedrive env queue limit
  Archive queue entry limit -> runArchive env queue entry limit
  Purge queue -> runPurge env queue

runRedrive :: OpsEnv -> Text -> Int -> IO OpsOutcome
runRedrive env queue limit
  | env.force =
      handlePgmq (runJobEff (pgmqRuntime env) (redriveDlq (rawJob queue) limit)) $ \moved ->
        Succeeded (mutationCountResult "redrive" queue moved)
  | otherwise = previewFromDepth env "redrive" queue (Just limit) ["pgmq", "dlq", "redrive", "--queue", queue, "--limit", showText limit]

runArchive :: OpsEnv -> Text -> Maybe Int64 -> Int -> IO OpsOutcome
runArchive env queue entry limit
  | env.force = case entry of
      Just messageId ->
        handlePgmq (runJobEff (pgmqRuntime env) (archiveDlqEntryById (rawJob queue) messageId)) $ \archived ->
          Succeeded
            OpsResult
              { headers = ["operation", "queue", "message_id", "archived"],
                rows = [["archive", queue, showText messageId, boolText archived]],
                jsonValue = object ["operation" .= ("archive" :: Text), "queue" .= queue, "message_id" .= messageId, "archived" .= archived]
              }
      Nothing ->
        handlePgmq (runJobEff (pgmqRuntime env) (archiveDlq (rawJob queue) limit)) $ \archived ->
          Succeeded (mutationCountResult "archive" queue archived)
  | otherwise =
      case entry of
        Just messageId ->
          pure
            ( PreviewRequired
                OpsResult
                  { headers = ["operation", "queue", "message_id", "disposition"],
                    rows = [["archive", queue, showText messageId, "would_archive_if_present"]],
                    jsonValue = object ["preview" .= True, "operation" .= ("archive" :: Text), "queue" .= queue, "message_id" .= messageId]
                  }
                (forceInvocation env ["pgmq", "dlq", "archive", "--queue", queue, "--entry", showText messageId])
            )
        Nothing -> previewFromDepth env "archive" queue (Just limit) ["pgmq", "dlq", "archive", "--queue", queue, "--limit", showText limit]

runPurge :: OpsEnv -> Text -> IO OpsOutcome
runPurge env queue
  | env.force = do
      confirmed <- confirmPurge env queue
      if confirmed
        then handlePgmq (runJobEff (pgmqRuntime env) (purgeDlq (rawJob queue))) $ \() ->
          Succeeded (messageResult ("purged DLQ for " <> queue))
        else pure (Failed "queue-name confirmation did not match; DLQ purge cancelled")
  | otherwise = previewFromDepth env "purge" queue Nothing ["pgmq", "dlq", "purge", "--queue", queue]

confirmPurge :: OpsEnv -> Text -> IO Bool
confirmPurge env queue
  | env.outputMode == Json = pure True
  | otherwise = do
      Text.IO.putStr ("type the queue name to confirm: " <> queue <> "\n> ")
      hFlush stdout
      entered <- Text.IO.getLine
      pure (entered == queue)

previewFromDepth :: OpsEnv -> Text -> Text -> Maybe Int -> [Text] -> IO OpsOutcome
previewFromDepth env operation queue requested arguments =
  handlePgmq (runJobEff (pgmqRuntime env) (jobDlqMetrics (rawJob queue))) $ \metrics ->
    let affected = maybe metrics.queueLength (min metrics.queueLength . fromIntegral) requested
     in PreviewRequired
          OpsResult
            { headers = ["operation", "queue", "available", "would_affect"],
              rows = [[operation, queue, showText metrics.queueLength, showText affected]],
              jsonValue =
                object
                  [ "preview" .= True,
                    "operation" .= operation,
                    "queue" .= queue,
                    "available" .= metrics.queueLength,
                    "would_affect_at_most" .= affected
                  ]
            }
          (forceInvocation env arguments)

handlePgmq :: IO (Either PgmqRuntimeError a) -> (a -> OpsOutcome) -> IO OpsOutcome
handlePgmq operation onSuccess = do
  result <- operation
  pure $ either (Failed . Text.pack . show) onSuccess result

pgmqRuntime :: OpsEnv -> JobRuntime
pgmqRuntime env = JobRuntime env.store.pool Nothing

rawJob :: Text -> Job Value
rawJob queue =
  Job
    { jobName = queue,
      jobQueue = queueRef queue,
      jobCodec = aesonJobCodec,
      jobPolicy = defaultRetryPolicy
    }

dlqListResult :: Text -> [DlqEntry Value] -> OpsResult
dlqListResult queue entries =
  OpsResult
    { headers = ["dlq_id", "queue", "original_id", "enqueued_at", "reads", "reason", "payload"],
      rows = map (dlqRow queue) entries,
      jsonValue = Aeson.toJSON (map (dlqJson queue) entries)
    }

dlqRow :: Text -> DlqEntry Value -> [Text]
dlqRow queue entry =
  [ showText entry.dlqMessageId,
    queue,
    maybe "" showText entry.originalMessageId,
    maybe "" (Text.pack . show) entry.originalEnqueuedAt,
    maybe "" showText entry.readCount,
    truncateCell 100 entry.reason,
    truncateCell 120 (jsonText (either (Aeson.String . Text.pack . show) id entry.originalPayload))
  ]

dlqJson :: Text -> DlqEntry Value -> Value
dlqJson queue entry =
  object
    [ "dlq_message_id" .= showText entry.dlqMessageId,
      "queue" .= queue,
      "reason" .= entry.reason,
      "original_payload" .= either (Aeson.String . Text.pack . show) id entry.originalPayload,
      "original_message_id" .= entry.originalMessageId,
      "original_enqueued_at" .= entry.originalEnqueuedAt,
      "read_count" .= entry.readCount,
      "raw_body" .= entry.rawBody
    ]

mutationCountResult :: Text -> Text -> Int -> OpsResult
mutationCountResult operation queue count =
  OpsResult
    { headers = ["operation", "queue", "affected"],
      rows = [[operation, queue, showText count]],
      jsonValue = object ["operation" .= operation, "queue" .= queue, "affected" .= count]
    }

showText :: (Show a) => a -> Text
showText = Text.pack . show

boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"

forceInvocation :: OpsEnv -> [Text] -> Text
forceInvocation env arguments = Text.unwords (map shellQuote ("keiro-ops" : arguments <> globalFlags <> ["--force"]))
  where
    globalFlags = ["--json" | env.outputMode == Json] <> ["--allow-schema-drift" | env.allowSchemaDrift]

shellQuote :: Text -> Text
shellQuote value = "'" <> Text.replace "'" "'\"'\"'" value <> "'"
