-- Resolve unqualified names into the Kiroku schema.
SET search_path TO kiroku, pg_catalog;

-- Self-expiring resume hint for workflows parked only on a sleep timer.
ALTER TABLE keiro_workflows
  ADD COLUMN IF NOT EXISTS wake_after TIMESTAMPTZ;
