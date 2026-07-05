-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

ALTER TABLE keiro_timers
  ADD COLUMN IF NOT EXISTS last_error TEXT;

DROP INDEX IF EXISTS keiro_timers_due_idx;

CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
  ON keiro_timers (status, fire_at, process_manager_name)
  WHERE status IN ('scheduled', 'firing');
