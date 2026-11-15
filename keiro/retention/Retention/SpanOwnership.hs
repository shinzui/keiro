{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Finite ownership probe, separate from the steady-state heap slope gate.
module Retention.SpanOwnership (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, evaluate)
import Control.Monad (forM, forM_, void)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..))
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import GHC.Exts (fromList)
import Keiro.Command qualified as Command
import Keiro.Integration.Event qualified as Integration
import Keiro.Outbox qualified as Outbox
import Keiro.Stream qualified as Stream
import Keiro.Telemetry qualified as Telemetry
import Keiro.Test.Postgres (Fixture, StoreRunner (..), withFreshResourceStore)
import Keiro.Timer qualified as Timer
import Keiro.Workflow qualified as Workflow
import Kiroku.Store qualified as Store
import OpenTelemetry.Attributes (toAttribute)
import OpenTelemetry.Context.ThreadLocal qualified as Context
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core
import Retention.Fixture (TargetCommand (..), retentionNoOpTargetStream)
import Shibuya.Adapter (TraceCorrelation (..))
import Shibuya.Core.Types qualified as Shibuya
import System.Mem (performMajorGC)
import System.Mem.Weak (Weak, deRefWeak, mkWeakPtr)
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "Span payload ownership" do
  forM_ [False, True] \finished ->
    it (if finished then "collects payloads with finished spans retained" else "collects payloads with live spans retained") $
      probe finished False
  it "detects a span-owned payload and collects it after releasing spans" $
    probe True True
  it "collects typed no-op payloads while their uninspected spans remain alive" $
    withFreshResourceStore fixture $ \(_, runner) -> do
      (processor, exported) <- inMemoryListExporter
      bracket
        (createTracerProvider [processor] emptyTracerProviderOptions)
        (\provider -> void (shutdownTracerProvider provider Nothing))
        $ \provider -> do
          weak <- produceNoOpPayloads runner (makeTracer provider "keiro-retention" tracerOptions)
          awaitCollection weak `shouldReturn` True
          spans <- readIORef exported
          length spans `shouldBe` 8

  it "collects batch payloads with mixed destinations and more than 128 linked rows" $ do
    (processor, exported) <- inMemoryListExporter
    bracket
      (createTracerProvider [processor] emptyTracerProviderOptions)
      (\provider -> void (shutdownTracerProvider provider Nothing))
      $ \provider -> do
        weak <- produceBatchPayloads (makeTracer provider "keiro-retention" tracerOptions)
        awaitCollection weak `shouldReturn` True
        spans <- readIORef exported
        length spans `shouldBe` 1

  it "collects fetched timer and journal payloads while durable spans remain retained" $
    withFreshResourceStore fixture $ \(_, runner) -> do
      (processor, exported) <- inMemoryListExporter
      bracket
        (createTracerProvider [processor] emptyTracerProviderOptions)
        (\provider -> void (shutdownTracerProvider provider Nothing))
        $ \provider -> do
          weak <- produceDurablePayloads runner (makeTracer provider "durable-ownership" tracerOptions)
          awaitCollection weak `shouldReturn` True
          spans <- readIORef exported
          length spans `shouldBe` 24

  forM_ [ParentAndLink, LinkOnly] $ \policy ->
    it ("collects subscription envelopes and lazy scalar attributes under " <> show policy) $ do
      (processor, exported) <- inMemoryListExporter
      bracket
        (createTracerProvider [processor] emptyTracerProviderOptions)
        (\provider -> void (shutdownTracerProvider provider Nothing))
        $ \provider -> do
          weak <- produceSubscriptionPayloads (makeTracer provider "keiro-retention" tracerOptions) policy
          awaitCollection weak `shouldReturn` True
          spans <- readIORef exported
          length spans `shouldBe` 8

