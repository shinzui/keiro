{-# LANGUAGE TemplateHaskell #-}
-- GHC 9.12 has no Template Haskell directory-dependency API, so a sibling SQL
-- file that is added or removed without being listed in the manifest leaves this
-- module looking up to date and silently skips manifest membership validation.
-- The plugin forces GHC to reconsider this module on every build it runs.
-- Note this cannot help when no Haskell source changes at all: cabal then
-- reports "Up to date" and never invokes GHC. A clean build revalidates, and
-- the migrations.native.lock suite test checks directory membership at test
-- runtime regardless.
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

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
