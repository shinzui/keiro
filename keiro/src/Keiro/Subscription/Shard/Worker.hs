{- | The sharded category-subscription worker: a rebalance loop that turns
leased bucket ownership ("Keiro.Subscription.Shard") into running kiroku
consumer-group readers (EP-51).

Start the __same__ worker binary @N@ times — on @N@ hosts, in @N@ containers, in
an autoscaling group — each calling 'runShardedSubscriptionGroup' with the same
'SubscriptionName' and 'ShardedWorkerOptions', and the workers cooperatively
partition the category among themselves: every event is processed by exactly one
worker, none twice, none skipped. No external coordinator (etcd/ZooKeeper/Consul)
— coordination lives in the @keiro_subscription_shards@ lease table.

== One pass

'reconcileShardsOnce' is the single testable unit (like
'Keiro.Workflow.Resume.resumeWorkflowsOnce'):

1. Estimate how many workers are live from the lease table.
2. 'Keiro.Subscription.Shard.acquireOwnedBuckets' — renew the leases this worker
   still holds and claim up to a fair share more (taking over expired leases).
3. __Shed__ any buckets held beyond the fair share when more than one worker is
   live, so a worker that grabbed too many on a cold start (when it briefly
   believed it was alone) gives the excess back and the pool converges to an
   even split. A lone worker never sheds — it must own every bucket.
4. Reconcile readers: open a kiroku consumer-group reader for each newly-owned
   bucket, stop the reader for each newly-lost bucket. A bucket that moves owners
   resumes at its own kiroku per-member checkpoint, so no event is dropped.

'runShardedSubscriptionGroup' is the loop driver: mint a 'WorkerId', ensure the
shard rows exist, then run 'reconcileShardsOnce' every @renewInterval@ forever.
On shutdown (the loop thread is killed, simulating a crash) a @finally@ stops
every reader this worker holds; its leases then expire and a surviving worker
re-claims its buckets (failover).

== Why @IO@, not @Eff@

Like 'Keiro.Workflow.Resume.runWorkflowResumeWorkerPush', this worker manages
long-lived 'Control.Concurrent' reader threads and takes the 'KirokuStore' handle
directly (each lease pass runs through 'Kiroku.Store.Effect.runStoreIO'), so its
natural home is 'IO'. The handler is an ordinary @'RecordedEvent' -> 'IO' ()@:
a sharded subscription delivers at-least-once (a brief overlap is possible while
a bucket changes owners), so the handler must be idempotent — keyed on
@eventId@ — exactly as keiro's async-projection guidance already requires.
-}
module Keiro.Subscription.Shard.Worker
  ( -- * Options
    ShardedWorkerOptions (..)
  , defaultShardedWorkerOptions

    -- * Running
  , reconcileShardsOnce
  , runShardedSubscriptionGroup
  )
where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (finally)
import Control.Monad (forever)
import Data.Int (Int32)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time (NominalDiffTime)
import Keiro.Prelude
import Data.UUID.V4 qualified as UUIDv4
import Keiro.Subscription.Shard
  ( ShardLease (..)
  , WorkerId (..)
  , acquireOwnedBuckets
  , ensureShards
  , fairShareTarget
  , ownershipSnapshot
  , relinquish
  )
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Subscription.Stream (subscriptionStream)
import Kiroku.Store.Subscription.Types
  ( ConsumerGroup (..)
  , SubscriptionName
  , SubscriptionResult (..)
  , SubscriptionTarget
  , defaultSubscriptionConfig
  )
import Kiroku.Store.Subscription.Types qualified as Sub
import Kiroku.Store.Types (RecordedEvent)
import Numeric.Natural (Natural)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

-- | How a sharded worker pool runs one subscription.
data ShardedWorkerOptions = ShardedWorkerOptions
  { shardCount :: !Int
  -- ^ @N@ buckets, fixed per subscription name (every worker must agree on @N@).
  , leaseTtl :: !NominalDiffTime
  -- ^ How long a claim/renew keeps a bucket before it expires (default 30 s).
  , renewInterval :: !NominalDiffTime
  -- ^ Gap between reconcile passes; well under 'leaseTtl' so a live worker renews
  --   several times per TTL (default 10 s ⇒ ~3 renews per 30 s TTL). A single
  --   missed renewal does not lose ownership; a dead worker loses every bucket
  --   within one TTL.
  , target :: !SubscriptionTarget
  -- ^ The category (or @AllStreams@) to shard.
  , batchSize :: !Int32
  -- ^ Events per database fetch per bucket reader (default 100).
  , bufferSize :: !Natural
  -- ^ Per-reader bounded-queue capacity (backpressure; default 256).
  }
  deriving stock (Generic)

-- | Sensible defaults for a sharded worker: 30 s lease, 10 s renew, batch 100,
-- buffer 256. Supply the category target and the bucket count @N@.
defaultShardedWorkerOptions :: SubscriptionTarget -> Int -> ShardedWorkerOptions
defaultShardedWorkerOptions target' shardCount' =
  ShardedWorkerOptions
    { shardCount = shardCount'
    , leaseTtl = 30
    , renewInterval = 10
    , target = target'
    , batchSize = 100
    , bufferSize = 256
    }

