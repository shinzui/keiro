module Keiro.Ops
  ( main,
    mainWithHooks,
    AppHooks (..),
    AggregateInspectors,
    ProcessManagerInspectors,
    OpsAuditConfig (..),
    emptyAppHooks,
    OpsInvocation (..),
    Command (..),
    opsCommandTree,
    commandParser,
    validateCommand,
    isMutation,
    runCommand,
    runCommandWithHeaderCache,
    runOpsInvocation,
  )
where

import Control.Exception (SomeException, displayException, fromException, try)
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations.SchemaCheck (renderSchemaDrift, verifyExpectedSchema)
import Keiro.Ops.Aggregate qualified as Aggregate
import Keiro.Ops.Embed
import Keiro.Ops.Env
import Keiro.Ops.Inbox qualified as Inbox
import Keiro.Ops.Outbox qualified as Outbox
import Keiro.Ops.Pgmq qualified as Pgmq
import Keiro.Ops.ProcessManager qualified as ProcessManager
import Keiro.Ops.Projection qualified as Projection
import Keiro.Ops.Rebuild qualified as Rebuild
import Keiro.Ops.Render
import Keiro.Ops.ReplayAudit qualified as ReplayAudit
import Keiro.Ops.Shard qualified as Shard
import Keiro.Ops.Snapshot qualified as Snapshot
import Keiro.Ops.Stream qualified as Stream
import Keiro.Ops.Timer qualified as Timer
import Keiro.Ops.Workflow qualified as Workflow
import Keiro.Ops.WorkflowHeaderCache (WorkflowHeaderCache, runHeaderCached)
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

-- | Programmatic front-end boundary. Alternative front ends must verify the
-- live schema, use JSON output mode, and respect 'isMutation'.
data Command
  = ProcessManager ProcessManager.Command
  | Aggregate Aggregate.Command
  | Workflow Workflow.Command
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

-- | The authoritative command grammar, including only mounted hooks.
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
        <> aggregateCommand
        <> processManagerCommand
    )
  where
    processManagerCommand = case hooks.processManagers of
      Nothing -> mempty
      Just _ -> command "pm" (info (ProcessManager <$> ProcessManager.commandParser) (progDesc "Inspect mounted process managers"))
    aggregateCommand =
      case hooks.aggregates of
        Nothing -> mempty
        Just _ -> command "aggregate" (info (Aggregate <$> Aggregate.commandParser) (progDesc "Inspect mounted aggregates"))
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

-- | Validate supported command arguments before admission or schema work.
validateCommand :: Command -> Either (Text.Text, Text.Text) ()
validateCommand (ProcessManager command) = ProcessManager.validateCommand command
validateCommand (Aggregate command) = Aggregate.validateCommand command
validateCommand (Workflow command) = Workflow.validateCommand command
validateCommand (Timer command) = Timer.validateCommand command
validateCommand (Projection command) = Projection.validateCommand command
validateCommand _ = Right ()

-- | Authoritative read/write classification for every front end.
isMutation :: Command -> Bool
isMutation = \case
  ProcessManager command -> ProcessManager.isMutation command
  Aggregate command -> Aggregate.isMutation command
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

-- | Reuse only pure header presentation after an exact fresh database check.
-- The optional bytes encode this outcome's successful read result. Other
-- commands use the ordinary authoritative runner without a cache lookup.
runCommandWithHeaderCache :: WorkflowHeaderCache -> AppHooks -> OpsEnv -> Command -> IO (OpsOutcome, Maybe ByteString)
runCommandWithHeaderCache cache _ env (Workflow (Workflow.Inspect (Workflow.InspectHeader ref))) = runHeaderCached cache env ref
runCommandWithHeaderCache _ hooks env command = do
  outcome <- runCommand hooks env command
  pure (outcome, Nothing)

-- | Execute a parsed command after schema verification. Front ends must use
-- JSON mode and enable force only after explicit mutation confirmation.
runCommand :: AppHooks -> OpsEnv -> Command -> IO OpsOutcome
runCommand hooks env = \case
  ProcessManager command -> maybe (pure (Failed "process-manager inspection hook is not mounted")) (\catalog -> ProcessManager.runCommand catalog env command) hooks.processManagers
  Aggregate command -> maybe (pure (Failed "aggregate inspection hook is not mounted")) (\catalog -> Aggregate.runCommand env catalog command) hooks.aggregates
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
  InspectionFailed code message -> operationalFailure (code <> ": " <> message)

operationalFailure :: Text.Text -> IO Exit.ExitCode
operationalFailure message = do
  Text.IO.hPutStrLn stderr ("keiro-ops: " <> message)
  pure (Exit.ExitFailure 1)
