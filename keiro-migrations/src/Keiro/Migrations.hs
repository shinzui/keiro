{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

{- | Embedded codd migrations for Keiro.

Use 'keiroFrameworkMigrations' when composing Keiro-owned SQL with a
service's own migrations. Use 'allKeiroMigrations' or
'runAllKeiroMigrations' when the caller wants Kiroku's event-store schema and
Keiro's framework schema applied together in the required order.
-}
module Keiro.Migrations
  ( keiroFrameworkMigrations
  , keiroMigrations
  , allKeiroMigrations
  , runKeiroMigrations
  , runAllKeiroMigrations
  )
where

import Codd (ApplyResult, CoddSettings, VerifySchemas, applyMigrations)
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

-- | Run Kiroku and Keiro embedded migrations through codd in one ledger.
runAllKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runAllKeiroMigrations settings connectTimeout verifySchemas =
  runCoddLogger $ do
    migrations <- allKeiroMigrations
    applyMigrations settings (Just migrations) connectTimeout verifySchemas

embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")
