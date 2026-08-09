module Keiro.Ops
  ( main,
  )
where

import Control.Exception (SomeException, displayException, fromException, try)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations.SchemaCheck (renderSchemaDrift, verifyExpectedSchema)
import Keiro.Ops.Env
import Keiro.Ops.Inbox qualified as Inbox
import Keiro.Ops.Outbox qualified as Outbox
import Keiro.Ops.Pgmq qualified as Pgmq
import Keiro.Ops.Projection qualified as Projection
import Keiro.Ops.Render
import Keiro.Ops.Shard qualified as Shard
import Keiro.Ops.Snapshot qualified as Snapshot
import Keiro.Ops.Stream qualified as Stream
import Keiro.Ops.Timer qualified as Timer
import Keiro.Ops.Workflow qualified as Workflow
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Options.Applicative
import System.Exit qualified as Exit
import System.IO (stderr)

main :: IO ()
main = do
  invocation <- customExecParser (prefs subparserInline) parserInfo
  result <- try (runInvocation invocation)
  case result of
    Left exception ->
      case fromException exception :: Maybe Exit.ExitCode of
        Just exitCode -> Exit.exitWith exitCode
        Nothing -> failOperational (Text.pack (displayException (exception :: SomeException)))
    Right () -> pure ()

data Invocation = Invocation
  { globalOptions :: !GlobalOptions,
    opsCommand :: !Command
  }

data Command
  = Workflow Workflow.Command
  | Timer Timer.Command
  | Outbox Outbox.Command
  | Inbox Inbox.Command
  | Pgmq Pgmq.Command
  | Projection Projection.Command
  | Shard Shard.Command
  | Snapshot Snapshot.Command
  | Stream Stream.Command

parserInfo :: ParserInfo Invocation
parserInfo =
  info
    (invocationParser <**> helper)
    ( fullDesc
        <> progDesc "Inspect and operate a Keiro deployment"
        <> failureCode 2
    )

invocationParser :: Parser Invocation
invocationParser = Invocation <$> globalOptionsParser <*> commandParser

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command
        "wf"
        ( info
            (Workflow <$> Workflow.commandParser)
            (progDesc "Inspect and operate durable workflows")
        )
        <> command
          "timer"
          ( info
              (Timer <$> Timer.commandParser)
              (progDesc "Inspect and operate durable timers")
          )
        <> command
          "outbox"
          (info (Outbox <$> Outbox.commandParser) (progDesc "Inspect and operate the transactional outbox"))
        <> command
          "inbox"
          (info (Inbox <$> Inbox.commandParser) (progDesc "Inspect and operate the integration-event inbox"))
        <> command
          "pgmq"
          (info (Pgmq <$> Pgmq.commandParser) (progDesc "Inspect and operate Keiro PGMQ queues"))
        <> command
          "projection"
          (info (Projection <$> Projection.commandParser) (progDesc "Inspect and operate projection dedup state"))
        <> command
          "shard"
          (info (Shard <$> Shard.commandParser) (progDesc "Inspect and operate sharded-subscription ownership"))
        <> command
          "snapshot"
          (info (Snapshot <$> Snapshot.commandParser) (progDesc "Inspect and operate advisory snapshots"))
        <> command
          "stream"
          (info (Stream <$> Stream.commandParser) (progDesc "Inspect and operate Kiroku streams"))
    )

runInvocation :: Invocation -> IO ()
runInvocation Invocation {globalOptions, opsCommand} = do
  connectionString <- resolveConnectionString globalOptions.databaseUrl
  verified <- verifyExpectedSchema (Settings.connectionString connectionString)
  case verified of
    Left migrationError ->
      failOperational ("schema verification failed: " <> Text.pack (show migrationError))
    Right drifts -> do
      let renderedDrifts = map renderSchemaDrift drifts
      traverse_ (Text.IO.hPutStrLn stderr . ("warning: " <>)) renderedDrifts
      if isMutation opsCommand && not (null drifts) && not globalOptions.allowSchemaDrift
        then
          failOperational
            "refusing mutation because the live schema differs from this binary; inspect the warnings or pass --allow-schema-drift"
        else withStore (defaultConnectionSettings connectionString) $ \store -> do
          let env =
                OpsEnv
                  { store,
                    outputMode = globalOptions.outputMode,
                    force = globalOptions.force,
                    schemaDrift = renderedDrifts,
                    allowSchemaDrift = globalOptions.allowSchemaDrift
                  }
          runCommand env opsCommand >>= finishOutcome env

isMutation :: Command -> Bool
isMutation = \case
  Workflow workflowCommand -> Workflow.isMutation workflowCommand
  Timer timerCommand -> Timer.isMutation timerCommand
  Outbox outboxCommand -> Outbox.isMutation outboxCommand
  Inbox inboxCommand -> Inbox.isMutation inboxCommand
  Pgmq pgmqCommand -> Pgmq.isMutation pgmqCommand
  Projection projectionCommand -> Projection.isMutation projectionCommand
  Shard shardCommand -> Shard.isMutation shardCommand
  Snapshot snapshotCommand -> Snapshot.isMutation snapshotCommand
  Stream streamCommand -> Stream.isMutation streamCommand

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  Workflow workflowCommand -> Workflow.runCommand env workflowCommand
  Timer timerCommand -> Timer.runCommand env timerCommand
  Outbox outboxCommand -> Outbox.runCommand env outboxCommand
  Inbox inboxCommand -> Inbox.runCommand env inboxCommand
  Pgmq pgmqCommand -> Pgmq.runCommand env pgmqCommand
  Projection projectionCommand -> Projection.runCommand env projectionCommand
  Shard shardCommand -> Shard.runCommand env shardCommand
  Snapshot snapshotCommand -> Snapshot.runCommand env snapshotCommand
  Stream streamCommand -> Stream.runCommand env streamCommand

finishOutcome :: OpsEnv -> OpsOutcome -> IO ()
finishOutcome env = \case
  Succeeded result -> renderResult env result
  PreviewRequired result reinvocation -> do
    renderResult env result
    Text.IO.hPutStrLn stderr ("preview only; re-run with --force: " <> reinvocation)
    Exit.exitWith (Exit.ExitFailure 1)
  Failed message -> failOperational message

failOperational :: Text.Text -> IO a
failOperational message = do
  Text.IO.hPutStrLn stderr ("keiro-ops: " <> message)
  Exit.exitWith (Exit.ExitFailure 1)
