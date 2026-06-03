ALTER TABLE keiro_timers
  ADD COLUMN IF NOT EXISTS last_error TEXT;

DROP INDEX IF EXISTS keiro_timers_due_idx;

CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
  ON keiro_timers (status, fire_at, process_manager_name)
  WHERE status IN ('scheduled', 'firing');
