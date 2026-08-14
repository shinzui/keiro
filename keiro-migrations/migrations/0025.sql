-- schema-versioned projection rebuild lifecycle

-- The existing status column remains the lifecycle phase so a pre-feature
-- runtime sees every version-managed value as unknown and fails closed.
ALTER TABLE keiro.keiro_projection_rebuild_groups
  DROP CONSTRAINT keiro_projection_rebuild_groups_status_chk,
  DROP CONSTRAINT keiro_projection_rebuild_groups_active_run_chk,
  ADD COLUMN serving_revision_id TEXT,
  ADD COLUMN serving_epoch BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN reads_allowed BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN writes_allowed BOOLEAN NOT NULL DEFAULT TRUE;

UPDATE keiro.keiro_projection_rebuild_groups
SET reads_allowed = (status = 'live'),
    writes_allowed = (status = 'live');

ALTER TABLE keiro.keiro_projection_rebuild_groups
  ADD CONSTRAINT keiro_projection_rebuild_groups_status_chk
    CHECK (
      status IN (
        'live',
        'rebuilding',
        'failed',
        'serving-versioned',
        'rebuilding-versioned',
        'cutover-versioned',
        'failed-versioned'
      )
    ),
  ADD CONSTRAINT keiro_projection_rebuild_groups_active_run_chk
    CHECK (
      (status IN ('live', 'serving-versioned') AND active_run_id IS NULL)
      OR (
        status IN (
          'rebuilding',
          'failed',
          'rebuilding-versioned',
          'cutover-versioned',
          'failed-versioned'
        )
        AND active_run_id IS NOT NULL
      )
    ),
  ADD CONSTRAINT keiro_projection_rebuild_groups_revision_phase_chk
    CHECK (
      (
        status IN ('live', 'rebuilding', 'failed')
        AND serving_revision_id IS NULL
        AND serving_epoch = 0
      )
      OR (
        status IN (
          'serving-versioned',
          'rebuilding-versioned',
          'cutover-versioned',
          'failed-versioned'
        )
        AND serving_revision_id IS NOT NULL
        AND serving_epoch >= 0
      )
    ),
  ADD CONSTRAINT keiro_projection_rebuild_groups_availability_chk
    CHECK (
      (status = 'live' AND reads_allowed AND writes_allowed)
      OR (status IN ('rebuilding', 'failed') AND NOT reads_allowed AND NOT writes_allowed)
      OR (status IN ('serving-versioned', 'rebuilding-versioned') AND reads_allowed AND writes_allowed)
      OR (status IN ('cutover-versioned', 'failed-versioned') AND reads_allowed AND NOT writes_allowed)
    );

CREATE TABLE keiro.keiro_projection_revisions (
  group_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_groups (group_id),
  revision_id TEXT NOT NULL,
  group_slice_fingerprint TEXT NOT NULL,
  registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, revision_id),
  UNIQUE (revision_id),
  CONSTRAINT keiro_projection_revisions_identity_chk
    CHECK (
      length(group_id) > 0
      AND length(revision_id) > 0
      AND length(group_slice_fingerprint) > 0
    )
);

ALTER TABLE keiro.keiro_projection_rebuild_groups
  ADD CONSTRAINT keiro_projection_rebuild_groups_serving_revision_fk
  FOREIGN KEY (group_id, serving_revision_id)
  REFERENCES keiro.keiro_projection_revisions (group_id, revision_id);

