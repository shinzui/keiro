-- The keiro_subscription_shards table: cooperative ownership of category
-- subscription buckets (EP-51).
--
-- A "bucket" is a kiroku consumer-group member index in [0, shard_count): the
-- stream key (originating stream_id) hashes to one bucket via
--   (((hashtextextended(stream_id::text, 0) % shard_count) + shard_count) % shard_count)
-- exactly as kiroku's readCategoryForwardConsumerGroupStmt does. This table does
-- NOT re-hash anything; it records WHO owns each bucket right now, as a renewable
-- lease. A live worker renews lease_expires_at on a heartbeat; a dead worker stops
-- renewing, its lease expires, and another worker re-claims the bucket (failover).
--
-- One row per (subscription_name, bucket). owner_worker_id NULL means unowned
-- (free to claim). The journal/checkpoints stay in kiroku's `subscriptions` table
-- keyed (subscription_name, consumer_group_member); this table only governs
-- assignment, never event position.
CREATE TABLE IF NOT EXISTS keiro.keiro_subscription_shards (
  subscription_name  TEXT        NOT NULL,
  bucket             INT         NOT NULL,        -- kiroku consumer-group member index
  shard_count        INT         NOT NULL,        -- N; fixed per subscription_name
  owner_worker_id    UUID,                        -- NULL = unowned / claimable
  lease_expires_at   TIMESTAMPTZ,                 -- NULL when unowned
  heartbeat_at       TIMESTAMPTZ,                 -- last renewal (observability)
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (subscription_name, bucket),
  CONSTRAINT keiro_subscription_shards_bucket_range_chk
    CHECK (bucket >= 0 AND bucket < shard_count),
  CONSTRAINT keiro_subscription_shards_count_chk
    CHECK (shard_count >= 1)
);

-- Fast lookup of an owner's currently-held buckets (renew path) and of
-- claimable buckets (claim path filters on lease_expires_at).
CREATE INDEX IF NOT EXISTS keiro_subscription_shards_owner_idx
  ON keiro.keiro_subscription_shards (subscription_name, owner_worker_id);

-- Find expired/unowned buckets cheaply during a claim sweep.
CREATE INDEX IF NOT EXISTS keiro_subscription_shards_lease_idx
  ON keiro.keiro_subscription_shards (subscription_name, lease_expires_at);
