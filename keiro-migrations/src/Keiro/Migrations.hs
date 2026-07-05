{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Embedded codd migrations for Keiro.

Use 'keiroFrameworkMigrations' when composing Keiro-owned SQL with a
service's own migrations. Use 'allKeiroMigrations' or
'runAllKeiroMigrations' when the caller wants Kiroku's event-store schema and
Keiro's framework schema applied together in the required order.
-}
module Keiro.Migrations (
    keiroFrameworkMigrations,
    keiroMigrations,
    allKeiroMigrations,
    runKeiroMigrations,
    runKeiroMigrationsNoCheck,
    runAllKeiroMigrations,
    runAllKeiroMigrationsNoCheck,
)
where

import Codd (ApplyResult, CoddSettings, VerifySchemas, applyMigrations, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Kiroku.Store.Migrations qualified as Kiroku
import Streaming.Prelude qualified as Streaming

-- | Keiro-owned embedded SQL migrations, ordered by timestamped filename.
keiroFrameworkMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
keiroFrameworkMigrations =
    traverse parseEmbeddedMigration embeddedMigrationFiles
  where
    parseEmbeddedMigration :: forall m. (MonadFail m, EnvVars m) => (FilePath, ByteString) -> m (AddedSqlMigration m)
    parseEmbeddedMigration (name, bytes) = do
        let stream :: PureStream m
            stream = PureStream $ Streaming.yield (TE.decodeUtf8 bytes)
        result <- parseAddedSqlMigration name stream
        case result of
            Left err -> fail ("Invalid Keiro migration " <> name <> ": " <> err)
            Right migration -> pure migration

-- | Compatibility alias for Keiro-owned framework migrations only.
keiroMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
keiroMigrations = keiroFrameworkMigrations

-- | Kiroku event-store migrations followed by Keiro framework migrations.
allKeiroMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
allKeiroMigrations = do
    kiroku <- Kiroku.kirokuMigrations
    keiro <- keiroFrameworkMigrations
    pure (kiroku <> keiro)

-- | Run only Keiro-owned embedded migrations through codd.
runKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runKeiroMigrations settings connectTimeout verifySchemas =
    runCoddLogger $ do
        migrations <- keiroFrameworkMigrations
        applyMigrations settings (Just migrations) connectTimeout verifySchemas

{- | Run only Keiro-owned embedded migrations without schema verification.

This is useful for local development databases that do not keep a checked-in
codd expected-schema representation.
-}
runKeiroMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
runKeiroMigrationsNoCheck settings connectTimeout =
    runCoddLogger $ do
        migrations <- keiroFrameworkMigrations
        applyMigrationsNoCheck settings (Just migrations) connectTimeout (\_ -> pure ())

-- | Run Kiroku and Keiro embedded migrations through codd in one ledger.
runAllKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runAllKeiroMigrations settings connectTimeout verifySchemas =
    runCoddLogger $ do
        migrations <- allKeiroMigrations
        applyMigrations settings (Just migrations) connectTimeout verifySchemas

{- | Run Kiroku and Keiro embedded migrations without schema verification.

This preserves codd's migration ledger and locking behavior while skipping
expected-schema comparison for local development databases.
-}
runAllKeiroMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
runAllKeiroMigrationsNoCheck settings connectTimeout =
    runCoddLogger $ do
        migrations <- allKeiroMigrations
        applyMigrationsNoCheck settings (Just migrations) connectTimeout (\_ -> pure ())

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
embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")
