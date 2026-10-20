-- add workflow instance creation-order index
-- Exclude wide keys to preserve the existing primary key's writer domain.
-- Inspection merges those through its separately budgeted candidate path.
-- Immutable creation keys support newest-first inspection and creation windows.
CREATE INDEX IF NOT EXISTS keiro_workflows_created_idx
  ON keiro.keiro_workflows (created_at, workflow_name, workflow_id)
  WHERE octet_length(workflow_name) + octet_length(workflow_id) <= 2600;
