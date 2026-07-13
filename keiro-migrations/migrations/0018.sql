-- keiro dead letters

-- Durable records for process-manager and router dispatches that reached a
-- target stream but were rejected. These rows are distinct from
-- kiroku.dead_letters: the source subscription event is successfully handled
-- and checkpointed after every rejected dispatch has been recorded here.
CREATE TABLE IF NOT EXISTS keiro.keiro_dead_letters (
  dead_letter_id          BIGSERIAL   PRIMARY KEY,
  dispatcher_kind         TEXT        NOT NULL,
  dispatcher_name         TEXT        NOT NULL,
  correlation_id          TEXT        NOT NULL,
  source_event_id         UUID        NOT NULL,
  source_global_position  BIGINT      NOT NULL,
  emit_index              INT         NOT NULL,
  target_stream_name      TEXT        NOT NULL,
  error_class             TEXT        NOT NULL,
  error_detail            TEXT        NOT NULL,
  attempt_count           INT         NOT NULL,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT keiro_dead_letters_dispatcher_kind_chk
    CHECK (dispatcher_kind IN ('process-manager', 'router')),
  CONSTRAINT keiro_dead_letters_attempt_count_chk
    CHECK (attempt_count >= 1),
  UNIQUE (dispatcher_name, source_event_id, emit_index)
);

CREATE INDEX IF NOT EXISTS keiro_dead_letters_dispatcher_created_at_idx
  ON keiro.keiro_dead_letters (dispatcher_name, created_at DESC);
