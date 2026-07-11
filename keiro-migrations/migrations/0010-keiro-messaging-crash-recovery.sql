-- messaging crash recovery

-- H5: per-message failure accounting for the inbox poison-message path.
ALTER TABLE keiro.keiro_inbox
  ADD COLUMN IF NOT EXISTS attempt_count BIGINT NOT NULL DEFAULT 0;

-- H3: lets the backlog gauge count rows without a sequential scan.
CREATE INDEX IF NOT EXISTS keiro_inbox_backlog_idx
  ON keiro.keiro_inbox (status)
  WHERE status IN ('processing', 'failed');

-- H4: lets garbageCollectSent find expired sent rows without a sequential scan.
CREATE INDEX IF NOT EXISTS keiro_outbox_sent_gc_idx
  ON keiro.keiro_outbox (published_at)
  WHERE status = 'sent';

-- L8: supports the PerSourceStream head-of-line predicate (any key, including
-- NULL); the existing keiro_outbox_head_of_line_idx excludes NULL keys.
CREATE INDEX IF NOT EXISTS keiro_outbox_source_order_idx
  ON keiro.keiro_outbox (source, created_at, outbox_id)
  WHERE status NOT IN ('sent', 'dead');
