module Main (
    main,
)
where

import Codd (ApplyResult (..), VerifySchemas (LaxCheck))
import Codd.Environment (getCoddSettings)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.List (isSuffixOf, sort)
import Data.Maybe (fromMaybe)
import Data.Text.IO qualified as TIO
import Data.Time (secondsToDiffTime)
import Keiro.Migrations (runAllKeiroMigrations, runAllKeiroMigrationsNoCheck)
import Keiro.Migrations.New (defaultMigrationsDir, newMigrationFile)
import Kiroku.Store.Migrations.Guards (renderChecksumManifest)
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
    hPutStrLn stderr "usage: keiro-migrate [up | new <description> | lock]"
    exitWith (ExitFailure 2)
