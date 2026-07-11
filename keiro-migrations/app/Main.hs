module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate (defaultRunOptions)
import Database.PostgreSQL.Migrate.CLI
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations (frameworkMigrationPlan, keiroMigrations)
import Kiroku.Store.Migrations qualified as Kiroku
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit qualified as Exit

main :: IO ()
main = do
    kiroku <- either (fail . show) pure Kiroku.kirokuMigrations
    keiro <- either (fail . show) pure keiroMigrations
    plan <- either (fail . show) pure (frameworkMigrationPlan kiroku keiro)
    command <-
        execParser
            ( info
                (migrationCommandParser plan <**> helper)
                (fullDesc <> progDesc "Manage the Kiroku and Keiro migration components")
            )
    defaultDatabaseUrl <- lookupEnv "DATABASE_URL"
    let defaultSettings =
            Settings.connectionString (Text.pack (maybe "" id defaultDatabaseUrl))
        environment = cliEnvironment defaultSettings plan defaultRunOptions
    outcome <- runMigrationCommand environment command
    case commandOutputFormat command of
        TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
        JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
    Exit.exitWith
        (case exitClass outcome of ExitSuccess -> Exit.ExitSuccess; _ -> Exit.ExitFailure 1)

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat command =
    case command of
        Plan PlanOptions{output = OutputOptions format} -> format
        List ListOptions{output = OutputOptions format} -> format
        Check CheckOptions{output = OutputOptions format} -> format
        Status StatusOptions{output = OutputOptions format} -> format
        Verify VerifyOptions{output = OutputOptions format} -> format
        Up UpOptions{output = OutputOptions format} -> format
        Repair RepairOptions{output = OutputOptions format} -> format
        New NewOptions{output = OutputOptions format} -> format
