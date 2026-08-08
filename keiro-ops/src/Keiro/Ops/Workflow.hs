module Keiro.Ops.Workflow
  ( Command,
    commandParser,
    runCommand,
  )
where

import Data.Text.IO qualified as Text.IO
import Options.Applicative

data Command = ShowHelp

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command
        "help"
        (info (pure ShowHelp) (progDesc "Describe the workflow command domain"))
    )

runCommand :: Command -> IO ()
runCommand ShowHelp = Text.IO.putStrLn "Workflow operations are available under keiro-ops wf."
