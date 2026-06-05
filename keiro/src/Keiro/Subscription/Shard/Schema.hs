{- | The @keiro_subscription_shards@ table: storage and lease logic for
cooperative consumer-group ownership (EP-51).

A category subscription can be split across @N@ buckets — kiroku consumer-group
member indices in @[0, N)@ — so that @N@ cooperating workers each drain a
disjoint slice of the keyspace. This module owns the durable __assignment__
layer: one row per @(subscription_name, bucket)@ recording which worker holds it
right now, as a renewable __lease__ (an owner id plus an expiry timestamp). A
live worker renews its lease on a heartbeat; a dead worker stops renewing, its
lease expires, and another worker re-claims the bucket (failover). It does
__not__ store event positions — kiroku's per-member checkpoints
(@(subscription_name, consumer_group_member)@) do that, so a re-homed bucket
resumes where its previous owner left off.

The statements here are 'Hasql.Transaction.Transaction'-flavoured so callers can
compose several into one short transaction (e.g. renew-then-claim in
'Keiro.Subscription.Shard.acquireOwnedBuckets'); the typed 'Eff'-level wrappers
that run them through kiroku's pool live in "Keiro.Subscription.Shard". The
claim uses @FOR UPDATE SKIP LOCKED@ over the claimable rows, exactly as
'Keiro.Timer.Schema.claimDueTimer' does, so two workers racing the same bucket
can never both win — a stale "how many workers are live" estimate only changes
how aggressively a worker claims, never whether ownership stays disjoint.
-}
module Keiro.Subscription.Shard.Schema (
    -- * Worker identity
    WorkerId (..),

    -- * Lease statements (composable within a transaction)
    ensureShardRows,
    claimShardsTx,
    renewLeaseTx,
    releaseShardsTx,
    listShardOwnership,
)
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Data.Int (Int32)
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

{- | A per-process unique id naming the owner in a lease row. A UUID minted once
at worker start ('Keiro.Subscription.Shard.freshWorkerId'); two restarts of the
same binary get two different ids, so a restarted process never inherits the
dead process's leases — it claims afresh once the old leases expire.
-}
newtype WorkerId = WorkerId UUID
    deriving stock (Eq, Ord, Show)

{- | Idempotently insert the @N@ rows @(name, bucket = 0..N-1, shard_count = N)@
with @owner_worker_id@ left @NULL@. @ON CONFLICT DO NOTHING@ makes calling it
on every worker startup safe; it converges the table to exactly @N@ rows.
-}
ensureShardRows :: SubscriptionName -> Int -> Tx.Transaction ()
ensureShardRows (SubscriptionName name) shardCount =
    Tx.statement (name, fromIntegral shardCount) ensureShardRowsStmt

{- | Claim up to @targetCount@ buckets that are currently unowned __or__ whose
lease has expired (@owner_worker_id IS NULL OR lease_expires_at < now@), in one
statement, returning the bucket numbers actually claimed. @FOR UPDATE SKIP
LOCKED@ over the claimable rows is the exclusion mechanism: two workers racing
the same bucket cannot both win. The TTL is added to @now@ here (in Haskell) to
form the new @lease_expires_at@.
-}
claimShardsTx ::
    SubscriptionName -> WorkerId -> Int -> UTCTime -> NominalDiffTime -> Tx.Transaction [Int]
claimShardsTx (SubscriptionName name) (WorkerId worker) targetCount now ttl =
    fmap (fmap fromIntegral) $
        Tx.statement
            (name, now, addUTCTime ttl now, worker, fromIntegral targetCount)
            claimShardsStmt

{- | Renew every lease this worker still holds: write a fresh @lease_expires_at =
now + ttl@ and @heartbeat_at = now@ for each row it owns, returning the buckets
still held. A bucket stolen after this worker's lease lapsed is owned by someone
else and so is __not__ in the result — that is how a worker learns it lost a
bucket and stops reading it.
-}
renewLeaseTx :: SubscriptionName -> WorkerId -> UTCTime -> NominalDiffTime -> Tx.Transaction [Int]
renewLeaseTx (SubscriptionName name) (WorkerId worker) now ttl =
    fmap (fmap fromIntegral) $
        Tx.statement (name, now, addUTCTime ttl now, worker) renewLeaseStmt

