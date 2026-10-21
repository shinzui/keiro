module Test.FeedSpec (spec) where

import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket, finally)
import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Word (Word64)
import Effectful (liftIO)
import Keiro.Ops.Http.Config
import Keiro.Ops.Http.Feed qualified as Feed
import Keiro.Ops.Http.Protocol qualified as P
import Keiro.Ops.Http.Views
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Keiro.Wake (WakeReason (..), neverWake, waitForWake)
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

quick :: Feed.FeedConfig
quick = Feed.defaultFeedConfig {Feed.fallbackInterval = 0.02, Feed.minRefreshInterval = 0.001, Feed.readTimeout = 2}

item :: Int -> Item
item value = Item "one" (object ["id" .= ("one" :: Text)]) (object ["value" .= value])

snapshotSequence :: P.ServerFrame -> Maybe Word64
snapshotSequence = \case P.Snapshot _ sequence _ _ _ _ -> Just sequence; _ -> Nothing

receive :: Feed.Subscriber -> IO P.ServerFrame
receive subscriber = timeout 2000000 (atomically (Feed.nextFrame subscriber)) >>= maybe (fail "feed frame deadline exceeded") pure
