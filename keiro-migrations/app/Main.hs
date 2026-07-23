module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Foldable (toList, traverse_)
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate (
    Confirmation (..),
    HistoryImportError (..),
    HistoryImportOutcome (..),
    HistoryImportReport (..),
    HistoryImportResult (..),
    MigrationId,
    MigrationPlan,
    connectionProviderFromSettings,
    defaultImportOptions,
    defaultRunOptions,
 )
import Database.PostgreSQL.Migrate.CLI
import Database.PostgreSQL.Migrate.History.Codd (
    CoddImportError (..),
    defaultCoddLockKey,
    importCoddHistory,
    withCoddLockKey,
 )
import Database.PostgreSQL.Migrate.Internal (
    componentNameText,
    migrationIdComponent,
    migrationIdName,
    migrationNameText,
 )
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations (
    CoddLedgerPreflight (..),
    frameworkMigrationPlan,
    keiroMigrations,
    preflightFreshLedgerOverCodd,
    renderCoddPreflight,
 )
import Keiro.Migrations.History.Codd (
    frameworkCoddHistoryMappings,
    frameworkCoddSourceConfig,
 )
import Keiro.Migrations.SchemaCheck (
    renderSchemaDrift,
    verifyExpectedSchema,
 )
import Kiroku.Store.Migrations qualified as Kiroku
import Numeric qualified
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit qualified as Exit
import System.IO (stderr)
import Text.Read qualified as Read

main :: IO ()
main = do
    kiroku <- either (fail . show) pure Kiroku.kirokuMigrations
    keiro <- either (fail . show) pure keiroMigrations
    plan <- either (fail . show) pure (frameworkMigrationPlan kiroku keiro)
    invocation <-
        execParser
            ( info
                (keiroInvocationParser plan <**> helper)
                (fullDesc <> progDesc "Manage the Kiroku and Keiro migration components")
            )
    defaultDatabaseUrl <- lookupEnv "DATABASE_URL"
    let defaultSettings =
            Settings.connectionString (Text.pack (maybe "" id defaultDatabaseUrl))
    runKeiroInvocation defaultSettings plan invocation

data KeiroInvocation = KeiroInvocation
    { allowFreshLedgerOverCodd :: Bool
    , keiroCommand :: KeiroCommand
    }

runKeiroInvocation ::
    Settings.Settings ->
    MigrationPlan ->
    KeiroInvocation ->
    IO ()
runKeiroInvocation
    defaultSettings
    plan
    KeiroInvocation{allowFreshLedgerOverCodd, keiroCommand} = do
        if allowFreshLedgerOverCodd && not (isUpCommand keiroCommand)
            then do
                Text.IO.hPutStrLn
                    stderr
                    "--allow-fresh-ledger-over-codd applies only to up"
                Exit.exitFailure
            else pure ()
        case keiroCommand of
            Framework command -> do
                preflightFrameworkUp defaultSettings allowFreshLedgerOverCodd command
                let environment = cliEnvironment defaultSettings plan defaultRunOptions
                outcome <- runMigrationCommand environment command
                case commandOutputFormat command of
                    TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
                    JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
                Exit.exitWith
                    (case exitClass outcome of ExitSucceeded -> Exit.ExitSuccess; _ -> Exit.ExitFailure 1)
            VerifySchema options ->
                runVerifySchema defaultSettings options
            ImportCoddHistory options ->
                runImportCoddHistory defaultSettings plan options

isUpCommand :: KeiroCommand -> Bool
isUpCommand keiroCommand =
    case keiroCommand of
        Framework Up{} -> True
        _ -> False

preflightFrameworkUp ::
    Settings.Settings ->
    Bool ->
    MigrationCommand ->
    IO ()
preflightFrameworkUp defaultSettings allowFreshLedgerOverCodd command =
    case command of
        Up UpOptions{connection = ConnectionOptions{databaseSettings}}
            | not allowFreshLedgerOverCodd -> do
                result <-
                    preflightFreshLedgerOverCodd
                        (maybe defaultSettings id databaseSettings)
                case result of
                    Left migrationError -> do
                        Text.IO.hPutStrLn
                            stderr
                            ( "codd-ledger preflight failed: "
                                <> Text.pack (show migrationError)
                            )
                        Exit.exitFailure
                    Right CoddPreflightClear -> pure ()
                    Right blocked@CoddPreflightBlocked{} -> do
                        Text.IO.hPutStrLn stderr (renderCoddPreflight blocked)
                        Exit.exitFailure
        _ -> pure ()

data KeiroCommand
    = Framework MigrationCommand
    | VerifySchema VerifySchemaOptions
    | ImportCoddHistory ImportCoddOptions

newtype VerifySchemaOptions = VerifySchemaOptions
    { verifySchemaDatabaseSettings :: Maybe Settings.Settings
    }

data ImportCoddOptions = ImportCoddOptions
    { importTargetSettings :: Maybe Settings.Settings
    , importSourceSettings :: Maybe Settings.Settings
    , importSourceLockKey :: Int64
    , importReason :: Text.Text
    , importConfirmation :: Confirmation
    , importJsonOutput :: Bool
    }

