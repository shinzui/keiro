module Main (
    main,
)
where

import Codd.Extras.WriteSchema (writeExpectedSchemaToDisk)
import Data.Time (secondsToDiffTime)
import Keiro.Migrations (runAllKeiroMigrationsNoCheck)
import System.Environment (getArgs)

main :: IO ()
main = do
    outputDir <- parseArgs =<< getArgs
    writeExpectedSchemaToDisk "keiro" ["keiro"] outputDir $ \settings ->
        runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)

parseArgs :: [String] -> IO FilePath
parseArgs [] = pure "keiro-migrations/expected-schema"
parseArgs [outputDir] = pure outputDir
parseArgs _ = fail "usage: cabal run keiro-write-expected-schema -- [output-dir]"
