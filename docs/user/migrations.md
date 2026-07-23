# Database Migrations

Keiro uses two framework-owned PostgreSQL schemas:

- Kiroku owns the event store in `kiroku`.
- Keiro owns snapshots, read-model metadata, timers, inbox/outbox state,
  workflow state, projection deduplication, and dispatch dead letters in
  `keiro`.

Every framework object is schema-qualified. Application projections and read
models belong to the application and should live in a separately owned schema;
see [Migration Ownership](migration-ownership.md).

## Native migration plan

The supported path is the `keiro-migrate` executable from `keiro-migrations`.
It uses `pg-migrate` and embeds two immutable components into the binary:

1. Kiroku's `kiroku` component;
2. Keiro's `keiro` component, which declares a dependency on `kiroku`.

`frameworkMigrationPlan` validates that concrete dependency order before a
database connection is opened. The checked-in
`keiro-migrations/migrations/manifest` is the authoritative order of Keiro SQL
files. Runtime code contains no second copy of the framework DDL.

The old timestamped Codd files, expected-schema snapshot, and lock manifest are
retained only as cutover evidence and opt-in legacy verification. They are not
the normal migration runner.

## Inspect and apply

Set the standard connection string and run the read-only inspection commands
before applying:

```bash
export DATABASE_URL='host=/tmp port=5432 dbname=service user=service_owner'

cabal run keiro-migrate -- plan
cabal run keiro-migrate -- status
cabal run keiro-migrate -- verify
cabal run keiro-migrate -- up
cabal run keiro-migrate -- verify
```

- `plan` prints the embedded component and migration order without changing the
  database.
- `status` compares declared migrations with the durable `pgmigrate` ledger.
- `verify` is the strict deployment gate. It rejects pending, changed,
  reordered, repaired, or unknown history.
- `up` acquires the shared advisory lock and applies the complete pending plan
  in dependency order. Do not select a subset during deployment.

Database-backed commands accept `--database-url`; otherwise `keiro-migrate`
reads `DATABASE_URL`. Add `--json` for machine-readable output. The `up` and
`repair` commands also accept `--no-wait`, `--lock-timeout`, and
`--statement-timeout`; use them only as explicit deployment-policy choices.
The defaults preserve serialized migration execution.

`pg-migrate` commits transactional SQL and its ledger row atomically.
Nontransactional migrations use durable running/applied/failed states. If one
has an ambiguous outcome, inspect the database and use the explicit `repair`
command with `--confirm` and an audit reason; never edit ledger rows directly.

## Application startup

Run migrations as a deployment job before starting application processes. Every
service replica should also call `missingMigrations` at boot and refuse to serve
until the database carries the complete migration plan expected by that binary:

```haskell
import Keiro.Migrations

guardMigrations :: ConnectionProvider -> MigrationPlan -> IO ()
guardMigrations provider plan = do
  result <- missingMigrations defaultRunOptions provider plan
  case result of
    Right handshake | handshakePassed handshake -> pure ()
    Right handshake -> fail ("refusing startup: " <> show handshake)
    Left err -> fail ("migration handshake failed: " <> show err)
```

This closes the deployment gap where an application replica starts before the
migration job has reached its database. After the handshake passes, open Kiroku
with schema initialization disabled:

```haskell
withStore
  (defaultConnectionSettings connString
    & #schemaInitialization .~ SkipSchemaInitialization)
  app
```

The deployment job keeps schema ownership deterministic instead of depending on
whichever replica starts first; the per-replica handshake proves that the job's
result is present before serving traffic.

## Authoring a migration

Append migrations through the ordered manifest:

```bash
cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "add workflow lookup index"

cabal run keiro-migrate -- check \
  --manifest keiro-migrations/migrations/manifest
```

Review the SQL file and manifest append together. Never edit, rename, remove, or
reorder a migration that may have reached a shared database. Correct mistakes
with a new forward migration. Qualify every object with its owner schema and do
not rely on `search_path`.

The manifest embedder checks ordering, missing entries, unlisted sibling SQL,
duplicate names, and payload validity at build time. Production executables do
not need the SQL files on disk.

## Existing 0.1.0.0 databases

The native ledger uses stable component-local identities such as
`keiro/0001-keiro-bootstrap`. It must not replay SQL merely because an older
database recorded the equivalent timestamped names in Codd.

For a database created by `keiro-migrations 0.1.0.0`:

1. follow [Upgrading To The Keiro Schema](upgrading-to-the-keiro-schema.md) if
   its `keiro_*` tables still live in `kiroku`;
2. quiesce legacy migration writers;
3. import the combined Kiroku/Keiro Codd history through
   `Keiro.Migrations.History.Codd`;
4. run `keiro-migrate verify`, then `up`.

The importer checks the selected legacy rows, manifest checksums, and exact SQL
payloads before recording native history. See
[Migration Ownership](migration-ownership.md#importing-existing-codd-history)
for the API shape and safety constraints.

## Runtime role privileges

Use an owner/admin role for migrations. Grant the runtime role only the access
it needs:

```sql
GRANT USAGE ON SCHEMA kiroku, keiro TO your_app_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA kiroku, keiro TO your_app_role;
GRANT USAGE, SELECT
  ON ALL SEQUENCES IN SCHEMA kiroku, keiro TO your_app_role;
```

Past `GRANT ... ON ALL` statements do not automatically cover objects created
later. Reapply grants after an upgrade or configure appropriate default
privileges for the migration owner.

## Repository verification

The normal migration tests exercise the native embedded plan and ledger. The
historical Codd transition suite is deliberately opt-in:

```bash
cabal test keiro-migrations:keiro-migrations-test

cabal test -flegacy-codd-tools \
  keiro-migrations:keiro-migrations-legacy-test
```

Back up persistent databases and prove restore procedures before framework
upgrades. Migration recovery is forward-only: restore or append a reviewed
repair migration; never bypass checksum or history mismatches.
