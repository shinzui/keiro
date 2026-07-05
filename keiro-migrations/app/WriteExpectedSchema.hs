module Main (
    main,
)
where

import Codd (CoddSettings (..))
import Codd.AppCommands.WriteSchema (WriteSchemaOpts (WriteToDisk), writeSchema)
import Codd.Parsing (connStringParser)
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Control.Exception (finally)
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Keiro.Migrations (runAllKeiroMigrationsNoCheck)
import System.Environment (getArgs)

{- | Pin the ephemeral PostgreSQL superuser to the fixed name @keiro@ so the
captured snapshot identity (roles, database owner, per-object owners) is
deterministic across machines and CI rather than the local OS username.
'Pg.withCachedConfig' is not exported, so we use 'Pg.startCached' + 'finally'.
-}
keiroPgConfig :: Pg.Config
keiroPgConfig = Pg.defaultConfig{Pg.user = "keiro"}

main :: IO ()
main = do
    outputDir <- parseArgs =<< getArgs
    started <- Pg.startCached keiroPgConfig Pg.defaultCacheConfig
    case started of
        Left err -> fail ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right db ->
            ( do
                let connStr = Pg.connectionString db
                    settings = coddSettings connStr outputDir
                runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)
                writeSchema settings (WriteToDisk (Just outputDir))
                putStrLn ("Wrote expected schema to " <> outputDir)
            )
                `finally` Pg.stop db

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
        , namespacesToCheck = IncludeSchemas [SqlSchema "keiro"]
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
