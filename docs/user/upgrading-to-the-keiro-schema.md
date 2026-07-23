# Upgrading To The Keiro Schema

`keiro-migrations 0.1.0.0` created Keiro's framework tables (`keiro_snapshots`,
`keiro_read_models`, `keiro_timers`, `keiro_outbox`, `keiro_inbox`,
`keiro_projection_dedup`, and the workflow tables) **inside kiroku's `kiroku`
PostgreSQL schema**. From the next release forward, Keiro creates and owns a
**dedicated `keiro` schema** and every migration is schema-qualified
`keiro.<table>`.

This is a one-time runbook for operators of an existing `0.1.0.0` database. It
relocates each `keiro_*` table from `kiroku` into `keiro` **without data loss**,
by wrapping the tested remediation script that ships in the `keiro-migrations`
package.

## Who Needs This

Only operators of a **persistent** database first migrated by
`keiro-migrations 0.1.0.0` — staging, production, or a long-lived local
database. **Ephemeral or template-per-suite test databases do not need it**: they
are created from scratch by the new migrations and already land in `keiro`. If
you have never run `keiro-migrations 0.1.0.0` against a durable database, skip
this page entirely.

## What It Does

The remediation script
[`keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql`](../../keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql)
runs, in a single transaction:

1. `CREATE SCHEMA IF NOT EXISTS keiro;`
2. For each `keiro_*` table still in `kiroku`, `ALTER TABLE kiroku.<table> SET
   SCHEMA keiro`. `SET SCHEMA` is a metadata-only operation: it moves the table
   together with its rows, indexes, and constraints; **no rows are copied and
   none are dropped**, so it cannot lose data. Each move is guarded by
   `to_regclass`, so a table already in `keiro` (or absent) is skipped.

**It does not touch migration history.** The script only creates the schema and
moves tables. A `0.1.0.0` database still has its historical rows in Codd's
ledger; those rows must be imported into the native `pgmigrate` ledger as a
separate, verified cutover step before `keiro-migrate up` is allowed to run.

The `keiro_*` framework tables use no `SERIAL` columns and no foreign keys, so
there is no dependent sequence to orphan and no cross-schema reference to break —
a clean move.

## 1. Back Up First

Take a backup (or a database snapshot) before running anything, and run during a
maintenance window with application writers stopped — the `SET SCHEMA` operations
take brief exclusive locks on each table.

```bash
pg_dump --format=custom --file=keiro-pre-upgrade.dump \
  "host=/tmp port=5432 dbname=keiro user=keiro_admin"
```

## 2. Run The Remediation Script

Apply the script inside a single transaction with `psql`:

```bash
psql "host=/tmp port=5432 dbname=keiro user=keiro_admin" \
  --single-transaction \
  --file=keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql
```

The script is itself wrapped in `BEGIN`/`COMMIT` and is idempotent: a second run
is a safe no-op (every table is already in `keiro`, so the `to_regclass` guard
skips them and no error is raised).

## 3. Import Legacy History

Keep application and legacy migration writers quiescent. `keiro-migrate up`
refuses a database that has `codd.sql_migrations` or
`codd_schema.sql_migrations` but no native history. The message names the ledger
it found. This guard prevents `up` from replaying the native plan over a database
whose history has not been imported.

`--allow-fresh-ledger-over-codd` is an emergency escape hatch for a deliberate
fresh start only. Never use it during a codd-to-pg-migrate cutover.

```bash
export DATABASE_URL='host=/tmp port=5432 dbname=keiro user=keiro_admin'
```

### 3a. Realign Sentinel-Named Ledger Rows (Alpha-Era Databases Only)

Some alpha databases recorded Keiro migrations under hand-assigned sentinel
filenames. Check the active ledger for those names:

```sql
-- Use codd_schema.sql_migrations instead if codd.sql_migrations is absent.
SELECT name
FROM codd.sql_migrations
WHERE name LIKE '2026-%-keiro-%'
  AND substr(name, 12, 8) IN
    ('00-00-00', '01-00-00', '02-00-00', '03-00-00', '00-00-04',
     '22-10-00', '22-20-00', '00-12-00', '00-55-00');
```

If the query returns rows, run the checked-in realignment before importing:

```bash
psql "$DATABASE_URL" \
  --single-transaction \
  --file=keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql
```

The fixup changes only codd row names and is idempotent. Skipping it makes the
import fail safely with `CoddSelectedFilenameMissing` or
`CoddStrictSourceHasUnselected`; the failed import writes no native history.

### 3b. Import The Combined History

The CLI uses the checked-in combined Kiroku/Keiro mapping, legacy manifest, and
exact SQL payloads. Strict source mode is mandatory, and `--confirm` explicitly
acknowledges the evidence being imported:

```bash
cabal run keiro-migrate -- import-codd-history \
  --reason "service cutover to pg-migrate" \
  --confirm
```

