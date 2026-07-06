# Database Migrations

Keiro uses PostgreSQL tables from two layers:

- Kiroku owns the event-store tables in the `kiroku` PostgreSQL schema:
  `streams`, `events`, `stream_events`, and `subscriptions`.
- Keiro owns its framework metadata tables — `keiro_snapshots`,
  `keiro_read_models`, `keiro_timers`, `keiro_outbox`, `keiro_inbox`, and the
  workflow tables — in a **dedicated `keiro` PostgreSQL schema that Keiro's
  bootstrap migration creates and owns** (with `CREATE SCHEMA IF NOT EXISTS
  keiro`). `kiroku` and `keiro` are two separate namespaces in the same database.

A PostgreSQL *schema* is a named table namespace inside one database. Every Keiro
migration now creates its objects **schema-qualified** as `keiro.<table>` and
does **not** set `search_path`, so framework tables can never accidentally land
in `public` or `kiroku` on an incremental upgrade.

Production deployments should create and evolve these tables with the
`keiro-migrate` executable from the `keiro-migrations` package. The executable
uses codd and applies Kiroku's embedded migrations first (creating the `kiroku`
schema and event-store tables), then Keiro's embedded migrations (creating the
`keiro` schema and framework tables), in one ordered migration ledger.

## Migrations Are The Only Source Of Schema

The codd migrations in `keiro-migrations` are the single definition of Keiro's
framework tables. The library no longer ships `initialize*Schema` helpers that
embedded `CREATE TABLE` statements in Haskell — keeping a second copy of the DDL
in sync with the migrations was a source of drift, so it was removed.

Because there is only one definition, the schema applied in tests is exactly the
schema applied in production:

- Production: run `keiro-migrate` before starting application processes.
- Tests: apply the same migrations to a template database once per suite and
  clone it per example. The `keiro-test-support` `withMigratedSuite` fixture
  does this with `runAllKeiroMigrationsNoCheck`; the dedicated
  `keiro-migrations-test` suite performs strict checked-in schema verification.

codd records which migrations have run, provides a reviewed forward history, and
verifies database shape — guarantees an in-application `CREATE TABLE IF NOT
EXISTS` cannot give you.

Keiro also checks `keiro-migrations/migrations.lock`, a SHA-256 manifest for the
embedded SQL files. Editing a shipped migration body after it has been reviewed
is a test failure; add a new forward migration instead. When you intentionally
add a SQL file, regenerate the lockfile with `keiro-migrate lock` and review it
with the SQL diff.

## Run The Migration

From the Keiro repository or a workspace that includes `keiro-migrations`, run:

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=keiro user=keiro_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema \
CODD_SCHEMAS=keiro \
cabal run keiro-migrate
```

`CODD_CONNECTION` is the PostgreSQL connection string for the target database.
`CODD_SCHEMAS=keiro` tells codd to scope its drift check to the dedicated `keiro`
schema that Keiro's framework tables live in. (Kiroku drift-gates its own
`kiroku` schema in its own package, so Keiro's gate need only see `keiro`.) codd
currently requires `CODD_MIGRATION_DIRS` and `CODD_EXPECTED_SCHEMA_DIR` in its
settings environment even though Keiro passes embedded migrations directly from
Haskell.

After a successful run, the database has Kiroku's event-store tables (in
`kiroku`), Keiro's framework tables (in `keiro`), and codd's internal migration
ledger. With codd v0.1.8, fresh databases use `codd.sql_migrations`; older
databases may briefly show `codd_schema.sql_migrations` until codd's internal
upgrade renames it. Application-owned tables live wherever your service
migrations place them — see [Application Tables](#application-tables) below for
how to choose the schema your read-model and projection tables live in.

## Upgrading An Existing Alpha Database

Databases first migrated by `keiro-migrations 0.1.0.0` have their `keiro_*`
tables in the `kiroku` schema (the old layout). **Before** running the current
migrations against such a database, follow the one-time
[Upgrading To The Keiro Schema](./upgrading-to-the-keiro-schema.md) runbook once
to relocate the tables into `keiro` — no data is lost. Fresh databases and
ephemeral test databases do not need it; they land in `keiro` from the start.

## Start The Application Afterward

Once migrations have run, open Kiroku with schema initialization disabled:

```haskell
withStore
  (defaultConnectionSettings connString
    & #schemaInitialization .~ SkipSchemaInitialization)
  app
```

This keeps application startup focused on opening the store, not changing the
database. It also prevents production rollouts from depending on whichever
application instance happens to start first.

## Application Tables

Keiro migrations only cover Keiro-owned framework tables (in `keiro`). They do
not create your application read-model tables, indexes, materialized views, or
reporting schemas.

Applications can now declare the schema their read-model and projection tables
live in as a first-class choice, so application data need not co-mingle with
either `kiroku` or `keiro`. See
[Read Models And Projections](./read-models-and-projections.md#choosing-your-projection-schema)
for the `ReadModel` `schema` field and the `Keiro.Connection` helpers.

See [Run And Operate Jitsurei](../guides/run-and-operate-jitsurei.md) for how
the guide package separates Keiro framework initialization from the
application-owned `jitsurei_order_summary` table, which the worked example places
in its own `jitsurei` schema.

Keep application-owned migrations in your service. If your service also uses
codd, compose the service migrations after `Keiro.Migrations.allKeiroMigrations`
and call `Codd.applyMigrations` once with the combined list. A single codd run
keeps all migration names in one ledger and one timestamp order.

## Forward-Only Recovery

codd is forward-only. Do not rename or edit a migration file after it has
reached a shared database. If a migration is wrong in production, recover by
restoring from backup or by shipping a new forward migration that repairs the
schema.

For local development, an already-initialized database can usually run
`keiro-migrate` successfully because Keiro's bootstrap SQL uses
`CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`. After codd records
the migration, its ledger is the source of truth.

## Updating The Expected Schema

The repository stores codd's expected schema files under
`keiro-migrations/expected-schema`. These files are the reviewed snapshot used
by `cabal test keiro-migrations-test` to prove the migrated database still
matches the schema Keiro intends to ship.

When a real schema change is required, add a new forward SQL migration under
`keiro-migrations/sql-migrations/`. Then regenerate the lockfile and the
expected schema from a fresh ephemeral PostgreSQL database:

```bash
cd keiro-migrations
cabal --project-dir=.. run keiro-migrations:exe:keiro-migrate -- lock
cd ..
cabal run keiro-write-expected-schema
```

Review the resulting diff before committing:

```bash
git diff -- keiro-migrations/sql-migrations keiro-migrations/expected-schema
cabal test keiro-migrations-test
```

Commit the SQL migration, `keiro-migrations/migrations.lock`, and
`keiro-migrations/expected-schema` changes together. Ordinary fixture-based
suites intentionally skip expected-schema comparison during setup so they remain
quiet and fast; `keiro-migrations-test` is the strict schema drift gate.
