module Main (
    main,
)
where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings, VerifySchemas (LaxCheck))
import Codd.Extras.Cli (CheckMode (..), MigrationCliConfig (..), migrationCliMain)
import Data.Time (DiffTime, secondsToDiffTime)
import Keiro.Migrations (
    migrationStatus,
    runAllKeiroMigrations,
    runAllKeiroMigrationsNoCheck,
    verifySchema,
 )
import Keiro.Migrations.New (defaultMigrationsDir, newMigrationFile)

main :: IO ()
main =
    migrationCliMain
        MigrationCliConfig
            { cliProgramName = "keiro-migrate"
            , cliMigrationsDirEnv = "KEIRO_MIGRATIONS_DIR"
            , cliDefaultMigrationsDir = defaultMigrationsDir
            , cliNewMigrationFile = newMigrationFile
            , cliRunUp = runUp
            , cliVerifySchema = verifySchema
            , cliMigrationStatus = migrationStatus
            , cliConnectTimeout = secondsToDiffTime 5
            , cliNoCheckEnv = Just "KEIRO_MIGRATE_NO_CHECK"
            , cliEmbedRefreshHint =
                "Next: touch the embed comment in src/Keiro/Migrations.hs so embedDir picks it up (or run `cabal clean`)."
            }

runUp :: CheckMode -> CoddSettings -> DiffTime -> IO ApplyResult
runUp NoCheck settings connectTimeout =
    runAllKeiroMigrationsNoCheck settings connectTimeout >> pure SchemasNotVerified
runUp Checked settings connectTimeout =
    runAllKeiroMigrations settings connectTimeout LaxCheck
