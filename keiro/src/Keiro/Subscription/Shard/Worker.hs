{- | The sharded category-subscription worker: a rebalance loop that turns
leased bucket ownership ("Keiro.Subscription.Shard") into running kiroku
consumer-group readers (EP-51).

Start the __same__ worker binary @N@ times — on @N@ hosts, in @N@ containers, in
an autoscaling group — each calling 'runShardedSubscriptionGroup' with the same
'SubscriptionName' and 'ShardedWorkerOptions', and the workers cooperatively
partition the category among themselves: every event is processed at least once
and none are skipped. A brief ownership overlap can deliver an event more than
once, so handlers must be idempotent. No external coordinator
(etcd/ZooKeeper/Consul) — coordination lives in the
@keiro_subscription_shards@ lease table.

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
   resumes at its own kiroku per-member checkpoint. Each event is acknowledged
   only after its handler returns, so a shed bucket's checkpoint never covers an
   unprocessed event and no event is dropped.

'runShardedSubscriptionGroup' is the loop driver: mint a 'WorkerId', ensure the
shard rows exist, then run 'reconcileShardsOnce' every @renewInterval@ forever.
On graceful shutdown (the loop thread is killed and can run cleanup) a @finally@
stops every reader this worker holds and relinquishes its leases so another
worker can claim immediately. A real process crash still recovers by lease
expiry.

== Why @IO@, not @Eff@

Like 'Keiro.Workflow.Resume.runWorkflowResumeWorkerPush', this worker manages
long-lived 'Control.Concurrent' reader threads and takes the 'KirokuStore' handle
directly (each lease pass runs through 'Kiroku.Store.Effect.runStoreIO'), so its
natural home is 'IO'. The compatibility handler is an ordinary
@'RecordedEvent' -> 'IO' ()@; 'runShardedSubscriptionGroupAck' exposes the
per-event 'ShardAck' surface for handlers that need an explicit retry or
dead-letter decision. A sharded subscription delivers at-least-once (a brief
overlap is possible while a bucket changes owners), so the handler must be
idempotent — keyed on @eventId@ — exactly as keiro's async-projection guidance
already requires.

A synchronous exception from either handler is retried in place according to
'retryPolicy', using 'handlerRetryDelay'. Exhausting the bounded delivery budget
records the event in kiroku's @kiroku.dead_letters@ table and advances to the next
event. 'ShardReaderDied' therefore reports stream-level failures, not ordinary
handler exceptions. An asynchronous exception from shedding or shutdown writes
no acknowledgement, so the event is redelivered by the next owner.

A zombie worker that misses renewals past @leaseTtl@ may continue reading briefly
after another worker claims its bucket, which can duplicate deliveries. It cannot
regress the consumer-group checkpoint: kiroku's checkpoint upsert is monotonic
(@GREATEST@), so a late acknowledgement from the laggard never moves progress
backward.
-}
module Keiro.Subscription.Shard.Worker (
    -- * Options
    ShardWorkerError (..),
    ShardedWorkerOptions (..),
    ShardedWorkerConfigError (..),
    defaultShardedWorkerOptions,
    mkShardedWorkerOptions,
    acquireOutcome,

    -- * Per-event acknowledgement
    ShardAck (..),
    ShardDelivery (..),
    ShardEventHandler,
    RetryDelay (..),
    DeadLetterReason (..),

    -- * Running
    reconcileShardsOnce,
    runShardedSubscriptionGroup,
    runShardedSubscriptionGroupAck,
)
where

import Control.Concurrent (forkFinally, killThread, threadDelay)
import Control.Concurrent.STM (atomically, putTMVar)
import Control.Exception (SomeAsyncException, SomeException, catch, displayException, finally, fromException, throwIO)
import Control.Monad (forever)
import Data.Bifunctor (first)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Data.UUID.V4 qualified as UUIDv4
import Keiro.Prelude
import Keiro.Subscription.Shard (
    ShardLease (..),
    WorkerId (..),
    acquireOwnedBuckets,
    ensureShards,
    fairShareTarget,
    ownershipSnapshot,
    relinquish,
 )
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Kiroku.Store.Subscription.Types (
    ConsumerGroup (..),
    DeadLetterReason (..),
    RetryDelay (..),
    RetryPolicy (..),
    SubscriptionName,
    SubscriptionResult (..),
    SubscriptionTarget,
    defaultRetryPolicy,
    defaultSubscriptionConfig,
 )
