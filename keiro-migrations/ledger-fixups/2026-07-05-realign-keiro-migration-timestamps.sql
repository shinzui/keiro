-- Ledger realignment for the keiro migration-timestamp rename (2026-07-05).
--
-- The keiro framework migrations were renamed from hand-assigned sentinel
-- timestamps (…-00-00-00, …-01-00-00, …) to their real UTC authoring times.
-- codd decides whether a migration is already applied by FILENAME
-- (`SELECT … FROM codd_schema.sql_migrations WHERE name = ?`), so a database
-- that already applied the old names would otherwise treat every renamed file
-- as pending and re-run it.
--
-- This script rewrites the `name` and `migration_timestamp` columns of the
-- codd ledger from the old identity to the new one, so codd sees the renamed
-- migrations as already applied and skips them. It changes ONLY codd's
-- bookkeeping — never your schema.
--
-- WHEN TO RUN: once per long-lived database (staging/prod/persistent local),
-- BEFORE the next `codd up` / migrate that carries the renamed files.
-- Ephemeral / template-per-suite test databases do not need it — they apply
-- from scratch.
--
-- SAFETY: the remap is 1:1 onto brand-new values, so neither UNIQUE(name) nor
-- UNIQUE(migration_timestamp) can be violated; and it is idempotent — a second
-- run matches no rows. Wrapped in a transaction so it is all-or-nothing.
--
-- NOTE: this codd builds its ledger as `codd_schema.sql_migrations`. If your
-- codd version uses the `codd` schema instead, replace the schema qualifier
-- throughout (`codd.sql_migrations`).

BEGIN;

UPDATE codd_schema.sql_migrations SET name = '2026-05-17-13-58-15-keiro-bootstrap.sql',              migration_timestamp = '2026-05-17 13:58:15+00' WHERE name = '2026-05-17-00-00-00-keiro-bootstrap.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-05-19-12-55-02-keiro-outbox.sql',                 migration_timestamp = '2026-05-19 12:55:02+00' WHERE name = '2026-05-17-01-00-00-keiro-outbox.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-05-19-13-05-23-keiro-inbox.sql',                  migration_timestamp = '2026-05-19 13:05:23+00' WHERE name = '2026-05-17-02-00-00-keiro-inbox.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-03-05-14-28-keiro-timer-recovery.sql',         migration_timestamp = '2026-06-03 05:14:28+00' WHERE name = '2026-05-17-03-00-00-keiro-timer-recovery.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-03-16-10-05-keiro-workflow-steps.sql',         migration_timestamp = '2026-06-03 16:10:05+00' WHERE name = '2026-06-03-00-00-00-keiro-workflow-steps.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-03-18-19-41-keiro-awakeables.sql',             migration_timestamp = '2026-06-03 18:19:41+00' WHERE name = '2026-06-03-01-00-00-keiro-awakeables.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-03-19-49-23-keiro-workflow-children.sql',      migration_timestamp = '2026-06-03 19:49:23+00' WHERE name = '2026-06-03-02-00-00-keiro-workflow-children.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-04-02-12-28-keiro-workflow-generation.sql',    migration_timestamp = '2026-06-04 02:12:28+00' WHERE name = '2026-06-05-00-00-00-keiro-workflow-generation.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-04-03-53-34-keiro-subscription-shards.sql',    migration_timestamp = '2026-06-04 03:53:34+00' WHERE name = '2026-06-05-01-00-00-keiro-subscription-shards.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-15-15-07-25-keiro-workflows-instances.sql',    migration_timestamp = '2026-06-15 15:07:25+00' WHERE name = '2026-06-11-00-00-04-keiro-workflows-instances.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-15-17-53-48-keiro-workflow-gc-index.sql',      migration_timestamp = '2026-06-15 17:53:48+00' WHERE name = '2026-06-15-22-10-00-keiro-workflow-gc-index.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-15-18-01-33-keiro-workflows-wake-after.sql',   migration_timestamp = '2026-06-15 18:01:33+00' WHERE name = '2026-06-15-22-20-00-keiro-workflows-wake-after.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-07-02-00-15-48-keiro-outbox-claim-order-index.sql', migration_timestamp = '2026-07-02 00:15:48+00' WHERE name = '2026-07-02-00-12-00-keiro-outbox-claim-order-index.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-07-02-00-58-54-keiro-inbox-drop-received-idx.sql',  migration_timestamp = '2026-07-02 00:58:54+00' WHERE name = '2026-07-02-00-55-00-keiro-inbox-drop-received-idx.sql';

-- Sanity check: no stale sentinel-named keiro rows should remain.
-- Expect zero rows.
--   SELECT name FROM codd_schema.sql_migrations
--   WHERE name LIKE '2026-%-keiro-%' AND substr(name, 12, 8) IN
--     ('00-00-00','01-00-00','02-00-00','03-00-00','00-00-04','22-10-00','22-20-00','00-12-00','00-55-00');

COMMIT;
