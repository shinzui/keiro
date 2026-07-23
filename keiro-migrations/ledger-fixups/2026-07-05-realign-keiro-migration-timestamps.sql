-- Ledger realignment for the keiro migration-timestamp rename (2026-07-05).
--
-- The keiro framework migrations were renamed from hand-assigned sentinel
-- timestamps (...-00-00-00, ...-01-00-00, ...) to their real UTC authoring
-- times. codd decides whether a migration is already applied by FILENAME
-- (`SELECT ... FROM <ledger>.sql_migrations WHERE name = ?`), so a database
-- that already applied the old names would otherwise treat every renamed file
-- as pending and re-run it.
--
-- This script rewrites only the `name` identity in the codd ledger, while
-- re-asserting `migration_timestamp` at the row's originally recorded value.
-- That timestamp assignment is a deliberate idempotent no-op. The script changes
-- ONLY codd's bookkeeping identity -- never a timestamp and never your schema.
--
-- WHEN TO RUN: once per long-lived database (staging/prod/persistent local),
-- BEFORE the next `codd up` / migrate that carries the renamed files.
-- Ephemeral / template-per-suite test databases do not need it -- they apply
-- from scratch.
--
-- SAFETY: the remap is 1:1 onto brand-new values, so neither UNIQUE(name) nor
-- UNIQUE(migration_timestamp) can be violated; and it is idempotent -- a second
-- run matches no rows. Wrapped in a transaction so it is all-or-nothing.
--
-- LEDGER LOCATION: codd v0.1.8 stores the ledger at `codd.sql_migrations` and
-- auto-renames older `codd_schema.sql_migrations` ledgers during apply. This
-- script targets `codd.sql_migrations` when present and falls back to the old
-- `codd_schema.sql_migrations` location for pre-upgrade databases.

BEGIN;

DO $$
DECLARE
  ledger regclass;
  remap record;
BEGIN
  ledger := to_regclass('codd.sql_migrations');
  IF ledger IS NULL THEN
    ledger := to_regclass('codd_schema.sql_migrations');
  END IF;

  IF ledger IS NULL THEN
    RAISE EXCEPTION 'could not find codd ledger table (expected codd.sql_migrations or codd_schema.sql_migrations)';
  END IF;

  FOR remap IN
    SELECT * FROM (VALUES
      ('2026-05-17-13-58-15-keiro-bootstrap.sql', '2026-05-17-00-00-00-keiro-bootstrap.sql', '2026-05-17 00:00:00+00'::timestamptz),
      ('2026-05-19-12-55-02-keiro-outbox.sql', '2026-05-17-01-00-00-keiro-outbox.sql', '2026-05-17 01:00:00+00'::timestamptz),
      ('2026-05-19-13-05-23-keiro-inbox.sql', '2026-05-17-02-00-00-keiro-inbox.sql', '2026-05-17 02:00:00+00'::timestamptz),
      ('2026-06-03-05-14-28-keiro-timer-recovery.sql', '2026-05-17-03-00-00-keiro-timer-recovery.sql', '2026-05-17 03:00:00+00'::timestamptz),
      ('2026-06-03-16-10-05-keiro-workflow-steps.sql', '2026-06-03-00-00-00-keiro-workflow-steps.sql', '2026-06-03 00:00:00+00'::timestamptz),
      ('2026-06-03-18-19-41-keiro-awakeables.sql', '2026-06-03-01-00-00-keiro-awakeables.sql', '2026-06-03 01:00:00+00'::timestamptz),
      ('2026-06-03-19-49-23-keiro-workflow-children.sql', '2026-06-03-02-00-00-keiro-workflow-children.sql', '2026-06-03 02:00:00+00'::timestamptz),
      ('2026-06-04-02-12-28-keiro-workflow-generation.sql', '2026-06-05-00-00-00-keiro-workflow-generation.sql', '2026-06-05 00:00:00+00'::timestamptz),
      ('2026-06-04-03-53-34-keiro-subscription-shards.sql', '2026-06-05-01-00-00-keiro-subscription-shards.sql', '2026-06-05 01:00:00+00'::timestamptz),
      ('2026-06-15-15-07-25-keiro-workflows-instances.sql', '2026-06-11-00-00-04-keiro-workflows-instances.sql', '2026-06-11 00:00:04+00'::timestamptz),
      ('2026-06-15-17-53-48-keiro-workflow-gc-index.sql', '2026-06-15-22-10-00-keiro-workflow-gc-index.sql', '2026-06-15 22:10:00+00'::timestamptz),
      ('2026-06-15-18-01-33-keiro-workflows-wake-after.sql', '2026-06-15-22-20-00-keiro-workflows-wake-after.sql', '2026-06-15 22:20:00+00'::timestamptz),
      ('2026-07-02-00-15-48-keiro-outbox-claim-order-index.sql', '2026-07-02-00-12-00-keiro-outbox-claim-order-index.sql', '2026-07-02 00:12:00+00'::timestamptz),
      ('2026-07-02-00-58-54-keiro-inbox-drop-received-idx.sql', '2026-07-02-00-55-00-keiro-inbox-drop-received-idx.sql', '2026-07-02 00:55:00+00'::timestamptz)
    ) AS remaps(new_name, old_name, old_timestamp)
  LOOP
    EXECUTE format('UPDATE %s SET name = $1, migration_timestamp = $2 WHERE name = $3', ledger)
      USING remap.new_name, remap.old_timestamp, remap.old_name;
  END LOOP;
END
$$;

-- Sanity check: no stale sentinel-named keiro rows should remain.
-- Expect zero rows. Replace <ledger> with codd.sql_migrations if present,
-- otherwise codd_schema.sql_migrations.
--   SELECT name FROM <ledger>
--   WHERE name LIKE '2026-%-keiro-%' AND substr(name, 12, 8) IN
--     ('00-00-00','01-00-00','02-00-00','03-00-00','00-00-04','22-10-00','22-20-00','00-12-00','00-55-00');

COMMIT;