-- Both probes use rows decoded from PostgreSQL, rather than synthetic contexts.
{-# NOINLINE produceDurablePayloads #-}
produceDurablePayloads :: StoreRunner -> Tracer -> IO [Weak Aeson.Value]
produceDurablePayloads (StoreRunner runStore) tracer = fmap concat $ forM [1 .. 8 :: Int] $ \index -> do
  let name = Workflow.WorkflowName "ownership"
      wid = Workflow.WorkflowId (Text.pack (show index))
      now = UTCTime (ModifiedJulianDay 60000) 0
      payload = Aeson.String (Text.replicate (128 * 1024) (Text.pack (show index)))
      request = Timer.TimerRequest (Timer.TimerId (UUID.fromWords 0 0 0 (fromIntegral index))) "ownership" "one" now payload Nothing
  Telemetry.withWorkflowSpan (Just tracer) name wid Nothing $ \_ -> do
    Right () <- runStore (Workflow.appendJournalEntryTraced (Just tracer) name wid (Workflow.StepRecorded "origin" payload now))
    captured <- Timer.captureTimerTraceContext (Just tracer) request
    Right () <- runStore (Store.runTransaction (Timer.scheduleTimerTx captured))
    pure ()
  Right events <- runStore (Store.readStreamForward (Workflow.workflowGenerationStreamName name wid 0) (Store.StreamVersion 0) 1)
  Right (Just timer) <- runStore (Timer.lookupTimer (Timer.TimerId (UUID.fromWords 0 0 0 (fromIntegral index))))
  let event = Vector.head events
  eventWeak <- mkWeakPtr (event.payload) Nothing
  timerWeak <- mkWeakPtr (timer.payload) Nothing
  Telemetry.withWorkflowSpan (Just tracer) name wid Nothing $ \sp ->
    Telemetry.recordWorkflowResumeLinks sp (Telemetry.traceContextFromMetadata event.metadata) (Telemetry.traceContextFromMetadata event.metadata)
  Telemetry.withTimerFireSpan (Just tracer) timer.processManagerName (case timer.timerId of Timer.TimerId uuid -> UUID.toText uuid) timer.traceContext (const (pure ()))
  pure [eventWeak, timerWeak]

{-# NOINLINE produceSubscriptionPayloads #-}
produceSubscriptionPayloads :: Tracer -> TraceCorrelation -> IO [Weak Text]
produceSubscriptionPayloads tracer policy = forM [1 .. 8 :: Int] $ \index -> do
  payload <- evaluate (Text.replicate (128 * 1024) (Text.pack (show index)))
  weak <- mkWeakPtr payload Nothing
  let envelope =
        Shibuya.Envelope
          { Shibuya.messageId = Shibuya.MessageId (Text.pack (show index)),
            Shibuya.cursor = Nothing,
            Shibuya.partition = Nothing,
            Shibuya.enqueuedAt = Nothing,
            Shibuya.traceContext = Just [("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")],
            Shibuya.headers = Nothing,
            Shibuya.attempt = Nothing,
            Shibuya.attributes = fromList [("payload.size", toAttribute (Text.length payload))],
            Shibuya.payload = payload
          }
  Telemetry.withSubscriptionProcessSpan (Just tracer) policy "ownership" envelope (const (pure ()))
  pure weak

{-# NOINLINE produceBatchPayloads #-}
produceBatchPayloads :: Tracer -> IO [Weak Text]
produceBatchPayloads tracer = do
  prepared <- forM [1 .. 200 :: Int] $ \index -> do
    payload <- evaluate (Text.replicate (128 * 1024) (Text.pack (show index)))
    weak <- mkWeakPtr payload Nothing
    let now = UTCTime (ModifiedJulianDay 60000) 0
        context = Integration.TraceContext "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" Nothing
        event = Integration.IntegrationEvent (Text.pack (show index)) "retention" (if even index then "even" else "odd") Nothing "Ownership" 1 Integration.ApplicationJson Nothing Nothing Nothing (BS.replicate 1024 65) now Nothing Nothing (Just context) (Just (Aeson.object ["payload" Aeson..= payload]))
        row = Outbox.OutboxRow (Outbox.OutboxId UUID.nil) event Outbox.OutboxPending 0 now Nothing Nothing Nothing Nothing now now
    pure (row, weak)
  Telemetry.withProducerBatchSpan (Just tracer) (map fst prepared) (const (pure ()))
  pure (map snd prepared)

{-# NOINLINE produceNoOpPayloads #-}
produceNoOpPayloads :: StoreRunner -> Tracer -> IO [Weak Text]
produceNoOpPayloads (StoreRunner runStore) tracer =
  forM [1 .. 8 :: Int] $ \index -> do
    payload <- evaluate (Text.replicate (128 * 1024) (Text.pack (show index)))
    weak <- mkWeakPtr payload Nothing
    let handler =
          Command.DomainCommandHandler
            { Command.eventStream = retentionNoOpTargetStream,
              Command.classifySilent = const (Command.SilentNoOp payload)
            }
        options = Command.defaultRunCommandOptions {Command.tracer = Just tracer}
    result <- runStore (Command.runDomainCommand options handler (Stream.stream ("ownership-noop-" <> Text.pack (show index))) (Credit 1))
    case result of
      Right (Right _) -> pure weak
      _ -> fail "no-op ownership command failed"

probe :: Bool -> Bool -> IO ()
probe finished retainPayload = do
  (processor, exported) <- inMemoryListExporter
  bracket
    (createTracerProvider [processor] emptyTracerProviderOptions)
    (\provider -> void (shutdownTracerProvider provider Nothing))
    \provider -> do
      let tracer = makeTracer provider "keiro-retention" tracerOptions
      (live, weakPayloads) <- produce tracer finished retainPayload
      collected <- awaitCollection weakPayloads
      collected `shouldBe` not retainPayload
      if finished
        then do
          spans <- readIORef exported
          length spans `shouldBe` 8
          -- Touch identities after GC, keeping the exporter roots live.
          mapM (evaluate . spanContext) spans >>= (\contexts -> length contexts `shouldBe` 8)
        else do
          mapM isRecording live `shouldReturn` replicate 8 True
          mapM_ (\span -> endSpan span Nothing) live
      writeIORef exported []
      awaitCollection weakPayloads `shouldReturn` True

-- A separate, non-inlined scope prevents the driver retaining workload locals.
{-# NOINLINE produce #-}
produce :: Tracer -> Bool -> Bool -> IO ([Span], [Weak Text])
produce tracer finished retainPayload = do
  results <- forM [1 .. 8 :: Int] \index -> do
    payload <- evaluate (Text.replicate (128 * 1024) (Text.pack (show index)))
    weak <- mkWeakPtr payload Nothing
    context <- Context.getContext
    span <-
      if finished && not retainPayload
        then Telemetry.withCommandSpan (Just tracer) ("ownership-" <> Text.pack (show index)) Nothing $ \current -> do
          stamped <- Telemetry.stampTraceContext (Just (Aeson.object ["payload" Aeson..= payload]))
          _ <- evaluate (Lazy.length (Aeson.encode stamped))
          maybe (fail "expected a recording command span") pure current
        else createSpan tracer context "ownership" defaultSpanArguments
    -- Force only the bounded scalar that real helpers put on spans.
    size <- evaluate (Text.length payload)
    addAttribute span "payload.size" size
    if retainPayload then addAttribute span "negative.payload" payload else pure ()
    if finished then endSpan span Nothing else pure ()
    pure (span, weak)
  pure (if finished then [] else map fst results, map snd results)

awaitCollection :: [Weak a] -> IO Bool
awaitCollection weak = loop (20 :: Int)
  where
    loop remaining = do
      performMajorGC
      alive <- traverse deRefWeak weak
      if all absent alive
        then pure True
        else
          if remaining == 0
            then pure False
            else threadDelay 10_000 >> loop (remaining - 1)
    absent Nothing = True
    absent (Just _) = False
