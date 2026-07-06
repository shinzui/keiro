# Keiro database migrations

Keiro ships embedded codd migrations in the `keiro-migrations` package. Run
the `keiro-migrate` executable before starting an application that opens a
Kiroku store. The executable applies Kiroku's event-store migrations first
(creating the `kiroku` schema) and then Keiro's framework migrations for
snapshots, read-model metadata, timers, and the workflow tables. Keiro's
migrations create their objects **schema-qualified** as `keiro.<table>` inside a
dedicated `keiro` schema that Keiro creates and owns, and they never pin
`search_path`.

For the framework-vs-application ownership contract and how to compose service
migrations with these framework migrations, see
[Migration Ownership](../docs/user/migration-ownership.md).

codd is forward-only. If a migration has already reached a shared database, do
not rename or edit it in place; add a new forward migration that repairs the
schema, or restore the database from backup.

The package also checks a `migrations.lock` manifest. Each line records the
SHA-256 of one embedded SQL file, so an accidental edit to a shipped migration
fails `cabal test keiro-migrations-test` with the filename. Regenerate the
manifest only when intentionally adding or reviewing migration files:

```bash
cd keiro-migrations
cabal --project-dir=.. run keiro-migrations:exe:keiro-migrate -- lock
```

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

codd v0.1.8 stores its migration ledger at `codd.sql_migrations` on fresh
databases and auto-renames older `codd_schema.sql_migrations` ledgers during
apply. Keiro's tests and fixup scripts detect both locations, preferring
`codd.sql_migrations`.

`keiro-migrate` accepts bare invocation and `up` as apply commands. It also
accepts `verify`, `status`, `new`, and `lock`. Unknown arguments fail with usage
and exit code 2 before reading `CODD_CONNECTION`, so a typo cannot accidentally
apply migrations. Set `KEIRO_MIGRATE_NO_CHECK=1`, `true`, or `yes` only for
local no-check applies; unset or any other value means the normal checked path
runs.

The executable serializes migration applies with the same PostgreSQL
session-level advisory lock used by `kiroku-store-migrate`, because
`keiro-migrate` applies Kiroku and Keiro migrations through one ledger. This
protects multi-replica deploys where two processes start migration at the same
time: the second process waits for the first to finish, then observes zero
pending migrations. The embedded runner also forces codd's retry policy to a
single try, ignoring `CODD_RETRY_POLICY`; codd 0.1.8 cannot re-read in-memory
embedded migrations during a retry, so retrying would mask the original database
error with an unrelated crash.

## Verifying and inspecting a database

`keiro-migrate verify` is read-only. It first checks the combined codd ledger
for every embedded Kiroku and Keiro migration name. If any are pending, it
prints them and exits 2 without comparing schema objects or applying anything.
If none are pending, it strict-compares the live `keiro` schema with the
expected-schema snapshot embedded in the binary, exits 0 on a match, and exits 1
with codd's differing objects on drift.

`keiro-migrate status` is also read-only. It prints the ledger table in use
(`codd.sql_migrations`, or `codd_schema.sql_migrations` on older databases), the
applied migration names and timestamps, the pending embedded migration names
from the combined Kiroku+Keiro set, and a summary line. Pending migrations do
not make `status` fail; use `verify` as the gate.

Production applications should run the migration executable before startup and
then open Kiroku with schema initialization disabled:

```haskell
withStore
  (defaultConnectionSettings connString
    & #schemaInitialization .~ SkipSchemaInitialization)
  app
```

Applications can fail fast before opening the store by calling the exported
startup handshake:

```haskell
missing <- Keiro.Migrations.missingMigrations coddSettings (secondsToDiffTime 5)
unless (null missing) $
  fail ("Run keiro-migrate before starting; pending migrations: " <> show missing)
```

## Runtime role privileges

Run migrations with an owner/admin role, then grant the application runtime role
only the privileges it needs on framework-owned objects:

```sql
GRANT USAGE ON SCHEMA kiroku, keiro TO your_app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA kiroku, keiro TO your_app_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA kiroku, keiro TO your_app_role;
-- Re-run after any framework upgrade whose migrations add tables or sequences:
-- new objects are NOT covered by past GRANT ... ON ALL TABLES statements.
```

## Updating expected schema

Keiro checks migration drift with codd's on-disk expected-schema representation
in `keiro-migrations/expected-schema`. When a legitimate framework schema
change is needed, add a new forward SQL file under
`keiro-migrations/sql-migrations/`, regenerate `migrations.lock`, regenerate the
representation from a fresh ephemeral database, inspect the git diff, and commit
the SQL migration, lockfile, and expected-schema files together:

```bash
cd keiro-migrations
cabal --project-dir=.. run keiro-migrations:exe:keiro-migrate -- lock
cd ..
cabal run keiro-write-expected-schema
git diff -- keiro-migrations/sql-migrations keiro-migrations/expected-schema
cabal test keiro-migrations-test
```

Fixture-only test suites use `runAllKeiroMigrationsNoCheck` by design: they only
need a freshly migrated database. `keiro-migrations-test` and
`keiro-migrate verify` are the canonical drift gates and run strict comparisons
against the checked-in expected schema.