-- | A live per-bucket reader: the action that stops it (cancels the kiroku
-- subscription and kills the drain thread).
newtype RunningReader = RunningReader {stopReader :: IO ()}

{- | Run one ownership-reconcile pass and bring the set of running readers in
line with the buckets owned afterwards. Returns the buckets this worker owns
after the pass. The @readers@ ref maps each owned bucket to its live reader.

This is the testable unit: a single call claims/renews/sheds leases and
starts/stops readers once, with no loop of its own.
-}
reconcileShardsOnce ::
  KirokuStore ->
  ShardLease ->
  ShardedWorkerOptions ->
  IORef (Map Int RunningReader) ->
  (RecordedEvent -> IO ()) ->
  IO (Set Int)
reconcileShardsOnce store lease opts readers handler = do
  now <- getCurrentTime
  -- Estimate live workers: distinct owners with a non-expired lease, plus self.
  snap <- either (const []) id <$> runStoreIO store (ownershipSnapshot lease)
  let liveOwners = Set.fromList [w | (_, Just w, Just expiresAt) <- snap, expiresAt > now]
      liveWorkers = Set.size (Set.insert (lease ^. #workerId) liveOwners)
      shareTarget = fairShareTarget (lease ^. #shardCount) liveWorkers
  -- Renew held + claim up to fair share.
  claimed <- either (const Set.empty) id <$> runStoreIO store (acquireOwnedBuckets lease liveWorkers)
  -- Shed any excess above the fair share so a cold-start over-claim self-balances
  -- (never when alone: a lone worker must own everything).
  owned <-
    if liveWorkers > 1 && Set.size claimed > shareTarget
      then do
        let excess = Set.fromList (drop shareTarget (sort (Set.toList claimed)))
        _ <- runStoreIO store (relinquish lease excess)
        pure (claimed `Set.difference` excess)
      else pure claimed
  -- Bring readers in line with `owned`: start newly-owned, stop newly-lost.
  current <- readIORef readers
  let running = Map.keysSet current
      toStart = owned `Set.difference` running
      toStop = running `Set.difference` owned
  for_ (Set.toList toStop) $ \bucket ->
    for_ (Map.lookup bucket current) stopReader
  started <-
    traverse
      (\bucket -> (,) bucket <$> startReader store lease opts handler bucket)
      (Set.toList toStart)
  atomicModifyIORef' readers $ \m ->
    let afterStop = foldr Map.delete m (Set.toList toStop)
        afterStart = foldr (\(b, r) -> Map.insert b r) afterStop started
     in (afterStart, ())
  pure owned

-- | Open a kiroku consumer-group reader for one bucket and fork a thread that
-- drains it into the handler. The returned 'RunningReader' cancels the
-- subscription (which terminates the drain) and kills the thread.
startReader ::
  KirokuStore ->
  ShardLease ->
  ShardedWorkerOptions ->
  (RecordedEvent -> IO ()) ->
  Int ->
  IO RunningReader
startReader store lease opts handler bucket = do
  let subConfig =
        (defaultSubscriptionConfig (lease ^. #subscriptionName) (opts ^. #target) (\_ -> pure Continue))
          { Sub.batchSize = opts ^. #batchSize
          , Sub.consumerGroup =
              Just (ConsumerGroup{member = fromIntegral bucket, size = fromIntegral (opts ^. #shardCount)})
          }
  (stream, cancelAction) <- subscriptionStream store subConfig (opts ^. #bufferSize)
  tid <- forkIO (Stream.fold (Fold.drainMapM handler) stream)
  pure (RunningReader (cancelAction >> killThread tid))

{- | The loop driver: mint a 'WorkerId', ensure the @N@ shard rows exist, then
'reconcileShardsOnce' every @renewInterval@ forever. On shutdown (the loop thread
is killed) a @finally@ stops every reader this worker holds, so a crashed
worker's buckets stop being read immediately; its leases then expire and a
surviving worker re-claims them.
-}
runShardedSubscriptionGroup ::
  KirokuStore ->
  SubscriptionName ->
  ShardedWorkerOptions ->
  (RecordedEvent -> IO ()) ->
  IO ()
runShardedSubscriptionGroup store subName opts handler = do
  worker <- WorkerId <$> UUIDv4.nextRandom
  let lease =
        ShardLease
          { subscriptionName = subName
          , workerId = worker
          , shardCount = opts ^. #shardCount
          , leaseTtl = opts ^. #leaseTtl
          }
  _ <- runStoreIO store (ensureShards lease)
  readers <- newIORef Map.empty
  loop lease readers `finally` stopAll readers
 where
  delayMicros = max 1 (round (realToFrac (opts ^. #renewInterval) * 1e6 :: Double))
  loop lease readers =
    forever $ do
      _ <- reconcileShardsOnce store lease opts readers handler
      threadDelay delayMicros
  stopAll readers = do
    current <- readIORef readers
    for_ (Map.elems current) stopReader