import Kiroku.Store.Subscription.Types qualified as Sub
import Kiroku.Store.Types (RecordedEvent)
import Numeric.Natural (Natural)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

data ShardWorkerError
    = ShardSnapshotFailed !Text
    | ShardAcquireFailed !Text
    | ShardReaderDied !Int !Text
    | ShardEnsureFailed !Text
    deriving stock (Generic, Eq, Show)

-- | Per-event disposition returned by an acknowledgement-aware shard handler.
data ShardAck
    = -- | Processing completed; the checkpoint may advance past this event.
      ShardAckOk
    | -- | Redeliver after the delay, bounded by 'retryPolicy'.
      ShardAckRetry !RetryDelay
    | -- | Record the event in kiroku's dead-letter table and advance immediately.
      ShardAckDeadLetter !DeadLetterReason
    deriving stock (Generic, Eq, Show)

-- | One delivery to an acknowledgement-aware shard handler.
data ShardDelivery = ShardDelivery
    { event :: !RecordedEvent
    -- ^ The delivered event.
    , attempt :: !Word
    -- ^ Zero-based redelivery count: 0 initially, 1 after the first retry, and so on.
    , bucket :: !Int
    -- ^ The consumer-group member owned by this reader.
    }
    deriving stock (Generic, Eq, Show)

type ShardEventHandler = ShardDelivery -> IO ShardAck

-- | How a sharded worker pool runs one subscription.
data ShardedWorkerOptions = ShardedWorkerOptions
    { shardCount :: !Int
    -- ^ @N@ buckets, fixed per subscription name (every worker must agree on @N@).
    , leaseTtl :: !NominalDiffTime
    -- ^ How long a claim/renew keeps a bucket before it expires (default 30 s).
    , renewInterval :: !NominalDiffTime
    {- ^ Gap between reconcile passes; well under 'leaseTtl' so a live worker renews
    several times per TTL (default 10 s ⇒ ~3 renews per 30 s TTL). A single
    missed renewal does not lose ownership; a dead worker loses every bucket
    within one TTL.
    -}
    , target :: !SubscriptionTarget
    -- ^ The category (or @AllStreams@) to shard.
    , batchSize :: !Int32
    -- ^ Events per database fetch per bucket reader (default 100).
    , bufferSize :: !Natural
    -- ^ Per-reader bridge queue capacity (default 256; one item is in flight).
    , handlerRetryDelay :: !RetryDelay
    -- ^ Delay before redelivering after a synchronous handler exception (default 1 s).
    , retryPolicy :: !RetryPolicy
    -- ^ Maximum total deliveries before retry exhaustion dead-letters the event.
    , onShardError :: !(Maybe (ShardWorkerError -> IO ()))
    -- ^ Optional error hook. Wire this to the application logger in production.
    }
    deriving stock (Generic)

data ShardedWorkerConfigError
    = InvalidShardCount !Int
    | InvalidShardLeaseTtl !NominalDiffTime
    | InvalidShardRenewInterval !NominalDiffTime
    | InvalidShardLeaseRenewInterval !NominalDiffTime !NominalDiffTime
    | InvalidShardBatchSize !Int32
    | InvalidShardBufferSize !Natural
    | InvalidShardHandlerRetryDelay !RetryDelay
    | InvalidShardRetryMaxAttempts !Int
    deriving stock (Generic, Eq, Show)

{- | Sensible defaults for a sharded worker: 30 s lease, 10 s renew, batch 100,
buffer 256. Supply the category target and the bucket count @N@.
-}
defaultShardedWorkerOptions :: SubscriptionTarget -> Int -> ShardedWorkerOptions
defaultShardedWorkerOptions target' shardCount' =
    ShardedWorkerOptions
        { shardCount = shardCount'
        , leaseTtl = 30
        , renewInterval = 10
        , target = target'
        , batchSize = 100
        , bufferSize = 256
        , handlerRetryDelay = RetryDelay 1
        , retryPolicy = defaultRetryPolicy
        , onShardError = Nothing
        }

