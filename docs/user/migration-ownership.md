# Migration Ownership

Keiro applications usually run one PostgreSQL database with three different table
owners:

- Kiroku owns the event-store tables in the `kiroku` schema.
- Keiro owns framework metadata in the `keiro` schema.
- Your application owns projection, read-model, reporting, and integration tables in
  schemas you choose.

Those ownership boundaries are operational boundaries. Framework schemas are changed
only by the shipped migration executables. Application schemas are changed only by
your application migrations. Neither side should issue DDL against the other's
objects.

The `jitsurei` worked example is the model: Keiro framework tables live in `keiro`,
Kiroku's event store lives in `kiroku`, and the application read model
`jitsurei_order_summary` lives in a separate `jitsurei` schema.

## Framework Migrations

`keiro-migrate` applies Kiroku's embedded event-store migrations first and Keiro's
embedded framework migrations second, in one codd ledger. The SQL files are
timestamped, embedded at compile time, protected by `migrations.lock`, and treated as
forward-only history.

Do not edit, rename, or copy framework migration files. codd decides whether a
migration has run by its filename, not by a body checksum. Editing a shipped file means
old databases skip the new body while fresh databases run it. The framework test
suites catch this with checksum manifests; application teams should adopt the same
discipline for their own migration directories.

Review `migrations.lock` changes during framework upgrades. A new framework migration
should add a lockfile entry. A checksum change for an old filename means a shipped body
changed and needs investigation.

## Application Migrations

Application migrations create your tables: projection tables, read-model tables,
materialized views, reporting schemas, and service-local integration state. Put them
outside `kiroku` and `keiro`.

