-- Continue-as-new (EP-48) rotates a long-running workflow onto a fresh journal
-- *generation* so its history stays bounded. The logical identity
-- (workflow_id, workflow_name) is stable; the generation discriminates the
-- physical journal stream wf:<name>-<id>#<gen>. Generation 0 is the pre-rotation
-- default, so every existing row and every never-rotating workflow is unaffected.
ALTER TABLE keiro.keiro_workflow_steps
  ADD COLUMN IF NOT EXISTS generation integer NOT NULL DEFAULT 0;

-- Fold the generation (and workflow_name) into the key so two generations of the
-- same logical workflow do not collide on a reserved step name (e.g. the terminal
-- markers). Adding columns to the key is a strict relaxation: no existing row can
-- violate the wider key. The as-shipped key is (workflow_id, step_name) — plan 47
-- (which would have keyed on (workflow_id, workflow_name, step_name)) has NOT landed,
-- so this migration re-keys with workflow_name AND generation in one step, doing both
-- jobs at once. The base table's primary-key constraint is named
-- keiro_workflow_steps_pkey (Postgres default <table>_pkey).
ALTER TABLE keiro.keiro_workflow_steps DROP CONSTRAINT keiro_workflow_steps_pkey;
ALTER TABLE keiro.keiro_workflow_steps
  ADD PRIMARY KEY (workflow_id, workflow_name, generation, step_name);

-- Support the current-generation lookup (MAX(generation) per id+name). Replaces the
-- old (workflow_id)-only lookup index.
DROP INDEX IF EXISTS keiro.keiro_workflow_steps_workflow_idx;
CREATE INDEX IF NOT EXISTS keiro_workflow_steps_workflow_idx
  ON keiro.keiro_workflow_steps (workflow_id, workflow_name, generation);
