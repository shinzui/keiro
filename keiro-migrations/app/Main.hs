module Main (
    main,
)
where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings, VerifySchemas (LaxCheck))
import Codd.Extras.Cli (CheckMode (..), MigrationCliConfig (..), migrationCliMain)
import Data.Time (DiffTime, secondsToDiffTime)
import Keiro.Migrations qualified as Migrations
import Keiro.Migrations.New qualified as New

main :: IO ()
main =
    migrationCliMain
        MigrationCliConfig
            { programName = "keiro-migrate"
            , migrationsDirEnv = "KEIRO_MIGRATIONS_DIR"
            , defaultMigrationsDir = New.defaultMigrationsDir
            , newMigrationFile = New.newMigrationFile
            , runUp = runUpMigrations
            , verifySchema = Migrations.verifySchema
            , migrationStatus = Migrations.migrationStatus
            , connectTimeout = secondsToDiffTime 5
            , noCheckEnv = Just "KEIRO_MIGRATE_NO_CHECK"
            , embedRefreshHint =
                "Next: touch the embed comment in src/Keiro/Migrations.hs so embedDir picks it up (or run `cabal clean`)."
            }

runUpMigrations :: CheckMode -> CoddSettings -> DiffTime -> IO ApplyResult
runUpMigrations NoCheck settings timeout =
    Migrations.runAllKeiroMigrationsNoCheck settings timeout >> pure SchemasNotVerified
runUpMigrations Checked settings timeout =
    Migrations.runAllKeiroMigrations settings timeout LaxCheck
