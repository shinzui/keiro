-- GC eligibility scan: terminal instances ordered by terminal age.
CREATE INDEX IF NOT EXISTS keiro_workflows_gc_idx
  ON keiro.keiro_workflows (status, completed_at);
