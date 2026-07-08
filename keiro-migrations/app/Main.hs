module Main (
    main,
)
where

import Codd (ApplyResult (..), CoddSettings (..), VerifySchemas (LaxCheck))
import Codd.Environment (getCoddSettings)
import Codd.Extras.Guards (renderChecksumManifest)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.Foldable (traverse_)
import Data.List (isSuffixOf, sort)
import Data.Maybe (fromMaybe)
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, secondsToDiffTime)
import Keiro.Migrations (
    LedgerSchema (..),
    MigrationStatus (..),
    VerifyOutcome (..),
    migrationStatus,
    runAllKeiroMigrations,
    runAllKeiroMigrationsNoCheck,
    verifySchema,
 )
import Keiro.Migrations.New (defaultMigrationsDir, newMigrationFile)
import System.Directory (listDirectory)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    case args of
        [] -> migrate
        ["up"] -> migrate
        ["verify"] -> verify
        ["status"] -> status
        ("new" : rest) -> generate (unwords rest)
        ("lock" : _) -> writeLock
        other -> usage other

{- | @keiro-migrate new <description>@: write a timestamped migration skeleton.
The target directory defaults to the package's @sql-migrations@ (run from the
keiro-migrations package root) and can be overridden with @KEIRO_MIGRATIONS_DIR@.
-}
generate :: String -> IO ()
generate description
    | all (== ' ') description =
        ioError (userError "usage: keiro-migrate new <description>")
    | otherwise = do
        dir <- fromMaybe defaultMigrationsDir <$> lookupEnv "KEIRO_MIGRATIONS_DIR"
        path <- newMigrationFile dir description
        putStrLn ("Created " <> path)
        putStrLn
            "Next: touch the embed comment in src/Keiro/Migrations.hs so embedDir picks it up (or run `cabal clean`)."

migrate :: IO ()
migrate = do
    settings <- getCoddSettings
    noCheck <- parseNoCheckEnv =<< lookupEnv "KEIRO_MIGRATE_NO_CHECK"
    case noCheck of
        NoCheck ->
            runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)
        Checked -> do
            result <- runAllKeiroMigrations settings (secondsToDiffTime 5) LaxCheck
            case result of
                SchemasMatch _ -> pure ()
                SchemasNotVerified -> pure ()
                SchemasDiffer _ -> do
                    hPutStrLn stderr "schema drift detected; see the codd diff above"
                    exitWith (ExitFailure 1)

writeLock :: IO ()
writeLock = do
    dir <- fromMaybe defaultMigrationsDir <$> lookupEnv "KEIRO_MIGRATIONS_DIR"
    names <- filter (".sql" `isSuffixOf`) <$> listDirectory dir
    sources <- traverse (\name -> (\bytes -> (name, bytes)) <$> BS.readFile (dir <> "/" <> name)) (sort names)
    TIO.writeFile "migrations.lock" (renderChecksumManifest sources)
    putStrLn ("Wrote migrations.lock (" <> show (length sources) <> " migrations)")

status :: IO ()
status = do
    settings <- getCoddSettings
    migrationStatus settings (secondsToDiffTime 5) >>= printStatus

verify :: IO ()
verify = do
    settings <- getCoddSettings
    outcome <- verifySchema settings (secondsToDiffTime 5)
    case outcome of
        VerifySucceeded -> putStrLn "Schema matches expected snapshot."
        VerifyFailed -> exitWith (ExitFailure 1)
        VerifyPending pending -> do
            hPutStrLn stderr "Cannot verify while migrations are pending:"
            traverse_ (hPutStrLn stderr . ("  " <>)) pending
            exitWith (ExitFailure 2)

printStatus :: MigrationStatus -> IO ()
printStatus MigrationStatus{statusLedgerSchema, statusApplied, statusPending} = do
    putStrLn ("Ledger: " <> maybe "not found" renderLedgerSchema statusLedgerSchema)
    putStrLn ("Applied (" <> show (length statusApplied) <> "):")
    traverse_ printApplied statusApplied
    putStrLn ("Pending (" <> show (length statusPending) <> "):")
    traverse_ (putStrLn . ("  " <>)) statusPending
    putStrLn ("applied " <> show (length statusApplied) <> ", pending " <> show (length statusPending))

renderLedgerSchema :: LedgerSchema -> String
renderLedgerSchema CoddLedger = "codd.sql_migrations"
renderLedgerSchema CoddSchemaLedger = "codd_schema.sql_migrations"

printApplied :: (FilePath, UTCTime) -> IO ()
printApplied (name, timestamp) =
    putStrLn ("  " <> name <> "   " <> show timestamp)

data CheckMode = Checked | NoCheck

parseNoCheckEnv :: Maybe String -> IO CheckMode
parseNoCheckEnv Nothing = pure Checked
parseNoCheckEnv (Just raw)
    | lowered `elem` ["1", "true", "yes"] = pure NoCheck
    | null raw = pure Checked
    | otherwise = do
        hPutStrLn stderr "Ignoring KEIRO_MIGRATE_NO_CHECK; accepted values are 1, true, yes"
        pure Checked
  where
    lowered = map toLower raw

usage :: [String] -> IO ()
usage args = do
    hPutStrLn stderr ("unknown keiro-migrate arguments: " <> unwords args)
    hPutStrLn stderr "usage: keiro-migrate [up | verify | status | new <description> | lock]"
    exitWith (ExitFailure 2)
