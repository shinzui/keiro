# Database Migrations

Keiro uses PostgreSQL tables from two layers:

- Kiroku owns the event-store tables: `streams`, `events`, `stream_events`, and
  `subscriptions`.
- Keiro owns framework metadata tables: `keiro_snapshots`, `keiro_read_models`,
  `keiro_timers`, `keiro_outbox`, and `keiro_inbox`.

Production deployments should create and evolve these tables with the
`keiro-migrate` executable from the `keiro-migrations` package. The executable
uses codd and applies Kiroku's embedded migrations first, then Keiro's embedded
migrations (the bootstrap, outbox, and inbox migrations), in one ordered
migration ledger.

## Why Run Migrations Explicitly

Keiro still exposes development helpers such as `initializeSnapshotSchema`,
`initializeReadModelSchema`, `initializeTimerSchema`, `initializeOutboxSchema`,
and `initializeInboxSchema`. They use `CREATE TABLE IF NOT EXISTS` and are
convenient in tests or small local programs.

Those helpers are not a production migration system. They do not record which
schema changes have run, they do not provide a reviewed forward history, and
they do not verify database shape. Production services should run
`keiro-migrate` before starting application processes.

## Run The Migration

From the Keiro repository or a workspace that includes `keiro-migrations`, run:

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=keiro user=keiro_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema \
CODD_SCHEMAS=public \
cabal run keiro-migrate
```

`CODD_CONNECTION` is the PostgreSQL connection string for the target database.
`CODD_SCHEMAS=public` tells codd to check the public schema. codd currently
requires `CODD_MIGRATION_DIRS` and `CODD_EXPECTED_SCHEMA_DIR` in its settings
environment even though Keiro passes embedded migrations directly from Haskell.

After a successful run, the database has Kiroku's event-store tables, Keiro's
framework tables, and codd's internal migration ledger.

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
