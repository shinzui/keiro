-- | Shared, bounded inspection drivers. A mounted idle handle owns no wake
-- cursor and performs no recurring reads. Close the handle before its store.
module Keiro.Ops.Http.Feed
  ( FeedConfig (..),
    defaultFeedConfig,
    Driver,
    DriverFailure (..),
    Subscriber,
    newDriver,
    stopDriver,
    subscribe,
    unsubscribe,
    nextFrame,
    driverSnapshot,
    FeedAcquireError (..),
    FeedHandle,
    FeedStats (..),
    feedStats,
    newFeedHandle,
    closeFeedHandle,
    withFeedHandle,
    acquireDriver,
    releaseDriver,
    handleHttpConfig,
    handleFeedConfig,
    handleBudget,
    handleClosed,
    withFeedConnection,
    FeedSchemaCheck (..),
    checkFeedSchema,
  )
where

import Control.Concurrent.Async (Async, asyncWithUnmask, uninterruptibleCancel, wait)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket, finally, mask, onException, uninterruptibleMask_)
import Control.Monad (forever, when)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Word (Word64)
import Hasql.Pool qualified as Pool
import Keiro.Migrations.SchemaCheck (verifyExpectedSchemaSession)
import Keiro.Ops.Http.Budget
import Keiro.Ops.Http.Config
import Keiro.Ops.Http.Feed.Driver
import Keiro.Ops.Http.Protocol qualified as Protocol
import Keiro.Ops.Http.Views
import Keiro.Wake
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Effect (runStoreIO)

data FeedAcquireError = TooManyViews | InitialReadFailed !Text | FeedClosed | FeedBusy | FeedRetiring | InitialResultTooLarge
  deriving stock (Eq, Show)

data Entry = Entry {token :: !Int, driver :: !Driver, references :: !Int}

data Registry = Registry
  {entries :: !(Map.Map Text Entry), nextToken :: !Int, pump :: !(Maybe (Async ())), closing :: !(Maybe (Async ()))}

data FeedHandle = FeedHandle
  { handleHttpConfig :: !OpsHttpConfig,
    handleFeedConfig :: !FeedConfig,
    store :: !KirokuStore,
    handleBudget :: !InspectionBudget,
    registry :: !(MVar Registry),
    epoch :: !(TVar Word64),
    closed :: !(TVar Bool),
    connections :: !(TVar Int)
  }

data FeedStats = FeedStats {activeViews :: !Int, activeConnections :: !Int, wakePumpRunning :: !Bool}
  deriving stock (Eq, Show)

newFeedHandle :: OpsHttpConfig -> FeedConfig -> KirokuStore -> IO FeedHandle
newFeedHandle http config store = do
  let effective =
        config
          { maxItems = min 500 config.maxItems,
            maxFrameBytes = min config.maxFrameBytes http.inspectionLimits.maxResponseBytes,
            readTimeout = min config.readTimeout (fromIntegral http.inspectionLimits.readDeadlineSeconds)
          }
  validateFeedConfig effective
  budget <- newInspectionBudget http.inspectionLimits
  FeedHandle http effective store budget
    <$> newMVar (Registry Map.empty 0 Nothing Nothing)
    <*> newTVarIO 0
    <*> newTVarIO False
    <*> newTVarIO 0

withFeedHandle :: OpsHttpConfig -> FeedConfig -> KirokuStore -> (FeedHandle -> IO a) -> IO a
withFeedHandle http config store = bracket (newFeedHandle http config store) closeFeedHandle

handleClosed :: FeedHandle -> STM Bool
handleClosed handle = readTVar handle.closed

