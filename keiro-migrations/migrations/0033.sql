-- add workflow instance creation-order index
-- Immutable creation keys support newest-first inspection and creation windows.
CREATE INDEX IF NOT EXISTS keiro_workflows_created_idx
  ON keiro.keiro_workflows (created_at, workflow_name, workflow_id);
