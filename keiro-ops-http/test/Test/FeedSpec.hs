module Test.FeedSpec (spec) where

import Control.Concurrent.Async (async, cancel, wait)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket, finally)
import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.Word (Word64)
import Effectful (liftIO)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Keiro.Ops.Http.Config
import Keiro.Ops.Http.Feed qualified as Feed
import Keiro.Ops.Http.Protocol qualified as P
import Keiro.Ops.Http.Views
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Keiro.Wake (WakeReason (..), neverWake, waitForWake)
import Kiroku.Store.Connection (KirokuStore (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = do
  describe "shared feed driver" $ do
    it "diffs fallback truth, extra-only changes, and recovery without duplicate reads per subscriber" $ do
      let removedItem = Item "two" (object ["id" .= ("two" :: Text)]) (body (item 2))
      source <- newIORef (Right ([item 1, removedItem], Nothing))
      let readItems = do
            value <- readIORef source
            stamp <- getCurrentTime
            pure (fmap (\(rows, extra) -> (stamp, rows, extra)) value)
      bracket (Feed.newDriver P.Workflows quick (waitForWake neverWake 20000) readItems) Feed.stopDriver $ \driver -> do
        one <- Feed.subscribe driver
        two <- Feed.subscribe driver
        first <- receive one
        receive two `shouldReturn` first
        snapshotSequence first `shouldBe` Just 0
        writeIORef source (Right ([item 3], Nothing))
        changed <- receive one
        receive two `shouldReturn` changed
        case changed of
          P.Update P.Workflows 1 P.Timeout _ rows removed _ -> do
            rows `shouldBe` [body (item 3)]
            removed `shouldBe` [keyJson removedItem]
          _ -> expectationFailure (show changed)
        timeout 100000 (atomically (Feed.nextFrame one)) `shouldReturn` Nothing
        writeIORef source (Left "read unavailable")
        forM_ [one, two] $ \subscriber ->
          receive subscriber >>= \case
            P.ErrorFrame P.ReadFailed _ _ -> pure ()
            frame -> expectationFailure (show frame)
        writeIORef source (Right ([item 3], Just (object ["visible_store_head" .= (9 :: Int)])))
        recovered <- receive one
        receive two `shouldReturn` recovered
        case recovered of
          P.Update P.Workflows 2 _ _ rows removed _ -> (rows, removed) `shouldBe` ([], [])
          _ -> expectationFailure (show recovered)
    it "signals overflow before retained deltas and resubscribes from the current sequence" $ do
      source <- newIORef [item 1]
      calls <- newIORef (0 :: Int)
      wake <- newEmptyMVar
      let readItems = do
            modifyIORef' calls (+ 1)
            rows <- readIORef source
            stamp <- getCurrentTime
            pure (Right (stamp, rows, Nothing))
      bracket (Feed.newDriver P.Workflows quick {Feed.queueCapacity = 2} (takeMVar wake >> pure WokenByNotify) readItems) Feed.stopDriver $ \driver -> do
        subscriber <- Feed.subscribe driver
        _ <- receive subscriber
        forM_ [1 .. 5] $ \sequence -> do
          writeIORef source [item (fromIntegral sequence + 1)]
          putMVar wake ()
          reached <- timeout 1000000 $ atomically $ do
            frame <- Feed.driverSnapshot driver
            check (snapshotSequence frame == Just sequence)
          reached `shouldBe` Just ()
        receive subscriber >>= \case
          P.ErrorFrame P.QueueOverflow _ _ -> pure ()
          frame -> expectationFailure (show frame)
        -- The overflow control frame also consumes the strict queue budget;
        -- retaining it can evict one more old delta. Recovery uses a snapshot.
        receive subscriber >>= \case
          P.Update P.Workflows 5 _ _ rows _ _ -> rows `shouldBe` [body (item 6)]
          frame -> expectationFailure (show frame)
        recovered <- Feed.subscribe driver >>= receive
        snapshotSequence recovered `shouldBe` Just 5
        readIORef calls `shouldReturn` 6
    it "retains fresh timer presentation without broadcasting a clock-only delta" $ do
      firstStamp <- getCurrentTime
      let secondStamp = addUTCTime 1 firstStamp
          timer countdown = Item "timer" (object ["timer_id" .= ("timer" :: Text)]) (object ["status" .= ("scheduled" :: Text), "due_in_seconds" .= (countdown :: Int)])
      source <- newIORef (firstStamp, [timer 10])
      wake <- newEmptyMVar
      let readItems = do
            (stamp, rows) <- readIORef source
            pure (Right (stamp, rows, Nothing))
      bracket (Feed.newDriver P.Timers quick (takeMVar wake >> pure WokenByNotify) readItems) Feed.stopDriver $ \driver -> do
        one <- Feed.subscribe driver
        _ <- receive one
        writeIORef source (secondStamp, [timer 9])
        putMVar wake ()
        refreshed <- timeout 7000000 $ atomically $ do
          frame <- Feed.driverSnapshot driver
          case frame of
            P.Snapshot _ 0 _ stamp rows _ -> check (stamp == secondStamp && rows == [body (timer 9)])
            _ -> retry
        refreshed `shouldBe` Just ()
        timeout 100000 (atomically (Feed.nextFrame one)) `shouldReturn` Nothing
        fresh <- Feed.subscribe driver >>= receive
        case fresh of
          P.Snapshot P.Timers 0 _ stamp rows _ -> (stamp, rows) `shouldBe` (secondStamp, [body (timer 9)])
          _ -> expectationFailure (show fresh)
  describe "feed registry" $ around (withFreshStore fixture) $ do
    it "reserves initialization, joins cancellation, shares a ready view, and drops the idle wake cursor" $ \store ->
      Feed.withFeedHandle defaultOpsHttpConfig quick {Feed.maxViews = 1, Feed.maxFrameBytes = 512} store $ \handle -> do
        Feed.feedStats handle `shouldReturn` Feed.FeedStats 0 0 False
        entered <- newEmptyMVar
        gate <- newEmptyMVar
        cleaned <- newEmptyMVar
        let blocked = View "blocked" P.Workflows (liftIO ((putMVar entered () >> takeMVar gate) `finally` putMVar cleaned ()))
            other = View "other" P.Workflows (liftIO (getCurrentTime >>= \stamp -> pure (stamp, [], Nothing)))
        request <- async (Feed.acquireDriver handle blocked)
        timeout 1000000 (takeMVar entered) `shouldReturn` Just ()
        refused <- Feed.acquireDriver handle other
        either (== Feed.TooManyViews) (const False) refused `shouldBe` True
        cancel request
        tryTakeMVar cleaned `shouldReturn` Just ()
        Feed.feedStats handle `shouldReturn` Feed.FeedStats 0 0 False
        let large = View "large" P.Workflows $ liftIO $ do
              stamp <- getCurrentTime
              pure (stamp, [Item "large" (object []) (object ["text" .= Text.replicate 1000 "x"])], Nothing)
        oversized <- Feed.acquireDriver handle large
        either (== Feed.InitialResultTooLarge) (const False) oversized `shouldBe` True
        Feed.feedStats handle `shouldReturn` Feed.FeedStats 0 0 False
        calls <- newIORef (0 :: Int)
        let shared = View "shared" P.Workflows $ liftIO $ do
              modifyIORef' calls (+ 1)
              stamp <- getCurrentTime
              pure (stamp, [item 1], Nothing)
        Right first <- Feed.acquireDriver handle shared
        Right second <- Feed.acquireDriver handle shared
        readIORef calls `shouldReturn` 1
        atomically (Feed.driverSnapshot first) >>= \frame -> atomically (Feed.driverSnapshot second) `shouldReturn` frame
        Feed.releaseDriver handle shared
        Feed.feedStats handle `shouldReturn` Feed.FeedStats 1 0 True
        Feed.releaseDriver handle shared
        Feed.feedStats handle `shouldReturn` Feed.FeedStats 0 0 False
        Feed.closeFeedHandle handle
        Feed.closeFeedHandle handle
    it "refuses a retiring view distinctly until blocked cleanup has joined" $ \store ->
      Feed.withFeedHandle defaultOpsHttpConfig quick {Feed.maxViews = 1} store $ \handle -> do
        block <- newIORef False
        entered <- newEmptyMVar
        cleanupEntered <- newEmptyMVar
        cleanupGate <- newEmptyMVar
        never <- newEmptyMVar
        let view = View "retiring" P.Workflows $ liftIO $ do
              shouldBlock <- readIORef block
              if shouldBlock
                then (putMVar entered () >> takeMVar never) `finally` (putMVar cleanupEntered () >> takeMVar cleanupGate)
                else pure ()
              stamp <- getCurrentTime
              pure (stamp, [item 1], Nothing)
        Right driver <- Feed.acquireDriver handle view
        _ <- Feed.subscribe driver >>= receive
        writeIORef block True
        timeout 2000000 (takeMVar entered) `shouldReturn` Just ()
        release <- async (Feed.releaseDriver handle view)
        ( do
            timeout 1000000 (takeMVar cleanupEntered) `shouldReturn` Just ()
            refused <- Feed.acquireDriver handle view
            either (== Feed.FeedRetiring) (const False) refused `shouldBe` True
            Feed.feedStats handle `shouldReturn` Feed.FeedStats 1 0 True
            writeIORef block False
          )
          `finally` (tryPutMVar cleanupGate () >> pure ())
        timeout 1000000 (wait release) `shouldReturn` Just ()
        Feed.feedStats handle `shouldReturn` Feed.FeedStats 0 0 False
        Right _ <- Feed.acquireDriver handle view
        Feed.releaseDriver handle view
    it "rechecks schema for each active view and recovers only after drift is removed" $ \store ->
      Feed.withFeedHandle defaultOpsHttpConfig quick store $ \handle -> do
        firstCalls <- newTVarIO (0 :: Int)
        secondCalls <- newTVarIO (0 :: Int)
        let view name calls = View name P.Workflows $ liftIO $ do
              atomically (modifyTVar' calls (+ 1))
              stamp <- getCurrentTime
              pure (stamp, [item 1], Nothing)
            firstView = view "schema-first" firstCalls
            secondView = view "schema-second" secondCalls
            sql text = Pool.use store.pool (Session.script text) >>= either (fail . show) pure
        Right first <- Feed.acquireDriver handle firstView
        one <- Feed.subscribe first
        _ <- receive one
        Right second <- Feed.acquireDriver handle secondView
        two <- Feed.subscribe second
        _ <- receive two
        sql "ALTER TABLE keiro.keiro_workflows ADD COLUMN feed_drift bigint"
        forM_ [one, two] $ \subscriber ->
          receive subscriber >>= \case
            P.ErrorFrame P.ReadFailed _ _ -> pure ()
            frame -> expectationFailure (show frame)
        before <- atomically ((,) <$> readTVar firstCalls <*> readTVar secondCalls)
        sql "ALTER TABLE keiro.keiro_workflows DROP COLUMN feed_drift"
        recovered <- timeout 2000000 $ atomically $ do
          after <- (,) <$> readTVar firstCalls <*> readTVar secondCalls
          check (fst after > fst before && snd after > snd before)
        recovered `shouldBe` Just ()
        forM_ [first, second] $ \driver -> Feed.subscribe driver >>= receive >>= \frame -> snapshotSequence frame `shouldBe` Just 0
        Feed.releaseDriver handle firstView
        Feed.releaseDriver handle secondView

quick :: Feed.FeedConfig
quick = Feed.defaultFeedConfig {Feed.fallbackInterval = 0.02, Feed.minRefreshInterval = 0.001, Feed.readTimeout = 2}

item :: Int -> Item
item value = Item "one" (object ["id" .= ("one" :: Text)]) (object ["value" .= value])

snapshotSequence :: P.ServerFrame -> Maybe Word64
snapshotSequence = \case P.Snapshot _ sequence _ _ _ _ -> Just sequence; _ -> Nothing

receive :: Feed.Subscriber -> IO P.ServerFrame
receive subscriber = timeout 2000000 (atomically (Feed.nextFrame subscriber)) >>= maybe (fail "feed frame deadline exceeded") pure
