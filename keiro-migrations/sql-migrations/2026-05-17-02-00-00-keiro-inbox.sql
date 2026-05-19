CREATE TABLE IF NOT EXISTS keiro_inbox (
  source TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  message_id TEXT,
  source_event_id UUID,
  source_global_position BIGINT,
  destination TEXT,
  event_type TEXT,
  schema_version BIGINT,
  content_type TEXT NOT NULL,
  schema_registry TEXT,
  schema_subject TEXT,
  schema_version_ref BIGINT,
  schema_id BIGINT,
  schema_fingerprint TEXT,
  causation_id UUID,
  correlation_id UUID,
  traceparent TEXT,
  tracestate TEXT,
  kafka_topic TEXT,
  kafka_partition BIGINT,
  kafka_offset BIGINT,
  payload_bytes BYTEA NOT NULL,
  attributes JSONB,
  occurred_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'processing',
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  last_error TEXT,
  PRIMARY KEY (source, dedupe_key)
);

CREATE INDEX IF NOT EXISTS keiro_inbox_received_idx
  ON keiro_inbox (received_at);

CREATE INDEX IF NOT EXISTS keiro_inbox_completed_idx
  ON keiro_inbox (completed_at)
  WHERE status = 'completed';
