module Keiro.Ops
  ( main,
    mainWithHooks,
    AppHooks (..),
    OpsAuditConfig (..),
    emptyAppHooks,
    OpsInvocation,
    opsCommandTree,
    runOpsInvocation,
  )
where

import Control.Exception (SomeException, displayException, fromException, try)
import Data.Foldable (traverse_)
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations.SchemaCheck (renderSchemaDrift, verifyExpectedSchema)
import Keiro.Ops.Embed
import Keiro.Ops.Env
import Keiro.Ops.Inbox qualified as Inbox
import Keiro.Ops.Outbox qualified as Outbox
import Keiro.Ops.Pgmq qualified as Pgmq
import Keiro.Ops.Projection qualified as Projection
import Keiro.Ops.Rebuild qualified as Rebuild
import Keiro.Ops.Render
import Keiro.Ops.ReplayAudit qualified as ReplayAudit
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
main = mainWithHooks emptyAppHooks

mainWithHooks :: AppHooks -> IO ()
mainWithHooks hooks = do
  invocation <- customExecParser (prefs subparserInline) (opsCommandTree hooks)
  exitCode <- runOpsInvocation hooks invocation
  Exit.exitWith exitCode

runOpsInvocation :: AppHooks -> OpsInvocation -> IO Exit.ExitCode
runOpsInvocation hooks invocation = do
  result <- try (runInvocation hooks invocation)
  case result of
    Left exception ->
      case fromException exception :: Maybe Exit.ExitCode of
        Just exitCode -> pure exitCode
        Nothing -> operationalFailure (Text.pack (displayException (exception :: SomeException)))
    Right exitCode -> pure exitCode

data OpsInvocation = OpsInvocation
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
  | ReplayAudit ReplayAudit.Command
  | Rebuild Rebuild.Command

opsCommandTree :: AppHooks -> ParserInfo OpsInvocation
opsCommandTree hooks =
  info
    (invocationParser hooks <**> helper)
    ( fullDesc
        <> progDesc "Inspect and operate a Keiro deployment"
        <> failureCode 2
    )

invocationParser :: AppHooks -> Parser OpsInvocation
invocationParser hooks = OpsInvocation <$> globalOptionsParser <*> commandParser hooks

commandParser :: AppHooks -> Parser Command
commandParser hooks =
  hsubparser
    ( command
        "wf"
        ( info
            (Workflow <$> Workflow.commandParserWithResume (isJust hooks.workflowResume))
            (progDesc "Inspect and operate durable workflows")
        )
        <> command
          "timer"
          ( info
              (Timer <$> Timer.commandParserWithDrain (isJust hooks.timerFire))
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
        <> replayAuditCommand
        <> rebuildCommand
    )
  where
    replayAuditCommand =
      case hooks.replayAudit of
        Nothing -> mempty
        Just _ ->
          command
            "replay-audit"
            (info (ReplayAudit <$> ReplayAudit.commandParser) (progDesc "Audit candidate-code replay against configured targets"))
    rebuildCommand =
      case hooks.projectionCatalog of
        Nothing -> mempty
        Just _ ->
          command
            "rebuild"
            (info (Rebuild <$> Rebuild.commandParser) (progDesc "Inspect and operate the mounted projection catalog"))

runInvocation :: AppHooks -> OpsInvocation -> IO Exit.ExitCode
runInvocation hooks OpsInvocation {globalOptions, opsCommand} = do
  connectionString <- resolveConnectionString globalOptions.databaseUrl
  verified <- verifyExpectedSchema (Settings.connectionString connectionString)
  case verified of
    Left migrationError ->
      operationalFailure ("schema verification failed: " <> Text.pack (show migrationError))
    Right drifts -> do
      let renderedDrifts = map renderSchemaDrift drifts
      traverse_ (Text.IO.hPutStrLn stderr . ("warning: " <>)) renderedDrifts
      if isMutation opsCommand && not (null drifts) && not globalOptions.allowSchemaDrift
        then
          operationalFailure
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
          runCommand hooks env opsCommand >>= finishOutcome env

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
  ReplayAudit _ -> False
  Rebuild rebuildCommand -> Rebuild.isMutation rebuildCommand

runCommand :: AppHooks -> OpsEnv -> Command -> IO OpsOutcome
runCommand hooks env = \case
  Workflow workflowCommand -> Workflow.runCommandWithResume hooks.workflowResume env workflowCommand
  Timer timerCommand -> Timer.runCommandWithFire hooks.timerFire env timerCommand
  Outbox outboxCommand -> Outbox.runCommand env outboxCommand
  Inbox inboxCommand -> Inbox.runCommand env inboxCommand
  Pgmq pgmqCommand -> Pgmq.runCommand env pgmqCommand
  Projection projectionCommand -> Projection.runCommand env projectionCommand
  Shard shardCommand -> Shard.runCommand env shardCommand
  Snapshot snapshotCommand -> Snapshot.runCommand env snapshotCommand
  Stream streamCommand -> Stream.runCommand env streamCommand
  ReplayAudit replayAuditCommand ->
    maybe
      (pure (Failed "replay audit hook is not mounted"))
      (\config -> ReplayAudit.runCommand env config replayAuditCommand)
      hooks.replayAudit
  Rebuild rebuildCommand ->
    maybe
      (pure (Failed "projection catalog hook is not mounted"))
      (\operations -> Rebuild.runCommand env operations rebuildCommand)
      hooks.projectionCatalog

finishOutcome :: OpsEnv -> OpsOutcome -> IO Exit.ExitCode
finishOutcome env = \case
  Succeeded result -> renderResult env result >> pure Exit.ExitSuccess
  SucceededWithExit result exitCode -> renderResult env result >> pure exitCode
  PreviewRequired result reinvocation -> do
    renderResult env result
    Text.IO.hPutStrLn stderr ("preview only; re-run with --force: " <> reinvocation)
    pure (Exit.ExitFailure 1)
  Failed message -> operationalFailure message

operationalFailure :: Text.Text -> IO Exit.ExitCode
operationalFailure message = do
  Text.IO.hPutStrLn stderr ("keiro-ops: " <> message)
  pure (Exit.ExitFailure 1)
