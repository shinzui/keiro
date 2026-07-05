-- Serves the outbox claim query's candidate scan: ordered walk by
-- (created_at, outbox_id) over claimable rows, stopping at the batch limit.
-- next_attempt_at is a residual filter, usually already satisfied for pending rows.
CREATE INDEX IF NOT EXISTS keiro_outbox_claim_order_idx
  ON keiro.keiro_outbox (created_at, outbox_id)
  WHERE status IN ('pending', 'failed');
