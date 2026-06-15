SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_projection_dedup (
  projection_name TEXT        NOT NULL,
  event_id        UUID        NOT NULL,
  applied_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (projection_name, event_id)
);

CREATE INDEX IF NOT EXISTS keiro_projection_dedup_applied_at_idx
  ON keiro_projection_dedup (applied_at);
