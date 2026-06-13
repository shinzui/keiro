# Database Migrations

Keiro uses PostgreSQL tables from two layers:

- Kiroku owns the event-store tables in the `kiroku` PostgreSQL schema:
  `streams`, `events`, `stream_events`, and `subscriptions`.
- Keiro owns framework metadata tables in the same `kiroku` schema:
  `keiro_snapshots`, `keiro_read_models`, `keiro_timers`, `keiro_outbox`, and
  `keiro_inbox`.

Production deployments should create and evolve these tables with the
`keiro-migrate` executable from the `keiro-migrations` package. The executable
uses codd and applies Kiroku's embedded migrations first, then Keiro's embedded
migrations (the bootstrap, outbox, and inbox migrations), in one ordered
migration ledger.

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

## Run The Migration

From the Keiro repository or a workspace that includes `keiro-migrations`, run:

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=keiro user=keiro_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema \
CODD_SCHEMAS=kiroku \
cabal run keiro-migrate
```

`CODD_CONNECTION` is the PostgreSQL connection string for the target database.
`CODD_SCHEMAS=kiroku` tells codd to check the schema used by Kiroku and Keiro
framework tables. codd currently
requires `CODD_MIGRATION_DIRS` and `CODD_EXPECTED_SCHEMA_DIR` in its settings
environment even though Keiro passes embedded migrations directly from Haskell.

After a successful run, the database has Kiroku's event-store tables, Keiro's
framework tables, and codd's internal migration ledger. Application-owned
tables remain outside this schema unless your service migrations place them
there deliberately.

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

Keiro migrations only cover Keiro-owned framework tables. They do not create
your application read-model tables, indexes, materialized views, or reporting
schemas.

See [Run And Operate Jitsurei](../guides/run-and-operate-jitsurei.md) for how
the guide package separates Keiro framework initialization from the
application-owned `jitsurei_order_summary` table.

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
`keiro-migrations/sql-migrations/`. Then regenerate the expected schema from a
fresh ephemeral PostgreSQL database:

```bash
cabal run keiro-write-expected-schema
```

Review the resulting diff before committing:

```bash
git diff -- keiro-migrations/sql-migrations keiro-migrations/expected-schema
cabal test keiro-migrations-test
```

Commit the SQL migration and `keiro-migrations/expected-schema` changes
together. Ordinary fixture-based suites intentionally skip expected-schema
comparison during setup so they remain quiet and fast; `keiro-migrations-test`
is the strict schema drift gate.
