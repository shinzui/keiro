{-# LANGUAGE TemplateHaskell #-}

module Keiro.Migrations.Internal.Definition (
    embeddedMigrationEntries,
    keiroMigrations,
) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate (
    DefinitionError,
    MigrationComponent,
    migrationComponentFromEmbeddedSql,
 )
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)

embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries =
    $(embedMigrationManifest "migrations/manifest")

keiroMigrations :: Either DefinitionError MigrationComponent
keiroMigrations =
    migrationComponentFromEmbeddedSql
        "keiro"
        (Set.singleton "kiroku")
        embeddedMigrationEntries
