module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate (
    MigrationPlan,
    defaultRunOptions,
 )
import Database.PostgreSQL.Migrate.CLI
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations (frameworkMigrationPlan, keiroMigrations)
import Keiro.Migrations.SchemaCheck (
    renderSchemaDrift,
    verifyExpectedSchema,
 )
import Kiroku.Store.Migrations qualified as Kiroku
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit qualified as Exit

main :: IO ()
main = do
    kiroku <- either (fail . show) pure Kiroku.kirokuMigrations
    keiro <- either (fail . show) pure keiroMigrations
    plan <- either (fail . show) pure (frameworkMigrationPlan kiroku keiro)
    keiroCommand <-
        execParser
            ( info
                (keiroCommandParser plan <**> helper)
                (fullDesc <> progDesc "Manage the Kiroku and Keiro migration components")
            )
    defaultDatabaseUrl <- lookupEnv "DATABASE_URL"
    let defaultSettings =
            Settings.connectionString (Text.pack (maybe "" id defaultDatabaseUrl))
    case keiroCommand of
        Framework command -> do
            let environment = cliEnvironment defaultSettings plan defaultRunOptions
            outcome <- runMigrationCommand environment command
            case commandOutputFormat command of
                TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
                JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
            Exit.exitWith
                (case exitClass outcome of ExitSucceeded -> Exit.ExitSuccess; _ -> Exit.ExitFailure 1)
        VerifySchema options ->
            runVerifySchema defaultSettings options

data KeiroCommand
    = Framework MigrationCommand
    | VerifySchema VerifySchemaOptions

newtype VerifySchemaOptions = VerifySchemaOptions
    { verifySchemaDatabaseSettings :: Maybe Settings.Settings
    }

keiroCommandParser :: MigrationPlan -> Parser KeiroCommand
keiroCommandParser plan =
    (Framework <$> migrationCommandParser plan)
        <|> subparser
            ( commandGroup "Keiro"
                <> Options.Applicative.command
                    "verify-schema"
                    ( info
                        (VerifySchema <$> verifySchemaOptionsParser <**> helper)
                        (progDesc "Compare live keiro schema objects against the embedded expected snapshot")
                    )
            )

verifySchemaOptionsParser :: Parser VerifySchemaOptions
verifySchemaOptionsParser =
    VerifySchemaOptions
        <$> optional
            ( option
                databaseSettingsReader
                ( long "database-url"
                    <> metavar "URL"
                    <> help "PostgreSQL URI or keyword/value connection string; defaults to DATABASE_URL"
                )
            )

databaseSettingsReader :: ReadM Settings.Settings
databaseSettingsReader =
    Settings.connectionString . Text.pack <$> str

runVerifySchema :: Settings.Settings -> VerifySchemaOptions -> IO ()
runVerifySchema defaultSettings VerifySchemaOptions{verifySchemaDatabaseSettings} = do
    result <-
        verifyExpectedSchema
            (maybe defaultSettings id verifySchemaDatabaseSettings)
    case result of
        Left migrationError -> do
            Text.IO.putStrLn
                ("schema verification failed: " <> Text.pack (show migrationError))
            Exit.exitFailure
        Right [] ->
            Text.IO.putStrLn "schema verification succeeded"
        Right drifts -> do
            traverse_ (Text.IO.putStrLn . renderSchemaDrift) drifts
            Exit.exitFailure

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
