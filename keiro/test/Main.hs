module Main (
    main,
)
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5, contrazip6)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (Exception, SomeException, evaluate, finally, throwIO, try)
import Data.Aeson (object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Monoid (mempty)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, diffUTCTime, secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID (UUID, fromString, fromWords64)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, throwError)
import GHC.Conc (ThreadStatus (..), threadStatus)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiki.Core (
    Edge (..),
    HsPred (..),
    InCtor (..),
    IndexN,
    RegFile (..),
    SymTransducer (..),
    Update (..),
    WireCtor (..),
    inpCtor,
    matchInCtor,
    oNil,
    pack,
    proj,
    (*:),
    (.==),
 )
import Keiki.Core qualified as Keiki
import Keiro
import Keiro qualified as KeiroRoot
import Keiro.Connection (ensureProjectionSchema, qualifyTable, withProjectionSchema)
import Keiro.EventStream (Terminality (..))
import Keiro.EventStream.Validate (EventStreamWarning (..), ValidatedEventStream, mkEventStream, mkEventStreamOrThrow, validateEventStream)
import Keiro.Inbox (
    InboxDedupePolicy (..),
    InboxError (..),
    InboxPersistence (..),
    InboxResult (..),
    InboxStatus (..),
    KafkaDeliveryRef (..),
    garbageCollectCompleted,
    listInbox,
    lookupInbox,
    markFailedTx,
    runInboxTransaction,
    runInboxTransactionBatch,
    runInboxTransactionWith,
    runInboxTransactionWithRetries,
    runInboxTransactionWithRetriesWith,
    sampleInboxBacklog,
 )
import Keiro.Inbox.Kafka qualified as InboxKafka
import Keiro.Integration.Event (
    IntegrationContentType (..),
    IntegrationEvent (..),
    SchemaReference (..),
    TraceContext (..),
    decodeJsonIntegrationEvent,
    encodeJsonIntegrationEvent,
    headerContentType,
    headerMessageId,
    headerSchemaSubject,
    headerSchemaVersion,
    headerSourceEventId,
    headerSourceGlobalPosition,
    headerTraceParent,
    integrationHeaders,
    integrationPayload,
    parseContentType,
 )
import Keiro.Integration.Event qualified as IntegrationEvent
import Keiro.Outbox (
    BackoffSchedule (..),
    ExponentialBackoffOptions (..),
    IntegrationEventDraft (..),
    IntegrationProducer (..),
    IntegrationProducerConfigError (..),
    OrderingPolicy (..),
    OutboxId (..),
    OutboxPublishConfigError (..),
    OutboxRow (..),
    OutboxStatus (..),
    PublishOutcome (..),
    claimOutboxBatch,
    defaultMaintenanceOptions,
    defaultPublishOptions,
    draftToEvent,
    enqueueIntegrationEventTx,
    freshOutboxId,
    garbageCollectSent,
    lookupOutbox,
    markOutboxSent,
    mintIntegrationEvent,
    mkIntegrationProducer,
    mkOutboxPublishOptions,
    outboxMaintenancePass,
    publishClaimedOutbox,
    sampleOutboxBacklog,
 )
import Keiro.Outbox.Kafka qualified as OutboxKafka
import Keiro.Outbox.Schema (markOutboxFailedTx)
import Keiro.Prelude
import Keiro.ProcessManager
import Keiro.Projection
import Keiro.ReadModel
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Keiro.Snapshot.Policy (shouldSnapshot, shouldSnapshotSpan)
import Keiro.Stream qualified as Stream
import Keiro.Subscription.Shard (
    ShardCountMismatch (..),
    ShardLease (..),
    WorkerId (..),
    ensureShards,
    fairShareTarget,
 )
import Keiro.Subscription.Shard.Schema (
    claimShardsTx,
    ensureShardRows,
    listShardOwnership,
    releaseShardsTx,
    renewLeaseTx,
 )
import Keiro.Subscription.Shard.Worker (
    ShardAck (..),
    ShardWorkerError (..),
    ShardedWorkerConfigError (..),
    ShardedWorkerOptions (..),
    acquireOutcome,
    defaultShardedWorkerOptions,
    mkShardedWorkerOptions,
    reconcileShardsOnce,
    runShardedSubscriptionGroup,
    runShardedSubscriptionGroupAck,
 )
import Keiro.Telemetry qualified as Telemetry
import Keiro.Test.Postgres (withFreshStore, withFreshStoreWith, withFreshStores2, withMigratedSuite)
import Keiro.Timer
import Keiro.Wake (
    WakeReason (..),
    WakeSignal (..),
    neverWake,
    wakeSignalFromStore,
 )
import Keiro.Workflow (
    PatchId (..),
    StepName (..),
    Workflow,
    WorkflowError (..),
    WorkflowId (..),
    WorkflowIdentityError (..),
    WorkflowJournalEvent (StepRecorded, WorkflowCancelled, WorkflowCompleted, WorkflowContinuedAsNew, WorkflowFailed),
    WorkflowName (..),
    WorkflowOutcome (..),
    appendJournalEntry,
    appendJournalEntryReturningId,
    awaitStep,
    awakeableAllocStepPrefix,
    continueAsNew,
    currentGeneration,
    defaultWorkflowRunOptions,
    findUnfinishedWorkflowIds,
    loadStepIndex,
    mkWorkflowId,
    mkWorkflowName,
    patch,
    patchSetStepName,
    patchStepName,
    restoreSeed,
    runWorkflow,
    runWorkflowWith,
    step,
    stepExists,
    workflowGenerationStreamName,
    workflowJournalCodec,
 )
import Keiro.Workflow.Awakeable (
    AwakeableId (..),
    WorkflowAwakeableCancelled (..),
    awakeableIdText,
    awakeableIdToUuid,
    awakeableNamed,
    cancelAwakeable,
    deterministicAwakeableId,
    signalAwakeable,
 )
import Keiro.Workflow.Awakeable.Schema qualified as Awk
import Keiro.Workflow.Child (
    ChildHandle (..),
    WorkflowChildCancelled (..),
    WorkflowChildFailed (..),
    awaitChild,
    cancelChild,
    childCompletionHook,
    childResultStepName,
    childSpawnStepName,
    runChildWorkflow,
    spawnChild,
 )
import Keiro.Workflow.Child.Schema qualified as Child
import Keiro.Workflow.Gc qualified as WorkflowGc
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Resume (
    ResumeLogEvent (..),
    ResumeSummary (..),
    WorkflowDef (..),
    defaultWorkflowResumeOptions,
    emptyResumeSummary,
    resumeWorkflowsOnce,
    runPollLoopWith,
    runWorkflowResumeWorkerPush,
    runWorkflowResumeWorkerWith,
 )
import Keiro.Workflow.Sleep (
    parseSleepPayload,
    runWorkflowTimerWorker,
    sleepNamed,
    sleepStepName,
    sleepTimerId,
    sleepTimerPayload,
    workflowSleepFireAction,
 )
import Keiro.Workflow.Snapshot (
    loadWorkflowSnapshot,
    workflowStateCodec,
 )
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Subscription.Types (
    SubscriptionName (..),
    SubscriptionTarget (..),
 )
import Kiroku.Store.Subscription.Types qualified as KirokuSub
import Kiroku.Store.Types (
    CategoryName (..),
    EventData (..),
    EventId (..),
    EventType (..),
    ExpectedVersion (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
 )
import OpenTelemetry.Attributes (Attribute (..), Attributes, PrimitiveAttribute (..), lookupAttribute)
import OpenTelemetry.Attributes.Key (AttributeKey, unkey)
import OpenTelemetry.Exporter.InMemory.Metric (inMemoryMetricExporter)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Exporter.Metric (
    GaugeDataPoint (..),
    HistogramDataPoint (..),
    MetricExport (..),
    NumberValue (..),
    ResourceMetricsExport (..),
    ScopeMetricsExport (..),
    SumDataPoint (..),
 )
import OpenTelemetry.MeterProvider (
    SdkMeterProviderOptions (..),
    createMeterProvider,
    defaultSdkMeterProviderOptions,
 )
import OpenTelemetry.Metric.Core (
    forceFlushMeterProvider,
    getMeter,
 )
import OpenTelemetry.Resource (emptyMaterializedResources)
import OpenTelemetry.Trace (
    SpanStatus (..),
    createTracerProvider,
    emptyTracerProviderOptions,
    makeTracer,
    shutdownTracerProvider,
    tracerOptions,
 )
import OpenTelemetry.Trace.Core (
    ImmutableSpan (..),
    Span,
    SpanContext (..),
    SpanHot (..),
    SpanKind,
    getSpanContext,
 )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Stream qualified as Streamly
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

main :: IO ()
main = withMigratedSuite $ \fixture -> hspec $ do
    describe "Keiro" $ do
        it "exposes the scaffold version" $
            KeiroRoot.version `shouldBe` ("0.1.0.0" :: Text)

    describe "Keiro.Telemetry metrics" $ do
        it "records instrument names and values through an SDK meter" $ do
            (exporter, ref) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            metrics <- Telemetry.newKeiroMetrics meter
            let h = Just metrics
            -- A counter (monotonic sum), a gauge (last value wins), a histogram.
            Telemetry.recordOutboxPublished h 3
            Telemetry.recordOutboxPublished h 2
            Telemetry.recordOutboxBacklog h 7
            Telemetry.recordInboxDuplicates h 1
            Telemetry.recordTimerFireLag h 12.5
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef ref
            let scalars = flattenScalarPoints exported
                hists = flattenHistogramPoints exported
            -- The counter accumulated 3 + 2 = 5.
            lookup "keiro.outbox.published" scalars `shouldBe` Just (IntNumber 5)
            -- The gauge holds its last recorded value.
            lookup "keiro.outbox.backlog" scalars `shouldBe` Just (IntNumber 7)
            -- The duplicate counter holds 1.
            lookup "keiro.inbox.duplicates" scalars `shouldBe` Just (IntNumber 1)
            -- The histogram saw one observation summing to 12.5.
            let lag = [(c, s) | (n, c, s) <- hists, n == "keiro.timer.fire.lag"]
            lag `shouldBe` [(1, 12.5)]
            -- Instruments we never recorded export no points.
            lookup "keiro.timer.stuck" scalars `shouldBe` Nothing

        it "records nothing through a Nothing handle" $ do
            (exporter, ref) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            -- A Nothing handle is the no-op path: helpers must short-circuit.
            let h = Nothing
            Telemetry.recordOutboxPublished h 99
            Telemetry.recordOutboxBacklog h 99
            Telemetry.recordTimerFireLag h 99.0
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef ref
            flattenScalarPoints exported `shouldBe` []
            flattenHistogramPoints exported `shouldBe` []

    describe "Keiro.Stream" $ do
        it "wraps and unwraps kiroku stream names" $ do
            let orderStream = stream "order-123" :: Stream OrderStream
            Stream.streamName orderStream `shouldBe` StreamName "order-123"
            Stream.streamName (mapStreamName (\(StreamName name) -> StreamName (name <> "-archived")) orderStream)
                `shouldBe` StreamName "order-123-archived"

        it "validates categories, rejecting the dash boundary and reserved names" $ do
            fmap Stream.categoryText (Stream.category "incident" :: Either Stream.CategoryError (Stream.StreamCategory ()))
                `shouldBe` Right "incident"
            -- compound categories are camelCase; ':' (reserved for the wf: family) is also accepted
            fmap Stream.categoryText (Stream.category "hospitalSurge" :: Either Stream.CategoryError (Stream.StreamCategory ()))
                `shouldBe` Right "hospitalSurge"
            fmap Stream.categoryText (Stream.category "wf:fulfillment" :: Either Stream.CategoryError (Stream.StreamCategory ()))
                `shouldBe` Right "wf:fulfillment"
            (Stream.category "" :: Either Stream.CategoryError (Stream.StreamCategory ()))
                `shouldBe` Left Stream.CategoryEmpty
            (Stream.category "hospital-surge" :: Either Stream.CategoryError (Stream.StreamCategory ()))
                `shouldBe` Left (Stream.CategoryContainsSeparator "hospital-surge")
            (Stream.category "$all" :: Either Stream.CategoryError (Stream.StreamCategory ()))
                `shouldBe` Left (Stream.CategoryReserved "$all")
            (Stream.category "ord ers" :: Either Stream.CategoryError (Stream.StreamCategory ()))
                `shouldBe` Left (Stream.CategoryContainsIllegalChar ' ' "ord ers")
            (Stream.category "ord\ners" :: Either Stream.CategoryError (Stream.StreamCategory ()))
                `shouldBe` Left (Stream.CategoryContainsIllegalChar '\n' "ord\ners")

        it "builds entity streams that round-trip through kiroku's category rule" $ do
            let cat = Stream.categoryUnsafe "orders" :: Stream.StreamCategory OrderStream
            Stream.streamName (Stream.entityStream cat "1") `shouldBe` StreamName "orders-1"
            Stream.categoryName cat `shouldBe` CategoryName "orders"
            -- The category keiro reports equals kiroku's own parse of the produced
            -- name, even when the id segment itself contains a dash.
            Store.categoryName (Stream.streamName (Stream.entityStream cat "a-b-c"))
                `shouldBe` Stream.categoryName cat

        it "entityStreamId renders ids via StreamIdSegment (Text and String)" $ do
            let cat = Stream.categoryUnsafe "orders" :: Stream.StreamCategory OrderStream
            Stream.streamName (Stream.entityStreamId cat ("o-1" :: Text)) `shouldBe` StreamName "orders-o-1"
            Stream.streamName (Stream.entityStreamId cat ("o-1" :: String)) `shouldBe` StreamName "orders-o-1"

        it "rejects blank entity stream id segments" $ do
            let cat = Stream.categoryUnsafe "orders" :: Stream.StreamCategory OrderStream
            evaluate (Stream.streamName (Stream.entityStream cat "")) `shouldThrow` anyErrorCall
            evaluate (Stream.streamName (Stream.entityStream cat "   ")) `shouldThrow` anyErrorCall

    describe "Keiro.Codec" $ do
        it "encodes current events with type tags and schema-version metadata" $ do
            encoded <- shouldBeRight (encodeForAppend orderCodec (OrderPlaced "order-123" 5))
            encoded ^. #eventType `shouldBe` EventType "OrderPlaced"
            encoded ^. #payload `shouldBe` object ["orderId" Aeson..= ("order-123" :: Text), "quantity" Aeson..= (5 :: Int)]
            extractSchemaVersion (recordedFrom encoded) `shouldBe` Right 2

        it "round-trips current events" $ do
            encoded <- shouldBeRight (encodeForAppend orderCodec (OrderPlaced "order-123" 5))
            decodeRecorded orderCodec (recordedFrom encoded) `shouldBe` Right (OrderPlaced "order-123" 5)

        it "decodes by the stored tag, not by payload shape (H1)" $ do
            let recorded =
                    recordedFrom
                        EventData
                            { eventId = Nothing
                            , eventType = EventType "CounterAudited"
                            , payload = object ["amount" Aeson..= (5 :: Int)]
                            , metadata = Just (metadataForOrDie 1 Nothing)
                            , causationId = Nothing
                            , correlationId = Nothing
                            }
            decodeRecorded counterCodec recorded `shouldBe` Right (CounterAudited 5)

        it "runs upcasters in source-version order" $
            decodeRaw orderCodec (EventType "OrderPlaced") 1 (object ["orderId" Aeson..= ("order-123" :: Text), "qty" Aeson..= (5 :: Int)])
                `shouldBe` Right (OrderPlaced "order-123" 5)

        it "rejects gaps in upcaster chains" $
            decodeRaw gappyCodec (EventType "OrderPlaced") 1 (object ["orderId" Aeson..= ("order-123" :: Text), "qty" Aeson..= (5 :: Int)])
                `shouldBe` Left (GapInUpcasterChain 2 3)

        it "validates codec construction invariants" $ do
            fmap (const ()) (mkCodec (orderCodec{schemaVersion = 0})) `shouldBe` Left (CodecSchemaVersionInvalid 0)
            fmap (const ()) (mkCodec (orderCodec{eventTypes = EventType "OrderPlaced" :| [EventType "OrderPlaced"]}))
                `shouldBe` Left (CodecDuplicateEventTypes [EventType "OrderPlaced"])
            fmap (const ()) (mkCodec (orderCodec{schemaVersion = 3, upcasters = [(1, const upcastOrderPlacedV1), (1, const upcastOrderPlacedV1)]}))
                `shouldBe` Left (CodecDuplicateUpcasterSources [1])
            fmap (const ()) (mkCodec (orderCodec{schemaVersion = 3, upcasters = [(1, const upcastOrderPlacedV1)]}))
                `shouldBe` Left (CodecUpcasterChainIncomplete [2] 3)
            case mkCodec orderCodec of
                Right _ -> pure ()
                Left err -> expectationFailure ("expected orderCodec to validate, got " <> show err)

        it "rejects future-version, malformed metadata, and incomplete upcaster chains" $ do
            let v1Payload = object ["orderId" Aeson..= ("order-123" :: Text), "qty" Aeson..= (5 :: Int)]
                earlyEndCodec =
                    orderCodec
                        { schemaVersion = 4
                        , upcasters = [(1, const upcastOrderPlacedV1), (2, const Right)]
                        }
            decodeRaw orderCodec (EventType "OrderPlaced") 3 v1Payload
                `shouldBe` Left (VersionAhead 3 2)
            decodeRaw earlyEndCodec (EventType "OrderPlaced") 1 v1Payload
                `shouldBe` Left (IncompleteUpcasterChain 3 4)

            let malformedStamp =
                    recordedFrom
                        EventData
                            { eventId = Nothing
                            , eventType = EventType "OrderPlaced"
                            , payload = object ["orderId" Aeson..= ("order-123" :: Text), "quantity" Aeson..= (5 :: Int)]
                            , metadata = Just (object ["schemaVersion" Aeson..= ("2" :: Text)])
                            , causationId = Nothing
                            , correlationId = Nothing
                            }
            extractSchemaVersion malformedStamp
                `shouldBe` Left (MalformedSchemaVersionStamp (Aeson.String "2"))
            fmap (const ()) (encodeForAppendWithMetadata orderCodec (Just (Aeson.String "x")) (OrderPlaced "order-123" 5))
                `shouldBe` Left (NonObjectCallerMetadata (Aeson.String "x"))

        it "rejects recorded events with unknown type tags" $ do
            let encoded =
                    recordedFrom
                        EventData
                            { eventId = Nothing
                            , eventType = EventType "OrderCancelled"
                            , payload = object ["orderId" Aeson..= ("order-123" :: Text)]
                            , metadata = Just (metadataForOrDie 2 Nothing)
                            , causationId = Nothing
                            , correlationId = Nothing
                            }
            decodeRecorded orderCodec encoded
                `shouldBe` Left (UnknownEventType (EventType "OrderCancelled") [EventType "OrderPlaced"])

    describe "Keiro.EventStream" $ do
        it "constructs an author-facing EventStream contract" $ do
            let contract =
                    EventStream
                        { transducer = emptyTransducer
                        , initialState = Idle
                        , initialRegisters = RNil
                        , eventCodec = orderCodec
                        , resolveStreamName = \s -> Stream.streamName s
                        , snapshotPolicy = Never
                        , stateCodec = Nothing
                        }
                typedStream = stream "order-123" :: Stream (EventStream () '[] OrderState OrderCommand OrderEvent)
            contract ^. #initialState `shouldBe` Idle
            (contract ^. #resolveStreamName) typedStream `shouldBe` StreamName "order-123"

        it "evaluates snapshot policies with explicit terminality" $ do
            shouldSnapshot (Every 2) NotTerminal () (StreamVersion 0) `shouldBe` False
            shouldSnapshot (Every 2) NotTerminal () (StreamVersion 2) `shouldBe` True
            shouldSnapshot OnTerminal Terminal () (StreamVersion 1) `shouldBe` True
            shouldSnapshot OnTerminal NotTerminal () (StreamVersion 1) `shouldBe` False
            shouldSnapshot (Custom (\terminality _ _ -> terminality == Terminal)) Terminal () (StreamVersion 1)
                `shouldBe` True
            shouldSnapshot (Custom (\terminality _ _ -> terminality == Terminal)) NotTerminal () (StreamVersion 1)
                `shouldBe` False
            shouldSnapshotSpan (Every 3) NotTerminal () (StreamVersion 2) (StreamVersion 4)
                `shouldBe` True
            shouldSnapshotSpan (Every 3) NotTerminal () (StreamVersion 4) (StreamVersion 5)
                `shouldBe` False

        it "rejects snapshot policies without a state codec" $ do
            let contract :: CounterEventStream
                contract = counterEventStreamDef{snapshotPolicy = Every 10, stateCodec = Nothing}
            fmap (const ()) (mkEventStream "snapshotless" contract)
                `shouldBe` Left [EventStreamWarning "snapshotless" "snapshotPolicy is set but stateCodec is Nothing; snapshots would never be written"]

    describe "EventStream replay-safety (validateEventStream)" $ do
        it "every production-intent stream validates clean" $
            concat
                [ validateEventStream "counter" counterEventStreamDef
                , validateEventStream "counter-no-op" noOpCounterEventStreamDef
                , validateEventStream "counter-multi" multiCounterEventStreamDef
                , validateEventStream "snapshot-counter" snapshotCounterEventStreamDef
                , validateEventStream "snapshot-counter-multi" multiSnapshotCounterEventStreamDef
                , validateEventStream "snapshot-counter-guarded" guardedSnapshotCounterEventStreamDef
                , validateEventStream "pm-snapshot-counter" pmSnapshotCounterEventStreamDef
                , validateEventStream "rejecting-counter" rejectingEventStreamDef
                ]
                `shouldBe` []

    describe "mkEventStream" $ do
        it "rejects a hidden-input stream by label" $ do
            let warns = validateEventStream "broken" brokenHiddenInputEventStream
            warns `shouldNotBe` []
            map eswStreamLabel warns `shouldSatisfy` all (== "broken")
            map eswReason warns `shouldSatisfy` any (Text.isInfixOf "hidden-input")
            case mkEventStream "broken" brokenHiddenInputEventStream of
                Left ws -> do
                    map eswStreamLabel ws `shouldSatisfy` all (== "broken")
                    map eswReason ws `shouldSatisfy` any (Text.isInfixOf "hidden-input")
                Right _ -> expectationFailure "expected mkEventStream to reject the hidden-input stream"

        it "accepts every production-intent stream" $ do
            let expectAccepted label eventStream =
                    case mkEventStream label eventStream of
                        Right _ -> pure ()
                        Left ws -> expectationFailure ("expected mkEventStream to accept " <> Text.unpack label <> ", got " <> show ws)
            expectAccepted "counter" counterEventStreamDef
            expectAccepted "counter-no-op" noOpCounterEventStreamDef
            expectAccepted "counter-multi" multiCounterEventStreamDef
            expectAccepted "snapshot-counter" snapshotCounterEventStreamDef
            expectAccepted "snapshot-counter-multi" multiSnapshotCounterEventStreamDef
            expectAccepted "snapshot-counter-guarded" guardedSnapshotCounterEventStreamDef
            expectAccepted "pm-snapshot-counter" pmSnapshotCounterEventStreamDef
            expectAccepted "rejecting-counter" rejectingEventStreamDef

        it "rejects a bare EventStream at runCommand (compile-time)" $ do
            (exitCode, _stdout, stderr) <-
                readProcessWithExitCode
                    "cabal"
                    [ "exec"
                    , "ghc"
                    , "--"
                    , "-fno-code"
                    , "-package"
                    , "keiro"
                    , "test/ReplaySafetyTypeProbe.hs"
                    ]
                    ""
            exitCode `shouldSatisfy` (/= ExitSuccess)
            stderr `shouldSatisfy` ("ValidatedEventStream" `isInfixOf`)

    describe "Keiro.Command" $ around (withFreshStore fixture) $ do
        it "creates a stream and appends the first command event" $ \storeHandle -> do
            let target = stream "counter-command-create" :: Stream CounterEventStream
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions counterEventStream target (Add 2)
            case result of
                Right (Right commandResult) -> do
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 1
                    commandResult ^. #eventsAppended `shouldBe` 1
                    commandResult ^. #globalPosition `shouldSatisfy` isJust
                other -> expectationFailure ("expected successful command, got " <> show other)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-command-create") (StreamVersion 0) 10
            Vector.length recorded `shouldBe` 1
            traverse (decodeRecorded counterCodec) (Vector.toList recorded)
                `shouldBe` Right [CounterAdded 2]

        it "rehydrates prior events before appending a second command event" $ \storeHandle -> do
            let target = stream "counter-command-update" :: Stream CounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions counterEventStream target (Add 2)
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions counterEventStream target (Add 3)
            case result of
                Right (Right commandResult) ->
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 2
                other -> expectationFailure ("expected successful second command, got " <> show other)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-command-update") (StreamVersion 0) 10
            traverse (decodeRecorded counterCodec) (Vector.toList recorded)
                `shouldBe` Right [CounterAdded 2, CounterAdded 3]

        it "uses caller-supplied event ids for idempotent command batches" $ \storeHandle -> do
            let target = stream "counter-command-event-id" :: Stream CounterEventStream
                supplied = EventId sampleUuid2
                options = defaultRunCommandOptions & #eventIds .~ [supplied]
            result <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream target (Add 7)
            case result of
                Right (Right commandResult) ->
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 1
                other -> expectationFailure ("expected successful command, got " <> show other)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-command-event-id") (StreamVersion 0) 10
            fmap (^. #eventId) (Vector.toList recorded) `shouldBe` [supplied]

        it "retries an optimistic conflict after rehydrating the winning event" $ \storeHandle -> do
            conflictInserted <- newIORef False
            let target = stream "counter-command-conflict" :: Stream CounterEventStream
                conflictStreamName = StreamName "counter-command-conflict"
                insertConflict = do
                    shouldInsert <- atomicModifyIORef' conflictInserted $ \alreadyInserted ->
                        if alreadyInserted
                            then (True, False)
                            else (True, True)
                    when shouldInsert $ do
                        encoded <- shouldBeRight (encodeForAppend counterCodec (CounterAdded 10))
                        outcome <-
                            Store.runStoreIO storeHandle $
                                Store.appendToStream conflictStreamName NoStream [encoded]
                        case outcome of
                            Right _ -> pure ()
                            Left err -> expectationFailure ("failed to insert conflict event: " <> show err)
                options = defaultRunCommandOptions & #beforeAppend .~ insertConflict
            result <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream target (Add 2)
            case result of
                Right (Right commandResult) -> do
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 2
                    commandResult ^. #eventsAppended `shouldBe` 1
                other -> expectationFailure ("expected retry to succeed, got " <> show other)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward conflictStreamName (StreamVersion 0) 10
            traverse (decodeRecorded counterCodec) (Vector.toList recorded)
                `shouldBe` Right [CounterAdded 10, CounterAdded 2]

        it "reports true retry attempts and command conflict metrics when the retry budget is exhausted" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            let target = stream "counter-command-exhausted-conflict" :: Stream CounterEventStream
                conflictStreamName = StreamName "counter-command-exhausted-conflict"
                insertConflict = do
                    encoded <- shouldBeRight (encodeForAppend counterCodec (CounterAdded 10))
                    outcome <-
                        Store.runStoreIO storeHandle $
                            Store.appendToStream conflictStreamName AnyVersion [encoded]
                    case outcome of
                        Right _ -> pure ()
                        Left err -> expectationFailure ("failed to insert conflict event: " <> show err)
                options =
                    defaultRunCommandOptions
                        & #beforeAppend
                        .~ insertConflict
                        & #retryLimit
                        .~ 2
                        & #retryBackoffMicros
                        .~ 0
                        & #metrics
                        ?~ keiroMetrics
            result <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream target (Add 2)
            case result of
                Right (Left (RetryExhausted attempts _)) ->
                    attempts `shouldBe` 3
                other -> expectationFailure ("expected exhausted retry budget, got " <> show other)
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            let scalars = flattenScalarPoints exported
            lookup "keiro.command.conflicts" scalars `shouldBe` Just (IntNumber 3)
            lookup "keiro.command.retries" scalars `shouldBe` Just (IntNumber 2)

        it "records the successful retry attempt on the command span" $ \storeHandle -> do
            (processor, spansRef) <- inMemoryListExporter
            provider <- createTracerProvider [processor] emptyTracerProviderOptions
            conflictInserted <- newIORef False
            let tracer = makeTracer provider "keiro-test" tracerOptions
                target = stream "counter-command-retry-span" :: Stream CounterEventStream
                conflictStreamName = StreamName "counter-command-retry-span"
                insertConflict = do
                    shouldInsert <- atomicModifyIORef' conflictInserted $ \alreadyInserted ->
                        if alreadyInserted
                            then (True, False)
                            else (True, True)
                    when shouldInsert $ do
                        encoded <- shouldBeRight (encodeForAppend counterCodec (CounterAdded 10))
                        outcome <-
                            Store.runStoreIO storeHandle $
                                Store.appendToStream conflictStreamName NoStream [encoded]
                        case outcome of
                            Right _ -> pure ()
                            Left err -> expectationFailure ("failed to insert conflict event: " <> show err)
                options =
                    defaultRunCommandOptions
                        & #beforeAppend
                        .~ insertConflict
                        & #retryBackoffMicros
                        .~ 0
                        & #tracer
                        ?~ tracer
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream target (Add 2)
            _ <- shutdownTracerProvider provider Nothing
            spans <- traverse captureSpan =<< readIORef spansRef
            case spans of
                [sp] ->
                    case lookupAttribute (csAttributes sp) "keiro.retry.attempt" of
                        Just (AttributeValue (IntAttribute n)) -> n `shouldBe` 2
                        other -> expectationFailure ("expected retry attempt attribute 2, got " <> show other)
                other -> expectationFailure ("expected one span, got " <> show (length other))

        it "counts duplicate deterministic command events" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            let supplied = EventId sampleUuid3
                first = stream "counter-command-duplicate-a" :: Stream CounterEventStream
                second = stream "counter-command-duplicate-b" :: Stream CounterEventStream
                options =
                    defaultRunCommandOptions
                        & #eventIds
                        .~ [supplied]
                        & #metrics
                        ?~ keiroMetrics
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream first (Add 1)
            result <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream second (Add 2)
            case result of
                Right (Left (StoreFailed Store.DuplicateEvent{})) -> pure ()
                other -> expectationFailure ("expected duplicate event failure, got " <> show other)
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            lookup "keiro.command.duplicates" (flattenScalarPoints exported) `shouldBe` Just (IntNumber 1)

        it "fails fast when a soft-deleted stream causes a conflict fixpoint" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            let target = stream "counter-command-soft-deleted" :: Stream CounterEventStream
                options =
                    defaultRunCommandOptions
                        & #retryBackoffMicros
                        .~ 0
                        & #metrics
                        ?~ keiroMetrics
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream target (Add 1)
            Right (Just _) <-
                Store.runStoreIO storeHandle $
                    Store.softDeleteStream (StreamName "counter-command-soft-deleted")
            result <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream target (Add 2)
            case result of
                Right (Left (ConflictFixpoint (StreamVersion 0) Store.StreamAlreadyExists{})) -> pure ()
                other -> expectationFailure ("expected conflict fixpoint, got " <> show other)
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            lookup "keiro.command.conflicts" (flattenScalarPoints exported) `shouldBe` Just (IntNumber 1)

        it "surfaces decode failure during hydration" $ \storeHandle -> do
            Right _ <-
                Store.runStoreIO storeHandle $
                    Store.appendToStream
                        (StreamName "counter-command-decode-failure")
                        NoStream
                        [ EventData
                            { eventId = Nothing
                            , eventType = EventType "OtherEvent"
                            , payload = object []
                            , metadata = Just (metadataForOrDie 1 Nothing)
                            , causationId = Nothing
                            , correlationId = Nothing
                            }
                        ]
            let target = stream "counter-command-decode-failure" :: Stream CounterEventStream
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions counterEventStream target (Add 1)
            result
                `shouldBe` Right
                    (Left (HydrationDecodeFailed (UnknownEventType (EventType "OtherEvent") [EventType "CounterAdded", EventType "CounterAudited"])))

        it "truncates command span error status descriptions" $ \storeHandle -> do
            (processor, spansRef) <- inMemoryListExporter
            provider <- createTracerProvider [processor] emptyTracerProviderOptions
            let tracer = makeTracer provider "keiro-test" tracerOptions
                longTag = Text.replicate 400 "x"
            Right _ <-
                Store.runStoreIO storeHandle $
                    Store.appendToStream
                        (StreamName "counter-command-long-decode-failure")
                        NoStream
                        [ EventData
                            { eventId = Nothing
                            , eventType = EventType longTag
                            , payload = object []
                            , metadata = Just (metadataForOrDie 1 Nothing)
                            , causationId = Nothing
                            , correlationId = Nothing
                            }
                        ]
            let target = stream "counter-command-long-decode-failure" :: Stream CounterEventStream
                options = defaultRunCommandOptions & #tracer ?~ tracer
            _ <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream target (Add 1)
            _ <- shutdownTracerProvider provider Nothing
            spans <- traverse captureSpan =<< readIORef spansRef
            case spans of
                [sp] ->
                    case csStatus sp of
                        Error description -> Text.length description `shouldSatisfy` (<= 256)
                        other -> expectationFailure ("expected error span status, got " <> show other)
                other -> expectationFailure ("expected one span, got " <> show (length other))

        it "rolls back the append when inline SQL condemns the transaction" $ \storeHandle -> do
            let target = stream "counter-command-rollback" :: Stream CounterEventStream
            result <-
                Store.runStoreIO storeHandle $
                    runCommandWithSql
                        defaultRunCommandOptions
                        counterEventStream
                        target
                        (Add 1)
                        (\_ -> Tx.condemn >> pure ("rolled-back" :: Text))
            case result of
                Right (Right (_, Just "rolled-back")) -> pure ()
                other -> expectationFailure ("expected condemned transaction result, got " <> show other)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-command-rollback") (StreamVersion 0) 10
            recorded `shouldBe` Vector.empty

        it "appends all events emitted by one accepted command" $ \storeHandle -> do
            let target = stream "counter-command-multi-create" :: Stream CounterEventStream
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions multiCounterEventStream target (Add 5)
            case result of
                Right (Right commandResult) -> do
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 2
                    commandResult ^. #eventsAppended `shouldBe` 2
                    commandResult ^. #globalPosition `shouldSatisfy` isJust
                other -> expectationFailure ("expected successful multi-event command, got " <> show other)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-command-multi-create") (StreamVersion 0) 10
            traverse (decodeRecorded counterCodec) (Vector.toList recorded)
                `shouldBe` Right [CounterAdded 5, CounterAudited 5]

        it "replays a prior multi-event command before appending the next batch" $ \storeHandle -> do
            let target = stream "counter-command-multi-replay" :: Stream CounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions multiCounterEventStream target (Add 2)
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions multiCounterEventStream target (Add 3)
            case result of
                Right (Right commandResult) -> do
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 4
                    commandResult ^. #eventsAppended `shouldBe` 2
                other -> expectationFailure ("expected successful second multi-event command, got " <> show other)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-command-multi-replay") (StreamVersion 0) 10
            traverse (decodeRecorded counterCodec) (Vector.toList recorded)
                `shouldBe` Right [CounterAdded 2, CounterAudited 2, CounterAdded 3, CounterAudited 3]

        it "passes the complete multi-event batch to inline SQL in append order" $ \storeHandle -> do
            let target = stream "counter-command-multi-sql-events" :: Stream CounterEventStream
            result <-
                Store.runStoreIO storeHandle $
                    runCommandWithSqlEvents
                        defaultRunCommandOptions
                        multiCounterEventStream
                        target
                        (Add 8)
                        (\pairs _ -> pure (Prelude.map Prelude.fst pairs))
            case result of
                Right (Right (commandResult, Just observed)) -> do
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 2
                    commandResult ^. #eventsAppended `shouldBe` 2
                    observed `shouldBe` [CounterAdded 8, CounterAudited 8]
                other -> expectationFailure ("expected successful SQL multi-event command, got " <> show other)

        it "command metadata is merged into stored event metadata" $ \storeHandle -> do
            let target = stream "counter-command-metadata" :: Stream CounterEventStream
                opts =
                    defaultRunCommandOptions
                        & #metadata
                        ?~ object ["actor" Aeson..= ("agent-7" :: Text)]
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand opts counterEventStream target (Add 4)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-command-metadata") (StreamVersion 0) 10
            case Vector.toList recorded of
                [event] ->
                    event ^. #metadata
                        `shouldBe` Just (object ["actor" Aeson..= ("agent-7" :: Text), "schemaVersion" Aeson..= (1 :: Int)])
                other -> expectationFailure ("expected a single recorded event, got " <> show other)

        it "reconstructed RecordedEvents match the stored batch" $ \storeHandle -> do
            let target = stream "counter-reconstruct-fidelity" :: Stream CounterEventStream
                opts =
                    defaultRunCommandOptions
                        & #metadata
                        ?~ object ["actor" Aeson..= ("agent-7" :: Text)]
            Right (Right (_, Just pairs)) <-
                Store.runStoreIO storeHandle $
                    runCommandWithSqlEvents opts multiCounterEventStream target (Add 8) (\ps _ -> pure ps)
            let reconstructed = Prelude.map Prelude.snd pairs
            -- Read the stored events back from their source stream.
            Right storedVec <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-reconstruct-fidelity") (StreamVersion 0) 10
            let stored = Vector.toList storedVec
            -- readStreamForward reports globalPosition 0 for stream reads, so take
            -- the true global positions from a category read (the DB is fresh per
            -- test, so category "counter" holds exactly this batch).
            Right catVec <-
                Store.runStoreIO storeHandle $
                    Store.readCategory (CategoryName "counter") (GlobalPosition 0) 10
            let catList = Vector.toList catVec
            Prelude.length reconstructed `shouldBe` 2
            Prelude.length stored `shouldBe` 2
            fmap (^. #eventId) reconstructed `shouldBe` fmap (^. #eventId) stored
            fmap (^. #eventType) reconstructed `shouldBe` fmap (^. #eventType) stored
            fmap (^. #streamVersion) reconstructed `shouldBe` fmap (^. #streamVersion) stored
            fmap (^. #originalVersion) reconstructed `shouldBe` fmap (^. #originalVersion) stored
            fmap (^. #originalStreamId) reconstructed `shouldBe` fmap (^. #originalStreamId) stored
            fmap (^. #payload) reconstructed `shouldBe` fmap (^. #payload) stored
            fmap (^. #metadata) reconstructed `shouldBe` fmap (^. #metadata) stored
            fmap (^. #globalPosition) reconstructed `shouldBe` fmap (^. #globalPosition) catList

        it "runCommand emits a Command span with the stream name, db.system.name, and keiro.events.appended" $ \storeHandle -> do
            (processor, spansRef) <- inMemoryListExporter
            provider <- createTracerProvider [processor] emptyTracerProviderOptions
            let tracer = makeTracer provider "keiro-test" tracerOptions
                target = stream "counter-command-otel" :: Stream CounterEventStream
                options = defaultRunCommandOptions & #tracer ?~ tracer
            Right (Right commandResult) <-
                Store.runStoreIO storeHandle $
                    runCommand options counterEventStream target (Add 9)
            commandResult ^. #streamVersion `shouldBe` StreamVersion 1
            _ <- shutdownTracerProvider provider Nothing
            spans <- traverse captureSpan =<< readIORef spansRef
            length spans `shouldBe` 1
            let sp = case spans of
                    (s : _) -> s
                    [] -> error "no command span captured"
            csName sp `shouldBe` "counter-command-otel"
            show (csKind sp) `shouldBe` "Internal"
            textAttr (csAttributes sp) "keiro.stream.name" `shouldBe` Just "counter-command-otel"
            textAttr (csAttributes sp) "db.system.name" `shouldBe` Just "postgresql"
            -- keiro.events.appended is an Int64 attribute, not Text.
            case lookupAttribute (csAttributes sp) "keiro.events.appended" of
                Just (AttributeValue (IntAttribute n)) -> n `shouldBe` 1
                other -> expectationFailure ("expected IntAttribute 1, got " <> show other)
            case csStatus sp of
                Unset -> pure ()
                Ok -> pure ()
                other -> expectationFailure ("expected Unset/Ok, got " <> show other)

    describe "Keiro.Snapshot" $ around (withFreshStore fixture) $ do
        it "writes a snapshot after policy threshold" $ \storeHandle -> do
            let target = stream "snapshot-write-threshold" :: Stream SnapshotCounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
            Right snapshotVersion <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "snapshot-write-threshold" snapshotVersionForStreamStmt
            snapshotVersion `shouldBe` Just (StreamVersion 2)

        it "does not fail a committed command when the post-commit snapshot write fails" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            let target = stream "snapshot-write-failure-swallowed" :: Stream SnapshotCounterEventStream
                options = defaultRunCommandOptions & #metrics ?~ keiroMetrics
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand options snapshotCounterEventStream target (Add 2)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.sql "ALTER TABLE keiro.keiro_snapshots ADD CONSTRAINT keiro_snapshots_no_writes CHECK (false) NOT VALID"
            result <-
                Store.runStoreIO storeHandle $
                    runCommand options snapshotCounterEventStream target (Add 3)
            case result of
                Right (Right commandResult) -> do
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 2
                    commandResult ^. #eventsAppended `shouldBe` 1
                other -> expectationFailure ("expected committed command despite snapshot failure, got " <> show other)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "snapshot-write-failure-swallowed") (StreamVersion 0) 10
            traverse (decodeRecorded counterCodec) (Vector.toList recorded)
                `shouldBe` Right [CounterAdded 2, CounterAdded 3]
            Right snapshotVersionDuringFailure <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "snapshot-write-failure-swallowed" snapshotVersionForStreamStmt
            snapshotVersionDuringFailure `shouldBe` Nothing
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            lookup "keiro.snapshot.write.failures" (flattenScalarPoints exported) `shouldBe` Just (IntNumber 1)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.sql "ALTER TABLE keiro.keiro_snapshots DROP CONSTRAINT keiro_snapshots_no_writes"
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand options snapshotCounterEventStream target (Add 4)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand options snapshotCounterEventStream target (Add 5)
            Right snapshotVersionAfterRecovery <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "snapshot-write-failure-swallowed" snapshotVersionForStreamStmt
            snapshotVersionAfterRecovery `shouldBe` Just (StreamVersion 4)

        it "hydrates from snapshot and replays only the tail" $ \storeHandle -> do
            let target = stream "snapshot-tail-hydration" :: Stream SnapshotCounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement
                            ( "snapshot-tail-hydration"
                            , (defaultStateCodec @SnapshotCounterRegs @CounterState 1 ^. #encode)
                                (Counting, RCons (Proxy @"lastAmount") 4 RNil)
                            )
                            corruptSnapshotStateStmt
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions guardedSnapshotCounterEventStream target (Add 4)
            case result of
                Right (Right commandResult) ->
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 3
                other -> expectationFailure ("expected snapshot-assisted command, got " <> show other)

        it "falls back when snapshot JSON is corrupt" $ \storeHandle -> do
            let target = stream "snapshot-corrupt-json" :: Stream SnapshotCounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("snapshot-corrupt-json", Aeson.String "bad") corruptSnapshotStateStmt
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 4)
            case result of
                Right (Right commandResult) ->
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 3
                other -> expectationFailure ("expected corrupt snapshot fallback, got " <> show other)

        it "falls back when shape hash mismatches" $ \storeHandle -> do
            let target = stream "snapshot-shape-mismatch" :: Stream SnapshotCounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("snapshot-shape-mismatch", "stale-shape") corruptSnapshotShapeStmt
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 4)
            case result of
                Right (Right commandResult) ->
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 3
                other -> expectationFailure ("expected stale shape fallback, got " <> show other)

        it "falls back after operator truncation" $ \storeHandle -> do
            let target = stream "snapshot-operator-truncate" :: Stream SnapshotCounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.sql "TRUNCATE keiro.keiro_snapshots"
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 4)
            case result of
                Right (Right commandResult) ->
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 3
                other -> expectationFailure ("expected truncation fallback, got " <> show other)

        it "writes snapshots after applying a complete multi-event command batch" $ \storeHandle -> do
            let target = stream "snapshot-multi-event-batch" :: Stream SnapshotCounterEventStream
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions multiSnapshotCounterEventStream target (Add 9)
            case result of
                Right (Right commandResult) -> do
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 2
                    commandResult ^. #eventsAppended `shouldBe` 2
                other -> expectationFailure ("expected multi-event snapshot command, got " <> show other)
            Right snapshotVersion <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "snapshot-multi-event-batch" snapshotVersionForStreamStmt
            snapshotVersion `shouldBe` Just (StreamVersion 2)

        it "writes a snapshot when a multi-event append crosses an Every boundary" $ \storeHandle -> do
            let target = stream "snapshot-multi-event-crosses-boundary" :: Stream SnapshotCounterEventStream
                boundaryEventStream :: SnapshotCounterEventStream
                boundaryEventStream =
                    snapshotCounterEventStreamDef
                        & #transducer
                        .~ multiSnapshotCounterTransducer
                        & #snapshotPolicy
                        .~ Every 3
                validatedBoundaryEventStream = mkEventStreamOrThrow "snapshot-multi-event-crosses-boundary" boundaryEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions validatedBoundaryEventStream target (Add 2)
            Right firstSnapshotVersion <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "snapshot-multi-event-crosses-boundary" snapshotVersionForStreamStmt
            firstSnapshotVersion `shouldBe` Nothing
            result <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions validatedBoundaryEventStream target (Add 3)
            case result of
                Right (Right commandResult) ->
                    commandResult ^. #streamVersion `shouldBe` StreamVersion 4
                other -> expectationFailure ("expected successful boundary-crossing command, got " <> show other)
            Right snapshotVersion <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "snapshot-multi-event-crosses-boundary" snapshotVersionForStreamStmt
            snapshotVersion `shouldBe` Just (StreamVersion 4)

        it "allows an incompatible snapshot codec to replace a higher-version row" $ \storeHandle -> do
            let target = stream "snapshot-codec-rollback-overwrite" :: Stream SnapshotCounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 1)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 4)
            Right snapshotVersionBefore <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "snapshot-codec-rollback-overwrite" snapshotVersionForStreamStmt
            snapshotVersionBefore `shouldBe` Just (StreamVersion 4)
            let rollbackCodec = defaultStateCodec @SnapshotCounterRegs @CounterState 2
            streamId <-
                Store.runStoreIO storeHandle (Store.lookupStreamId (StreamName "snapshot-codec-rollback-overwrite")) >>= \case
                    Right (Just sid) -> pure sid
                    other -> expectationFailure ("expected stream id, got " <> show other) *> error "unreachable"
            Right () <-
                Store.runStoreIO storeHandle $
                    writeSnapshotRow
                        SnapshotWrite
                            { streamId = streamId
                            , streamVersion = StreamVersion 2
                            , state = (rollbackCodec ^. #encode) (Counting, RCons (Proxy @"lastAmount") 2 RNil)
                            , stateCodecVersion = rollbackCodec ^. #stateCodecVersion
                            , regfileShapeHash = rollbackCodec ^. #shapeHash
                            }
            Right snapshotVersionAfter <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "snapshot-codec-rollback-overwrite" snapshotVersionForStreamStmt
            snapshotVersionAfter `shouldBe` Just (StreamVersion 2)

    describe "Keiro.Connection projection schema" $
        around (withFreshStoreWith fixture (withProjectionSchema "app_reads")) $ do
            it "places a read-model table in a configured schema, separate from keiro metadata" $ \storeHandle -> do
                -- qualifiedTableName builds the app's fully-qualified data table ref.
                qualifiedTableName placedReadModel `shouldBe` "\"app_reads\".\"placed_counter\""

                -- Create the app schema (opt-in) and the qualified read-model table.
                Right () <-
                    Store.runStoreIO storeHandle $ do
                        ensureProjectionSchema "app_reads"
                        Store.runTransaction initializePlacedTable

                -- Drive a command with the inline projection that writes the app table.
                let target = stream "placed-in-app-reads" :: Stream CounterEventStream
                result <-
                    Store.runStoreIO storeHandle $
                        runCommandWithProjections
                            defaultRunCommandOptions
                            counterEventStream
                            target
                            (Add 7)
                            [placedInlineProjection]
                case result of
                    Right (Right _) -> pure ()
                    other -> expectationFailure ("expected placed inline projection command, got " <> show other)

                -- Read it back through the configured-schema read model.
                queryResult <-
                    Store.runStoreIO storeHandle $
                        runQuery Nothing placedReadModel "placed"
                queryResult `shouldBe` Right (Right 7)

                -- Prove placement: the app table is in app_reads, NOT in kiroku, and
                -- Keiro's own metadata (keiro_read_models) is in the keiro schema.
                Right (inApp, inKiroku, keiroMeta) <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            (,,)
                                <$> Tx.statement ("app_reads", "placed_counter") pgTableCountStmt
                                <*> Tx.statement ("kiroku", "placed_counter") pgTableCountStmt
                                <*> Tx.statement ("keiro", "keiro_read_models") pgTableCountStmt
                inApp `shouldBe` (1 :: Int)
                inKiroku `shouldBe` (0 :: Int)
                keiroMeta `shouldBe` (1 :: Int)

    describe "Keiro.ReadModel" $ around (withFreshStore fixture) $ do
        it "queries inline projection with Eventual consistency" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            let target = stream "read-model-inline" :: Stream CounterEventStream
            result <-
                Store.runStoreIO storeHandle $
                    runCommandWithProjections
                        defaultRunCommandOptions
                        counterEventStream
                        target
                        (Add 5)
                        [counterInlineProjection]
            case result of
                Right (Right commandResult) ->
                    commandResult ^. #globalPosition `shouldSatisfy` isJust
                other -> expectationFailure ("expected inline projection command, got " <> show other)
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQuery Nothing counterReadModel "inline"
            queryResult `shouldBe` Right (Right 5)

        it "reads the minimum checkpoint across consumer-group subscription members" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $ do
                        Tx.statement ("counter-read-model-sub", 1, 7) upsertSubscriptionCursorMemberStmt
                        Tx.statement ("counter-read-model-sub", 2, 3) upsertSubscriptionCursorMemberStmt
            position <-
                Store.runStoreIO storeHandle $
                    readSubscriptionPosition "counter-read-model-sub"
            position `shouldBe` Right (Just (GlobalPosition 3))

        it "Strong returns immediately on an empty log" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQueryWith Nothing Strong counterReadModel "empty"
            queryResult `shouldBe` Right (Right 0)

        it "Strong returns immediately when the subscription is already at the store head" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            let target = stream "read-model-strong-at-head" :: Stream CounterEventStream
            Right (Right commandResult) <-
                Store.runStoreIO storeHandle $
                    runCommandWithProjections
                        defaultRunCommandOptions
                        counterEventStream
                        target
                        (Add 5)
                        [counterInlineProjection]
            globalPosition <- case commandResult ^. #globalPosition of
                Just position -> pure position
                Nothing -> expectationFailure "expected command global position" *> error "unreachable"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("counter-read-model-sub", globalPositionToInt globalPosition) upsertSubscriptionCursorStmt
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQueryWith Nothing Strong counterReadModel "inline"
            queryResult `shouldBe` Right (Right 5)

        it "Strong blocks until the subscription reaches the store head captured at query start" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            let target = stream "read-model-strong-blocking" :: Stream CounterEventStream
            Right (Right commandResult) <-
                Store.runStoreIO storeHandle $
                    runCommandWithProjections
                        defaultRunCommandOptions
                        counterEventStream
                        target
                        (Add 6)
                        [counterInlineProjection]
            globalPosition <- case commandResult ^. #globalPosition of
                Just position -> pure position
                Nothing -> expectationFailure "expected command global position" *> error "unreachable"
            _ <- forkIO $ do
                threadDelay 20000
                advanced <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Tx.statement ("counter-read-model-sub", globalPositionToInt globalPosition) upsertSubscriptionCursorStmt
                case advanced of
                    Right () -> pure ()
                    Left err -> expectationFailure ("failed to advance subscription cursor: " <> show err)
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQueryWith Nothing Strong counterReadModel "inline"
            queryResult `shouldBe` Right (Right 6)

        it "inline projection populates actor and source_event_id from command metadata" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            let target = stream "read-model-inline-metadata" :: Stream CounterEventStream
                opts =
                    defaultRunCommandOptions
                        & #metadata
                        ?~ object ["actor" Aeson..= ("agent-7" :: Text)]
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommandWithProjections opts counterEventStream target (Add 5) [counterInlineProjection]
            Right row <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement "inline" selectCounterMetaStmt)
            -- selectCounterMetaStmt returns (amount, actor, source_event_id).
            row `shouldSatisfy` \(amount, actor, srcId) ->
                amount == 5 && actor == Just "agent-7" && isJust srcId

        it "waits for async projection cursor with PositionWait" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            let target = stream "read-model-position-wait" :: Stream CounterEventStream
            Right (Right commandResult) <-
                Store.runStoreIO storeHandle $
                    runCommandWithProjections
                        defaultRunCommandOptions
                        counterEventStream
                        target
                        (Add 3)
                        [counterInlineProjection]
            globalPosition <- case commandResult ^. #globalPosition of
                Just position -> pure position
                Nothing -> expectationFailure "expected command global position" *> error "unreachable"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("counter-read-model-sub", globalPositionToInt globalPosition) upsertSubscriptionCursorStmt
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQueryWith
                        Nothing
                        (PositionWait (fastWaitOptions & #target .~ Just globalPosition))
                        counterReadModel
                        "inline"
            queryResult `shouldBe` Right (Right 3)

        it "times out when PositionWait target is not reached" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("counter-read-model-sub", 1) upsertSubscriptionCursorStmt
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQueryWith
                        Nothing
                        (PositionWait (fastWaitOptions & #target .~ Just (GlobalPosition 5)))
                        counterReadModel
                        "timeout"
            queryResult
                `shouldBe` Right
                    (Left (ReadModelWaitTimeout "counter-read-model" (GlobalPosition 5) (GlobalPosition 1)))

        it "does not write the registry row on repeated read-model queries" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            Right (Right 0) <-
                Store.runStoreIO storeHandle $
                    runQuery Nothing counterReadModel "no-churn"
            Right xminBefore <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "counter-read-model" readModelXminStmt
            Right (Right 0) <-
                Store.runStoreIO storeHandle $
                    runQuery Nothing counterReadModel "no-churn"
            Right xminAfter <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "counter-read-model" readModelXminStmt
            xminAfter `shouldBe` xminBefore

        it "handles concurrent first-time read-model registration" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            resultA <- newEmptyMVar
            resultB <- newEmptyMVar
            _ <-
                forkIO $
                    Store.runStoreIO storeHandle (runQuery Nothing counterReadModel "concurrent")
                        >>= putMVar resultA
            _ <-
                forkIO $
                    Store.runStoreIO storeHandle (runQuery Nothing counterReadModel "concurrent")
                        >>= putMVar resultB
            first <- takeMVar resultA
            second <- takeMVar resultB
            first `shouldBe` Right (Right 0)
            second `shouldBe` Right (Right 0)

        it "rejects stale read-model schema" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            Right (Right 0) <-
                Store.runStoreIO storeHandle $
                    runQuery Nothing counterReadModel "stale"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("counter-read-model", 99) updateReadModelVersionStmt
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQuery Nothing counterReadModel "stale"
            queryResult
                `shouldBe` Right
                    (Left (ReadModelStaleSchema "counter-read-model" 1 99 "counter-read-model-v1" "counter-read-model-v1"))

        it "surfaces unknown read-model statuses with the raw status text" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            Right (Right 0) <-
                Store.runStoreIO storeHandle $
                    runQuery Nothing counterReadModel "unknown-status"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("counter-read-model", "wedged") updateReadModelStatusStmt
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQuery Nothing counterReadModel "unknown-status"
            queryResult
                `shouldBe` Right
                    (Left (ReadModelNotLive "counter-read-model" (UnknownStatus "wedged")))

        it "ignores duplicate async event by source_event_id" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            let target = stream "read-model-async-idempotent" :: Stream CounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions counterEventStream target (Add 7)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "read-model-async-idempotent") (StreamVersion 0) 10
            event <- case Vector.toList recorded of
                [onlyEvent] -> pure onlyEvent
                other -> expectationFailure ("expected one event, got " <> show other) *> error "unreachable"
            Right () <- Store.runStoreIO storeHandle $
                Store.runTransaction $ do
                    applyAsyncProjection counterAsyncProjection event
                    applyAsyncProjection counterAsyncProjection event
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQuery Nothing counterReadModel "async-idempotent"
            queryResult `shouldBe` Right (Right 7)

        it "deduplicates async projection application across transactions and reopens after pruning" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeProjectionDedupCounterTable
            let target = stream "read-model-async-dedup-window" :: Stream CounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions counterEventStream target (Add 7)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "read-model-async-dedup-window") (StreamVersion 0) 10
            event <- case Vector.toList recorded of
                [onlyEvent] -> pure onlyEvent
                other -> expectationFailure ("expected one event, got " <> show other) *> error "unreachable"
            let incrementingProjection =
                    AsyncProjection
                        { name = "incrementing-async-projection"
                        , subscriptionName = "incrementing-async-projection-sub"
                        , applyRecorded = \_ -> Tx.statement () incrementProjectionDedupCounterStmt
                        , idempotencyKey = \recordedEvent -> recordedEvent ^. #eventId
                        }
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        applyAsyncProjection incrementingProjection event
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        applyAsyncProjection incrementingProjection event
            Right countAfterDuplicate <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement () selectProjectionDedupCounterStmt
            countAfterDuplicate `shouldBe` 1
            cutoff <- addUTCTime 1 <$> getCurrentTime
            pruned <- Store.runStoreIO storeHandle $ pruneAsyncProjectionDedupBefore cutoff
            pruned `shouldBe` Right 1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        applyAsyncProjection incrementingProjection event
            Right countAfterPrune <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement () selectProjectionDedupCounterStmt
            countAfterPrune `shouldBe` 2

        it "tracks rebuild state transitions" $ \storeHandle -> do
            Right rebuilding <-
                Store.runStoreIO storeHandle $
                    Rebuild.rebuild counterReadModel
            rebuilding ^. #status `shouldBe` Rebuilding
            Right live <-
                Store.runStoreIO storeHandle $
                    Rebuild.promote counterReadModel
            live ^. #status `shouldBe` Live
            Right abandoned <-
                Store.runStoreIO storeHandle $
                    Rebuild.abandonRebuild counterReadModel
            abandoned ^. #status `shouldBe` Abandoned

        it "records projection lag behind the log head" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            let target = stream "read-model-lag" :: Stream CounterEventStream
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions counterEventStream target (Add 1)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runCommand defaultRunCommandOptions counterEventStream target (Add 1)
            -- The subscription cursor is never advanced, so the read model is behind
            -- the head by every appended event: the lag gauge records that gap.
            Right () <-
                Store.runStoreIO storeHandle $
                    recordProjectionLag (Just keiroMetrics) counterAsyncProjection
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            let scalars = flattenScalarPoints exported
            case lookup "keiro.projection.lag" scalars of
                Just (IntNumber n) -> n `shouldSatisfy` (>= 1)
                other -> expectationFailure ("expected an integer projection lag, got " <> show other)

        it "counts a position-wait timeout in the timeout counter" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeCounterReadModelTable
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("counter-read-model-sub", 1) upsertSubscriptionCursorStmt
            queryResult <-
                Store.runStoreIO storeHandle $
                    runQueryWith
                        (Just keiroMetrics)
                        (PositionWait (fastWaitOptions & #target .~ Just (GlobalPosition 5)))
                        counterReadModel
                        "timeout"
            queryResult
                `shouldBe` Right
                    (Left (ReadModelWaitTimeout "counter-read-model" (GlobalPosition 5) (GlobalPosition 1)))
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            let scalars = flattenScalarPoints exported
            -- The single give-up bumped the counter exactly once.
            lookup "keiro.projection.wait.timeouts" scalars `shouldBe` Just (IntNumber 1)

    describe "Keiro.ProcessManager" $ around (withFreshStore fixture) $ do
        it "advances manager state, emits a deterministic target command once, and schedules a timer" $ \storeHandle -> do
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 9)
            result <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions counterProcessManager sourceEvent (CounterAdded 9)
            case result of
                Right (Right pmResult) -> do
                    case pmResult ^. #managerResult of
                        PMStateAppended managerResult ->
                            managerResult ^. #streamVersion `shouldBe` StreamVersion 1
                        other -> expectationFailure ("expected appended manager state, got " <> show other)
                    case pmResult ^. #commandResults of
                        [PMCommandAppended commandResult] ->
                            commandResult ^. #eventsAppended `shouldBe` 1
                        other -> expectationFailure ("expected one emitted command, got " <> show other)
                    pmResult ^. #timersScheduled `shouldBe` 1
                other -> expectationFailure ("expected process-manager success, got " <> show other)
            Right managerEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "pm:counter-order-1") (StreamVersion 0) 10
            Right targetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-target-order-1") (StreamVersion 0) 10
            Vector.length managerEvents `shouldBe` 1
            Vector.length targetEvents `shouldBe` 1
            timer <-
                Store.runStoreIO storeHandle $
                    claimDueTimer dueTimerTime
            case timer of
                Right (Just row) -> do
                    row ^. #processManagerName `shouldBe` "counter-pm"
                    row ^. #correlationId `shouldBe` "order-1"
                other -> expectationFailure ("expected scheduled timer row, got " <> show other)

        it "schedules timers when the manager command emits no events" $ \storeHandle -> do
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 9)
            result <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions timerOnlyProcessManager sourceEvent (CounterAdded 9)
            case result of
                Right (Right pmResult) -> do
                    case pmResult ^. #managerResult of
                        PMStateAppended managerResult -> do
                            managerResult ^. #streamVersion `shouldBe` StreamVersion 0
                            managerResult ^. #eventsAppended `shouldBe` 0
                        other -> expectationFailure ("expected no-op manager state, got " <> show other)
                    pmResult ^. #commandResults `shouldBe` []
                    pmResult ^. #timersScheduled `shouldBe` 1
                other -> expectationFailure ("expected process-manager success, got " <> show other)
            dueCount <-
                Store.runStoreIO storeHandle $
                    countDueTimers dueTimerTime
            dueCount `shouldBe` Right 1
            timer <-
                Store.runStoreIO storeHandle $
                    claimDueTimer dueTimerTime
            case timer of
                Right (Just row) -> do
                    row ^. #processManagerName `shouldBe` "timer-only-pm"
                    row ^. #correlationId `shouldBe` "order-1"
                other -> expectationFailure ("expected scheduled timer row, got " <> show other)

        it "treats duplicate input delivery as idempotent state and command dispatch" $ \storeHandle -> do
            let sourceEvent = recordedFromEventId (EventId sampleUuid2) (CounterAdded 4)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions counterProcessManager sourceEvent (CounterAdded 4)
            duplicate <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions counterProcessManager sourceEvent (CounterAdded 4)
            case duplicate of
                Right (Right pmResult) -> do
                    pmResult ^. #managerResult `shouldSatisfy` \case
                        PMStateDuplicate{} -> True
                        _ -> False
                    pmResult ^. #commandResults `shouldSatisfy` \case
                        [PMCommandDuplicate{}] -> True
                        _ -> False
                other -> expectationFailure ("expected idempotent duplicate handling, got " <> show other)
            Right managerEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "pm:counter-order-1") (StreamVersion 0) 10
            Right targetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-target-order-1") (StreamVersion 0) 10
            Vector.length managerEvents `shouldBe` 1
            Vector.length targetEvents `shouldBe` 1

        it "keeps multiple workflow process managers isolated by configured streams and categories" $ \storeHandle -> do
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 6)
                fulfillmentManager =
                    workflowProcessManager
                        "fulfillment-pm"
                        "pm:fulfillment"
                        "fulfillment-target-order-1"
                billingManager =
                    workflowProcessManager
                        "billing-pm"
                        "pm:billing"
                        "billing-target-order-1"
            fulfillmentResult <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions fulfillmentManager sourceEvent (CounterAdded 6)
            billingResult <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions billingManager sourceEvent (CounterAdded 6)
            assertWorkflowProcessManagerAppended fulfillmentResult
            assertWorkflowProcessManagerAppended billingResult

            Right fulfillmentManagerEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "pm:fulfillment-order-1") (StreamVersion 0) 10
            Right billingManagerEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "pm:billing-order-1") (StreamVersion 0) 10
            Right fulfillmentTargetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "fulfillment-target-order-1") (StreamVersion 0) 10
            Right billingTargetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "billing-target-order-1") (StreamVersion 0) 10
            Vector.length fulfillmentManagerEvents `shouldBe` 1
            Vector.length billingManagerEvents `shouldBe` 1
            Vector.length fulfillmentTargetEvents `shouldBe` 1
            Vector.length billingTargetEvents `shouldBe` 1

            Right fulfillmentCategoryEvents <-
                Store.runStoreIO storeHandle $
                    Store.readCategory (CategoryName "pm:fulfillment") (GlobalPosition 0) 10
            Right billingCategoryEvents <-
                Store.runStoreIO storeHandle $
                    Store.readCategory (CategoryName "pm:billing") (GlobalPosition 0) 10
            Right sharedPmCategoryEvents <-
                Store.runStoreIO storeHandle $
                    Store.readCategory (CategoryName "pm") (GlobalPosition 0) 10
            Right sharedPmNamespaceEvents <-
                Store.runStoreIO storeHandle $
                    Store.readCategory (CategoryName "pm:") (GlobalPosition 0) 10
            Vector.length fulfillmentCategoryEvents `shouldBe` 1
            Vector.length billingCategoryEvents `shouldBe` 1
            sharedPmCategoryEvents `shouldBe` Vector.empty
            sharedPmNamespaceEvents `shouldBe` Vector.empty

        it "worker finalizes AckOk through the ack handle on success" $ \storeHandle -> do
            decisionsRef <- newIORef []
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 9)
                messages = [(sourceEvent, CounterAdded 9)]
                adapter = inMemoryAdapter decisionsRef messages
            Right () <-
                Store.runStoreIO storeHandle $
                    runProcessManagerWorker defaultRunCommandOptions counterProcessManager adapter Just
            decisions <- readIORef decisionsRef
            decisions `shouldBe` [AckOk]

        it "worker halts instead of acking when a target dispatch is rejected" $ \storeHandle -> do
            decisionsRef <- newIORef []
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 9)
                messages = [(sourceEvent, CounterAdded 9)]
                adapter = inMemoryAdapter decisionsRef messages
                rejectingPm =
                    (counterProcessManager :: ProcessManager CounterEvent (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent)
                        { targetEventStream = rejectingEventStream
                        }
            Right () <-
                Store.runStoreIO storeHandle $
                    runProcessManagerWorker defaultRunCommandOptions rejectingPm adapter Just
            decisions <- readIORef decisionsRef
            decisions `shouldSatisfy` \case
                [AckHalt (HaltFatal _)] -> True
                _ -> False
            Right targetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "counter-target-order-1") (StreamVersion 0) 10
            Right managerEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "pm:counter-order-1") (StreamVersion 0) 10
            Vector.length targetEvents `shouldBe` 0
            Vector.length managerEvents `shouldBe` 1

        it "records dispatch failures through worker metrics" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            decisionsRef <- newIORef []
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 9)
                messages = [(sourceEvent, CounterAdded 9)]
                adapter = inMemoryAdapter decisionsRef messages
                rejectingPm =
                    (counterProcessManager :: ProcessManager CounterEvent (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent)
                        { targetEventStream = rejectingEventStream
                        }
                workerOptions = defaultWorkerOptions & #metrics ?~ keiroMetrics
            Right () <-
                Store.runStoreIO storeHandle $
                    runProcessManagerWorkerWith workerOptions defaultRunCommandOptions rejectingPm adapter Just
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            lookup "keiro.dispatch.failed" (flattenScalarPoints exported) `shouldBe` Just (IntNumber 1)

        it "classifies transient store failures as retry and command rejections as halt" $ \_storeHandle -> do
            ackForCommandError (RetryDelay 5) (StoreFailed (Store.ConnectionLost "boom"))
                `shouldBe` AckRetry (RetryDelay 5)
            ackForCommandError (RetryDelay 5) CommandRejected `shouldSatisfy` \case
                AckHalt (HaltFatal _) -> True
                _ -> False

        it "worker applies poison-message policy on decode failure" $ \storeHandle -> do
            let badMessages = ["not-decodable" :: Text]
            defaultDecisions <- newIORef []
            Right () <-
                Store.runStoreIO storeHandle $
                    runProcessManagerWorker
                        defaultRunCommandOptions
                        counterProcessManager
                        (inMemoryAdapter defaultDecisions badMessages)
                        (const Nothing)
            defaultObserved <- readIORef defaultDecisions
            defaultObserved `shouldSatisfy` \case
                [AckHalt (HaltFatal _)] -> True
                _ -> False

            skippedRef <- newIORef []
            skipDecisions <- newIORef []
            let skipOptions =
                    defaultWorkerOptions
                        & #poisonPolicy
                        .~ PoisonSkip (\env -> liftIO (modifyIORef' skippedRef (<> [env ^. #payload])))
            Right () <-
                Store.runStoreIO storeHandle $
                    runProcessManagerWorkerWith
                        skipOptions
                        defaultRunCommandOptions
                        counterProcessManager
                        (inMemoryAdapter skipDecisions badMessages)
                        (const Nothing)
            readIORef skipDecisions `shouldReturn` [AckOk]
            readIORef skippedRef `shouldReturn` badMessages

            deadLetterDecisions <- newIORef []
            deadLetterRef <- newIORef []
            let deadLetterOptions =
                    defaultWorkerOptions
                        & #poisonPolicy
                        .~ PoisonDeadLetter (\env -> liftIO (modifyIORef' deadLetterRef (<> [env ^. #payload])))
            Right () <-
                Store.runStoreIO storeHandle $
                    runProcessManagerWorkerWith
                        deadLetterOptions
                        defaultRunCommandOptions
                        counterProcessManager
                        (inMemoryAdapter deadLetterDecisions badMessages)
                        (const Nothing)
            deadLetterObserved <- readIORef deadLetterDecisions
            deadLetterObserved `shouldSatisfy` \case
                [AckDeadLetter (InvalidPayload _)] -> True
                _ -> False
            readIORef deadLetterRef `shouldReturn` badMessages

        it "folds a concurrent duplicate target dispatch to PMCommandDuplicate" $ \storeHandle -> do
            insertCount <- newIORef (0 :: Int)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 9)
                commandId = deterministicCommandId "counter-pm" "order-1" (sourceEvent ^. #eventId) 0
                targetStreamName = StreamName "counter-target-order-1"
                insertConcurrentTarget = do
                    callNo <- atomicModifyIORef' insertCount (\n -> (n + 1, n))
                    when (callNo == 1) $ appendCounterEventWithId storeHandle targetStreamName commandId (CounterAdded 9)
                options =
                    defaultRunCommandOptions
                        & #beforeAppend
                        .~ insertConcurrentTarget
                        & #retryBackoffMicros
                        .~ 0
            result <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce options counterProcessManager sourceEvent (CounterAdded 9)
            case result of
                Right (Right pmResult) ->
                    pmResult ^. #commandResults `shouldSatisfy` \case
                        [PMCommandDuplicate duplicateId] -> duplicateId == commandId
                        _ -> False
                other -> expectationFailure ("expected duplicate target dispatch fold, got " <> show other)
            Right targetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward targetStreamName (StreamVersion 0) 10
            Vector.length targetEvents `shouldBe` 1

        it "folds a concurrent duplicate manager-state append to PMStateDuplicate" $ \storeHandle -> do
            insertCount <- newIORef (0 :: Int)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 9)
                managerId = deterministicCommandId "counter-pm" "order-1" (sourceEvent ^. #eventId) (-1)
                managerStreamName = StreamName "pm:counter-order-1"
                insertConcurrentManager = do
                    callNo <- atomicModifyIORef' insertCount (\n -> (n + 1, n))
                    when (callNo == 0) $ appendCounterEventWithId storeHandle managerStreamName managerId (CounterAdded 9)
                options =
                    defaultRunCommandOptions
                        & #beforeAppend
                        .~ insertConcurrentManager
                        & #retryBackoffMicros
                        .~ 0
            result <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce options counterProcessManager sourceEvent (CounterAdded 9)
            case result of
                Right (Right pmResult) -> do
                    pmResult ^. #managerResult `shouldSatisfy` \case
                        PMStateDuplicate duplicateId -> duplicateId == managerId
                        _ -> False
                    pmResult ^. #commandResults `shouldSatisfy` \case
                        [PMCommandAppended{}] -> True
                        _ -> False
                other -> expectationFailure ("expected duplicate manager-state fold, got " <> show other)

    describe "Keiro.ProcessManager duplicate confirmation" $ around (withFreshStore fixture) $ do
        it "rejects a duplicate report carrying a different id" $ \storeHandle -> do
            let targetStreamName = StreamName "duplicate-confirmation-mismatch"
                ourId = EventId sampleUuid
                otherId = EventId sampleUuid2
            appendCounterEventWithId storeHandle targetStreamName otherId (CounterAdded 1)
            outcome <-
                Store.runStoreIO storeHandle $
                    confirmBenignDuplicate
                        targetStreamName
                        ourId
                        (StoreFailed (Store.DuplicateEvent (Just otherId)))
            outcome `shouldBe` Right False

        it "rejects a matching id that exists only in another stream" $ \storeHandle -> do
            let targetStreamName = StreamName "duplicate-confirmation-target"
                otherStreamName = StreamName "duplicate-confirmation-other"
                ourId = EventId sampleUuid
                targetEventId = EventId sampleUuid2
            appendCounterEventWithId storeHandle targetStreamName targetEventId (CounterAdded 1)
            appendCounterEventWithId storeHandle otherStreamName ourId (CounterAdded 1)
            outcome <-
                Store.runStoreIO storeHandle $
                    confirmBenignDuplicate
                        targetStreamName
                        ourId
                        (StoreFailed (Store.DuplicateEvent (Just ourId)))
            outcome `shouldBe` Right False

        it "confirms matching and id-less duplicate reports when the id is in the target stream" $ \storeHandle -> do
            let targetStreamName = StreamName "duplicate-confirmation-present"
                ourId = EventId sampleUuid
            appendCounterEventWithId storeHandle targetStreamName ourId (CounterAdded 1)
            matchingOutcome <-
                Store.runStoreIO storeHandle $
                    confirmBenignDuplicate
                        targetStreamName
                        ourId
                        (StoreFailed (Store.DuplicateEvent (Just ourId)))
            missingDetailOutcome <-
                Store.runStoreIO storeHandle $
                    confirmBenignDuplicate
                        targetStreamName
                        ourId
                        (StoreFailed (Store.DuplicateEvent Nothing))
            matchingOutcome `shouldBe` Right True
            missingDetailOutcome `shouldBe` Right True

        it "rejects non-duplicate command failures" $ \storeHandle -> do
            let targetStreamName = StreamName "duplicate-confirmation-non-duplicate"
                ourId = EventId sampleUuid
            appendCounterEventWithId storeHandle targetStreamName ourId (CounterAdded 1)
            outcome <-
                Store.runStoreIO storeHandle $
                    confirmBenignDuplicate
                        targetStreamName
                        ourId
                        (StoreFailed (Store.ConnectionLost "boom"))
            outcome `shouldBe` Right False

    describe "Keiro.ProcessManager snapshots" $ around (withFreshStore fixture) $ do
        it "writes a snapshot of the manager state stream after the policy threshold" $ \storeHandle -> do
            -- Two distinct source events, both correlating to "order-1", drive the one
            -- manager instance to manager-stream version 2, which Every 2 snapshots.
            let sourceA = recordedFromEventId (EventId sampleUuid) (CounterAdded 2)
                sourceB = recordedFromEventId (EventId sampleUuid2) (CounterAdded 3)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceA (CounterAdded 2)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceB (CounterAdded 3)
            Right managerEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "pm:counter-snap-order-1") (StreamVersion 0) 10
            Vector.length managerEvents `shouldBe` 2
            Right snapshotVersion <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "pm:counter-snap-order-1" snapshotVersionForStreamStmt
            snapshotVersion `shouldBe` Just (StreamVersion 2)

        it "hydrates the manager from its snapshot and replays only the tail" $ \storeHandle -> do
            -- After the threshold snapshot exists, a third reaction should land on top of
            -- the snapshot at version 3 rather than replaying from version 0.
            let sourceA = recordedFromEventId (EventId sampleUuid) (CounterAdded 2)
                sourceB = recordedFromEventId (EventId sampleUuid2) (CounterAdded 3)
                sourceC = recordedFromEventId (EventId sampleUuid3) (CounterAdded 4)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceA (CounterAdded 2)
            Right (Right _) <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceB (CounterAdded 3)
            -- Confirm the snapshot is present before the tail-replay reaction.
            Right snapshotVersion <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "pm:counter-snap-order-1" snapshotVersionForStreamStmt
            snapshotVersion `shouldBe` Just (StreamVersion 2)
            result <-
                Store.runStoreIO storeHandle $
                    runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceC (CounterAdded 4)
            case result of
                Right (Right pmResult) ->
                    case pmResult ^. #managerResult of
                        PMStateAppended managerResult ->
                            managerResult ^. #streamVersion `shouldBe` StreamVersion 3
                        other -> expectationFailure ("expected appended manager state, got " <> show other)
                other -> expectationFailure ("expected snapshot-assisted PM reaction, got " <> show other)

    describe "Keiro.Router" $ around (withFreshStore fixture) $ do
        it "encodes colon-bearing and non-ASCII id components without collisions" $ \_storeHandle -> do
            let sourceEventId = EventId sampleUuid
                colonLeft =
                    deterministicRouterCommandId
                        "router:a"
                        "key"
                        sourceEventId
                        (StreamName "target")
                        0
                colonRight =
                    deterministicRouterCommandId
                        "router"
                        "a:key"
                        sourceEventId
                        (StreamName "target")
                        0
                unicodeLeft =
                    deterministicRouterCommandId
                        "router"
                        "key"
                        sourceEventId
                        (StreamName ("target-" <> Text.singleton '\x101'))
                        0
                unicodeRight =
                    deterministicRouterCommandId
                        "router"
                        "key"
                        sourceEventId
                        (StreamName ("target-" <> Text.singleton '\x201'))
                        0
            colonLeft `shouldNotBe` colonRight
            unicodeLeft `shouldNotBe` unicodeRight

        it "resolves targets effectfully and fans out one command per target" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeRouterTargetsTable
            Right () <- Store.runStoreIO storeHandle $
                Store.runTransaction $ do
                    Tx.statement ("g1", "router-target-a") insertRouterTargetStmt
                    Tx.statement ("g1", "router-target-b") insertRouterTargetStmt
                    Tx.statement ("g1", "router-target-c") insertRouterTargetStmt
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
            Right (RouterResult rs1) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions demoRouter sourceEvent (RouteGroup "g1")
            length rs1 `shouldBe` 3
            rs1 `shouldSatisfy` all isAppended
            -- Data-dependence is load-bearing: an unseeded group resolves to no
            -- targets, so the count tracks the read model, not a fixed list.
            Right (RouterResult rsEmpty) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions demoRouter sourceEvent (RouteGroup "no-such-group")
            length rsEmpty `shouldBe` 0
            -- Each resolved target stream received exactly one command.
            Right targetA <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "router-target-a") (StreamVersion 0) 10
            Right targetB <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "router-target-b") (StreamVersion 0) 10
            Right targetC <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "router-target-c") (StreamVersion 0) 10
            Vector.length targetA `shouldBe` 1
            Vector.length targetB `shouldBe` 1
            Vector.length targetC `shouldBe` 1

        it "reports every dispatch as a duplicate on replay, writing no new events" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeRouterTargetsTable
            Right () <- Store.runStoreIO storeHandle $
                Store.runTransaction $ do
                    Tx.statement ("g1", "router-target-a") insertRouterTargetStmt
                    Tx.statement ("g1", "router-target-b") insertRouterTargetStmt
                    Tx.statement ("g1", "router-target-c") insertRouterTargetStmt
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
            Right (RouterResult rs1) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions demoRouter sourceEvent (RouteGroup "g1")
            rs1 `shouldSatisfy` all isAppended
            Right (RouterResult rs2) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions demoRouter sourceEvent (RouteGroup "g1")
            length rs2 `shouldBe` 3
            rs2 `shouldSatisfy` all isDuplicate
            -- Replay added nothing: each target stream still holds exactly one event.
            Right targetA <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "router-target-a") (StreamVersion 0) 10
            Right targetB <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "router-target-b") (StreamVersion 0) 10
            Right targetC <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "router-target-c") (StreamVersion 0) 10
            Vector.length targetA `shouldBe` 1
            Vector.length targetB `shouldBe` 1
            Vector.length targetC `shouldBe` 1

        it "dedups by target identity when a redelivered resolve reorders targets after a partial dispatch" $ \storeHandle -> do
            attemptsRef <- newIORef (0 :: Int)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                router = unstableRouter attemptsRef $ \case
                    0 -> ["swap-a"]
                    _ -> ["swap-b", "swap-a"]
            Right (RouterResult firstAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            firstAttempt `shouldSatisfy` all isAppended
            Right (RouterResult secondAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            secondAttempt `shouldSatisfy` \case
                [swapB, swapA] -> isAppended swapB && isDuplicate swapA
                _ -> False
            Right swapAEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "swap-a") (StreamVersion 0) 10
            Right swapBEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "swap-b") (StreamVersion 0) 10
            Vector.length swapAEvents `shouldBe` 1
            Vector.length swapBEvents `shouldBe` 1

        it "dispatches a target added by resolve drift instead of misreading it as a duplicate" $ \storeHandle -> do
            attemptsRef <- newIORef (0 :: Int)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                router = unstableRouter attemptsRef $ \case
                    0 -> ["growth-a", "growth-b"]
                    _ -> ["growth-a", "growth-c"]
            Right (RouterResult firstAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            firstAttempt `shouldSatisfy` all isAppended
            Right (RouterResult secondAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            secondAttempt `shouldSatisfy` \case
                [growthA, growthC] -> isDuplicate growthA && isAppended growthC
                _ -> False
            Right growthAEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "growth-a") (StreamVersion 0) 10
            Right growthBEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "growth-b") (StreamVersion 0) 10
            Right growthCEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "growth-c") (StreamVersion 0) 10
            Vector.length growthAEvents `shouldBe` 1
            Vector.length growthBEvents `shouldBe` 1
            Vector.length growthCEvents `shouldBe` 1

        it "keeps full-completion order swaps idempotent" $ \storeHandle -> do
            attemptsRef <- newIORef (0 :: Int)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                router = unstableRouter attemptsRef $ \case
                    0 -> ["order-a", "order-b"]
                    _ -> ["order-b", "order-a"]
            Right (RouterResult firstAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            firstAttempt `shouldSatisfy` all isAppended
            Right (RouterResult secondAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            secondAttempt `shouldSatisfy` all isDuplicate
            Right orderAEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "order-a") (StreamVersion 0) 10
            Right orderBEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "order-b") (StreamVersion 0) 10
            Vector.length orderAEvents `shouldBe` 1
            Vector.length orderBEvents `shouldBe` 1

        it "keeps dispatches to targets dropped by a later resolve attempt" $ \storeHandle -> do
            attemptsRef <- newIORef (0 :: Int)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                router = unstableRouter attemptsRef $ \case
                    0 -> ["drop-a", "drop-b"]
                    _ -> ["drop-b"]
            Right (RouterResult firstAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            firstAttempt `shouldSatisfy` all isAppended
            Right (RouterResult secondAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            secondAttempt `shouldSatisfy` \case
                [dropB] -> isDuplicate dropB
                _ -> False
            -- Resolve is authoritative per attempt. Across redeliveries, the
            -- dispatched set is the union of each attempt's resolved targets.
            Right dropAEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "drop-a") (StreamVersion 0) 10
            Right dropBEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "drop-b") (StreamVersion 0) 10
            Vector.length dropAEvents `shouldBe` 1
            Vector.length dropBEvents `shouldBe` 1

        it "keeps repeated commands to one target distinct within a resolve batch" $ \storeHandle -> do
            attemptsRef <- newIORef (0 :: Int)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                router = unstableRouter attemptsRef (const ["twin", "twin"])
            Right (RouterResult firstAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            firstAttempt `shouldSatisfy` all isAppended
            Right twinEventsAfterFirstAttempt <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "twin") (StreamVersion 0) 10
            Vector.length twinEventsAfterFirstAttempt `shouldBe` 2
            Right (RouterResult secondAttempt) <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions router sourceEvent (RouteGroup "g1")
            secondAttempt `shouldSatisfy` all isDuplicate
            Right twinEventsAfterSecondAttempt <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "twin") (StreamVersion 0) 10
            Vector.length twinEventsAfterSecondAttempt `shouldBe` 2

        it "drains an adapter, dispatching one command per resolved target for every message" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeRouterTargetsTable
            Right () <- Store.runStoreIO storeHandle $
                Store.runTransaction $ do
                    Tx.statement ("g1", "worker-a") insertRouterTargetStmt
                    Tx.statement ("g1", "worker-b") insertRouterTargetStmt
                    Tx.statement ("g2", "worker-c") insertRouterTargetStmt
            decisionsRef <- newIORef []
            let sourceEvent1 = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                sourceEvent2 = recordedFromEventId (EventId sampleUuid2) (CounterAdded 1)
                messages =
                    [ (sourceEvent1, RouteGroup "g1")
                    , (sourceEvent2, RouteGroup "g2")
                    ]
                adapter = inMemoryAdapter decisionsRef messages
            Right () <-
                Store.runStoreIO storeHandle $
                    runRouterWorker defaultRunCommandOptions demoRouter adapter Just
            decisions <- readIORef decisionsRef
            decisions `shouldBe` [AckOk, AckOk]
            Right wa <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "worker-a") (StreamVersion 0) 10
            Right wb <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "worker-b") (StreamVersion 0) 10
            Right wc <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "worker-c") (StreamVersion 0) 10
            Vector.length wa `shouldBe` 1
            Vector.length wb `shouldBe` 1
            Vector.length wc `shouldBe` 1

        it "finalizes AckHalt rather than AckOk when a dispatched command fails" $ \storeHandle -> do
            decisionsRef <- newIORef []
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                messages = [(sourceEvent, RouteGroup "g1")]
                adapter = inMemoryAdapter decisionsRef messages
            Right () <-
                Store.runStoreIO storeHandle $
                    runRouterWorker defaultRunCommandOptions failingRouter adapter Just
            decisions <- readIORef decisionsRef
            decisions `shouldSatisfy` \case
                [AckHalt (HaltFatal _)] -> True
                _ -> False

        it "finalizes AckRetry for a transient thrown resolver error and continues" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeRouterTargetsTable
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement ("g2", "worker-after-retry") insertRouterTargetStmt)
            decisionsRef <- newIORef []
            attemptsRef <- newIORef (0 :: Int)
            let sourceEvent1 = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                sourceEvent2 = recordedFromEventId (EventId sampleUuid2) (CounterAdded 1)
                messages = [(sourceEvent1, RouteGroup "g1"), (sourceEvent2, RouteGroup "g2")]
                adapter = inMemoryAdapter decisionsRef messages
                flakyRouter ::
                    (IOE :> es, Store :> es, Error Store.StoreError :> es) =>
                    Router RouteGroup (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent es
                flakyRouter =
                    Router
                        { name = "flaky-router"
                        , key = \(RouteGroup g) -> g
                        , resolve = \(RouteGroup g) -> do
                            attempt <- liftIO (atomicModifyIORef' attemptsRef (\n -> (n + 1, n)))
                            if attempt == 0
                                then throwError (Store.ConnectionLost "injected")
                                else do
                                    result <- runQuery Nothing routerTargetsReadModel g
                                    pure $ case result of
                                        Right targetIds ->
                                            [ PMCommand{target = stream targetId, command = Add 1}
                                            | targetId <- targetIds
                                            ]
                                        Left _ -> []
                        , targetEventStream = counterEventStream
                        , targetProjections = const []
                        }
            Right () <-
                Store.runStoreIO storeHandle $
                    runRouterWorker defaultRunCommandOptions flakyRouter adapter Just
            decisions <- readIORef decisionsRef
            decisions `shouldSatisfy` \case
                [AckRetry{}, AckOk] -> True
                _ -> False

        it "finalizes AckHalt for a deterministic thrown resolver error" $ \storeHandle -> do
            decisionsRef <- newIORef []
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                messages = [(sourceEvent, RouteGroup "g1")]
                adapter = inMemoryAdapter decisionsRef messages
                failingResolveRouter ::
                    (Error Store.StoreError :> es) =>
                    Router RouteGroup (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent es
                failingResolveRouter =
                    Router
                        { name = "failing-resolve-router"
                        , key = \(RouteGroup g) -> g
                        , resolve = \_ -> throwError (Store.UnexpectedServerError "XX000" "boom")
                        , targetEventStream = counterEventStream
                        , targetProjections = const []
                        }
            Right () <-
                Store.runStoreIO storeHandle $
                    runRouterWorker defaultRunCommandOptions failingResolveRouter adapter Just
            decisions <- readIORef decisionsRef
            decisions `shouldSatisfy` \case
                [AckHalt (HaltFatal _)] -> True
                _ -> False

        it "folds a concurrent duplicate router dispatch to PMCommandDuplicate" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeRouterTargetsTable
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement ("g1", "router-duplicate-target") insertRouterTargetStmt)
            insertCount <- newIORef (0 :: Int)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                targetStreamName = StreamName "router-duplicate-target"
                commandId =
                    deterministicRouterCommandId
                        "demo-router"
                        "g1"
                        (sourceEvent ^. #eventId)
                        targetStreamName
                        0
                insertConcurrentTarget = do
                    callNo <- atomicModifyIORef' insertCount (\n -> (n + 1, n))
                    when (callNo == 0) $ appendCounterEventWithId storeHandle targetStreamName commandId (CounterAdded 1)
                options =
                    defaultRunCommandOptions
                        & #beforeAppend
                        .~ insertConcurrentTarget
                        & #retryBackoffMicros
                        .~ 0
            result <-
                Store.runStoreIO storeHandle $
                    runRouterOnce options demoRouter sourceEvent (RouteGroup "g1")
            case result of
                Right (RouterResult [PMCommandDuplicate duplicateId]) ->
                    duplicateId `shouldBe` commandId
                other -> expectationFailure ("expected duplicate router dispatch fold, got " <> show other)
            Right targetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward targetStreamName (StreamVersion 0) 10
            Vector.length targetEvents `shouldBe` 1

        it "dedups a pre-upgrade positional router dispatch during the transition" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction initializeRouterTargetsTable
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement ("g1", "transition-target") insertRouterTargetStmt)
            let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 1)
                legacyId = deterministicCommandId "demo-router" "g1" (sourceEvent ^. #eventId) 0
                targetStreamName = StreamName "transition-target"
            appendCounterEventWithId storeHandle targetStreamName legacyId (CounterAdded 1)
            result <-
                Store.runStoreIO storeHandle $
                    runRouterOnce defaultRunCommandOptions demoRouter sourceEvent (RouteGroup "g1")
            case result of
                Right (RouterResult [PMCommandDuplicate duplicateId]) ->
                    duplicateId `shouldBe` legacyId
                other -> expectationFailure ("expected transition duplicate, got " <> show other)
            Right targetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward targetStreamName (StreamVersion 0) 10
            Vector.length targetEvents `shouldBe` 1

    describe "Keiro.Timer" $ around (withFreshStore fixture) $ do
        it "validates worker options before startup" $ \_storeHandle -> do
            shouldBeRight_ (mkTimerWorkerOptions defaultTimerWorkerOptions)
            mkTimerWorkerOptions (defaultTimerWorkerOptions & #maxAttempts ?~ (-1))
                `shouldBeLeft` InvalidTimerMaxAttempts (-1)
            mkTimerWorkerOptions (defaultTimerWorkerOptions & #requeueStuckAfter ?~ 0)
                `shouldBeLeft` InvalidTimerRequeueStuckAfter 0

        it "claims a due timer, fires a command, and marks it complete once" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            let firedEventId = EventId sampleUuid2
            workerResult <- Store.runStoreIO storeHandle $
                runTimerWorker Nothing dueTimerTime $ \_ -> do
                    fired <-
                        runCommand
                            (defaultRunCommandOptions & #eventIds .~ [firedEventId])
                            counterEventStream
                            (stream "timer-target")
                            (Add 11)
                    case fired of
                        Right _ -> pure (Just firedEventId)
                        Left err -> liftIO (expectationFailure ("expected timer command to fire, got " <> show err)) *> pure Nothing
            case workerResult of
                Right (Just timer) ->
                    timer ^. #status `shouldBe` Firing
                other -> expectationFailure ("expected fired timer, got " <> show other)
            secondWorkerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorker Nothing dueTimerTime (\_ -> pure (Just firedEventId))
            secondWorkerResult `shouldBe` Right Nothing
            Right targetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "timer-target") (StreamVersion 0) 10
            fmap (^. #eventId) (Vector.toList targetEvents) `shouldBe` [firedEventId]

        it "records timer backlog, fire lag, attempts, and stuck count" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            let firedEventId = EventId sampleUuid2
            workerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorker (Just keiroMetrics) dueTimerTime (\_ -> pure (Just firedEventId))
            case workerResult of
                Right (Just _) -> pure ()
                other -> expectationFailure ("expected a fired timer, got " <> show other)
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            let scalars = flattenScalarPoints exported
                hists = flattenHistogramPoints exported
            -- One scheduled+due row at the start of the pass: backlog gauge holds 1.
            lookup "keiro.timer.backlog" scalars `shouldBe` Just (IntNumber 1)
            -- Nothing was stranded in 'firing' before this pass: stuck gauge holds 0.
            lookup "keiro.timer.stuck" scalars `shouldBe` Just (IntNumber 0)
            -- The claimed timer was due exactly at 'now' and is on its first attempt:
            -- one fire.lag observation of 0 ms and one attempts observation of 1.
            [(c, s) | (n, c, s) <- hists, n == "keiro.timer.fire.lag"] `shouldBe` [(1, 0.0)]
            [(c, s) | (n, c, s) <- hists, n == "keiro.timer.attempts"] `shouldBe` [(1, 1.0)]

        it "finds a firing timer with findStuckTimers and requeues it for re-firing" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            -- Strand it in Firing by claiming without firing.
            claimed <- Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime
            case claimed of
                Right (Just timer) -> timer ^. #status `shouldBe` Firing
                other -> expectationFailure ("expected a claimed timer, got " <> show other)
            -- It surfaces as stuck under the permissive filter.
            Right stuck <-
                Store.runStoreIO storeHandle $
                    findStuckTimers dueTimerTime anyStuckTimer
            fmap (^. #timerId) stuck `shouldBe` [counterTimerRequest ^. #timerId]
            -- A bound it does not meet (only one attempt) excludes it.
            Right unmatched <-
                Store.runStoreIO storeHandle $
                    findStuckTimers dueTimerTime (StuckTimerFilter Nothing (Just 5))
            unmatched `shouldBe` []
            -- Requeue is idempotent: True the first time, False once it is scheduled.
            requeued <-
                Store.runStoreIO storeHandle $
                    requeueStuckTimer (counterTimerRequest ^. #timerId)
            requeued `shouldBe` Right True
            requeuedAgain <-
                Store.runStoreIO storeHandle $
                    requeueStuckTimer (counterTimerRequest ^. #timerId)
            requeuedAgain `shouldBe` Right False
            -- The ordinary loop re-claims and fires it exactly once.
            let firedEventId = EventId sampleUuid2
            workerResult <- Store.runStoreIO storeHandle $
                runTimerWorker Nothing dueTimerTime $ \_ -> do
                    fired <-
                        runCommand
                            (defaultRunCommandOptions & #eventIds .~ [firedEventId])
                            counterEventStream
                            (stream "timer-target")
                            (Add 7)
                    case fired of
                        Right _ -> pure (Just firedEventId)
                        Left err -> liftIO (expectationFailure ("expected timer command to fire, got " <> show err)) *> pure Nothing
            case workerResult of
                Right (Just timer) ->
                    timer ^. #status `shouldBe` Firing
                other -> expectationFailure ("expected re-fired timer, got " <> show other)
            secondWorkerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorker Nothing dueTimerTime (\_ -> pure (Just firedEventId))
            secondWorkerResult `shouldBe` Right Nothing
            Right targetEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "timer-target") (StreamVersion 0) 10
            fmap (^. #eventId) (Vector.toList targetEvents) `shouldBe` [firedEventId]

        it "re-fires a timer stranded by a crashed worker" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            Right (Just claimed) <- Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime
            claimed ^. #status `shouldBe` Firing
            realNow <- getCurrentTime
            firedRef <- newIORef []
            let futureNow = addUTCTime 400 realNow
                firedEventId = EventId sampleUuid2
            workerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorker Nothing futureNow $ \timer -> do
                        liftIO (modifyIORef' firedRef (<> [timer ^. #timerId]))
                        pure (Just firedEventId)
            case workerResult of
                Right (Just timer) -> timer ^. #timerId `shouldBe` counterTimerRequest ^. #timerId
                other -> expectationFailure ("expected stale timer to be requeued and claimed, got " <> show other)
            firedTimers <- readIORef firedRef
            firedTimers `shouldBe` [counterTimerRequest ^. #timerId]
            Right statusRow <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement sampleUuid timerStatusAndErrorStmt
            statusRow `shouldBe` Just ("fired", Nothing)
            secondWorkerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorker Nothing futureNow (\_ -> pure (Just firedEventId))
            secondWorkerResult `shouldBe` Right Nothing

        it "does not requeue a fresh firing row" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            Right (Just _) <- Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime
            realNow <- getCurrentTime
            firedRef <- newIORef False
            workerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorker Nothing realNow $ \_ -> do
                        liftIO (writeIORef firedRef True)
                        pure (Just (EventId sampleUuid2))
            workerResult `shouldBe` Right Nothing
            didFire <- readIORef firedRef
            didFire `shouldBe` False
            Right statusRow <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement sampleUuid timerStatusAndErrorStmt
            statusRow `shouldBe` Just ("firing", Nothing)

        it "requeueStuckAfter = Nothing preserves a stranded firing row" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            Right (Just _) <- Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime
            realNow <- getCurrentTime
            firedRef <- newIORef False
            let opts = defaultTimerWorkerOptions & #requeueStuckAfter .~ Nothing
            workerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorkerWith Nothing opts (addUTCTime 400 realNow) $ \_ -> do
                        liftIO (writeIORef firedRef True)
                        pure (Just (EventId sampleUuid2))
            workerResult `shouldBe` Right Nothing
            didFire <- readIORef firedRef
            didFire `shouldBe` False
            Right statusRow <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement sampleUuid timerStatusAndErrorStmt
            statusRow `shouldBe` Just ("firing", Nothing)

        it "does not claim a cancelled timer" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            cancelled <-
                Store.runStoreIO storeHandle $
                    cancelTimer (counterTimerRequest ^. #timerId)
            cancelled `shouldBe` Right True
            claimed <- Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime
            claimed `shouldBe` Right Nothing
            cancelledAgain <-
                Store.runStoreIO storeHandle $
                    cancelTimer (counterTimerRequest ^. #timerId)
            cancelledAgain `shouldBe` Right False

        it "dead-letters a timer that exceeds the attempt ceiling and never reclaims it" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            firedRef <- newIORef False
            let firedEventId = EventId sampleUuid2
            -- maxAttempts = Just 0: the first claim sets attempts = 1 > 0, so the
            -- worker dead-letters instead of firing.
            result <- Store.runStoreIO storeHandle $
                runTimerWorkerWith Nothing (defaultTimerWorkerOptions & #maxAttempts .~ Just 0) dueTimerTime $ \_ -> do
                    liftIO (writeIORef firedRef True)
                    pure (Just firedEventId)
            case result of
                Right (Just timer) ->
                    timer ^. #status `shouldBe` Firing
                other -> expectationFailure ("expected a claimed timer, got " <> show other)
            -- The fire action never ran.
            didFire <- readIORef firedRef
            didFire `shouldBe` False
            -- The row landed in 'dead' with the expected reason in last_error.
            Right statusRow <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement sampleUuid timerStatusAndErrorStmt
            statusRow `shouldBe` Just ("dead", Just "timer exceeded attempt ceiling of 0")
            -- A dead row is never re-claimed.
            secondWorkerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorker Nothing dueTimerTime (\_ -> pure (Just firedEventId))
            secondWorkerResult `shouldBe` Right Nothing

        it "markTimerFired does not resurrect a dead timer" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            Right (Just _) <- Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime
            deadened <-
                Store.runStoreIO storeHandle $
                    deadLetterTimer (counterTimerRequest ^. #timerId) "operator dead-letter"
            deadened `shouldBe` Right True
            marked <-
                Store.runStoreIO storeHandle $
                    markTimerFired (counterTimerRequest ^. #timerId) (EventId sampleUuid2)
            marked `shouldBe` Right False
            Right statusRow <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement sampleUuid timerStatusAndErrorStmt
            statusRow `shouldBe` Just ("dead", Just "operator dead-letter")

        it "records a row stranded in Firing in the stuck gauge" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        scheduleTimerTx counterTimerRequest
            -- Strand it in Firing by claiming without firing (a crashed worker).
            Right (Just _) <- Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime
            -- A later pass finds nothing scheduled and due, but sees the stranded row.
            workerResult <-
                Store.runStoreIO storeHandle $
                    runTimerWorker (Just keiroMetrics) dueTimerTime (\_ -> pure Nothing)
            workerResult `shouldBe` Right Nothing
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            let scalars = flattenScalarPoints exported
            -- The one firing row is counted as stuck.
            lookup "keiro.timer.stuck" scalars `shouldBe` Just (IntNumber 1)
            -- It is not 'scheduled', so it does not show up as backlog.
            lookup "keiro.timer.backlog" scalars `shouldBe` Just (IntNumber 0)

    describe "Keiro.Outbox.Kafka" $ do
        it "converts an outbox row to a Kafka producer record" $ do
            let envelope = sampleIntegrationEnvelope
                row = sampleOutboxRow envelope
                record = OutboxKafka.outboxRowToKafkaRecord row
            record ^. #topic `shouldBe` envelope ^. #destination
            record ^. #key `shouldBe` Just "order-123"
            record ^. #payload `shouldBe` envelope ^. #payloadBytes
            -- Headers include identity fields and content type.
            let headers = record ^. #headers
                messageIdHeader = Prelude.lookup "keiro-message-id" headers
            messageIdHeader `shouldBe` Just "018f0f18-17aa-7000-8000-0000000000aa"

        it "drops the partition key when the envelope has no key" $ do
            let envelope = sampleIntegrationEnvelope & #key .~ Nothing
                record = OutboxKafka.integrationEventToKafkaRecord envelope
            record ^. #key `shouldBe` Nothing

    describe "Keiro.Outbox" $ around (withFreshStore fixture) $ do
        it "validates publisher options before startup" $ \_storeHandle -> do
            shouldBeRight_ (mkOutboxPublishOptions defaultPublishOptions)
            mkOutboxPublishOptions (defaultPublishOptions & #batchSize .~ 0)
                `shouldBeLeft` InvalidOutboxBatchSize 0
            mkOutboxPublishOptions (defaultPublishOptions & #maxAttempts .~ 0)
                `shouldBeLeft` InvalidOutboxMaxAttempts 0
            mkOutboxPublishOptions (defaultPublishOptions & #publishingTimeout .~ 0)
                `shouldBeLeft` InvalidOutboxPublishingTimeout 0
            mkOutboxPublishOptions (defaultPublishOptions & #backoff .~ ConstantBackoff (-1))
                `shouldBeLeft` InvalidConstantBackoff (-1)
            mkOutboxPublishOptions
                ( defaultPublishOptions
                    & #backoff
                    .~ ExponentialBackoff
                        ExponentialBackoffOptions
                            { initial = 0
                            , maxDelay = 1
                            , multiplier = 2
                            }
                )
                `shouldBeLeft` InvalidExponentialBackoffInitial 0
            mkOutboxPublishOptions
                ( defaultPublishOptions
                    & #backoff
                    .~ ExponentialBackoff
                        ExponentialBackoffOptions
                            { initial = 1
                            , maxDelay = 10
                            , multiplier = 0.5
                            }
                )
                `shouldBeLeft` InvalidExponentialBackoffMultiplier 0.5
            mkOutboxPublishOptions
                ( defaultPublishOptions
                    & #backoff
                    .~ ExponentialBackoff
                        ExponentialBackoffOptions
                            { initial = 5
                            , maxDelay = 4
                            , multiplier = 2
                            }
                )
                `shouldBeLeft` InvalidExponentialBackoffMaxDelay 5 4

        it "enqueues and looks up an outbox row" $ \storeHandle -> do
            let envelope = sampleIntegrationEnvelope
                oid = OutboxId outboxUuid1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid envelope)
            lookedUp <- Store.runStoreIO storeHandle (lookupOutbox oid)
            case lookedUp of
                Right (Just row) -> do
                    row ^. #outboxId `shouldBe` oid
                    row ^. #status `shouldBe` OutboxPending
                    row ^. #attemptCount `shouldBe` 0
                    row ^. #event . #messageId `shouldBe` envelope ^. #messageId
                    row ^. #event . #destination `shouldBe` envelope ^. #destination
                    row ^. #event . #payloadBytes `shouldBe` envelope ^. #payloadBytes
                other -> expectationFailure ("expected enqueued row, got " <> show other)

        it "claims a pending row, transitions it to publishing, and increments attempt count" $ \storeHandle -> do
            let oid = OutboxId outboxUuid1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
            now <- getCurrentTime
            Right rows <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            case rows of
                [row] -> do
                    row ^. #outboxId `shouldBe` oid
                    row ^. #status `shouldBe` OutboxPublishing
                    row ^. #attemptCount `shouldBe` 1
                other -> expectationFailure ("expected one claimed row, got " <> show other)

        it "claims contiguous per-key runs in one pass" $ \storeHandle -> do
            let keyedRows =
                    [ (outboxIdFromOrdinal 1, sampleIntegrationEnvelope & #messageId .~ "run-a1" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 2, sampleIntegrationEnvelope & #messageId .~ "run-a2" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 3, sampleIntegrationEnvelope & #messageId .~ "run-a3" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 4, sampleIntegrationEnvelope & #messageId .~ "run-a4" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 5, sampleIntegrationEnvelope & #messageId .~ "run-a5" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 6, sampleIntegrationEnvelope & #messageId .~ "run-b1" & #key .~ Just "B")
                    , (outboxIdFromOrdinal 7, sampleIntegrationEnvelope & #messageId .~ "run-b2" & #key .~ Just "B")
                    , (outboxIdFromOrdinal 8, sampleIntegrationEnvelope & #messageId .~ "run-b3" & #key .~ Just "B")
                    ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) keyedRows
            now <- getCurrentTime
            Right rows <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            fmap (^. #outboxId) rows `shouldBe` fmap fst keyedRows
            fmap (^. #attemptCount) rows `shouldBe` replicate 8 1

        it "does not let a backoff head starve other keys" $ \storeHandle -> do
            let a1Id = outboxIdFromOrdinal 1
                a2Id = outboxIdFromOrdinal 2
                b1Id = outboxIdFromOrdinal 3
                b2Id = outboxIdFromOrdinal 4
                rows =
                    [ (a1Id, sampleIntegrationEnvelope & #messageId .~ "backoff-a1" & #key .~ Just "A")
                    , (a2Id, sampleIntegrationEnvelope & #messageId .~ "backoff-a2" & #key .~ Just "A")
                    , (b1Id, sampleIntegrationEnvelope & #messageId .~ "backoff-b1" & #key .~ Just "B")
                    , (b2Id, sampleIntegrationEnvelope & #messageId .~ "backoff-b2" & #key .~ Just "B")
                    ]
                failA1 row
                    | row ^. #outboxId == a1Id = pure (PublishFailed "wait")
                    | otherwise = pure PublishSucceeded
                opts =
                    defaultPublishOptions
                        & #batchSize
                        .~ 1
                        & #backoff
                        .~ ConstantBackoff 3600
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            Right failedPass <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow failA1) opts Nothing)
            failedPass ^. #retried `shouldBe` 1
            now <- getCurrentTime
            Right claimed <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            fmap (^. #outboxId) claimed `shouldBe` [b1Id, b2Id]
            Right (Just a2Row) <- Store.runStoreIO storeHandle (lookupOutbox a2Id)
            a2Row ^. #status `shouldBe` OutboxPending

        it "claims contiguous per-source runs in one pass" $ \storeHandle -> do
            let rows =
                    [ (outboxIdFromOrdinal 1, sampleIntegrationEnvelope & #messageId .~ "source-a1" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 2, sampleIntegrationEnvelope & #messageId .~ "source-b1" & #key .~ Just "B")
                    , (outboxIdFromOrdinal 3, sampleIntegrationEnvelope & #messageId .~ "source-a2" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 4, sampleIntegrationEnvelope & #messageId .~ "source-b2" & #key .~ Just "B")
                    ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            now <- getCurrentTime
            Right claimed <- Store.runStoreIO storeHandle (claimOutboxBatch PerSourceStream 10 now)
            fmap (^. #outboxId) claimed `shouldBe` fmap fst rows

        it "claims null-keyed rows freely alongside keyed runs" $ \storeHandle -> do
            let rows =
                    [ (outboxIdFromOrdinal 1, sampleIntegrationEnvelope & #messageId .~ "null-1" & #key .~ Nothing)
                    , (outboxIdFromOrdinal 2, sampleIntegrationEnvelope & #messageId .~ "keyed-1" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 3, sampleIntegrationEnvelope & #messageId .~ "null-2" & #key .~ Nothing)
                    , (outboxIdFromOrdinal 4, sampleIntegrationEnvelope & #messageId .~ "keyed-2" & #key .~ Just "A")
                    ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            now <- getCurrentTime
            Right claimed <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            fmap (^. #outboxId) claimed `shouldBe` fmap fst rows

        it "does not claim a tail while the previous run is still publishing" $ \storeHandle -> do
            let rows =
                    [ (outboxIdFromOrdinal 1, sampleIntegrationEnvelope & #messageId .~ "publishing-a1" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 2, sampleIntegrationEnvelope & #messageId .~ "publishing-a2" & #key .~ Just "A")
                    , (outboxIdFromOrdinal 3, sampleIntegrationEnvelope & #messageId .~ "publishing-a3" & #key .~ Just "A")
                    ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            now <- getCurrentTime
            Right firstClaim <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            fmap (^. #outboxId) firstClaim `shouldBe` fmap fst rows
            Right secondClaim <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            secondClaim `shouldBe` []

        it "marks a claimed row as sent with published_at set" $ \storeHandle -> do
            let oid = OutboxId outboxUuid1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
            now <- getCurrentTime
            Right [_] <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            Right True <- Store.runStoreIO storeHandle (markOutboxSent oid now)
            Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            row ^. #status `shouldBe` OutboxSent
            row ^. #publishedAt `shouldSatisfy` isJust
            row ^. #lastError `shouldBe` Nothing

        it "reclaims a row stranded in publishing by a crashed worker through maintenance" $ \storeHandle -> do
            let oid = OutboxId outboxUuid1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
            now <- getCurrentTime
            let pastNow = addUTCTime (-3600) now
            Right [_] <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            Right () <- Store.runStoreIO storeHandle (backdateOutboxUpdatedAt oid pastNow)
            Right (Just stranded) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            stranded ^. #status `shouldBe` OutboxPublishing
            publishedRef <- newIORef (0 :: Int)
            let publish _ = do
                    liftIO (modifyIORef' publishedRef (+ 1))
                    pure PublishSucceeded
            Right noPublish <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) defaultPublishOptions Nothing)
            noPublish ^. #claimed `shouldBe` 0
            Right (Just stillStranded) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            stillStranded ^. #status `shouldBe` OutboxPublishing
            Right maintenance <- Store.runStoreIO storeHandle (outboxMaintenancePass defaultMaintenanceOptions Nothing)
            maintenance ^. #requeued `shouldBe` 1
            maintenance ^. #deadLettered `shouldBe` 0
            Right summary <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) defaultPublishOptions Nothing)
            summary ^. #published `shouldBe` 1
            published <- readIORef publishedRef
            published `shouldBe` 1
            Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            row ^. #status `shouldBe` OutboxSent

        it "head-of-line traffic unwedges after reclaim" $ \storeHandle -> do
            let firstId = OutboxId outboxUuid1
                secondId = OutboxId outboxUuid2
                first = sampleIntegrationEnvelope & #messageId .~ "stuck-first" & #key .~ Just "same-key"
                second = sampleIntegrationEnvelope & #messageId .~ "stuck-second" & #key .~ Just "same-key"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx firstId first)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx secondId second)
            now <- getCurrentTime
            let pastNow = addUTCTime (-3600) now
            Right [claimedFirst] <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 1 now)
            claimedFirst ^. #outboxId `shouldBe` firstId
            Right () <- Store.runStoreIO storeHandle (backdateOutboxUpdatedAt firstId pastNow)
            publishedRef <- newIORef []
            let publish row = do
                    liftIO (modifyIORef' publishedRef (<> [row ^. #outboxId]))
                    pure PublishSucceeded
            Right maintenance <- Store.runStoreIO storeHandle (outboxMaintenancePass defaultMaintenanceOptions Nothing)
            maintenance ^. #requeued `shouldBe` 1
            Right firstPass <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) defaultPublishOptions Nothing)
            firstPass ^. #published `shouldBe` 2
            Right secondPass <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) defaultPublishOptions Nothing)
            secondPass ^. #published `shouldBe` 0
            published <- readIORef publishedRef
            published `shouldBe` [firstId, secondId]
            Right (Just secondRow) <- Store.runStoreIO storeHandle (lookupOutbox secondId)
            secondRow ^. #status `shouldBe` OutboxSent

        it "does not reclaim a recently claimed row" $ \storeHandle -> do
            let oid = OutboxId outboxUuid1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
            now <- getCurrentTime
            Right [_] <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            publishedRef <- newIORef (0 :: Int)
            let publish _ = do
                    liftIO (modifyIORef' publishedRef (+ 1))
                    pure PublishSucceeded
            Right summary <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) defaultPublishOptions Nothing)
            summary ^. #claimed `shouldBe` 0
            published <- readIORef publishedRef
            published `shouldBe` 0
            Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            row ^. #status `shouldBe` OutboxPublishing

        it "a throwing batch publish callback fails every row in that publish call" $ \storeHandle -> do
            let throwId = OutboxId outboxUuid1
                okId = OutboxId outboxUuid2
                throwEvent = sampleIntegrationEnvelope & #messageId .~ "throwing-publish" & #key .~ Just "throw-key"
                okEvent = sampleIntegrationEnvelope & #messageId .~ "ok-after-throw" & #key .~ Just "ok-key"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx throwId throwEvent)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx okId okEvent)
            let publish row
                    | row ^. #outboxId == throwId = liftIO (throwIO (userError "kafka exploded"))
                    | otherwise = pure PublishSucceeded
            Right summary <-
                Store.runStoreIO storeHandle $
                    publishClaimedOutbox (perRow publish) (defaultPublishOptions & #backoff .~ ConstantBackoff 0) Nothing
            summary ^. #retried `shouldBe` 2
            summary ^. #published `shouldBe` 0
            Right (Just throwRow) <- Store.runStoreIO storeHandle (lookupOutbox throwId)
            throwRow ^. #status `shouldBe` OutboxFailed
            throwRow ^. #lastError `shouldSatisfy` maybe False (Text.isInfixOf "kafka exploded")
            Right (Just okRow) <- Store.runStoreIO storeHandle (lookupOutbox okId)
            okRow ^. #status `shouldBe` OutboxFailed
            okRow ^. #lastError `shouldSatisfy` maybe False (Text.isInfixOf "kafka exploded")

        it "a row that exhausts attempts while crash-looping is dead-lettered by maintenance" $ \storeHandle -> do
            let oid = OutboxId outboxUuid1
                opts = defaultMaintenanceOptions & #maxAttempts .~ 1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
            now <- getCurrentTime
            let pastNow = addUTCTime (-3600) now
            Right [_] <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            Right () <- Store.runStoreIO storeHandle (backdateOutboxUpdatedAt oid pastNow)
            Right summary <- Store.runStoreIO storeHandle (outboxMaintenancePass opts Nothing)
            summary ^. #requeued `shouldBe` 0
            summary ^. #deadLettered `shouldBe` 1
            Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            row ^. #status `shouldBe` OutboxDead

        it "markOutboxSent does not resurrect a dead row" $ \storeHandle -> do
            let oid = OutboxId outboxUuid1
                opts = defaultPublishOptions & #maxAttempts .~ 1 & #backoff .~ ConstantBackoff 0
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
            let publish _ = pure (PublishFailed "boom")
            Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) opts Nothing)
            now <- getCurrentTime
            Right marked <- Store.runStoreIO storeHandle (markOutboxSent oid now)
            marked `shouldBe` False
            Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            row ^. #status `shouldBe` OutboxDead

        it "publishClaimedOutbox marks success and records failures with last_error" $ \storeHandle -> do
            let okId = OutboxId outboxUuid1
                failId = OutboxId outboxUuid2
                okEvent = sampleIntegrationEnvelope
                failEvent =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "msg-fail-1"
                        & #key
                        .~ Just "order-789"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx okId okEvent)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx failId failEvent)
            let publish row
                    | row ^. #outboxId == okId = pure PublishSucceeded
                    | otherwise = pure (PublishFailed "broker unreachable")
            Right summary <-
                Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) defaultPublishOptions Nothing)
            summary ^. #claimed `shouldBe` 2
            summary ^. #published `shouldBe` 1
            summary ^. #retried `shouldBe` 1
            summary ^. #dead `shouldBe` 0
            Right (Just okRow) <- Store.runStoreIO storeHandle (lookupOutbox okId)
            okRow ^. #status `shouldBe` OutboxSent
            Right (Just failRow) <- Store.runStoreIO storeHandle (lookupOutbox failId)
            failRow ^. #status `shouldBe` OutboxFailed
            failRow ^. #lastError `shouldBe` Just "broker unreachable"

        it "publishClaimedOutbox hands a same-key run to one batch publish call" $ \storeHandle -> do
            let rows =
                    [ (outboxIdFromOrdinal (fromIntegral i), sampleIntegrationEnvelope & #messageId .~ ("batch-ok-" <> Text.pack (show i)) & #key .~ Just "batch-key")
                    | i <- [1 .. 10 :: Int]
                    ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            invocationRef <- newIORef (0 :: Int)
            let publish claimed = do
                    liftIO (modifyIORef' invocationRef (+ 1))
                    pure [(row ^. #outboxId, PublishSucceeded) | row <- claimed]
            Right summary <- Store.runStoreIO storeHandle (publishClaimedOutbox publish defaultPublishOptions Nothing)
            summary ^. #claimed `shouldBe` 10
            summary ^. #published `shouldBe` 10
            invocations <- readIORef invocationRef
            invocations `shouldBe` 1
            for_ (fmap fst rows) $ \oid -> do
                Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
                row ^. #status `shouldBe` OutboxSent

        it "publishClaimedOutbox skips the same-key suffix after a mid-run failure" $ \storeHandle -> do
            let row1Id = outboxIdFromOrdinal 1
                row2Id = outboxIdFromOrdinal 2
                row3Id = outboxIdFromOrdinal 3
                row4Id = outboxIdFromOrdinal 4
                row5Id = outboxIdFromOrdinal 5
                ids = [row1Id, row2Id, row3Id, row4Id, row5Id]
                rows =
                    [ (oid, sampleIntegrationEnvelope & #messageId .~ ("batch-fail-" <> Text.pack (show i)) & #key .~ Just "batch-fail-key")
                    | (i, oid) <- zip [1 .. 5 :: Int] ids
                    ]
                publish claimed =
                    pure
                        [ ( row ^. #outboxId
                          , if row ^. #outboxId == row3Id
                                then PublishFailed "pivot failed"
                                else PublishSucceeded
                          )
                        | row <- claimed
                        ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            Right summary <-
                Store.runStoreIO storeHandle $
                    publishClaimedOutbox publish (defaultPublishOptions & #backoff .~ ConstantBackoff 0) Nothing
            summary ^. #published `shouldBe` 2
            summary ^. #retried `shouldBe` 3
            Right (Just row1) <- Store.runStoreIO storeHandle (lookupOutbox row1Id)
            Right (Just row2) <- Store.runStoreIO storeHandle (lookupOutbox row2Id)
            Right (Just row3) <- Store.runStoreIO storeHandle (lookupOutbox row3Id)
            Right (Just row4) <- Store.runStoreIO storeHandle (lookupOutbox row4Id)
            Right (Just row5) <- Store.runStoreIO storeHandle (lookupOutbox row5Id)
            row1 ^. #status `shouldBe` OutboxSent
            row2 ^. #status `shouldBe` OutboxSent
            row3 ^. #status `shouldBe` OutboxFailed
            row3 ^. #attemptCount `shouldBe` 1
            row3 ^. #lastError `shouldBe` Just "pivot failed"
            row4 ^. #status `shouldBe` OutboxFailed
            row4 ^. #attemptCount `shouldBe` 0
            row4 ^. #lastError `shouldBe` Just "skipped: earlier record for the same key failed"
            row5 ^. #status `shouldBe` OutboxFailed
            row5 ^. #attemptCount `shouldBe` 0

        it "PerSourceStream keeps one source's failure from skipping another source's rows" $ \storeHandle -> do
            let rowA1 = outboxIdFromOrdinal 1
                rowB1 = outboxIdFromOrdinal 2
                rowA2 = outboxIdFromOrdinal 3
                rowB2 = outboxIdFromOrdinal 4
                mkRow oid src msgId =
                    (oid, sampleIntegrationEnvelope & #messageId .~ msgId & #source .~ src & #key .~ Nothing)
                rows =
                    [ mkRow rowA1 "per-source-a" "ps-a1"
                    , mkRow rowB1 "per-source-b" "ps-b1"
                    , mkRow rowA2 "per-source-a" "ps-a2"
                    , mkRow rowB2 "per-source-b" "ps-b2"
                    ]
                publish claimed =
                    pure
                        [ ( row ^. #outboxId
                          , if row ^. #outboxId == rowA2
                                then PublishFailed "source-a pivot failed"
                                else PublishSucceeded
                          )
                        | row <- claimed
                        ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            Right summary <-
                Store.runStoreIO storeHandle $
                    publishClaimedOutbox publish (defaultPublishOptions & #orderingPolicy .~ PerSourceStream & #backoff .~ ConstantBackoff 0) Nothing
            summary ^. #claimed `shouldBe` 4
            summary ^. #published `shouldBe` 3
            summary ^. #retried `shouldBe` 1
            Right (Just a1) <- Store.runStoreIO storeHandle (lookupOutbox rowA1)
            Right (Just a2) <- Store.runStoreIO storeHandle (lookupOutbox rowA2)
            Right (Just b1) <- Store.runStoreIO storeHandle (lookupOutbox rowB1)
            Right (Just b2) <- Store.runStoreIO storeHandle (lookupOutbox rowB2)
            a1 ^. #status `shouldBe` OutboxSent
            a2 ^. #status `shouldBe` OutboxFailed
            a2 ^. #attemptCount `shouldBe` 1
            a2 ^. #lastError `shouldBe` Just "source-a pivot failed"
            b1 ^. #status `shouldBe` OutboxSent
            b2 ^. #status `shouldBe` OutboxSent

        it "a late failure mark does not clobber a row that already reached a terminal state" $ \storeHandle -> do
            let oid = OutboxId outboxUuid1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
            now <- getCurrentTime
            Right [_] <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            Right True <- Store.runStoreIO storeHandle (markOutboxSent oid now)
            Right _ <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (markOutboxFailedTx oid "late failure from a timed-out worker" 5 60 now)
            Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            row ^. #status `shouldBe` OutboxSent
            row ^. #lastError `shouldBe` Nothing

        it "claims nothing while another transaction holds an uncommitted claim on a key's head" $ \storeHandle -> do
            let headId = outboxIdFromOrdinal 1
                tailId = outboxIdFromOrdinal 2
                rows =
                    [ (headId, sampleIntegrationEnvelope & #messageId .~ "claim-race-1" & #key .~ Just "claim-race-key")
                    , (tailId, sampleIntegrationEnvelope & #messageId .~ "claim-race-2" & #key .~ Just "claim-race-key")
                    ]
                OutboxId headUuid = headId
                holdClaimSql =
                    TE.encodeUtf8 $
                        "UPDATE keiro.keiro_outbox SET status = 'publishing', attempt_count = attempt_count + 1, updated_at = now() WHERE outbox_id = '"
                            <> UUID.toText headUuid
                            <> "'"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            holderDone <- newEmptyMVar
            _ <- forkIO $ do
                holder <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $ do
                            Tx.sql holdClaimSql
                            Tx.sql "SELECT pg_sleep(2)"
                putMVar holderDone holder
            -- Let the holder acquire its uncommitted row lock, then race a claim.
            threadDelay 500000
            now <- getCurrentTime
            Right claimed <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
            fmap (^. #outboxId) claimed `shouldBe` []
            Right () <- takeMVar holderDone
            pure ()

        it "StopTheLine publishes singleton batches and skips the unattempted suffix" $ \storeHandle -> do
            let row1Id = outboxIdFromOrdinal 1
                row2Id = outboxIdFromOrdinal 2
                row3Id = outboxIdFromOrdinal 3
                row4Id = outboxIdFromOrdinal 4
                ids = [row1Id, row2Id, row3Id, row4Id]
                rows =
                    [ (oid, sampleIntegrationEnvelope & #messageId .~ ("stop-line-" <> Text.pack (show i)) & #key .~ Just "stop-key")
                    | (i, oid) <- zip [1 .. 4 :: Int] ids
                    ]
                publishRef = fmap (^. #outboxId)
                publish claimed =
                    pure
                        [ ( row ^. #outboxId
                          , if row ^. #outboxId == row2Id
                                then PublishFailed "stop here"
                                else PublishSucceeded
                          )
                        | row <- claimed
                        ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        traverse_ (uncurry enqueueIntegrationEventTx) rows
            seenRef <- newIORef []
            let trackedPublish claimed = do
                    liftIO (modifyIORef' seenRef (<> publishRef claimed))
                    publish claimed
                opts = defaultPublishOptions & #orderingPolicy .~ StopTheLine & #backoff .~ ConstantBackoff 0
            Right summary <- Store.runStoreIO storeHandle (publishClaimedOutbox trackedPublish opts Nothing)
            summary ^. #published `shouldBe` 1
            summary ^. #retried `shouldBe` 3
            summary ^. #haltedOn `shouldBe` Just row2Id
            seen <- readIORef seenRef
            seen `shouldBe` take 2 ids
            Right (Just row3) <- Store.runStoreIO storeHandle (lookupOutbox row3Id)
            Right (Just row4) <- Store.runStoreIO storeHandle (lookupOutbox row4Id)
            row3 ^. #status `shouldBe` OutboxFailed
            row3 ^. #attemptCount `shouldBe` 0
            row4 ^. #status `shouldBe` OutboxFailed
            row4 ^. #attemptCount `shouldBe` 0

        it "publishClaimedOutbox treats a missing batch outcome as a failed row" $ \storeHandle -> do
            let okId = outboxIdFromOrdinal 1
                missingId = outboxIdFromOrdinal 2
                okEvent = sampleIntegrationEnvelope & #messageId .~ "missing-outcome-ok" & #key .~ Just "ok-key"
                missingEvent = sampleIntegrationEnvelope & #messageId .~ "missing-outcome-fail" & #key .~ Just "missing-key"
                publish claimed =
                    pure
                        [ (row ^. #outboxId, PublishSucceeded)
                        | row <- claimed
                        , row ^. #outboxId == okId
                        ]
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $ do
                        enqueueIntegrationEventTx okId okEvent
                        enqueueIntegrationEventTx missingId missingEvent
            Right summary <- Store.runStoreIO storeHandle (publishClaimedOutbox publish defaultPublishOptions Nothing)
            summary ^. #published `shouldBe` 1
            summary ^. #retried `shouldBe` 1
            Right (Just missingRow) <- Store.runStoreIO storeHandle (lookupOutbox missingId)
            missingRow ^. #status `shouldBe` OutboxFailed
            missingRow ^. #lastError `shouldBe` Just "publisher returned no outcome"

        it "auto-dead-letters a row after maxAttempts consecutive failures" $ \storeHandle -> do
            let oid = OutboxId outboxUuid1
                event = sampleIntegrationEnvelope & #key .~ Nothing
                opts =
                    defaultPublishOptions
                        & #batchSize
                        .~ 10
                        & #maxAttempts
                        .~ 3
                        & #backoff
                        .~ ConstantBackoff 0
                        & #orderingPolicy
                        .~ BestEffort
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oid event)
            let publish _ = pure (PublishFailed "broker exploded")
            -- First two failures retain Failed status.
            Right s1 <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) opts Nothing)
            s1 ^. #retried `shouldBe` 1
            s1 ^. #dead `shouldBe` 0
            Right s2 <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) opts Nothing)
            s2 ^. #retried `shouldBe` 1
            s2 ^. #dead `shouldBe` 0
            -- Third failure crosses the threshold.
            Right s3 <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) opts Nothing)
            s3 ^. #dead `shouldBe` 1
            Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
            row ^. #status `shouldBe` OutboxDead
            -- A dead row is not claimable.
            now <- getCurrentTime
            Right reclaimed <- Store.runStoreIO storeHandle (claimOutboxBatch BestEffort 10 now)
            reclaimed `shouldBe` []

        it "garbageCollectSent deletes only old sent rows" $ \storeHandle -> do
            let oldSentId = OutboxId outboxUuid1
                recentSentId = OutboxId outboxUuid2
                failedId = OutboxId outboxUuid3
                deadId = OutboxId outboxUuid4
                base = sampleIntegrationEnvelope & #key .~ Nothing
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx oldSentId (base & #messageId .~ "gc-old-sent"))
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx recentSentId (base & #messageId .~ "gc-recent-sent"))
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx failedId (base & #messageId .~ "gc-failed"))
            let firstPass row
                    | row ^. #outboxId == failedId = pure (PublishFailed "keep failed")
                    | otherwise = pure PublishSucceeded
                firstPassOpts =
                    defaultPublishOptions
                        & #batchSize
                        .~ 10
                        & #orderingPolicy
                        .~ BestEffort
                        & #backoff
                        .~ ConstantBackoff 3600
            Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow firstPass) firstPassOpts Nothing)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx deadId (base & #messageId .~ "gc-dead"))
            let deadPass row
                    | row ^. #outboxId == deadId = pure (PublishFailed "keep dead")
                    | otherwise = pure PublishSucceeded
                deadPassOpts =
                    defaultPublishOptions
                        & #batchSize
                        .~ 10
                        & #maxAttempts
                        .~ 1
                        & #orderingPolicy
                        .~ BestEffort
            Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow deadPass) deadPassOpts Nothing)
            now <- getCurrentTime
            Right () <- Store.runStoreIO storeHandle (backdateOutboxPublishedAt oldSentId (addUTCTime (-3600) now))
            Right deleted <- Store.runStoreIO storeHandle (garbageCollectSent 300 now)
            deleted `shouldBe` 1
            Right oldRow <- Store.runStoreIO storeHandle (lookupOutbox oldSentId)
            oldRow `shouldBe` Nothing
            Right (Just recentRow) <- Store.runStoreIO storeHandle (lookupOutbox recentSentId)
            recentRow ^. #status `shouldBe` OutboxSent
            Right (Just failedRow) <- Store.runStoreIO storeHandle (lookupOutbox failedId)
            failedRow ^. #status `shouldBe` OutboxFailed
            Right (Just deadRow) <- Store.runStoreIO storeHandle (lookupOutbox deadId)
            deadRow ^. #status `shouldBe` OutboxDead

        it "enforces per-key head-of-line blocking and unblocks once the predecessor reaches a terminal state" $ \storeHandle -> do
            let a1Id = OutboxId outboxUuid1
                a2Id = OutboxId outboxUuid2
                b1Id = OutboxId outboxUuid3
                a1 = sampleIntegrationEnvelope & #messageId .~ "a1" & #key .~ Just "k1"
                a2 = sampleIntegrationEnvelope & #messageId .~ "a2" & #key .~ Just "k1"
                b1 = sampleIntegrationEnvelope & #messageId .~ "b1" & #key .~ Just "k2"
            -- Insert in created_at order (a1 first, then a2, then b1).
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx a1Id a1)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx a2Id a2)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx b1Id b1)
            claimed <- newIORef []
            let publish row = do
                    liftIO (atomicModifyIORef' claimed (\xs -> ((row ^. #outboxId) : xs, ())))
                    if row ^. #outboxId == a1Id
                        then pure (PublishFailed "broker hiccup")
                        else pure PublishSucceeded
            -- First pass: with a one-row batch, a1 fails and both later rows remain pending.
            let firstPassOpts =
                    defaultPublishOptions
                        & #batchSize
                        .~ 1
                        & #backoff
                        .~ ConstantBackoff 0
            Right summary1 <-
                Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) firstPassOpts Nothing)
            summary1 ^. #claimed `shouldBe` 1
            claimedIds <- readIORef claimed
            claimedIds `shouldSatisfy` (a2Id `notElem`)
            claimedIds `shouldSatisfy` (a1Id `elem`)
            claimedIds `shouldSatisfy` (b1Id `notElem`)
            Right (Just a1Row) <- Store.runStoreIO storeHandle (lookupOutbox a1Id)
            a1Row ^. #status `shouldBe` OutboxFailed
            Right (Just b1Row) <- Store.runStoreIO storeHandle (lookupOutbox b1Id)
            b1Row ^. #status `shouldBe` OutboxPending
            Right (Just a2Row) <- Store.runStoreIO storeHandle (lookupOutbox a2Id)
            a2Row ^. #status `shouldBe` OutboxPending
            -- Drive a1 to terminal sent state so a2 can move. One pass claims a1
            -- (now that next_attempt_at has passed). A second pass claims a2,
            -- which becomes head-of-line once a1 reaches `sent`.
            writeIORef claimed []
            let publishOk row = do
                    liftIO (atomicModifyIORef' claimed (\xs -> ((row ^. #outboxId) : xs, ())))
                    pure PublishSucceeded
                retryOpts =
                    defaultPublishOptions
                        & #batchSize
                        .~ 1
                        & #backoff
                        .~ ConstantBackoff 0
            Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publishOk) retryOpts Nothing)
            Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publishOk) retryOpts Nothing)
            Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publishOk) retryOpts Nothing)
            claimedIds2 <- readIORef claimed
            claimedIds2 `shouldSatisfy` (a1Id `elem`)
            claimedIds2 `shouldSatisfy` (a2Id `elem`)
            claimedIds2 `shouldSatisfy` (b1Id `elem`)
            Right (Just a2Row') <- Store.runStoreIO storeHandle (lookupOutbox a2Id)
            a2Row' ^. #status `shouldBe` OutboxSent

        it "allows null-keyed rows to publish independently" $ \storeHandle -> do
            let n1 = OutboxId outboxUuid1
                n2 = OutboxId outboxUuid2
                e = sampleIntegrationEnvelope & #key .~ Nothing
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx n1 (e & #messageId .~ "n1"))
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx n2 (e & #messageId .~ "n2"))
            let publish row
                    | row ^. #outboxId == n1 = pure (PublishFailed "transient")
                    | otherwise = pure PublishSucceeded
            Right summary <-
                Store.runStoreIO storeHandle $
                    publishClaimedOutbox (perRow publish) (defaultPublishOptions & #backoff .~ ConstantBackoff 0) Nothing
            summary ^. #claimed `shouldBe` 2
            summary ^. #published `shouldBe` 1
            summary ^. #retried `shouldBe` 1

        it "mints message ids with the configured TypeID prefix" $ \storeHandle -> do
            Right minted <-
                Store.runStoreIO storeHandle (mintIntegrationEvent sampleProducer sampleDraft)
            minted ^. #source `shouldBe` "ordering"
            minted ^. #destination `shouldBe` "billing.orders.v1"
            Text.isPrefixOf "msg_" (minted ^. #messageId) `shouldBe` True

        it "validates integration producer message id prefixes before startup" $ \_storeHandle -> do
            shouldBeRight_ (mkIntegrationProducer sampleProducer)
            case mkIntegrationProducer (sampleProducer & #messageIdPrefix .~ "Bad-Prefix") of
                Left (InvalidMessageIdPrefix prefix reason) -> do
                    prefix `shouldBe` "Bad-Prefix"
                    reason `shouldSatisfy` (not . Text.null)
                other -> expectationFailure ("expected invalid prefix, got " <> show (void other))

        it "draftToEvent stamps source and messageId without minting" $ \_storeHandle -> do
            let event = draftToEvent "ordering" "msg-fixed-1" sampleDraft
            event ^. #messageId `shouldBe` "msg-fixed-1"
            event ^. #source `shouldBe` "ordering"
            event ^. #destination `shouldBe` "billing.orders.v1"

        it "freshOutboxId returns distinct UUIDv7 ids" $ \storeHandle -> do
            Right ids <-
                Store.runStoreIO storeHandle (traverse (\_ -> freshOutboxId) [1 .. 4 :: Int])
            length ids `shouldBe` 4
            length (uniqueIds ids) `shouldBe` 4

        it "publishClaimedOutbox emits a Producer span with messaging semconv attributes" $ \storeHandle -> do
            (processor, spansRef) <- inMemoryListExporter
            provider <- createTracerProvider [processor] emptyTracerProviderOptions
            let tracer = makeTracer provider "keiro-test" tracerOptions
                okId = OutboxId outboxUuid1
                failId = OutboxId outboxUuid2
                okEvent = sampleIntegrationEnvelope
                failEvent =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "msg-fail-otel-1"
                        & #key
                        .~ Just "order-otel-fail"
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx okId okEvent)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx failId failEvent)
            let publish row
                    | row ^. #outboxId == okId = pure PublishSucceeded
                    | otherwise = pure (PublishFailed "broker unreachable")
                opts = defaultPublishOptions & #tracer ?~ tracer
            Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) opts Nothing)
            _ <- shutdownTracerProvider provider Nothing
            spans <- traverse captureSpan =<< readIORef spansRef
            length spans `shouldBe` 1
            case spans of
                [batchSpan] -> do
                    csName batchSpan `shouldBe` ("send " <> (okEvent ^. #destination))
                    show (csKind batchSpan) `shouldBe` "Producer"
                    textAttr (csAttributes batchSpan) "messaging.system" `shouldBe` Just "kafka"
                    textAttr (csAttributes batchSpan) "messaging.operation.type" `shouldBe` Just "publish"
                    textAttr (csAttributes batchSpan) "messaging.operation.name" `shouldBe` Just "send"
                    textAttr (csAttributes batchSpan) "messaging.destination.name"
                        `shouldBe` Just (okEvent ^. #destination)
                    textAttr (csAttributes batchSpan) "messaging.kafka.message.key"
                        `shouldBe` (okEvent ^. #key)
                    intAttr (csAttributes batchSpan) "keiro.outbox.batch.size" `shouldBe` Just 2
                    textAttr (csAttributes batchSpan) "error.type" `shouldBe` Just "publish_failed"
                    case csStatus batchSpan of
                        Error msg -> msg `shouldBe` "broker unreachable"
                        other -> expectationFailure ("expected Error \"broker unreachable\", got " <> show other)
                other -> expectationFailure ("expected one batch span, got " <> show (length other))

        it "publishClaimedOutbox records counters and sampleOutboxBacklog records the gauge" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            let okId = OutboxId outboxUuid1
                failId = OutboxId outboxUuid2
                okEvent = sampleIntegrationEnvelope & #messageId .~ "metrics-ok" & #key .~ Nothing
                failEvent = sampleIntegrationEnvelope & #messageId .~ "metrics-fail" & #key .~ Nothing
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx okId okEvent)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (enqueueIntegrationEventTx failId failEvent)
            let publish row
                    | row ^. #outboxId == okId = pure PublishSucceeded
                    | otherwise = pure (PublishFailed "broker down")
                retryPassOpts =
                    defaultPublishOptions
                        & #batchSize
                        .~ 10
                        & #maxAttempts
                        .~ 5
                        & #backoff
                        .~ ConstantBackoff 0
                        & #orderingPolicy
                        .~ BestEffort
                deadPassOpts = retryPassOpts & #maxAttempts .~ 1
            -- Pass 1 (maxAttempts = 5): ok publishes, the fail row retries.
            Right summary1 <-
                Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) retryPassOpts (Just keiroMetrics))
            summary1 ^. #published `shouldBe` 1
            summary1 ^. #retried `shouldBe` 1
            -- Pass 2 (maxAttempts = 1): the failed row crosses the ceiling and dies.
            Right summary2 <-
                Store.runStoreIO storeHandle (publishClaimedOutbox (perRow publish) deadPassOpts (Just keiroMetrics))
            summary2 ^. #dead `shouldBe` 1
            -- Flush so the in-memory exporter receives the aggregates.
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            let scalars = flattenScalarPoints exported
            -- Counters are cumulative across both passes.
            lookup "keiro.outbox.published" scalars `shouldBe` Just (IntNumber 1)
            lookup "keiro.outbox.retried" scalars `shouldBe` Just (IntNumber 1)
            lookup "keiro.outbox.deadlettered" scalars `shouldBe` Just (IntNumber 1)
            -- Publish passes no longer run the backlog COUNT(*) on the hot path.
            lookup "keiro.outbox.backlog" scalars `shouldBe` Nothing

            Store.runStoreIO storeHandle (sampleOutboxBacklog (Just keiroMetrics)) `shouldReturn` Right ()
            _ <- forceFlushMeterProvider provider Nothing
            sampled <- readIORef metricsRef
            let sampledScalars = flattenScalarPoints sampled
            lookup "keiro.outbox.backlog" sampledScalars `shouldBe` Just (IntNumber 0)

    describe "Keiro.Inbox" $ around (withFreshStore fixture) $ do
        it "runs the handler once and records the row as completed" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-1"
                        & #source
                        .~ "ordering"
                handler ev =
                    Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right result1 <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler
            case result1 of
                Right (InboxProcessed ()) -> pure ()
                other -> expectationFailure ("expected InboxProcessed, got " <> show other)
            Right rowCount1 <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount1 `shouldBe` 1
            Right (Just inboxRow) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-1")
            inboxRow ^. #status `shouldBe` InboxCompleted
            inboxRow ^. #completedAt `shouldSatisfy` isJust

        it "treats a redelivery with the same messageId as a duplicate" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-dup"
                        & #source
                        .~ "ordering"
                handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right (Right (InboxProcessed ())) <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler
            Right result2 <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler
            result2 `shouldBe` Right InboxDuplicate
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 1

        it "records inbox counters and samples backlog separately under the in-memory exporter" $ \storeHandle -> do
            (exporter, metricsRef) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            keiroMetrics <- Telemetry.newKeiroMetrics meter
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event = sampleIntegrationEnvelope & #messageId .~ "inbox-metrics-dup" & #source .~ "ordering"
                handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            -- First delivery runs the handler: processed.
            Right (Right (InboxProcessed ())) <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction (Just keiroMetrics) PreferIntegrationMessageId event Nothing handler
            -- Second delivery of the same (source, message_id): duplicate.
            Right result2 <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction (Just keiroMetrics) PreferIntegrationMessageId event Nothing handler
            result2 `shouldBe` Right InboxDuplicate
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef metricsRef
            let scalars = flattenScalarPoints exported
            lookup "keiro.inbox.processed" scalars `shouldBe` Just (IntNumber 1)
            lookup "keiro.inbox.duplicates" scalars `shouldBe` Just (IntNumber 1)
            lookup "keiro.inbox.backlog" scalars `shouldBe` Nothing
            Store.runStoreIO storeHandle (sampleInboxBacklog (Just keiroMetrics)) `shouldReturn` Right ()
            _ <- forceFlushMeterProvider provider Nothing
            sampled <- readIORef metricsRef
            let sampledScalars = flattenScalarPoints sampled
            lookup "keiro.inbox.backlog" sampledScalars `shouldBe` Just (IntNumber 0)
            -- The handler ran exactly once (the duplicate path does not re-run it).
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 1

        it "deduplicates via PreferSourceEventIdentity even when messageId differs" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let shared = sampleIntegrationEnvelope & #source .~ "ordering"
                first = shared & #messageId .~ "republish-1"
                second = shared & #messageId .~ "republish-2"
                handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right (Right (InboxProcessed ())) <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferSourceEventIdentity first Nothing handler
            Right result2 <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferSourceEventIdentity second Nothing handler
            result2 `shouldBe` Right InboxDuplicate

        it "uses KafkaDeliveryIdentity when supplied" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event = sampleIntegrationEnvelope & #source .~ "ordering"
                kafka = KafkaDeliveryRef "billing.orders.v1" 0 17
                handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right (Right (InboxProcessed ())) <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing KafkaDeliveryIdentity event (Just kafka) handler
            Right (Right InboxDuplicate) <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing KafkaDeliveryIdentity event (Just kafka) handler
            Right (Just row) <-
                Store.runStoreIO storeHandle $
                    lookupInbox "ordering" "billing.orders.v1:0:17"
            row ^. #status `shouldBe` InboxCompleted

        it "reports DedupePolicyUnsatisfied when the envelope lacks the required field" $ \storeHandle -> do
            let event =
                    sampleIntegrationEnvelope
                        & #source
                        .~ "ordering"
                        & #sourceEventId
                        .~ Nothing
                        & #sourceGlobalPosition
                        .~ Nothing
            Right result <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferSourceEventIdentity event Nothing (\_ -> pure ())
            result `shouldBe` Left (DedupePolicyUnsatisfied PreferSourceEventIdentity)

        it "leaves no inbox row when the handler condemns the transaction" $ \storeHandle -> do
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-rollback"
                        & #source
                        .~ "ordering"
                handler _ = do
                    Tx.condemn
                    pure ()
            _ <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler
            Right row <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-rollback")
            row `shouldBe` Nothing

        it "leaves no inbox row when the plain handler throws" $ \storeHandle -> do
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-throw-plain"
                        & #source
                        .~ "ordering"
                handler _ = (pure $! error "plain inbox handler failed") :: Tx.Transaction ()
            thrown <-
                try $
                    Store.runStoreIO storeHandle $
                        runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler
            case thrown of
                Left (_ :: SomeException) -> pure ()
                Right other -> expectationFailure ("expected handler exception, got " <> show (void other))
            Right row <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-throw-plain")
            row `shouldBe` Nothing

        it "exports markFailedTx from the public inbox module and preserves explicit failure marks" $ \storeHandle -> do
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-public-failed"
                        & #source
                        .~ "ordering"
                handler _ = do
                    markFailedTx "ordering" "inbox-msg-public-failed" "operator failed" (event ^. #occurredAt)
                    pure ()
            Right (Right (InboxProcessed ())) <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler
            Right (Just row) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-public-failed")
            row ^. #status `shouldBe` InboxFailed
            row ^. #lastError `shouldBe` Just "operator failed"

        it "a throwing handler records a failed attempt instead of looping" $ \storeHandle -> do
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-poison-1"
                        & #source
                        .~ "ordering"
                handler _ = (pure $! error "inbox exploded") :: Tx.Transaction ()
            Right result <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWithRetries Nothing 3 PreferIntegrationMessageId event Nothing handler
            case result of
                Right (InboxHandlerFailed err attempts) -> do
                    Text.isInfixOf "inbox exploded" err `shouldBe` True
                    attempts `shouldBe` 1
                other -> expectationFailure ("expected InboxHandlerFailed, got " <> show other)
            Right (Just row) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-poison-1")
            row ^. #status `shouldBe` InboxFailed
            row ^. #attemptCount `shouldBe` 1
            row ^. #lastError `shouldSatisfy` maybe False (Text.isInfixOf "inbox exploded")

        it "a transient poison message succeeds on retry" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-poison-transient"
                        & #source
                        .~ "ordering"
                failOnce _ = (pure $! error "temporary inbox failure") :: Tx.Transaction ()
                succeeding ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right result1 <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWithRetries Nothing 3 PreferIntegrationMessageId event Nothing failOnce
            case result1 of
                Right (InboxHandlerFailed _ 1) -> pure ()
                other -> expectationFailure ("expected first failed attempt, got " <> show other)
            Right result2 <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWithRetries Nothing 3 PreferIntegrationMessageId event Nothing succeeding
            result2 `shouldBe` Right (InboxProcessed ())
            Right (Just row) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-poison-transient")
            row ^. #status `shouldBe` InboxCompleted
            row ^. #attemptCount `shouldBe` 1
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 1

        it "an unrecoverable message dead-letters at the ceiling" $ \storeHandle -> do
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-poison-dead"
                        & #source
                        .~ "ordering"
                handler _ = (pure $! error "always broken") :: Tx.Transaction ()
            Right result1 <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWithRetries Nothing 2 PreferIntegrationMessageId event Nothing handler
            Right result2 <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWithRetries Nothing 2 PreferIntegrationMessageId event Nothing handler
            Right result3 <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWithRetries Nothing 2 PreferIntegrationMessageId event Nothing handler
            case (result1, result2, result3) of
                ( Right (InboxHandlerFailed _ 1)
                    , Right (InboxHandlerFailed _ 2)
                    , Right (InboxPreviouslyFailed _)
                    ) -> pure ()
                other -> expectationFailure ("unexpected poison lifecycle: " <> show other)
            Right (Just row) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-poison-dead")
            row ^. #status `shouldBe` InboxFailed
            row ^. #attemptCount `shouldBe` 2

        it "processes a batch of distinct messages in one transaction" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let events =
                    [ sampleIntegrationEnvelope
                        & #messageId
                        .~ ("inbox-batch-msg-" <> Text.pack (show n))
                        & #source
                        .~ "batch-ordering"
                    | n <- [1 .. 50 :: Int]
                    ]
                handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right results <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionBatch Nothing 3 PreferIntegrationMessageId PersistFullEnvelope ((,Nothing) <$> events) handler
            results `shouldBe` replicate 50 (Right (InboxProcessed ()))
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 50
            Right inboxRows <- Store.runStoreIO storeHandle (listInbox "batch-ordering")
            length inboxRows `shouldBe` 50
            all ((== InboxCompleted) . (^. #status)) inboxRows `shouldBe` True

        it "deduplicates repeated messages within one batch" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-batch-dup"
                        & #source
                        .~ "batch-ordering"
                handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right results <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionBatch Nothing 3 PreferIntegrationMessageId PersistFullEnvelope [(event, Nothing), (event, Nothing)] handler
            results `shouldBe` [Right (InboxProcessed ()), Right InboxDuplicate]
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 1

        it "falls back per message when one batch handler throws" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let events =
                    [ sampleIntegrationEnvelope
                        & #messageId
                        .~ ("inbox-batch-poison-" <> Text.pack (show n))
                        & #source
                        .~ "batch-ordering"
                    | n <- [1 .. 5 :: Int]
                    ]
                handler ev
                    | ev ^. #messageId == "inbox-batch-poison-3" =
                        (pure $! error "batch poison") :: Tx.Transaction ()
                    | otherwise =
                        Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right results <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionBatch Nothing 3 PreferIntegrationMessageId PersistFullEnvelope ((,Nothing) <$> events) handler
            case results of
                [ Right (InboxProcessed ())
                    , Right (InboxProcessed ())
                    , Right (InboxHandlerFailed err 1)
                    , Right (InboxProcessed ())
                    , Right (InboxProcessed ())
                    ] ->
                        Text.isInfixOf "batch poison" err `shouldBe` True
                other -> expectationFailure ("unexpected batch fallback results: " <> show other)
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 4
            Right (Just row) <- Store.runStoreIO storeHandle (lookupInbox "batch-ordering" "inbox-batch-poison-3")
            row ^. #status `shouldBe` InboxFailed
            row ^. #attemptCount `shouldBe` 1
            row ^. #lastError `shouldSatisfy` maybe False (Text.isInfixOf "batch poison")

        it "reports duplicates across batch calls" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-batch-existing-dup"
                        & #source
                        .~ "batch-ordering"
                handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right first <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionBatch Nothing 3 PreferIntegrationMessageId PersistFullEnvelope [(event, Nothing)] handler
            first `shouldBe` [Right (InboxProcessed ())]
            Right second <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionBatch Nothing 3 PreferIntegrationMessageId PersistFullEnvelope [(event, Nothing)] handler
            second `shouldBe` [Right InboxDuplicate]
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 1

        it "falls back per message when one batch handler condemns the transaction" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let events =
                    [ sampleIntegrationEnvelope
                        & #messageId
                        .~ ("inbox-batch-condemn-" <> Text.pack (show n))
                        & #source
                        .~ "batch-ordering"
                    | n <- [1 .. 3 :: Int]
                    ]
                handler ev
                    | ev ^. #messageId == "inbox-batch-condemn-2" = Tx.condemn
                    | otherwise = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right results <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionBatch Nothing 3 PreferIntegrationMessageId PersistFullEnvelope ((,Nothing) <$> events) handler
            -- The condemned single-message retry reports processed by the
            -- documented single-path contract; what matters is that the
            -- innocent batch mates actually committed.
            results `shouldBe` replicate 3 (Right (InboxProcessed ()))
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 2
            Right (Just mate1) <- Store.runStoreIO storeHandle (lookupInbox "batch-ordering" "inbox-batch-condemn-1")
            Right (Just mate3) <- Store.runStoreIO storeHandle (lookupInbox "batch-ordering" "inbox-batch-condemn-3")
            mate1 ^. #status `shouldBe` InboxCompleted
            mate3 ^. #status `shouldBe` InboxCompleted
            Right condemned <- Store.runStoreIO storeHandle (lookupInbox "batch-ordering" "inbox-batch-condemn-2")
            condemned `shouldBe` Nothing

        it "classifies a legacy processing row as InboxInProgress without running the handler" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-legacy-processing"
                        & #source
                        .~ "ordering"
                handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.sql "INSERT INTO keiro.keiro_inbox (source, dedupe_key, content_type, payload_bytes, status) VALUES ('ordering', 'inbox-legacy-processing', 'application/json', ''::bytea, 'processing')"
            Right result <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler
            result `shouldBe` Right InboxInProgress
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 0
            Right (Just row) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-legacy-processing")
            row ^. #status `shouldBe` InboxProcessing

        it "runs the handler once when two workers race the same dedupe key" $ \storeHandle -> do
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-race-dup"
                        & #source
                        .~ "ordering"
                slowHandler ev = do
                    Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
                    Tx.sql "SELECT pg_sleep(1.5)"
                fastHandler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
            firstDone <- newEmptyMVar
            _ <- forkIO $ do
                first <-
                    Store.runStoreIO storeHandle $
                        runInboxTransaction Nothing PreferIntegrationMessageId event Nothing slowHandler
                putMVar firstDone first
            -- Let the slow worker insert its uncommitted row, then race the
            -- same dedupe key: the second insert must block on the unique
            -- constraint until the first commits, then classify as duplicate.
            threadDelay 400000
            Right second <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferIntegrationMessageId event Nothing fastHandler
            Right first <- takeMVar firstDone
            first `shouldBe` Right (InboxProcessed ())
            second `shouldBe` Right InboxDuplicate
            Right rowCount <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
            rowCount `shouldBe` 1

        it "can persist only dedupe columns for successful rows" $ \storeHandle -> do
            let kafka = KafkaDeliveryRef "billing.orders.v1" 1 42
                event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-slim-success"
                        & #source
                        .~ "ordering"
                        & #payloadBytes
                        .~ "full success payload"
                        & #attributes
                        ?~ object ["source" Aeson..= ("slim-test" :: Text)]
                handler _ = pure ()
            Right (Right (InboxProcessed ())) <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWith Nothing PersistDedupeOnly PreferIntegrationMessageId event (Just kafka) handler
            Right (Just row) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-slim-success")
            row ^. #event . #payloadBytes `shouldBe` ""
            row ^. #event . #attributes `shouldBe` Nothing
            row ^. #event . #traceContext `shouldBe` Nothing
            row ^. #event . #schemaReference `shouldBe` Nothing
            row ^. #event . #messageId `shouldBe` "inbox-slim-success"
            row ^. #event . #sourceEventId `shouldBe` event ^. #sourceEventId
            row ^. #event . #sourceGlobalPosition `shouldBe` event ^. #sourceGlobalPosition
            row ^. #event . #causationId `shouldBe` event ^. #causationId
            row ^. #event . #correlationId `shouldBe` event ^. #correlationId
            row ^. #event . #occurredAt `shouldBe` event ^. #occurredAt
            row ^. #kafka `shouldBe` Just kafka
            Right redelivery <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWith Nothing PersistDedupeOnly PreferIntegrationMessageId event (Just kafka) handler
            redelivery `shouldBe` Right InboxDuplicate

        it "keeps full failed rows even when successful rows are dedupe-only" $ \storeHandle -> do
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-slim-failed"
                        & #source
                        .~ "ordering"
                        & #payloadBytes
                        .~ "full failed payload"
                        & #attributes
                        ?~ object ["source" Aeson..= ("failed-slim-test" :: Text)]
                handler _ = (pure $! error "slim failure") :: Tx.Transaction ()
            Right result <-
                Store.runStoreIO storeHandle $
                    runInboxTransactionWithRetriesWith Nothing 3 PersistDedupeOnly PreferIntegrationMessageId event Nothing handler
            case result of
                Right (InboxHandlerFailed err 1) ->
                    Text.isInfixOf "slim failure" err `shouldBe` True
                other -> expectationFailure ("expected InboxHandlerFailed, got " <> show other)
            Right (Just row) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-slim-failed")
            row ^. #status `shouldBe` InboxFailed
            row ^. #event . #payloadBytes `shouldBe` event ^. #payloadBytes
            row ^. #event . #attributes `shouldBe` event ^. #attributes
            row ^. #event . #traceContext `shouldBe` event ^. #traceContext
            row ^. #event . #schemaReference `shouldBe` event ^. #schemaReference

        it "garbage-collects completed rows older than the retention window" $ \storeHandle -> do
            let event =
                    sampleIntegrationEnvelope
                        & #messageId
                        .~ "inbox-msg-gc"
                        & #source
                        .~ "ordering"
                handler _ = pure ()
            Right (Right (InboxProcessed ())) <-
                Store.runStoreIO storeHandle $
                    runInboxTransaction Nothing PreferIntegrationMessageId event Nothing handler
            -- Backdate the row so it falls outside the retention window.
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.sql
                            "UPDATE keiro.keiro_inbox SET completed_at = now() - interval '40 days' WHERE message_id = 'inbox-msg-gc'"
            now <- getCurrentTime
            Right deleted <- Store.runStoreIO storeHandle (garbageCollectCompleted (nominalDays 30) now)
            deleted `shouldBe` 1
            Right rows <- Store.runStoreIO storeHandle (listInbox "ordering")
            rows `shouldBe` []

    describe "Keiro.Inbox.Kafka" $ do
        it "reconstructs an integration event from headers and payload" $ do
            let envelope = sampleIntegrationEnvelope
                headers = integrationHeaders envelope
                receivedAt = addUTCTime 60 (envelope ^. #occurredAt)
                record =
                    InboxKafka.KafkaInboundRecord
                        { topic = "billing.orders.v1"
                        , partition = 2
                        , offset = 113
                        , key = Just "order-123"
                        , payload = envelope ^. #payloadBytes
                        , headers
                        , receivedAt
                        }
            case InboxKafka.integrationEventFromKafka record of
                Right (rebuilt, kafkaRef) -> do
                    rebuilt ^. #messageId `shouldBe` envelope ^. #messageId
                    rebuilt ^. #source `shouldBe` envelope ^. #source
                    rebuilt ^. #destination `shouldBe` envelope ^. #destination
                    rebuilt ^. #eventType `shouldBe` envelope ^. #eventType
                    rebuilt ^. #schemaVersion `shouldBe` envelope ^. #schemaVersion
                    rebuilt ^. #sourceEventId `shouldBe` envelope ^. #sourceEventId
                    rebuilt ^. #sourceGlobalPosition `shouldBe` envelope ^. #sourceGlobalPosition
                    rebuilt ^. #payloadBytes `shouldBe` envelope ^. #payloadBytes
                    rebuilt ^. #occurredAt `shouldBe` envelope ^. #occurredAt
                    rebuilt ^. #attributes `shouldBe` envelope ^. #attributes
                    kafkaRef ^. #topic `shouldBe` "billing.orders.v1"
                    kafkaRef ^. #partition `shouldBe` 2
                    kafkaRef ^. #offset `shouldBe` 113
                Left err -> expectationFailure ("expected Right, got Left " <> show err)

        it "falls back to receivedAt when the occurredAt header is absent" $ do
            let envelope = sampleIntegrationEnvelope
                receivedAt = addUTCTime 60 (envelope ^. #occurredAt)
                headers = filter ((/= "keiro-occurred-at") . Prelude.fst) (integrationHeaders envelope)
                record =
                    InboxKafka.KafkaInboundRecord
                        { topic = "billing.orders.v1"
                        , partition = 2
                        , offset = 113
                        , key = Just "order-123"
                        , payload = envelope ^. #payloadBytes
                        , headers
                        , receivedAt
                        }
            case InboxKafka.integrationEventFromKafka record of
                Right (rebuilt, _) -> rebuilt ^. #occurredAt `shouldBe` receivedAt
                Left err -> expectationFailure ("expected Right, got Left " <> show err)

        it "rejects malformed occurredAt headers" $ do
            let envelope = sampleIntegrationEnvelope
                headers = ("keiro-occurred-at", "not-a-time") : filter ((/= "keiro-occurred-at") . Prelude.fst) (integrationHeaders envelope)
                record =
                    InboxKafka.KafkaInboundRecord
                        { topic = "billing.orders.v1"
                        , partition = 2
                        , offset = 113
                        , key = Just "order-123"
                        , payload = envelope ^. #payloadBytes
                        , headers
                        , receivedAt = envelope ^. #occurredAt
                        }
            InboxKafka.integrationEventFromKafka record
                `shouldBe` Left (InboxKafka.InvalidTimeHeader "keiro-occurred-at" "not-a-time")

        it "reports MissingHeader for an essential header" $ do
            let envelope = sampleIntegrationEnvelope
                headers = filter ((/= "keiro-message-id") . Prelude.fst) (integrationHeaders envelope)
                record =
                    InboxKafka.KafkaInboundRecord
                        { topic = "billing.orders.v1"
                        , partition = 0
                        , offset = 0
                        , key = Nothing
                        , payload = envelope ^. #payloadBytes
                        , headers
                        , receivedAt = envelope ^. #occurredAt
                        }
            InboxKafka.integrationEventFromKafka record
                `shouldBe` Left (InboxKafka.MissingHeader "keiro-message-id")

        it "withConsumerSpan parents the consumer span under an upstream producer span via W3C headers" $ do
            (processor, spansRef) <- inMemoryListExporter
            provider <- createTracerProvider [processor] emptyTracerProviderOptions
            let tracer = makeTracer provider "keiro-test" tracerOptions
                -- Clear the baked-in TraceContext on the sample so the only
                -- `traceparent` on the wire comes from the active producer
                -- span (via `injectTraceContext`).
                envelope = sampleIntegrationEnvelope & #traceContext .~ Nothing
                producerRecord = OutboxKafka.integrationEventToKafkaRecord envelope
            producerHeadersText <-
                Telemetry.withProducerSpan (Just tracer) envelope producerRecord $ \_ -> do
                    let baseHeaders =
                            [(TE.decodeUtf8 n, TE.decodeUtf8 v) | (n, v) <- producerRecord ^. #headers]
                    Telemetry.injectTraceContext baseHeaders
            -- Build the inbound record the consumer would receive and open the
            -- consumer span around a no-op body.
            now <- getCurrentTime
            let inbound =
                    InboxKafka.KafkaInboundRecord
                        { topic = envelope ^. #destination
                        , partition = 7
                        , offset = 42
                        , key = envelope ^. #key
                        , payload = envelope ^. #payloadBytes
                        , headers = producerHeadersText
                        , receivedAt = now
                        }
            Telemetry.withConsumerSpan (Just tracer) (Just "billing-cg") inbound (Just envelope) $ \_ ->
                pure ()
            _ <- shutdownTracerProvider provider Nothing
            spans <- traverse captureSpan =<< readIORef spansRef
            length spans `shouldBe` 2
            let findByName needle = case [s | s <- spans, csName s == needle] of
                    (s : _) -> s
                    [] -> error ("no span captured with name=" <> Text.unpack needle)
                producerSp = findByName ("send " <> envelope ^. #destination)
                consumerSp = findByName ("process " <> envelope ^. #destination)
            -- Same trace id end-to-end (cross-process parenting).
            traceId (csContext producerSp) `shouldBe` traceId (csContext consumerSp)
            -- Consumer's parent is the producer span.
            case csParent consumerSp of
                Nothing -> expectationFailure "consumer span has no parent"
                Just parent -> do
                    parentCtx <- getSpanContext parent
                    spanId parentCtx `shouldBe` spanId (csContext producerSp)
            -- Consumer span carries the expected attributes.
            show (csKind consumerSp) `shouldBe` "Consumer"
            textAttr (csAttributes consumerSp) "messaging.system" `shouldBe` Just "kafka"
            textAttr (csAttributes consumerSp) "messaging.operation.type" `shouldBe` Just "process"
            textAttr (csAttributes consumerSp) "messaging.destination.name"
                `shouldBe` Just (envelope ^. #destination)
            textAttr (csAttributes consumerSp) "messaging.destination.partition.id"
                `shouldBe` Just "7"
            textAttr (csAttributes consumerSp) "messaging.consumer.group.name"
                `shouldBe` Just "billing-cg"
            textAttr (csAttributes consumerSp) "messaging.message.id"
                `shouldBe` Just (envelope ^. #messageId)

    describe "Keiro cross-context Kafka integration" $ around (withFreshStores2 fixture) $ do
        it "publishes an Ordering integration event and runs the Billing handler exactly once across duplicate deliveries" $ \(ordering, billing) -> do
            Right () <-
                Store.runStoreIO billing $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS billing_received_orders (order_id TEXT PRIMARY KEY, quantity BIGINT NOT NULL)")
            topic <- newKafkaTopic
            -- Ordering side: enqueue an outbox row representing a published event.
            let orderingEvent = orderSubmittedEnvelope "order-aaa" 7 "msg-aaa"
                oid = OutboxId outboxUuid1
            Right () <-
                Store.runStoreIO ordering $
                    Store.runTransaction (enqueueIntegrationEventTx oid orderingEvent)
            -- Run the publisher worker: push records to the in-process topic.
            Right pubSummary1 <-
                Store.runStoreIO ordering $
                    publishClaimedOutbox (perRow (kafkaTopicPublish topic)) defaultPublishOptions Nothing
            pubSummary1 ^. #published `shouldBe` 1
            -- Billing side: consume from the topic.
            records1 <- drainKafkaTopic topic
            record1 <- case records1 of
                [r] -> pure r
                other -> expectationFailure ("expected 1 record, got " <> show (length other)) *> error "unreachable"
            Right consumed1 <-
                Store.runStoreIO billing $
                    consumeAndApply record1 billingReactionHandler
            consumed1 `shouldBe` ConsumeApplied (InboxProcessed ())
            Right rowCount1 <-
                Store.runStoreIO billing $
                    Store.runTransaction (Tx.statement () billingReceivedOrdersCountStmt)
            rowCount1 `shouldBe` 1

            -- Simulate Kafka redelivery: pretend the same Kafka record was
            -- delivered again at a different offset. The producer also retries
            -- (the outbox flips back to pending and the worker republishes).
            let redelivered = redeliverWithDifferentOffset record1
            Right consumed2 <-
                Store.runStoreIO billing $
                    consumeAndApply redelivered billingReactionHandler
            consumed2 `shouldBe` ConsumeApplied InboxDuplicate
            Right rowCount2 <-
                Store.runStoreIO billing $
                    Store.runTransaction (Tx.statement () billingReceivedOrdersCountStmt)
            rowCount2 `shouldBe` 1

        it "preserves per-partition ordering for two events sharing a Kafka key" $ \(ordering, billing) -> do
            Right () <-
                Store.runStoreIO billing $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS billing_received_orders (order_id TEXT PRIMARY KEY, quantity BIGINT NOT NULL)")
            Right () <-
                Store.runStoreIO billing $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS billing_event_log (seq BIGSERIAL PRIMARY KEY, source TEXT NOT NULL, event_type TEXT NOT NULL, order_id TEXT NOT NULL)")
            topic <- newKafkaTopic
            -- Two events for the same order key.
            let submittedEnv = orderSubmittedEnvelope "order-bbb" 4 "msg-bbb-1"
                cancelledEnv = orderCancelledEnvelope "order-bbb" "msg-bbb-2"
                submittedId = OutboxId outboxUuid1
                cancelledId = OutboxId outboxUuid2
            Right () <-
                Store.runStoreIO ordering $
                    Store.runTransaction (enqueueIntegrationEventTx submittedId submittedEnv)
            Right () <-
                Store.runStoreIO ordering $
                    Store.runTransaction (enqueueIntegrationEventTx cancelledId cancelledEnv)
            -- Run-claiming lets a same-key contiguous run drain in one pass.
            let drainOnce =
                    publishClaimedOutbox
                        (perRow (kafkaTopicPublish topic))
                        (defaultPublishOptions & #backoff .~ ConstantBackoff 0)
                        Nothing
            Right s1 <- Store.runStoreIO ordering drainOnce
            Right s2 <- Store.runStoreIO ordering drainOnce
            (s1 ^. #published) + (s2 ^. #published) `shouldBe` 2
            records <- drainKafkaTopic topic
            length records `shouldBe` 2
            -- Apply both records to billing in delivery order.
            for_ records $ \record -> do
                Right consumed <-
                    Store.runStoreIO billing $
                        consumeAndApply record (loggingReactionHandler "billing")
                case consumed of
                    ConsumeApplied (InboxProcessed ()) -> pure ()
                    other -> expectationFailure ("expected processed, got " <> show other)
            Right events <-
                Store.runStoreIO billing $
                    Store.runTransaction (Tx.statement () billingEventLogStmt)
            events `shouldBe` [("OrderSubmitted", "order-bbb"), ("OrderCancelled", "order-bbb")]

        it "head-of-line blocks a same-key successor when the first send fails repeatedly until the first row reaches dead status" $ \(ordering, billing) -> do
            Right () <-
                Store.runStoreIO billing $
                    Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS billing_received_orders (order_id TEXT PRIMARY KEY, quantity BIGINT NOT NULL)")
            topic <- newKafkaTopic
            let submittedEnv = orderSubmittedEnvelope "order-ccc" 1 "msg-ccc-1"
                cancelledEnv = orderCancelledEnvelope "order-ccc" "msg-ccc-2"
                firstId = OutboxId outboxUuid1
                secondId = OutboxId outboxUuid2
            Right () <-
                Store.runStoreIO ordering $
                    Store.runTransaction (enqueueIntegrationEventTx firstId submittedEnv)
            Right () <-
                Store.runStoreIO ordering $
                    Store.runTransaction (enqueueIntegrationEventTx secondId cancelledEnv)
            -- Failing publish for the first row, success for any other.
            let publish row
                    | row ^. #outboxId == firstId =
                        pure (PublishFailed "simulated broker reject")
                    | otherwise = do
                        kafkaTopicAccept topic row
                        pure PublishSucceeded
                deadOpts =
                    defaultPublishOptions
                        & #batchSize
                        .~ 1
                        & #backoff
                        .~ ConstantBackoff 0
                        & #maxAttempts
                        .~ 2
            -- This test drives the pre-M3 sequential failure/dead-letter path
            -- with one-row batches. M3 adds suffix skipping for larger claimed
            -- same-key runs.
            -- First pass: the first row attempts once and fails; the second is
            -- outside the one-row claim window.
            Right pass1 <- Store.runStoreIO ordering (publishClaimedOutbox (perRow publish) deadOpts Nothing)
            pass1 ^. #retried `shouldBe` 1
            pass1 ^. #published `shouldBe` 0
            -- Second pass crosses maxAttempts and dead-letters the first row.
            Right pass2 <- Store.runStoreIO ordering (publishClaimedOutbox (perRow publish) deadOpts Nothing)
            pass2 ^. #dead `shouldBe` 1
            Right (Just firstRow) <- Store.runStoreIO ordering (lookupOutbox firstId)
            firstRow ^. #status `shouldBe` OutboxDead
            -- With the first row dead, the second becomes claimable and publishes.
            Right pass3 <- Store.runStoreIO ordering (publishClaimedOutbox (perRow publish) deadOpts Nothing)
            pass3 ^. #published `shouldBe` 1
            Right (Just secondRow) <- Store.runStoreIO ordering (lookupOutbox secondId)
            secondRow ^. #status `shouldBe` OutboxSent
            -- Billing only sees the second event.
            records <- drainKafkaTopic topic
            record <- case records of
                [r] -> pure r
                other -> expectationFailure ("expected 1 record, got " <> show (length other)) *> error "unreachable"
            Right consumed <-
                Store.runStoreIO billing $
                    consumeAndApply record billingReactionHandler
            consumed `shouldBe` ConsumeApplied (InboxProcessed ())

    describe "Keiro.Integration.Event" $ do
        it "round-trips a JSON envelope through encode and decode" $ do
            let envelope = sampleIntegrationEnvelope
                payload = OrderSubmittedPayload "order-123" 5
                encoded = encodeJsonIntegrationEvent envelope payload
            decodeJsonIntegrationEvent encoded `shouldBe` Right payload

        it "preserves identity and routing through encode" $ do
            let envelope = sampleIntegrationEnvelope
                encoded = encodeJsonIntegrationEvent envelope (OrderSubmittedPayload "order-123" 5)
            encoded ^. #messageId `shouldBe` envelope ^. #messageId
            encoded ^. #source `shouldBe` "ordering"
            encoded ^. #destination `shouldBe` "billing.orders.v1"
            encoded ^. #key `shouldBe` Just "order-123"
            encoded ^. #eventType `shouldBe` "OrderSubmitted"
            encoded ^. #schemaVersion `shouldBe` 1
            encoded ^. #contentType `shouldBe` ApplicationJson

        it "emits the canonical wire headers" $ do
            let envelope = sampleIntegrationEnvelope
                headers = integrationHeaders envelope
            Prelude.lookup headerMessageId headers `shouldBe` Just (envelope ^. #messageId)
            Prelude.lookup headerSchemaVersion headers `shouldBe` Just "1"
            Prelude.lookup headerContentType headers `shouldBe` Just "application/json"
            Prelude.lookup headerSchemaSubject headers `shouldBe` Just "billing.orders.v1.OrderSubmitted"
            Prelude.lookup headerSourceEventId headers `shouldBe` Just "018f0f18-17aa-7000-8000-000000000003"
            Prelude.lookup headerSourceGlobalPosition headers `shouldBe` Just "42"
            Prelude.lookup headerTraceParent headers
                `shouldBe` Just "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

        it "preserves a different content type without claiming JSON" $ do
            let envelope =
                    sampleIntegrationEnvelope
                        & #contentType
                        .~ OtherContentType "application/vnd.apache.avro.binary"
                        & #payloadBytes
                        .~ "\x00\x01\x02"
                headers = integrationHeaders envelope
            Prelude.lookup headerContentType headers
                `shouldBe` Just "application/vnd.apache.avro.binary"
            decodeJsonIntegrationEvent envelope
                `shouldBe` ( Left (IntegrationEvent.UnsupportedContentType "application/vnd.apache.avro.binary") ::
                                Either IntegrationEvent.IntegrationEventError OrderSubmittedPayload
                           )

        it "reports malformed JSON payloads as decode errors instead of throwing" $ do
            let envelope =
                    sampleIntegrationEnvelope
                        & #payloadBytes
                        .~ "{not-json"
            case decodeJsonIntegrationEvent envelope :: Either IntegrationEvent.IntegrationEventError OrderSubmittedPayload of
                Left (IntegrationEvent.MalformedPayload _) -> pure ()
                other -> expectationFailure ("expected MalformedPayload, got " <> show other)

        it "reports a JSON value that does not satisfy the target type as DecodeFailed" $ do
            let envelope =
                    sampleIntegrationEnvelope
                        & #payloadBytes
                        .~ "{\"orderId\":\"order-123\"}"
            case decodeJsonIntegrationEvent envelope :: Either IntegrationEvent.IntegrationEventError OrderSubmittedPayload of
                Left (IntegrationEvent.DecodeFailed _) -> pure ()
                other -> expectationFailure ("expected DecodeFailed, got " <> show other)

        it "parses content-type headers back to the canonical type" $ do
            parseContentType "application/json" `shouldBe` ApplicationJson
            parseContentType "Application/JSON" `shouldBe` ApplicationJson
            parseContentType "application/json; charset=utf-8" `shouldBe` ApplicationJson
            parseContentType "APPLICATION/JSON ; CHARSET=UTF-8" `shouldBe` ApplicationJson
            parseContentType "application/vnd.apache.avro.binary"
                `shouldBe` OtherContentType "application/vnd.apache.avro.binary"

        it "preserves the payload bytes through integrationPayload" $ do
            let envelope = sampleIntegrationEnvelope
                encoded = encodeJsonIntegrationEvent envelope (OrderSubmittedPayload "order-123" 5)
            integrationPayload encoded `shouldBe` (encoded ^. #payloadBytes)

    describe "Keiro.Telemetry" $ do
        it "is a pass-through under a noop (Nothing) tracer" $ do
            counter <- newIORef (0 :: Int)
            let envelope = sampleIntegrationEnvelope
                record = OutboxKafka.integrationEventToKafkaRecord envelope
            result <-
                Telemetry.withProducerSpan Nothing envelope record $ \mSpan -> do
                    atomicModifyIORef' counter (\n -> (n + 1, ()))
                    pure (mSpan, "ok" :: Text)
            callsAfter <- readIORef counter
            callsAfter `shouldBe` (1 :: Int)
            snd result `shouldBe` "ok"
            fst result `shouldSatisfy` isNothing

        it "re-exports AttributeKeys whose textual payload matches the spec name" $ do
            attrKeyText Telemetry.messaging_operation_type `shouldBe` "messaging.operation.type"
            attrKeyText Telemetry.messaging_operation_name `shouldBe` "messaging.operation.name"
            attrKeyText Telemetry.messaging_destination_partition_id `shouldBe` "messaging.destination.partition.id"
            attrKeyText Telemetry.messaging_consumer_group_name `shouldBe` "messaging.consumer.group.name"
            attrKeyText Telemetry.messaging_client_id `shouldBe` "messaging.client.id"
            attrKeyTextInt64 Telemetry.messaging_kafka_offset `shouldBe` "messaging.kafka.offset"
            attrKeyText Telemetry.db_system_name `shouldBe` "db.system.name"
            attrKeyText Telemetry.db_namespace `shouldBe` "db.namespace"
            attrKeyText Telemetry.db_collection_name `shouldBe` "db.collection.name"
            attrKeyText Telemetry.db_operation_name `shouldBe` "db.operation.name"
            attrKeyText Telemetry.keiro_stream_name `shouldBe` "keiro.stream.name"
            attrKeyTextInt64 Telemetry.keiro_retry_attempt `shouldBe` "keiro.retry.attempt"
            attrKeyTextInt64 Telemetry.keiro_events_appended `shouldBe` "keiro.events.appended"

        it "extracts a TraceContext from a W3C traceparent header pair" $ do
            let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
                tracestate = "vendor1=value1"
                hs = [(headerTraceParent, traceparent), ("tracestate", tracestate)]
            Telemetry.traceContextFromHeaders hs
                `shouldBe` Just (TraceContext traceparent (Just tracestate))

        it "returns Nothing when the traceparent header is missing" $ do
            Telemetry.traceContextFromHeaders [("content-type", "application/json")]
                `shouldBe` Nothing

        it "injectTraceContext is a no-op when no span is active on the thread" $ do
            let baseline = [("content-type", "application/json")]
            injected <- Telemetry.injectTraceContext baseline
            injected `shouldBe` baseline

        it "traceContextFromCurrentSpan returns Nothing outside any span" $ do
            tc <- Telemetry.traceContextFromCurrentSpan
            tc `shouldBe` Nothing

    describe "Keiro.Workflow" $ around (withFreshStore fixture) $ do
        it "journals each step once, returns Completed, and runs each side effect once" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "demo"
                wid = WorkflowId "demo-1"
            result <- Store.runStoreIO storeHandle $ runWorkflow name wid (demoWorkflow counter)
            result `shouldBe` Right (Completed (1, 2))
            sideEffects <- readIORef counter
            sideEffects `shouldBe` 2
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:demo-demo-1") (StreamVersion 0) 10
            Vector.length recorded `shouldBe` 3
            traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded)
                `shouldSatisfy` \case
                    Right [StepRecorded "first" _ _, StepRecorded "second" _ _, WorkflowCompleted _] -> True
                    _ -> False

        it "replays recorded steps without re-running their side effects" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "replay"
                wid = WorkflowId "r-1"
            first <- Store.runStoreIO storeHandle $ runWorkflow name wid (demoWorkflow counter)
            first `shouldBe` Right (Completed (1, 2))
            afterFirst <- readIORef counter
            afterFirst `shouldBe` 2
            -- A second run with the same id is exactly the crash-restart scenario.
            second <- Store.runStoreIO storeHandle $ runWorkflow name wid (demoWorkflow counter)
            second `shouldBe` Right (Completed (1, 2))
            afterSecond <- readIORef counter
            afterSecond `shouldBe` 2
            -- The deterministic ids and pre-load gating leave the journal at 3 events.
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:replay-r-1") (StreamVersion 0) 10
            Vector.length recorded `shouldBe` 3

        it "reuses the recorded result for a repeated step name in one run" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "samename"
                wid = WorkflowId "s-1"
                duplicateStepWorkflow = do
                    a <- step (StepName "dup") (liftIO (incrementAndRead counter))
                    b <- step (StepName "dup") (liftIO (incrementAndRead counter))
                    pure (a, b)
            result <- Store.runStoreIO storeHandle $ runWorkflow name wid duplicateStepWorkflow
            result `shouldBe` Right (Completed (1, 1))
            sideEffects <- readIORef counter
            sideEffects `shouldBe` 1

        it "suspends on an unresolved awaitStep, journaling no completion" $ \storeHandle -> do
            let name = WorkflowName "awaiter"
                wid = WorkflowId "a-1"
            result <- Store.runStoreIO storeHandle $ runWorkflow name wid neverArmingWorkflow
            result `shouldBe` Right Suspended
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:awaiter-a-1") (StreamVersion 0) 10
            Vector.length recorded `shouldBe` 0

        it "resumes and completes once an awaited step is externally completed" $ \storeHandle -> do
            let name = WorkflowName "awaiter2"
                wid = WorkflowId "a-2"
            suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid neverArmingWorkflow
            suspended `shouldBe` Right Suspended
            -- Simulate a wake source recording the awaited step's resolution.
            Right () <- Store.runStoreIO storeHandle $ do
                now <- liftIO getCurrentTime
                appendJournalEntry name wid (StepRecorded "awk:test" (toJSON (42 :: Int)) now)
            resumed <- Store.runStoreIO storeHandle $ runWorkflow name wid neverArmingWorkflow
            resumed `shouldBe` Right (Completed 42)
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:awaiter2-a-2") (StreamVersion 0) 10
            traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded)
                `shouldSatisfy` \case
                    Right [StepRecorded "awk:test" _ _, WorkflowCompleted _] -> True
                    _ -> False

        it "treats a duplicate external journal append as idempotent" $ \storeHandle -> do
            let name = WorkflowName "duplicate-append"
                wid = WorkflowId "da-1"
                stepKey = "awk:test"
                eventAt t = StepRecorded stepKey (toJSON (42 :: Int)) t
            now <- getCurrentTime
            Right firstId <-
                Store.runStoreIO storeHandle $
                    appendJournalEntryReturningId name wid (eventAt now)
            secondResult <-
                Store.runStoreIO storeHandle $
                    appendJournalEntryReturningId name wid (eventAt now)
            secondId <- case secondResult of
                Right value -> pure value
                Left err -> expectationFailure ("expected idempotent duplicate append, got " <> show err) *> error "unreachable"
            secondId `shouldBe` firstId
            Right indexed <- Store.runStoreIO storeHandle $ loadStepIndex name wid 0
            Map.lookup stepKey indexed `shouldBe` Just (toJSON (42 :: Int))
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:duplicate-append-da-1") (StreamVersion 0) 10
            Vector.length recorded `shouldBe` 1

        it "returns the journaled value when another writer records the same step mid-flight" $ \storeHandle -> do
            let name = WorkflowName "journal-race"
                wid = WorkflowId "jr-1"
                body =
                    step (StepName "raced") $ do
                        now <- liftIO getCurrentTime
                        appendJournalEntry name wid (StepRecorded "raced" (toJSON ("winner" :: Text)) now)
                        pure ("loser" :: Text)
            outcome <- Store.runStoreIO storeHandle $ runWorkflow name wid body
            outcome `shouldBe` Right (Completed "winner")
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:journal-race-jr-1") (StreamVersion 0) 10
            traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded)
                `shouldSatisfy` \case
                    Right [StepRecorded "raced" value _, WorkflowCompleted _] -> value == toJSON ("winner" :: Text)
                    _ -> False

        it "returns the JSON round-trip of a fresh step result" $ \storeHandle -> do
            let name = WorkflowName "roundtrip-step"
                wid = WorkflowId "rs-1"
                body = step (StepName "approx") (pure (Approx 1.7))
            first <- Store.runStoreIO storeHandle $ runWorkflow name wid body
            first `shouldBe` Right (Completed (Approx 2.0))
            replay <- Store.runStoreIO storeHandle $ runWorkflow name wid body
            replay `shouldBe` Right (Completed (Approx 2.0))

        it "throws WorkflowStepDecodeError on the first run when the recorded result cannot decode" $ \storeHandle -> do
            let name = WorkflowName "bad-roundtrip"
                wid = WorkflowId "br-1"
                body = step (StepName "bad") (pure RejectingRoundTrip)
            Store.runStoreIO storeHandle (runWorkflow name wid body)
                `shouldThrow` \case
                    WorkflowStepDecodeError key _ -> key == "bad"
                    _ -> False
            Store.runStoreIO storeHandle (stepExists name wid 0 "bad")
                `shouldReturn` Right True

        it "discovers unfinished workflows via the step index" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            Right (Completed _) <-
                Store.runStoreIO storeHandle $
                    runWorkflow (WorkflowName "done") (WorkflowId "d-1") (demoWorkflow counter)
            Right Suspended <-
                Store.runStoreIO storeHandle $
                    runWorkflow (WorkflowName "pending") (WorkflowId "p-1") (stepThenAwaitWorkflow counter)
            now <- getCurrentTime
            Right unfinished <- Store.runStoreIO storeHandle (findUnfinishedWorkflowIds now)
            unfinished `shouldBe` [("p-1", "pending")]

    describe "Keiro.Workflow instance table" $ around (withFreshStore fixture) $ do
        it "creates and completes a workflow instance row transactionally with the journal" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "inst-complete"
                wid = WorkflowId "ic-1"
            Right (Completed _) <- Store.runStoreIO storeHandle $ runWorkflow name wid (demoWorkflow counter)
            Right (Just row) <- Store.runStoreIO storeHandle $ Instance.lookupInstance name wid
            row ^. #workflowId `shouldBe` "ic-1"
            row ^. #workflowName `shouldBe` "inst-complete"
            row ^. #generation `shouldBe` 0
            row ^. #status `shouldBe` Instance.WfCompleted
            row ^. #completedAt `shouldSatisfy` isJust

        it "records suspended status for workflows that park before journaling" $ \storeHandle -> do
            let name = WorkflowName "inst-suspended"
                wid = WorkflowId "is-1"
            Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid neverArmingWorkflow
            Right (Just row) <- Store.runStoreIO storeHandle $ Instance.lookupInstance name wid
            row ^. #status `shouldBe` Instance.WfSuspended
            row ^. #generation `shouldBe` 0
            row ^. #completedAt `shouldBe` Nothing

        it "creates child instance rows at spawn time and flips them to cancelled" $ \storeHandle -> do
            let childWid = WorkflowId "inst-child"
                childName = WorkflowName "ship"
            Right Suspended <-
                Store.runStoreIO storeHandle $
                    runWorkflow (WorkflowName "inst-parent") (WorkflowId "ip-1") (parentWorkflow childWid)
            Right (Just spawned) <- Store.runStoreIO storeHandle $ Instance.lookupInstance childName childWid
            spawned ^. #status `shouldBe` Instance.WfRunning
            Right True <- Store.runStoreIO storeHandle $ cancelChild (ChildHandle childName childWid)
            Right (Just cancelledRow) <- Store.runStoreIO storeHandle $ Instance.lookupInstance childName childWid
            cancelledRow ^. #status `shouldBe` Instance.WfCancelled
            cancelledRow ^. #completedAt `shouldSatisfy` isJust

        it "bumps the instance generation when continueAsNew rotates" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "inst-rotate"
                wid = WorkflowId "ir-1"
            Right ContinuedAsNew <-
                Store.runStoreIO storeHandle $
                    runWorkflow name wid (rollingTotal counter 1 2)
            Right (Just row) <- Store.runStoreIO storeHandle $ Instance.lookupInstance name wid
            row ^. #generation `shouldBe` 1
            row ^. #status `shouldBe` Instance.WfRunning

        it "does not let a late append resurrect a terminal instance row" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "inst-terminal"
                wid = WorkflowId "it-1"
            Right (Completed _) <- Store.runStoreIO storeHandle $ runWorkflow name wid (demoWorkflow counter)
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry name wid (StepRecorded "late" (toJSON True) now)
            Right (Just row) <- Store.runStoreIO storeHandle $ Instance.lookupInstance name wid
            row ^. #status `shouldBe` Instance.WfCompleted

        it "discovers unfinished workflows from the instance table" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let completedName = WorkflowName "discover-completed"
                cancelledName = WorkflowName "discover-cancelled"
                crashedName = WorkflowName "discover-crashed"
                rotatedName = WorkflowName "discover-rotated"
            Right (Completed _) <-
                Store.runStoreIO storeHandle $
                    runWorkflow completedName (WorkflowId "done") (demoWorkflow counter)
            cancelledAt <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry cancelledName (WorkflowId "cancelled") (WorkflowCancelled cancelledAt)
            Left (_ :: SimulatedCrash) <-
                try $
                    Store.runStoreIO storeHandle $
                        runWorkflow crashedName (WorkflowId "crashed") (crashAfterStep1 counter)
            Right ContinuedAsNew <-
                Store.runStoreIO storeHandle $
                    runWorkflow rotatedName (WorkflowId "rotated") (rollingTotal counter 1 2)
            now <- getCurrentTime
            Right unfinished <- Store.runStoreIO storeHandle (findUnfinishedWorkflowIds now)
            unfinished
                `shouldBe` [ ("crashed", "discover-crashed")
                           , ("rotated", "discover-rotated")
                           ]

    describe "Keiro.Workflow snapshots" $ around (withFreshStore fixture) $ do
        -- Validation (a): a snapshot row appears at the expected version and
        -- decodes to the full accumulated step map.
        it "writes a snapshot of the accumulated step map after Every 2 fires" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "snap"
                wid = WorkflowId "w1"
            result <-
                Store.runStoreIO storeHandle $
                    runWorkflowWith
                        (defaultWorkflowRunOptions & #snapshotPolicy .~ Every 2)
                        name
                        wid
                        (countingSixSteps counter)
            result `shouldBe` Right (Completed [1, 2, 3, 4, 5, 6])
            -- Every 2 fired at versions 2, 4, 6; the upsert keeps the highest (6).
            Right snapVersion <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "wf:snap-w1" snapshotVersionForStreamStmt
            snapVersion `shouldBe` Just (StreamVersion 6)
            -- and the row decodes to the six-entry accumulated map.
            Right mSeed <- Store.runStoreIO storeHandle $ loadWorkflowSnapshot (StreamName "wf:snap-w1")
            case mSeed of
                Just (m, v) -> do
                    v `shouldBe` StreamVersion 6
                    Map.keys m `shouldBe` ["s1", "s2", "s3", "s4", "s5", "s6"]
                Nothing -> expectationFailure "expected a workflow snapshot row"

        -- The OnTerminal completion-site wiring: only the final WorkflowCompleted
        -- append (version 7) triggers the snapshot.
        it "writes a terminal snapshot under OnTerminal at the completion version" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "term"
                wid = WorkflowId "tm1"
            result <-
                Store.runStoreIO storeHandle $
                    runWorkflowWith
                        (defaultWorkflowRunOptions & #snapshotPolicy .~ OnTerminal)
                        name
                        wid
                        (countingSixSteps counter)
            result `shouldBe` Right (Completed [1, 2, 3, 4, 5, 6])
            Right snapVersion <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement "wf:term-tm1" snapshotVersionForStreamStmt
            snapVersion `shouldBe` Just (StreamVersion 7)

        -- Validation (b): re-hydration reads only the tail after the snapshot
        -- version, and the journaled steps short-circuit (the counter stays put).
        it "reads only the tail after the snapshot version on re-hydration" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "tail"
                wid = WorkflowId "t1"
                opts = defaultWorkflowRunOptions & #snapshotPolicy .~ Every 2
            first <- Store.runStoreIO storeHandle $ runWorkflowWith opts name wid (countingSixSteps counter)
            first `shouldBe` Right (Completed [1, 2, 3, 4, 5, 6])
            afterFirst <- readIORef counter
            afterFirst `shouldBe` 6
            -- A full version-0 replay would read every journal event...
            Right full <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:tail-t1") (StreamVersion 0) 100
            Vector.length full `shouldBe` 7 -- six StepRecorded + one WorkflowCompleted
            -- ...whereas the runtime seeds from the snapshot and reads only the tail.
            Right (Just (seedMap, StreamVersion sv)) <-
                Store.runStoreIO storeHandle $ loadWorkflowSnapshot (StreamName "wf:tail-t1")
            Map.size seedMap `shouldBe` 6
            Right tailEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:tail-t1") (StreamVersion sv) 100
            Vector.length tailEvents `shouldSatisfy` (< Vector.length full)
            Vector.length tailEvents `shouldBe` 1 -- only the WorkflowCompleted at v7
            -- Re-hydration completes from the seed without re-running any step.
            second <- Store.runStoreIO storeHandle $ runWorkflowWith opts name wid (countingSixSteps counter)
            second `shouldBe` Right (Completed [1, 2, 3, 4, 5, 6])
            afterSecond <- readIORef counter
            afterSecond `shouldBe` 6

        -- Validation (c): a Never run and an Every 2 run produce identical results
        -- and identical journals, and the snapshot seed equals a full replay.
        it "produces identical results and journals under Never and Every 2" $ \storeHandle -> do
            counterN <- newIORef (0 :: Int)
            counterE <- newIORef (0 :: Int)
            neverRes <-
                Store.runStoreIO storeHandle $
                    runWorkflowWith
                        (defaultWorkflowRunOptions & #snapshotPolicy .~ Never)
                        (WorkflowName "corr-never")
                        (WorkflowId "c1")
                        (countingSixSteps counterN)
            everyRes <-
                Store.runStoreIO storeHandle $
                    runWorkflowWith
                        (defaultWorkflowRunOptions & #snapshotPolicy .~ Every 2)
                        (WorkflowName "corr-every")
                        (WorkflowId "c1")
                        (countingSixSteps counterE)
            neverRes `shouldBe` Right (Completed [1, 2, 3, 4, 5, 6])
            everyRes `shouldBe` Right (Completed [1, 2, 3, 4, 5, 6])
            Right neverEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:corr-never-c1") (StreamVersion 0) 100
            Right everyEvents <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:corr-every-c1") (StreamVersion 0) 100
            let stepResults evs =
                    [ (k, v)
                    | Right (StepRecorded k v _) <- decodeRecorded workflowJournalCodec <$> Vector.toList evs
                    ]
            stepResults neverEvents `shouldBe` stepResults everyEvents
            -- The snapshot seed equals the map a full version-0 replay would fold.
            Right (Just (seedMap, _)) <-
                Store.runStoreIO storeHandle $ loadWorkflowSnapshot (StreamName "wf:corr-every-c1")
            seedMap `shouldBe` Map.fromList (stepResults everyEvents)

        -- Validation (d): an advisory snapshot whose discriminant no longer matches
        -- is ignored and the workflow hydrates via full replay.
        it "hydrates via full replay when the snapshot discriminant mismatches" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "dmiss"
                wid = WorkflowId "d1"
                opts = defaultWorkflowRunOptions & #snapshotPolicy .~ Every 2
            _ <- Store.runStoreIO storeHandle $ runWorkflowWith opts name wid (countingSixSteps counter)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("wf:dmiss-d1", "stale-shape") corruptSnapshotShapeStmt
            Right mSeed <- Store.runStoreIO storeHandle $ loadWorkflowSnapshot (StreamName "wf:dmiss-d1")
            mSeed `shouldBe` Nothing
            resumed <- Store.runStoreIO storeHandle $ runWorkflowWith opts name wid (countingSixSteps counter)
            resumed `shouldBe` Right (Completed [1, 2, 3, 4, 5, 6])

        -- Validation (d), second arm: corrupt snapshot JSON is treated as a miss.
        it "hydrates via full replay when the snapshot JSON is corrupt" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "cjson"
                wid = WorkflowId "d2"
                opts = defaultWorkflowRunOptions & #snapshotPolicy .~ Every 2
            _ <- Store.runStoreIO storeHandle $ runWorkflowWith opts name wid (countingSixSteps counter)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("wf:cjson-d2", Aeson.String "bad") corruptSnapshotStateStmt
            Right mSeed <- Store.runStoreIO storeHandle $ loadWorkflowSnapshot (StreamName "wf:cjson-d2")
            mSeed `shouldBe` Nothing
            resumed <- Store.runStoreIO storeHandle $ runWorkflowWith opts name wid (countingSixSteps counter)
            resumed `shouldBe` Right (Completed [1, 2, 3, 4, 5, 6])

    describe "Keiro.Workflow.Resume" $ around (withFreshStore fixture) $ do
        -- M2: crash mid-run, then a resume pass drives the workflow to Completed
        -- without re-running the already-journaled step.
        it "resumes a crashed mid-run workflow, running only the un-journaled tail" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "crash-demo"
                wid = WorkflowId "cd-1"
            -- Simulate a crash after step 1's append has committed.
            crashed <-
                try
                    ( Store.runStoreIO storeHandle $
                        runWorkflow name wid (crashAfterStep1 counter)
                    ) ::
                    IO (Either SomeException (Either Store.StoreError (WorkflowOutcome (Int, Int, Int))))
            case crashed of
                Left _ -> pure () -- the SimulatedCrash unwound the run, as intended
                Right other -> expectationFailure ("expected a simulated crash, got " <> show other)
            readIORef counter >>= \c -> c `shouldBe` 1
            -- Resume with a registry mapping the name to the FULL definition.
            let registry = Map.singleton name (WorkflowDef (\_wid -> threeStep counter))
            Right summary <-
                Store.runStoreIO storeHandle $ resumeWorkflowsOnce defaultWorkflowResumeOptions registry
            summary
                `shouldBe` ResumeSummary
                    { discovered = 1
                    , resumed = 1
                    , completed = 1
                    , stillSuspended = 0
                    , unknownName = 0
                    , failed = 0
                    , transientErrors = 0
                    , leaseSkipped = 0
                    }
            -- Step 1 short-circuited; steps 2 and 3 ran exactly once.
            readIORef counter >>= \c -> c `shouldBe` 3
            -- The journal now holds s1, s2, s3, WorkflowCompleted.
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:crash-demo-cd-1") (StreamVersion 0) 10
            traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded)
                `shouldSatisfy` \case
                    Right [StepRecorded "s1" _ _, StepRecorded "s2" _ _, StepRecorded "s3" _ _, WorkflowCompleted _] -> True
                    _ -> False
            -- A second pass discovers nothing — the workflow is finished.
            Right summary2 <-
                Store.runStoreIO storeHandle $ resumeWorkflowsOnce defaultWorkflowResumeOptions registry
            summary2 `shouldBe` emptyResumeSummary

        -- M3: a workflow suspended on an awaited step is driven to Completed once
        -- that step is journaled (here simulated; an EP-39/EP-40 wake source would
        -- journal the same StepRecorded end to end).
        it "resumes a suspended workflow once its awaited step is journaled" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "await-demo"
                wid = WorkflowId "ad-1"
            suspended <-
                Store.runStoreIO storeHandle $ runWorkflow name wid (awaitingThenStep counter)
            suspended `shouldBe` Right Suspended
            -- Simulate the wake source resolving the await.
            Right () <- Store.runStoreIO storeHandle $ do
                now <- liftIO getCurrentTime
                appendJournalEntry name wid (StepRecorded "awk:approval" (toJSON ("ok" :: Text)) now)
            let registry = Map.singleton name (WorkflowDef (\_wid -> awaitingThenStep counter))
            Right summary <-
                Store.runStoreIO storeHandle $ resumeWorkflowsOnce defaultWorkflowResumeOptions registry
            summary
                `shouldBe` ResumeSummary
                    { discovered = 1
                    , resumed = 1
                    , completed = 1
                    , stillSuspended = 0
                    , unknownName = 0
                    , failed = 0
                    , transientErrors = 0
                    , leaseSkipped = 0
                    }
            readIORef counter >>= \c -> c `shouldBe` 1
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:await-demo-ad-1") (StreamVersion 0) 10
            traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded)
                `shouldSatisfy` \case
                    Right [StepRecorded "awk:approval" _ _, StepRecorded "use" _ _, WorkflowCompleted _] -> True
                    _ -> False

        -- M4: a discovered workflow whose name is absent from the registry is
        -- skipped and counted, never silently dropped or fatal.
        it "skips and counts a workflow whose name is absent from the registry" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "orphan"
                wid = WorkflowId "or-1"
            crashed <-
                try
                    ( Store.runStoreIO storeHandle $
                        runWorkflow name wid (crashAfterStep1 counter)
                    ) ::
                    IO (Either SomeException (Either Store.StoreError (WorkflowOutcome (Int, Int, Int))))
            case crashed of
                Left _ -> pure ()
                Right other -> expectationFailure ("expected a simulated crash, got " <> show other)
            -- Empty registry: the orphan is surfaced via unknownName, not completed.
            Right summary <-
                Store.runStoreIO storeHandle $ resumeWorkflowsOnce defaultWorkflowResumeOptions Map.empty
            summary
                `shouldBe` ResumeSummary
                    { discovered = 1
                    , resumed = 0
                    , completed = 0
                    , stillSuspended = 0
                    , unknownName = 1
                    , failed = 0
                    , transientErrors = 0
                    , leaseSkipped = 0
                    }
            -- The journal is unchanged: still one step, no completion.
            Right recorded <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:orphan-or-1") (StreamVersion 0) 10
            Vector.length recorded `shouldBe` 1

        it "isolates a poison workflow so a healthy workflow still completes" $ \storeHandle -> do
            healthyCounter <- newIORef (0 :: Int)
            let poisonName = WorkflowName "poison"
                poisonId = WorkflowId "poison-1"
                healthyName = WorkflowName "healthy"
                healthyId = WorkflowId "healthy-1"
                opts =
                    defaultWorkflowResumeOptions
                        & #maxAttempts
                        .~ 1
                        & #logEvent
                        .~ const (pure ())
                registry =
                    Map.fromList
                        [ (poisonName, WorkflowDef (\_ -> liftIO (throwIO SimulatedCrash) *> pure (0 :: Int)))
                        , (healthyName, WorkflowDef (\_ -> threeStep healthyCounter))
                        ]
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry poisonName poisonId (StepRecorded "seed" (toJSON True) now)
            crashed <-
                try
                    ( Store.runStoreIO storeHandle $
                        runWorkflow healthyName healthyId (crashAfterStep1 healthyCounter)
                    ) ::
                    IO (Either SomeException (Either Store.StoreError (WorkflowOutcome (Int, Int, Int))))
            case crashed of
                Left _ -> pure ()
                Right other -> expectationFailure ("expected a simulated crash, got " <> show other)
            Right summary <- Store.runStoreIO storeHandle $ resumeWorkflowsOnce opts registry
            summary
                `shouldBe` emptyResumeSummary
                    { discovered = 2
                    , resumed = 2
                    , completed = 1
                    , failed = 1
                    }
            readIORef healthyCounter >>= \c -> c `shouldBe` 3
            Right (Just poisonRow) <- Store.runStoreIO storeHandle $ Instance.lookupInstance poisonName poisonId
            poisonRow ^. #status `shouldBe` Instance.WfFailed

        it "marks a crashing workflow failed and short-circuits later direct runs" $ \storeHandle -> do
            let name = WorkflowName "terminal-poison"
                wid = WorkflowId "tp-1"
                opts =
                    defaultWorkflowResumeOptions
                        & #maxAttempts
                        .~ 1
                        & #logEvent
                        .~ const (pure ())
                registry = Map.singleton name (WorkflowDef (\_ -> liftIO (throwIO SimulatedCrash) *> pure (0 :: Int)))
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry name wid (StepRecorded "seed" (toJSON True) now)
            Right summary <- Store.runStoreIO storeHandle $ resumeWorkflowsOnce opts registry
            failed summary `shouldBe` 1
            Right (Just row) <- Store.runStoreIO storeHandle $ Instance.lookupInstance name wid
            row ^. #status `shouldBe` Instance.WfFailed
            row ^. #attempts `shouldBe` 1
            direct <- Store.runStoreIO storeHandle $ runWorkflow name wid (step (StepName "never") (pure (1 :: Int)))
            direct `shouldBe` Right Failed
            Right recordedFailed <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:terminal-poison-tp-1") (StreamVersion 0) 10
            traverse (decodeRecorded workflowJournalCodec) (Vector.toList recordedFailed)
                `shouldSatisfy` \case
                    Right events -> any (\case WorkflowFailed{} -> True; _ -> False) events
                    _ -> False

        it "classifies thrown store errors as transient without consuming attempts" $ \storeHandle -> do
            let name = WorkflowName "transient"
                wid = WorkflowId "tr-1"
                opts = defaultWorkflowResumeOptions & #logEvent .~ const (pure ())
                registry =
                    Map.singleton name $
                        WorkflowDef
                            ( \_ -> do
                                _ <- throwError (Store.ConnectionLost "boom")
                                pure (0 :: Int)
                            )
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry name wid (StepRecorded "seed" (toJSON True) now)
            Right summary <- Store.runStoreIO storeHandle $ resumeWorkflowsOnce opts registry
            transientErrors summary `shouldBe` 1
            failed summary `shouldBe` 0
            Right (Just row) <- Store.runStoreIO storeHandle $ Instance.lookupInstance name wid
            row ^. #attempts `shouldBe` 0
            row ^. #status `shouldBe` Instance.WfRunning

        it "keeps the fixed-poll loop alive when one pass contains a poison workflow" $ \storeHandle -> do
            done <- newEmptyMVar
            healthyCounter <- newIORef (0 :: Int)
            let poisonName = WorkflowName "fixed-loop-poison"
                poisonId = WorkflowId "flp-1"
                healthyName = WorkflowName "fixed-loop-healthy"
                healthyId = WorkflowId "flh-1"
                opts =
                    defaultWorkflowResumeOptions
                        & #pollInterval
                        .~ 50_000
                        & #maxAttempts
                        .~ 1
                        & #logEvent
                        .~ const (pure ())
                healthyBody = threeStepThenSignal healthyCounter done
                registry =
                    Map.fromList
                        [ (poisonName, WorkflowDef (\_ -> liftIO (throwIO SimulatedCrash) *> pure (0 :: Int)))
                        , (healthyName, WorkflowDef (\_ -> healthyBody))
                        ]
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry poisonName poisonId (StepRecorded "seed" (toJSON True) now)
            crashed <-
                try
                    ( Store.runStoreIO storeHandle $
                        runWorkflow healthyName healthyId (crashAfterStep1 healthyCounter)
                    ) ::
                    IO (Either SomeException (Either Store.StoreError (WorkflowOutcome (Int, Int, Int))))
            case crashed of
                Left _ -> pure ()
                Right other -> expectationFailure ("expected a simulated crash, got " <> show other)
            worker <- forkIO (void (Store.runStoreIO storeHandle (runWorkflowResumeWorkerWith opts registry)))
            completed <- timeout 5_000_000 (takeMVar done)
            status <- threadStatus worker
            killThread worker
            completed `shouldBe` Just ()
            status `shouldSatisfy` \case
                ThreadFinished -> False
                ThreadDied -> False
                _ -> True

        it "claims one workflow instance for a single live owner and releases it" $ \storeHandle -> do
            let name = WorkflowName "lease-claim"
                wid = WorkflowId "lc-1"
            Right claimedA <- Store.runStoreIO storeHandle $ Instance.claimInstance "owner-a" 30 name wid
            claimedA `shouldBe` True
            Right claimedB <- Store.runStoreIO storeHandle $ Instance.claimInstance "owner-b" 30 name wid
            claimedB `shouldBe` False
            Right () <- Store.runStoreIO storeHandle $ Instance.releaseInstance "owner-a" False name wid
            Right claimedBAfterRelease <- Store.runStoreIO storeHandle $ Instance.claimInstance "owner-b" 30 name wid
            claimedBAfterRelease `shouldBe` True

        it "lets an expired workflow lease be taken and resets attempts on progressed release" $ \storeHandle -> do
            let name = WorkflowName "lease-expire"
                wid = WorkflowId "le-1"
            Right claimedA <- Store.runStoreIO storeHandle $ Instance.claimInstance "owner-a" 30 name wid
            claimedA `shouldBe` True
            Right attempt <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Instance.recordCrashTx "le-1" "lease-expire" "boom"
            attempt `shouldBe` 1
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.sql "UPDATE keiro.keiro_workflows SET lease_expires_at = now() - interval '1 second', next_attempt_at = now() - interval '1 second' WHERE workflow_id = 'le-1' AND workflow_name = 'lease-expire'"
            Right claimedB <- Store.runStoreIO storeHandle $ Instance.claimInstance "owner-b" 30 name wid
            claimedB `shouldBe` True
            Right () <- Store.runStoreIO storeHandle $ Instance.releaseInstance "owner-b" True name wid
            Right (Just row) <- Store.runStoreIO storeHandle $ Instance.lookupInstance name wid
            row ^. #attempts `shouldBe` 0
            row ^. #lastError `shouldBe` Nothing
            row ^. #nextAttemptAt `shouldBe` Nothing
            row ^. #leasedBy `shouldBe` Nothing

        it "skips a resume candidate held by another live lease owner" $ \storeHandle -> do
            ran <- newIORef False
            let name = WorkflowName "lease-skip"
                wid = WorkflowId "ls-1"
                registry =
                    Map.singleton name $
                        WorkflowDef
                            ( \_ -> do
                                liftIO (writeIORef ran True)
                                pure (0 :: Int)
                            )
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry name wid (StepRecorded "seed" (toJSON True) now)
            Right foreignClaim <- Store.runStoreIO storeHandle $ Instance.claimInstance "foreign-owner" 30 name wid
            foreignClaim `shouldBe` True
            Right summary <- Store.runStoreIO storeHandle $ resumeWorkflowsOnce defaultWorkflowResumeOptions registry
            summary
                `shouldBe` emptyResumeSummary
                    { discovered = 1
                    , leaseSkipped = 1
                    }
            readIORef ran `shouldReturn` False

        -- M4: resume on an already-completed workflow is a genuine no-op.
        it "discovers nothing for an already-completed workflow and is stable" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "done-demo"
                wid = WorkflowId "dd-1"
            done <- Store.runStoreIO storeHandle $ runWorkflow name wid (threeStep counter)
            done `shouldBe` Right (Completed (1, 2, 3))
            readIORef counter >>= \c -> c `shouldBe` 3
            let registry = Map.singleton name (WorkflowDef (\_wid -> threeStep counter))
            Right summary1 <-
                Store.runStoreIO storeHandle $ resumeWorkflowsOnce defaultWorkflowResumeOptions registry
            summary1 `shouldBe` emptyResumeSummary
            Right summary2 <-
                Store.runStoreIO storeHandle $ resumeWorkflowsOnce defaultWorkflowResumeOptions registry
            summary2 `shouldBe` emptyResumeSummary
            readIORef counter >>= \c -> c `shouldBe` 3

    describe "Keiro.Workflow continue-as-new" $ around (withFreshStore fixture) $ do
        -- EP-48 headline proof (Checks 1 & 2): a 300-step rolling-total workflow that
        -- rotates every 50 steps keeps each physical generation journal bounded by
        -- K = rotateEvery + 2 (at most rotateEvery work steps + the one seed step that
        -- opened the generation + the one terminal marker), yet returns the correct
        -- final total. A single non-rotating run would put all 300 steps on one
        -- journal and the per-generation `<= K` bound would fail.
        it "rotates a long workflow, bounds each generation, and returns the correct total" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "roller"
                wid = WorkflowId "r-1"
                rotateEvery = 50 :: Int
                total = 300 :: Int
                k = rotateEvery + 2
                body = rollingTotal counter rotateEvery total
                -- Re-invoke runWorkflow until it Completes; each call resolves and
                -- advances the current generation, exactly as the resume worker does.
                drive :: Int -> IO Int
                drive budget
                    | budget <= 0 =
                        expectationFailure "workflow did not complete within the rotation budget" >> pure (-1)
                    | otherwise = do
                        outcome <- Store.runStoreIO storeHandle (runWorkflow name wid body)
                        case outcome of
                            Right ContinuedAsNew -> drive (budget - 1)
                            Right (Completed t) -> pure t
                            other -> expectationFailure ("unexpected outcome: " <> show other) >> pure (-1)
            -- The first invocation rotates (generation 0 did rotateEvery steps).
            firstOutcome <- Store.runStoreIO storeHandle (runWorkflow name wid body)
            firstOutcome `shouldBe` Right ContinuedAsNew
            -- Drive the remaining generations to completion (bounded passes).
            finalTotal <- drive (total `div` rotateEvery + 3)
            -- Check 2: correct result, and each side effect ran exactly once.
            finalTotal `shouldBe` total
            readIORef counter >>= (`shouldBe` total)
            -- The workflow rotated to its final generation (300/50 = 6 generations: 0..5).
            Right gen <- Store.runStoreIO storeHandle (currentGeneration name wid)
            gen `shouldBe` (total `div` rotateEvery - 1)
            -- Check 1: every generation's physical journal is bounded by K, and the
            -- total is split ACROSS generations (bounded per generation, not in
            -- aggregate). Each generation holds exactly 1 seed + rotateEvery work + 1
            -- marker = K events, so the sum is total + 2 per generation.
            lengths <-
                traverse
                    ( \g -> do
                        let streamName = workflowGenerationStreamName name wid g
                        Right evs <- Store.runStoreIO storeHandle (Store.readStreamForward streamName (StreamVersion 0) 1000)
                        pure (Vector.length evs)
                    )
                    [0 .. gen]
            for_ lengths (`shouldSatisfy` (<= k))
            sum lengths `shouldBe` (total + 2 * (gen + 1))
            -- The first generation ends with a rotation marker; the last with a
            -- completion marker.
            Right gen0evs <- Store.runStoreIO storeHandle (Store.readStreamForward (workflowGenerationStreamName name wid 0) (StreamVersion 0) 1000)
            (decodeRecorded workflowJournalCodec <$> Vector.toList gen0evs)
                `shouldSatisfy` any
                    ( \case
                        Right (WorkflowContinuedAsNew 1 _) -> True
                        _ -> False
                    )
            Right lastEvs <- Store.runStoreIO storeHandle (Store.readStreamForward (workflowGenerationStreamName name wid gen) (StreamVersion 0) 1000)
            (decodeRecorded workflowJournalCodec <$> Vector.toList lastEvs)
                `shouldSatisfy` any
                    ( \case
                        Right (WorkflowCompleted _) -> True
                        _ -> False
                    )

        -- EP-48 Check 3: discovery and resume follow the CURRENT generation. After a
        -- rotation the rotated (newer) generation is unfinished and discoverable —
        -- the older generation's WorkflowContinuedAsNew marker does NOT mask it — and
        -- the resume worker drives the rotated generation forward to completion.
        it "rediscovers and resumes a rotated workflow on its current generation" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "roller2"
                wid = WorkflowId "r-2"
                rotateEvery = 50 :: Int
                total = 150 :: Int
                registry = Map.singleton name (WorkflowDef (\_ -> rollingTotal counter rotateEvery total))
                resumeUntilDone :: Int -> IO ()
                resumeUntilDone budget
                    | budget <= 0 = expectationFailure "resume did not complete the rotated workflow"
                    | otherwise = do
                        Right summary <-
                            Store.runStoreIO storeHandle (resumeWorkflowsOnce defaultWorkflowResumeOptions registry)
                        if completed summary == 1 then pure () else resumeUntilDone (budget - 1)
            -- First run rotates onto generation 1.
            firstOutcome <- Store.runStoreIO storeHandle (runWorkflow name wid (rollingTotal counter rotateEvery total))
            firstOutcome `shouldBe` Right ContinuedAsNew
            -- The rotated current generation (1) is unfinished and discoverable.
            now <- getCurrentTime
            Right unfinished <- Store.runStoreIO storeHandle (findUnfinishedWorkflowIds now)
            unfinished `shouldBe` [("r-2", "roller2")]
            -- The resume worker drives the rotated generation(s) to completion.
            resumeUntilDone (total `div` rotateEvery + 3)
            readIORef counter >>= (`shouldBe` total)
            -- Finished: discovery now reports nothing for it.
            finalNow <- getCurrentTime
            Right finalUnfinished <- Store.runStoreIO storeHandle (findUnfinishedWorkflowIds finalNow)
            finalUnfinished `shouldBe` []

    describe "Keiro.Workflow patch API" $ around (withFreshStore fixture) $ do
        it "an in-flight instance observes the OLD branch; a fresh instance the NEW branch; the decision is journaled once and stable" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "patchwf"
                inflight = WorkflowId "inflight-1"
                fresh = WorkflowId "fresh-1"
                patchOptions = defaultWorkflowRunOptions & #activePatches .~ Set.singleton fraudPatchId

            -- 1. Run the in-flight instance to a suspension under the PRE-patch code.
            pre <- Store.runStoreIO storeHandle $ runWorkflow name inflight (prePatchWorkflow counter)
            pre `shouldBe` Right Suspended

            -- 2. Redeploy: re-run the SAME instance id under the POST-patch code. It
            --    already journaled reserve-inventory, so it is in flight -> False.
            r1 <- Store.runStoreIO storeHandle $ runWorkflowWith patchOptions name inflight (postPatchWorkflow counter)
            r1 `shouldBe` Right (Completed "old-branch")

            -- 3. Replay the in-flight instance again: same OLD branch, every time.
            r2 <- Store.runStoreIO storeHandle $ runWorkflowWith patchOptions name inflight (postPatchWorkflow counter)
            r2 `shouldBe` Right (Completed "old-branch")

            -- 4. A fresh instance under the POST-patch code takes the NEW branch.
            f1 <- Store.runStoreIO storeHandle $ runWorkflowWith patchOptions name fresh (postPatchWorkflow counter)
            f1 `shouldBe` Right (Completed "new-branch")
            -- and stays on the new branch on replay.
            f2 <- Store.runStoreIO storeHandle $ runWorkflowWith patchOptions name fresh (postPatchWorkflow counter)
            f2 `shouldBe` Right (Completed "new-branch")

            -- 5. The patch decision is journaled exactly once per instance, with the
            --    expected Bool, on the patch:<id> key.
            Right inflightJournal <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:patchwf-inflight-1") (StreamVersion 0) 20
            let inflightDecisions =
                    [ v
                    | Right ev <- map (decodeRecorded workflowJournalCodec) (Vector.toList inflightJournal)
                    , StepRecorded k v _ <- [ev]
                    , k == patchStepName fraudPatchId
                    ]
            inflightDecisions `shouldBe` [toJSON False]

            Right freshJournal <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (StreamName "wf:patchwf-fresh-1") (StreamVersion 0) 20
            let freshDecisions =
                    [ v
                    | Right ev <- map (decodeRecorded workflowJournalCodec) (Vector.toList freshJournal)
                    , StepRecorded k v _ <- [ev]
                    , k == patchStepName fraudPatchId
                    ]
            freshDecisions `shouldBe` [toJSON True]
            let freshPatchSets =
                    [ v
                    | Right ev <- map (decodeRecorded workflowJournalCodec) (Vector.toList freshJournal)
                    , StepRecorded k v _ <- [ev]
                    , k == patchSetStepName
                    ]
            freshPatchSets `shouldBe` [toJSON [unPatchId fraudPatchId]]

        it "a fresh instance suspended before its patch call still takes the NEW branch" $ \storeHandle -> do
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "patch-after-suspend"
                wid = WorkflowId "pas-1"
                patchOptions = defaultWorkflowRunOptions & #activePatches .~ Set.singleton fraudPatchId
            Right Suspended <-
                Store.runStoreIO storeHandle $
                    runWorkflowWith patchOptions name wid (postPatchAfterSuspendWorkflow counter)
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry name wid (StepRecorded "awk:gate" Aeson.Null now)
            resumed <-
                Store.runStoreIO storeHandle $
                    runWorkflowWith patchOptions name wid (postPatchAfterSuspendWorkflow counter)
            resumed `shouldBe` Right (Completed "new-branch")

        it "an in-flight instance with only wake-source completions stays on the OLD branch" $ \storeHandle -> do
            let name = WorkflowName "patch-wake-only"
                wid = WorkflowId "pwo-1"
                patchOptions = defaultWorkflowRunOptions & #activePatches .~ Set.singleton fraudPatchId
            Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid prePatchWakeOnlyWorkflow
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry name wid (StepRecorded "awk:gate" Aeson.Null now)
            resumed <-
                Store.runStoreIO storeHandle $
                    runWorkflowWith patchOptions name wid postPatchWakeOnlyWorkflow
            resumed `shouldBe` Right (Completed "old-branch")

        it "records the active patch set again for a fresh rotated generation" $ \storeHandle -> do
            let name = WorkflowName "patch-rotating"
                wid = WorkflowId "pr-1"
                patchOptions = defaultWorkflowRunOptions & #activePatches .~ Set.singleton fraudPatchId
            first <- Store.runStoreIO storeHandle $ runWorkflowWith patchOptions name wid rotatingPatchWorkflow
            first `shouldBe` Right ContinuedAsNew
            second <- Store.runStoreIO storeHandle $ runWorkflowWith patchOptions name wid rotatingPatchWorkflow
            second `shouldBe` Right (Completed "new-branch")
            Right gen1Journal <-
                Store.runStoreIO storeHandle $
                    Store.readStreamForward (workflowGenerationStreamName name wid 1) (StreamVersion 0) 20
            let gen1PatchSets =
                    [ v
                    | Right ev <- map (decodeRecorded workflowJournalCodec) (Vector.toList gen1Journal)
                    , StepRecorded k v _ <- [ev]
                    , k == patchSetStepName
                    ]
            gen1PatchSets `shouldBe` [toJSON [unPatchId fraudPatchId]]

    describe "Keiro.Wake" $ around (withFreshStore fixture) $ do
        -- EP-50: the wake primitive over kiroku's existing per-store notifier.
        it "returns WokenByTimeout when idle (no append)" $ \store -> do
            wake <- wakeSignalFromStore store
            reason <- waitForWake wake 200000 -- 200 ms
            reason `shouldBe` WokenByTimeout

        it "returns WokenByNotify promptly after a real append" $ \store -> do
            wake <- wakeSignalFromStore store
            -- A real append bumps the streams row and fires kiroku's NOTIFY on
            -- kiroku.events; the store's notifier ticks the broadcast channel.
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO store $
                    appendJournalEntry (WorkflowName "wakedemo") (WorkflowId "w1") (StepRecorded "s" (toJSON True) now)
            reason <- waitForWake wake 5000000 -- generous 5 s ceiling; the round-trip is milliseconds
            reason `shouldBe` WokenByNotify

        it "neverWake always returns WokenByTimeout" $ \_store -> do
            reason <- waitForWake neverWake 100000
            reason `shouldBe` WokenByTimeout

    describe "Keiro.Workflow push latency (EP-50)" $ around (withFreshStore fixture) $ do
        -- The user-visible win: a gated workflow resumes within sub-second of the
        -- gate append, under a deliberately large (10 s) fallback — so a pass that
        -- resumes it sub-second can only have been woken by the NOTIFY, not the poll.
        it "resumes a gated workflow sub-second after the gate append (10s fallback)" $ \store -> do
            done <- newEmptyMVar
            let name = WorkflowName "pushwf"
                wid = WorkflowId "p-1"
                registry = Map.singleton name (WorkflowDef (\_ -> gateThenSignal done))
                opts = defaultWorkflowResumeOptions & #pollInterval .~ 10000000 -- 10 s fallback
            first <- Store.runStoreIO store (runWorkflow name wid (gateThenSignal done))
            first `shouldBe` Right Suspended
            worker <- forkIO (runWorkflowResumeWorkerPush store opts registry)
            -- Let the worker start, duplicate the tick channel, and park in its wait
            -- before we append, so the gate's NOTIFY cannot be missed.
            threadDelay 250000
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO store $
                    appendJournalEntry name wid (StepRecorded "awk:gate" (toJSON ()) now)
            resumed <- timeout 5000000 (takeMVar done)
            t1 <- getCurrentTime
            killThread worker
            resumed `shouldBe` Just ()
            let latency = realToFrac (diffUTCTime t1 now) :: Double
            latency `shouldSatisfy` (< 1.0)

        it "logs a failed push pass and keeps draining after the store recovers" $ \store -> do
            done <- newEmptyMVar
            logs <- newIORef []
            let name = WorkflowName "push-recover"
                wid = WorkflowId "pr-1"
                registry = Map.singleton name (WorkflowDef (\_ -> gateThenSignal done))
                opts =
                    defaultWorkflowResumeOptions
                        & #pollInterval
                        .~ 100_000
                        & #logEvent
                        .~ \event -> modifyIORef' logs (<> [event])
                waitForPassFailure = timeout 5_000_000 $ do
                    let go = do
                            seen <- readIORef logs
                            if any isPassFailure seen
                                then pure ()
                                else threadDelay 20_000 >> go
                    go
                isPassFailure = \case
                    ResumePassFailed{} -> True
                    _ -> False
            first <- Store.runStoreIO store (runWorkflow name wid (gateThenSignal done))
            first `shouldBe` Right Suspended
            Right () <-
                Store.runStoreIO store $
                    Store.runTransaction $
                        Tx.sql "ALTER TABLE keiro.keiro_workflow_steps RENAME TO keiro_workflow_steps_hidden"
            worker <- forkIO (runWorkflowResumeWorkerPush store opts registry)
            logged <- waitForPassFailure
            logged `shouldBe` Just ()
            Right () <-
                Store.runStoreIO store $
                    Store.runTransaction $
                        Tx.sql "ALTER TABLE keiro.keiro_workflow_steps_hidden RENAME TO keiro_workflow_steps"
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO store $
                    appendJournalEntry name wid (StepRecorded "awk:gate" (toJSON ()) now)
            resumed <- timeout 5_000_000 (takeMVar done)
            status <- threadStatus worker
            killThread worker
            resumed `shouldBe` Just ()
            status `shouldSatisfy` \case
                ThreadFinished -> False
                ThreadDied -> False
                _ -> True

    describe "Keiro.Workflow push fallback (EP-50)" $ around (withFreshStore fixture) $ do
        -- Push is strictly an optimization: with the worker on 'neverWake' (every
        -- NOTIFY dropped) and a small fallback, the gated workflow still drains on
        -- the durable poll.
        it "still drains on the fallback timeout when no notification is delivered" $ \store -> do
            done <- newEmptyMVar
            let name = WorkflowName "fallbackwf"
                wid = WorkflowId "f-1"
                registry = Map.singleton name (WorkflowDef (\_ -> gateThenSignal done))
                onePass = void (Store.runStoreIO store (resumeWorkflowsOnce defaultWorkflowResumeOptions registry))
            first <- Store.runStoreIO store (runWorkflow name wid (gateThenSignal done))
            first `shouldBe` Right Suspended
            worker <- forkIO (runPollLoopWith neverWake 200000 onePass) -- 200 ms fallback, no notifications
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO store $
                    appendJournalEntry name wid (StepRecorded "awk:gate" (toJSON ()) now)
            resumed <- timeout 5000000 (takeMVar done)
            killThread worker
            resumed `shouldBe` Just ()

    describe "Shard lease" $ around (withFreshStore fixture) $ do
        -- EP-51 M2: claim / renew / release / expiry at the SQL layer, with explicit
        -- `now` timestamps standing in for the passage of time (no workers yet). The
        -- exclusion guarantee is the FOR UPDATE SKIP LOCKED claim; disjointness and
        -- failover are both observable purely from the lease table.
        let subName = SubscriptionName "orders-shard"
            wA = WorkerId sampleUuid
            wB = WorkerId sampleUuid2
            ttl = 30 :: NominalDiffTime
            t0 = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
            tExpired = addUTCTime 60 t0 -- past A's 30 s lease
            shardOpts = defaultShardedWorkerOptions (Category (CategoryName "orders")) 4
        it "validates sharded worker options before startup" $ \_store -> do
            shouldBeRight_ (mkShardedWorkerOptions shardOpts)
            mkShardedWorkerOptions (shardOpts & #shardCount .~ 0)
                `shouldBeLeft` InvalidShardCount 0
            mkShardedWorkerOptions (shardOpts & #leaseTtl .~ 0)
                `shouldBeLeft` InvalidShardLeaseTtl 0
            mkShardedWorkerOptions (shardOpts & #renewInterval .~ 0)
                `shouldBeLeft` InvalidShardRenewInterval 0
            mkShardedWorkerOptions (shardOpts & #leaseTtl .~ 10 & #renewInterval .~ 10)
                `shouldBeLeft` InvalidShardLeaseRenewInterval 10 10
            mkShardedWorkerOptions (shardOpts & #batchSize .~ 0)
                `shouldBeLeft` InvalidShardBatchSize 0
            mkShardedWorkerOptions (shardOpts & #bufferSize .~ 0)
                `shouldBeLeft` InvalidShardBufferSize 0
            mkShardedWorkerOptions (shardOpts & #handlerRetryDelay .~ KirokuSub.RetryDelay (-1))
                `shouldBeLeft` InvalidShardHandlerRetryDelay (KirokuSub.RetryDelay (-1))
            mkShardedWorkerOptions (shardOpts & #retryPolicy .~ KirokuSub.RetryPolicy 0)
                `shouldBeLeft` InvalidShardRetryMaxAttempts 0

        it "ensureShardRows populates N rows once (idempotent on re-run)" $ \store -> do
            Right () <- Store.runStoreIO store $ Store.runTransaction $ do
                ensureShardRows subName 4
                ensureShardRows subName 4
            Right rows <- Store.runStoreIO store $ Store.runTransaction (listShardOwnership subName)
            map (\(b, _, _) -> b) rows `shouldBe` [0, 1, 2, 3]
            all (\(_, o, _) -> isNothing o) rows `shouldBe` True

        it "worker A claims all N when free; B claims 0 while A holds valid leases" $ \store -> do
            Right claimedA <- Store.runStoreIO store $ Store.runTransaction $ do
                ensureShardRows subName 4
                claimShardsTx subName wA 4 t0 ttl
            claimedA `shouldBe` [0, 1, 2, 3]
            Right claimedB <- Store.runStoreIO store $ Store.runTransaction (claimShardsTx subName wB 4 t0 ttl)
            claimedB `shouldBe` []

        it "B claims A's buckets after A's lease expires; A then renews nothing" $ \store -> do
            Right _ <- Store.runStoreIO store $ Store.runTransaction $ do
                ensureShardRows subName 4
                claimShardsTx subName wA 4 t0 ttl
            Right claimedB <- Store.runStoreIO store $ Store.runTransaction (claimShardsTx subName wB 4 tExpired ttl)
            claimedB `shouldBe` [0, 1, 2, 3]
            -- A lost every bucket to B, so its renew returns the empty set: this is how
            -- a worker learns it no longer owns a bucket and stops reading it.
            Right heldA <- Store.runStoreIO store $ Store.runTransaction (renewLeaseTx subName wA tExpired ttl)
            heldA `shouldBe` []

        it "renewLease returns only still-held buckets" $ \store -> do
            Right held <- Store.runStoreIO store $ Store.runTransaction $ do
                ensureShardRows subName 4
                _ <- claimShardsTx subName wA 4 t0 ttl
                renewLeaseTx subName wA t0 ttl
            held `shouldBe` [0, 1, 2, 3]

        it "releaseShards: relinquished buckets are immediately claimable" $ \store -> do
            Right _ <- Store.runStoreIO store $ Store.runTransaction $ do
                ensureShardRows subName 4
                _ <- claimShardsTx subName wA 4 t0 ttl
                releaseShardsTx subName wA [0, 1]
            -- Even while A's lease over 2,3 is still valid, the released 0,1 are claimable.
            Right claimedB <- Store.runStoreIO store $ Store.runTransaction (claimShardsTx subName wB 4 t0 ttl)
            claimedB `shouldBe` [0, 1]

        it "fairShareTarget divides buckets evenly (ceil)" $ \_store -> do
            fairShareTarget 6 3 `shouldBe` 2
            fairShareTarget 6 4 `shouldBe` 2
            fairShareTarget 7 3 `shouldBe` 3
            fairShareTarget 4 0 `shouldBe` 4 -- a non-positive estimate claims everything
        it "acquireOutcome keeps previous ownership on acquire failure" $ \_store -> do
            let previous = Set.fromList [0, 2]
            acquireOutcome previous (Left "database unavailable")
                `shouldBe` (previous, Just (ShardAcquireFailed "database unavailable"))
            acquireOutcome previous (Right (Set.fromList [1, 3]))
                `shouldBe` (Set.fromList [1, 3], Nothing)

        it "ensureShards rejects a shardCount mismatch" $ \store -> do
            let lease4 =
                    ShardLease
                        { subscriptionName = subName
                        , workerId = wA
                        , shardCount = 4
                        , leaseTtl = ttl
                        }
                lease6 =
                    ShardLease
                        { subscriptionName = subName
                        , workerId = wA
                        , shardCount = 6
                        , leaseTtl = ttl
                        }
            Right () <- Store.runStoreIO store (ensureShards lease4)
            Store.runStoreIO store (ensureShards lease6)
                `shouldThrow` \case
                    ShardCountMismatch name configured found ->
                        name == "orders-shard" && configured == 6 && found == [4]

    describe "Sharded subscription single worker" $ around (withFreshStore fixture) $ do
        -- EP-51 M3: one process owning all N buckets drains a seeded category exactly
        -- once. The sink is idempotent on event_id, so "count == total" proves every
        -- event was delivered with none missing and none surviving as a duplicate row.
        it "one worker with N=4 buckets drains a seeded category exactly once" $ \store -> do
            Right () <- Store.runStoreIO store $ Store.runTransaction (Tx.sql createShardSinkSql)
            total <- seedOrders store 8 5 -- 40 events across 8 streams
            let opts =
                    (defaultShardedWorkerOptions (Category (CategoryName "orders")) 4)
                        { leaseTtl = 3
                        , renewInterval = 0.3
                        }
            w <- forkIO (runShardedSubscriptionGroup store (SubscriptionName "orders-sub") opts (sinkHandler store 1))
            drained <- waitUntilSinkCount store total 20_000_000
            killThread w
            drained `shouldBe` True
            count <- shardSinkCount store
            count `shouldBe` total
            maxW <- maxWorkersPerStream store
            maxW `shouldBe` 1

    describe "Sharded subscription drain and failover" $ around (withFreshStore fixture) $ do
        -- EP-51 M5: the behavioural acceptance. Three worker processes cooperatively
        -- partition a category; we let ownership converge on the *empty* category
        -- first (so the churn of cold-start rebalancing touches no events), then seed
        -- and drain under stable membership — so each stream is owned by exactly one
        -- worker throughout the drain. Then we kill a worker and prove its buckets are
        -- re-homed and the new events drain (failover via lease expiry).
        let sub = SubscriptionName "orders-failover"
            mkOpts = (defaultShardedWorkerOptions (Category (CategoryName "orders")) 6){leaseTtl = 3, renewInterval = 0.3}
        it "three workers drain disjointly, then re-home a killed worker's buckets" $ \store -> do
            Right () <- Store.runStoreIO store $ Store.runTransaction (Tx.sql createShardSinkSql)
            w1 <- forkIO (runShardedSubscriptionGroup store sub mkOpts (sinkHandler store 1))
            w2 <- forkIO (runShardedSubscriptionGroup store sub mkOpts (sinkHandler store 2))
            w3 <- forkIO (runShardedSubscriptionGroup store sub mkOpts (sinkHandler store 3))
            -- Wait for cooperative balance on the empty category: all 6 buckets owned,
            -- spread across >= 2 workers, none holding more than its fair share.
            balanced <- waitShardsBalanced store sub 6 2 15_000_000
            balanced `shouldBe` True
            -- Now seed and drain under stable membership.
            total1 <- seedOrders store 12 5 -- 60 events
            ok1 <- waitUntilSinkCount store total1 25_000_000
            ok1 `shouldBe` True
            -- Disjoint: no stream key was processed by two workers (stable membership,
            -- so no re-homing split any stream).
            maxW <- maxWorkersPerStream store
            maxW `shouldBe` 1
            -- The work genuinely spread (not a monopoly): at least two workers participated.
            spread <- distinctWorkers store
            spread `shouldSatisfy` (>= 2)
            -- Counts sum to total with no duplicate event id (PK on event_id + count).
            c1 <- shardSinkCount store
            c1 `shouldBe` total1
            -- Kill worker 1 (its readers stop; it stops renewing, so its leases expire).
            killThread w1
            -- Seed more across all streams; some hash to worker 1's now-orphaned buckets.
            total2 <- seedOrders store 12 5 -- another 60
            -- Failover: a surviving worker re-claims the expired buckets and drains the
            -- new events. If re-homing did not happen, events on worker 1's buckets would
            -- never drain and this would time out.
            ok2 <- waitUntilSinkCount store (total1 + total2) 30_000_000
            killThread w2
            killThread w3
            ok2 `shouldBe` True
            c2 <- shardSinkCount store
            c2 `shouldBe` (total1 + total2)

        it "a killed worker relinquishes its leases immediately" $ \store -> do
            let subImmediate = SubscriptionName "orders-immediate-release"
                longTtlOpts =
                    (defaultShardedWorkerOptions (Category (CategoryName "orders")) 4)
                        { leaseTtl = 30
                        , renewInterval = 0.2
                        }
            w <- forkIO (runShardedSubscriptionGroup store subImmediate longTtlOpts (sinkHandler store 1))
            owned <- waitShardsBalanced store subImmediate 4 1 10_000_000
            owned `shouldBe` True
            killThread w
            released <- waitShardsUnowned store subImmediate 4 3_000_000
            released `shouldBe` True

        it "a handler exception is retried in place and drains" $ \store -> do
            Right () <- Store.runStoreIO store $ Store.runTransaction (Tx.sql createShardSinkSql)
            thrown <- newIORef False
            errors <- newIORef []
            let subRestart = SubscriptionName "orders-reader-restart"
                opts =
                    (defaultShardedWorkerOptions (Category (CategoryName "orders")) 2)
                        { leaseTtl = 3
                        , renewInterval = 0.2
                        , handlerRetryDelay = KirokuSub.RetryDelay 0.05
                        , onShardError = Just (\err -> modifyIORef' errors (err :))
                        }
                handler ev = do
                    firstTime <-
                        atomicModifyIORef'
                            thrown
                            ( \seen ->
                                if seen
                                    then (seen, False)
                                    else (True, True)
                            )
                    when firstTime (throwIO (userError "reader boom"))
                    sinkHandler store 1 ev
            w <- forkIO (runShardedSubscriptionGroup store subRestart opts handler)
            balanced <- waitShardsBalanced store subRestart 2 1 10_000_000
            balanced `shouldBe` True
            total <- seedOrders store 4 2
            drained <- waitUntilSinkCount store total 20_000_000
            killThread w
            drained `shouldBe` True
            seenErrors <- readIORef errors
            seenErrors `shouldSatisfy` all (\case ShardReaderDied _ _ -> False; _ -> True)

    describe "Sharded subscription ack coupling" $ around (withFreshStore fixture) $ do
        it "redelivers a batch-tail event whose handler was killed mid-flight" $ \store -> do
            Right () <- Store.runStoreIO store $ Store.runTransaction (Tx.sql createShardSinkSql)
            total <- seedOrders store 1 5
            enteredTail <- newEmptyMVar
            holdTail <- newEmptyMVar
            let sub = SubscriptionName "orders-ack-tail"
                opts =
                    (defaultShardedWorkerOptions (Category (CategoryName "orders")) 1)
                        { leaseTtl = 3
                        , renewInterval = 0.3
                        }
                blockingHandler ev = do
                    let orderNumber = parseEither (withObject "OrderPlaced" (.: "n")) (ev ^. #payload)
                    when (orderNumber == Right (4 :: Int)) $ do
                        putMVar enteredTail ()
                        takeMVar holdTail
                    sinkHandler store 1 ev
            first <- forkIO (runShardedSubscriptionGroup store sub opts blockingHandler)
            entered <- timeout 10_000_000 (takeMVar enteredTail)
            entered `shouldBe` Just ()
            -- The old pull bridge replies Continue before invoking the handler;
            -- leave enough time for its batch-tail checkpoint to commit while the
            -- handler remains blocked. The ack-coupled bridge introduced by EP-96
            -- remains blocked on the unfilled reply instead.
            threadDelay 200_000
            killThread first
            second <- forkIO (runShardedSubscriptionGroup store sub opts (sinkHandler store 2))
            drained <- waitUntilSinkCount store total 20_000_000
            killThread second
            drained `shouldBe` True
            shardSinkCount store `shouldReturn` total

        it "loses no events when a bucket is shed mid-drain during rebalance" $ \store -> do
            Right () <- Store.runStoreIO store $ Store.runTransaction (Tx.sql createShardSinkSql)
            total <- seedOrders store 24 5
            let sub = SubscriptionName "orders-ack-rebalance"
                opts =
                    (defaultShardedWorkerOptions (Category (CategoryName "orders")) 4)
                        { leaseTtl = 3
                        , renewInterval = 0.3
                        , batchSize = 1
                        }
                slowHandler tag ev = do
                    threadDelay 100_000
                    sinkHandler store tag ev
            first <- forkIO (runShardedSubscriptionGroup store sub opts (slowHandler 1))
            -- acquireOwnedBuckets claims one bucket per pass. Starting the joiner
            -- while A owns three leaves one claimable bucket for B, making B visible;
            -- A's next pass then sheds its excess third bucket while its handler is
            -- deliberately slow and in flight.
            ownsThree <- waitUntilOwnedShardCount store sub 3 10_000_000
            ownsThree `shouldBe` True
            second <- forkIO (runShardedSubscriptionGroup store sub opts (slowHandler 2))
            drained <- waitUntilSinkCount store total 30_000_000
            killThread first
            killThread second
            drained `shouldBe` True
            shardSinkCount store `shouldReturn` total

        it "allows zombie overlap duplicates without losing an event" $ \store -> do
            Right () <- Store.runStoreIO store $ Store.runTransaction (Tx.sql createShardSinkSql)
            total <- seedOrders store 1 5
            entered <- newEmptyMVar
            release <- newEmptyMVar
            deliveries <- newIORef ([] :: [EventId])
            successor <- newIORef Nothing
            readersA <- newIORef Map.empty
            let sub = SubscriptionName "orders-ack-zombie"
                opts =
                    (defaultShardedWorkerOptions (Category (CategoryName "orders")) 1)
                        { leaseTtl = 2
                        , renewInterval = 0.2
                        }
                leaseA =
                    ShardLease
                        { subscriptionName = sub
                        , workerId = WorkerId sampleUuid
                        , shardCount = 1
                        , leaseTtl = 2
                        }
                handlerA delivery = do
                    let ev = delivery ^. #event
                    modifyIORef' deliveries ((ev ^. #eventId) :)
                    putMVar entered ()
                    takeMVar release
                    sinkHandler store 1 ev
                    pure ShardAckOk
                handlerB delivery = do
                    let ev = delivery ^. #event
                    modifyIORef' deliveries ((ev ^. #eventId) :)
                    sinkHandler store 2 ev
                    pure ShardAckOk
                cleanup = do
                    void (tryPutMVar release ())
                    mSuccessor <- readIORef successor
                    for_ mSuccessor killThread
                    now <- getCurrentTime
                    let cleanupWorker = WorkerId sampleUuid2
                    _ <- Store.runStoreIO store $ Store.runTransaction $ do
                        releaseShardsTx sub (WorkerId sampleUuid) [0]
                        claimShardsTx sub cleanupWorker 1 now 30
                    void (reconcileShardsOnce store leaseA opts readersA handlerA)
            ( do
                    Right () <- Store.runStoreIO store (ensureShards leaseA)
                    void (reconcileShardsOnce store leaseA opts readersA handlerA)
                    timeout 10_000_000 (takeMVar entered) `shouldReturn` Just ()
                    -- A no longer renews, but its reader remains alive and blocked
                    -- with one unacknowledged event. B can claim after expiry and
                    -- must therefore receive that event again from the checkpoint.
                    threadDelay 2_500_000
                    workerB <- forkIO (runShardedSubscriptionGroupAck store sub opts handlerB)
                    writeIORef successor (Just workerB)
                    drained <- waitUntilSinkCount store total 20_000_000
                    drained `shouldBe` True
                    raw <- readIORef deliveries
                    length raw `shouldSatisfy` (> total)
                    shardSinkCount store `shouldReturn` total
                )
                `finally` cleanup

        it "dead-letters a poison event after bounded retries and keeps draining" $ \store -> do
            Right () <- Store.runStoreIO store $ Store.runTransaction (Tx.sql createShardSinkSql)
            total <- seedOrders store 1 4
            poisonDeliveries <- newIORef (0 :: Int)
            errors <- newIORef []
            let sub = SubscriptionName "orders-ack-poison"
                opts =
                    (defaultShardedWorkerOptions (Category (CategoryName "orders")) 1)
                        { leaseTtl = 3
                        , renewInterval = 0.2
                        , handlerRetryDelay = KirokuSub.RetryDelay 0.05
                        , retryPolicy = KirokuSub.RetryPolicy 3
                        , onShardError = Just (\err -> modifyIORef' errors (err :))
                        }
                handler ev = do
                    let orderNumber = parseEither (withObject "OrderPlaced" (.: "n")) (ev ^. #payload)
                    if orderNumber == Right (1 :: Int)
                        then do
                            modifyIORef' poisonDeliveries (+ 1)
                            throwIO (userError "poison order")
                        else sinkHandler store 1 ev
            worker <- forkIO (runShardedSubscriptionGroup store sub opts handler)
            drained <- waitUntilSinkCount store (total - 1) 20_000_000
            details <- shardDeadLetterDetails store "orders-ack-poison"
            attempts <- readIORef poisonDeliveries
            seenErrors <- readIORef errors
            killThread worker
            drained `shouldBe` True
            attempts `shouldBe` 3
            details `shouldBe` (1, Just "max retry attempts exceeded (3)", Just 3)
            seenErrors `shouldSatisfy` all (\case ShardReaderDied _ _ -> False; _ -> True)

    describe "Keiro.Workflow observability" $ around (withFreshStore fixture) $ do
        -- The headline operability signal: executed (real work) vs replayed
        -- (recorded history), recorded by the runtime through an SDK meter and read
        -- back from the in-memory exporter — plus the active gauge and the
        -- journal-length histogram.
        it "records workflow instruments through an SDK meter" $ \storeHandle -> do
            (exporter, ref) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            metrics <- Telemetry.newKeiroMetrics meter
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "obs"
                wid = WorkflowId "obs-1"
                opts = defaultWorkflowRunOptions & #metrics .~ Just metrics
            -- First run: both steps miss → two executions.
            first <- Store.runStoreIO storeHandle $ runWorkflowWith opts name wid (demoWorkflow counter)
            first `shouldBe` Right (Completed (1, 2))
            -- Second run, same id: both steps hit → two replays.
            second <- Store.runStoreIO storeHandle $ runWorkflowWith opts name wid (demoWorkflow counter)
            second `shouldBe` Right (Completed (1, 2))
            -- The side effects ran exactly twice across both runs (the replay run
            -- short-circuited every step).
            readIORef counter >>= \c -> c `shouldBe` 2
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef ref
            let scalars = flattenScalarPoints exported
                hists = flattenHistogramPoints exported
            lookup "keiro.workflow.steps.executed" scalars `shouldBe` Just (IntNumber 2)
            lookup "keiro.workflow.steps.replayed" scalars `shouldBe` Just (IntNumber 2)
            -- One journal-length observation per completed run (two completions).
            [c | (n, c, _) <- hists, n == "keiro.workflow.journal.length"] `shouldBe` [2]
            -- Both runs finished, so the live-run count returned to zero.
            lookup "keiro.workflow.active" scalars `shouldBe` Just (IntNumber 0)

        -- The resume worker increments keiro.workflow.resumed per re-invocation and
        -- samples keiro.workflow.awakeables.pending each pass.
        it "records a resume and the pending-awakeable count when the worker re-invokes" $ \storeHandle -> do
            (exporter, ref) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
            metrics <- Telemetry.newKeiroMetrics meter
            counter <- newIORef (0 :: Int)
            let name = WorkflowName "obs-resume"
                wid = WorkflowId "obs-r-1"
            -- Suspend a workflow so it has a step row but no completion: the resume
            -- worker will re-invoke it (and stay Suspended, which still counts as a
            -- re-invocation).
            suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (stepThenAwaitWorkflow counter)
            suspended `shouldBe` Right Suspended
            -- Register one pending awakeable (independent of the suspended workflow's
            -- own await) so the pending gauge has something to count.
            let aid = awakeableIdToUuid (deterministicAwakeableId (WorkflowName "ext") (WorkflowId "1") "cb")
            Right () <-
                Store.runStoreIO storeHandle $ Store.runTransaction $ Awk.registerAwakeableTx aid "ext" "1"
            -- One resume pass with metrics threaded through the run options.
            let registry = Map.singleton name (WorkflowDef (\_wid -> stepThenAwaitWorkflow counter))
                resumeOpts =
                    defaultWorkflowResumeOptions
                        & #runOptions
                        .~ (defaultWorkflowRunOptions & #metrics .~ Just metrics)
            Right _summary <- Store.runStoreIO storeHandle $ resumeWorkflowsOnce resumeOpts registry
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef ref
            let scalars = flattenScalarPoints exported
            lookup "keiro.workflow.resumed" scalars `shouldBe` Just (IntNumber 1)
            lookup "keiro.workflow.awakeables.pending" scalars `shouldBe` Just (IntNumber 1)

        -- The no-op idiom end to end: defaultWorkflowRunOptions carries metrics =
        -- Nothing, so a run on a dedicated provider exports no points at all.
        it "records nothing through a Nothing handle" $ \storeHandle -> do
            (exporter, ref) <- inMemoryMetricExporter
            (provider, _env) <-
                createMeterProvider
                    emptyMaterializedResources
                    defaultSdkMeterProviderOptions{metricExporter = Just exporter}
            counter <- newIORef (0 :: Int)
            result <-
                Store.runStoreIO storeHandle $
                    runWorkflow (WorkflowName "obs-noop") (WorkflowId "obs-n-1") (demoWorkflow counter)
            result `shouldBe` Right (Completed (1, 2))
            _ <- forceFlushMeterProvider provider Nothing
            exported <- readIORef ref
            flattenScalarPoints exported `shouldBe` []
            flattenHistogramPoints exported `shouldBe` []

    describe "Keiro.Workflow.Snapshot codec" $ do
        -- Pure (no-DB) round-trip of the workflow state codec.
        it "round-trips a non-trivial accumulated step map and carries the sentinel shape hash" $ do
            let m =
                    Map.fromList
                        [ ("first", toJSON (1 :: Int))
                        , ("second", toJSON ["a", "b" :: Text])
                        , ("sleep:42", Aeson.Null)
                        ]
            (workflowStateCodec ^. #decode) ((workflowStateCodec ^. #encode) m) `shouldBe` Right m
            (workflowStateCodec ^. #shapeHash) `shouldBe` "keiro.workflow.stepmap.v1"
            (workflowStateCodec ^. #stateCodecVersion) `shouldBe` 1

    describe "Keiro.Workflow.Types journal codec" $ do
        -- Pure (no-DB) round-trip of the EP-48 rotation marker, proving the
        -- additive WorkflowContinuedAsNew constructor encodes and decodes
        -- self-describingly within schemaVersion 1.
        it "round-trips a WorkflowContinuedAsNew rotation marker" $ do
            let t = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 3600)
                marker = WorkflowContinuedAsNew 3 t
            (workflowJournalCodec ^. #decode) ((workflowJournalCodec ^. #eventType) marker) ((workflowJournalCodec ^. #encode) marker)
                `shouldBe` Right marker
            (workflowJournalCodec ^. #schemaVersion) `shouldBe` 1
            EventType "WorkflowContinuedAsNew" `elem` (workflowJournalCodec ^. #eventTypes) `shouldBe` True

        it "validates workflow identity smart constructors" $ do
            mkWorkflowName "orderFulfillment" `shouldBe` Right (WorkflowName "orderFulfillment")
            mkWorkflowName "" `shouldBe` Left WorkflowNameEmpty
            mkWorkflowName "order-fulfillment" `shouldBe` Left (WorkflowNameInvalidChar '-' "order-fulfillment")
            mkWorkflowName "order:fulfillment" `shouldBe` Left (WorkflowNameInvalidChar ':' "order:fulfillment")
            mkWorkflowName "order#1" `shouldBe` Left (WorkflowNameInvalidChar '#' "order#1")
            mkWorkflowId "550e8400-e29b-41d4-a716-446655440000"
                `shouldBe` Right (WorkflowId "550e8400-e29b-41d4-a716-446655440000")
            mkWorkflowId "" `shouldBe` Left WorkflowIdEmpty
            mkWorkflowId "customer:42" `shouldBe` Left (WorkflowIdInvalidChar ':' "customer:42")
            mkWorkflowId "customer#42" `shouldBe` Left (WorkflowIdInvalidChar '#' "customer#42")

    describe "Keiro.Workflow.Sleep" $ do
        -- Pure (no-DB) checks of the id/payload/step-name helpers.
        it "derives a deterministic, distinct timer id" $ do
            let name = WorkflowName "wf"
                wid = WorkflowId "w-1"
                sleepGolden = uuidLiteral "a95d5e7f-a43d-5ee2-9243-8206f0d8734a"
            sleepTimerId name wid 0 "sleep:cool" `shouldBe` sleepTimerId name wid 0 "sleep:cool"
            (sleepTimerId name wid 0 "sleep:cool" == sleepTimerId name wid 0 "sleep:other")
                `shouldBe` False
            sleepTimerId name wid 0 "sleep:cool"
                `shouldBe` TimerId sleepGolden
            sleepTimerId name wid 1 "sleep:cool" `shouldNotBe` sleepTimerId name wid 0 "sleep:cool"
            sleepTimerId name wid 2 "sleep:cool" `shouldNotBe` sleepTimerId name wid 1 "sleep:cool"

        it "round-trips and recognises its timer payload" $ do
            parseSleepPayload (sleepTimerPayload "sleep:cool") `shouldBe` Just "sleep:cool"
            parseSleepPayload (object ["kind" Aeson..= ("counter-timeout" :: Text)])
                `shouldBe` Nothing

        it "prefixes the journal step name with the reserved sleep prefix" $
            sleepStepName (StepName "cool") `shouldBe` "sleep:cool"

        around (withFreshStore fixture) $ do
            it "arms a timer and suspends, then a fired timer resumes the workflow" $ \storeHandle -> do
                counter <- newIORef (0 :: Int)
                let name = WorkflowName "sleepdemo"
                    wid = WorkflowId "sd-1"
                    journalStream = StreamName "wf:sleepdemo-sd-1"
                    TimerId timerUuid = sleepTimerId name wid 0 "sleep:cool"
                -- First run: 'a' runs, the sleep arms a timer, and the run suspends.
                outcome1 <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (sleepDemoNamed counter (StepName "cool") 0)
                outcome1 `shouldBe` Right Suspended
                afterFirst <- readIORef counter
                afterFirst `shouldBe` 1
                -- The journal holds only 'a' (no completion, no sleep:cool yet).
                Right recorded1 <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward journalStream (StreamVersion 0) 100
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded1)
                    `shouldSatisfy` \case
                        Right [StepRecorded "a" _ _] -> True
                        _ -> False
                -- The durable wait is a single Scheduled timer row carrying the
                -- workflow-sleep payload.
                Right timerRow <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Tx.statement timerUuid sleepTimerStatusStmt
                timerRow `shouldSatisfy` \case
                    Just (status, payload) ->
                        status == "scheduled" && parseSleepPayload payload == Just "sleep:cool"
                    Nothing -> False
                -- Fire the timer through the routing worker (no PM fallback needed).
                fireTime <- getCurrentTime
                fireResult <-
                    Store.runStoreIO storeHandle $
                        runWorkflowTimerWorker Nothing fireTime (\_ -> pure Nothing)
                case fireResult of
                    Right (Just timer) -> timer ^. #status `shouldBe` Firing
                    other -> expectationFailure ("expected a fired sleep timer, got " <> show other)
                -- The row is now Fired and the journal gained sleep:cool.
                Right afterFire <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Tx.statement timerUuid sleepTimerStatusStmt
                fmap fst afterFire `shouldBe` Just "fired"
                Right recorded2 <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward journalStream (StreamVersion 0) 100
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded2)
                    `shouldSatisfy` \case
                        Right [StepRecorded "a" _ _, StepRecorded "sleep:cool" _ _] -> True
                        _ -> False
                -- Second run completes: 'a' and the sleep short-circuit, only 'b' runs.
                outcome2 <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (sleepDemoNamed counter (StepName "cool") 0)
                outcome2 `shouldBe` Right (Completed (1, 2))
                afterSecond <- readIORef counter
                afterSecond `shouldBe` 2
                Right recorded3 <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward journalStream (StreamVersion 0) 100
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded3)
                    `shouldSatisfy` \case
                        Right [StepRecorded "a" _ _, StepRecorded "sleep:cool" _ _, StepRecorded "b" _ _, WorkflowCompleted _] -> True
                        _ -> False

            it "respects a positive delay: not due before fire_at, fires after" $ \storeHandle -> do
                counter <- newIORef (0 :: Int)
                let name = WorkflowName "sleepwait"
                    wid = WorkflowId "rt-1"
                    journalStream = StreamName "wf:sleepwait-rt-1"
                clockBeforeFire <- getCurrentTime
                outcome1 <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (sleepDemoNamed counter (StepName "wait") 1)
                outcome1 `shouldBe` Right Suspended
                afterFirst <- readIORef counter
                afterFirst `shouldBe` 1
                -- A worker whose clock is before fire_at claims nothing.
                notDue <-
                    Store.runStoreIO storeHandle $
                        runTimerWorker Nothing clockBeforeFire workflowSleepFireAction
                notDue `shouldBe` Right Nothing
                Right recordedMid <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward journalStream (StreamVersion 0) 100
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList recordedMid)
                    `shouldSatisfy` \case
                        Right [StepRecorded "a" _ _] -> True
                        _ -> False
                -- Wait out the one-second delay, then the worker fires it.
                threadDelay 1_200_000
                afterDelay <- getCurrentTime
                fired <-
                    Store.runStoreIO storeHandle $
                        runTimerWorker Nothing afterDelay workflowSleepFireAction
                fired `shouldSatisfy` \case
                    Right (Just _) -> True
                    _ -> False
                Right recordedWoken <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward journalStream (StreamVersion 0) 100
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList recordedWoken)
                    `shouldSatisfy` \case
                        Right [StepRecorded "a" _ _, StepRecorded "sleep:wait" _ _] -> True
                        _ -> False
                outcome2 <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (sleepDemoNamed counter (StepName "wait") 1)
                outcome2 `shouldBe` Right (Completed (1, 2))
                afterSecond <- readIORef counter
                afterSecond `shouldBe` 2

            it "does not postpone fire_at when a resume pass re-arms the sleep" $ \storeHandle -> do
                counter <- newIORef (0 :: Int)
                let name = WorkflowName "sleeponce"
                    wid = WorkflowId "so-1"
                    TimerId timerUuid = sleepTimerId name wid 0 "sleep:cool"
                    registry = Map.singleton name (WorkflowDef (\_ -> sleepDemoNamed counter (StepName "cool") 300))
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (sleepDemoNamed counter (StepName "cool") 300)
                Right (Just firstFireAt) <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Tx.statement timerUuid sleepTimerFireAtStmt
                Right summary <-
                    Store.runStoreIO storeHandle $
                        resumeWorkflowsOnce defaultWorkflowResumeOptions registry
                discovered summary `shouldBe` 0
                Right (Just secondFireAt) <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Tx.statement timerUuid sleepTimerFireAtStmt
                secondFireAt `shouldBe` firstFireAt
                readIORef counter >>= (`shouldBe` 1)

            it "skips a sleeping workflow until wake_after expires" $ \storeHandle -> do
                counter <- newIORef (0 :: Int)
                let name = WorkflowName "sleepwakeafter"
                    wid = WorkflowId "swa-1"
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (sleepDemoNamed counter (StepName "wait") 60)
                now <- getCurrentTime
                Right mWakeAfter <- Store.runStoreIO storeHandle $ workflowWakeAfter name wid
                case mWakeAfter of
                    Nothing -> expectationFailure "expected wake_after"
                    Just wakeAfter -> wakeAfter `shouldSatisfy` (> now)
                Right early <- Store.runStoreIO storeHandle $ findUnfinishedWorkflowIds now
                early `shouldBe` []
                Right due <- Store.runStoreIO storeHandle $ findUnfinishedWorkflowIds (addUTCTime 61 now)
                due `shouldBe` [("swa-1", "sleepwakeafter")]

            it "does not re-invoke a parked sleeper before wake_after" $ \storeHandle -> do
                counter <- newIORef (0 :: Int)
                let name = WorkflowName "sleepquiet"
                    wid = WorkflowId "sq-1"
                    registry = Map.singleton name (WorkflowDef (\_ -> sleepDemoNamed counter (StepName "wait") 60))
                    pass = Store.runStoreIO storeHandle (resumeWorkflowsOnce defaultWorkflowResumeOptions registry)
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (sleepDemoNamed counter (StepName "wait") 60)
                Right s1 <- pass
                Right s2 <- pass
                Right s3 <- pass
                map discovered [s1, s2, s3] `shouldBe` [0, 0, 0]
                readIORef counter >>= (`shouldBe` 1)

            it "treats a missing instance row during sleep arm as a no-op wake hint update" $ \storeHandle -> do
                let name = WorkflowName "sleepmissingrow"
                    wid = WorkflowId "smr-1"
                    body = sleepNamed (StepName "wait") 60 >> pure ()
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid body
                Right () <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Tx.statement ("smr-1", "sleepmissingrow") deleteWorkflowInstanceStmt
                Store.runStoreIO storeHandle (runWorkflow name wid body)
                    `shouldReturn` Right Suspended

            it "fires a sleep longer than the resume cadence under an active resume worker" $ \storeHandle -> do
                counter <- newIORef (0 :: Int)
                let name = WorkflowName "sleepactive"
                    wid = WorkflowId "sa-1"
                    registry = Map.singleton name (WorkflowDef (\_ -> sleepDemoNamed counter (StepName "wait") 1))
                    drive 0 = expectationFailure "active resume cadence kept postponing the sleep"
                    drive n = do
                        Right summary <-
                            Store.runStoreIO storeHandle $
                                resumeWorkflowsOnce defaultWorkflowResumeOptions registry
                        now <- getCurrentTime
                        _ <-
                            Store.runStoreIO storeHandle $
                                runWorkflowTimerWorker Nothing now (\_ -> pure Nothing)
                        if completed summary == 1
                            then pure ()
                            else threadDelay 250_000 >> drive (n - 1)
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (sleepDemoNamed counter (StepName "wait") 1)
                drive (16 :: Int)
                readIORef counter >>= (`shouldBe` 2)

            it "uses generation-namespaced timer ids after continueAsNew" $ \storeHandle -> do
                counter <- newIORef (0 :: Int)
                let name = WorkflowName "sleeproll"
                    wid = WorkflowId "sr-1"
                    registry = Map.singleton name (WorkflowDef (\_ -> rollingSleepWorkflow counter))
                    drive 0 = expectationFailure "rolling sleep did not complete"
                    drive n = do
                        Right summary <-
                            Store.runStoreIO storeHandle $
                                resumeWorkflowsOnce defaultWorkflowResumeOptions registry
                        now <- getCurrentTime
                        _ <-
                            Store.runStoreIO storeHandle $
                                runWorkflowTimerWorker Nothing now (\_ -> pure Nothing)
                        if completed summary == 1
                            then pure ()
                            else drive (n - 1)
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (rollingSleepWorkflow counter)
                drive (12 :: Int)
                readIORef counter >>= (`shouldBe` 3)

    describe "Keiro.Workflow.Awakeable" $ do
        -- Pure (no-DB) check of the deterministic id derivation.
        it "derives a deterministic AwakeableId, stable across calls and label-sensitive" $ do
            let aid1 = deterministicAwakeableId (WorkflowName "w") (WorkflowId "1") "approval"
                aid2 = deterministicAwakeableId (WorkflowName "w") (WorkflowId "1") "approval"
                aidOther = deterministicAwakeableId (WorkflowName "w") (WorkflowId "1") "other"
                awakeableGolden = uuidLiteral "ccaeaf74-3ffe-5ea5-a118-a3441a95c279"
            aid1 `shouldBe` aid2
            (aid1 == aidOther) `shouldBe` False
            aid1 `shouldBe` AwakeableId awakeableGolden

        around (withFreshStore fixture) $ do
            it "schema: registers, completes once (idempotent), cancels, and counts pending rows" $ \storeHandle -> do
                let aidA = awakeableIdToUuid (deterministicAwakeableId (WorkflowName "sch") (WorkflowId "1") "a")
                    aidB = awakeableIdToUuid (deterministicAwakeableId (WorkflowName "sch") (WorkflowId "1") "b")
                now <- getCurrentTime
                Right () <- Store.runStoreIO storeHandle $ Store.runTransaction $ do
                    Awk.registerAwakeableTx aidA "sch" "1"
                    Awk.registerAwakeableTx aidB "sch" "1"
                Right pendingCount <- Store.runStoreIO storeHandle Awk.countPendingAwakeables
                pendingCount `shouldBe` 2
                Right (Just rowA) <- Store.runStoreIO storeHandle $ Awk.lookupAwakeable aidA
                rowA ^. #status `shouldBe` Awk.Pending
                rowA ^. #payload `shouldBe` Nothing
                -- Complete A once; the status-guarded UPDATE makes a re-complete a no-op.
                Right firstComplete <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Awk.completeAwakeableTx aidA (toJSON ("done" :: Text)) now
                firstComplete `shouldBe` True
                Right secondComplete <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Awk.completeAwakeableTx aidA (toJSON ("again" :: Text)) now
                secondComplete `shouldBe` False
                Right (Just rowA') <- Store.runStoreIO storeHandle $ Awk.lookupAwakeable aidA
                rowA' ^. #status `shouldBe` Awk.Completed
                rowA' ^. #payload `shouldBe` Just (toJSON ("done" :: Text))
                -- Cancel the still-pending B; both rows are now resolved.
                Right cancelled <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Awk.cancelAwakeableTx aidB
                cancelled `shouldBe` True
                Right pendingAfter <- Store.runStoreIO storeHandle Awk.countPendingAwakeables
                pendingAfter `shouldBe` 0

            it "suspends on an unsignalled awakeable, recording a pending row and no completion" $ \storeHandle -> do
                aidRef <- newIORef Nothing
                let name = WorkflowName "approval"
                    wid = WorkflowId "wf1"
                outcome1 <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                outcome1 `shouldBe` Right Suspended
                aid <- readRequiredAwakeableId aidRef
                Right (Just row) <- Store.runStoreIO storeHandle $ Awk.lookupAwakeable (awakeableIdToUuid aid)
                row ^. #status `shouldBe` Awk.Pending
                row ^. #payload `shouldBe` Nothing
                Right pendingNow <- Store.runStoreIO storeHandle Awk.countPendingAwakeables
                pendingNow `shouldBe` 1
                Right recorded <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:approval-wf1") (StreamVersion 0) 100
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded)
                    `shouldSatisfy` \case
                        Right [StepRecorded stepName value _] ->
                            stepName == awakeableAllocStepPrefix <> "approval" && value == toJSON aid
                        _ -> False

            it "resumes with the signalled payload after signalAwakeable" $ \storeHandle -> do
                aidRef <- newIORef Nothing
                let name = WorkflowName "approval"
                    wid = WorkflowId "wf1"
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                aid <- readRequiredAwakeableId aidRef
                let awkStep = "awk:" <> awakeableIdText aid
                Right signalled <- Store.runStoreIO storeHandle $ signalAwakeable aid ("ok" :: Text)
                signalled `shouldBe` True
                Right (Just row) <- Store.runStoreIO storeHandle $ Awk.lookupAwakeable (awakeableIdToUuid aid)
                row ^. #status `shouldBe` Awk.Completed
                row ^. #payload `shouldBe` Just (toJSON ("ok" :: Text))
                Right afterSignal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:approval-wf1") (StreamVersion 0) 100
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList afterSignal)
                    `shouldSatisfy` \case
                        Right [StepRecorded allocStep _ _, StepRecorded s r _] ->
                            allocStep == awakeableAllocStepPrefix <> "approval" && s == awkStep && r == toJSON ("ok" :: Text)
                        _ -> False
                outcome2 <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                outcome2 `shouldBe` Right (Completed "ok!")
                Right afterResume <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:approval-wf1") (StreamVersion 0) 100
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList afterResume)
                    `shouldSatisfy` \case
                        Right [StepRecorded allocStep _ _, StepRecorded s1 _ _, StepRecorded "use" _ _, WorkflowCompleted _] ->
                            allocStep == awakeableAllocStepPrefix <> "approval" && s1 == awkStep
                        _ -> False

            it "is idempotent: a second signal returns False and does not change the value" $ \storeHandle -> do
                aidRef <- newIORef Nothing
                let name = WorkflowName "idem"
                    wid = WorkflowId "wf-i"
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                aid <- readRequiredAwakeableId aidRef
                let awkStep = "awk:" <> awakeableIdText aid
                Right True <- Store.runStoreIO storeHandle $ signalAwakeable aid ("ok" :: Text)
                Right again <- Store.runStoreIO storeHandle $ signalAwakeable aid ("later" :: Text)
                again `shouldBe` False
                Right (Just row) <- Store.runStoreIO storeHandle $ Awk.lookupAwakeable (awakeableIdToUuid aid)
                row ^. #payload `shouldBe` Just (toJSON ("ok" :: Text))
                Right recorded <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:idem-wf-i") (StreamVersion 0) 100
                Right decoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded))
                [r | StepRecorded s r _ <- decoded, s == awkStep] `shouldBe` [toJSON ("ok" :: Text)]

            it "throws WorkflowAwakeableCancelled after cancelAwakeable" $ \storeHandle -> do
                aidRef <- newIORef Nothing
                let name = WorkflowName "cancelwf"
                    wid = WorkflowId "wf2"
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                aid <- readRequiredAwakeableId aidRef
                Right cancelled <- Store.runStoreIO storeHandle $ cancelAwakeable aid
                cancelled `shouldBe` True
                Right (Just row) <- Store.runStoreIO storeHandle $ Awk.lookupAwakeable (awakeableIdToUuid aid)
                row ^. #status `shouldBe` Awk.Cancelled
                Store.runStoreIO storeHandle (runWorkflow name wid (approvalFlowWithId aidRef))
                    `shouldThrow` (== WorkflowAwakeableCancelled aid)
                Right recorded <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:cancelwf-wf2") (StreamVersion 0) 100
                Right decoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded))
                any (\case WorkflowCompleted{} -> True; _ -> False) decoded `shouldBe` False

            it "re-appends a missing journal entry when re-signalled (crash-safe)" $ \storeHandle -> do
                aidRef <- newIORef Nothing
                let name = WorkflowName "crash"
                    wid = WorkflowId "wf3"
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                aid <- readRequiredAwakeableId aidRef
                let awkStep = "awk:" <> awakeableIdText aid
                -- Simulate "row completed but the journal append did not happen" by
                -- completing the row directly, bypassing signalAwakeable's journal write.
                now <- getCurrentTime
                Right completedRow <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Awk.completeAwakeableTx (awakeableIdToUuid aid) (toJSON ("ok" :: Text)) now
                completedRow `shouldBe` True
                Right beforeRepair <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:crash-wf3") (StreamVersion 0) 100
                Right beforeDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList beforeRepair))
                [() | StepRecorded s _ _ <- beforeDecoded, s == awkStep] `shouldBe` []
                -- A re-signal with the same payload returns False (already completed) but
                -- repairs the missing journal entry from the stored payload.
                Right repaired <- Store.runStoreIO storeHandle $ signalAwakeable aid ("ok" :: Text)
                repaired `shouldBe` False
                Right afterRepair <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:crash-wf3") (StreamVersion 0) 100
                Right afterDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList afterRepair))
                [r | StepRecorded s r _ <- afterDecoded, s == awkStep] `shouldBe` [toJSON ("ok" :: Text)]

            it "repairs a completed awakeable row from the await arm without a second signal" $ \storeHandle -> do
                aidRef <- newIORef Nothing
                let name = WorkflowName "crash-arm"
                    wid = WorkflowId "wf4"
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                aid <- readRequiredAwakeableId aidRef
                let awkStep = "awk:" <> awakeableIdText aid
                now <- getCurrentTime
                Right True <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Awk.completeAwakeableTx (awakeableIdToUuid aid) (toJSON ("ok" :: Text)) now
                repairedRun <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                repairedRun `shouldBe` Right Suspended
                Right repairedJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:crash-arm-wf4") (StreamVersion 0) 100
                Right repairedDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList repairedJournal))
                [r | StepRecorded s r _ <- repairedDecoded, s == awkStep] `shouldBe` [toJSON ("ok" :: Text)]
                completed <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                completed `shouldBe` Right (Completed "ok!")

            it "refuses a forged coordinate-derived id for a fresh awakeable" $ \storeHandle -> do
                aidRef <- newIORef Nothing
                let name = WorkflowName "fresh-awake"
                    wid = WorkflowId "fa-1"
                    forged = deterministicAwakeableId name wid "approval"
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                real <- readRequiredAwakeableId aidRef
                real `shouldNotBe` forged
                Right forgedSignal <- Store.runStoreIO storeHandle $ signalAwakeable forged ("bad" :: Text)
                forgedSignal `shouldBe` False
                Right stillSuspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                stillSuspended `shouldBe` Suspended
                Right realSignal <- Store.runStoreIO storeHandle $ signalAwakeable real ("ok" :: Text)
                realSignal `shouldBe` True
                completed <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                completed `shouldBe` Right (Completed "ok!")

            it "adopts a generation-0 legacy deterministic row" $ \storeHandle -> do
                aidRef <- newIORef Nothing
                let name = WorkflowName "legacy-awake"
                    wid = WorkflowId "la-1"
                    legacy = deterministicAwakeableId name wid "approval"
                Right () <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Awk.registerAwakeableTx (awakeableIdToUuid legacy) (unWorkflowName name) (unWorkflowId wid)
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                adopted <- readRequiredAwakeableId aidRef
                adopted `shouldBe` legacy
                Right True <- Store.runStoreIO storeHandle $ signalAwakeable legacy ("ok" :: Text)
                completed <- Store.runStoreIO storeHandle $ runWorkflow name wid (approvalFlowWithId aidRef)
                completed `shouldBe` Right (Completed "ok!")

            it "allocates a fresh awakeable for the same label after continueAsNew" $ \storeHandle -> do
                idsRef <- newIORef []
                let name = WorkflowName "awake-roll"
                    wid = WorkflowId "ar-1"
                    body = rollingAwakeableWorkflow idsRef
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid body
                ids1 <- readIORef idsRef
                [firstAid] <- pure ids1
                Right True <- Store.runStoreIO storeHandle $ signalAwakeable firstAid ("first" :: Text)
                Right ContinuedAsNew <- Store.runStoreIO storeHandle $ runWorkflow name wid body
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow name wid body
                ids2 <- readIORef idsRef
                case ids2 of
                    [firstAgain, secondAid] -> do
                        firstAgain `shouldBe` firstAid
                        secondAid `shouldNotBe` firstAid
                        Right staleSignal <- Store.runStoreIO storeHandle $ signalAwakeable firstAid ("stale" :: Text)
                        staleSignal `shouldBe` False
                        Right stillSuspended <- Store.runStoreIO storeHandle $ runWorkflow name wid body
                        stillSuspended `shouldBe` Suspended
                        Right True <- Store.runStoreIO storeHandle $ signalAwakeable secondAid ("second" :: Text)
                        completed <- Store.runStoreIO storeHandle $ runWorkflow name wid body
                        completed `shouldBe` Right (Completed "second")
                    other -> expectationFailure ("expected two awakeable ids, got " <> show other)

    describe "Keiro.Workflow.Child" $ do
        -- M2: the reserved spawn/result step-name derivations are stable.
        it "derives the child spawn and result step names" $ do
            childSpawnStepName (WorkflowId "c1") `shouldBe` "child:c1"
            childResultStepName (WorkflowId "c1") `shouldBe` "child:c1:result"

        -- M3(a): the new terminal journal constructors round-trip through the codec.
        it "round-trips WorkflowCancelled and WorkflowFailed through the journal codec" $ do
            let t = UTCTime (ModifiedJulianDay 0) 0
                rt ev = (workflowJournalCodec ^. #decode) ((workflowJournalCodec ^. #eventType) ev) ((workflowJournalCodec ^. #encode) ev)
            rt (WorkflowCancelled t) `shouldBe` Right (WorkflowCancelled t)
            rt (WorkflowFailed "boom" t) `shouldBe` Right (WorkflowFailed "boom" t)

        around (withFreshStore fixture) $ do
            -- M1: the keiro_workflow_children table and its schema helpers.
            it "schema: registers, completes, cancels, and counts child links" $ \storeHandle -> do
                Right () <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Child.registerChildTx "c-1" "ship" "p-1" "parent" "child:c-1:result"
                Right (Just row) <- Store.runStoreIO storeHandle $ Child.lookupChild "c-1" "ship"
                row ^. #status `shouldBe` Child.Running
                row ^. #parentId `shouldBe` "p-1"
                row ^. #parentName `shouldBe` "parent"
                row ^. #awaitStep `shouldBe` "child:c-1:result"
                now <- getCurrentTime
                Right firstComplete <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Child.markChildResultTx "c-1" "ship" (toJSON ("packed+labelled" :: Text)) now
                firstComplete `shouldBe` True
                Right secondComplete <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Child.markChildResultTx "c-1" "ship" (toJSON ("again" :: Text)) now
                secondComplete `shouldBe` False
                Right () <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Child.registerChildTx "c-2" "ship" "p-1" "parent" "child:c-2:result"
                Right cancelled <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Child.markChildCancelledTx "c-2" "ship"
                cancelled `shouldBe` True
                Right kids <- Store.runStoreIO storeHandle $ Child.lookupChildrenOfParent "p-1" "parent"
                map (^. #childId) kids `shouldBe` ["c-1", "c-2"]
                Right active <- Store.runStoreIO storeHandle Child.countActiveChildren
                active `shouldBe` (0 :: Int)
                Right st <- Store.runStoreIO storeHandle $ Child.childStatus "c-1" "ship"
                st `shouldBe` Just Child.ChildCompleted

            -- M4: spawn -> drive the child (with the completion hook) -> resume parent.
            it "spawns a child, drives it, propagates its result, and resumes the parent to Completed" $ \storeHandle -> do
                let childWid = WorkflowId "ship-1"
                suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p1") (parentWorkflow childWid)
                suspended `shouldBe` Right Suspended
                Right parentJournal1 <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p1") (StreamVersion 0) 10
                Right decoded1 <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal1))
                decoded1 `shouldSatisfy` \case
                    [StepRecorded "child:ship-1" _ _] -> True
                    _ -> False
                Right (Just childRow) <- Store.runStoreIO storeHandle $ Child.lookupChild "ship-1" "ship"
                childRow ^. #status `shouldBe` Child.Running
                childRow ^. #parentId `shouldBe` "p1"
                childRow ^. #parentName `shouldBe` "parent"
                childRow ^. #awaitStep `shouldBe` "child:ship-1:result"
                -- 2) drive the child through runChildWorkflow (propagates on completion).
                childOutcome <-
                    Store.runStoreIO storeHandle $
                        runChildWorkflow defaultWorkflowRunOptions (WorkflowName "ship") childWid shipWorkflow
                childOutcome `shouldBe` Right (Completed "packed+labelled")
                Right childJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:ship-ship-1") (StreamVersion 0) 10
                traverse (decodeRecorded workflowJournalCodec) (Vector.toList childJournal)
                    `shouldSatisfy` \case
                        Right [StepRecorded "pack" _ _, StepRecorded "label" _ _, WorkflowCompleted _] -> True
                        _ -> False
                Right parentJournal2 <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p1") (StreamVersion 0) 10
                Right decoded2 <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal2))
                [r | StepRecorded "child:ship-1:result" r _ <- decoded2]
                    `shouldBe` [object ["ok" Aeson..= ("packed+labelled" :: Text)]]
                Right (Just childRow2) <- Store.runStoreIO storeHandle $ Child.lookupChild "ship-1" "ship"
                childRow2 ^. #status `shouldBe` Child.ChildCompleted
                -- 3) resume the parent: it replays past awaitChild and completes.
                resumed <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p1") (parentWorkflow childWid)
                resumed `shouldBe` Right (Completed "done:packed+labelled")
                Right parentJournal3 <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p1") (StreamVersion 0) 10
                Right decoded3 <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal3))
                any (\case StepRecorded "notify" _ _ -> True; _ -> False) decoded3 `shouldBe` True
                any (\case WorkflowCompleted{} -> True; _ -> False) decoded3 `shouldBe` True

            it "repairs a completed child row from awaitChild without another completion hook" $ \storeHandle -> do
                let childWid = WorkflowId "ship-crash"
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p-crash") (parentWorkflow childWid)
                now <- getCurrentTime
                Right transitioned <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Child.markChildResultTx "ship-crash" "ship" (toJSON ("packed+labelled" :: Text)) now
                transitioned `shouldBe` True
                Right beforeRepair <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p-crash") (StreamVersion 0) 10
                Right beforeDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList beforeRepair))
                [r | StepRecorded "child:ship-crash:result" r _ <- beforeDecoded] `shouldBe` []
                repaired <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p-crash") (parentWorkflow childWid)
                repaired `shouldBe` Right Suspended
                Right afterRepair <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p-crash") (StreamVersion 0) 10
                Right afterDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList afterRepair))
                [r | StepRecorded "child:ship-crash:result" r _ <- afterDecoded]
                    `shouldBe` [object ["ok" Aeson..= ("packed+labelled" :: Text)]]
                completed <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p-crash") (parentWorkflow childWid)
                completed `shouldBe` Right (Completed "done:packed+labelled")

            -- M5: re-invoking the parent does not re-spawn the child (crash survival).
            it "does not re-spawn the child when the parent is re-invoked" $ \storeHandle -> do
                let childWid = WorkflowId "ship-2"
                s1 <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p2") (parentWorkflow childWid)
                s1 `shouldBe` Right Suspended
                Right (Just beforeRow) <- Store.runStoreIO storeHandle $ Child.lookupChild "ship-2" "ship"
                let createdAt0 = beforeRow ^. #createdAt
                s2 <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p2") (parentWorkflow childWid)
                s2 `shouldBe` Right Suspended
                Right parentJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p2") (StreamVersion 0) 10
                Right decoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal))
                length [() | StepRecorded "child:ship-2" _ _ <- decoded] `shouldBe` 1
                Right kids <- Store.runStoreIO storeHandle $ Child.lookupChildrenOfParent "p2" "parent"
                length kids `shouldBe` 1
                map (^. #createdAt) kids `shouldBe` [createdAt0]

            -- M5: cancelling a child stops it and makes the parent's awaitChild throw.
            it "cancels a child: the child stops and the parent's awaitChild throws" $ \storeHandle -> do
                let childWid = WorkflowId "cancel-child"
                    h = ChildHandle (WorkflowName "ship") childWid
                s1 <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p3") (parentWorkflow childWid)
                s1 `shouldBe` Right Suspended
                Right cancelled <- Store.runStoreIO storeHandle $ cancelChild h
                cancelled `shouldBe` True
                Right childJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:ship-cancel-child") (StreamVersion 0) 10
                Right childDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList childJournal))
                any (\case WorkflowCancelled{} -> True; _ -> False) childDecoded `shouldBe` True
                Right st <- Store.runStoreIO storeHandle $ Child.childStatus "cancel-child" "ship"
                st `shouldBe` Just Child.ChildCancelled
                Right parentJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p3") (StreamVersion 0) 10
                Right parentDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal))
                [r | StepRecorded "child:cancel-child:result" r _ <- parentDecoded]
                    `shouldBe` [object ["cancelled" Aeson..= True]]
                -- driving the child returns Cancelled and runs none of its steps.
                childOutcome <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "ship") childWid shipWorkflow
                childOutcome `shouldBe` Right Keiro.Workflow.Cancelled
                Right childJournal2 <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:ship-cancel-child") (StreamVersion 0) 10
                Right childDecoded2 <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList childJournal2))
                any (\case StepRecorded "pack" _ _ -> True; _ -> False) childDecoded2 `shouldBe` False
                -- re-invoking the parent throws WorkflowChildCancelled.
                Store.runStoreIO
                    storeHandle
                    (runWorkflow (WorkflowName "parent") (WorkflowId "p3") (parentWorkflow childWid))
                    `shouldThrow` (== WorkflowChildCancelled (WorkflowName "ship") childWid)

            it "repairs a cancelled child row when cancelChild is retried after the row flip" $ \storeHandle -> do
                let childWid = WorkflowId "cancel-child-crash"
                    h = ChildHandle (WorkflowName "ship") childWid
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p-cancel-crash") (parentWorkflow childWid)
                Right transitioned <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Child.markChildCancelledTx "cancel-child-crash" "ship"
                transitioned `shouldBe` True
                Right retried <- Store.runStoreIO storeHandle $ cancelChild h
                retried `shouldBe` False
                Right childJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:ship-cancel-child-crash") (StreamVersion 0) 10
                Right childDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList childJournal))
                any (\case WorkflowCancelled{} -> True; _ -> False) childDecoded `shouldBe` True
                Right parentJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p-cancel-crash") (StreamVersion 0) 10
                Right parentDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal))
                [r | StepRecorded "child:cancel-child-crash:result" r _ <- parentDecoded]
                    `shouldBe` [object ["cancelled" Aeson..= True]]

            it "heals a cancelled-but-unmarked child from runChildWorkflow" $ \storeHandle -> do
                let childWid = WorkflowId "cancel-child-drive"
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p-cancel-drive") (parentWorkflow childWid)
                Right True <-
                    Store.runStoreIO storeHandle $
                        Store.runTransaction $
                            Child.markChildCancelledTx "cancel-child-drive" "ship"
                childOutcome <-
                    Store.runStoreIO storeHandle $
                        runChildWorkflow defaultWorkflowRunOptions (WorkflowName "ship") childWid shipWorkflow
                childOutcome `shouldBe` Right Keiro.Workflow.Cancelled
                Right childJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:ship-cancel-child-drive") (StreamVersion 0) 10
                Right childDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList childJournal))
                any (\case WorkflowCancelled{} -> True; _ -> False) childDecoded `shouldBe` True
                Right parentJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p-cancel-drive") (StreamVersion 0) 10
                Right parentDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal))
                [r | StepRecorded "child:cancel-child-drive:result" r _ <- parentDecoded]
                    `shouldBe` [object ["cancelled" Aeson..= True]]

            it "delivers an honest child result equal to the old cancellation sentinel" $ \storeHandle -> do
                let childWid = WorkflowId "json-cancelled-object"
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "json-parent") (WorkflowId "jp1") (jsonObjectParentWorkflow childWid)
                childOutcome <-
                    Store.runStoreIO storeHandle $
                        runChildWorkflow defaultWorkflowRunOptions (WorkflowName "json-child") childWid jsonObjectChildWorkflow
                childOutcome `shouldBe` Right (Completed (object ["cancelled" Aeson..= True]))
                completed <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "json-parent") (WorkflowId "jp1") (jsonObjectParentWorkflow childWid)
                completed `shouldBe` Right (Completed (object ["cancelled" Aeson..= True]))
                Right parentJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:json-parent-jp1") (StreamVersion 0) 10
                Right parentDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal))
                [r | StepRecorded "child:json-cancelled-object:result" r _ <- parentDecoded]
                    `shouldBe` [object ["ok" Aeson..= object ["cancelled" Aeson..= True]]]

            it "throws WorkflowStepDecodeError when an enveloped child result has the wrong type" $ \storeHandle -> do
                let childWid = WorkflowId "decode-child"
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p-decode") (parentWorkflow childWid)
                Store.runStoreIO
                    storeHandle
                    (childCompletionHook (WorkflowName "ship") childWid (toJSON (42 :: Int)))
                    `shouldReturn` Right ()
                Store.runStoreIO
                    storeHandle
                    (runWorkflow (WorkflowName "parent") (WorkflowId "p-decode") (parentWorkflow childWid))
                    `shouldThrow` \case
                        WorkflowStepDecodeError key _ -> key == "child:decode-child:result"
                        _ -> False

            it "wakes a parent with WorkflowChildFailed when a child reaches the failure ceiling" $ \storeHandle -> do
                let childWid = WorkflowId "failed-child"
                    registry =
                        Map.fromList
                            [ (WorkflowName "parent", WorkflowDef (\_ -> parentWorkflow childWid))
                            , (WorkflowName "ship", WorkflowDef (\_ -> liftIO (throwIO SimulatedCrash) *> pure ("" :: Text)))
                            ]
                    opts = defaultWorkflowResumeOptions & #maxAttempts .~ 1
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p-failed-child") (parentWorkflow childWid)
                Right summary <- Store.runStoreIO storeHandle $ resumeWorkflowsOnce opts registry
                failed summary `shouldBe` 1
                Right (Just childRow) <- Store.runStoreIO storeHandle $ Child.lookupChild "failed-child" "ship"
                childRow ^. #status `shouldBe` Child.ChildFailed
                Store.runStoreIO
                    storeHandle
                    (runWorkflow (WorkflowName "parent") (WorkflowId "p-failed-child") (parentWorkflow childWid))
                    `shouldThrow` \case
                        WorkflowChildFailed (WorkflowName "ship") (WorkflowId "failed-child") reason ->
                            "SimulatedCrash" `Text.isInfixOf` reason
                        _ -> False

            it "stops at the next step boundary when a workflow is cancelled mid-run" $ \storeHandle -> do
                counter <- newIORef 0
                let name = WorkflowName "self-cancel"
                    wid = WorkflowId "sc1"
                outcome <-
                    Store.runStoreIO storeHandle $
                        runWorkflow name wid (selfCancellingWorkflow name wid counter)
                outcome `shouldBe` Right Keiro.Workflow.Cancelled
                readIORef counter `shouldReturn` 2
                Right recorded <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:self-cancel-sc1") (StreamVersion 0) 10
                Right decoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList recorded))
                any (\case StepRecorded "three" _ _ -> True; _ -> False) decoded `shouldBe` False

            -- EP-42 worker-driven variant: the resume worker drives both parent and
            -- child from a registry, selecting childCompletionHook for the child and
            -- union-discovering the zero-step child.
            it "drives a parent and its child to completion through the resume worker" $ \storeHandle -> do
                let childWid = WorkflowId "ship-3"
                    registry =
                        Map.fromList
                            [ (WorkflowName "parent", WorkflowDef (\_ -> parentWorkflow childWid))
                            , (WorkflowName "ship", WorkflowDef (\_ -> shipWorkflow))
                            ]
                Right Suspended <-
                    Store.runStoreIO storeHandle $
                        runWorkflow (WorkflowName "parent") (WorkflowId "p4") (parentWorkflow childWid)
                let drive = Store.runStoreIO storeHandle (resumeWorkflowsOnce defaultWorkflowResumeOptions registry)
                Right _ <- drive
                Right _ <- drive
                Right _ <- drive
                Right parentJournal <-
                    Store.runStoreIO storeHandle $
                        Store.readStreamForward (StreamName "wf:parent-p4") (StreamVersion 0) 10
                Right parentDecoded <- pure (traverse (decodeRecorded workflowJournalCodec) (Vector.toList parentJournal))
                any (\case WorkflowCompleted{} -> True; _ -> False) parentDecoded `shouldBe` True
                Right (Just childRow) <- Store.runStoreIO storeHandle $ Child.lookupChild "ship-3" "ship"
                childRow ^. #status `shouldBe` Child.ChildCompleted

            it "attaches to a completed child after continueAsNew" $ \storeHandle -> do
                let childWid = WorkflowId "ship-rotated"
                    parentName = WorkflowName "parent-rotating"
                    parentId = WorkflowId "p-rotating"
                    body = rotatingParentWorkflow childWid
                Right Suspended <- Store.runStoreIO storeHandle $ runWorkflow parentName parentId body
                childOutcome <-
                    Store.runStoreIO storeHandle $
                        runChildWorkflow defaultWorkflowRunOptions (WorkflowName "ship") childWid shipWorkflow
                childOutcome `shouldBe` Right (Completed "packed+labelled")
                Right ContinuedAsNew <- Store.runStoreIO storeHandle $ runWorkflow parentName parentId body
                repair <- Store.runStoreIO storeHandle $ runWorkflow parentName parentId body
                repair `shouldBe` Right Suspended
                completed <- Store.runStoreIO storeHandle $ runWorkflow parentName parentId body
                completed `shouldBe` Right (Completed "packed+labelled")

    describe "Keiro.Workflow.Gc" $ around (withFreshStore fixture) $ do
        it "deletes terminal workflow data after retention" $ \storeHandle -> do
            let name = WorkflowName "gc-basic"
                wid = WorkflowId "gb-1"
                gcStreamName = workflowGenerationStreamName name wid 0
                aid = fromMaybe (error "invalid gc awakeable uuid") (fromString "00000000-0000-0000-0000-0000000000a1")
                timerId = fromMaybe (error "invalid gc timer uuid") (fromString "00000000-0000-0000-0000-0000000000a2")
            counter <- newIORef (0 :: Int)
            Right (Completed _) <-
                Store.runStoreIO storeHandle $
                    runWorkflowWith
                        (defaultWorkflowRunOptions & #snapshotPolicy .~ OnTerminal)
                        name
                        wid
                        (demoWorkflow counter)
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $ do
                        Awk.registerAwakeableTx aid "gc-basic" "gb-1"
                        Tx.statement (timerId, "gc-basic", "gb-1", now, object ["kind" Aeson..= ("keiro.workflow.sleep" :: Text)], "fired") insertGcTimerStmt
            Right beforeCounts <- Store.runStoreIO storeHandle $ workflowOwnedRowCounts "gc-basic" "gb-1"
            beforeCounts `shouldBe` (1, 3, 1, 0, 1, 1)
            Right freshSummary <-
                Store.runStoreIO storeHandle $
                    WorkflowGc.gcWorkflowsOnce
                        now
                        WorkflowGc.WorkflowGcPolicy{retention = 3600, batchSize = 10}
            freshSummary `shouldBe` WorkflowGc.WorkflowGcSummary{scanned = 0, deleted = 0}
            Right (Just _) <- Store.runStoreIO storeHandle $ Store.lookupStreamId gcStreamName
            Right deletedSummary <-
                Store.runStoreIO storeHandle $
                    WorkflowGc.gcWorkflowsOnce
                        (addUTCTime 1 now)
                        WorkflowGc.WorkflowGcPolicy{retention = 0, batchSize = 10}
            deletedSummary `shouldBe` WorkflowGc.WorkflowGcSummary{scanned = 1, deleted = 1}
            Right Nothing <- Store.runStoreIO storeHandle $ Store.lookupStreamId gcStreamName
            Right afterCounts <- Store.runStoreIO storeHandle $ workflowOwnedRowCounts "gc-basic" "gb-1"
            afterCounts `shouldBe` (0, 0, 0, 0, 0, 0)

        it "keeps completed children while a parent is live and converges after partial cleanup" $ \storeHandle -> do
            let parentName = WorkflowName "gc-live-parent"
                parentId = WorkflowId "gp-1"
                childName = WorkflowName "gc-child"
                childId = WorkflowId "gc-1"
            now <- getCurrentTime
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $ do
                        Instance.upsertInstanceTx "gp-1" "gc-live-parent" 0 Instance.WfRunning Nothing
                        Child.registerChildTx "gc-1" "gc-child" "gp-1" "gc-live-parent" "child:gc-1:result"
                        void (Child.markChildResultTx "gc-1" "gc-child" (toJSON ("ok" :: Text)) now)
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry childName childId (WorkflowCompleted now)
            Right held <-
                Store.runStoreIO storeHandle $
                    WorkflowGc.gcWorkflowsOnce
                        (addUTCTime 1 now)
                        WorkflowGc.WorkflowGcPolicy{retention = 0, batchSize = 10}
            held `shouldBe` WorkflowGc.WorkflowGcSummary{scanned = 0, deleted = 0}
            Right childStillThere <- Store.runStoreIO storeHandle $ Store.lookupStreamId (workflowGenerationStreamName childName childId 0)
            childStillThere `shouldSatisfy` isJust
            Right () <-
                Store.runStoreIO storeHandle $
                    appendJournalEntry parentName parentId (WorkflowCompleted now)
            Right () <-
                Store.runStoreIO storeHandle $
                    Store.runTransaction $
                        Tx.statement ("gc-1", "gc-child") deleteGcStepsStmt
            Right collected <-
                Store.runStoreIO storeHandle $
                    WorkflowGc.gcWorkflowsOnce
                        (addUTCTime 1 now)
                        WorkflowGc.WorkflowGcPolicy{retention = 0, batchSize = 10}
            collected `shouldBe` WorkflowGc.WorkflowGcSummary{scanned = 2, deleted = 2}
            Right parentGone <- Store.runStoreIO storeHandle $ Instance.lookupInstance parentName parentId
            parentGone `shouldBe` Nothing
            Right childGone <- Store.runStoreIO storeHandle $ Instance.lookupInstance childName childId
            childGone `shouldBe` Nothing
            Right childRows <- Store.runStoreIO storeHandle $ workflowOwnedChildCount "gc-child" "gc-1"
            childRows `shouldBe` 0

{- | Increment a shared counter and return its new value (the step's side
effect, so replay can be proven by watching the counter).
-}
incrementAndRead :: IORef Int -> IO Int
incrementAndRead ref = atomicModifyIORef' ref (\n -> (n + 1, n + 1))

{- | Six numbered steps, each returning its index after bumping a shared
counter. The counter lets a re-hydration prove the steps short-circuit
(it stays at 6 when every step is replayed from the journal/snapshot).
-}
countingSixSteps :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es [Int]
countingSixSteps counter =
    mapM
        (\i -> step (StepName ("s" <> Text.pack (show i))) (liftIO (incrementAndRead counter) >> pure i))
        [1 .. 6]

newtype Approx = Approx Double
    deriving stock (Eq, Show)

instance ToJSON Approx where
    toJSON (Approx d) = toJSON (round d :: Int)

instance FromJSON Approx where
    parseJSON value = do
        n <- Aeson.parseJSON value
        pure (Approx (fromIntegral (n :: Int)))

data RejectingRoundTrip = RejectingRoundTrip
    deriving stock (Eq, Show)

instance ToJSON RejectingRoundTrip where
    toJSON RejectingRoundTrip = Aeson.String "not-an-object"

instance FromJSON RejectingRoundTrip where
    parseJSON = Aeson.withObject "RejectingRoundTrip" $ \_ -> pure RejectingRoundTrip

{- | A distinguished exception used to simulate a process crash mid-workflow
(after a step has committed its journal append but before completion).
-}
data SimulatedCrash = SimulatedCrash
    deriving stock (Show)

instance Exception SimulatedCrash

{- | A three-step workflow; each step bumps a shared counter so a resume can
prove steps short-circuit (the counter only advances for steps that run).
-}
threeStep :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es (Int, Int, Int)
threeStep counter = do
    a <- step (StepName "s1") (liftIO (incrementAndRead counter))
    b <- step (StepName "s2") (liftIO (incrementAndRead counter))
    c <- step (StepName "s3") (liftIO (incrementAndRead counter))
    pure (a, b, c)

threeStepThenSignal :: (Workflow :> es, IOE :> es) => IORef Int -> MVar () -> Eff es (Int, Int, Int)
threeStepThenSignal counter done = do
    result <- threeStep counter
    liftIO (putMVar done ())
    pure result

{- | Runs step @"s1"@ (which commits its own journal append) then crashes, so
the journal is left with one StepRecorded and no WorkflowCompleted.
-}
crashAfterStep1 :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es (Int, Int, Int)
crashAfterStep1 counter = do
    _ <- step (StepName "s1") (liftIO (incrementAndRead counter))
    _ <- liftIO (throwIO SimulatedCrash)
    pure (0, 0, 0)

{- | Awaits an external step, then runs a step that bumps the counter. Used to
prove the resume worker drives a suspended workflow to completion once its
awaited step is journaled.
-}
awaitingThenStep :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Text
awaitingThenStep counter = do
    decision <- awaitStep (StepName "awk:approval") (pure ())
    _ <- step (StepName "use") (liftIO (incrementAndRead counter) >> pure (decision <> "!"))
    pure (decision <> "-done")

{- | A rolling-total workflow (EP-48 continue-as-new acceptance). It adds @total@
unit-valued work steps to a running total, rotating its journal every
@rotateEvery@ steps via 'continueAsNew'. The carried seed is the pair
@(runningTotal, stepsDoneGlobally)@ so each generation knows the global
progress; @genDone@ counts steps within the /current/ generation to bound it.
Each work step bumps @counter@ exactly once (proving rotation neither drops
nor double-counts) and returns 1, so the final total equals @total@.

Step names are the global step index (@w0@, @w1@, …), so they are unique
within each generation's journal and replay-stable. Note the regression
direction: on a tree where 'continueAsNew' did not rotate, this body would put
all @total@ steps on generation 0's single journal and the per-generation
@<= K@ bound below would fail for @total > K@.
-}
rollingTotal :: (Workflow :> es, IOE :> es) => IORef Int -> Int -> Int -> Eff es Int
rollingTotal counter rotateEvery total = do
    (acc0, done0) <- restoreSeed (0 :: Int, 0 :: Int)
    go acc0 done0 0
  where
    go acc done genDone
        | done >= total = pure acc -- all global work done: this generation completes
        | genDone >= rotateEvery = continueAsNew (acc, done) -- bound this generation; carry onward
        | otherwise = do
            n <-
                step
                    (StepName ("w" <> Text.pack (show done)))
                    (liftIO (modifyIORef' counter (+ 1) >> pure (1 :: Int)))
            go (acc + n) (done + 1) (genDone + 1)

-- The patch id under test (EP-49).
fraudPatchId :: PatchId
fraudPatchId = PatchId "fraud-check-v2"

{- | The workflow BEFORE the patch shipped: reserve, then await an external step
(so an instance can be left in flight, mid-journal, with one ordinary step
recorded and no completion). Used to create the in-flight instance.
-}
prePatchWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Text
prePatchWorkflow counter = do
    _ <- step (StepName "reserve-inventory") (liftIO (incrementAndRead counter) >> pure ())
    (_ :: ()) <- awaitStep (StepName "awk:gate") (pure ()) -- park here, in flight
    pure "old-done"

{- | The workflow AFTER the patch shipped: the same first step, then a
patch-gated cross-cutting branch. The in-flight instance (which already
journaled reserve-inventory under the pre-patch code) must observe False and
take the OLD branch; a fresh instance must observe True and take the NEW branch.
-}
postPatchWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Text
postPatchWorkflow counter = do
    _ <- step (StepName "reserve-inventory") (liftIO (incrementAndRead counter) >> pure ())
    useNew <- patch fraudPatchId
    if useNew
        then step (StepName "new-charge") (pure "new-branch")
        else step (StepName "old-charge") (pure "old-branch")

postPatchAfterSuspendWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Text
postPatchAfterSuspendWorkflow counter = do
    _ <- step (StepName "reserve-inventory") (liftIO (incrementAndRead counter) >> pure ())
    (_ :: ()) <- awaitStep (StepName "awk:gate") (pure ())
    useNew <- patch fraudPatchId
    if useNew
        then step (StepName "new-charge") (pure "new-branch")
        else step (StepName "old-charge") (pure "old-branch")

prePatchWakeOnlyWorkflow :: (Workflow :> es) => Eff es Text
prePatchWakeOnlyWorkflow = do
    (_ :: ()) <- awaitStep (StepName "awk:gate") (pure ())
    pure "old-done"

postPatchWakeOnlyWorkflow :: (Workflow :> es) => Eff es Text
postPatchWakeOnlyWorkflow = do
    (_ :: ()) <- awaitStep (StepName "awk:gate") (pure ())
    useNew <- patch fraudPatchId
    if useNew
        then step (StepName "new-charge") (pure "new-branch")
        else step (StepName "old-charge") (pure "old-branch")

rotatingPatchWorkflow :: (Workflow :> es) => Eff es Text
rotatingPatchWorkflow = do
    seed <- restoreSeed (0 :: Int)
    if seed < 1
        then continueAsNew (seed + 1)
        else do
            useNew <- patch fraudPatchId
            if useNew
                then step (StepName "new-charge") (pure "new-branch")
                else step (StepName "old-charge") (pure "old-branch")

{- | A workflow (EP-50 push tests) that awaits an external "awk:gate" step, then
runs a step that fills @done@ — so a test can observe the exact moment the
workflow resumes to completion. Awaiting first means the journal is empty until
the external gate append, which is what makes the instance discoverable by the
resume worker (the gate's StepRecorded is the first index row).
-}
gateThenSignal :: (Workflow :> es, IOE :> es) => MVar () -> Eff es Text
gateThenSignal done = do
    (_ :: ()) <- awaitStep (StepName "awk:gate") (pure ())
    _ <- step (StepName "after-gate") (liftIO (putMVar done ()) >> pure ())
    pure "resumed"

-- | A two-step workflow whose steps each bump a shared counter.
demoWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es (Int, Int)
demoWorkflow counter = do
    a <- step (StepName "first") (liftIO (incrementAndRead counter))
    b <- step (StepName "second") (liftIO (incrementAndRead counter))
    pure (a, b)

{- | A workflow that immediately awaits a step nothing ever arms — used to
exercise the suspend path and external completion.
-}
neverArmingWorkflow :: (Workflow :> es) => Eff es Int
neverArmingWorkflow = awaitStep (StepName "awk:test") (pure ())

{- | The awakeable validation workflow: allocate a durable promise, suspend on
it, and (once signalled) append "!" to the payload through a recorded step.
-}
approvalFlowWithId :: (Workflow :> es, Store :> es, IOE :> es) => IORef (Maybe AwakeableId) -> Eff es Text
approvalFlowWithId ref = do
    (aid, await) <- awakeableNamed (StepName "approval")
    liftIO (writeIORef ref (Just aid))
    v <- await
    step (StepName "use") (pure (v <> "!"))

readRequiredAwakeableId :: IORef (Maybe AwakeableId) -> IO AwakeableId
readRequiredAwakeableId ref =
    readIORef ref >>= \case
        Just aid -> pure aid
        Nothing -> fail "workflow did not allocate an awakeable id"

uuidLiteral :: String -> UUID
uuidLiteral raw =
    case fromString raw of
        Just uuid -> uuid
        Nothing -> error ("invalid UUID literal in test: " <> raw)

{- | A two-step workflow with a durable sleep between the steps. The sleep's
name and delay are parameters so one helper drives both the zero-delta and
the real-time tests.
-}
sleepDemoNamed ::
    (Workflow :> es, Store :> es, IOE :> es) =>
    IORef Int -> StepName -> NominalDiffTime -> Eff es (Int, Int)
sleepDemoNamed counter sName delta = do
    a <- step (StepName "a") (liftIO (incrementAndRead counter))
    sleepNamed sName delta
    b <- step (StepName "b") (liftIO (incrementAndRead counter))
    pure (a, b)

rollingSleepWorkflow ::
    (Workflow :> es, Store :> es, IOE :> es) =>
    IORef Int -> Eff es Int
rollingSleepWorkflow counter = do
    seed <- restoreSeed (0 :: Int)
    _ <- step (StepName "work") (liftIO (incrementAndRead counter))
    if seed < 2
        then sleepNamed (StepName "cool") 0 >> continueAsNew (seed + 1)
        else pure seed

rollingAwakeableWorkflow ::
    (Workflow :> es, Store :> es, IOE :> es) =>
    IORef [AwakeableId] -> Eff es Text
rollingAwakeableWorkflow idsRef = do
    seed <- restoreSeed (0 :: Int)
    (aid, await) <- awakeableNamed (StepName "gate")
    liftIO (modifyIORef' idsRef (\ids -> if aid `elem` ids then ids else ids <> [aid]))
    value <- await
    if seed < 1
        then continueAsNew (seed + 1)
        else step (StepName "use") (pure value)

rotatingParentWorkflow ::
    (Workflow :> es, Store :> es, IOE :> es) =>
    WorkflowId -> Eff es Text
rotatingParentWorkflow childWid = do
    seed <- restoreSeed (0 :: Int)
    h <- spawnChild (WorkflowName "ship") childWid shipWorkflow
    result <- awaitChild h
    if seed < 1
        then continueAsNew (seed + 1)
        else pure result

{- | A workflow that records one step, then suspends on an await — so it has a
step row but no completion marker (the unfinished-discovery case).
-}
stepThenAwaitWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Int
stepThenAwaitWorkflow counter = do
    _ <- step (StepName "s1") (liftIO (incrementAndRead counter))
    awaitStep (StepName "awk:wait") (pure ())

-- | A two-step child workflow used in the child-workflow tests.
shipWorkflow :: (Workflow :> es) => Eff es Text
shipWorkflow = do
    a <- step (StepName "pack") (pure ("packed" :: Text))
    b <- step (StepName "label") (pure (a <> "+labelled"))
    pure b

{- | A parent that spawns a @"ship"@ child (id supplied), awaits its result, and
then records a @notify@ step. Parametrised by child id so each test isolates
its own child journal.
-}
parentWorkflow :: (Workflow :> es, Store :> es, IOE :> es) => WorkflowId -> Eff es Text
parentWorkflow childWid = do
    h <- spawnChild (WorkflowName "ship") childWid shipWorkflow
    result <- awaitChild h
    _ <- step (StepName "notify") (pure ("done:" <> result))
    pure ("done:" <> result)

jsonObjectChildWorkflow :: Eff es Aeson.Value
jsonObjectChildWorkflow =
    pure (object ["cancelled" Aeson..= True])

jsonObjectParentWorkflow :: (Workflow :> es, Store :> es, IOE :> es) => WorkflowId -> Eff es Aeson.Value
jsonObjectParentWorkflow childWid = do
    h <- spawnChild (WorkflowName "json-child") childWid jsonObjectChildWorkflow
    result <- awaitChild h
    _ <- step (StepName "json-notify") (pure ())
    pure result

selfCancellingWorkflow :: (Workflow :> es, Store :> es, IOE :> es) => WorkflowName -> WorkflowId -> IORef Int -> Eff es Int
selfCancellingWorkflow name wid counter = do
    _ <- step (StepName "one") (liftIO (incrementAndRead counter))
    _ <-
        step (StepName "two") $ do
            now <- liftIO getCurrentTime
            appendJournalEntry name wid (WorkflowCancelled now)
            liftIO (incrementAndRead counter)
    step (StepName "three") (liftIO (incrementAndRead counter))

nominalDays :: Int -> NominalDiffTime
nominalDays n = fromIntegral n * 86400

attrKeyText :: AttributeKey Text -> Text
attrKeyText = unkey

attrKeyTextInt64 :: AttributeKey Int64 -> Text
attrKeyTextInt64 = unkey

textAttr :: Attributes -> Text -> Maybe Text
textAttr attrs name = case lookupAttribute attrs name of
    Just (AttributeValue (TextAttribute t)) -> Just t
    _ -> Nothing

intAttr :: Attributes -> Text -> Maybe Int64
intAttr attrs name = case lookupAttribute attrs name of
    Just (AttributeValue (IntAttribute n)) -> Just n
    _ -> Nothing

{- | A frozen snapshot of an 'ImmutableSpan'. In hs-opentelemetry 1.0 the
mutable span fields (name, attributes, status) live behind the
@spanHot :: IORef SpanHot@ field rather than directly on 'ImmutableSpan',
so the tests read that reference once after the span ends and assert on
this flat record.
-}
data CapturedSpan = CapturedSpan
    { csName :: Text
    , csKind :: SpanKind
    , csAttributes :: Attributes
    , csStatus :: SpanStatus
    , csContext :: SpanContext
    , csParent :: Maybe Span
    }

captureSpan :: ImmutableSpan -> IO CapturedSpan
captureSpan sp = do
    hot <- readIORef (spanHot sp)
    pure
        CapturedSpan
            { csName = hotName hot
            , csKind = spanKind sp
            , csAttributes = hotAttributes hot
            , csStatus = hotStatus hot
            , csContext = spanContext sp
            , csParent = spanParent sp
            }

{- | Tiny in-process \"Kafka topic\": an MVar of consumed records plus an
incrementing offset. The publisher pushes records here; the consumer
drains the MVar. There is no real broker — the goal of the fixture is
to validate that the keiro envelope and outbox/inbox semantics
compose correctly across two isolated PostgreSQL contexts.
-}
newtype KafkaTopic = KafkaTopic (MVar (Int64, [InboxKafka.KafkaInboundRecord]))

newKafkaTopic :: IO KafkaTopic
newKafkaTopic = KafkaTopic <$> newMVar (0, [])

kafkaTopicAccept :: (MonadIO m) => KafkaTopic -> OutboxRow -> m ()
kafkaTopicAccept (KafkaTopic ref) row = liftIO $ do
    let record = OutboxKafka.outboxRowToKafkaRecord row
        headersText =
            [ (TE.decodeUtf8 name, TE.decodeUtf8 value)
            | (name, value) <- record ^. #headers
            ]
    now <- getCurrentTime
    modifyMVar ref $ \(nextOffset, acc) ->
        let inbound =
                InboxKafka.KafkaInboundRecord
                    { topic = record ^. #topic
                    , partition = 0
                    , offset = nextOffset
                    , key = fmap TE.decodeUtf8 (record ^. #key)
                    , payload = record ^. #payload
                    , headers = headersText
                    , receivedAt = now
                    }
         in pure ((nextOffset + 1, inbound : acc), ())

kafkaTopicPublish ::
    forall es.
    (IOE :> es) =>
    KafkaTopic ->
    OutboxRow ->
    Eff es PublishOutcome
kafkaTopicPublish topic row = do
    kafkaTopicAccept topic row
    pure PublishSucceeded

perRow ::
    (OutboxRow -> Eff es PublishOutcome) ->
    [OutboxRow] ->
    Eff es [(OutboxId, PublishOutcome)]
perRow publish rows =
    traverse publishOne rows
  where
    publishOne row = do
        outcome <- publish row
        pure (row ^. #outboxId, outcome)

drainKafkaTopic :: KafkaTopic -> IO [InboxKafka.KafkaInboundRecord]
drainKafkaTopic (KafkaTopic ref) = do
    (_, acc) <- readMVar ref
    pure (reverse acc)

redeliverWithDifferentOffset ::
    InboxKafka.KafkaInboundRecord ->
    InboxKafka.KafkaInboundRecord
redeliverWithDifferentOffset record = record & #offset .~ (record ^. #offset) + 1000

data ConsumeResult a
    = ConsumeDecodeFailed !InboxKafka.KafkaDecodeError
    | ConsumePolicyUnsatisfied !InboxError
    | ConsumeApplied !(InboxResult a)
    deriving stock (Eq, Show)

{- | A worker-shaped consumer: decode the Kafka record into an
IntegrationEvent and run it through the inbox.
-}
consumeAndApply ::
    forall es.
    (IOE :> es, Store :> es) =>
    InboxKafka.KafkaInboundRecord ->
    (IntegrationEvent -> Tx.Transaction ()) ->
    Eff es (ConsumeResult ())
consumeAndApply record handler =
    case InboxKafka.integrationEventFromKafka record of
        Left err -> pure (ConsumeDecodeFailed err)
        Right (event, kafkaRef) -> do
            result <-
                runInboxTransaction Nothing PreferIntegrationMessageId event (Just kafkaRef) handler
            case result of
                Left err -> pure (ConsumePolicyUnsatisfied err)
                Right applied -> pure (ConsumeApplied applied)

billingReactionHandler :: IntegrationEvent -> Tx.Transaction ()
billingReactionHandler event = case decodeJsonIntegrationEvent event of
    Left _ -> Tx.condemn
    Right (OrderSubmittedPayload orderId quantity) ->
        Tx.statement (orderId, fromIntegral quantity :: Int64) insertReceivedOrderStmt

loggingReactionHandler :: Text -> IntegrationEvent -> Tx.Transaction ()
loggingReactionHandler _ event = do
    -- The cross-context test only needs the (eventType, key) pair, not
    -- the decoded payload.
    let key = fromMaybe "" (event ^. #key)
    Tx.statement (event ^. #source, event ^. #eventType, key) appendBillingEventLogStmt

insertReceivedOrderStmt :: Statement (Text, Int64) ()
insertReceivedOrderStmt =
    preparable
        """
        INSERT INTO billing_received_orders (order_id, quantity) VALUES ($1, $2)
        ON CONFLICT (order_id) DO NOTHING
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

billingReceivedOrdersCountStmt :: Statement () Int
billingReceivedOrdersCountStmt =
    preparable
        "SELECT COUNT(*)::bigint FROM billing_received_orders"
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

appendBillingEventLogStmt :: Statement (Text, Text, Text) ()
appendBillingEventLogStmt =
    preparable
        "INSERT INTO billing_event_log (source, event_type, order_id) VALUES ($1, $2, $3)"
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

billingEventLogStmt :: Statement () [(Text, Text)]
billingEventLogStmt =
    preparable
        "SELECT event_type, order_id FROM billing_event_log ORDER BY seq"
        E.noParams
        ( D.rowList
            ( (,)
                <$> D.column (D.nonNullable D.text)
                <*> D.column (D.nonNullable D.text)
            )
        )

orderSubmittedEnvelope :: Text -> Int -> Text -> IntegrationEvent
orderSubmittedEnvelope orderId quantity messageId =
    encodeJsonIntegrationEvent
        ( sampleIntegrationEnvelope
            & #messageId
            .~ messageId
            & #eventType
            .~ "OrderSubmitted"
            & #key
            .~ Just orderId
        )
        (OrderSubmittedPayload orderId quantity)

orderCancelledEnvelope :: Text -> Text -> IntegrationEvent
orderCancelledEnvelope orderId messageId =
    sampleIntegrationEnvelope
        & #messageId
        .~ messageId
        & #eventType
        .~ "OrderCancelled"
        & #key
        .~ Just orderId
        & #payloadBytes
        .~ ("{\"orderId\":\"" <> TE.encodeUtf8 orderId <> "\"}")
        & #contentType
        .~ ApplicationJson

inboxTestCounterInsertStmt :: Statement Text ()
inboxTestCounterInsertStmt =
    preparable
        "INSERT INTO inbox_test_counter (message_id) VALUES ($1)"
        (E.param (E.nonNullable E.text))
        D.noResult

inboxTestCounterCountStmt :: Statement () Int
inboxTestCounterCountStmt =
    preparable
        "SELECT COUNT(*)::bigint FROM inbox_test_counter"
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

sampleProducer :: IntegrationProducer ()
sampleProducer =
    IntegrationProducer
        { name = "ordering-integration-producer"
        , source = "ordering"
        , messageIdPrefix = "msg"
        , mapEvent = \_recorded () -> Just sampleDraft
        }

sampleDraft :: IntegrationEventDraft
sampleDraft =
    IntegrationEventDraft
        { destination = "billing.orders.v1"
        , key = Just "order-123"
        , eventType = "OrderSubmitted"
        , schemaVersion = 1
        , contentType = ApplicationJson
        , schemaReference = Nothing
        , sourceEventId = Nothing
        , sourceGlobalPosition = Nothing
        , payloadBytes = "{\"orderId\":\"order-123\",\"quantity\":5}"
        , occurredAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
        , causationId = Nothing
        , correlationId = Nothing
        , traceContext = Nothing
        , attributes = Just (object ["source" Aeson..= ("test-suite" :: Text)])
        }

sampleOutboxRow :: IntegrationEvent -> OutboxRow
sampleOutboxRow event =
    OutboxRow
        { outboxId = OutboxId outboxUuid1
        , event
        , status = OutboxPending
        , attemptCount = 0
        , nextAttemptAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
        , lastError = Nothing
        , publishedAt = Nothing
        , createdAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
        , updatedAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
        }

backdateOutboxUpdatedAt :: (Store :> es) => OutboxId -> UTCTime -> Eff es ()
backdateOutboxUpdatedAt oid timestamp =
    Store.runTransaction $
        Tx.statement (unOutboxId oid, timestamp) backdateOutboxUpdatedAtStmt

backdateOutboxUpdatedAtStmt :: Statement (UUID, UTCTime) ()
backdateOutboxUpdatedAtStmt =
    preparable
        "UPDATE keiro.keiro_outbox SET updated_at = $2 WHERE outbox_id = $1"
        ( contrazip2
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult

backdateOutboxPublishedAt :: (Store :> es) => OutboxId -> UTCTime -> Eff es ()
backdateOutboxPublishedAt oid timestamp =
    Store.runTransaction $
        Tx.statement (unOutboxId oid, timestamp) backdateOutboxPublishedAtStmt

backdateOutboxPublishedAtStmt :: Statement (UUID, UTCTime) ()
backdateOutboxPublishedAtStmt =
    preparable
        "UPDATE keiro.keiro_outbox SET published_at = $2 WHERE outbox_id = $1"
        ( contrazip2
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult

outboxUuid1, outboxUuid2, outboxUuid3, outboxUuid4 :: UUID
outboxUuid1 = case fromString "018f0f18-0000-7000-8000-000000000a01" of
    Just uuid -> uuid
    Nothing -> error "invalid outbox uuid 1"
outboxUuid2 = case fromString "018f0f18-0000-7000-8000-000000000a02" of
    Just uuid -> uuid
    Nothing -> error "invalid outbox uuid 2"
outboxUuid3 = case fromString "018f0f18-0000-7000-8000-000000000a03" of
    Just uuid -> uuid
    Nothing -> error "invalid outbox uuid 3"
outboxUuid4 = case fromString "018f0f18-0000-7000-8000-000000000a04" of
    Just uuid -> uuid
    Nothing -> error "invalid outbox uuid 4"

outboxIdFromOrdinal :: Word64 -> OutboxId
outboxIdFromOrdinal n =
    OutboxId (fromWords64 0x018f0f1800007000 (0x8000000000000000 + n))

uniqueIds :: (Eq a) => [a] -> [a]
uniqueIds = foldr (\x xs -> if x `elem` xs then xs else x : xs) []

data OrderSubmittedPayload = OrderSubmittedPayload
    { orderId :: !Text
    , quantity :: !Int
    }
    deriving stock (Generic, Eq, Show)

instance ToJSON OrderSubmittedPayload where
    toJSON = genericToJSON (aesonPrefix camelCase)
    toEncoding = genericToEncoding (aesonPrefix camelCase)

instance FromJSON OrderSubmittedPayload where
    parseJSON = genericParseJSON (aesonPrefix camelCase)

sampleIntegrationEnvelope :: IntegrationEvent
sampleIntegrationEnvelope =
    IntegrationEvent
        { messageId = "018f0f18-17aa-7000-8000-0000000000aa"
        , source = "ordering"
        , destination = "billing.orders.v1"
        , key = Just "order-123"
        , eventType = "OrderSubmitted"
        , schemaVersion = 1
        , contentType = ApplicationJson
        , schemaReference =
            Just
                SchemaReference
                    { registry = Just "https://schemas.example/registry"
                    , subject = Just "billing.orders.v1.OrderSubmitted"
                    , version = Just 1
                    , schemaId = Just 42
                    , fingerprint = Just "sha256:abc123"
                    }
        , sourceEventId = Just (EventId integrationSourceEventUuid)
        , sourceGlobalPosition = Just (GlobalPosition 42)
        , payloadBytes = "{\"orderId\":\"order-123\",\"quantity\":5}"
        , occurredAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
        , causationId = Just (EventId integrationCausationUuid)
        , correlationId = Just (EventId integrationCorrelationUuid)
        , traceContext =
            Just
                TraceContext
                    { traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
                    , tracestate = Just "rojo=00f067aa0ba902b7"
                    }
        , attributes = Nothing
        }

integrationSourceEventUuid :: UUID
integrationSourceEventUuid =
    case fromString "018f0f18-17aa-7000-8000-000000000003" of
        Just uuid -> uuid
        Nothing -> error "invalid integration source event UUID"

integrationCausationUuid :: UUID
integrationCausationUuid =
    case fromString "018f0f18-17aa-7000-8000-000000000004" of
        Just uuid -> uuid
        Nothing -> error "invalid integration causation UUID"

integrationCorrelationUuid :: UUID
integrationCorrelationUuid =
    case fromString "018f0f18-17aa-7000-8000-000000000005" of
        Just uuid -> uuid
        Nothing -> error "invalid integration correlation UUID"

data OrderStream

data OrderEvent
    = OrderPlaced !Text !Int
    deriving stock (Generic, Eq, Show)

data OrderState
    = Idle
    deriving stock (Generic, Eq, Show)

data OrderCommand
    = PlaceOrder
    deriving stock (Generic, Eq, Show)

orderCodec :: Codec OrderEvent
orderCodec =
    Codec
        { eventTypes = EventType "OrderPlaced" :| []
        , eventType = \case
            OrderPlaced{} -> EventType "OrderPlaced"
        , schemaVersion = 2
        , encode = \case
            OrderPlaced orderId quantity ->
                object ["orderId" Aeson..= orderId, "quantity" Aeson..= quantity]
        , decode = parseOrderPlaced
        , upcasters = [(1, const upcastOrderPlacedV1)]
        }

gappyCodec :: Codec OrderEvent
gappyCodec =
    Codec
        { eventTypes = orderCodec ^. #eventTypes
        , eventType = orderCodec ^. #eventType
        , schemaVersion = 4
        , encode = orderCodec ^. #encode
        , decode = orderCodec ^. #decode
        , upcasters = [(1, const upcastOrderPlacedV1), (3, const Right)]
        }

parseOrderPlaced :: EventType -> Value -> Either Text OrderEvent
parseOrderPlaced _ value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (fromStringLiteral message)
  where
    parser = withObject "OrderPlaced" $ \objectValue ->
        OrderPlaced
            <$> objectValue .: "orderId"
            <*> objectValue .: "quantity"

upcastOrderPlacedV1 :: Value -> Either Text Value
upcastOrderPlacedV1 value =
    case parseEither parser value of
        Right migrated -> Right migrated
        Left message -> Left (fromStringLiteral message)
  where
    parser = withObject "OrderPlacedV1" $ \objectValue -> do
        orderId <- objectValue .: "orderId"
        quantity <- objectValue .: "qty"
        pure (object ["orderId" Aeson..= (orderId :: Text), "quantity" Aeson..= (quantity :: Int)])

metadataForOrDie :: Int -> Maybe Value -> Value
metadataForOrDie version existing =
    either (error . show) id (metadataFor version existing)

emptyTransducer :: SymTransducer () '[] OrderState OrderCommand OrderEvent
emptyTransducer =
    SymTransducer
        { edgesOut = \_ -> []
        , initial = Idle
        , initialRegs = RNil
        , isFinal = \_ -> True
        }

type CounterEventStream = EventStream (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent

type ValidatedCounterEventStream = ValidatedEventStream (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent

type SnapshotCounterRegs = '[ '("lastAmount", Int)]

type SnapshotCounterEventStream = EventStream (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent

type ValidatedSnapshotCounterEventStream = ValidatedEventStream (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent

data CounterCommand
    = Add !Int
    deriving stock (Generic, Eq, Show)

data CounterEvent
    = CounterAdded !Int
    | CounterAudited !Int
    deriving stock (Generic, Eq, Show)

data CounterState
    = Counting
    deriving stock (Generic, Eq, Show, Enum, Bounded, Ord)
    deriving anyclass (FromJSON, ToJSON)

counterEventStreamDef :: CounterEventStream
counterEventStreamDef =
    EventStream
        { transducer = counterTransducer
        , initialState = Counting
        , initialRegisters = RNil
        , eventCodec = counterCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Never
        , stateCodec = Nothing
        }

counterEventStream :: ValidatedCounterEventStream
counterEventStream = mkEventStreamOrThrow "counter" counterEventStreamDef

noOpCounterEventStreamDef :: CounterEventStream
noOpCounterEventStreamDef =
    counterEventStreamDef & #transducer .~ noOpCounterTransducer

noOpCounterEventStream :: ValidatedCounterEventStream
noOpCounterEventStream = mkEventStreamOrThrow "counter-no-op" noOpCounterEventStreamDef

counterTransducer :: SymTransducer (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent
counterTransducer =
    SymTransducer
        { edgesOut = \case
            Counting ->
                [ Edge
                    { guard = matchInCtor addCtor
                    , update = UKeep
                    , output = [pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)]
                    , target = Counting
                    }
                ]
        , initial = Counting
        , initialRegs = RNil
        , isFinal = \_ -> False
        }

noOpCounterTransducer :: SymTransducer (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent
noOpCounterTransducer =
    SymTransducer
        { edgesOut = \case
            Counting ->
                [ Edge
                    { guard = matchInCtor addCtor
                    , update = UKeep
                    , output = []
                    , target = Counting
                    }
                ]
        , initial = Counting
        , initialRegs = RNil
        , isFinal = \_ -> False
        }

multiCounterEventStreamDef :: CounterEventStream
multiCounterEventStreamDef =
    counterEventStreamDef & #transducer .~ multiCounterTransducer

multiCounterEventStream :: ValidatedCounterEventStream
multiCounterEventStream = mkEventStreamOrThrow "counter-multi" multiCounterEventStreamDef

multiCounterTransducer :: SymTransducer (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent
multiCounterTransducer =
    SymTransducer
        { edgesOut = \case
            Counting ->
                [ Edge
                    { guard = matchInCtor addCtor
                    , update = UKeep
                    , output =
                        [ pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)
                        , pack addCtor counterAuditedCtor (inpCtor addCtor #amount *: oNil)
                        ]
                    , target = Counting
                    }
                ]
        , initial = Counting
        , initialRegs = RNil
        , isFinal = \_ -> False
        }

snapshotCounterEventStreamDef :: SnapshotCounterEventStream
snapshotCounterEventStreamDef =
    EventStream
        { transducer = snapshotCounterTransducer
        , initialState = Counting
        , initialRegisters = RCons (Proxy @"lastAmount") 0 RNil
        , eventCodec = counterCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Every 2
        , stateCodec = Just (defaultStateCodec @SnapshotCounterRegs @CounterState 1)
        }

snapshotCounterEventStream :: ValidatedSnapshotCounterEventStream
snapshotCounterEventStream = mkEventStreamOrThrow "snapshot-counter" snapshotCounterEventStreamDef

snapshotCounterTransducer :: SymTransducer (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent
snapshotCounterTransducer =
    SymTransducer
        { edgesOut = \case
            Counting ->
                [ Edge
                    { guard = matchInCtor addCtor
                    , update =
                        USet
                            (#lastAmount :: IndexN "lastAmount" SnapshotCounterRegs Int)
                            (inpCtor addCtor #amount)
                    , output = [pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)]
                    , target = Counting
                    }
                ]
        , initial = Counting
        , initialRegs = RCons (Proxy @"lastAmount") 0 RNil
        , isFinal = \_ -> False
        }

multiSnapshotCounterEventStreamDef :: SnapshotCounterEventStream
multiSnapshotCounterEventStreamDef =
    snapshotCounterEventStreamDef
        & #transducer
        .~ multiSnapshotCounterTransducer
        & #snapshotPolicy
        .~ Every 1

multiSnapshotCounterEventStream :: ValidatedSnapshotCounterEventStream
multiSnapshotCounterEventStream = mkEventStreamOrThrow "snapshot-counter-multi" multiSnapshotCounterEventStreamDef

multiSnapshotCounterTransducer :: SymTransducer (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent
multiSnapshotCounterTransducer =
    SymTransducer
        { edgesOut = \case
            Counting ->
                [ Edge
                    { guard = matchInCtor addCtor
                    , update =
                        USet
                            (#lastAmount :: IndexN "lastAmount" SnapshotCounterRegs Int)
                            (inpCtor addCtor #amount)
                    , output =
                        [ pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)
                        , pack addCtor counterAuditedCtor (inpCtor addCtor #amount *: oNil)
                        ]
                    , target = Counting
                    }
                ]
        , initial = Counting
        , initialRegs = RCons (Proxy @"lastAmount") 0 RNil
        , isFinal = \_ -> False
        }

guardedSnapshotCounterEventStreamDef :: SnapshotCounterEventStream
guardedSnapshotCounterEventStreamDef =
    snapshotCounterEventStreamDef & #transducer .~ guardedSnapshotCounterTransducer

guardedSnapshotCounterEventStream :: ValidatedSnapshotCounterEventStream
guardedSnapshotCounterEventStream = mkEventStreamOrThrow "snapshot-counter-guarded" guardedSnapshotCounterEventStreamDef

guardedSnapshotCounterTransducer :: SymTransducer (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent
guardedSnapshotCounterTransducer =
    SymTransducer
        { edgesOut = \case
            Counting ->
                [ Edge
                    { guard =
                        PAnd
                            (matchInCtor addCtor)
                            (inpCtor addCtor #amount .== proj (#lastAmount :: Keiki.Index SnapshotCounterRegs Int))
                    , update =
                        USet
                            (#lastAmount :: IndexN "lastAmount" SnapshotCounterRegs Int)
                            (inpCtor addCtor #amount)
                    , output = [pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)]
                    , target = Counting
                    }
                ]
        , initial = Counting
        , initialRegs = RCons (Proxy @"lastAmount") 0 RNil
        , isFinal = \_ -> False
        }

{- | A deliberately replay-unsafe stream: its single edge is an ε-edge
(empty @output@) whose @update@ reads the command's @amount@. Because
the edge emits no event, that command field cannot be recovered on
replay, so keiki's hidden-input check flags it. Used to prove
'validateEventStream' / 'mkEventStream' reject an unsafe stream.
-}
brokenHiddenInputEventStream :: SnapshotCounterEventStream
brokenHiddenInputEventStream =
    snapshotCounterEventStreamDef & #transducer .~ brokenHiddenInputTransducer

brokenHiddenInputTransducer :: SymTransducer (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent
brokenHiddenInputTransducer =
    SymTransducer
        { edgesOut = \case
            Counting ->
                [ Edge
                    { guard = matchInCtor addCtor
                    , update =
                        USet
                            (#lastAmount :: IndexN "lastAmount" SnapshotCounterRegs Int)
                            (inpCtor addCtor #amount)
                    , output = []
                    , target = Counting
                    }
                ]
        , initial = Counting
        , initialRegs = RCons (Proxy @"lastAmount") 0 RNil
        , isFinal = \_ -> False
        }

type AddFields = '[ '("amount", Int)]

addCtor :: InCtor CounterCommand AddFields
addCtor =
    InCtor
        { icName = "Add"
        , icMatch = \case
            Add amount -> Just (RCons Proxy amount RNil)
        , icBuild = \case
            RCons _ amount RNil -> Add amount
        }

counterAddedCtor :: WireCtor CounterEvent (Int, ())
counterAddedCtor =
    WireCtor
        { wcName = "CounterAdded"
        , wcMatch = \case
            CounterAdded amount -> Just (amount, ())
            CounterAudited{} -> Nothing
        , wcBuild = \case
            (amount, ()) -> CounterAdded amount
        }

counterAuditedCtor :: WireCtor CounterEvent (Int, ())
counterAuditedCtor =
    WireCtor
        { wcName = "CounterAudited"
        , wcMatch = \case
            CounterAudited amount -> Just (amount, ())
            CounterAdded{} -> Nothing
        , wcBuild = \case
            (amount, ()) -> CounterAudited amount
        }

counterCodec :: Codec CounterEvent
counterCodec =
    Codec
        { eventTypes = EventType "CounterAdded" :| [EventType "CounterAudited"]
        , eventType = \case
            CounterAdded{} -> EventType "CounterAdded"
            CounterAudited{} -> EventType "CounterAudited"
        , schemaVersion = 1
        , encode = \case
            CounterAdded amount -> object ["amount" Aeson..= amount]
            CounterAudited amount -> object ["amount" Aeson..= amount, "audited" Aeson..= True]
        , decode = parseCounterEvent
        , upcasters = []
        }

parseCounterEvent :: EventType -> Value -> Either Text CounterEvent
parseCounterEvent (EventType tag) value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (fromStringLiteral message)
  where
    parser = withObject "CounterEvent" $ \objectValue -> do
        amount <- objectValue .: "amount"
        case tag of
            "CounterAdded" -> pure (CounterAdded amount)
            "CounterAudited" -> pure (CounterAudited amount)
            _ -> fail "unknown counter event type"

counterProcessManager ::
    ProcessManager
        CounterEvent
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
counterProcessManager =
    ProcessManager
        { name = "counter-pm"
        , correlate = \_ -> "order-1"
        , eventStream = counterEventStream
        , streamFor = \correlationId -> stream ("pm:counter-" <> correlationId)
        , targetEventStream = counterEventStream
        , targetProjections = const []
        , handle = \case
            CounterAdded amount ->
                ProcessManagerAction
                    { command = Add amount
                    , commands =
                        [ PMCommand
                            { target = stream "counter-target-order-1"
                            , command = Add amount
                            }
                        ]
                    , timers = [counterTimerRequest]
                    }
            CounterAudited amount ->
                ProcessManagerAction
                    { command = Add amount
                    , commands = []
                    , timers = []
                    }
        }

timerOnlyProcessManager ::
    ProcessManager
        CounterEvent
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
timerOnlyProcessManager =
    ProcessManager
        { name = "timer-only-pm"
        , correlate = \_ -> "order-1"
        , eventStream = noOpCounterEventStream
        , streamFor = \correlationId -> stream ("pm:timer-only-" <> correlationId)
        , targetEventStream = counterEventStream
        , targetProjections = const []
        , handle = \case
            CounterAdded amount ->
                ProcessManagerAction
                    { command = Add amount
                    , commands = []
                    , timers =
                        [ counterTimerRequest
                            & #processManagerName
                            .~ "timer-only-pm"
                        ]
                    }
            CounterAudited amount ->
                ProcessManagerAction
                    { command = Add amount
                    , commands = []
                    , timers = []
                    }
        }

-- A process manager whose OWN state stream snapshots under Every 2.
-- This is the first PM fixture to exercise a state-stream snapshot: the only
-- difference from counterProcessManager is that its eventStream carries a
-- snapshotPolicy + stateCodec (it reuses snapshotCounterEventStream), so
-- runProcessManagerOnce's manager-state append (which goes through
-- runCommandWithSql) writes and reuses snapshots. The manager registers are
-- SnapshotCounterRegs because the eventStream is a SnapshotCounterEventStream;
-- the target side stays '[]/counterEventStream exactly as counterProcessManager.
pmSnapshotCounterEventStreamDef :: SnapshotCounterEventStream
pmSnapshotCounterEventStreamDef = snapshotCounterEventStreamDef

pmSnapshotCounterEventStream :: ValidatedSnapshotCounterEventStream
pmSnapshotCounterEventStream = mkEventStreamOrThrow "pm-snapshot-counter" pmSnapshotCounterEventStreamDef

pmSnapshotProcessManager ::
    ProcessManager
        CounterEvent
        (HsPred SnapshotCounterRegs CounterCommand)
        SnapshotCounterRegs
        CounterState
        CounterCommand
        CounterEvent
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
pmSnapshotProcessManager =
    ProcessManager
        { name = "counter-snap-pm"
        , correlate = \_ -> "order-1"
        , eventStream = pmSnapshotCounterEventStream
        , streamFor = \correlationId -> stream ("pm:counter-snap-" <> correlationId)
        , targetEventStream = counterEventStream
        , targetProjections = const []
        , handle = \case
            CounterAdded amount ->
                ProcessManagerAction
                    { command = Add amount
                    , commands = [] -- keep the test focused on the manager state stream
                    , timers = []
                    }
            CounterAudited amount ->
                ProcessManagerAction
                    { command = Add amount
                    , commands = []
                    , timers = []
                    }
        }

workflowProcessManager ::
    Text ->
    Text ->
    Text ->
    ProcessManager
        CounterEvent
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
workflowProcessManager managerName managerCategory targetStreamName =
    counterProcessManager
        { name = managerName
        , streamFor = \correlationId -> stream (managerCategory <> "-" <> correlationId)
        , handle = \case
            CounterAdded amount ->
                ProcessManagerAction
                    { command = Add amount
                    , commands =
                        [ PMCommand
                            { target = stream targetStreamName
                            , command = Add amount
                            }
                        ]
                    , timers = []
                    }
            CounterAudited amount ->
                ProcessManagerAction
                    { command = Add amount
                    , commands = []
                    , timers = []
                    }
        }

assertWorkflowProcessManagerAppended ::
    Either
        Store.StoreError
        ( Either
            CommandError
            (ProcessManagerResult CounterEventStream CounterEventStream)
        ) ->
    Expectation
assertWorkflowProcessManagerAppended = \case
    Right (Right pmResult) -> do
        pmResult ^. #managerResult `shouldSatisfy` \case
            PMStateAppended{} -> True
            _ -> False
        pmResult ^. #commandResults `shouldSatisfy` \case
            [PMCommandAppended{}] -> True
            _ -> False
    other -> expectationFailure ("expected workflow process-manager success, got " <> show other)

counterTimerRequest :: TimerRequest
counterTimerRequest =
    TimerRequest
        { timerId = TimerId sampleUuid
        , processManagerName = "counter-pm"
        , correlationId = "order-1"
        , fireAt = dueTimerTime
        , payload = object ["kind" Aeson..= ("counter-timeout" :: Text)]
        }

dueTimerTime :: UTCTime
dueTimerTime = UTCTime (ModifiedJulianDay 1) (secondsToDiffTime 0)

timerStatusAndErrorStmt :: Statement UUID (Maybe (Text, Maybe Text))
timerStatusAndErrorStmt =
    preparable
        """
        SELECT status, last_error
        FROM keiro.keiro_timers
        WHERE timer_id = $1
        """
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text)))

-- | Read a timer's status and JSON payload by id (for the workflow-sleep tests).
sleepTimerStatusStmt :: Statement UUID (Maybe (Text, Value))
sleepTimerStatusStmt =
    preparable
        """
        SELECT status, payload
        FROM keiro.keiro_timers
        WHERE timer_id = $1
        """
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))

-- | Read a timer's fire time by id (for workflow-sleep re-arm tests).
sleepTimerFireAtStmt :: Statement UUID (Maybe UTCTime)
sleepTimerFireAtStmt =
    preparable
        """
        SELECT fire_at
        FROM keiro.keiro_timers
        WHERE timer_id = $1
        """
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe (D.column (D.nonNullable D.timestamptz)))

recordedFrom :: EventData -> RecordedEvent
recordedFrom event =
    RecordedEvent
        { eventId = EventId sampleUuid
        , eventType = event ^. #eventType
        , streamVersion = StreamVersion 1
        , globalPosition = GlobalPosition 1
        , originalStreamId = StreamId 1
        , originalVersion = StreamVersion 1
        , payload = event ^. #payload
        , metadata = event ^. #metadata
        , causationId = Nothing
        , correlationId = Nothing
        , createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0)
        }

recordedFromEventId :: EventId -> CounterEvent -> RecordedEvent
recordedFromEventId eventId event =
    case encodeForAppend counterCodec event of
        Right encoded -> recordedFrom encoded & #eventId .~ eventId
        Left err -> error ("test fixture failed to encode counter event: " <> show err)

appendCounterEventWithId :: Store.KirokuStore -> StreamName -> EventId -> CounterEvent -> IO ()
appendCounterEventWithId storeHandle streamName eventId event = do
    encoded <- shouldBeRight (encodeForAppend counterCodec event)
    outcome <-
        Store.runStoreIO storeHandle $
            Store.appendToStream streamName NoStream [encoded & #eventId ?~ eventId]
    case outcome of
        Right _ -> pure ()
        Left err -> expectationFailure ("failed to insert concurrent duplicate event: " <> show err)

sampleUuid :: UUID
sampleUuid =
    case fromString "018f0f18-17aa-7000-8000-000000000001" of
        Just uuid -> uuid
        Nothing -> error "invalid test UUID"

sampleUuid2 :: UUID
sampleUuid2 =
    case fromString "018f0f18-17aa-7000-8000-000000000002" of
        Just uuid -> uuid
        Nothing -> error "invalid test UUID"

sampleUuid3 :: UUID
sampleUuid3 =
    case fromString "018f0f18-17aa-7000-8000-000000000003" of
        Just uuid -> uuid
        Nothing -> error "invalid test UUID"

shouldBeRight :: (HasCallStack, Show e) => Either e a -> IO a
shouldBeRight = \case
    Right value -> pure value
    Left err -> expectationFailure ("expected Right, got Left " <> show err) *> error "unreachable"

shouldBeRight_ :: (HasCallStack, Show e) => Either e a -> Expectation
shouldBeRight_ = \case
    Right _ -> pure ()
    Left err -> expectationFailure ("expected Right, got Left " <> show err)

shouldBeLeft :: (HasCallStack, Eq e, Show e) => Either e a -> e -> Expectation
shouldBeLeft actual expected =
    case actual of
        Left err -> err `shouldBe` expected
        Right _ -> expectationFailure ("expected Left " <> show expected <> ", got Right")

fromStringLiteral :: String -> Text
fromStringLiteral = Text.pack

snapshotVersionForStreamStmt :: Statement Text (Maybe StreamVersion)
snapshotVersionForStreamStmt =
    preparable
        """
        SELECT ks.stream_version
        FROM keiro.keiro_snapshots ks
        JOIN streams s ON s.stream_id = ks.stream_id
        WHERE s.stream_name = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (StreamVersion <$> D.column (D.nonNullable D.int8)))

corruptSnapshotStateStmt :: Statement (Text, Value) ()
corruptSnapshotStateStmt =
    preparable
        """
        UPDATE keiro.keiro_snapshots ks
        SET state = $2
        FROM streams s
        WHERE s.stream_id = ks.stream_id
          AND s.stream_name = $1
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.jsonb))
        )
        D.noResult

corruptSnapshotShapeStmt :: Statement (Text, Text) ()
corruptSnapshotShapeStmt =
    preparable
        """
        UPDATE keiro.keiro_snapshots ks
        SET regfile_shape_hash = $2
        FROM streams s
        WHERE s.stream_id = ks.stream_id
          AND s.stream_name = $1
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

counterReadModel :: ReadModel Text Int
counterReadModel =
    ReadModel
        { name = "counter-read-model"
        , tableName = "counter_read_model"
        , schema = "kiroku"
        , subscriptionName = "counter-read-model-sub"
        , version = 1
        , shapeHash = "counter-read-model-v1"
        , defaultConsistency = Eventual
        , query = \modelId -> Tx.statement modelId selectCounterReadModelStmt
        }

counterInlineProjection :: InlineProjection CounterEvent
counterInlineProjection =
    InlineProjection
        { name = "counter-inline-projection"
        , apply = \event recorded ->
            case event of
                CounterAdded amount ->
                    Tx.statement
                        ( "inline"
                        , Prelude.fromIntegral amount
                        , globalPositionToInt (recorded ^. #globalPosition)
                        , Just (eventIdToUuid (recorded ^. #eventId))
                        , metadataActor recorded
                        )
                        upsertCounterReadModelStmt
                CounterAudited{} -> pure ()
        }

counterAsyncProjection :: AsyncProjection
counterAsyncProjection =
    AsyncProjection
        { name = "counter-async-projection"
        , subscriptionName = "counter-read-model-sub"
        , applyRecorded = \recorded ->
            case decodeRecorded counterCodec recorded of
                Right (CounterAdded amount) ->
                    Tx.statement
                        ( "async-idempotent"
                        , Prelude.fromIntegral amount
                        , globalPositionToInt (recorded ^. #globalPosition)
                        , Just (eventIdToUuid (recorded ^. #eventId))
                        , Nothing
                        )
                        upsertCounterReadModelStmt
                Right CounterAudited{} -> pure ()
                Left _ -> pure ()
        , idempotencyKey = \recorded -> recorded ^. #eventId
        }

fastWaitOptions :: PositionWaitOptions
fastWaitOptions =
    PositionWaitOptions
        { target = Nothing
        , timeoutMicros = 50000
        , pollMicros = 5000
        }

initializeCounterReadModelTable :: Tx.Transaction ()
initializeCounterReadModelTable =
    Tx.sql
        """
        CREATE TABLE IF NOT EXISTS counter_read_model (
          model_id TEXT PRIMARY KEY,
          amount BIGINT NOT NULL,
          last_seen BIGINT NOT NULL,
          source_event_id UUID UNIQUE,
          actor TEXT
        )
        """

-- A read model whose data table lives in an application-configured schema
-- (@app_reads@), demonstrating EP-4's configurable projection schema. Its SQL is
-- fully qualified via 'placedTable'; Keiro's own metadata stays in @keiro@.
placedTable :: Text
placedTable = qualifyTable "app_reads" "placed_counter"

placedReadModel :: ReadModel Text Int
placedReadModel =
    ReadModel
        { name = "placed-counter-read-model"
        , tableName = "placed_counter"
        , schema = "app_reads"
        , subscriptionName = "placed-counter-sub"
        , version = 1
        , shapeHash = "placed-counter-v1"
        , defaultConsistency = Eventual
        , query = \modelId -> Tx.statement modelId selectPlacedStmt
        }

placedInlineProjection :: InlineProjection CounterEvent
placedInlineProjection =
    InlineProjection
        { name = "placed-inline-projection"
        , apply = \event recorded ->
            case event of
                CounterAdded amount ->
                    Tx.statement
                        ( "placed"
                        , Prelude.fromIntegral amount
                        , globalPositionToInt (recorded ^. #globalPosition)
                        )
                        upsertPlacedStmt
                CounterAudited{} -> pure ()
        }

initializePlacedTable :: Tx.Transaction ()
initializePlacedTable =
    Tx.sql $
        TE.encodeUtf8 $
            "CREATE TABLE IF NOT EXISTS "
                <> placedTable
                <> " (\n"
                <> "  model_id TEXT PRIMARY KEY,\n"
                <> "  amount BIGINT NOT NULL,\n"
                <> "  last_seen BIGINT NOT NULL\n"
                <> ")"

upsertPlacedStmt :: Statement (Text, Int64, Int64) ()
upsertPlacedStmt =
    preparable
        ( "INSERT INTO "
            <> placedTable
            <> " (model_id, amount, last_seen)\n"
            <> "VALUES ($1, $2, $3)\n"
            <> "ON CONFLICT (model_id) DO UPDATE\n"
            <> "  SET amount = EXCLUDED.amount, last_seen = EXCLUDED.last_seen"
        )
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

selectPlacedStmt :: Statement Text Int
selectPlacedStmt =
    preparable
        ("SELECT COALESCE((SELECT amount FROM " <> placedTable <> " WHERE model_id = $1), 0)")
        (E.param (E.nonNullable E.text))
        (D.singleRow (Prelude.fromIntegral <$> D.column (D.nonNullable D.int8)))

-- Count matching base tables in a given schema; proves table placement.
pgTableCountStmt :: Statement (Text, Text) Int
pgTableCountStmt =
    preparable
        "SELECT count(*)::int FROM pg_tables WHERE schemaname = $1 AND tablename = $2"
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.singleRow (Prelude.fromIntegral <$> D.column (D.nonNullable D.int4)))

initializeProjectionDedupCounterTable :: Tx.Transaction ()
initializeProjectionDedupCounterTable =
    Tx.sql
        """
        CREATE TABLE IF NOT EXISTS projection_dedup_counter (
          id BOOLEAN PRIMARY KEY DEFAULT TRUE,
          amount BIGINT NOT NULL
        );

        INSERT INTO projection_dedup_counter (id, amount)
        VALUES (TRUE, 0)
        ON CONFLICT (id) DO NOTHING;
        """

upsertCounterReadModelStmt :: Statement (Text, Int64, Int64, Maybe UUID, Maybe Text) ()
upsertCounterReadModelStmt =
    preparable
        """
        INSERT INTO counter_read_model (model_id, amount, last_seen, source_event_id, actor)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (source_event_id) DO NOTHING
        """
        ( contrazip5
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nullable E.uuid))
            (E.param (E.nullable E.text))
        )
        D.noResult

incrementProjectionDedupCounterStmt :: Statement () ()
incrementProjectionDedupCounterStmt =
    preparable
        """
        UPDATE projection_dedup_counter
        SET amount = amount + 1
        WHERE id = TRUE
        """
        E.noParams
        D.noResult

selectProjectionDedupCounterStmt :: Statement () Int
selectProjectionDedupCounterStmt =
    preparable
        """
        SELECT amount
        FROM projection_dedup_counter
        WHERE id = TRUE
        """
        E.noParams
        (D.singleRow (Prelude.fromIntegral <$> D.column (D.nonNullable D.int8)))

selectCounterMetaStmt :: Statement Text (Int64, Maybe Text, Maybe UUID)
selectCounterMetaStmt =
    preparable
        """
        SELECT amount, actor, source_event_id
        FROM counter_read_model
        WHERE model_id = $1
        """
        (E.param (E.nonNullable E.text))
        ( D.singleRow
            ( (,,)
                <$> D.column (D.nonNullable D.int8)
                <*> D.column (D.nullable D.text)
                <*> D.column (D.nullable D.uuid)
            )
        )

selectCounterReadModelStmt :: Statement Text Int
selectCounterReadModelStmt =
    preparable
        """
        SELECT COALESCE((SELECT amount FROM counter_read_model WHERE model_id = $1), 0)
        """
        (E.param (E.nonNullable E.text))
        (D.singleRow (Prelude.fromIntegral <$> D.column (D.nonNullable D.int8)))

upsertSubscriptionCursorStmt :: Statement (Text, Int64) ()
upsertSubscriptionCursorStmt =
    preparable
        """
        INSERT INTO subscriptions (subscription_name, stream_name, last_seen)
        VALUES ($1, '$all', $2)
        ON CONFLICT (subscription_name, consumer_group_member) DO UPDATE
          SET last_seen = EXCLUDED.last_seen,
              updated_at = now()
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

upsertSubscriptionCursorMemberStmt :: Statement (Text, Int32, Int64) ()
upsertSubscriptionCursorMemberStmt =
    preparable
        """
        INSERT INTO subscriptions (subscription_name, stream_name, consumer_group_member, consumer_group_size, last_seen)
        VALUES ($1, '$all', $2, 2, $3)
        ON CONFLICT (subscription_name, consumer_group_member) DO UPDATE
          SET last_seen = EXCLUDED.last_seen,
              updated_at = now()
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

updateReadModelVersionStmt :: Statement (Text, Int64) ()
updateReadModelVersionStmt =
    preparable
        """
        UPDATE keiro.keiro_read_models
        SET version = $2
        WHERE name = $1
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

updateReadModelStatusStmt :: Statement (Text, Text) ()
updateReadModelStatusStmt =
    preparable
        """
        UPDATE keiro.keiro_read_models
        SET status = $2
        WHERE name = $1
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

readModelXminStmt :: Statement Text Text
readModelXminStmt =
    preparable
        """
        SELECT xmin::text
        FROM keiro.keiro_read_models
        WHERE name = $1
        """
        (E.param (E.nonNullable E.text))
        (D.singleRow (D.column (D.nonNullable D.text)))

globalPositionToInt :: GlobalPosition -> Int64
globalPositionToInt (GlobalPosition value) = value

eventIdToUuid :: EventId -> UUID
eventIdToUuid (EventId value) = value

metadataActor :: RecordedEvent -> Maybe Text
metadataActor recorded = do
    Aeson.Object o <- recorded ^. #metadata
    Aeson.String s <- KeyMap.lookup "actor" o
    pure s

-- Router test fixtures: an effectful, data-dependent fan-out whose target set
-- is stored in a read-model table (router_targets) rather than computed purely.

newtype RouteGroup = RouteGroup Text
    deriving stock (Generic, Eq, Show)

{- | Maps a routing group to the list of target counter stream identifiers seeded
for it. The query is genuinely effectful: 'demoRouter' calls it via 'runQuery'.
-}
routerTargetsReadModel :: ReadModel Text [Text]
routerTargetsReadModel =
    ReadModel
        { name = "router-targets-read-model"
        , tableName = "router_targets"
        , schema = "kiroku"
        , subscriptionName = "router-targets-sub"
        , version = 1
        , shapeHash = "router-targets-v1"
        , defaultConsistency = Eventual
        , query = \groupId -> Tx.statement groupId selectRouterTargetsStmt
        }

demoRouter ::
    (IOE :> es, Store :> es) =>
    Router
        RouteGroup
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
        es
demoRouter =
    Router
        { name = "demo-router"
        , key = \(RouteGroup g) -> g
        , resolve = \(RouteGroup g) -> do
            result <- runQuery Nothing routerTargetsReadModel g
            pure $ case result of
                Right targetIds ->
                    [ PMCommand{target = stream targetId, command = Add 1}
                    | targetId <- targetIds
                    ]
                Left _ -> []
        , targetEventStream = counterEventStream
        , targetProjections = const []
        }

unstableRouter ::
    (IOE :> es) =>
    IORef Int ->
    (Int -> [Text]) ->
    Router
        RouteGroup
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
        es
unstableRouter attemptsRef targetsFor =
    Router
        { name = "unstable-router"
        , key = \(RouteGroup g) -> g
        , resolve = \_ -> do
            attempt <- liftIO (atomicModifyIORef' attemptsRef (\n -> (n + 1, n)))
            pure
                [ PMCommand{target = stream targetId, command = Add 1}
                | targetId <- targetsFor attempt
                ]
        , targetEventStream = counterEventStream
        , targetProjections = const []
        }

isAppended :: PMCommandResult target -> Bool
isAppended = \case
    PMCommandAppended{} -> True
    _ -> False

isDuplicate :: PMCommandResult target -> Bool
isDuplicate = \case
    PMCommandDuplicate{} -> True
    _ -> False

initializeRouterTargetsTable :: Tx.Transaction ()
initializeRouterTargetsTable =
    Tx.sql
        """
        CREATE TABLE IF NOT EXISTS router_targets (
          group_id TEXT NOT NULL,
          target_id TEXT NOT NULL
        )
        """

insertRouterTargetStmt :: Statement (Text, Text) ()
insertRouterTargetStmt =
    preparable
        """
        INSERT INTO router_targets (group_id, target_id)
        VALUES ($1, $2)
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

selectRouterTargetsStmt :: Statement Text [Text]
selectRouterTargetsStmt =
    preparable
        """
        SELECT target_id
        FROM router_targets
        WHERE group_id = $1
        ORDER BY target_id
        """
        (E.param (E.nonNullable E.text))
        (D.rowList (D.column (D.nonNullable D.text)))

-- Router worker fixtures: an in-memory Shibuya adapter that records every
-- finalized AckDecision, plus a router whose dispatch always fails.

inMemoryAdapter ::
    (IOE :> es) =>
    IORef [AckDecision] ->
    [msg] ->
    Adapter es msg
inMemoryAdapter decisionsRef messages =
    Adapter
        { adapterName = "router-test-adapter"
        , source = Streamly.fromList (fmap ingest messages)
        , shutdown = pure ()
        }
  where
    ingest message =
        Ingested
            { envelope = routerTestEnvelope message
            , ack = AckHandle (\decision -> liftIO (modifyIORef' decisionsRef (<> [decision])))
            , lease = Nothing
            }

routerTestEnvelope :: msg -> Envelope msg
routerTestEnvelope message =
    Envelope
        { messageId = "router-test-message"
        , cursor = Nothing
        , partition = Nothing
        , enqueuedAt = Nothing
        , traceContext = Nothing
        , headers = Nothing
        , attempt = Nothing
        , attributes = mempty
        , payload = message
        }

{- | A target aggregate with no outgoing edges: every command is rejected
(CommandRejected), so a dispatch through it surfaces as PMCommandFailed,
driving the worker's AckHalt branch.
-}
rejectingEventStreamDef :: CounterEventStream
rejectingEventStreamDef =
    counterEventStreamDef & #transducer .~ rejectingTransducer

rejectingEventStream :: ValidatedCounterEventStream
rejectingEventStream = mkEventStreamOrThrow "rejecting-counter" rejectingEventStreamDef

rejectingTransducer :: SymTransducer (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent
rejectingTransducer =
    SymTransducer
        { edgesOut = \case
            Counting -> []
        , initial = Counting
        , initialRegs = RNil
        , isFinal = \_ -> False
        }

failingRouter ::
    Router
        RouteGroup
        (HsPred '[] CounterCommand)
        '[]
        CounterState
        CounterCommand
        CounterEvent
        es
failingRouter =
    Router
        { name = "failing-router"
        , key = \(RouteGroup g) -> g
        , resolve = \_ -> pure [PMCommand{target = stream "failing-target", command = Add 1}]
        , targetEventStream = rejectingEventStream
        , targetProjections = const []
        }

-- Flatten exported counter/gauge points to (instrument name, value).
flattenScalarPoints :: [ResourceMetricsExport] -> [(Text, NumberValue)]
flattenScalarPoints rmes =
    [ (name, val)
    | rme <- rmes
    , scope <- Vector.toList (resourceMetricsScopes rme)
    , export <- Vector.toList (scopeMetricsExports scope)
    , (name, val) <- pointsOf export
    ]
  where
    pointsOf (MetricExportSum n _ _ _ _ _ _ pts) =
        [(n, sumDataPointValue p) | p <- Vector.toList pts]
    pointsOf (MetricExportGauge n _ _ _ _ pts) =
        [(n, gaugeDataPointValue p) | p <- Vector.toList pts]
    pointsOf _ = []

-- Flatten exported histogram points to (instrument name, count, sum).
flattenHistogramPoints :: [ResourceMetricsExport] -> [(Text, Word64, Double)]
flattenHistogramPoints rmes =
    [ (n, histogramDataPointCount p, histogramDataPointSum p)
    | rme <- rmes
    , scope <- Vector.toList (resourceMetricsScopes rme)
    , export <- Vector.toList (scopeMetricsExports scope)
    , MetricExportHistogram n _ _ _ _ pts <- [export]
    , p <- Vector.toList pts
    ]

-- ===========================================================================
-- EP-51 sharded-subscription test helpers
-- ===========================================================================

-- A test sink the sharded handlers write to: one row per processed event,
-- idempotent on event_id (an at-least-once handler may redeliver during a
-- rebalance). worker_tag identifies which worker process handled it; stream_id
-- is the originating stream (the partition key kiroku hashes on).
createShardSinkSql :: ByteString
createShardSinkSql =
    "CREATE TABLE IF NOT EXISTS shard_sink \
    \(event_id uuid PRIMARY KEY, worker_tag int NOT NULL, stream_id bigint NOT NULL)"

-- Seed @nStreams@ category-@orders@ streams with @perStream@ events each
-- (upsert append, so it is safe to call twice in one test). Returns the total
-- number of events appended.
seedOrders :: Store.KirokuStore -> Int -> Int -> IO Int
seedOrders store nStreams perStream = do
    for_ [0 .. nStreams - 1] $ \i -> do
        let sname = StreamName ("orders-" <> Text.pack (show i))
            evs =
                [ EventData
                    { eventId = Nothing
                    , eventType = EventType "OrderPlaced"
                    , payload = object ["n" Aeson..= (j :: Int)]
                    , metadata = Nothing
                    , causationId = Nothing
                    , correlationId = Nothing
                    }
                | j <- [0 .. perStream - 1]
                ]
        Right _ <- Store.runStoreIO store $ Store.appendToStream sname AnyVersion evs
        pure ()
    pure (nStreams * perStream)

-- A handler for worker @tag@: idempotently record (event_id, tag, stream_id).
sinkHandler :: Store.KirokuStore -> Int32 -> RecordedEvent -> IO ()
sinkHandler store tag ev =
    void $
        Store.runStoreIO store $
            Store.runTransaction $
                Tx.statement (eventUuid (ev ^. #eventId), tag, streamIdInt (ev ^. #originalStreamId)) insertShardSinkStmt
  where
    eventUuid (EventId u) = u
    streamIdInt (StreamId s) = s

insertShardSinkStmt :: Statement (UUID, Int32, Int64) ()
insertShardSinkStmt =
    preparable
        "INSERT INTO shard_sink (event_id, worker_tag, stream_id) VALUES ($1, $2, $3) ON CONFLICT (event_id) DO NOTHING"
        ( contrazip3
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

shardSinkCount :: Store.KirokuStore -> IO Int
shardSinkCount store =
    either (const 0) id
        <$> Store.runStoreIO store (Store.runTransaction (Tx.statement () countShardSinkStmt))

countShardSinkStmt :: Statement () Int
countShardSinkStmt =
    preparable
        "SELECT count(*) FROM shard_sink"
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

shardDeadLetterDetails :: Store.KirokuStore -> Text -> IO (Int, Maybe Text, Maybe Int)
shardDeadLetterDetails store subscription =
    either (const (0, Nothing, Nothing)) id
        <$> Store.runStoreIO store (Store.runTransaction (Tx.statement subscription shardDeadLetterDetailsStmt))

shardDeadLetterDetailsStmt :: Statement Text (Int, Maybe Text, Maybe Int)
shardDeadLetterDetailsStmt =
    preparable
        "SELECT count(*)::bigint, max(reason_summary), max(attempt_count) \
        \FROM kiroku.dead_letters \
        \WHERE subscription_name = $1 AND consumer_group_member = 0"
        (E.param (E.nonNullable E.text))
        ( D.singleRow $
            (,,)
                <$> (fromIntegral <$> D.column (D.nonNullable D.int8))
                <*> D.column (D.nullable D.text)
                <*> (fmap fromIntegral <$> D.column (D.nullable D.int4))
        )

-- The largest number of distinct workers that processed any single stream. 1
-- means perfectly disjoint ownership (no stream split across workers).
maxWorkersPerStream :: Store.KirokuStore -> IO Int
maxWorkersPerStream store =
    either (const 0) id
        <$> Store.runStoreIO store (Store.runTransaction (Tx.statement () maxWorkersPerStreamStmt))

maxWorkersPerStreamStmt :: Statement () Int
maxWorkersPerStreamStmt =
    preparable
        "SELECT COALESCE(MAX(c), 0) FROM \
        \(SELECT count(DISTINCT worker_tag) AS c FROM shard_sink GROUP BY stream_id) s"
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

-- How many distinct workers processed at least one event (proves the work
-- spread across the pool rather than monopolised by one worker).
distinctWorkers :: Store.KirokuStore -> IO Int
distinctWorkers store =
    either (const 0) id
        <$> Store.runStoreIO store (Store.runTransaction (Tx.statement () distinctWorkersStmt))

distinctWorkersStmt :: Statement () Int
distinctWorkersStmt =
    preparable
        "SELECT count(DISTINCT worker_tag) FROM shard_sink"
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

-- Poll the sink count until it reaches @target@ or the timeout elapses.
waitUntilSinkCount :: Store.KirokuStore -> Int -> Int -> IO Bool
waitUntilSinkCount store target timeoutMicros = go (max 1 (timeoutMicros `div` step))
  where
    step = 100_000
    go :: Int -> IO Bool
    go 0 = (>= target) <$> shardSinkCount store
    go n = do
        c <- shardSinkCount store
        if c >= target
            then pure True
            else threadDelay step >> go (n - 1)

-- Poll until at least @target@ shard rows have a live owner. Tests use this to
-- join a second worker at a precise point in the one-bucket-per-pass ramp-up.
waitUntilOwnedShardCount :: Store.KirokuStore -> SubscriptionName -> Int -> Int -> IO Bool
waitUntilOwnedShardCount store sub target timeoutMicros = go (max 1 (timeoutMicros `div` step))
  where
    step = 50_000
    go 0 = hasTarget
    go n = do
        reached <- hasTarget
        if reached then pure True else threadDelay step >> go (n - 1)
    hasTarget = do
        rows <- either (const []) id <$> Store.runStoreIO store (Store.runTransaction (listShardOwnership sub))
        pure (length [() | (_, Just _, _) <- rows] >= target)

-- Poll the lease table until cooperative ownership has converged: every bucket
-- owned, at least @minWorkers@ distinct owners, and no owner holding more than
-- its fair share. This is the "balanced on the empty category" gate the
-- failover test waits on before seeding, so the drain runs under stable
-- membership.
waitShardsBalanced :: Store.KirokuStore -> SubscriptionName -> Int -> Int -> Int -> IO Bool
waitShardsBalanced store sub n minWorkers timeoutMicros = go (max 1 (timeoutMicros `div` step))
  where
    step = 200_000
    go :: Int -> IO Bool
    go 0 = isBalanced
    go k = do
        ok <- isBalanced
        if ok then pure True else threadDelay step >> go (k - 1)
    isBalanced :: IO Bool
    isBalanced = do
        rows <- either (const []) id <$> Store.runStoreIO store (Store.runTransaction (listShardOwnership sub))
        let owners = [w | (_, Just w, _) <- rows]
            distinct = length (nubOrd owners)
            perOwner = [length g | g <- groupByOwner owners]
            fairShare = (n + max 1 distinct - 1) `div` max 1 distinct
        pure (length rows == n && length owners == n && distinct >= minWorkers && all (<= fairShare) perOwner)
    groupByOwner ws = [filter (== w) ws | w <- nubOrd ws]
    nubOrd = Set.toList . Set.fromList

waitShardsUnowned :: Store.KirokuStore -> SubscriptionName -> Int -> Int -> IO Bool
waitShardsUnowned store sub n timeoutMicros = go (max 1 (timeoutMicros `div` step))
  where
    step = 100_000
    go 0 = isUnowned
    go k = do
        ok <- isUnowned
        if ok then pure True else threadDelay step >> go (k - 1)
    isUnowned = do
        rows <- either (const []) id <$> Store.runStoreIO store (Store.runTransaction (listShardOwnership sub))
        pure (length rows == n && all (\(_, owner, _) -> isNothing owner) rows)

workflowOwnedRowCounts :: (Store :> es) => Text -> Text -> Eff es (Int64, Int64, Int64, Int64, Int64, Int64)
workflowOwnedRowCounts name wid =
    Store.runTransaction (Tx.statement (wid, name) workflowOwnedRowCountsStmt)

workflowOwnedChildCount :: (Store :> es) => Text -> Text -> Eff es Int64
workflowOwnedChildCount name wid =
    Store.runTransaction (Tx.statement (wid, name, wid, name) workflowOwnedChildCountStmt)

workflowWakeAfter :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es (Maybe UTCTime)
workflowWakeAfter (WorkflowName name) (WorkflowId wid) =
    Store.runTransaction (Tx.statement (wid, name) workflowWakeAfterStmt)

insertGcTimerStmt :: Statement (UUID, Text, Text, UTCTime, Value, Text) ()
insertGcTimerStmt =
    preparable
        """
        INSERT INTO keiro.keiro_timers
          (timer_id, process_manager_name, correlation_id, fire_at, payload, status)
        VALUES ($1, $2, $3, $4, $5, $6)
        """
        ( contrazip6
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.jsonb))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

deleteGcStepsStmt :: Statement (Text, Text) ()
deleteGcStepsStmt =
    preparable
        """
        DELETE FROM keiro.keiro_workflow_steps
        WHERE workflow_id = $1 AND workflow_name = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

deleteWorkflowInstanceStmt :: Statement (Text, Text) ()
deleteWorkflowInstanceStmt =
    preparable
        """
        DELETE FROM keiro.keiro_workflows
        WHERE workflow_id = $1 AND workflow_name = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

workflowWakeAfterStmt :: Statement (Text, Text) (Maybe UTCTime)
workflowWakeAfterStmt =
    preparable
        """
        SELECT wake_after
        FROM keiro.keiro_workflows
        WHERE workflow_id = $1 AND workflow_name = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (maybe Nothing id <$> D.rowMaybe (D.column (D.nullable D.timestamptz)))

workflowOwnedRowCountsStmt :: Statement (Text, Text) (Int64, Int64, Int64, Int64, Int64, Int64)
workflowOwnedRowCountsStmt =
    preparable
        """
        SELECT
          (SELECT count(*) FROM keiro.keiro_workflows WHERE workflow_id = $1 AND workflow_name = $2),
          (SELECT count(*) FROM keiro.keiro_workflow_steps WHERE workflow_id = $1 AND workflow_name = $2),
          (SELECT count(*) FROM keiro.keiro_awakeables WHERE owner_workflow_id = $1 AND owner_workflow_name = $2),
          (SELECT count(*) FROM keiro.keiro_workflow_children
            WHERE (parent_id = $1 AND parent_name = $2) OR (child_id = $1 AND child_name = $2)),
          (SELECT count(*) FROM keiro.keiro_timers
            WHERE correlation_id = $1 AND process_manager_name = $2 AND payload->>'kind' = 'keiro.workflow.sleep'),
          (SELECT count(*)
             FROM keiro.keiro_snapshots s
             JOIN streams st ON st.stream_id = s.stream_id
            WHERE st.stream_name = 'wf:' || $2 || '-' || $1)
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        ( D.singleRow $
            (,,,,,)
                <$> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.int8)
        )

workflowOwnedChildCountStmt :: Statement (Text, Text, Text, Text) Int64
workflowOwnedChildCountStmt =
    preparable
        """
        SELECT count(*)
        FROM keiro.keiro_workflow_children
        WHERE (parent_id = $1 AND parent_name = $2)
           OR (child_id = $3 AND child_name = $4)
        """
        ( contrazip4
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.singleRow (D.column (D.nonNullable D.int8)))