-- | Reserve upgrading sockets too, before any schema IO. All exits, including
-- failed accept/send and cancellation, return this connection slot.
withFeedConnection :: FeedHandle -> IO a -> IO (Maybe a)
withFeedConnection handle action = mask $ \restore -> do
  admitted <- atomically $ do
    closed <- handleClosed handle
    active <- readTVar handle.connections
    if closed || active >= handle.handleFeedConfig.maxConnections
      then pure False
      else writeTVar handle.connections (active + 1) >> pure True
  if not admitted
    then pure Nothing
    else
      Just <$> restore action `finally` atomically (modifyTVar' handle.connections (subtract 1))

data FeedSchemaCheck = FeedSchemaMatches | FeedSchemaDrift | FeedSchemaReadFailed
  deriving stock (Eq, Show)

-- Call inside the shared admission/deadline scope, both on upgrade and refresh.
checkFeedSchema :: FeedHandle -> IO FeedSchemaCheck
checkFeedSchema handle = do
  result <- Pool.use handle.store.pool verifyExpectedSchemaSession
  pure $ case result of
    Right (Right []) -> FeedSchemaMatches
    Right (Right _) -> FeedSchemaDrift
    _ -> FeedSchemaReadFailed

readView :: FeedHandle -> View -> IO (Either Text ReadResult)
readView handle view = do
  schema <- checkFeedSchema handle
  if schema == FeedSchemaReadFailed || (schema == FeedSchemaDrift && handle.handleHttpConfig.schemaDrift == RefuseOnDrift)
    then pure (Left "schema verification failed")
    else do
      result <- runStoreIO handle.store view.readItems
      pure (either (const (Left "inspection read failed")) Right result)

-- | One initialization task/result per canonical view. Entries retiring at zero
-- references keep their slot until cancellation has joined the driver.
acquireDriver :: FeedHandle -> View -> IO (Either FeedAcquireError Driver)
acquireDriver handle view = mask $ \restore -> do
  reserved <- modifyMVar handle.registry $ \state -> do
    closed <- readTVarIO handle.closed
    if closed
      then pure (state, Left FeedClosed)
      else case Map.lookup view.viewId state.entries of
        Just entry | entry.references == 0 -> pure (state, Left FeedRetiring)
        Just entry -> pure (state {entries = Map.insert view.viewId entry {references = entry.references + 1} state.entries}, Right entry.driver)
        Nothing | Map.size state.entries >= handle.handleFeedConfig.maxViews -> pure (state, Left TooManyViews)
        Nothing -> do
          pump <- case state.pump of
            Just pump -> pure pump
            Nothing -> startPump handle
          seen <- readTVarIO handle.epoch >>= newTVarIO
          driver <-
            startDriver
              view.feedName
              handle.handleFeedConfig
              handle.handleBudget
              handle.handleHttpConfig.inspectionLimits.readDeadlineSeconds
              (awaitEpoch handle seen)
              (readView handle view)
              `onException` (case state.pump of Nothing -> uninterruptibleCancel pump; Just _ -> pure ())
          let entry = Entry state.nextToken driver 1
          pure (state {entries = Map.insert view.viewId entry state.entries, nextToken = state.nextToken + 1, pump = Just pump}, Right driver)
  case reserved of
    Left problem -> pure (Left problem)
    Right driver -> do
      result <- restore (awaitDriver driver) `onException` releaseDriver handle view
      case result of
        Right () -> do
          closed <- atomically ((||) <$> handleClosed handle <*> driverClosed driver)
          if closed then releaseDriver handle view >> pure (Left FeedClosed) else pure (Right driver)
        Left (DriverFailure code message) -> do
          releaseDriver handle view
          pure
            ( Left
                ( case code of
                    Protocol.InspectionBusy -> FeedBusy
                    Protocol.InspectionResultTooLarge -> InitialResultTooLarge
                    _ -> InitialReadFailed message
                )
            )

releaseDriver :: FeedHandle -> View -> IO ()
releaseDriver handle view = uninterruptibleMask_ $ do
  retiring <- modifyMVar handle.registry $ \state -> case Map.lookup view.viewId state.entries of
    Nothing -> pure (state, Nothing)
    Just entry | entry.references <= 0 -> pure (state, Nothing)
    Just entry | entry.references > 1 -> pure (state {entries = Map.insert view.viewId entry {references = entry.references - 1} state.entries}, Nothing)
    Just entry -> pure (state {entries = Map.insert view.viewId entry {references = 0} state.entries}, Just entry)
  case retiring of
    Nothing -> pure ()
    Just entry -> do
      stopDriver entry.driver
      modifyMVar_ handle.registry $ \state -> case Map.lookup view.viewId state.entries of
        Just current | current.token == entry.token -> do
          let remaining = Map.delete view.viewId state.entries
          if Map.null remaining
            then do
              -- Join the old cursor owner before admitting a replacement pump.
              mapM_ uninterruptibleCancel state.pump
              pure state {entries = remaining, pump = Nothing}
            else pure state {entries = remaining}
        _ -> pure state

startPump :: FeedHandle -> IO (Async ())
startPump handle = do
  signal <- wakeSignalFromStore handle.store
  asyncWithUnmask $ \unmask -> unmask $ forever $ do
    reason <- waitForWake signal 1000000
    when (reason == WokenByNotify) (atomically (modifyTVar' handle.epoch (+ 1)))

awaitEpoch :: FeedHandle -> TVar Word64 -> IO WakeReason
awaitEpoch handle seen = do
  timer <- registerDelay (ceiling (handle.handleFeedConfig.fallbackInterval * 1000000))
  atomically $
    (do current <- readTVar handle.epoch; previous <- readTVar seen; check (current /= previous); writeTVar seen current; pure WokenByNotify)
      `orElse` (readTVar timer >>= check >> pure WokenByTimeout)

-- An owned closing job finishes even if a caller waiting on close is cancelled.
-- Later close calls join the same job; it is never restarted or abandoned.
closeFeedHandle :: FeedHandle -> IO ()
closeFeedHandle handle = mask $ \restore -> do
  closing <- uninterruptibleMask_ $ modifyMVar handle.registry $ \state -> case state.closing of
    Just task -> pure (state, task)
    Nothing -> do
      atomically (writeTVar handle.closed True)
      task <- asyncWithUnmask $ \unmask -> unmask $ do
        mapM_ (stopDriver . (.driver)) (Map.elems state.entries)
        mapM_ uninterruptibleCancel state.pump
        atomically (readTVar handle.connections >>= check . (== 0))
      pure (state {entries = Map.empty, pump = Nothing, closing = Just task}, task)
  restore (wait closing)

feedStats :: FeedHandle -> IO FeedStats
feedStats handle = do
  state <- readMVar handle.registry
  active <- readTVarIO handle.connections
  pure (FeedStats (Map.size state.entries) active (maybe False (const True) state.pump))
