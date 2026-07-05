-- Workflow instance state used by the resume worker and by later discovery /
-- pruning work. The journal remains the source of truth; this table is a
-- transactional summary maintained beside journal-index writes.
CREATE TABLE IF NOT EXISTS keiro.keiro_workflows (
  workflow_id      TEXT        NOT NULL,
  workflow_name    TEXT        NOT NULL,
  generation       INTEGER     NOT NULL DEFAULT 0,
  status           TEXT        NOT NULL DEFAULT 'running',
  attempts         INTEGER     NOT NULL DEFAULT 0,
  last_error       TEXT,
  next_attempt_at  TIMESTAMPTZ,
  leased_by        TEXT,
  lease_expires_at TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at     TIMESTAMPTZ,
  PRIMARY KEY (workflow_id, workflow_name),
  CONSTRAINT keiro_workflows_status_chk
    CHECK (status IN ('running', 'suspended', 'completed', 'cancelled', 'failed'))
);

CREATE INDEX IF NOT EXISTS keiro_workflows_active_idx
  ON keiro.keiro_workflows (status)
  WHERE status IN ('running', 'suspended');

WITH current_gen AS (
  SELECT workflow_id, workflow_name, MAX(generation) AS generation
  FROM keiro.keiro_workflow_steps
  GROUP BY workflow_id, workflow_name
),
terminal AS (
  SELECT
    cg.workflow_id,
    cg.workflow_name,
    cg.generation,
    CASE
      WHEN EXISTS (
        SELECT 1 FROM keiro.keiro_workflow_steps s
        WHERE s.workflow_id = cg.workflow_id
          AND s.workflow_name = cg.workflow_name
          AND s.generation = cg.generation
          AND s.step_name = '__workflow_completed__'
      ) THEN 'completed'
      WHEN EXISTS (
        SELECT 1 FROM keiro.keiro_workflow_steps s
        WHERE s.workflow_id = cg.workflow_id
          AND s.workflow_name = cg.workflow_name
          AND s.generation = cg.generation
          AND s.step_name = '__workflow_cancelled__'
      ) THEN 'cancelled'
      WHEN EXISTS (
        SELECT 1 FROM keiro.keiro_workflow_steps s
        WHERE s.workflow_id = cg.workflow_id
          AND s.workflow_name = cg.workflow_name
          AND s.generation = cg.generation
          AND s.step_name = '__workflow_failed__'
      ) THEN 'failed'
      ELSE 'running'
    END AS status
  FROM current_gen cg
)
INSERT INTO keiro.keiro_workflows (workflow_id, workflow_name, generation, status, completed_at)
SELECT workflow_id, workflow_name, generation, status,
       CASE WHEN status IN ('completed', 'cancelled', 'failed') THEN now() ELSE NULL END
FROM terminal
ON CONFLICT (workflow_id, workflow_name) DO NOTHING;

INSERT INTO keiro.keiro_workflows (workflow_id, workflow_name, generation, status)
SELECT child_id, child_name, 0, 'running'
FROM keiro.keiro_workflow_children
WHERE status = 'running'
ON CONFLICT (workflow_id, workflow_name) DO NOTHING;

ALTER TABLE keiro.keiro_workflow_children DROP CONSTRAINT IF EXISTS keiro_workflow_children_status_chk;
ALTER TABLE keiro.keiro_workflow_children ADD CONSTRAINT keiro_workflow_children_status_chk
  CHECK (status IN ('running', 'completed', 'cancelled', 'failed'));
