-- Reserve worker-side state on keiro_inbox without breaking existing rows.
ALTER TABLE keiro_inbox
    ADD COLUMN IF NOT EXISTS attempt_count   INTEGER  NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS claimed_at      TIMESTAMPTZ;

-- Existing rows were written by runInboxTransaction in one tx and are
-- already 'completed' or 'failed'; back-fill is unnecessary. New states:
-- 'pending' (written, awaiting handler) and 'dead' (terminal after
-- max_attempts). 'processing' is reused as the in-flight claim marker.

CREATE INDEX IF NOT EXISTS keiro_inbox_claimable_idx
    ON keiro_inbox (next_attempt_at, source, dedupe_key)
    WHERE status IN ('pending', 'failed', 'processing');
