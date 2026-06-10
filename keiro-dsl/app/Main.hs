{- | The @keiro-dsl@ command-line tool. EP-1 ships the @parse@ subcommand; later
milestones add @check@ and @scaffold@ to the same optparse-applicative command
tree.
-}
module Main (main) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec)
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

newtype Command
    = Parse FilePath

main :: IO ()
main = run =<< execParser opts
  where
    opts =
        info
            (commands <**> helper)
            (fullDesc <> progDesc "keiro-dsl: a typed-specification toolchain for keiro services")

commands :: Parser Command
commands =
    subparser
        ( command
            "parse"
            (info (Parse <$> fileArg <**> helper) (progDesc "Parse a .kdsl file and pretty-print it back"))
        )

fileArg :: Parser FilePath
fileArg = argument str (metavar "FILE" <> help "Path to a .kdsl spec (use /dev/stdin for stdin)")

run :: Command -> IO ()
run (Parse fp) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> TIO.putStrLn (renderSpec spec)
