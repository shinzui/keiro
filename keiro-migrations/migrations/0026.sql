-- public projection-group status contract

-- Persist the cursor authority selected by catalog registration.  A row exists
-- for every group so an inline projection (append) is distinguishable from a
-- legacy or not-yet-reconciled group (unmanaged).  Checkpoint subscription
-- names are private registration metadata; only their conservative floor is
-- published below.
CREATE TABLE keiro.keiro_projection_group_cursors (
  group_id TEXT PRIMARY KEY
    REFERENCES keiro.keiro_projection_rebuild_groups (group_id) ON DELETE CASCADE,
  position_basis TEXT NOT NULL,
  subscription_names TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT keiro_projection_group_cursors_basis_chk
    CHECK (position_basis IN ('append', 'checkpoint', 'unmanaged')),
  CONSTRAINT keiro_projection_group_cursors_subscription_names_chk
    CHECK (
      array_position(subscription_names, NULL) IS NULL
      AND (
        (position_basis = 'checkpoint' AND cardinality(subscription_names) > 0)
        OR (
          position_basis IN ('append', 'unmanaged')
          AND cardinality(subscription_names) = 0
        )
      )
    )
);

INSERT INTO keiro.keiro_projection_group_cursors
  (group_id, position_basis, subscription_names)
SELECT group_id, 'unmanaged', ARRAY[]::TEXT[]
FROM keiro.keiro_projection_rebuild_groups
ON CONFLICT (group_id) DO NOTHING;

CREATE SCHEMA IF NOT EXISTS keiro_read;
REVOKE ALL ON SCHEMA keiro_read FROM PUBLIC;

-- This owner-rights view is the only supported SQL surface for an external
-- projection reader.  It intentionally depends only on Keiro-owned relations
-- and Kiroku's versioned owner relation, never Kiroku's private tables.
CREATE VIEW keiro_read.projection_group_status_v1
WITH (security_barrier = true, security_invoker = false) AS
WITH checkpoint_floors AS (
  SELECT
    cursors.group_id,
    CASE
      WHEN cursors.position_basis = 'checkpoint'
        AND count(DISTINCT checkpoints.subscription_name)
              = cardinality(cursors.subscription_names)::BIGINT
      THEN min(checkpoints.checkpoint_position)
      ELSE NULL
    END AS serving_applied_position
  FROM keiro.keiro_projection_group_cursors AS cursors
  LEFT JOIN LATERAL unnest(cursors.subscription_names)
    AS required_subscription(subscription_name)
    ON true
  LEFT JOIN kiroku.subscription_checkpoints_v1 AS checkpoints
    ON checkpoints.subscription_name = required_subscription.subscription_name
  GROUP BY cursors.group_id, cursors.position_basis, cursors.subscription_names
), candidate_progress AS (
  SELECT
    sources.run_id,
    min(sources.cursor_position) AS candidate_rebuild_position
  FROM keiro.keiro_projection_rebuild_sources AS sources
  GROUP BY sources.run_id
), query_models AS (
  SELECT
    models.rebuild_group_id AS group_id,
    array_agg(models.name ORDER BY models.name) AS query_models
  FROM keiro.keiro_read_models AS models
  GROUP BY models.rebuild_group_id
)
SELECT
  groups.group_id,
  groups.status AS lifecycle_phase,
  groups.reads_allowed,
  groups.writes_allowed,
  groups.serving_revision_id,
  groups.serving_epoch,
  coalesce(cursors.position_basis, 'unmanaged') AS serving_position_basis,
  CASE
    WHEN groups.reads_allowed AND cursors.position_basis = 'checkpoint'
    THEN checkpoint_floors.serving_applied_position
    ELSE NULL
  END AS serving_applied_position,
  groups.active_run_id,
  runs.candidate_revision_id,
  candidate_progress.candidate_rebuild_position,
  runs.captured_head AS candidate_rebuild_head,
  coalesce(query_models.query_models, ARRAY[]::TEXT[]) AS query_models,
  runs.started_at AS rebuild_started_at,
  groups.completed_at AS last_promoted_at,
  groups.failed_at,
  groups.failure_code,
  groups.failure_detail
FROM keiro.keiro_projection_rebuild_groups AS groups
LEFT JOIN keiro.keiro_projection_group_cursors AS cursors
  ON cursors.group_id = groups.group_id
LEFT JOIN checkpoint_floors
  ON checkpoint_floors.group_id = groups.group_id
LEFT JOIN keiro.keiro_projection_rebuild_runs AS runs
  ON runs.run_id = groups.active_run_id
LEFT JOIN candidate_progress
  ON candidate_progress.run_id = runs.run_id
LEFT JOIN query_models
  ON query_models.group_id = groups.group_id;

REVOKE ALL ON keiro_read.projection_group_status_v1 FROM PUBLIC;

COMMENT ON SCHEMA keiro_read IS
  'Versioned, owner-rights read contracts for out-of-process Keiro consumers.';
COMMENT ON VIEW keiro_read.projection_group_status_v1 IS
  'Frozen v1 projection-group status contract. Grant schema USAGE and view SELECT only.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.group_id IS
  'Stable rebuild-group identifier and row key.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.lifecycle_phase IS
  'Diagnostic lifecycle phase; readers must use reads_allowed for availability.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.reads_allowed IS
  'Authoritative permission to serve reads from the current generation.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.writes_allowed IS
  'Whether live projection writes may currently target the serving generation.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.serving_revision_id IS
  'Served schema revision, or NULL for legacy/offline groups without versioned generations.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.serving_epoch IS
  'Monotonic cache-invalidation epoch for changes to the served generation.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.serving_position_basis IS
  'append, checkpoint, or unmanaged; determines how serving_applied_position is interpreted.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.serving_applied_position IS
  'Conservative floor across every registered checkpoint subscription/member; NULL until all subscriptions are present, and always NULL for append or unmanaged groups.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.active_run_id IS
  'Active rebuild run, including a retained failed run, or NULL when no rebuild is active.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.candidate_revision_id IS
  'Versioned candidate revision for the active run, or NULL for offline/no active run.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.candidate_rebuild_position IS
  'Conservative floor of persisted source cursors for the active run, or NULL before sources exist/no active run.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.candidate_rebuild_head IS
  'Head captured by the active rebuild run, or NULL when no run is active.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.query_models IS
  'Sorted query-model names owned by the group; empty when none are registered.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.rebuild_started_at IS
  'Start time of the active rebuild run, or NULL when no run is active.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.last_promoted_at IS
  'Most recent group promotion completion time, or NULL before the first promotion.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.failed_at IS
  'Group failure time, or NULL outside a failed lifecycle.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.failure_code IS
  'Stable machine-readable group failure code, or NULL outside a failed lifecycle.';
COMMENT ON COLUMN keiro_read.projection_group_status_v1.failure_detail IS
  'Operator-facing group failure detail, or NULL outside a failed lifecycle.';
