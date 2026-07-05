-- One-time remediation: relocate keiro framework tables from the kiroku schema
-- into the dedicated keiro schema (MasterPlan 12 / EP-1).
--
-- Context: keiro-migrations 0.1.0.0 created every keiro_* table UNQUALIFIED
-- under `SET search_path TO kiroku`, so the framework tables physically landed
-- inside kiroku's private schema. From EP-1 forward the migrations create them
-- in a dedicated `keiro` schema. This script moves an already-migrated 0.1.0.0
-- database to the new layout WITHOUT re-running migrations and without data loss.
--
-- codd identifies applied migrations by FILENAME (the `name` column in
-- codd_schema.sql_migrations). EP-1 KEEPS every migration filename unchanged and
-- rewrote only the file bodies, so codd still sees all migrations as applied and
-- re-runs nothing. This script therefore does NOT rename any ledger row; it only
-- (1) creates the keiro schema and (2) moves each keiro_* table into it.
--
-- SAFETY / IDEMPOTENCE: each move is guarded by to_regclass, so a second run is a
-- no-op (the table is already in keiro and no longer visible as kiroku.<table>).
-- The keiro_* tables use no SERIAL columns and no foreign keys, so there is no
-- dependent sequence to orphan and no cross-schema reference to break. Wrapped in
-- one transaction: all-or-nothing.
--
-- WHEN TO RUN: once per long-lived database seeded from 0.1.0.0 (staging, prod,
-- persistent local), BEFORE the next keiro-migrate that carries the EP-1 file
-- bodies. Ephemeral / template-per-suite test databases apply the new bodies
-- from scratch and never need this.
--
-- NOTE: this codd builds its ledger as `codd_schema.sql_migrations`. If your codd
-- version uses the `codd` schema instead, adjust the verification query below.

BEGIN;

CREATE SCHEMA IF NOT EXISTS keiro;

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'keiro_snapshots', 'keiro_read_models', 'keiro_timers', 'keiro_outbox',
    'keiro_inbox', 'keiro_projection_dedup', 'keiro_workflows',
    'keiro_workflow_steps', 'keiro_workflow_children', 'keiro_awakeables',
    'keiro_subscription_shards'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF to_regclass('kiroku.' || t) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE kiroku.%I SET SCHEMA keiro', t);
    END IF;
  END LOOP;
END
$$;

COMMIT;

-- Verification (run after COMMIT; expects zero rows). Every current on-disk
-- migration filename must already be recorded as applied, so a subsequent
-- keiro-migrate is a no-op. Filenames are unchanged by EP-1, so there is nothing
-- to realign; this query simply confirms it.
--
--   SELECT f.name
--   FROM (VALUES
--     ('2026-05-17-13-58-15-keiro-bootstrap.sql'),
--     ('2026-05-19-12-55-02-keiro-outbox.sql'),
--     ('2026-05-19-13-05-23-keiro-inbox.sql'),
--     ('2026-06-03-05-14-28-keiro-timer-recovery.sql'),
--     ('2026-06-03-16-10-05-keiro-workflow-steps.sql'),
--     ('2026-06-03-18-19-41-keiro-awakeables.sql'),
--     ('2026-06-03-19-49-23-keiro-workflow-children.sql'),
--     ('2026-06-04-02-12-28-keiro-workflow-generation.sql'),
--     ('2026-06-04-03-53-34-keiro-subscription-shards.sql'),
--     ('2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql'),
--     ('2026-06-15-15-07-25-keiro-workflows-instances.sql'),
--     ('2026-06-15-17-53-48-keiro-workflow-gc-index.sql'),
--     ('2026-06-15-18-01-33-keiro-workflows-wake-after.sql'),
--     ('2026-06-15-21-49-37-keiro-projection-dedup.sql'),
--     ('2026-07-02-00-15-48-keiro-outbox-claim-order-index.sql'),
--     ('2026-07-02-00-58-54-keiro-inbox-drop-received-idx.sql')
--   ) AS f(name)
--   WHERE NOT EXISTS (
--     SELECT 1 FROM codd_schema.sql_migrations m WHERE m.name = f.name
--   );
