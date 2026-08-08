-- projection rebuild groups

CREATE TABLE IF NOT EXISTS keiro.keiro_projection_rebuild_groups (
  group_id TEXT PRIMARY KEY,
  catalog_fingerprint TEXT NOT NULL,
  status TEXT NOT NULL,
  active_run_id TEXT,
  requested_by TEXT,
  request_reason TEXT,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  failure_code TEXT,
  failure_detail TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT keiro_projection_rebuild_groups_status_chk
    CHECK (status IN ('live', 'rebuilding', 'failed')),
  CONSTRAINT keiro_projection_rebuild_groups_active_run_chk
    CHECK (
      (status = 'live' AND active_run_id IS NULL)
      OR (status IN ('rebuilding', 'failed') AND active_run_id IS NOT NULL)
    )
);

ALTER TABLE keiro.keiro_read_models
  ADD COLUMN IF NOT EXISTS rebuild_group_id TEXT;

-- Every pre-catalog read model becomes a deterministic singleton group. A
-- non-live legacy state stays fenced: rebuilding remains rebuilding, while
-- paused, abandoned, and unknown values become failed with the raw state in
-- failure_detail. The catalog registration path may later adopt a matching live
-- singleton into an explicitly named catalog group.
INSERT INTO keiro.keiro_projection_rebuild_groups (
  group_id,
  catalog_fingerprint,
  status,
  active_run_id,
  started_at,
  failed_at,
  failure_code,
  failure_detail,
  created_at,
  updated_at
)
SELECT
  '$legacy-read-model:' || name,
  '$legacy-unmanaged',
  CASE status
    WHEN 'live' THEN 'live'
    WHEN 'rebuilding' THEN 'rebuilding'
    ELSE 'failed'
  END,
  CASE
    WHEN status = 'live' THEN NULL
    ELSE '$legacy-read-model:' || name
  END,
  CASE WHEN status = 'rebuilding' THEN updated_at ELSE NULL END,
  CASE WHEN status NOT IN ('live', 'rebuilding') THEN updated_at ELSE NULL END,
  CASE WHEN status NOT IN ('live', 'rebuilding') THEN 'legacy-read-model-state' ELSE NULL END,
  CASE WHEN status NOT IN ('live', 'rebuilding') THEN status ELSE NULL END,
  updated_at,
  updated_at
FROM keiro.keiro_read_models
ON CONFLICT (group_id) DO NOTHING;

UPDATE keiro.keiro_read_models
SET rebuild_group_id = '$legacy-read-model:' || name
WHERE rebuild_group_id IS NULL;

ALTER TABLE keiro.keiro_read_models
  ALTER COLUMN rebuild_group_id SET NOT NULL;

ALTER TABLE keiro.keiro_read_models
  ADD CONSTRAINT keiro_read_models_rebuild_group_fk
  FOREIGN KEY (rebuild_group_id)
  REFERENCES keiro.keiro_projection_rebuild_groups (group_id);

CREATE INDEX IF NOT EXISTS keiro_read_models_rebuild_group_idx
  ON keiro.keiro_read_models (rebuild_group_id);
