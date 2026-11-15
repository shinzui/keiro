{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module DurableTracingSpec (spec) where

import Control.Exception (bracket, try)
import Control.Monad (forM_, void)
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Exception qualified as Exception
import Keiro.Codec qualified
import Keiro.Command (defaultRunCommandOptions, runCommand)
import Keiro.Integration.Event (TraceContext)
import Keiro.Prelude (liftIO, (&), (.~), (^.))
import Keiro.ProcessManager (PMCommand (..))
import Keiro.ProcessManager.Reaction qualified as Reaction
import Keiro.Stream (stream)
import Keiro.Telemetry qualified as Telemetry
import Keiro.Test.Postgres (Fixture, StoreRunner (..), withFreshResourceStore)
import Keiro.Timer qualified as Timer
import Keiro.Workflow
import Keiro.Workflow.Awakeable qualified as Awakeable
import Keiro.Workflow.Child qualified as Child
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Sleep qualified as Sleep
import Keiro.Workflow.Snapshot (writeWorkflowSnapshot)
import Kiroku.Store qualified as Store
import Kiroku.Store.Subscription.Types (SubscriptionName (..), SubscriptionTarget (..))
import Kiroku.Store.Types (CategoryName (..), ExpectedVersion (..), RecordedEvent, StreamName (..), StreamVersion (..))
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), lookupAttribute)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import ReactionExample qualified as Example
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku (defaultKirokuAdapterConfig, kirokuAdapter)
import Streamly.Data.Stream qualified as Streamly
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = describe "durable tracing" $ around (withFreshResourceStore fixture) do
  it "links exact sleep wake and origin beyond a snapshot, ignoring a later event and preserving replay" $ \(store, StoreRunner runStore) ->
    withRecorder $ \tracer exported -> do
      let name = WorkflowName "traceSleep"
          wid = WorkflowId "one"
          options = defaultWorkflowRunOptions & #tracer .~ Just tracer
          flow = do
            value <- step (StepName "origin") (pure (7 :: Int))
            _ <- awaitValue (StepName "sleep:pause")
            _ <- awaitValue (StepName "hold")
            pure value
      runStore (runWorkflowWith options name wid flow) `shouldReturn` Right Suspended
      runStore (Instance.lookupTraceAwaitedStep name wid 0) `shouldReturn` Right (Just "sleep:pause")
      [first] <- readIORef exported
      let firstContext = spanContext first
      now <- getCurrentTime
      let commandOptions = defaultRunCommandOptions & #tracer .~ Just tracer
          timerRequest = Timer.TimerRequest (Sleep.sleepTimerId name wid 0 "sleep:pause") "traceSleep" "one" now (Sleep.sleepTimerPayload 0 "sleep:pause") Nothing
          manager =
            (Example.exampleReactionManager now)
              { Reaction.name = "trace-reaction",
                Reaction.react =
                  const
                    ( Reaction.NoAdvance
                        [ Reaction.FollowSchedule Reaction.Once timerRequest,
                          Reaction.FollowDispatch (PMCommand (stream "tracetarget-one") (Example.SendAlert "one"))
                        ]
                    )
              }
      Right (Right _) <- runStore $ runCommand commandOptions Example.exampleTargetEventStream (stream "tracesource-one") (Example.SendAlert "source")
      Right () <- runStore do
        adapter@Adapter {source = incoming, shutdown = stop} <- kirokuAdapter store (defaultKirokuAdapterConfig (SubscriptionName "durable-chain") (Category (CategoryName "tracesource")))
        Reaction.runReactiveProcessManagerWorker
          commandOptions
          manager
          (adapter {source = Streamly.take 1 incoming})
          (\event -> Just (event, Example.IncidentReported "one" Example.Urgent))
          `Exception.finally` stop
      processing <- named "process trace-reaction" =<< readIORef exported
      sourceSpan <- named "command tracesource" =<< readIORef exported
      assertRoot processing
      assertLinks processing [(Nothing, spanContext sourceSpan)]
      dispatched <- named "command tracetarget" =<< readIORef exported
      case spanParent dispatched of
        Just parent -> getSpanContext parent >>= (\ctx -> sameContext ctx (spanContext processing))
        _ -> expectationFailure "dispatched command lost processing parent"
      Right (Just fired) <-
        runStore $
          Sleep.runWorkflowTimerWorkerWith
            (Timer.defaultTimerWorkerOptions & #tracer .~ Just tracer)
            Nothing
            now
            (const (pure Nothing))
      case fired ^. #traceContext >>= Telemetry.creationLinkFromTraceContext of
        Just link -> sameContext (linkContext link) (spanContext processing)
        Nothing -> expectationFailure "reaction did not capture processing creation context"
      spansAfterFire <- readIORef exported
      fire <- named "timer fire traceSleep" spansAfterFire
      assertRoot fire
      assertLinks fire [(Nothing, spanContext processing)]
      -- This later append must never replace the exact awaited sleep event.
      inSpan' tracer "unrelated" defaultSpanArguments $ \_ -> do
        Right _ <- runStore $ appendJournalEntryTraced (Just tracer) name wid (StepRecorded "unrelated" Aeson.Null now)
        pure ()
      Right events <- runStore $ Store.readStreamForward (workflowGenerationStreamName name wid 0) (StreamVersion 0) 20
      let lastEvent = Vector.last events
          state = Map.fromList [("origin", Aeson.toJSON (7 :: Int)), ("sleep:pause", Aeson.Null), ("unrelated", Aeson.Null)]
      runStore (writeWorkflowSnapshot (lastEvent ^. #originalStreamId) (lastEvent ^. #originalVersion) state) `shouldReturn` Right ()
      -- A failed resume restores ambient state and leaves attribution available
      -- for the next attempt; both origin and wake are before the snapshot.
      inSpan' tracer "ambient" defaultSpanArguments $ \ambient -> do
        let failing = do
              _ <- step (StepName "origin") (pure (7 :: Int))
              Sleep.sleepNamed (StepName "pause") (-1)
              Exception.throwIO (userError "retry")
        failed <- try (runStore $ runWorkflowWith options name wid failing) :: IO (Either IOError (Either Store.StoreError (WorkflowOutcome Int)))
        failed `shouldSatisfy` either (const True) (const False)
        assertTraceContext (spanContextOf ambient) =<< Telemetry.traceContextFromCurrentSpan
      inSpan' tracer "ambient-success" defaultSpanArguments $ \ambient -> do
        runStore (runWorkflowWith options name wid flow) `shouldReturn` Right Suspended
        assertTraceContext (spanContextOf ambient) =<< Telemetry.traceContextFromCurrentSpan
      spans <- readIORef exported
      resumes <- filterMName "workflow traceSleep" spans
      length resumes `shouldBe` 3
      forM_ (take 2 resumes) $ \resume -> do
        assertRoot resume
        assertLinks resume [(Just "origin", firstContext), (Just "wake", spanContext fire)]
      -- Replay observes the same map with tracing disabled; metadata is not folded.
      runStore (loadStepIndex name wid 0) `shouldReturn` Right state
      runStore (runWorkflow name wid flow) `shouldReturn` Right Suspended
      runStore (loadStepIndex name wid 0) `shouldReturn` Right state
      runStore (Instance.lookupTraceAwaitedStep name wid 0) `shouldReturn` Right Nothing

  it "deduplicates first-event sleep as wake and leaves legacy timers unlinked" $ \(_, StoreRunner runStore) ->
    withRecorder $ \tracer exported -> do
      let name = WorkflowName "firstSleep"
          wid = WorkflowId "one"
          options = defaultWorkflowRunOptions & #tracer .~ Just tracer
          flow = Sleep.sleepNamed (StepName "pause") (-1)
      runStore (runWorkflowWith options name wid flow) `shouldReturn` Right Suspended
      now <- getCurrentTime
      Right (Just _) <-
        runStore $
          Sleep.runWorkflowTimerWorkerWith
            (Timer.defaultTimerWorkerOptions & #tracer .~ Just tracer)
            Nothing
            now
            (const (pure Nothing))
      runStore (runWorkflowWith options name wid flow) `shouldReturn` Right (Completed ())
      spans <- readIORef exported
      fire <- named "timer fire firstSleep" spans
      resumed <- named "workflow firstSleep" spans
      assertLinks resumed [(Just "wake", spanContext fire)]
      runStore (Instance.lookupTraceAwaitedStep name wid 0) `shouldReturn` Right Nothing
      let request = Timer.TimerRequest (Timer.TimerId UUID.nil) "legacy" "one" now Aeson.Null Nothing
      runStore (Store.runTransaction (Timer.scheduleTimerTx request)) `shouldReturn` Right ()
      Right (Just _) <-
        runStore $
          Timer.runTimerWorkerWith
            Nothing
            (Timer.defaultTimerWorkerOptions & #tracer .~ Just tracer)
            now
            (const (pure Nothing))
      legacy <- named "timer fire legacy" =<< readIORef exported
      assertRoot legacy
      assertLinks legacy []

  it "stamps explicitly traced signals, preserves first metadata on retry, and ignores ambient-only enablement" $ \(_, StoreRunner runStore) ->
    withRecorder $ \tracer exported -> do
      let name = WorkflowName "signalTrace"
          wid = WorkflowId "one"
          options = defaultWorkflowRunOptions & #tracer .~ Just tracer
          flow = do
            (_, wait) <- Awakeable.awakeableNamed (StepName "reply")
            asInt wait
      runStore (runWorkflowWith options name wid flow) `shouldReturn` Right Suspended
      Right rows <- runStore $ Store.readStreamForward (workflowGenerationStreamName name wid 0) (StreamVersion 0) 10
      aid <- case decodeJournal (Vector.head rows) of
        Right (StepRecorded _ value _) -> case Aeson.fromJSON value of
          Aeson.Success aid -> pure aid
          _ -> fail "awakeable allocation"
        _ -> fail "allocation journal missing"
      inSpan' tracer "signal" defaultSpanArguments $ \_ ->
        runStore (Awakeable.signalAwakeableTraced (Just tracer) aid (42 :: Int)) `shouldReturn` Right True
      Right before <- runStore $ Store.getEvent (deterministicJournalId name wid 0 (awakeableStepPrefix <> Awakeable.awakeableIdText aid))
      inSpan' tracer "retry" defaultSpanArguments $ \_ ->
        runStore (Awakeable.signalAwakeableTraced (Just tracer) aid (999 :: Int)) `shouldReturn` Right False
      Right after <- runStore $ Store.getEvent (deterministicJournalId name wid 0 (awakeableStepPrefix <> Awakeable.awakeableIdText aid))
      fmap (^. #metadata) after `shouldBe` fmap (^. #metadata) before
      runStore (runWorkflowWith options name wid flow) `shouldReturn` Right (Completed 42)
      signal <- named "signal" =<< readIORef exported
      resumed <- named "workflow signalTrace" =<< readIORef exported
      links <- linksOf resumed
      [spanId (frozenLinkContext link) | link <- links, roleOf link == Just "wake"] `shouldBe` [spanId (spanContext signal)]
      inSpan' tracer "ambient-only" defaultSpanArguments $ \_ ->
        runStore (runWorkflow (WorkflowName "plain") wid (step (StepName "x") (pure (1 :: Int)))) `shouldReturn` Right (Completed 1)
      Right plain <- runStore $ Store.readStreamForward (workflowGenerationStreamName (WorkflowName "plain") wid 0) (StreamVersion 0) 10
      map (Telemetry.traceContextFromMetadata . (^. #metadata)) (Vector.toList plain) `shouldBe` [Nothing, Nothing]

  it "propagates the finished child context to the parent's exact wake" $ \(_, StoreRunner runStore) ->
    withRecorder $ \tracer exported -> do
      let parentName = WorkflowName "parentTrace"
          parentId = WorkflowId "one"
          childName = WorkflowName "childTrace"
          childId = WorkflowId "two"
          options = defaultWorkflowRunOptions & #tracer .~ Just tracer
          parent = Child.spawnChild childName childId traceChild >>= Child.awaitChild
      runStore (runWorkflowWith options parentName parentId parent) `shouldReturn` Right Suspended
      runStore (Child.runChildWorkflow options childName childId traceChild) `shouldReturn` Right (Completed 9)
      runStore (runWorkflowWith options parentName parentId parent) `shouldReturn` Right (Completed 9)
      spans <- readIORef exported
      childSpan <- named "workflow childTrace" spans
      parentSpan <- named "workflow parentTrace" spans
      links <- linksOf parentSpan
      [spanId (frozenLinkContext link) | link <- links, roleOf link == Just "wake"] `shouldBe` [spanId (spanContext childSpan)]

  it "records wake-before-suspend hints, clears on rotation, and omits missing or legacy evidence" $ \(_, StoreRunner runStore) ->
    withRecorder $ \tracer exported -> do
      let name = WorkflowName "hintTrace"
          wid = WorkflowId "one"
          options = defaultWorkflowRunOptions & #tracer .~ Just tracer
      now <- getCurrentTime
      -- A real wake commits before suspension takes the same per-step lock.
      runStore (appendJournalEntry name wid (StepRecorded "gate" Aeson.Null now)) `shouldReturn` Right ()
      runStore (Instance.markInstanceSuspendedAwaitingTraced True name wid 0 "gate") `shouldReturn` Right ()
      Right (Just row) <- runStore (Instance.lookupInstance name wid)
      row ^. #status `shouldBe` Instance.WfRunning
      runStore (Instance.lookupTraceAwaitedStep name wid 0) `shouldReturn` Right (Just "gate")
      runStore (runWorkflowWith options name wid (awaitValue (StepName "next"))) `shouldReturn` Right Suspended
      resumed <- named "workflow hintTrace" =<< readIORef exported
      assertLinks resumed [] -- legacy metadata has no context
      runStore (Instance.markInstanceSuspendedAwaitingTraced True name wid 0 "missing") `shouldReturn` Right ()
      runStore (runWorkflowWith options name wid (continueAsNew (1 :: Int))) `shouldReturn` Right (ContinuedAsNew :: WorkflowOutcome ())
      runStore (Instance.lookupTraceAwaitedStep name wid 1) `shouldReturn` Right Nothing
      -- No first event means a cancellation-only wake cannot invent a link.
      let emptyName = WorkflowName "missingTrace"
      runStore (Instance.markInstanceSuspendedAwaitingTraced True emptyName wid 0 "awk:missing") `shouldReturn` Right ()
      runStore (runWorkflowWith options emptyName wid (awaitValue (StepName "hold"))) `shouldReturn` Right Suspended
      emptySpan <- named "workflow missingTrace" =<< readIORef exported
      assertLinks emptySpan []

  it "omits malformed, foreign-stream, and mismatched-step wake evidence" $ \(_, StoreRunner runStore) ->
    withRecorder $ \tracer exported ->
      forM_ ["malformed", "wrong-stream", "wrong-step"] $ \scenario -> do
        let name = WorkflowName scenario
            wid = WorkflowId "one"
            options = defaultWorkflowRunOptions & #tracer .~ Just tracer
            flow = do
              _ <- step (StepName "origin") (pure (7 :: Int))
              _ <- awaitValue (StepName "gate")
              awaitValue (StepName "hold")
        runStore (runWorkflowWith options name wid flow) `shouldReturn` Right Suspended
        now <- getCurrentTime
        let metadata = Just (Aeson.object ["traceparent" Aeson..= (if scenario == "malformed" then "bad" else "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" :: Text)])
            event = StepRecorded (if scenario == "wrong-step" then "other" else "gate") Aeson.Null now
            target = if scenario == "wrong-stream" then StreamName "foreign-one" else workflowGenerationStreamName name wid 0
        entry <- either (fail . show) pure (Keiro.Codec.encodeForAppendWithMetadata workflowJournalCodec metadata event)
        Right _ <- runStore (Store.appendToStream target AnyVersion [entry & #eventId .~ Just (deterministicJournalId name wid 0 "gate")])
        runStore (runWorkflowWith options name wid flow) `shouldReturn` Right Suspended
        resume <- named ("workflow " <> scenario) =<< readIORef exported
        links <- linksOf resume
        map roleOf links `shouldBe` [Just "origin"]

withRecorder :: (Tracer -> IORef [ImmutableSpan] -> IO a) -> IO a
withRecorder action = do
  (processor, exported) <- inMemoryListExporter
  bracket
    (createTracerProvider [processor] emptyTracerProviderOptions)
    (\provider -> void (shutdownTracerProvider provider Nothing))
    (\provider -> action (makeTracer provider "durable-test" tracerOptions) exported)

named :: Text -> [ImmutableSpan] -> IO ImmutableSpan
named wanted spans = do
  matches <- filterMName wanted spans
  case matches of
    first : _ -> pure first
    _ -> fail ("missing span " <> show wanted)

filterMName :: Text -> [ImmutableSpan] -> IO [ImmutableSpan]
filterMName wanted spans = do
  pairs <- traverse (\sp -> (sp,) . hotName <$> readIORef (spanHot sp)) spans
  pure [sp | (sp, name) <- pairs, name == wanted]

linksOf :: ImmutableSpan -> IO [Link]
linksOf sp = Vector.toList . appendOnlyBoundedCollectionValues . hotLinks <$> readIORef (spanHot sp)

roleOf :: Link -> Maybe Text
roleOf link = case lookupAttribute (frozenLinkAttributes link) "keiro.workflow.link" of
  Just (AttributeValue (TextAttribute role)) -> Just role
  _ -> Nothing

assertRoot :: ImmutableSpan -> Expectation
assertRoot sp = case spanParent sp of
  Nothing -> pure ()
  Just _ -> expectationFailure "durable span inherited a parent"

assertLinks :: ImmutableSpan -> [(Maybe Text, SpanContext)] -> Expectation
assertLinks sp expected = do
  actual <- linksOf sp
  [(roleOf link, traceId (frozenLinkContext link), spanId (frozenLinkContext link)) | link <- actual]
    `shouldMatchList` [(role, traceId ctx, spanId ctx) | (role, ctx) <- expected]

sameContext :: SpanContext -> SpanContext -> Expectation
sameContext a b = (traceId a, spanId a) `shouldBe` (traceId b, spanId b)

assertTraceContext :: IO SpanContext -> Maybe TraceContext -> Expectation
assertTraceContext expected context = do
  ctx <- expected
  case context >>= Telemetry.creationLinkFromTraceContext of
    Nothing -> expectationFailure "ambient context lost"
    Just link -> sameContext ctx (linkContext link)

spanContextOf :: Span -> IO SpanContext
spanContextOf = getSpanContext

decodeJournal :: RecordedEvent -> Either String WorkflowJournalEvent
decodeJournal row = case Keiro.Codec.decodeRecorded workflowJournalCodec row of
  Left err -> Left (show err)
  Right event -> Right event

awaitValue :: (Workflow :> es) => StepName -> Eff es Aeson.Value
awaitValue key = awaitStep key (pure ())

asInt :: Eff es Int -> Eff es Int
asInt = id

traceChild :: (Workflow :> es) => Eff es Int
traceChild = step (StepName "result") (pure 9)
