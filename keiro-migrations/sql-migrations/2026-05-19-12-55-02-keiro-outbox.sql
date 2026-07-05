CREATE TABLE IF NOT EXISTS keiro.keiro_outbox (
  outbox_id UUID PRIMARY KEY,
  message_id TEXT NOT NULL,
  source TEXT NOT NULL,
  destination TEXT NOT NULL,
  message_key TEXT,
  event_type TEXT NOT NULL,
  schema_version BIGINT NOT NULL,
  content_type TEXT NOT NULL,
  schema_registry TEXT,
  schema_subject TEXT,
  schema_version_ref BIGINT,
  schema_id BIGINT,
  schema_fingerprint TEXT,
  source_event_id UUID,
  source_global_position BIGINT,
  causation_id UUID,
  correlation_id UUID,
  traceparent TEXT,
  tracestate TEXT,
  payload_bytes BYTEA NOT NULL,
  attributes JSONB,
  occurred_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  attempt_count BIGINT NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error TEXT,
  published_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source, message_id)
);

CREATE INDEX IF NOT EXISTS keiro_outbox_pending_idx
  ON keiro.keiro_outbox (status, next_attempt_at, created_at);

CREATE INDEX IF NOT EXISTS keiro_outbox_head_of_line_idx
  ON keiro.keiro_outbox (source, message_key, created_at)
  WHERE status NOT IN ('sent', 'dead') AND message_key IS NOT NULL;
