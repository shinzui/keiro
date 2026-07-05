-- Self-expiring resume hint for workflows parked only on a sleep timer.
ALTER TABLE keiro.keiro_workflows
  ADD COLUMN IF NOT EXISTS wake_after TIMESTAMPTZ;
