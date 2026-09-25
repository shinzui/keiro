{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Retention.Legs
  ( Leg (..),
    allLegs,
  )
where

import Control.Concurrent (threadDelay)
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
import Keiro.Command qualified as Command
import Keiro.EventStream.Validate (unvalidated)
import Keiro.ProcessManager (defaultWorkerOptions, runProcessManagerWorkerWith)
import Keiro.Projection (AsyncApplyOutcome (..), AsyncProjection (..), applyAsyncProjection)
import Keiro.ReadModel.Schema (registerReadModel)
import Keiro.Router (runRouterWorkerWith)
import Keiro.Snapshot.Schema (SnapshotRow (..), lookupSnapshotRow)
import Keiro.Stream qualified as KeiroStream
import Keiro.Test.Postgres (StoreRunner (..))
import Kiroku.Store qualified as Store
import Kiroku.Store.Subscription qualified as Subscription
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Kiroku.Store.Subscription.Types (SubscriptionConfig, SubscriptionName (..), SubscriptionResult (..), SubscriptionTarget (..), defaultSubscriptionConfig)
import Kiroku.Store.Transaction qualified as StoreTx
import Kiroku.Store.Types (CategoryName (..), EventData (..), EventId (..), EventType (..), ExpectedVersion (..), RecordedEvent, StreamName (..), StreamVersion (..))
import Retention.Fixture (LedgerCommand (..), TargetCommand (..), TargetEventStream, ackAdapter, appendSignals, decodeSignal, ledgerTarget, retentionLedger, retentionManager, retentionRouter, retentionTargetStream, sampleOnAck, seedLedger, seedLedgerRaw)
import Retention.Measure (GateConfig (..), HeapSample (..), Verdict (..), measureLeg, measureLegWithSampler, sampleHeap)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku (defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Streamly
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data Leg = Leg
  { legName :: !Text,
    run :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
  }

allLegs :: [Leg]
allLegs =
  [ Leg "baseline-no-store" baselineNoStore,
    Leg "kiroku-append-probe" kirokuAppendProbe,
    Leg "kiroku-append-only" kirokuAppendOnly,
    Leg "kiroku-append-tx" kirokuAppendTx,
    Leg "kiroku-probe-only" kirokuProbeOnly,
    Leg "kiroku-subscribe-ack" kirokuSubscribeAck,
    Leg "hand-bridge-ack" handBridgeAck,
    Leg "shibuya-adapter-ack" shibuyaAdapterAck,
    Leg "pm-worker" pmWorker,
    Leg "router-worker" routerWorker,
    Leg "projection-apply" projectionApply,
    Leg "command-long-history" commandLongHistory,
    Leg "hydrate-only" hydrateOnly,
    Leg "kiroku-read-tail" kirokuReadTail,
    Leg "command-short-history" commandShortHistory,
    Leg "command-long-history-verify-every" commandLongHistoryVerifyEvery
  ]

operationCount :: GateConfig -> Int
operationCount config = config.blocks * config.blockSize

commandLongHistory :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
commandLongHistory = commandLongHistoryWithRate "command-long-history" 0

commandLongHistoryVerifyEvery :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
commandLongHistoryVerifyEvery = commandLongHistoryWithRate "command-long-history-verify-every" 1

commandLongHistoryWithRate :: Text -> Int -> GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
commandLongHistoryWithRate name rate config (_, runner@(StoreRunner runStore)) = do
  seedLedger runner ledgerTarget 10_000
  let options = defaultRunCommandOptions {Command.seedVerifySampleRate = rate}
  measured <- measureLeg config name \index -> do
    outcome <- runStore (Command.runCommand options retentionLedger ledgerTarget (Deposit 1))
    case outcome of
      Right (Right result)
        | result.eventsAppended == 1
            && result.streamVersion == StreamVersion (fromIntegral (10_000 + index)) ->
            pure ()
      other -> fail (Text.unpack name <> ": command " <> show index <> ": " <> show other)
  snapshot <- runStore do
    maybeId <- Store.lookupStreamId (KeiroStream.streamName ledgerTarget)
    traverse lookupSnapshotRow maybeId
  let expectedSnapshot = StreamVersion (fromIntegral (((10_000 + operationCount config) `div` 100) * 100))
  case snapshot of
    Right (Just (Just row)) | row.streamVersion == expectedSnapshot -> pure ()
    other -> fail (Text.unpack name <> ": final snapshot: " <> show other)
  postReturn name (operationCount config)
  pure measured

hydrateOnly :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
hydrateOnly config (_, runner@(StoreRunner runStore)) = do
  seedLedger runner ledgerTarget 10_000
  let options = defaultRunCommandOptions {Command.seedVerifySampleRate = 0}
  measured <- measureLeg config "hydrate-only" \_ -> do
    outcome <- runStore (Command.hydrate options (unvalidated retentionLedger) ledgerTarget)
    case outcome of
      Right (Right hydrated) | hydrated.streamVersion == StreamVersion 10_000 -> pure ()
      Right (Right hydrated) -> fail ("hydrate-only: unexpected version " <> show hydrated.streamVersion)
      Right (Left failure) -> fail ("hydrate-only: " <> show failure)
      Left failure -> fail ("hydrate-only: " <> show failure)
  postReturn "hydrate-only" (operationCount config)
  pure measured

kirokuReadTail :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
kirokuReadTail config (_, runner@(StoreRunner runStore)) = do
  seedLedgerRaw runner ledgerTarget 10_000
  let name = KeiroStream.streamName ledgerTarget
  measured <- measureLeg config "kiroku-read-tail" \_ -> do
    outcome <- runStore do
      maybeId <- Store.lookupStreamId name
      events <- Store.readStreamForward name (StreamVersion 9_900) 256
      pure (maybeId, events)
    case outcome of
      Right (Just _, events) | Vector.length events == 100 -> pure ()
      other -> fail ("kiroku-read-tail: " <> show (fmap (\(streamId, events) -> (streamId, Vector.length events)) other))
  postReturn "kiroku-read-tail" (operationCount config)
  pure measured

commandShortHistory :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
commandShortHistory config (_, StoreRunner runStore) = do
  let options = defaultRunCommandOptions {Command.seedVerifySampleRate = 0}
  measured <- measureLeg config "command-short-history" \index -> do
    let target = KeiroStream.stream ("retentiontarget-" <> Text.pack (show (index `mod` 16))) :: KeiroStream.Stream TargetEventStream
        expected = StreamVersion (fromIntegral ((index - 1) `div` 16 + 1))
    outcome <- runStore (Command.runCommand options retentionTargetStream target (Credit 1))
    case outcome of
      Right (Right result) | result.eventsAppended == 1 && result.streamVersion == expected -> pure ()
      other -> fail ("command-short-history: command " <> show index <> ": " <> show other)
  postReturn "command-short-history" (operationCount config)
  pure measured

baselineNoStore :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
baselineNoStore config _ =
  measureLeg config "baseline-no-store" \index ->
    void (evaluate (sum (replicate 100 (index `mod` 17))))

kirokuAppendProbe :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
kirokuAppendProbe config (_, StoreRunner runStore) = do
  measured <- measureLegWithSampler config "kiroku-append-probe" \sample -> do
    outcome <- runStore $ forM_ [1 .. operationCount config] \index -> do
      let (streamName, eventId, event) = plainEvent index
      _ <- Store.appendToStream streamName AnyVersion [event]
      exists <- Store.eventExistsInStream streamName eventId
      unless exists $ liftIO $ fail ("kiroku-append-probe: missing event " <> show index)
      when (index `mod` config.blockSize == 0) $ liftIO (sample index)
    void (expectRight outcome)
  postReturn "kiroku-append-probe" (operationCount config)
  settleSeconds <- lookupEnv "KEIRO_RETENTION_SETTLE_SECONDS"
  forM_ settleSeconds \rawSeconds -> case readMaybe rawSeconds of
    Just seconds | seconds > 0 -> do
      threadDelay (seconds * 1_000_000)
      settled <- sampleHeap (operationCount config)
      Text.IO.putStrLn ("settled leg=kiroku-append-probe after_seconds=" <> Text.pack (show seconds) <> " live_bytes=" <> Text.pack (show settled.liveBytes) <> " large_objects_bytes=" <> Text.pack (show settled.largeObjectBytes))
    _ -> fail "KEIRO_RETENTION_SETTLE_SECONDS must be a positive integer"
  pure measured

kirokuAppendOnly :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
kirokuAppendOnly config (_, StoreRunner runStore) = do
  requestedRate <- lookupEnv "KEIRO_RETENTION_APPEND_RATE"
  delayMicros <- case requestedRate of
    Nothing -> pure 0
    Just rawRate -> case readMaybe rawRate of
      Just rate | rate > 0 -> pure (1_000_000 `div` rate)
      _ -> fail "KEIRO_RETENTION_APPEND_RATE must be a positive integer"
  measured <- measureLegWithSampler config "kiroku-append-only" \sample -> do
    outcome <- runStore $ forM_ [1 .. operationCount config] \index -> do
      let (streamName, _, event) = plainEvent index
      _ <- Store.appendToStream streamName AnyVersion [event]
      when (delayMicros > 0) $ liftIO (threadDelay delayMicros)
      when (index `mod` config.blockSize == 0) $ liftIO (sample index)
    void (expectRight outcome)
  postReturn "kiroku-append-only" (operationCount config)
  pure measured

kirokuAppendTx :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
kirokuAppendTx config (_, StoreRunner runStore) = do
  measured <- measureLegWithSampler config "kiroku-append-tx" \sample -> do
    outcome <- runStore $ forM_ [1 .. operationCount config] \index -> do
      let (streamName, _, event) = plainEvent index
      result <- StoreTx.runTransactionAppendingResource streamName AnyVersion [event] (const (pure ()))
      case result of
        Left failure -> liftIO $ fail ("kiroku-append-tx: " <> show failure)
        Right () -> pure ()
      when (index `mod` config.blockSize == 0) $ liftIO (sample index)
    void (expectRight outcome)
  postReturn "kiroku-append-tx" (operationCount config)
  pure measured

kirokuProbeOnly :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
kirokuProbeOnly config (_, StoreRunner runStore) = do
  setup <- runStore $ forM_ [1 .. operationCount config] \index -> do
    let (streamName, _, event) = plainEvent index
    void (Store.appendToStream streamName AnyVersion [event])
  void (expectRight setup)
  measured <- measureLegWithSampler config "kiroku-probe-only" \sample -> do
    outcome <- runStore $ forM_ [1 .. operationCount config] \index -> do
      let (streamName, eventId, _) = plainEvent index
      exists <- Store.eventExistsInStream streamName eventId
      unless exists $ liftIO $ fail ("kiroku-probe-only: missing event " <> show index)
      when (index `mod` config.blockSize == 0) $ liftIO (sample index)
    void (expectRight outcome)
  postReturn "kiroku-probe-only" (operationCount config)
  pure measured

plainEvent :: Int -> (StreamName, EventId, EventData)
plainEvent index =
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
   in (streamName, eventId, event)

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

handBridgeAck :: GateConfig -> (Store.KirokuStore, StoreRunner) -> IO (Verdict, [HeapSample])
handBridgeAck config (store, runner@(StoreRunner runStore)) = do
  appendSignals runner (operationCount config)
  measured <- measureLegWithSampler config "hand-bridge-ack" \sample -> do
    outcome <- runStore do
      (adapter, _) <- liftIO $ ackAdapter store (sourceConfig "retention-hand-bridge-ack") 256
      consumeAdapter (operationCount config) config.blockSize sample adapter `Effectful.finally` adapter.shutdown
    void (expectRight outcome)
  postReturn "hand-bridge-ack" (operationCount config)
  pure measured

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
  let snapshotTargets = operationCount config > 1500
  Text.IO.putStrLn $ if snapshotTargets then "router-worker target snapshots: Every 100" else "router-worker target snapshots: Never"
  appendSignals runner (operationCount config)
  measured <- measureLegWithSampler config "router-worker" \sample -> do
    outcome <- runStore do
      adapter <- kirokuAdapter store (defaultKirokuAdapterConfig (SubscriptionName "retention-router") sourceTarget)
      instrumented <- sampleOnAck (operationCount config) config.blockSize sample adapter
      runRouterWorkerWith defaultWorkerOptions defaultRunCommandOptions (retentionRouter snapshotTargets) instrumented decodeSignal
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
