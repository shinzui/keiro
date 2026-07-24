# Migration Ownership

Keiro applications usually have three PostgreSQL schema owners:

- Kiroku owns the event store in `kiroku`.
- Keiro owns framework tables in `keiro`.
- The application owns projections, read models, reporting tables, and
  integration state in explicitly named application schemas.

Those are operational boundaries. A component changes only the objects it owns,
and runtime code does not create framework schema.

## Framework Components

`Kiroku.Store.Migrations.kirokuMigrations` returns the Kiroku
`MigrationComponent`. `Keiro.Migrations.keiroMigrations` returns the Keiro
component, whose dependency set contains exactly `kiroku`.

Compose concrete components in dependency order:

```haskell
import Keiro.Migrations (frameworkMigrationPlan, keiroMigrations)
import Kiroku.Store.Migrations qualified as Kiroku

frameworkPlan = do
  kiroku <- Kiroku.kirokuMigrations
  keiro <- keiroMigrations
  frameworkMigrationPlan kiroku keiro
```

The planner rejects a missing Kiroku component or reversed ordering with a
structured `PlanError`. Keiro does not copy Kiroku SQL or wrap both libraries in
an untyped migration set.

The manifest `keiro-migrations/migrations/manifest` is the source of migration
order. Each immutable SQL file has a stable component-local identifier. Do not
edit or reorder shipped entries; append a new migration for every correction.
At compile time, the manifest embedder checks order, directory membership, and
the exact SQL payloads. On GHC 9.12 the embedding module loads
`RecompilePlugin`, which reruns that check whenever Cabal invokes GHC; it cannot
help a build that Cabal declares up to date without invoking the compiler.

The default migration suite supplies the independent review-time gate. It reads
`migrations.native.lock` and the migrations directory at test runtime and
requires the lockfile, manifest, directory membership, and every SHA-256 payload
to agree. At deploy time, pg-migrate adds a third layer: the `pgmigrate` ledger
keys applied history by checksum and fails closed on divergence.

## Application Components

Application migrations create only application-owned objects. Put them outside
`kiroku` and `keiro`, qualify every object name, and do not rely on
`search_path`.

An application that wants one database plan should define its own component and
place it after Kiroku and Keiro. Declare dependencies that reflect the SQL it
actually consumes. `migrationPlan` validates the explicit order before any
database connection is opened.

```haskell
plan = migrationPlan (kiroku :| [keiro, application])
```

An application may instead run its existing migration tool after
`keiro-migrate`. That keeps ownership clear but splits status and verification
across two ledgers.

## Authoring

Use the standard CLI to create and check append-only files:

```bash
cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "add workflow lookup index"

cabal run keiro-migrate -- check \
  --manifest keiro-migrations/migrations/manifest
```

Every new Keiro migration is a three-file review diff: the immutable SQL file,
its appended `migrations/manifest` line, and its appended
`migrations.native.lock` SHA-256 line in the same order. Review that all three
agree. Prefer idempotent DDL where it does not weaken correctness, qualify every
object as `<schema>.<object>`, and use a nontransactional migration only when
PostgreSQL forbids the operation in a transaction. Run
`cabal test keiro-migrations-test`; the named mismatch explains whether the
lockfile, directory membership, or payload needs attention.

`migrations.lock` without `.native` is frozen codd-cutover evidence. Never add
native entries to it: strict history import relies on its exact legacy filename
set.

## Importing Existing Codd History

Kiroku and Keiro historically shared one Codd ledger. During cutover,
`Keiro.Migrations.History.Codd` combines all seven Kiroku and sixteen Keiro
mappings into one `frameworkCoddHistoryMappings` set, which `importCoddHistory`
turns into a single `HistoryImport`. The adapter verifies the old
`migrations.lock` checksums and exact source payloads before recording either
target prefix.

Most operators should drive this through the CLI rather than the library:
`keiro-migrate import-codd-history --reason TEXT --confirm` uses the same
checked-in mapping and evidence. See
[Upgrading To The Keiro Schema](upgrading-to-the-keiro-schema.md#3b-import-the-combined-history).
The Haskell entry point below is for services that embed the cutover in their
own tooling.

```haskell
config <-
  either (fail . show) pure $
    frameworkCoddSourceConfig provider True reason Confirmed

report <-
  importCoddHistory
    defaultImportOptions
    config
    provider
    frameworkPlan
    frameworkCoddHistoryMappings
```

Run this only while legacy writers are quiescent. Strict source mode rejects
unselected rows; partial or changed history leaves neither component imported.
After import, run `keiro-migrate verify`. A subsequent `up` must report every
historical entry as already applied and execute no legacy SQL.

The timestamped `sql-migrations/` directory, `migrations.lock`, expected-schema
snapshot, remediation script, and sentinel-ledger fixup remain transition
evidence. Their Codd test target is opt-in:

```bash
cabal test -flegacy-codd-tools \
  keiro-migrations:keiro-migrations-legacy-test
```

## Operating

Run migrations with an owner or administrator role before application startup:

```bash
export DATABASE_URL='host=/tmp port=5432 dbname=service user=service_owner'
cabal run keiro-migrate -- status
cabal run keiro-migrate -- verify
cabal run keiro-migrate -- up
```

`status` and `verify` are read-only. `verify` compares the complete declared plan
with the `pgmigrate` ledger and fails on pending, changed, reordered, repaired,
or unknown entries. `up` uses the shared advisory lock, so concurrent migrators
serialize; deployments should still designate one migrator.

Then open Kiroku with runtime schema initialization disabled:

```haskell
withStore
  (defaultConnectionSettings connString
    & #schemaInitialization .~ SkipSchemaInitialization)
  app
```

Grant runtime roles only the privileges they need:

```sql
GRANT USAGE ON SCHEMA kiroku, keiro TO your_app_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA kiroku, keiro TO your_app_role;
GRANT USAGE, SELECT
  ON ALL SEQUENCES IN SCHEMA kiroku, keiro TO your_app_role;
```

Back up persistent databases before framework upgrades. Databases from
`keiro-migrations 0.1.0.0` may first require
[Upgrading To The Keiro Schema](upgrading-to-the-keiro-schema.md). Never repair
schema drift by editing a shipped payload; append a migration or restore the
reviewed backup.