ALTER TABLE keiro.keiro_projection_rebuild_runs
  DROP CONSTRAINT keiro_projection_rebuild_runs_status_chk,
  DROP CONSTRAINT keiro_projection_rebuild_runs_failure_chk,
  ADD COLUMN rebuild_mode TEXT NOT NULL DEFAULT 'offline',
  ADD COLUMN candidate_revision_id TEXT,
  ADD COLUMN cutover_threshold BIGINT,
  ADD COLUMN cutover_lock_timeout_ms BIGINT,
  ADD COLUMN history_retention_lease_id UUID,
  ADD COLUMN history_retention_lease_owner TEXT,
  ADD COLUMN history_retention_protected_through BIGINT,
  ADD COLUMN history_retention_expires_at TIMESTAMPTZ,
  ADD COLUMN history_retention_renewed_at TIMESTAMPTZ,
  ADD COLUMN history_retention_released_at TIMESTAMPTZ,
  ADD COLUMN abandoned_at TIMESTAMPTZ,
  ADD CONSTRAINT keiro_projection_rebuild_runs_status_chk
    CHECK (status IN ('running', 'failed', 'verified', 'cutover', 'promoted', 'abandoned')),
  ADD CONSTRAINT keiro_projection_rebuild_runs_failure_chk
    CHECK (
      (status = 'failed' AND failure_code IS NOT NULL AND failed_at IS NOT NULL)
      OR (status <> 'failed' AND failure_code IS NULL AND failed_at IS NULL)
    ),
  ADD CONSTRAINT keiro_projection_rebuild_runs_abandoned_chk
    CHECK (
      (status = 'abandoned' AND abandoned_at IS NOT NULL)
      OR (status <> 'abandoned' AND abandoned_at IS NULL)
    ),
  ADD CONSTRAINT keiro_projection_rebuild_runs_mode_chk
    CHECK (
      (
        rebuild_mode = 'offline'
        AND candidate_revision_id IS NULL
        AND cutover_threshold IS NULL
        AND cutover_lock_timeout_ms IS NULL
        AND history_retention_lease_id IS NULL
        AND history_retention_lease_owner IS NULL
        AND history_retention_protected_through IS NULL
        AND history_retention_expires_at IS NULL
        AND history_retention_renewed_at IS NULL
        AND history_retention_released_at IS NULL
      )
      OR (
        rebuild_mode = 'versioned'
        AND candidate_revision_id IS NOT NULL
        AND cutover_threshold IS NOT NULL
        AND cutover_threshold >= 0
        AND cutover_lock_timeout_ms IS NOT NULL
        AND cutover_lock_timeout_ms > 0
        AND history_retention_lease_id IS NOT NULL
        AND history_retention_lease_owner IS NOT NULL
        AND length(history_retention_lease_owner) > 0
        AND history_retention_protected_through IS NOT NULL
        AND history_retention_protected_through >= 0
        AND history_retention_expires_at IS NOT NULL
        AND history_retention_renewed_at IS NOT NULL
      )
    ),
  ADD CONSTRAINT keiro_projection_rebuild_runs_candidate_revision_fk
    FOREIGN KEY (group_id, candidate_revision_id)
    REFERENCES keiro.keiro_projection_revisions (group_id, revision_id);

