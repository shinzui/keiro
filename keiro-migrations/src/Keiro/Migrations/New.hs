{- | Generate a new timestamped Keiro migration skeleton.

The embedded migrations are ordered by their @YYYY-MM-DD-HH-MM-SS-slug.sql@
file names (lexicographic order == chronological order because every field is
fixed-width and zero-padded). 'newMigrationFile' stamps the /real/ current UTC
time, so two migrations authored at different moments can never collide and
always sort in authoring order — no hand-assigned slots to coordinate.
-}
module Keiro.Migrations.New
  ( newMigrationFile
  , defaultMigrationsDir
  , migrationFileName
  , migrationSlug
  , migrationTemplate
  )
where

import Control.Monad (when)
import Data.Char (isAlphaNum, toLower)
import Data.List (isPrefixOf)
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

-- | Directory (relative to the keiro-migrations package root) that holds the
-- embedded SQL migrations. Override with @KEIRO_MIGRATIONS_DIR@ in the caller.
defaultMigrationsDir :: FilePath
defaultMigrationsDir = "sql-migrations"

-- | Create a new migration skeleton under @dir@, named for the current UTC
-- time, and return the path written. Fails if @description@ has no
-- alphanumeric content, or if the (extraordinarily unlikely) target path
-- already exists — we never overwrite an existing migration.
newMigrationFile :: FilePath -> String -> IO FilePath
newMigrationFile dir description = do
  when (not (any isAlphaNum description)) $
    ioError (userError "migration description must contain at least one letter or digit")
  now <- getCurrentTime
  let path = dir </> migrationFileName now description
  createDirectoryIfMissing True dir
  exists <- doesFileExist path
  when exists $
    ioError (userError ("refusing to overwrite existing migration: " <> path))
  writeFile path (migrationTemplate description)
  pure path

-- | The file name for a migration authored at the given time, e.g.
-- @2026-06-05-14-32-07-keiro-add-foo.sql@.
migrationFileName :: UTCTime -> String -> FilePath
migrationFileName now description =
  formatTime defaultTimeLocale "%Y-%m-%d-%H-%M-%S" now
    <> "-"
    <> migrationSlug description
    <> ".sql"

-- | Normalise a free-text description into the file-name slug: lower-case,
-- non-alphanumeric runs become single dashes, ends trimmed, and a @keiro-@
-- prefix ensured to match the existing convention
-- (@keiro-bootstrap@, @keiro-workflow-steps@, …).
migrationSlug :: String -> String
migrationSlug raw =
  let dashed = map (\c -> if isAlphaNum c then toLower c else '-') raw
      trimmed = trimDashes (collapseDashes dashed)
   in if "keiro-" `isPrefixOf` trimmed then trimmed else "keiro-" <> trimmed
 where
  collapseDashes ('-' : '-' : rest) = collapseDashes ('-' : rest)
  collapseDashes (c : rest) = c : collapseDashes rest
  collapseDashes [] = []
  trimDashes = f . f where f = reverse . dropWhile (== '-')

-- | The skeleton body, matching the current convention: a descriptive header
-- comment, the session @search_path@ pin (so unqualified names resolve into
-- the kiroku schema on incremental upgrades), then a body placeholder.
migrationTemplate :: String -> String
migrationTemplate description =
  unlines
    [ "-- " <> description
    , "--"
    , "-- Pin the session search_path so unqualified names resolve into the kiroku"
    , "-- schema when this migration is applied incrementally to an existing database"
    , "-- (search_path is session-scoped; see"
    , "-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md)."
    , "SET search_path TO kiroku, pg_catalog;"
    , ""
    , "-- TODO: write the migration body. Prefer idempotent DDL (IF NOT EXISTS)."
    ]
