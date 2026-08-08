module Keiro.Ops.Workflow
  ( Command,
    commandParser,
    isMutation,
    runCommand,
  )
where

import Keiro.Ops.Env (OpsEnv)
import Keiro.Ops.Render (OpsOutcome (..), messageResult)
import Options.Applicative

data Command = ShowHelp

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command
        "help"
        (info (pure ShowHelp) (progDesc "Describe the workflow command domain"))
    )

isMutation :: Command -> Bool
isMutation ShowHelp = False

runCommand :: OpsEnv -> Command -> IO OpsOutcome
runCommand _ ShowHelp =
  pure (Succeeded (messageResult "Workflow operations are available under keiro-ops wf."))
