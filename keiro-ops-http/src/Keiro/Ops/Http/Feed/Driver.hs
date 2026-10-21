-- | One read loop per canonical view. Only the registry creates production
-- drivers; the injected constructor keeps fallback/diff checks small.
module Keiro.Ops.Http.Feed.Driver
  ( FeedConfig (..),
    defaultFeedConfig,
    validateFeedConfig,
    Driver,
    Subscriber,
    DriverFailure (..),
    ReadResult,
    newDriver,
    startDriver,
    awaitDriver,
    stopDriver,
    subscribe,
    unsubscribe,
    nextFrame,
    subscribeOnQueue,
    unsubscribeSTM,
    driverClosed,
    driverSnapshot,
    enqueueSnapshot,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, asyncWithUnmask, uninterruptibleCancel)
import Control.Concurrent.STM
import Control.Exception (Exception, SomeAsyncException, SomeException, finally, fromException, mask, onException, throwIO, try)
import Control.Monad (forM_, unless, void)
import Data.Aeson (Value)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import Keiro.Ops.Http.Budget qualified as Budget
import Keiro.Ops.Http.Config (InspectionLimits (..), defaultInspectionLimits)
import Keiro.Ops.Http.Feed.Queue qualified as Queue
import Keiro.Ops.Http.Protocol qualified as P
import Keiro.Ops.Http.Views
import Keiro.Wake (WakeReason (..))
import System.Timeout (timeout)

data FeedConfig = FeedConfig
  { fallbackInterval :: !NominalDiffTime,
    minRefreshInterval :: !NominalDiffTime,
    maxViews :: !Int,
    maxFrameBytes :: !Int,
    maxQueuedBytes :: !Int,
    readTimeout :: !NominalDiffTime,
    queueCapacity :: !Int,
    idlePingSeconds :: !Int,
    maxConnections :: !Int,
    maxItems :: !Int
  }
  deriving stock (Eq, Show, Generic)

defaultFeedConfig :: FeedConfig
defaultFeedConfig = FeedConfig 1 1 32 1048576 2097152 5 256 30 256 500

validateFeedConfig :: FeedConfig -> IO ()
validateFeedConfig config = unless valid (ioError (userError "feed limits must be positive, representable, and hold control frames (256 bytes)"))
  where
    periods = [config.fallbackInterval, config.minRefreshInterval, config.readTimeout, fromIntegral config.idlePingSeconds]
    valid =
      all (> 0) [config.maxViews, config.queueCapacity, config.maxConnections, config.maxItems]
        && config.maxFrameBytes >= 256
        && config.maxQueuedBytes >= 256
        && all (\period -> period > 0 && ceiling (period * 1000000) <= toInteger (maxBound :: Int)) periods

type ReadResult = (UTCTime, [Item], Maybe Value)

data DriverFailure = DriverFailure !P.SocketErrorCode !Text
  deriving stock (Eq, Show)

instance Exception DriverFailure

data DriverState = DriverState
  { currentSequence :: !Word64,
    rows :: ![Item],
    extra :: !(Maybe Value),
    snapshot :: !(Maybe Queue.Outgoing),
    subscribers :: !(Map.Map Int Queue.OutboundQueue),
    nextId :: !Int,
    closed :: !Bool,
    lastError :: !(Maybe P.SocketErrorCode)
  }

data Driver = Driver
  { name :: !P.FeedName,
    config :: !FeedConfig,
    state :: !(TVar DriverState),
    ready :: !(TMVar (Either DriverFailure ())),
    worker :: !(Async ())
  }

data Subscriber = Subscriber !Int !Queue.OutboundQueue