CREATE TABLE keiro.keiro_projection_target_generations (
  generation_id UUID PRIMARY KEY,
  group_id TEXT NOT NULL,
  target_id TEXT NOT NULL,
  revision_id TEXT NOT NULL,
  schema_name TEXT NOT NULL,
  relation_name TEXT NOT NULL,
  relation_oid BIGINT NOT NULL,
  schema_version TEXT NOT NULL,
  expected_shape_id TEXT NOT NULL,
  observed_shape_fingerprint TEXT NOT NULL,
  observed_catalog_snapshot TEXT NOT NULL,
  lifecycle TEXT NOT NULL,
  created_by_run_id TEXT
    REFERENCES keiro.keiro_projection_rebuild_runs (run_id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  served_at TIMESTAMPTZ,
  retired_at TIMESTAMPTZ,
  dropped_at TIMESTAMPTZ,
  UNIQUE (generation_id, created_by_run_id, target_id),
  FOREIGN KEY (group_id, revision_id)
    REFERENCES keiro.keiro_projection_revisions (group_id, revision_id),
  CONSTRAINT keiro_projection_target_generations_identity_chk
    CHECK (
      length(target_id) > 0
      AND length(schema_name) > 0
      AND length(relation_name) > 0
      AND relation_oid > 0
      AND length(schema_version) > 0
      AND length(expected_shape_id) > 0
      AND length(observed_shape_fingerprint) > 0
    ),
  CONSTRAINT keiro_projection_target_generations_lifecycle_chk
    CHECK (lifecycle IN ('staging', 'serving', 'retired', 'dropped')),
  CONSTRAINT keiro_projection_target_generations_transition_evidence_chk
    CHECK (
      (
        lifecycle = 'staging'
        AND created_by_run_id IS NOT NULL
        AND served_at IS NULL
        AND retired_at IS NULL
        AND dropped_at IS NULL
      )
      OR (
        lifecycle = 'serving'
        AND served_at IS NOT NULL
        AND retired_at IS NULL
        AND dropped_at IS NULL
      )
      OR (
        lifecycle = 'retired'
        AND served_at IS NOT NULL
        AND retired_at IS NOT NULL
        AND dropped_at IS NULL
      )
      OR (
        lifecycle = 'dropped'
        AND dropped_at IS NOT NULL
        AND (
          (served_at IS NULL AND retired_at IS NULL)
          OR (served_at IS NOT NULL AND retired_at IS NOT NULL)
        )
      )
    )
);

CREATE UNIQUE INDEX keiro_projection_target_generations_serving_idx
  ON keiro.keiro_projection_target_generations (group_id, target_id)
  WHERE lifecycle = 'serving';

CREATE UNIQUE INDEX keiro_projection_target_generations_relation_idx
  ON keiro.keiro_projection_target_generations (schema_name, relation_name)
  WHERE lifecycle <> 'dropped';

CREATE TABLE keiro.keiro_projection_rebuild_run_targets (
  run_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_runs (run_id) ON DELETE CASCADE,
  target_id TEXT NOT NULL,
  target_mode TEXT NOT NULL,
  candidate_generation_id UUID NOT NULL,
  PRIMARY KEY (run_id, target_id),
  UNIQUE (candidate_generation_id),
  FOREIGN KEY (candidate_generation_id, run_id, target_id)
    REFERENCES keiro.keiro_projection_target_generations
      (generation_id, created_by_run_id, target_id),
  CONSTRAINT keiro_projection_rebuild_run_targets_mode_chk
    CHECK (target_mode IN ('application', 'clone'))
);

CREATE TABLE keiro.keiro_projection_rebuild_promotion_objects (
  run_id TEXT NOT NULL,
  target_id TEXT NOT NULL,
  object_order INTEGER NOT NULL,
  object_kind TEXT NOT NULL,
  generation_name TEXT NOT NULL,
  canonical_name TEXT NOT NULL,
  PRIMARY KEY (run_id, target_id, object_order),
  UNIQUE (run_id, target_id, generation_name),
  UNIQUE (run_id, target_id, canonical_name),
  FOREIGN KEY (run_id, target_id)
    REFERENCES keiro.keiro_projection_rebuild_run_targets (run_id, target_id)
    ON DELETE CASCADE,
  CONSTRAINT keiro_projection_rebuild_promotion_objects_order_chk
    CHECK (object_order >= 0),
  CONSTRAINT keiro_projection_rebuild_promotion_objects_kind_chk
    CHECK (object_kind IN ('index', 'constraint', 'owned-sequence')),
  CONSTRAINT keiro_projection_rebuild_promotion_objects_names_chk
    CHECK (length(generation_name) > 0 AND length(canonical_name) > 0)
);

COMMENT ON TABLE keiro.keiro_projection_revisions IS
  'Registered executable/schema revision identities for projection rebuild groups.';

COMMENT ON TABLE keiro.keiro_projection_target_generations IS
  'Durable physical projection target identity and schema evidence across staging, serving, retirement, and drop.';
