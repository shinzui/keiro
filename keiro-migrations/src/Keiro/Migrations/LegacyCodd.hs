{-# LANGUAGE TemplateHaskell #-}

{- | Transitional Codd-only tools retained for expected-schema snapshots,
remediation drills, and historical ledger fixups.

Normal migration execution uses 'Keiro.Migrations' and does not build this
module unless the @legacy-codd-tools@ Cabal flag is enabled.
-}
module Keiro.Migrations.LegacyCodd (
    LedgerSchema (..),
    MigrationStatus (..),
    VerifyOutcome (..),
    embeddedMigrationNames,
    embeddedMigrationSources,
    kirokuEmbeddedMigrationNames,
    migrationStatus,
    missingMigrations,
    runAllKeiroMigrations,
    runAllKeiroMigrationsNoCheck,
    runKirokuMigrationsNoCheck,
    verifySchema,
) where

import Codd (ApplyResult, CoddSettings (..), VerifySchemas)
import Codd.Extras.Ledger (LedgerSchema (..), MigrationStatus (..), VerifyOutcome (..))
import Codd.Extras.MigrationSet (MigrationSet)
import Codd.Extras.MigrationSet qualified as MigrationSet
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Time (DiffTime)
import Keiro.Migrations.ExpectedSchema (expectedSchemaFiles)
import Keiro.Migrations.History.Codd (keiroLegacyMigrationNames)
import Kiroku.Store.Migrations.History.Codd qualified as Kiroku

runAllKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runAllKeiroMigrations settings connectTimeout verifySchemas =
    MigrationSet.applyMigrationSets settings connectTimeout verifySchemas frameworkMigrationSets

runAllKeiroMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
runAllKeiroMigrationsNoCheck settings connectTimeout =
    void $ MigrationSet.applyMigrationSetsNoCheck settings connectTimeout frameworkMigrationSets

runKirokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
runKirokuMigrationsNoCheck settings connectTimeout =
    void $ MigrationSet.applyMigrationSetNoCheck settings connectTimeout kirokuMigrationSet

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

frameworkMigrationSets :: [MigrationSet]
frameworkMigrationSets =
    [ kirokuMigrationSet
    , keiroMigrationSet
    ]

kirokuMigrationSet :: MigrationSet
kirokuMigrationSet =
    MigrationSet.MigrationSet
        { MigrationSet.label = "Kiroku legacy evidence"
        , MigrationSet.files = sourceFiles Kiroku.kirokuLegacyMigrationNames Kiroku.kirokuCoddSourcePayloads
        }

keiroMigrationSet :: MigrationSet
keiroMigrationSet =
    MigrationSet.MigrationSet
        { MigrationSet.label = "Keiro legacy evidence"
        , MigrationSet.files = embeddedMigrationFiles
        }

sourceFiles ::
    (Foldable collection) =>
    collection FilePath ->
    Map.Map FilePath ByteString ->
    [(FilePath, ByteString)]
sourceFiles names payloads =
    [ (name, requirePayload name)
    | name <- toList names
    ]
  where
    requirePayload name =
        case Map.lookup name payloads of
            Just payload -> payload
            Nothing -> error ("missing checked-in legacy payload for " <> name)

embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")

embeddedMigrationSources :: [(FilePath, ByteString)]
embeddedMigrationSources = embeddedMigrationFiles

embeddedMigrationNames :: [FilePath]
embeddedMigrationNames =
    MigrationSet.migrationNames keiroMigrationSet

kirokuEmbeddedMigrationNames :: [FilePath]
kirokuEmbeddedMigrationNames =
    MigrationSet.migrationNames kirokuMigrationSet

expectedLedgerNames :: [FilePath]
expectedLedgerNames =
    MigrationSet.migrationNamesForSets frameworkMigrationSets
