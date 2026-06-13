module Main (
    main,
)
where

import Codd (CoddSettings (..))
import Codd.AppCommands.WriteSchema (WriteSchemaOpts (WriteToDisk), writeSchema)
import Codd.Parsing (connStringParser)
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Keiro.Migrations (runAllKeiroMigrationsNoCheck)
import System.Environment (getArgs)

main :: IO ()
main = do
    outputDir <- parseArgs =<< getArgs
    result <- Pg.withCached $ \db -> do
        let connStr = Pg.connectionString db
            settings = coddSettings connStr outputDir
        runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)
        writeSchema settings (WriteToDisk (Just outputDir))
    case result of
        Left err -> fail ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right () -> putStrLn ("Wrote expected schema to " <> outputDir)

parseArgs :: [String] -> IO FilePath
parseArgs [] = pure "keiro-migrations/expected-schema"
parseArgs [outputDir] = pure outputDir
parseArgs _ = fail "usage: cabal run keiro-write-expected-schema -- [output-dir]"

coddSettings :: Text -> FilePath -> CoddSettings
coddSettings connStr expectedSchemaDir =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Left expectedSchemaDir
        , namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]
        , extraRolesToCheck = []
        , retryPolicy = singleTryPolicy
        , txnIsolationLvl = DbDefault
        , schemaAlgoOpts = SchemaAlgo False False False
        }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
    case parseOnly (connStringParser <* endOfInput) connStr of
        Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
        Right parsed -> parsed
