{- | The @keiro-dsl@ command-line tool. EP-1 ships the @parse@ and @check@
subcommands; a later milestone adds @scaffold@ to the same
optparse-applicative command tree.
-}
module Main (main) where

import Control.Monad (unless)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Parser (parseSpec)
import Keiro.Dsl.PrettyPrint (renderSpec)
import Keiro.Dsl.Validate (renderDiagnostic, validateSpec)
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data Command
    = Parse FilePath
    | Check FilePath

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
            <> command
                "check"
                (info (Check <$> fileArg <**> helper) (progDesc "Validate a .kdsl file; print diagnostics and exit non-zero on any error"))
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
run (Check fp) = do
    input <- TIO.readFile fp
    case parseSpec fp input of
        Left err -> do
            hPutStrLn stderr (T.unpack err)
            exitFailure
        Right spec -> do
            let diags = validateSpec spec
            unless (null diags) $ do
                mapM_ (TIO.hPutStrLn stderr . renderDiagnostic fp) diags
                exitFailure
            putStrLn "OK"
