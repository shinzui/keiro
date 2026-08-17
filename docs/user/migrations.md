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
cabal run keiro-migrate -- verify-schema
cabal run keiro-migrate -- up
cabal run keiro-migrate -- verify
cabal run keiro-migrate -- verify-schema
```

- `plan` prints the embedded component and migration order without changing the
  database.
- `status` compares declared migrations with the durable `pgmigrate` ledger.
- `verify` is the strict plan-versus-ledger gate. It rejects pending, changed,
  reordered, repaired, or unknown migration history.
- `verify-schema` compares the live tables, columns, constraints, and indexes in
  the `keiro` schema with the embedded PostgreSQL 18 expected snapshot. Run it
  after restores and cutovers, and alongside `verify` in deployment, so a clean
  ledger cannot conceal live object drift.
- `up` acquires the shared advisory lock and applies the complete pending plan
  in dependency order. Do not select a subset during deployment.

Database-backed commands accept `--database-url`; otherwise `keiro-migrate`
reads `DATABASE_URL`. The pg-migrate commands accept `--json` for
machine-readable output; `verify-schema` currently emits text. The `up` and
`repair` commands also accept `--no-wait`, `--lock-timeout`, and
`--statement-timeout`; use them only as explicit deployment-policy choices. The
defaults preserve serialized migration execution.

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

## Databases that applied Kiroku `0010` under `kiroku-store-migrations` 0.3.2.x

`kiroku-store-migrations` 0.4.0.0 corrects the payload of Kiroku migration
`0010`, which changes its checksum. `pg-migrate` verifies the exact SHA-256 of
each applied migration's payload, so a database that already applied `0010`
from 0.3.2.0 or 0.3.2.1 fails every `keiro-migrate up` and `keiro-migrate
verify` with `MigrationChecksumMismatch` until its ledger row is re-baselined.

Who needs the re-baseline:

| Database | Action |
|---|---|
| Applied `0010` under 0.3.2.x — every PostgreSQL 18 database, and a fresh PostgreSQL 17 install performed by 0.3.2.x | Run the fixup once, before the next `up` |
| Never reached `0010` — every ordinary PostgreSQL 17 upgrade, the path this Kiroku release fixes | Nothing. `0010` is still pending and applies from the corrected payload |
| Ephemeral or template-per-suite test databases | Nothing. They apply the whole plan from scratch |

The fixup ships with `kiroku-store-migrations` as
`ledger-fixups/2026-08-16-rebaseline-0010-checksum.sql`. It rewrites one
checksum, touches no schema, and is idempotent — a second run, or a run against
a database that applied the corrected payload, matches no rows. It assumes
`pg-migrate`'s default ledger schema `pgmigrate`; edit the `to_regclass` call if
your application configured a different one through `ledgerConfig`.

```bash
psql "$DATABASE_URL" \
  --set ON_ERROR_STOP=on \
  --file=<kiroku-store-migrations>/ledger-fixups/2026-08-16-rebaseline-0010-checksum.sql
keiro-migrate verify
keiro-migrate up
```

Kiroku's forward migration `0011` then converges the schema through the
ordinary runner: it publishes `kiroku.uuidv7()` where missing and binds
`history_retention_leases.lease_id`'s stored default to it. It is a no-op on a
database that applied the corrected `0010`.

For a data-bearing database, rehearse the fixup and the following `up` on a
restored clone first, exactly as
[Upgrading To The Keiro Schema](upgrading-to-the-keiro-schema.md) prescribes for
the 2026-07-05 realignment.

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

After an intentional PostgreSQL 18 schema change, regenerate the native
expected snapshot explicitly and review its diff:

```bash
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 \
  cabal test keiro-migrations-test \
  --test-options='--match "checked-in snapshot"'
```

The default suite never regenerates the file; it fails on drift.

Back up persistent databases and prove restore procedures before framework
upgrades. Migration recovery is forward-only: restore or append a reviewed
repair migration; never bypass checksum or history mismatches.
