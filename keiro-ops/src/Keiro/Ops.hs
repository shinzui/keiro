module Keiro.Ops
  ( main,
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations.SchemaCheck (renderSchemaDrift, verifyExpectedSchema)
import Keiro.Ops.Env
import Keiro.Ops.Render
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
    Left exception -> failOperational (Text.pack (displayException (exception :: SomeException)))
    Right () -> pure ()

data Invocation = Invocation
  { globalOptions :: !GlobalOptions,
    opsCommand :: !Command
  }

data Command
  = Workflow Workflow.Command
  | Timer Timer.Command

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

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand env = \case
  Workflow workflowCommand -> Workflow.runCommand env workflowCommand
  Timer timerCommand -> Timer.runCommand env timerCommand

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
