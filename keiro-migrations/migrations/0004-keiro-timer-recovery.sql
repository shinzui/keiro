ALTER TABLE keiro.keiro_timers
  ADD COLUMN IF NOT EXISTS last_error TEXT;

DROP INDEX IF EXISTS keiro.keiro_timers_due_idx;

CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
  ON keiro.keiro_timers (status, fire_at, process_manager_name)
  WHERE status IN ('scheduled', 'firing');