-- | Production supplies the shared mount budget. The worker, including its
-- initial read, is owned before any caller waits; cancelled waiters cannot
-- strand an initialization task or lose another waiter's shared result.
startDriver :: P.FeedName -> FeedConfig -> Budget.InspectionBudget -> Int -> IO WakeReason -> IO (Either Text ReadResult) -> IO Driver
startDriver name config budget hostDeadline awaitChange readItems = mask $ \_ -> do
  validateFeedConfig config
  state <- newTVarIO (DriverState 0 [] Nothing Nothing Map.empty 0 False Nothing)
  ready <- newEmptyTMVarIO
  worker <- asyncWithUnmask $ \unmask ->
    unmask (run state ready)
      `finally` atomically
        ( do
            modifyTVar' state (\value -> value {closed = True, rows = [], extra = Nothing, snapshot = Nothing, subscribers = Map.empty})
            void (tryPutTMVar ready (Left (DriverFailure P.ReadFailed "feed driver closed")))
        )
  pure (Driver name config state ready worker)
  where
    maximumBytes = min config.maxFrameBytes config.maxQueuedBytes
    deadline = ceiling (min config.readTimeout (fromIntegral hostDeadline) * 1000000)
    cadence = if name == P.Timers then max 5 config.minRefreshInterval else config.minRefreshInterval
    run state ready = do
      firstStart <- getMonotonicTimeNSec
      initial <- bounded (refresh state P.Subscribed)
      atomically (void (tryPutTMVar ready (fmap (const ()) initial)))
      case initial of Left _ -> pure (); Right _ -> loop state firstStart
    loop state previousStart = do
      active <- atomically $ do
        value <- readTVar state
        check (value.closed || not (Map.null value.subscribers))
        pure (not value.closed)
      if not active
        then pure ()
        else do
          reason <- awaitChange
          now <- getMonotonicTimeNSec
          let elapsed = toInteger (now - previousStart) `div` 1000
              remaining = ceiling (cadence * 1000000) - elapsed
          if remaining > 0 then threadDelay (fromInteger remaining) else pure ()
          value <- readTVarIO state
          if value.closed
            then pure ()
            else
              if Map.null value.subscribers
                then loop state previousStart
                else do
                  started <- getMonotonicTimeNSec
                  result <- bounded (refresh state (case reason of WokenByNotify -> P.Notify; WokenByTimeout -> P.Timeout))
                  case result of Left problem -> publishError state problem; Right _ -> pure ()
                  loop state started
    bounded action = do
      admitted <- Budget.withInspectionAdmission budget (trySync (timeout deadline action))
      pure $ case admitted of
        Left _ -> Left (DriverFailure P.InspectionBusy "inspection read capacity is busy")
        Right (Left problem) -> Left problem
        Right (Right Nothing) -> Left (DriverFailure P.ReadFailed "inspection read deadline exceeded")
        Right (Right (Just value)) -> Right value
    refresh state trigger = do
      result <- readItems
      (stamp, items, extra) <- either (const (throwIO (DriverFailure P.ReadFailed "inspection read failed"))) pure result
      previous <- readTVarIO state
      let old = Map.fromList [(item.key, item) | item <- previous.rows]
          current = Map.fromList [(item.key, item) | item <- items]
          changed = [item.body | item <- items, maybe True ((/= stableItemBody name item) . stableItemBody name) (Map.lookup item.key old)]
          removed = [item.keyJson | item <- previous.rows, Map.notMember item.key current]
          different = not (null changed && null removed) || extra /= previous.extra
          sequence = previous.currentSequence + if trigger /= P.Subscribed && different then 1 else 0
      snapshot <- prepare (P.Snapshot name sequence P.Subscribed stamp (map (.body) items) extra)
      update <-
        if trigger /= P.Subscribed && different
          then Just <$> prepare (P.Update name sequence trigger stamp changed removed extra)
          else pure Nothing
      atomically $ do
        value <- readTVar state
        unless value.closed $ do
          writeTVar state value {currentSequence = sequence, rows = items, extra = extra, snapshot = Just snapshot, lastError = Nothing}
          forM_ update $ \frame -> forM_ (Map.elems value.subscribers) (\queue -> void (Queue.enqueueOutgoing queue frame))
    prepare frame =
      Queue.prepareOutgoing maximumBytes frame
        >>= maybe
          (throwIO (DriverFailure P.InspectionResultTooLarge "inspection frame exceeds the host byte limit"))
          pure
    publishError state (DriverFailure code message) = do
      frame <- Queue.prepareOutgoing maximumBytes (P.ErrorFrame code message (Just name))
      atomically $ do
        value <- readTVar state
        unless (value.closed || value.lastError == Just code) $ do
          writeTVar state value {lastError = Just code}
          forM_ frame $ \outgoing -> forM_ (Map.elems value.subscribers) (\queue -> void (Queue.enqueueOutgoing queue outgoing))

