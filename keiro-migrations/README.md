# Keiro database migrations

Keiro ships embedded codd migrations in the `keiro-migrations` package. Run
the `keiro-migrate` executable before starting an application that opens a
Kiroku store. The executable applies Kiroku's event-store migrations first
(creating the `kiroku` schema) and then Keiro's framework migrations for
snapshots, read-model metadata, timers, and the workflow tables. Keiro's
migrations create their objects **schema-qualified** as `keiro.<table>` inside a
dedicated `keiro` schema that Keiro creates and owns, and they never pin
`search_path`.

codd is forward-only. If a migration has already reached a shared database, do
not rename or edit it in place; add a new forward migration that repairs the
schema, or restore the database from backup.

For a local database, run:

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=keiro user=keiro_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema \
CODD_SCHEMAS=keiro \
cabal run keiro-migrate
```

`CODD_SCHEMAS=keiro` matches the dedicated `keiro` schema that Keiro creates and
owns for its framework tables, distinct from kiroku's `kiroku` event-store
schema. The checked-in expected-schema snapshot is scoped to `keiro` and is
portable — it records no machine-specific database role or owner — so
`keiro-migrations-test` passes on any machine and in CI. `CODD_MIGRATION_DIRS` is
still required by codd's settings parser, but Keiro passes embedded migrations
directly to codd.

Databases first migrated by `keiro-migrations 0.1.0.0` have their `keiro_*`
tables in `kiroku`; before applying these migrations to such a database, follow
the [Upgrading To The Keiro Schema](../docs/user/upgrading-to-the-keiro-schema.md)
runbook once.
Production applications should run the migration executable before startup and
then open Kiroku with schema initialization disabled:

```haskell
withStore
  (defaultConnectionSettings connString
    & #schemaInitialization .~ SkipSchemaInitialization)
  app
```

## Updating expected schema

Keiro checks migration drift with codd's on-disk expected-schema representation
in `keiro-migrations/expected-schema`. When a legitimate framework schema
change is needed, add a new forward SQL file under
`keiro-migrations/sql-migrations/`, regenerate the representation from a fresh
ephemeral database, inspect the git diff, and commit the SQL migration and
expected-schema files together:

```bash
cabal run keiro-write-expected-schema
git diff -- keiro-migrations/sql-migrations keiro-migrations/expected-schema
cabal test keiro-migrations-test
```

Fixture-only test suites use `runAllKeiroMigrationsNoCheck` by design: they only
need a freshly migrated database. `keiro-migrations-test` is the canonical drift
gate and runs a strict comparison against the checked-in expected schema.