Choose a schema explicitly. `ReadModel.schema`, `qualifiedTableName`,
`Keiro.Connection.qualifyTable`, `withProjectionSchema`,
`keiroConnectionSettings`, and `ensureProjectionSchema` are documented in
[Read Models And Projections](read-models-and-projections.md#choosing-your-projection-schema).
Production schema creation belongs in your migrations; `ensureProjectionSchema` is
for development, tests, and examples.

Author application SQL with the same safety rules as framework SQL:

- Use real UTC timestamp filenames: `YYYY-MM-DD-HH-MM-SS-description.sql`.
- Keep statements idempotent where possible: `CREATE TABLE IF NOT EXISTS`,
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, and similar.
- Hard-qualify every object as `<your_schema>.<object>`.
- Do not rely on `search_path`.
- Use `CREATE INDEX CONCURRENTLY` only in a codd no-transaction migration with
  `-- codd: no-txn`.

You can reuse Keiro's scaffolder for application files:

```bash
KEIRO_MIGRATIONS_DIR=db/migrations keiro-migrate new "add order summary"
```

Then replace the generated `keiro.keiro_example` placeholder with your application
schema and DDL.

### CI Guards

Use `Kiroku.Store.Migrations.Guards` over your application migration directory. This
example checks names, body lint, checksums, and timestamp uniqueness across the
combined framework-plus-application ledger:

```haskell
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

import Data.ByteString qualified as BS
import Data.List (isSuffixOf, sort)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Migrations qualified as Keiro
import Kiroku.Store.Migrations qualified as Kiroku
import Kiroku.Store.Migrations.Guards
import System.Directory (listDirectory)
import Test.Hspec

appMigrationDir :: FilePath
appMigrationDir = "db/migrations"

appMigrationFiles :: IO [FilePath]
appMigrationFiles =
  sort . filter (".sql" `isSuffixOf`) <$> listDirectory appMigrationDir

appMigrationSources :: IO [(FilePath, BS.ByteString)]
appMigrationSources = do
  names <- appMigrationFiles
  traverse
    (\name -> do
      bytes <- BS.readFile (appMigrationDir <> "/" <> name)
      pure (name, bytes))
    names

spec :: Spec
spec =
  describe "application migrations" $ do
    it "use real UTC timestamps" $ do
      names <- appMigrationFiles
      sentinelViolations names `shouldBe` []

    it "are unique across the combined ledger" $ do
      names <- appMigrationFiles
      duplicateTimestampViolations
        (Kiroku.embeddedMigrationNames <> Keiro.embeddedMigrationNames <> names)
        `shouldBe` []

    it "are schema-qualified and codd-safe" $ do
      sources <- appMigrationSources
      lintViolations (LintConfig "jitsurei." []) sources `shouldBe` []

    it "match the application lockfile" $ do
      manifest <- parseChecksumManifest <$> TIO.readFile "db/migrations.lock"
      sources <- appMigrationSources
      case manifest of
        Left err -> expectationFailure (T.unpack err)
        Right parsed -> checksumViolations parsed sources `shouldBe` []
```

Adjust `"jitsurei."`, `db/migrations`, and `db/migrations.lock` to your service.

## Ledger Choices

If your service uses codd, prefer one combined ledger: framework migrations first,
application migrations after them, and one `applyMigrations` call. This gives one
timestamp order and one place to answer "what has this database applied?"

```haskell
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Codd (CoddSettings, VerifySchemas (StrictCheck), applyMigrations)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString qualified as BS
import Data.List (isSuffixOf, sort)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Keiro.Migrations (allKeiroMigrations)
import Streaming.Prelude qualified as Streaming
import System.Directory (listDirectory)
import UnliftIO (MonadIO (liftIO))

loadAppMigrations :: (EnvVars m, MonadFail m, MonadIO m) => FilePath -> m [AddedSqlMigration m]
loadAppMigrations dir = do
  names <- liftIO $ sort . filter (".sql" `isSuffixOf`) <$> listDirectory dir
  traverse (loadOne dir) names

loadOne :: forall m. (EnvVars m, MonadFail m, MonadIO m) => FilePath -> FilePath -> m (AddedSqlMigration m)
loadOne dir name = do
  bytes <- liftIO $ BS.readFile (dir <> "/" <> name)
  let stream :: PureStream m
      stream = PureStream $ Streaming.yield (TE.decodeUtf8 bytes)
  either fail pure =<< parseAddedSqlMigration name stream

runServiceMigrations :: CoddSettings -> DiffTime -> IO ()
runServiceMigrations settings timeout =
  runCoddLogger $ do
    framework <- allKeiroMigrations
    app <- loadAppMigrations "db/migrations"
    _ <- applyMigrations settings (Just (framework <> app)) timeout StrictCheck
    pure ()
```

The combined ledger means codd's `UNIQUE (name)` and
`UNIQUE (migration_timestamp)` constraints apply to framework and application files
together. That is why the CI guard checks the union.

A separate application ledger is also valid when your team already has migration
tooling. In that model, run `keiro-migrate` first, then run your service migrations
with your tool and your ledger. The tradeoff is that status and drift are split across
two systems.

## Privileges

Run migrations with an owner or admin role. Grant the runtime role only the privileges
the application needs:

```sql
GRANT USAGE ON SCHEMA kiroku, keiro TO your_app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA kiroku, keiro TO your_app_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA kiroku, keiro TO your_app_role;
-- Re-run after any framework upgrade whose migrations add tables or sequences:
-- new objects are NOT covered by past GRANT ... ON ALL TABLES statements.
```

Grant your application schemas separately, according to your service's read/write
model.

## Operating

Run `keiro-migrate` before application startup, then open Kiroku with schema
initialization disabled:

```haskell
withStore
  (defaultConnectionSettings connString
    & #schemaInitialization .~ SkipSchemaInitialization)
  app
```

Use `keiro-migrate status` for inspection:

```text
Ledger: codd.sql_migrations
Applied (23):
  2026-05-16-12-17-14-kiroku-bootstrap.sql   2026-05-16 12:17:14 UTC
Pending (0):
applied 23, pending 0
```

Use `keiro-migrate verify` as the gate. It is read-only: pending migrations exit 2,
schema drift exits 1 with codd's differing objects, and a match exits 0.

Applications can also fail fast at startup:

```haskell
missing <- Keiro.Migrations.missingMigrations coddSettings (secondsToDiffTime 5)
unless (null missing) $
  fail ("Run keiro-migrate before starting; pending migrations: " <> show missing)
```

`keiro-migrate` and `kiroku-store-migrate` share a PostgreSQL advisory lock around
apply, so two migrators against one database serialize. Still prefer one migrator per
deploy; the lock is a safety net.

codd `v0.1.8` stores the ledger at `codd.sql_migrations`. Older databases may still
have `codd_schema.sql_migrations` until first contact with codd `v0.1.8` renames it.
Operator SQL should check `codd.sql_migrations` first and only fall back to
`codd_schema.sql_migrations` for pre-upgrade databases.

Back up persistent databases before framework upgrades. codd is forward-only:
recovery is a backup restore or a new forward migration. For alpha databases with
old `keiro_*` tables in `kiroku`, run
[Upgrading To The Keiro Schema](upgrading-to-the-keiro-schema.md) before applying
current migrations.

## Version Support

The checked expected-schema snapshots are under `expected-schema/v18/`, and the
drift gates run against PostgreSQL 18 in the current test setup. The bootstrap SQL has
PostgreSQL 17 compatibility paths where needed, but this repository's portable
expected-schema verification is currently captured and tested on PostgreSQL 18.

When a future change adds another PostgreSQL major to CI, update this guide together
with the migration test documentation.
