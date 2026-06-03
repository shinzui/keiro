-- The keiro_workflow_children table: durable parent->child workflow links.
--
-- A parent workflow's `spawnChild` records the child in the parent's journal
-- as a StepRecorded "child:<childId>" (so a replay short-circuits the spawn)
-- and inserts a 'running' row here linking the child's (id, name) back to the
-- parent's (id, name) plus the parent-journal step the parent awaits
-- ("child:<childId>:result"). When the child completes, `childCompletionHook`
-- flips the row to 'completed' (storing the child's result) and appends that
-- await step to the parent's journal so the parent's `awaitChild` resolves.
-- `cancelChild` flips a still-'running' row to 'cancelled' and writes a
-- WorkflowCancelled marker to the child's journal so the child stops.
--
-- The journal streams (wf:<name>-<id>) remain the source of truth for replay;
-- this table is the parent<->child relation plus operator-visible state and
-- the discovery seed that lets the resume worker drive a zero-step child.
CREATE TABLE IF NOT EXISTS keiro_workflow_children (
  child_id      TEXT        NOT NULL,
  child_name    TEXT        NOT NULL,
  parent_id     TEXT        NOT NULL,
  parent_name   TEXT        NOT NULL,
  await_step    TEXT        NOT NULL,   -- "child:<childId>:result" in the parent journal
  status        TEXT        NOT NULL DEFAULT 'running',
  result        JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at  TIMESTAMPTZ,
  PRIMARY KEY (child_id, child_name),
  CONSTRAINT keiro_workflow_children_status_chk
    CHECK (status IN ('running', 'completed', 'cancelled'))
);

-- List all children of one parent (operator inspection, awaitChild arm re-assertion).
CREATE INDEX IF NOT EXISTS keiro_workflow_children_parent_idx
  ON keiro_workflow_children (parent_id, parent_name);

-- Discovery for the resume worker: children still running (zero-step children too).
CREATE INDEX IF NOT EXISTS keiro_workflow_children_running_idx
  ON keiro_workflow_children (status)
  WHERE status = 'running';