trySync :: IO a -> IO (Either DriverFailure a)
trySync action =
  try action >>= \case
    Right value -> pure (Right value)
    Left (err :: SomeException) -> case fromException err :: Maybe SomeAsyncException of
      Just _ -> throwIO err
      Nothing -> pure (Left (maybe (DriverFailure P.ReadFailed "inspection read failed") id (fromException err)))

newDriver :: P.FeedName -> FeedConfig -> IO WakeReason -> IO (Either Text ReadResult) -> IO Driver
newDriver name config awaitChange readItems = mask $ \restore -> do
  budget <- Budget.newInspectionBudget defaultInspectionLimits {maxConcurrentReads = 1}
  driver <- startDriver name config budget (max 1 (ceiling config.readTimeout)) awaitChange readItems
  outcome <- restore (awaitDriver driver) `onException` stopDriver driver
  case outcome of Left problem -> stopDriver driver >> throwIO problem; Right () -> pure driver

awaitDriver :: Driver -> IO (Either DriverFailure ())
awaitDriver driver = atomically (readTMVar driver.ready)

driverClosed :: Driver -> STM Bool
driverClosed driver = (.closed) <$> readTVar driver.state

stopDriver :: Driver -> IO ()
stopDriver driver = mask $ \_ -> do
  atomically $ modifyTVar' driver.state (\value -> value {closed = True, rows = [], extra = Nothing, snapshot = Nothing, subscribers = Map.empty})
  uninterruptibleCancel driver.worker

subscribe :: Driver -> IO Subscriber
subscribe driver = do
  queue <- Queue.newOutboundQueue driver.config.queueCapacity driver.config.maxQueuedBytes driver.config.maxFrameBytes
  atomically (subscribeOnQueue driver queue)

subscribeOnQueue :: Driver -> Queue.OutboundQueue -> STM Subscriber
subscribeOnQueue driver queue = do
  value <- readTVar driver.state
  if value.closed || Map.size value.subscribers >= driver.config.maxConnections
    then throwSTM (DriverFailure P.ReadFailed "driver is closed or subscriber capacity is full")
    else case value.snapshot of
      Nothing -> throwSTM (DriverFailure P.ReadFailed "driver initialization is incomplete")
      Just snapshot -> do
        let identifier = value.nextId
        writeTVar driver.state value {subscribers = Map.insert identifier queue value.subscribers, nextId = identifier + 1}
        void (Queue.enqueueOutgoing queue snapshot)
        pure (Subscriber identifier queue)

unsubscribeSTM :: Driver -> Subscriber -> STM ()
unsubscribeSTM driver (Subscriber identifier queue) = do
  modifyTVar' driver.state (\value -> value {subscribers = Map.delete identifier value.subscribers})
  Queue.purgeFeed queue driver.name

unsubscribe :: Driver -> Subscriber -> IO ()
unsubscribe driver subscriber = atomically (unsubscribeSTM driver subscriber)

nextFrame :: Subscriber -> STM P.ServerFrame
nextFrame (Subscriber _ queue) = Queue.nextFrame queue

-- | The last successful observation, used for resubscription without a read.
driverSnapshot :: Driver -> STM P.ServerFrame
driverSnapshot driver = do
  value <- readTVar driver.state
  case value.snapshot of
    Just outgoing | not value.closed -> pure outgoing.frame
    _ -> throwSTM (DriverFailure P.ReadFailed "driver has no current snapshot")

enqueueSnapshot :: Driver -> Queue.OutboundQueue -> STM ()
enqueueSnapshot driver queue = do
  value <- readTVar driver.state
  case value.snapshot of
    Just outgoing | not value.closed -> void (Queue.enqueueOutgoing queue outgoing)
    _ -> throwSTM (DriverFailure P.ReadFailed "driver has no current snapshot")
