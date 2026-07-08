{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Embedded codd migrations for Keiro.

Use 'keiroFrameworkMigrations' when composing Keiro-owned SQL with a
service's own migrations. Use 'allKeiroMigrations' or
'runAllKeiroMigrations' when the caller wants Kiroku's event-store schema and
Keiro's framework schema applied together in the required order.
-}
module Keiro.Migrations (
    LedgerSchema (..),
    MigrationStatus (..),
    VerifyOutcome (..),
    embeddedMigrationNames,
    embeddedMigrationSources,
    frameworkMigrationGroups,
    frameworkMigrationSets,
    keiroFrameworkMigrationSet,
    keiroFrameworkMigrations,
    keiroMigrations,
    allKeiroMigrations,
    migrationStatus,
    missingMigrations,
    runKeiroMigrations,
    runKeiroMigrationsNoCheck,
    runAllKeiroMigrations,
    runAllKeiroMigrationsNoCheck,
    verifySchema,
)
where

import Codd (ApplyResult, CoddSettings (..), VerifySchemas)
import Codd.Extras.Ledger (LedgerSchema (..), MigrationStatus (..), VerifyOutcome (..))
import Codd.Extras.MigrationSet (MigrationSet)
import Codd.Extras.MigrationSet qualified as MigrationSet
import Codd.Parsing (AddedSqlMigration, EnvVars)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Time (DiffTime)
import Keiro.Migrations.ExpectedSchema (expectedSchemaFiles)
import Kiroku.Store.Migrations qualified as Kiroku

-- | Keiro-owned embedded SQL migrations, ordered by timestamped filename.
keiroFrameworkMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
keiroFrameworkMigrations =
    MigrationSet.parseMigrationSet keiroFrameworkMigrationSet

-- | Compatibility alias for Keiro-owned framework migrations only.
keiroMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
keiroMigrations = keiroFrameworkMigrations

-- | Kiroku event-store migrations followed by Keiro framework migrations.
allKeiroMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
allKeiroMigrations =
    MigrationSet.parseMigrationSets frameworkMigrationSets

-- | Run only Keiro-owned embedded migrations through codd.
runKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runKeiroMigrations settings connectTimeout verifySchemas =
    MigrationSet.applyMigrationSet settings connectTimeout verifySchemas keiroFrameworkMigrationSet

{- | Run only Keiro-owned embedded migrations without schema verification.

This is useful for local development databases that do not keep a checked-in
codd expected-schema representation.
-}
runKeiroMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
runKeiroMigrationsNoCheck settings connectTimeout =
    void $ MigrationSet.applyMigrationSetNoCheck settings connectTimeout keiroFrameworkMigrationSet

frameworkMigrationGroups :: [(String, [(FilePath, ByteString)])]
frameworkMigrationGroups =
    MigrationSet.migrationGroups frameworkMigrationSets

frameworkMigrationSets :: [MigrationSet]
frameworkMigrationSets =
    [ kirokuMigrationSet
    , keiroFrameworkMigrationSet
    ]

kirokuMigrationSet :: MigrationSet
kirokuMigrationSet =
    MigrationSet.MigrationSet
        { MigrationSet.label = "Kiroku"
        , MigrationSet.files = Kiroku.embeddedMigrationSources
        }

-- | Run Kiroku and Keiro embedded migrations through codd in one ledger.
runAllKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runAllKeiroMigrations settings connectTimeout verifySchemas =
    MigrationSet.applyMigrationSets settings connectTimeout verifySchemas frameworkMigrationSets

{- | Run Kiroku and Keiro embedded migrations without schema verification.

This preserves codd's migration ledger and locking behavior while skipping
expected-schema comparison for local development databases.
-}
runAllKeiroMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
runAllKeiroMigrationsNoCheck settings connectTimeout =
    void $ MigrationSet.applyMigrationSetsNoCheck settings connectTimeout frameworkMigrationSets

verifySchema :: CoddSettings -> DiffTime -> IO VerifyOutcome
verifySchema =
    MigrationSet.verifyExpectedSchema
        expectedLedgerNames
        MigrationSet.ExpectedSchema
            { MigrationSet.label = "keiro-expected-schema"
            , MigrationSet.files = expectedSchemaFiles
            }

missingMigrations :: CoddSettings -> DiffTime -> IO [FilePath]
missingMigrations settings connectTimeout =
    MigrationSet.missingMigrationsForNames expectedLedgerNames (migsConnString settings) connectTimeout

migrationStatus :: CoddSettings -> DiffTime -> IO MigrationStatus
migrationStatus settings connectTimeout =
    MigrationSet.migrationStatusForNames expectedLedgerNames (migsConnString settings) connectTimeout

expectedLedgerNames :: [FilePath]
expectedLedgerNames =
    MigrationSet.migrationNamesForSets frameworkMigrationSets

-- Embedded migrations (touch this comment to force a TH recompile when adding
-- a new .sql file; embedDir is not tracked per-file by GHC's recompilation
-- checker). Every file name carries the real UTC authoring timestamp emitted
-- by `keiro-migrate new` (see "Keiro.Migrations.New"); never hand-assign a
-- rounded sentinel like -00-00-00. The migration-filename guard in the test
-- suite rejects such timestamps. Current set includes
-- 2026-06-03-16-10-05-keiro-workflow-steps.sql,
-- 2026-06-03-18-19-41-keiro-awakeables.sql,
-- 2026-06-03-19-49-23-keiro-workflow-children.sql, 2026-06-15-15-07-25-keiro-workflows-instances.sql, (EP-48/EP-6)
-- 2026-06-04-02-12-28-keiro-workflow-generation.sql, and (EP-51)
-- 2026-06-04-03-53-34-keiro-subscription-shards.sql,
-- 2026-06-15-21-49-37-keiro-projection-dedup.sql, and
-- 2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql, and
-- 2026-06-15-17-53-48-keiro-workflow-gc-index.sql, and
-- 2026-06-15-18-01-33-keiro-workflows-wake-after.sql, and
-- 2026-07-02-00-15-48-keiro-outbox-claim-order-index.sql, and
-- 2026-07-02-00-58-54-keiro-inbox-drop-received-idx.sql. (EP-2/M3)
-- EP-1 (MasterPlan 12): bodies rewritten to create/qualify the keiro schema.
-- 2026-07-06: integrity guard embed refresh.
embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")

keiroFrameworkMigrationSet :: MigrationSet
keiroFrameworkMigrationSet =
    MigrationSet.MigrationSet
        { MigrationSet.label = "Keiro"
        , MigrationSet.files = embeddedMigrationFiles
        }

embeddedMigrationSources :: [(FilePath, ByteString)]
embeddedMigrationSources = embeddedMigrationFiles

embeddedMigrationNames :: [FilePath]
embeddedMigrationNames =
    MigrationSet.migrationNames keiroFrameworkMigrationSet
