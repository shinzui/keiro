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

**It does not touch codd's migration ledger.** codd identifies an applied
migration purely by its file *name* (`codd_schema.sql_migrations.name`), and the
new release keeps every migration filename unchanged — only the file bodies were
rewritten. So a `0.1.0.0` database already records every migration as applied and
codd re-runs nothing; there is no ledger row to rename or realign. The script
therefore only creates the schema and moves the tables.

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

## 3. Run The New Migrations

After remediation, apply the current migrations the normal way (the
`keiro-migrate` invocation from [Database Migrations](./migrations.md), with
`CODD_SCHEMAS=keiro`):

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=keiro user=keiro_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema \
CODD_SCHEMAS=keiro \
cabal run keiro-migrate
```

Expected result: because the tables are already in `keiro` and every migration
filename is already recorded as applied, this run makes **no** schema changes —
it is effectively a no-op that confirms the ledger is consistent.

## 4. Verify Success

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

## 5. Rollback / Recovery

Because the remediation is a single transaction, a failure mid-script leaves the
database unchanged (all-or-nothing). The backup covers the case where a *later*
step (the migration run or app start) reveals a problem:

```bash
pg_restore --clean --if-exists --dbname=keiro keiro-pre-upgrade.dump
```

To reverse a single move manually in an emergency,
`ALTER TABLE keiro.<table> SET SCHEMA kiroku;` restores the old location; this is
for emergency rollback only and is not part of the supported path.
