-- Preserve terminal child-workflow failures independently of a parent
-- generation's journal so awaitChild can deliver them after continue-as-new.
ALTER TABLE keiro.keiro_workflow_children
  ADD COLUMN IF NOT EXISTS failure_reason TEXT NULL;