keiroInvocationParser :: MigrationPlan -> Parser KeiroInvocation
keiroInvocationParser plan =
    KeiroInvocation
        <$> switch
            ( long "allow-fresh-ledger-over-codd"
                <> help
                    "Allow up to initialize native history even when a codd ledger exists"
            )
        <*> keiroCommandParser plan

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
                <> Options.Applicative.command
                    "import-codd-history"
                    ( info
                        (ImportCoddHistory <$> importCoddOptionsParser <**> helper)
                        (progDesc "Import verified codd history into the native migration ledger")
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

importCoddOptionsParser :: Parser ImportCoddOptions
importCoddOptionsParser =
    ImportCoddOptions
        <$> optional
            ( option
                databaseSettingsReader
                ( long "database-url"
                    <> metavar "URL"
                    <> help "Target PostgreSQL connection string; defaults to DATABASE_URL"
                )
            )
        <*> optional
            ( option
                databaseSettingsReader
                ( long "source-database-url"
                    <> metavar "URL"
                    <> help "Codd source connection string; defaults to the target database"
                )
            )
        <*> option
            lockKeyReader
            ( long "source-lock-key"
                <> metavar "INT64"
                <> value defaultCoddLockKey
                <> showDefault
                <> help "Cooperating legacy wrapper advisory-lock key (decimal or 0x hexadecimal)"
            )
        <*> (Text.pack <$> strOption (long "reason" <> metavar "TEXT" <> help "Audited reason for the history import"))
        <*> flag
            NotConfirmed
            Confirmed
            (long "confirm" <> help "Confirm the checked-in codd source evidence")
        <*> switch (long "json" <> help "Emit JSON schema version 1 conventions")

lockKeyReader :: ReadM Int64
lockKeyReader = eitherReader $ \input ->
    case input of
        '0' : 'x' : hexadecimal ->
            case (Numeric.readHex hexadecimal :: [(Integer, String)]) of
                [(parsed, "")] -> checkedInt64 parsed
                _ -> Left lockKeyError
        _ ->
            case (Read.readMaybe input :: Maybe Integer) of
                Just parsed -> checkedInt64 parsed
                Nothing -> Left lockKeyError
  where
    checkedInt64 parsed
        | parsed < toInteger (minBound :: Int64) = Left lockKeyError
        | parsed > toInteger (maxBound :: Int64) = Left lockKeyError
        | otherwise = Right (fromInteger parsed)

    lockKeyError = "expected an Int64 decimal or 0x hexadecimal advisory-lock key"

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

runImportCoddHistory ::
    Settings.Settings ->
    MigrationPlan ->
    ImportCoddOptions ->
    IO ()
runImportCoddHistory
    defaultSettings
    plan
    ImportCoddOptions
        { importTargetSettings
        , importSourceSettings
        , importSourceLockKey
        , importReason
        , importConfirmation
        , importJsonOutput
        } = do
        let targetSettings = maybe defaultSettings id importTargetSettings
            sourceSettings = maybe targetSettings id importSourceSettings
            targetProvider = connectionProviderFromSettings targetSettings
            sourceProvider = connectionProviderFromSettings sourceSettings
        case frameworkCoddSourceConfig
            sourceProvider
            True
            importReason
            importConfirmation of
            Left definitionError -> do
                Text.IO.hPutStrLn
                    stderr
                    ("codd history import definition failed: " <> Text.pack (show definitionError))
                Exit.exitFailure
            Right baseConfig -> do
                let config =
                        if importSourceLockKey == defaultCoddLockKey
                            then baseConfig
                            else withCoddLockKey importSourceLockKey baseConfig
                result <-
                    importCoddHistory
                        defaultImportOptions
                        config
                        targetProvider
                        plan
                        frameworkCoddHistoryMappings
                case result of
                    Left importError -> do
                        Text.IO.hPutStrLn stderr (renderCoddImportError importError)
                        Exit.exitFailure
                    Right report
                        | importJsonOutput ->
                            LazyByteString.putStrLn
                                (Aeson.encode (renderHistoryImportJson "codd" report))
                        | otherwise ->
                            Text.IO.putStr (renderHistoryImportText report)

renderHistoryImportText :: HistoryImportReport -> Text.Text
renderHistoryImportText HistoryImportReport{importResults} =
    Text.unlines (renderResult <$> toList importResults)
  where
    renderResult HistoryImportResult{importedMigration, importOutcome} =
        outcomeText importOutcome <> " " <> migrationIdText importedMigration

    outcomeText Imported = "imported"
    outcomeText AlreadyImported = "already imported"

migrationIdText :: MigrationId -> Text.Text
migrationIdText identifier =
    componentNameText (migrationIdComponent identifier)
        <> "/"
        <> migrationNameText (migrationIdName identifier)

renderCoddImportError :: CoddImportError -> Text.Text
renderCoddImportError importError =
    "codd history import failed: "
        <> Text.pack (show importError)
        <> recoveryHint importError
  where
    recoveryHint CoddSelectedFilenameMissing{} = filenameRealignmentHint
    recoveryHint CoddStrictSourceHasUnselected{} = filenameRealignmentHint
    recoveryHint (CoddTargetImportFailed HistoryImportConflict{}) =
        " The native ledger already has rows without import evidence; see the recovery "
            <> "procedure in docs/user/upgrading-to-the-keiro-schema.md."
    recoveryHint _ = ""

    filenameRealignmentHint =
        " If this ledger predates the 2026-07-05 filename realignment, run "
            <> "keiro-migrations/ledger-fixups/"
            <> "2026-07-05-realign-keiro-migration-timestamps.sql first."

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
