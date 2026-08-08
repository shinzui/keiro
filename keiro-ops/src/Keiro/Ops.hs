module Keiro.Ops
  ( main,
  )
where

import Keiro.Ops.Timer qualified as Timer
import Keiro.Ops.Workflow qualified as Workflow
import Options.Applicative

main :: IO ()
main = execParser parserInfo >>= runCommand

data Command
  = Workflow Workflow.Command
  | Timer Timer.Command

parserInfo :: ParserInfo Command
parserInfo =
  info
    (commandParser <**> helper)
    (fullDesc <> progDesc "Inspect and operate a Keiro deployment")

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command
        "wf"
        ( info
            (Workflow <$> Workflow.commandParser <**> helper)
            (progDesc "Inspect and operate durable workflows")
        )
        <> command
          "timer"
          ( info
              (Timer <$> Timer.commandParser <**> helper)
              (progDesc "Inspect and operate durable timers")
          )
    )

runCommand :: Command -> IO ()
runCommand = \case
  Workflow workflowCommand -> Workflow.runCommand workflowCommand
  Timer timerCommand -> Timer.runCommand timerCommand
