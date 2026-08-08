-- projection replay progress

CREATE TABLE keiro.keiro_projection_rebuild_runs (
  run_id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_groups (group_id),
  catalog_fingerprint TEXT NOT NULL,
  contract_fingerprint TEXT NOT NULL,
  runner_format TEXT NOT NULL,
  captured_head BIGINT NOT NULL,
  page_size INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'running',
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  failed_at TIMESTAMPTZ,
  verified_at TIMESTAMPTZ,
  promoted_at TIMESTAMPTZ,
  failure_code TEXT,
  failure_detail TEXT,
  failure_source_id TEXT,
  failure_projection_id TEXT,
  failure_position BIGINT,
  CONSTRAINT keiro_projection_rebuild_runs_status_chk
    CHECK (status IN ('running', 'failed', 'verified', 'promoted')),
  CONSTRAINT keiro_projection_rebuild_runs_head_chk
    CHECK (captured_head >= 0),
  CONSTRAINT keiro_projection_rebuild_runs_page_size_chk
    CHECK (page_size > 0),
  CONSTRAINT keiro_projection_rebuild_runs_failure_chk
    CHECK (
      (status = 'failed' AND failure_code IS NOT NULL AND failed_at IS NOT NULL)
      OR (status <> 'failed' AND failure_code IS NULL AND failed_at IS NULL)
    )
);

CREATE TABLE keiro.keiro_projection_rebuild_sources (
  run_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_runs (run_id) ON DELETE CASCADE,
  source_id TEXT NOT NULL,
  source_scope TEXT NOT NULL,
  category TEXT,
  cursor_position BIGINT NOT NULL DEFAULT 0,
  target_position BIGINT NOT NULL,
  exhausted_through BIGINT,
  event_count BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, source_id),
  CONSTRAINT keiro_projection_rebuild_sources_scope_chk
    CHECK (
      (source_scope = 'all' AND category IS NULL)
      OR (source_scope = 'category' AND category IS NOT NULL)
    ),
  CONSTRAINT keiro_projection_rebuild_sources_cursor_chk
    CHECK (cursor_position >= 0 AND cursor_position <= target_position),
  CONSTRAINT keiro_projection_rebuild_sources_target_chk
    CHECK (target_position >= 0),
  CONSTRAINT keiro_projection_rebuild_sources_exhausted_chk
    CHECK (exhausted_through IS NULL OR exhausted_through = target_position),
  CONSTRAINT keiro_projection_rebuild_sources_count_chk
    CHECK (event_count >= 0)
);

CREATE TABLE keiro.keiro_projection_rebuild_adapters (
  run_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  projection_id TEXT NOT NULL,
  adapter_order INTEGER NOT NULL,
  evaluation_count BIGINT NOT NULL DEFAULT 0,
  apply_count BIGINT NOT NULL DEFAULT 0,
  completed_through BIGINT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, source_id, projection_id),
  UNIQUE (run_id, adapter_order),
  FOREIGN KEY (run_id, source_id)
    REFERENCES keiro.keiro_projection_rebuild_sources (run_id, source_id)
    ON DELETE CASCADE,
  CONSTRAINT keiro_projection_rebuild_adapters_order_chk
    CHECK (adapter_order >= 0),
  CONSTRAINT keiro_projection_rebuild_adapters_counts_chk
    CHECK (evaluation_count >= 0 AND apply_count >= 0 AND apply_count <= evaluation_count),
  CONSTRAINT keiro_projection_rebuild_adapters_completed_chk
    CHECK (completed_through IS NULL OR completed_through >= 0)
);

CREATE TABLE keiro.keiro_projection_rebuild_verifications (
  run_id TEXT NOT NULL
    REFERENCES keiro.keiro_projection_rebuild_runs (run_id) ON DELETE CASCADE,
  verification_id TEXT NOT NULL,
  verification_version TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  detail TEXT,
  completed_at TIMESTAMPTZ,
  PRIMARY KEY (run_id, verification_id),
  CONSTRAINT keiro_projection_rebuild_verifications_status_chk
    CHECK (status IN ('pending', 'passed', 'failed')),
  CONSTRAINT keiro_projection_rebuild_verifications_completion_chk
    CHECK (
      (status = 'pending' AND completed_at IS NULL)
      OR (status IN ('passed', 'failed') AND completed_at IS NOT NULL)
    )
);

CREATE INDEX keiro_projection_rebuild_runs_group_idx
  ON keiro.keiro_projection_rebuild_runs (group_id, started_at DESC);
