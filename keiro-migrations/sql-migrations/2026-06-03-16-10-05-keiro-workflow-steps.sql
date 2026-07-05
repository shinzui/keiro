-- The fast-lookup index of journaled workflow steps. The journal stream
-- (wf:<name>-<id>) is the source of truth for replay; this table is a derived
-- view kept in sync inside the same transaction as each journal append. It
-- lets the runtime hot path and the EP-42 resume worker look up a step (or
-- discover unfinished workflows) without rescanning the journal stream.
--
-- The reserved step name '__workflow_completed__' is written when a workflow
-- finishes (see Keiro.Workflow.Types.completedStepName); its absence is how
-- findUnfinishedWorkflowIds distinguishes an in-flight workflow from a
-- completed one.
CREATE TABLE IF NOT EXISTS keiro.keiro_workflow_steps (
  workflow_id    text        NOT NULL,
  workflow_name  text        NOT NULL,
  step_name      text        NOT NULL,
  result         jsonb       NOT NULL,
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workflow_id, step_name)
);

CREATE INDEX IF NOT EXISTS keiro_workflow_steps_workflow_idx
  ON keiro.keiro_workflow_steps (workflow_id);