{- | Graceful relinquish: clear ownership of the given buckets this worker holds
so they become claimable immediately, without waiting for lease expiry. Called
on clean shutdown. Only rows still owned by @worker@ are affected, so a bucket
already stolen is left untouched.
-}
releaseShardsTx :: SubscriptionName -> WorkerId -> [Int] -> Tx.Transaction ()
releaseShardsTx (SubscriptionName name) (WorkerId worker) buckets =
    Tx.statement (name, worker, fmap fromIntegral buckets) releaseShardsStmt

{- | Observability/test read of @(bucket, owner, lease_expires_at)@ for one
subscription, ordered by bucket.
-}
listShardOwnership :: SubscriptionName -> Tx.Transaction [(Int, Maybe WorkerId, Maybe UTCTime)]
listShardOwnership (SubscriptionName name) =
    Tx.statement name listShardOwnershipStmt

ensureShardRowsStmt :: Statement (Text, Int32) ()
ensureShardRowsStmt =
    preparable
        """
        INSERT INTO keiro_subscription_shards (subscription_name, bucket, shard_count)
        SELECT $1, g, $2
        FROM generate_series(0, $2 - 1) AS g
        ON CONFLICT (subscription_name, bucket) DO NOTHING
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
        )
        D.noResult

claimShardsStmt :: Statement (Text, UTCTime, UTCTime, UUID, Int32) [Int32]
claimShardsStmt =
    preparable
        """
        WITH claimable AS (
          SELECT bucket
          FROM keiro_subscription_shards
          WHERE subscription_name = $1
            AND (owner_worker_id IS NULL OR lease_expires_at < $2)
          ORDER BY bucket
          LIMIT $5
          FOR UPDATE SKIP LOCKED
        )
        UPDATE keiro_subscription_shards s
        SET owner_worker_id = $4,
            lease_expires_at = $3,
            heartbeat_at = $2,
            updated_at = $2
        FROM claimable c
        WHERE s.subscription_name = $1 AND s.bucket = c.bucket
        RETURNING s.bucket
        """
        ( contrazip5
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.int4))
        )
        (D.rowList (D.column (D.nonNullable D.int4)))

renewLeaseStmt :: Statement (Text, UTCTime, UTCTime, UUID) [Int32]
renewLeaseStmt =
    preparable
        """
        UPDATE keiro_subscription_shards
        SET lease_expires_at = $3,
            heartbeat_at = $2,
            updated_at = $2
        WHERE subscription_name = $1
          AND owner_worker_id = $4
        RETURNING bucket
        """
        ( contrazip4
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.uuid))
        )
        (D.rowList (D.column (D.nonNullable D.int4)))

releaseShardsStmt :: Statement (Text, UUID, [Int32]) ()
releaseShardsStmt =
    preparable
        """
        UPDATE keiro_subscription_shards
        SET owner_worker_id = NULL,
            lease_expires_at = NULL,
            updated_at = now()
        WHERE subscription_name = $1
          AND owner_worker_id = $2
          AND bucket = ANY($3)
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.int4))))
        )
        D.noResult

listShardOwnershipStmt :: Statement Text [(Int, Maybe WorkerId, Maybe UTCTime)]
listShardOwnershipStmt =
    preparable
        """
        SELECT bucket, owner_worker_id, lease_expires_at
        FROM keiro_subscription_shards
        WHERE subscription_name = $1
        ORDER BY bucket
        """
        (E.param (E.nonNullable E.text))
        (D.rowList ownershipRowDecoder)

ownershipRowDecoder :: D.Row (Int, Maybe WorkerId, Maybe UTCTime)
ownershipRowDecoder =
    (,,)
        <$> (fromIntegral <$> D.column (D.nonNullable D.int4))
        <*> (fmap WorkerId <$> D.column (D.nullable D.uuid))
        <*> D.column (D.nullable D.timestamptz)
