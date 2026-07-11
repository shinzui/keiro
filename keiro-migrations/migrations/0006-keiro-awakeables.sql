-- The keiro_awakeables table: durable promises an external system resolves.
--
-- A workflow's `awakeable` allocates a deterministic id, inserts a 'pending'
-- row here, and suspends; an external caller later runs `signalAwakeable`,
-- which flips the row to 'completed' (storing the payload) and appends a
-- StepRecorded "awk:<uuid>" to the owning workflow's journal so the next
-- runWorkflow takes the awaitStep hit path. `cancelAwakeable` flips a still
-- 'pending' row to 'cancelled'; a subsequent run then throws.
--
-- The journal stream (wf:<name>-<id>) remains the source of truth for replay;
-- this table is the external-completion handshake plus operator-visible state
-- (a stuck 'pending' row is a workflow waiting on a callback that never came).
CREATE TABLE IF NOT EXISTS keiro.keiro_awakeables (
  awakeable_id        UUID PRIMARY KEY,
  owner_workflow_name TEXT        NOT NULL,
  owner_workflow_id   TEXT        NOT NULL,
  status              TEXT        NOT NULL DEFAULT 'pending',
  payload             JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at        TIMESTAMPTZ,
  CONSTRAINT keiro_awakeables_status_chk
    CHECK (status IN ('pending', 'completed', 'cancelled'))
);

-- Gauge support (EP-44 keiro.workflow.awakeables.pending) and operator triage.
CREATE INDEX IF NOT EXISTS keiro_awakeables_pending_idx
  ON keiro.keiro_awakeables (status)
  WHERE status = 'pending';

-- Find all awakeables owned by one workflow instance (operator repair, EP-42/EP-43).
CREATE INDEX IF NOT EXISTS keiro_awakeables_owner_idx
  ON keiro.keiro_awakeables (owner_workflow_name, owner_workflow_id);
