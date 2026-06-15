-- Resolve unqualified names into the Kiroku schema.
SET search_path TO kiroku, pg_catalog;

-- GC eligibility scan: terminal instances ordered by terminal age.
CREATE INDEX IF NOT EXISTS keiro_workflows_gc_idx
  ON keiro_workflows (status, completed_at);