-- | Validate sharded worker options before starting a worker pool member.
mkShardedWorkerOptions :: ShardedWorkerOptions -> Either ShardedWorkerConfigError ShardedWorkerOptions
mkShardedWorkerOptions opts
    | opts ^. #shardCount < 1 = Left (InvalidShardCount (opts ^. #shardCount))
    | opts ^. #leaseTtl <= 0 = Left (InvalidShardLeaseTtl (opts ^. #leaseTtl))
    | opts ^. #renewInterval <= 0 = Left (InvalidShardRenewInterval (opts ^. #renewInterval))
    | opts ^. #leaseTtl <= opts ^. #renewInterval =
        Left (InvalidShardLeaseRenewInterval (opts ^. #leaseTtl) (opts ^. #renewInterval))
    | opts ^. #batchSize < 1 = Left (InvalidShardBatchSize (opts ^. #batchSize))
    | opts ^. #bufferSize < 1 = Left (InvalidShardBufferSize (opts ^. #bufferSize))
    | RetryDelay delay <- opts ^. #handlerRetryDelay
    , delay < 0 =
        Left (InvalidShardHandlerRetryDelay (opts ^. #handlerRetryDelay))
    | RetryPolicy attempts <- opts ^. #retryPolicy
    , attempts < 1 =
        Left (InvalidShardRetryMaxAttempts attempts)
    | otherwise = Right opts

{- | A live per-bucket reader: the action that stops it (cancels the kiroku
subscription and kills the drain thread).
-}
newtype RunningReader = RunningReader {stopReader :: IO ()}

reportShardError :: ShardedWorkerOptions -> ShardWorkerError -> IO ()
reportShardError opts err =
    for_ (opts ^. #onShardError) ($ err)

acquireOutcome :: Set Int -> Either Text (Set Int) -> (Set Int, Maybe ShardWorkerError)
acquireOutcome previous = \case
    Right owned -> (owned, Nothing)
    Left err -> (previous, Just (ShardAcquireFailed err))

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
    ShardEventHandler ->
    IO (Set Int)
reconcileShardsOnce store lease opts readers handler = do
    now <- getCurrentTime
    current <- readIORef readers
    -- Estimate live workers: distinct owners with a non-expired lease, plus self.
    snapResult <- runStoreIO store (ownershipSnapshot lease)
    snap <- case snapResult of
        Right rows -> pure rows
        Left err -> do
            reportShardError opts (ShardSnapshotFailed (Text.pack (show err)))
            pure []
    let liveOwners = Set.fromList [w | (_, Just w, Just expiresAt) <- snap, expiresAt > now]
        liveWorkers = Set.size (Set.insert (lease ^. #workerId) liveOwners)
        shareTarget = fairShareTarget (lease ^. #shardCount) liveWorkers
    -- Renew held + claim up to fair share.
    claimedResult <- runStoreIO store (acquireOwnedBuckets lease liveWorkers)
    let previousOwned = Map.keysSet current
        (claimed, mAcquireError) = acquireOutcome previousOwned (first (Text.pack . show) claimedResult)
    for_ mAcquireError (reportShardError opts)
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
    let running = Map.keysSet current
        toStart = owned `Set.difference` running
        toStop = running `Set.difference` owned
    for_ (Set.toList toStop) $ \bucket ->
        for_ (Map.lookup bucket current) stopReader
    started <-
        traverse
            (\bucket -> (,) bucket <$> startReader store lease opts readers handler bucket)
            (Set.toList toStart)
    atomicModifyIORef' readers $ \m ->
        let afterStop = foldr Map.delete m (Set.toList toStop)
            afterStart = foldr (\(b, r) -> Map.insert b r) afterStop started
         in (afterStart, ())
    pure owned

{- | Open a kiroku consumer-group reader for one bucket and fork a thread that
drains it into the handler. The returned 'RunningReader' cancels the
subscription (which terminates the drain) and kills the thread.
-}
startReader ::
    KirokuStore ->
    ShardLease ->
    ShardedWorkerOptions ->
    IORef (Map Int RunningReader) ->
    ShardEventHandler ->
    Int ->
    IO RunningReader
startReader store lease opts readers handler bucket = do
    stopping <- newIORef False
    let subConfig =
            (defaultSubscriptionConfig (lease ^. #subscriptionName) (opts ^. #target) (\_ -> pure Continue))
                { Sub.batchSize = opts ^. #batchSize
                , Sub.consumerGroup =
                    Just (ConsumerGroup{member = fromIntegral bucket, size = fromIntegral (opts ^. #shardCount)})
                , Sub.retryPolicy = opts ^. #retryPolicy
                }
        handleItem item = do
            outcome <-
                handler
                    ShardDelivery
                        { event = ackEvent item
                        , attempt = ackAttempt item
                        , bucket = bucket
                        }
                    `catch` handlerException
            atomically (putTMVar (ackReply item) (toSubscriptionResult outcome))
        handlerException err =
            case fromException err of
                Just async -> throwIO (async :: SomeAsyncException)
                Nothing -> pure (ShardAckRetry (opts ^. #handlerRetryDelay))
    (stream, cancelAction) <- subscriptionAckStream store subConfig (opts ^. #bufferSize)
    tid <-
        forkFinally (Stream.fold (Fold.drainMapM handleItem) stream) $ \result -> do
            intentional <- readIORef stopping
            unless intentional $ do
                atomicModifyIORef' readers (\m -> (Map.delete bucket m, ()))
                let reason = case result of
                        Left err -> Text.pack (displayException (err :: SomeException))
                        Right _ -> "reader stream ended"
                reportShardError opts (ShardReaderDied bucket reason)
    pure
        ( RunningReader $ do
            writeIORef stopping True
            cancelAction
            killThread tid
        )

toSubscriptionResult :: ShardAck -> SubscriptionResult
toSubscriptionResult = \case
    ShardAckOk -> Continue
    ShardAckRetry delay -> Retry delay
    ShardAckDeadLetter reason -> DeadLetter reason

{- | The loop driver: mint a 'WorkerId', ensure the @N@ shard rows exist, then
'reconcileShardsOnce' every @renewInterval@ forever. On shutdown (the loop thread
is killed) a @finally@ stops every reader this worker holds, so a crashed
worker's buckets stop being read immediately; its leases then expire and a
surviving worker re-claims them.

The fixed @renewInterval@ between passes (the 'threadDelay' in 'loop') is the
__rebalance-signal seam__ (EP-51 Milestone 6). The shipped default is a pure poll:
correctness — disjointness and failover — rests entirely on the lease table and
does not depend on any notification. The EP-50 'Keiro.Wake' channel wakes on event
/appends/ (@kiroku.events@), which is a different event than a shard ownership
/change/; signalling a prompt rebalance on a worker join or a voluntary relinquish
would ride a dedicated @keiro_shard_rebalance@ @NOTIFY@ fired on claim/release, and
the swap is local to this one 'threadDelay' (replace it with a bounded wait on that
channel, exactly as 'Keiro.Workflow.Resume.runPollLoopWith' does for appends). Left
as the poll default here because it is a latency optimisation, not a correctness
requirement.
-}
runShardedSubscriptionGroup ::
    KirokuStore ->
    SubscriptionName ->
    ShardedWorkerOptions ->
    (RecordedEvent -> IO ()) ->
    IO ()
runShardedSubscriptionGroup store subName opts handler =
    runShardedSubscriptionGroupAck store subName opts $ \delivery -> do
        handler (delivery ^. #event)
        pure ShardAckOk

{- | Acknowledgement-aware loop driver. Unlike the compatibility wrapper, the
handler decides whether each event advances, retries, or dead-letters.
-}
runShardedSubscriptionGroupAck ::
    KirokuStore ->
    SubscriptionName ->
    ShardedWorkerOptions ->
    ShardEventHandler ->
    IO ()
runShardedSubscriptionGroupAck store subName opts handler = do
    worker <- WorkerId <$> UUIDv4.nextRandom
    let lease =
            ShardLease
                { subscriptionName = subName
                , workerId = worker
                , shardCount = opts ^. #shardCount
                , leaseTtl = opts ^. #leaseTtl
                }
    ensured <- runStoreIO store (ensureShards lease)
    case ensured of
        Right () -> pure ()
        Left err -> reportShardError opts (ShardEnsureFailed (Text.pack (show err)))
    readers <- newIORef Map.empty
    loop lease readers `finally` cleanup lease readers
  where
    delayMicros = max 1 (round (realToFrac (opts ^. #renewInterval) * 1e6 :: Double))
    loop lease readers =
        forever $ do
            _ <- reconcileShardsOnce store lease opts readers handler
            threadDelay delayMicros
    cleanup lease readers = do
        current <- readIORef readers
        for_ (Map.elems current) stopReader
        _ <- runStoreIO store (relinquish lease (Map.keysSet current))
        pure ()
