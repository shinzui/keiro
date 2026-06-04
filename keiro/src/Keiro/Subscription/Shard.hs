{- | Cooperative consumer-group ownership for category subscriptions (EP-51).

kiroku already partitions a category into @N@ buckets (consumer-group members) by
a stable hash of the originating stream id, and keeps a per-member checkpoint, so
@N@ disjoint readers can drain a busy category in parallel. What kiroku leaves to
the operator is /membership/: "exactly one live process must own each member
index at a time" is, by itself, a manual @[0..N-1]@ wiring. This module supplies
the missing operability layer — a __lease__ over each bucket so a pool of
identical worker processes agree, with no external coordinator, on who owns which
bucket right now and re-divide the buckets automatically when a worker joins,
leaves, or dies.

The storage and SQL live in "Keiro.Subscription.Shard.Schema"; this module is the
typed 'Eff'-level surface over kiroku's 'Store':

* 'freshWorkerId' mints the per-process owner id.
* 'acquireOwnedBuckets' is the one-pass reconcile: renew the leases this worker
  still holds, then claim up to a /fair share/ more (taking over any expired
  leases), returning the buckets owned after the pass.
* 'renewOwnedBuckets' / 'relinquish' are the heartbeat and the graceful release.
* 'ensureShards' / 'ownershipSnapshot' populate and read the table.

The lease, not a held lock, is the ownership mechanism: a transaction-scoped
advisory lock auto-releases at transaction end (so it cannot span a worker's
multi-transaction lifetime) and a session-scoped lock has no connection affinity
through kiroku's pooled 'Store' — the same finding
'Keiro.Workflow.Resume.WorkflowResumeOptions' records for the resume worker. A
renewable @lease_expires_at@ timestamp gives lifetime ownership and automatic
failover without depending on connection affinity, and disjointness rests on the
@FOR UPDATE SKIP LOCKED@ claim, not on the liveness estimate being exact.
-}
module Keiro.Subscription.Shard
  ( -- * Worker identity
    WorkerId (..)
  , freshWorkerId

    -- * Lease descriptor
  , ShardLease (..)

    -- * Ownership operations
  , ensureShards
  , acquireOwnedBuckets
  , renewOwnedBuckets
  , relinquish
  , ownershipSnapshot

    -- * Fair-share helper
  , fairShareTarget
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time (NominalDiffTime)
import Data.UUID.V4 qualified as UUIDv4
import Effectful (Eff, IOE, (:>))
import Keiro.Prelude
import Keiro.Subscription.Shard.Schema
  ( WorkerId (..)
  , claimShardsTx
  , ensureShardRows
  , listShardOwnership
  , releaseShardsTx
  , renewLeaseTx
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Subscription.Types (SubscriptionName)
import Kiroku.Store.Transaction (runTransaction)

-- | Mint a fresh per-process 'WorkerId' (a random UUID).
freshWorkerId :: (IOE :> es) => Eff es WorkerId
freshWorkerId = WorkerId <$> liftIO UUIDv4.nextRandom

{- | Everything an ownership pass needs for one @(subscription, worker)@: which
subscription is being sharded, this worker's id, the fixed bucket count @N@, and
how long a claim/renew is valid before it expires.
-}
data ShardLease = ShardLease
  { subscriptionName :: !SubscriptionName
  , workerId :: !WorkerId
  , shardCount :: !Int
  -- ^ @N@; the fixed number of buckets for this subscription name.
  , leaseTtl :: !NominalDiffTime
  -- ^ How long a claim or renewal keeps a bucket before it expires.
  }
  deriving stock (Generic)

-- | The fair-share claim target: @ceil(N / liveWorkers)@. When @k@ workers are
-- live they collectively claim all @N@ buckets and no single worker hogs them. A
-- non-positive @liveWorkers@ is treated as one (claim everything).
fairShareTarget :: Int -> Int -> Int
fairShareTarget shardCount liveWorkers =
  let k = max 1 liveWorkers
   in (shardCount + k - 1) `div` k

-- | Idempotently populate the @N@ shard rows for this subscription. Safe to call
-- on every worker startup ('ensureShardRows' uses @ON CONFLICT DO NOTHING@).
ensureShards :: (Store :> es) => ShardLease -> Eff es ()
ensureShards lease =
  runTransaction (ensureShardRows (subscriptionName lease) (shardCount lease))

{- | One ownership-reconcile pass: in a single transaction, renew the leases this
worker still holds, then — if it holds fewer than its fair share — claim __one__
more bucket (unowned or expired). Returns the set of buckets owned __after__ the
pass.

Claiming __one at a time__ is deliberate and is what makes a pool of identical
workers converge to a fair split without any external coordinator. If a cold
worker grabbed its whole fair share at once it could, racing alone before its
peers' first pass, monopolise every bucket and then never see the idle peers
(they own nothing, so they are invisible in the lease table). Taking one bucket
per pass instead means concurrently-starting workers each grab one, become
visible after the first pass, and climb to an even share together; a worker
joining a balanced pool only picks up buckets freed by an expired lease
(failover). Ownership spreads over up to @N@ reconcile intervals — a deliberate
trade of spin-up latency for coordinator-free fairness.

@liveWorkers@ is the caller's estimate of how many workers are currently live
(see 'ownershipSnapshot'); it tunes the fair-share target and self-corrects next
pass. It never causes double ownership, because the @FOR UPDATE SKIP LOCKED@
claim is the real exclusion mechanism.
-}
acquireOwnedBuckets :: (IOE :> es, Store :> es) => ShardLease -> Int -> Eff es (Set Int)
acquireOwnedBuckets lease liveWorkers = do
  now <- liftIO getCurrentTime
  let target = fairShareTarget (shardCount lease) liveWorkers
  runTransaction $ do
    held <- renewLeaseTx (subscriptionName lease) (workerId lease) now (leaseTtl lease)
    -- Claim at most one bucket per pass (see the note above on convergence).
    claimed <-
      if length held < target
        then claimShardsTx (subscriptionName lease) (workerId lease) 1 now (leaseTtl lease)
        else pure []
    pure (Set.fromList held <> Set.fromList claimed)

-- | Renew only — write a fresh expiry for every bucket this worker still holds
-- and return them. Used when a worker wants to heartbeat without claiming more.
renewOwnedBuckets :: (IOE :> es, Store :> es) => ShardLease -> Eff es (Set Int)
renewOwnedBuckets lease = do
  now <- liftIO getCurrentTime
  held <- runTransaction (renewLeaseTx (subscriptionName lease) (workerId lease) now (leaseTtl lease))
  pure (Set.fromList held)

-- | Graceful release of the given buckets (clean shutdown), so they are
-- claimable immediately instead of after lease expiry.
relinquish :: (Store :> es) => ShardLease -> Set Int -> Eff es ()
relinquish lease buckets =
  runTransaction (releaseShardsTx (subscriptionName lease) (workerId lease) (Set.toList buckets))

-- | Read every bucket's @(bucket, owner, lease_expires_at)@ for this
-- subscription. The worker uses it to estimate @liveWorkers@ (count of distinct
-- non-expired owners) before an 'acquireOwnedBuckets' pass.
ownershipSnapshot ::
  (Store :> es) => ShardLease -> Eff es [(Int, Maybe WorkerId, Maybe UTCTime)]
ownershipSnapshot lease =
  runTransaction (listShardOwnership (subscriptionName lease))
