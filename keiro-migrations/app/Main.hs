module Main (
    main,
)
where

import Codd (VerifySchemas (LaxCheck))
import Codd.Environment (getCoddSettings)
import Data.Maybe (fromMaybe)
import Data.Time (secondsToDiffTime)
import Keiro.Migrations (runAllKeiroMigrations, runAllKeiroMigrationsNoCheck)
import Keiro.Migrations.New (defaultMigrationsDir, newMigrationFile)
import System.Environment (getArgs, lookupEnv)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("new" : rest) -> generate (unwords rest)
        _ -> migrate

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
    noCheck <- lookupEnv "KEIRO_MIGRATE_NO_CHECK"
    case noCheck of
        Just _ ->
            runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)
        Nothing -> do
            _ <- runAllKeiroMigrations settings (secondsToDiffTime 5) LaxCheck
            pure ()
