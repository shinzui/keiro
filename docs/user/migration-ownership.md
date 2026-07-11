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

cabal run keiro-migrate -- check keiro-migrations/migrations/manifest
```

Review the new SQL and manifest append together. Prefer idempotent DDL where it
does not weaken correctness, qualify every object as `<schema>.<object>`, and
use a nontransactional migration only when PostgreSQL forbids the operation in
a transaction.

## Importing Existing Codd History

Kiroku and Keiro historically shared one Codd ledger. During cutover,
`Keiro.Migrations.History.Codd` combines all seven Kiroku and sixteen Keiro
mappings into one `HistoryImport`. The adapter verifies the old
`migrations.lock` checksums and exact source payloads before recording either
target prefix.

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
