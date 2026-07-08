{- | Generate a new timestamped Keiro migration skeleton.

The embedded migrations are ordered by their @YYYY-MM-DD-HH-MM-SS-slug.sql@
file names (lexicographic order == chronological order because every field is
fixed-width and zero-padded). 'newMigrationFile' stamps the /real/ current UTC
time, so two migrations authored at different moments can never collide and
always sort in authoring order -- no hand-assigned slots to coordinate.
-}
module Keiro.Migrations.New (
    newMigrationFile,
    defaultMigrationsDir,
    migrationFileName,
    migrationSlug,
    migrationTemplate,
) where

import Codd.Extras.New qualified as New
import Data.Time (UTCTime)

defaultMigrationsDir :: FilePath
defaultMigrationsDir = New.defaultMigrationsDir

newMigrationFile :: FilePath -> String -> IO FilePath
newMigrationFile = New.newMigrationFile migrationFileConfig

migrationFileName :: UTCTime -> String -> FilePath
migrationFileName = New.migrationFileName migrationFileConfig

migrationSlug :: String -> String
migrationSlug = New.migrationSlug (Just "keiro")

migrationTemplate :: String -> String
migrationTemplate description =
    unlines
        [ "-- " <> description
        , "--"
        , "-- Create objects fully qualified in the keiro schema (no session path pin)."
        , "-- Example:"
        , "--   CREATE TABLE IF NOT EXISTS keiro.keiro_example ("
        , "--     id UUID PRIMARY KEY"
        , "--   );"
        , ""
        , "-- TODO: write the migration body. Prefer idempotent DDL (IF NOT EXISTS)."
        ]

migrationFileConfig :: New.MigrationFileConfig
migrationFileConfig =
    New.MigrationFileConfig
        { New.migrationSlugPrefix = Just "keiro"
        , New.migrationTemplate = migrationTemplate
        }