The command prints one `imported <component>/<migration>` line per historical
entry. It is idempotent; a safe rerun prints `already imported` for every entry.
Use `--source-database-url` only when the read-only codd ledger is in a different
database, and coordinate any nondefault `--source-lock-key` with the legacy
wrapper.

### Recovery: `up` Ran Before The Import

An older binary, or an operator using the override, can create native rows
without import audits. On a current codd database the run normally aborts at
`kiroku/0006-stream-name-length-check`, leaving five applied Kiroku rows. The
import then fails with `HistoryImportConflict`.

First inspect all four native ledger tables and prove that the schema contains
only the erroneous rows and no import evidence:

```sql
SELECT
  to_regclass('pgmigrate.ledger_metadata') AS ledger_metadata,
  to_regclass('pgmigrate.migrations') AS migrations,
  to_regclass('pgmigrate.history_imports') AS history_imports,
  to_regclass('pgmigrate.repairs') AS repairs;

SELECT component, migration, position, status
FROM pgmigrate.migrations
ORDER BY component, position;

SELECT count(*) AS import_audit_rows
FROM pgmigrate.history_imports;
```

For the dominant current-history incident, the second query must show exactly
five `kiroku` rows at positions 1 through 5 and the final query must return zero.
Stop and investigate if any row predates the mistaken run, any other component
or position appears, or any import audit exists.

> Warning: the next statement destroys the native ledger. Run it only after the
> checks above prove that this database had no legitimate pg-migrate history
> before the mistake.

```sql
DROP SCHEMA pgmigrate CASCADE;
```

The importer recreates the native ledger. Resume the cutover in order: confirm
the backup, run the schema remediation when upgrading a `0.1.0.0` layout, run
step 3a when sentinel names exist, then import, inspect `verify`, run `up`, and
verify again.

There is a worse variant on codd history predating
`2026-06-14-14-01-17-stream-name-length-check.sql`: the mistaken `up` can
succeed and create an empty parallel `keiro` schema while the real
`kiroku.keiro_*` tables still hold application data. Use this psql query to
count every framework table in both schemas:

```sql
SELECT format(
  'SELECT %L AS qualified_table, count(*) AS rows FROM %I.%I;',
  table_schema || '.' || table_name,
  table_schema,
  table_name
)
FROM information_schema.tables
WHERE table_schema IN ('keiro', 'kiroku')
  AND table_name LIKE 'keiro\_%'
ORDER BY table_schema, table_name
\gexec
```

If and only if every parallel `keiro.*` table is empty and the
`kiroku.keiro_*` tables contain the real rows, drop the empty parallel schema:

```sql
DROP SCHEMA keiro CASCADE;
```

Do that **before** rerunning the remediation script. The remediation skips a
table that already exists in `keiro`; leaving the empty parallel tables in place
would strand the real rows in `kiroku`. Then perform the guarded native-ledger
cleanup above and resume the normal sequence.

## 4. Run And Verify The Native Plan

After remediation and history import, inspect the native plan:

```bash
export DATABASE_URL='host=/tmp port=5432 dbname=keiro user=keiro_admin'
cabal run keiro-migrate -- status
cabal run keiro-migrate -- verify
```

At this point `verify` is expected to exit nonzero only because the post-codd
native migrations are pending. Review every reported issue; do not continue if
there is a checksum, ordering, unknown-row, or status problem. Then apply the
pending tail and run both independent integrity checks:

```bash
cabal run keiro-migrate -- up
cabal run keiro-migrate -- verify
cabal run keiro-migrate -- verify-schema
```

Expected result: imported historical entries are already applied; `up` executes
only native migrations introduced after that history; `verify` confirms ledger
integrity; and `verify-schema` confirms that live Keiro tables, columns,
constraints, and indexes match the embedded PostgreSQL 18 snapshot.

## 5. Verify Success

Confirm every `keiro_*` table now lives in `keiro` and none remain in `kiroku`:

```sql
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_name LIKE 'keiro\_%'
ORDER BY table_schema, table_name;
```

Every `keiro_*` row should show `table_schema = keiro`; none should show
`kiroku`. Then confirm the app starts and reads/writes its tables normally —
**"the application serves traffic against the relocated tables" is the ultimate
acceptance signal**. A subsequent `keiro-migrate` should report nothing to apply.

## 6. Rollback / Recovery

Because the remediation is a single transaction, a failure mid-script leaves the
database unchanged (all-or-nothing). The backup covers the case where a *later*
step (the migration run or app start) reveals a problem:

```bash
pg_restore --clean --if-exists --dbname=keiro keiro-pre-upgrade.dump
```

To reverse a single move manually in an emergency,
`ALTER TABLE keiro.<table> SET SCHEMA kiroku;` restores the old location; this is
for emergency rollback only and is not part of the supported path.
