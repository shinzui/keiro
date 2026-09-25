{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Retention.Legs
  ( Leg (..),
    allLegs,
  )
where

import Control.Concurrent.STM (atomically, putTMVar)
import Control.Exception (evaluate, finally)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (toJSON)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Exception qualified as Effectful
import Keiro.Command (defaultRunCommandOptions)
import Keiro.ProcessManager (defaultWorkerOptions, runProcessManagerWorkerWith)
import Keiro.Projection (AsyncApplyOutcome (..), AsyncProjection (..), applyAsyncProjection)
import Keiro.ReadModel.Schema (registerReadModel)
import Keiro.Router (runRouterWorkerWith)
import Keiro.Test.Postgres (StoreRunner (..))
import Kiroku.Store qualified as Store
import Kiroku.Store.Subscription qualified as Subscription
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Kiroku.Store.Subscription.Types (SubscriptionConfig, SubscriptionName (..), SubscriptionResult (..), SubscriptionTarget (..), defaultSubscriptionConfig)
import Kiroku.Store.Types (CategoryName (..), EventData (..), EventId (..), EventType (..), ExpectedVersion (..), RecordedEvent, StreamName (..), StreamVersion (..))
import Retention.Fixture (appendSignals, decodeSignal, retentionManager, retentionRouter, sampleOnAck)
import Retention.Measure (GateConfig (..), HeapSample (..), Verdict (..), measureLeg, measureLegWithSampler, sampleHeap)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku (defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Streamly
import System.Timeout (timeout)

data Leg = Leg
  { legName :: !Text,
    run :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
  }

allLegs :: [Leg]
allLegs =
  [ Leg "baseline-no-store" baselineNoStore,
    Leg "kiroku-append-probe" kirokuAppendProbe,
    Leg "kiroku-subscribe-ack" kirokuSubscribeAck,
    Leg "shibuya-adapter-ack" shibuyaAdapterAck,
    Leg "pm-worker" pmWorker,
    Leg "router-worker" routerWorker,
    Leg "projection-apply" projectionApply
  ]

operationCount :: GateConfig -> Int
operationCount config = config.blocks * config.blockSize

baselineNoStore :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
baselineNoStore config _ =
  measureLeg config "baseline-no-store" \index ->
    void (evaluate (sum (replicate 100 (index `mod` 17))))

kirokuAppendProbe :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
kirokuAppendProbe config (_, StoreRunner runStore) =
  measureLeg config "kiroku-append-probe" \index -> do
    let streamName = StreamName ("retentionplain-" <> Text.pack (show (index `mod` 16)))
        eventId = EventId (UUID.fromWords 0 0 0 (fromIntegral index))
        event =
          EventData
            { eventId = Just eventId,
              eventType = EventType "RetentionPlain",
              payload = toJSON index,
              metadata = Nothing,
              causationId = Nothing,
              correlationId = Nothing
            }
    exists <-
      expectRight =<< runStore do
        _ <- Store.appendToStream streamName AnyVersion [event]
        Store.eventExistsInStream streamName eventId
    unless exists $ fail ("kiroku-append-probe: missing event " <> show index)

sourceTarget :: SubscriptionTarget
sourceTarget = Category (CategoryName "retentionsource")

sourceConfig :: Text -> SubscriptionConfig
sourceConfig name = defaultSubscriptionConfig (SubscriptionName name) sourceTarget (\_ -> pure Continue)

kirokuSubscribeAck :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
kirokuSubscribeAck config (store, runner) = do
  appendSignals runner (operationCount config)
  measured <- measureLegWithSampler config "kiroku-subscribe-ack" \sample -> do
    (source, cancel) <- subscriptionAckStream store (sourceConfig "retention-kiroku-ack") 256
    consumeAck (operationCount config) config.blockSize sample source `finally` cancel
  postReturn "kiroku-subscribe-ack" (operationCount config)
  pure measured

consumeAck :: Int -> Int -> (Int -> IO ()) -> Stream IO AckItem -> IO ()
consumeAck expected blockSize sample = go 1
  where
    go index source = do
      next <- timeout 30_000_000 (Streamly.uncons source)
      case next of
        Nothing -> fail ("kiroku-subscribe-ack: timed out after " <> show (index - 1) <> " events")
        Just Nothing -> fail ("kiroku-subscribe-ack: ended after " <> show (index - 1) <> " events")
        Just (Just (item, rest)) -> do
          atomically (putTMVar item.ackReply Continue)
          when (index `mod` blockSize == 0) (sample index)
          when (index < expected) (go (index + 1) rest)

shibuyaAdapterAck :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
shibuyaAdapterAck config (store, runner@(StoreRunner runStore)) = do
  appendSignals runner (operationCount config)
  measured <- measureLegWithSampler config "shibuya-adapter-ack" \sample -> do
    outcome <- runStore do
      adapter <- kirokuAdapter store (defaultKirokuAdapterConfig (SubscriptionName "retention-shibuya-ack") sourceTarget)
      consumeAdapter (operationCount config) config.blockSize sample adapter `Effectful.finally` adapter.shutdown
    void (expectRight outcome)
  postReturn "shibuya-adapter-ack" (operationCount config)
  pure measured

consumeAdapter :: (IOE :> es) => Int -> Int -> (Int -> IO ()) -> Adapter es RecordedEvent -> Eff es ()
consumeAdapter expected blockSize sample adapter = go 1 adapter.source
  where
    go index source = do
      next <- Streamly.uncons source
      case next of
        Nothing -> liftIO $ fail ("shibuya-adapter-ack: ended after " <> show (index - 1) <> " events")
        Just (item, rest) -> do
          item.ack.finalize AckOk
          when (index `mod` blockSize == 0) $ liftIO (sample index)
          when (index < expected) (go (index + 1) rest)

pmWorker :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
pmWorker config (store, runner@(StoreRunner runStore)) = do
  appendSignals runner (operationCount config)
  measured <- measureLegWithSampler config "pm-worker" \sample -> do
    outcome <- runStore do
      adapter <- kirokuAdapter store (defaultKirokuAdapterConfig (SubscriptionName "retention-pm") sourceTarget)
      instrumented <- sampleOnAck (operationCount config) config.blockSize sample adapter
      runProcessManagerWorkerWith defaultWorkerOptions defaultRunCommandOptions retentionManager instrumented decodeSignal
        `Effectful.finally` adapter.shutdown
    void (expectRight outcome)
  assertTargets runner (operationCount config) [0 .. 15] (\accountNumber -> length [index | index <- [1 .. operationCount config], index `mod` 16 == accountNumber])
  postReturn "pm-worker" (operationCount config)
  pure measured

routerWorker :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
routerWorker config (store, runner@(StoreRunner runStore)) = do
  appendSignals runner (operationCount config)
  measured <- measureLegWithSampler config "router-worker" \sample -> do
    outcome <- runStore do
      adapter <- kirokuAdapter store (defaultKirokuAdapterConfig (SubscriptionName "retention-router") sourceTarget)
      instrumented <- sampleOnAck (operationCount config) config.blockSize sample adapter
      runRouterWorkerWith defaultWorkerOptions defaultRunCommandOptions retentionRouter instrumented decodeSignal
        `Effectful.finally` adapter.shutdown
    void (expectRight outcome)
  assertTargets runner (operationCount config) [0 .. 3] (const (operationCount config))
  postReturn "router-worker" (operationCount config)
  pure measured

assertTargets :: StoreRunner -> Int -> [Int] -> (Int -> Int) -> IO ()
assertTargets (StoreRunner runStore) total accounts expectedFor =
  forM_ accounts \accountNumber -> do
    let name = StreamName ("retentiontarget-" <> Text.pack (show accountNumber))
    events <- expectRight =<< runStore (Store.readStreamForward name (StreamVersion 0) (fromIntegral (total + 1)))
    unless (Vector.length events == expectedFor accountNumber) $
      fail ("target " <> show name <> ": expected " <> show (expectedFor accountNumber) <> " events, got " <> show (Vector.length events))

projectionApply :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
projectionApply config (store, runner@(StoreRunner runStore)) = do
  void (expectRight =<< runStore (registerReadModel "retention-activity" 1 "retention-activity-v1"))
  appendSignals runner (operationCount config)
  measured <- measureLegWithSampler config "projection-apply" \sample -> do
    countRef <- newIORef 0
    let projection =
          AsyncProjection
            { name = "retention-activity",
              readModelName = "retention-activity",
              subscriptionName = "retention-projection",
              applyRecorded = \_ -> pure (),
              idempotencyKey = (.eventId)
            }
        handler event = do
          outcome <- expectRight =<< runStore (Store.runTransaction (applyAsyncProjection projection event))
          unless (outcome == AsyncApplied) $ fail ("projection-apply: " <> show outcome)
          count <- atomicModifyIORef' countRef (\previous -> let next = previous + 1 in (next, next))
          when (count `mod` config.blockSize == 0) (sample count)
          pure if count == operationCount config then Stop else Continue
        config' = defaultSubscriptionConfig (SubscriptionName "retention-projection") sourceTarget handler
    completed <- timeout 120_000_000 (Subscription.withSubscription store config' Subscription.wait)
    case completed of
      Nothing -> fail "projection-apply: subscription timed out"
      Just (Left failure) -> fail ("projection-apply: " <> show failure)
      Just (Right ()) -> pure ()
    count <- readIORef countRef
    unless (count == operationCount config) $ fail ("projection-apply: processed " <> show count <> " events")
  postReturn "projection-apply" (operationCount config)
  pure measured

postReturn :: Text -> Int -> IO ()
postReturn name count = do
  sample <- sampleHeap count
  Text.IO.putStrLn ("post-return leg=" <> name <> " live_bytes=" <> Text.pack (show sample.liveBytes) <> " large_objects_bytes=" <> Text.pack (show sample.largeObjectBytes))

expectRight :: (Show errorType) => Either errorType a -> IO a
expectRight = either (fail . show) pure
