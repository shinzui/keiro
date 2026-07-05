-- Keiro framework bootstrap migration (codd).
--
-- Keiro owns the dedicated `keiro` schema. codd applies this file in its own
-- session, so the schema is created here and every object is written fully
-- qualified as keiro.<name> — no session search_path pin is used anywhere.
CREATE SCHEMA IF NOT EXISTS keiro;

CREATE TABLE IF NOT EXISTS keiro.keiro_snapshots (
  stream_id BIGINT PRIMARY KEY,
  stream_version BIGINT NOT NULL,
  state JSONB NOT NULL,
  state_codec_version BIGINT NOT NULL,
  regfile_shape_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS keiro_snapshots_compat_idx
  ON keiro.keiro_snapshots (stream_id, state_codec_version, regfile_shape_hash, stream_version DESC);

CREATE TABLE IF NOT EXISTS keiro.keiro_read_models (
  name TEXT PRIMARY KEY,
  version BIGINT NOT NULL,
  shape_hash TEXT NOT NULL,
  last_built_at TIMESTAMPTZ,
  status TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS keiro.keiro_timers (
  timer_id UUID PRIMARY KEY,
  process_manager_name TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  fire_at TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled',
  attempts BIGINT NOT NULL DEFAULT 0,
  fired_event_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
  ON keiro.keiro_timers (status, fire_at, process_manager_name);
