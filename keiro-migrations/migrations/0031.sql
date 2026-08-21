-- add terminal outbox rejection outcome

ALTER TABLE keiro.keiro_outbox
  ADD COLUMN rejected_at TIMESTAMPTZ,
  ADD COLUMN rejection_code TEXT,
  ADD COLUMN rejection_detail TEXT,
  ADD CONSTRAINT keiro_outbox_rejection_audit_check CHECK (
    (
      status = 'rejected'
      AND rejected_at IS NOT NULL
      AND rejection_code IS NOT NULL
    )
    OR
    (
      status <> 'rejected'
      AND rejected_at IS NULL
      AND rejection_code IS NULL
      AND rejection_detail IS NULL
    )
  ),
  ADD CONSTRAINT keiro_outbox_rejection_code_check CHECK (
    rejection_code IS NULL
    OR rejection_code ~ '^[a-z][a-z0-9._-]{0,63}$'
  ),
  ADD CONSTRAINT keiro_outbox_rejection_detail_check CHECK (
    rejection_detail IS NULL
    OR octet_length(rejection_detail) BETWEEN 1 AND 1024
  );

-- Rejected rows are terminal and must not remain in head-of-line indexes.
DROP INDEX IF EXISTS keiro.keiro_outbox_head_of_line_idx;
CREATE INDEX keiro_outbox_head_of_line_idx
  ON keiro.keiro_outbox (source, message_key, created_at)
  WHERE status NOT IN ('sent', 'dead', 'rejected') AND message_key IS NOT NULL;

DROP INDEX IF EXISTS keiro.keiro_outbox_source_order_idx;
CREATE INDEX keiro_outbox_source_order_idx
  ON keiro.keiro_outbox (source, created_at, outbox_id)
  WHERE status NOT IN ('sent', 'dead', 'rejected');
