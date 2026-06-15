{- | Thin OpenTelemetry surface for the keiro library.

This module is the single place keiro reaches for @hs-opentelemetry-api@
and @hs-opentelemetry-semantic-conventions@. Callers configure a 'Tracer'
on the application side (typically via @hs-opentelemetry-sdk@'s
'OpenTelemetry.Trace.makeTracer'), then pass it through to keiro's
publisher / consumer / command surfaces.

When no tracer is supplied, every helper degrades to a thin pass-through
(it calls the body and returns its value), so applications that do not
yet wire OpenTelemetry are unaffected.

# Attribute keys

keiro links @hs-opentelemetry-semantic-conventions@ @1.40.0.0@ (generated
from spec @v1.40@) directly. Every messaging.* / db.* typed 'AttributeKey'
the keiro audit cites (@docs/research/opentelemetry-semconv-audit.md@) is
imported from @OpenTelemetry.SemanticConventions@ and re-exported from this
module, so 'Keiro.Telemetry' remains the one-stop telemetry surface for the
library while every convention name is anchored to the spec-generated module
rather than a hand-typed string.

Only the @keiro.*@ keys ('keiro_stream_name', 'keiro_retry_attempt',
'keiro_events_appended') are defined locally: they are bespoke to keiro and
have no upstream equivalent.
-}
module Keiro.Telemetry (
    -- * Span helpers
    Tracer,
    withProducerSpan,
    withConsumerSpan,
    withCommandSpan,
    withWorkflowSpan,

    -- * W3C TraceContext bridge
    traceContextFromCurrentSpan,
    traceContextFromHeaders,
    injectTraceContext,

    -- * Re-exported semantic-convention 'AttributeKey's

    --
    -- $semconv_keys
    messaging_operation_type,
    messaging_operation_name,
    messaging_destination_partition_id,
    messaging_consumer_group_name,
    messaging_client_id,
    messaging_kafka_offset,
    db_system_name,
    db_namespace,
    db_collection_name,
    db_operation_name,

    -- * Bespoke keiro 'AttributeKey's
    keiro_stream_name,
    keiro_retry_attempt,
    keiro_events_appended,
    keiro_workflow_name,
    keiro_workflow_id,
    keiro_workflow_step,

    -- * Metrics surface

    --
    -- $metrics
    Meter,
    InstrumentationLibrary (..),
    keiroInstrumentationLibrary,
    keiroOutboxBacklogName,
    keiroOutboxPublishedName,
    keiroOutboxRetriedName,
    keiroOutboxDeadletteredName,
    keiroOutboxReclaimedName,
    keiroInboxProcessedName,
    keiroInboxDuplicatesName,
    keiroInboxFailedName,
    keiroInboxPoisonedName,
    keiroInboxBacklogName,
    keiroTimerBacklogName,
    keiroTimerFireLagName,
    keiroTimerAttemptsName,
    keiroTimerStuckName,
    keiroTimerRequeuedName,
    keiroProjectionLagName,
    keiroProjectionWaitTimeoutsName,
    keiroCommandConflictsName,
    keiroCommandRetriesName,
    keiroCommandDuplicatesName,
    keiroSnapshotWriteFailuresName,
    keiroDispatchFailedName,
    keiroDispatchDuplicatesName,
    keiroDispatchPoisonName,
    keiroWorkflowStepsExecutedName,
    keiroWorkflowStepsReplayedName,
    keiroWorkflowResumedName,
    keiroWorkflowJournalLengthName,
    keiroWorkflowAwakeablesPendingName,
    keiroWorkflowActiveName,
    KeiroMetrics (..),
    newKeiroMetrics,
    recordOutboxBacklog,
    recordOutboxPublished,
    recordOutboxRetried,
    recordOutboxDeadlettered,
    recordOutboxReclaimed,
    recordInboxProcessed,
    recordInboxDuplicates,
    recordInboxFailed,
    recordInboxPoisoned,
    recordInboxBacklog,
    recordTimerBacklog,
    recordTimerFireLag,
    recordTimerAttempts,
    recordTimerStuck,
    recordTimerRequeued,
    recordProjectionLag,
    recordProjectionWaitTimeouts,
    recordCommandConflicts,
    recordCommandRetries,
    recordCommandDuplicates,
    recordSnapshotWriteFailures,
    recordDispatchFailed,
    recordDispatchDuplicate,
    recordDispatchPoison,
    recordWorkflowStepExecuted,
    recordWorkflowStepReplayed,
    recordWorkflowResumed,
    recordWorkflowActive,
    recordWorkflowJournalLength,
    recordWorkflowAwakeablesPending,
)
where

import "base" Control.Exception (bracket)
import "base" GHC.Stack (HasCallStack)
import "bytestring" Data.ByteString qualified as ByteString
import "hs-opentelemetry-api" OpenTelemetry.Attributes (emptyAttributes)
import "hs-opentelemetry-api" OpenTelemetry.Attributes.Key (AttributeKey (..))
import "hs-opentelemetry-api" OpenTelemetry.Context (insertSpan, lookupSpan)
import "hs-opentelemetry-api" OpenTelemetry.Context.ThreadLocal (
    attachContext,
    detachContext,
    getContext,
 )
import "hs-opentelemetry-api" OpenTelemetry.Metric.Core (
    Counter,
    Gauge,
    Histogram,
    Meter,
    counterAdd,
    defaultAdvisoryParameters,
    gaugeRecord,
    histogramRecord,
    meterCreateCounterInt64,
    meterCreateGaugeInt64,
    meterCreateHistogram,
 )
import "hs-opentelemetry-api" OpenTelemetry.Trace.Core (
    InstrumentationLibrary (..),
    Span,
    SpanArguments (..),
    SpanKind (..),
    Tracer,
    addAttribute,
    defaultSpanArguments,
    inSpan',
    wrapSpanContext,
 )
import "hs-opentelemetry-semantic-conventions" OpenTelemetry.SemanticConventions (
    db_collection_name,
    db_namespace,
    db_operation_name,
    db_system_name,
    messaging_client_id,
    messaging_consumer_group_name,
    messaging_destination_name,
    messaging_destination_partition_id,
    messaging_kafka_message_key,
    messaging_kafka_offset,
    messaging_message_id,
    messaging_operation_name,
    messaging_operation_type,
    messaging_system,
 )
import "text" Data.Text qualified as Text
import "text" Data.Text.Encoding qualified as TE
import "unliftio-core" Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)

import Keiro.Inbox.Kafka (KafkaInboundRecord)
import Keiro.Integration.Event (
    IntegrationEvent,
    TraceContext (..),
    headerTraceParent,
    headerTraceState,
 )
import Keiro.Outbox.Kafka (KafkaProducerRecord)
import Keiro.Prelude
import Keiro.Workflow.Types (StepName (..), WorkflowId (..), WorkflowName (..))

import "hs-opentelemetry-propagator-w3c" OpenTelemetry.Propagator.W3CTraceContext (
    decodeSpanContext,
    encodeSpanContext,
 )

-- ---------------------------------------------------------------------------
-- Bespoke keiro AttributeKeys
-- ---------------------------------------------------------------------------

{- $semconv_keys
The messaging.* / db.* 'AttributeKey's re-exported here are imported
directly from 'OpenTelemetry.SemanticConventions'
(@hs-opentelemetry-semantic-conventions@ @1.40.0.0@). They are surfaced
from this module so 'Keiro.Telemetry' stays the single telemetry import
for the library; their definitions live upstream.

The @keiro_*@ keys below are bespoke to keiro and have no upstream
equivalent, so they are defined locally.
-}

keiro_stream_name :: AttributeKey Text
keiro_stream_name = AttributeKey "keiro.stream.name"

keiro_retry_attempt :: AttributeKey Int64
keiro_retry_attempt = AttributeKey "keiro.retry.attempt"

keiro_events_appended :: AttributeKey Int64
keiro_events_appended = AttributeKey "keiro.events.appended"

keiro_workflow_name :: AttributeKey Text
keiro_workflow_name = AttributeKey "keiro.workflow.name"

keiro_workflow_id :: AttributeKey Text
keiro_workflow_id = AttributeKey "keiro.workflow.id"

keiro_workflow_step :: AttributeKey Text
keiro_workflow_step = AttributeKey "keiro.workflow.step"

-- ---------------------------------------------------------------------------
-- Span helpers
-- ---------------------------------------------------------------------------

{- | Run @body@ inside a @Producer@-kind span named @"send " <> destination@
populated with the messaging attributes prescribed by
@docs/research/opentelemetry-semconv-audit.md@ for the outbox publish
site.

When the supplied 'Tracer' is 'Nothing', the body runs unwrapped and the
helper is a no-op pass-through. This keeps the cost of the helper at
"one 'Maybe' branch" for applications that have not yet configured a
tracer.

The body receives the producer 'Span' so it can record a publish failure
via 'recordPublishError'.
-}
withProducerSpan ::
    (MonadUnliftIO m, HasCallStack) =>
    Maybe Tracer ->
    IntegrationEvent ->
    KafkaProducerRecord ->
    (Maybe Span -> m a) ->
    m a
withProducerSpan Nothing _ _ body = body Nothing
withProducerSpan (Just tracer) event record body =
    inSpan' tracer name args $ \sp -> do
        setProducerAttributes sp event record
        body (Just sp)
  where
    name = "send " <> (event ^. #destination)
    args = defaultSpanArguments{kind = Producer}

{- | Run @body@ inside a @Consumer@-kind span named @"process " <> topic@.

Like 'withProducerSpan', the helper is a pass-through under a 'Nothing'
tracer. The 'KafkaInboundRecord' is required so the helper can populate
@messaging.kafka.offset@ and @messaging.destination.partition.id@
without the caller threading them separately.

The optional 'Text' is a consumer group name, recorded as
@messaging.consumer.group.name@ when present. The 'IntegrationEvent' is
attached when present (decode succeeded), so @messaging.message.id@
is set; otherwise the helper records only the headers known from the
broker record.
-}
withConsumerSpan ::
    (MonadUnliftIO m, HasCallStack) =>
    Maybe Tracer ->
    -- | consumer group name (optional)
    Maybe Text ->
    KafkaInboundRecord ->
    -- | decoded envelope; 'Nothing' on a decode failure path
    Maybe IntegrationEvent ->
    (Maybe Span -> m a) ->
    m a
withConsumerSpan Nothing _ _ _ body = body Nothing
withConsumerSpan (Just tracer) consumerGroup record mEvent body =
    withRemoteParent (record ^. #headers) $
        inSpan' tracer name args $ \sp -> do
            setConsumerAttributes sp consumerGroup record mEvent
            body (Just sp)
  where
    name = "process " <> (record ^. #topic)
    args = defaultSpanArguments{kind = Consumer}

{- | Run @body@ with the OpenTelemetry context temporarily augmented by a
parent span extracted from the supplied header list via the W3C
TraceContext propagator.

When no @traceparent@ header is present (or it cannot be parsed) the
body runs unwrapped, so the helper is safe to call unconditionally.

This is the bridge that makes a 'Consumer'-kind span open in this
process a *child* of the 'Producer'-kind span that emitted the message
in the upstream process, joining the two traces by trace id.
-}
withRemoteParent ::
    (MonadUnliftIO m) => [(Text, Text)] -> m a -> m a
withRemoteParent hs body =
    case parentSpanContext hs of
        Nothing -> body
        Just spanCtx -> withRunInIO $ \runInIO -> do
            ctx <- getContext
            let newCtx = insertSpan (wrapSpanContext spanCtx) ctx
            bracket
                (attachContext newCtx)
                detachContext
                (const (runInIO body))
  where
    parentSpanContext hsList =
        let tp = fmap TE.encodeUtf8 (Prelude.lookup headerTraceParent hsList)
            ts = fmap TE.encodeUtf8 (Prelude.lookup headerTraceState hsList)
         in decodeSpanContext tp ts

{- | Open an @Internal@ span around a command run, named after the resolved
stream identifier. Attributes capture the stream name and (when the
caller supplies it) the retry attempt number. The number of events
appended is attached after a successful append by the caller via
'addAttribute span keiro_events_appended n'.
-}
withCommandSpan ::
    (MonadUnliftIO m, HasCallStack) =>
    Maybe Tracer ->
    -- | resolved stream name
    Text ->
    -- | retry attempt (1-based); 'Nothing' to omit
    Maybe Int64 ->
    (Maybe Span -> m a) ->
    m a
withCommandSpan Nothing _ _ body = body Nothing
withCommandSpan (Just tracer) streamName retryAttempt body =
    inSpan' tracer streamName args $ \sp -> do
        addAttribute sp (unkey keiro_stream_name) streamName
        case retryAttempt of
            Nothing -> pure ()
            Just n -> addAttribute sp (unkey keiro_retry_attempt) n
        body (Just sp)
  where
    args = defaultSpanArguments{kind = Internal}

{- | Open an @Internal@ span around a workflow run (or a single step/resume when
a 'StepName' is supplied), named @"workflow " <> name@. Attributes carry the
bespoke @keiro.workflow.name@, @keiro.workflow.id@, and — when present —
@keiro.workflow.step@ keys. Like 'withCommandSpan', a 'Nothing' tracer makes the
helper a pass-through, so it is safe to call unconditionally.
-}
withWorkflowSpan ::
    (MonadUnliftIO m, HasCallStack) =>
    Maybe Tracer ->
    WorkflowName ->
    WorkflowId ->
    Maybe StepName ->
    (Maybe Span -> m a) ->
    m a
withWorkflowSpan Nothing _ _ _ body = body Nothing
withWorkflowSpan (Just tracer) name wid mStep body =
    inSpan' tracer spanName args $ \sp -> do
        addAttribute sp (unkey keiro_workflow_name) (unWorkflowName name)
        addAttribute sp (unkey keiro_workflow_id) (unWorkflowId wid)
        case mStep of
            Nothing -> pure ()
            Just s -> addAttribute sp (unkey keiro_workflow_step) (unStepName s)
        body (Just sp)
  where
    spanName = "workflow " <> unWorkflowName name
    args = defaultSpanArguments{kind = Internal}

-- ---------------------------------------------------------------------------
-- W3C TraceContext bridge
-- ---------------------------------------------------------------------------

{- | Read the current thread-local span context and format it as a
'TraceContext'. Returns 'Nothing' when no span is active on the current
thread.

The application is expected to have already configured the W3C
propagator on its 'TracerProvider' (so the propagator is responsible for
on-the-wire framing); this helper is the keiro-side bridge between the
in-memory span and the keiro 'TraceContext' record stored on
'IntegrationEvent' envelopes and outbox rows.
-}
traceContextFromCurrentSpan :: (MonadIO m) => m (Maybe TraceContext)
traceContextFromCurrentSpan = do
    ctx <- getContext
    case lookupSpan ctx of
        Nothing -> pure Nothing
        Just sp -> do
            (traceparentBytes, tracestateBytes) <- liftIO (encodeSpanContext sp)
            let traceparent = TE.decodeUtf8 traceparentBytes
                tracestate
                    | ByteString.null tracestateBytes = Nothing
                    | otherwise = Just (TE.decodeUtf8 tracestateBytes)
            pure (Just (TraceContext traceparent tracestate))

{- | Lift a 'TraceContext' out of a flat @[(Text, Text)]@ header list. This
is the mirror image of 'integrationHeaders': it does not validate the
@traceparent@ format (the W3C propagator's parser does that at consume
time); it merely converts the on-the-wire pair of headers to the keiro
envelope record.
-}
traceContextFromHeaders :: [(Text, Text)] -> Maybe TraceContext
traceContextFromHeaders hs = case Prelude.lookup headerTraceParent hs of
    Nothing -> Nothing
    Just tp -> Just (TraceContext tp (Prelude.lookup headerTraceState hs))

{- | Append the W3C @traceparent@ / @tracestate@ headers for the current
thread-local span to the supplied header list. When no span is active
on the current thread, the input list is returned unchanged.

Used by adapters that build a flat header list from their own envelope
(e.g. the outbox publisher) so the headers carry the active span
context even if the caller did not capture a 'TraceContext' onto the
event explicitly.
-}
injectTraceContext :: (MonadIO m) => [(Text, Text)] -> m [(Text, Text)]
injectTraceContext hs = do
    mctx <- traceContextFromCurrentSpan
    pure $ case mctx of
        Nothing -> hs
        Just tc ->
            hs
                ++ [(headerTraceParent, tc ^. #traceparent)]
                ++ maybe [] (\ts -> [(headerTraceState, ts)]) (tc ^. #tracestate)

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

setProducerAttributes ::
    (MonadIO m) => Span -> IntegrationEvent -> KafkaProducerRecord -> m ()
setProducerAttributes sp event _record = do
    addAttribute sp (unkey messaging_system) ("kafka" :: Text)
    addAttribute sp (unkey messaging_operation_type) ("publish" :: Text)
    addAttribute sp (unkey messaging_operation_name) ("send" :: Text)
    addAttribute sp (unkey messaging_destination_name) (event ^. #destination)
    addAttribute sp (unkey messaging_message_id) (event ^. #messageId)
    case event ^. #key of
        Nothing -> pure ()
        Just k -> addAttribute sp (unkey messaging_kafka_message_key) k

setConsumerAttributes ::
    (MonadIO m) =>
    Span ->
    Maybe Text ->
    KafkaInboundRecord ->
    Maybe IntegrationEvent ->
    m ()
setConsumerAttributes sp consumerGroup record mEvent = do
    addAttribute sp (unkey messaging_system) ("kafka" :: Text)
    addAttribute sp (unkey messaging_operation_type) ("process" :: Text)
    addAttribute sp (unkey messaging_operation_name) ("process" :: Text)
    addAttribute sp (unkey messaging_destination_name) (record ^. #topic)
    addAttribute sp (unkey messaging_destination_partition_id) (showText (record ^. #partition))
    addAttribute sp (unkey messaging_kafka_offset) (record ^. #offset)
    case record ^. #key of
        Nothing -> pure ()
        Just k -> addAttribute sp (unkey messaging_kafka_message_key) k
    case consumerGroup of
        Nothing -> pure ()
        Just g -> addAttribute sp (unkey messaging_consumer_group_name) g
    case mEvent of
        Nothing -> pure ()
        Just event -> addAttribute sp (unkey messaging_message_id) (event ^. #messageId)

showText :: (Show a) => a -> Text
showText = Text.pack . show

-- ---------------------------------------------------------------------------
-- Metrics surface
-- ---------------------------------------------------------------------------

{- $metrics
Alongside the span helpers above, 'Keiro.Telemetry' exposes the library's
metrics surface: a 'KeiroMetrics' record holding every instrument keiro
records (built once from a 'Meter' by 'newKeiroMetrics'), and one
@record*@ helper per instrument that takes a @'Maybe' 'KeiroMetrics'@ and
no-ops on 'Nothing'. This mirrors the @'Maybe' 'Tracer'@ opt-in the span
helpers use: an application that never configures a 'MeterProvider' pays
only one 'Maybe' branch per recording site. The per-instrument name, unit,
kind, and description are catalogued in
@docs/research/opentelemetry-semconv-audit.md@.
-}

{- | The instrumentation scope keiro tags all its metric instruments with.
Mirrors the @"keiro"@ scope name the span helpers use on the application's
'Tracer'.
-}
keiroInstrumentationLibrary :: InstrumentationLibrary
keiroInstrumentationLibrary =
    InstrumentationLibrary
        { libraryName = "keiro"
        , libraryVersion = ""
        , librarySchemaUrl = ""
        , libraryAttributes = emptyAttributes
        }

keiroOutboxBacklogName :: Text
keiroOutboxBacklogName = "keiro.outbox.backlog"
keiroOutboxPublishedName :: Text
keiroOutboxPublishedName = "keiro.outbox.published"
keiroOutboxRetriedName :: Text
keiroOutboxRetriedName = "keiro.outbox.retried"
keiroOutboxDeadletteredName :: Text
keiroOutboxDeadletteredName = "keiro.outbox.deadlettered"
keiroOutboxReclaimedName :: Text
keiroOutboxReclaimedName = "keiro.outbox.reclaimed"
keiroInboxProcessedName :: Text
keiroInboxProcessedName = "keiro.inbox.processed"
keiroInboxDuplicatesName :: Text
keiroInboxDuplicatesName = "keiro.inbox.duplicates"
keiroInboxFailedName :: Text
keiroInboxFailedName = "keiro.inbox.failed"
keiroInboxPoisonedName :: Text
keiroInboxPoisonedName = "keiro.inbox.poisoned"
keiroInboxBacklogName :: Text
keiroInboxBacklogName = "keiro.inbox.backlog"
keiroTimerBacklogName :: Text
keiroTimerBacklogName = "keiro.timer.backlog"
keiroTimerFireLagName :: Text
keiroTimerFireLagName = "keiro.timer.fire.lag"
keiroTimerAttemptsName :: Text
keiroTimerAttemptsName = "keiro.timer.attempts"
keiroTimerStuckName :: Text
keiroTimerStuckName = "keiro.timer.stuck"
keiroTimerRequeuedName :: Text
keiroTimerRequeuedName = "keiro.timer.requeued"
keiroProjectionLagName :: Text
keiroProjectionLagName = "keiro.projection.lag"
keiroProjectionWaitTimeoutsName :: Text
keiroProjectionWaitTimeoutsName = "keiro.projection.wait.timeouts"
keiroCommandConflictsName :: Text
keiroCommandConflictsName = "keiro.command.conflicts"
keiroCommandRetriesName :: Text
keiroCommandRetriesName = "keiro.command.retries"
keiroCommandDuplicatesName :: Text
keiroCommandDuplicatesName = "keiro.command.duplicates"
keiroSnapshotWriteFailuresName :: Text
keiroSnapshotWriteFailuresName = "keiro.snapshot.write.failures"
keiroDispatchFailedName :: Text
keiroDispatchFailedName = "keiro.dispatch.failed"
keiroDispatchDuplicatesName :: Text
keiroDispatchDuplicatesName = "keiro.dispatch.duplicates"
keiroDispatchPoisonName :: Text
keiroDispatchPoisonName = "keiro.dispatch.poison"
keiroWorkflowStepsExecutedName :: Text
keiroWorkflowStepsExecutedName = "keiro.workflow.steps.executed"
keiroWorkflowStepsReplayedName :: Text
keiroWorkflowStepsReplayedName = "keiro.workflow.steps.replayed"
keiroWorkflowResumedName :: Text
keiroWorkflowResumedName = "keiro.workflow.resumed"
keiroWorkflowJournalLengthName :: Text
keiroWorkflowJournalLengthName = "keiro.workflow.journal.length"
keiroWorkflowAwakeablesPendingName :: Text
keiroWorkflowAwakeablesPendingName = "keiro.workflow.awakeables.pending"
keiroWorkflowActiveName :: Text
keiroWorkflowActiveName = "keiro.workflow.active"

{- | All metric instruments the keiro library records, built once from a
'Meter' by 'newKeiroMetrics'. Workers accept a @'Maybe' 'KeiroMetrics'@ and
treat 'Nothing' as "record nothing"; the per-instrument recording helpers in
this module take @'Maybe' 'KeiroMetrics'@ so call sites stay one-liners.

Instrument kinds follow the keiro metrics policy: backlog and lag are
synchronous gauges recorded by each worker per poll pass; tallies are
monotonic counters; distributions are histograms. See
@docs/research/opentelemetry-semconv-audit.md@ for the per-instrument
name / unit / kind / description catalogue.
-}
data KeiroMetrics = KeiroMetrics
    { outboxBacklog :: Gauge Int64
    , outboxPublished :: Counter Int64
    , outboxRetried :: Counter Int64
    , outboxDeadlettered :: Counter Int64
    , outboxReclaimed :: Counter Int64
    , inboxProcessed :: Counter Int64
    , inboxDuplicates :: Counter Int64
    , inboxFailed :: Counter Int64
    , inboxPoisoned :: Counter Int64
    , inboxBacklog :: Gauge Int64
    , timerBacklog :: Gauge Int64
    , timerFireLag :: Histogram
    , timerAttempts :: Histogram
    , timerStuck :: Gauge Int64
    , timerRequeued :: Counter Int64
    , projectionLag :: Gauge Int64
    , projectionWaitTimeouts :: Counter Int64
    , commandConflicts :: Counter Int64
    , commandRetries :: Counter Int64
    , commandDuplicates :: Counter Int64
    , snapshotWriteFailures :: Counter Int64
    , dispatchFailed :: Counter Int64
    , dispatchDuplicates :: Counter Int64
    , dispatchPoison :: Counter Int64
    , workflowStepsExecuted :: Counter Int64
    , workflowStepsReplayed :: Counter Int64
    , workflowResumed :: Counter Int64
    , workflowActive :: Gauge Int64
    , workflowJournalLength :: Histogram
    , workflowAwakeablesPending :: Gauge Int64
    }

{- | Construct every keiro metric instrument from a 'Meter'. Call this once at
application start after building an SDK 'OpenTelemetry.Metric.Core.MeterProvider'
and obtaining a 'Meter' (e.g. @getMeter mp keiroInstrumentationLibrary@), then
thread the resulting 'KeiroMetrics' into workers as @'Just' metrics@. Under a
no-op meter every instrument is itself a no-op, so this is safe to call
unconditionally.
-}
newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics
newKeiroMetrics meter = liftIO $ do
    outboxBacklog' <- gaugeI64 keiroOutboxBacklogName "{event}" "Outbox rows awaiting publish."
    outboxPublished' <- counterI64 keiroOutboxPublishedName "{event}" "Outbox events successfully published."
    outboxRetried' <- counterI64 keiroOutboxRetriedName "{event}" "Outbox publish attempts that failed and will retry."
    outboxDeadlettered' <- counterI64 keiroOutboxDeadletteredName "{event}" "Outbox events parked after exhausting retries."
    outboxReclaimed' <- counterI64 keiroOutboxReclaimedName "{event}" "Outbox rows reclaimed from a crashed or stalled publisher."
    inboxProcessed' <- counterI64 keiroInboxProcessedName "{message}" "Inbox messages processed successfully."
    inboxDuplicates' <- counterI64 keiroInboxDuplicatesName "{message}" "Inbox messages skipped as duplicates."
    inboxFailed' <- counterI64 keiroInboxFailedName "{message}" "Inbox messages whose handler failed."
    inboxPoisoned' <- counterI64 keiroInboxPoisonedName "{message}" "Inbox messages dead-lettered after exhausting handler attempts."
    inboxBacklog' <- gaugeI64 keiroInboxBacklogName "{message}" "Inbox messages awaiting processing."
    timerBacklog' <- gaugeI64 keiroTimerBacklogName "{timer}" "Due timers awaiting firing."
    timerFireLag' <- histogram keiroTimerFireLagName "ms" "Delay between a timer's scheduled time and when it fired."
    timerAttempts' <- histogram keiroTimerAttemptsName "{attempt}" "Number of attempts a timer took to fire."
    timerStuck' <- gaugeI64 keiroTimerStuckName "{timer}" "Timers stuck in the Firing state past threshold."
    timerRequeued' <- counterI64 keiroTimerRequeuedName "{timer}" "Timers moved from firing back to scheduled after a stale claim."
    projectionLag' <- gaugeI64 keiroProjectionLagName "{event}" "Events between the log head and a projection's checkpoint."
    projectionWaitTimeouts' <- counterI64 keiroProjectionWaitTimeoutsName "{timeout}" "Position-wait calls that timed out before the projection caught up."
    commandConflicts' <- counterI64 keiroCommandConflictsName "{conflict}" "Optimistic-concurrency conflicts observed by command runners."
    commandRetries' <- counterI64 keiroCommandRetriesName "{retry}" "Command retry attempts started after an optimistic-concurrency conflict."
    commandDuplicates' <- counterI64 keiroCommandDuplicatesName "{event}" "Command appends rejected as duplicate deterministic event ids."
    snapshotWriteFailures' <- counterI64 keiroSnapshotWriteFailuresName "{failure}" "Post-commit snapshot writes that failed and were swallowed."
    dispatchFailed' <- counterI64 keiroDispatchFailedName "{command}" "Process-manager/router dispatch commands that failed."
    dispatchDuplicates' <- counterI64 keiroDispatchDuplicatesName "{command}" "Process-manager/router dispatch commands skipped as duplicate deterministic event ids."
    dispatchPoison' <- counterI64 keiroDispatchPoisonName "{message}" "Process-manager/router worker messages classified as poison."
    workflowStepsExecuted' <- counterI64 keiroWorkflowStepsExecutedName "{step}" "Workflow steps that ran their action (a journal miss)."
    workflowStepsReplayed' <- counterI64 keiroWorkflowStepsReplayedName "{step}" "Workflow steps short-circuited to a recorded result (a journal hit)."
    workflowResumed' <- counterI64 keiroWorkflowResumedName "{workflow}" "Workflow re-invocations performed by the resume worker."
    workflowActive' <- gaugeI64 keiroWorkflowActiveName "{workflow}" "Workflow runs currently in progress in this process."
    workflowJournalLength' <- histogram keiroWorkflowJournalLengthName "{event}" "Journal event count of a workflow at completion."
    workflowAwakeablesPending' <- gaugeI64 keiroWorkflowAwakeablesPendingName "{awakeable}" "Awakeables awaiting an external signal."
    pure
        KeiroMetrics
            { outboxBacklog = outboxBacklog'
            , outboxPublished = outboxPublished'
            , outboxRetried = outboxRetried'
            , outboxDeadlettered = outboxDeadlettered'
            , outboxReclaimed = outboxReclaimed'
            , inboxProcessed = inboxProcessed'
            , inboxDuplicates = inboxDuplicates'
            , inboxFailed = inboxFailed'
            , inboxPoisoned = inboxPoisoned'
            , inboxBacklog = inboxBacklog'
            , timerBacklog = timerBacklog'
            , timerFireLag = timerFireLag'
            , timerAttempts = timerAttempts'
            , timerStuck = timerStuck'
            , timerRequeued = timerRequeued'
            , projectionLag = projectionLag'
            , projectionWaitTimeouts = projectionWaitTimeouts'
            , commandConflicts = commandConflicts'
            , commandRetries = commandRetries'
            , commandDuplicates = commandDuplicates'
            , snapshotWriteFailures = snapshotWriteFailures'
            , dispatchFailed = dispatchFailed'
            , dispatchDuplicates = dispatchDuplicates'
            , dispatchPoison = dispatchPoison'
            , workflowStepsExecuted = workflowStepsExecuted'
            , workflowStepsReplayed = workflowStepsReplayed'
            , workflowResumed = workflowResumed'
            , workflowActive = workflowActive'
            , workflowJournalLength = workflowJournalLength'
            , workflowAwakeablesPending = workflowAwakeablesPending'
            }
  where
    counterI64 :: Text -> Text -> Text -> IO (Counter Int64)
    counterI64 name unit desc =
        meterCreateCounterInt64 meter name (Just unit) (Just desc) defaultAdvisoryParameters
    gaugeI64 :: Text -> Text -> Text -> IO (Gauge Int64)
    gaugeI64 name unit desc =
        meterCreateGaugeInt64 meter name (Just unit) (Just desc) defaultAdvisoryParameters
    histogram :: Text -> Text -> Text -> IO Histogram
    histogram name unit desc =
        meterCreateHistogram meter name (Just unit) (Just desc) defaultAdvisoryParameters

-- Internal: record an Int64 on the counter selected by @sel@, or do nothing.
recordCounter ::
    (MonadIO m) => (KeiroMetrics -> Counter Int64) -> Maybe KeiroMetrics -> Int64 -> m ()
recordCounter _ Nothing _ = pure ()
recordCounter sel (Just ms) n = liftIO (counterAdd (sel ms) n emptyAttributes)

-- Internal: record an Int64 on the gauge selected by @sel@, or do nothing.
recordGaugeI64 ::
    (MonadIO m) => (KeiroMetrics -> Gauge Int64) -> Maybe KeiroMetrics -> Int64 -> m ()
recordGaugeI64 _ Nothing _ = pure ()
recordGaugeI64 sel (Just ms) n = liftIO (gaugeRecord (sel ms) n emptyAttributes)

-- Internal: record a Double on the histogram selected by @sel@, or do nothing.
recordHistogram ::
    (MonadIO m) => (KeiroMetrics -> Histogram) -> Maybe KeiroMetrics -> Double -> m ()
recordHistogram _ Nothing _ = pure ()
recordHistogram sel (Just ms) v = liftIO (histogramRecord (sel ms) v emptyAttributes)

recordOutboxBacklog :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxBacklog = recordGaugeI64 outboxBacklog
recordOutboxPublished :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxPublished = recordCounter outboxPublished
recordOutboxRetried :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxRetried = recordCounter outboxRetried
recordOutboxDeadlettered :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxDeadlettered = recordCounter outboxDeadlettered
recordOutboxReclaimed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordOutboxReclaimed = recordCounter outboxReclaimed
recordInboxProcessed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxProcessed = recordCounter inboxProcessed
recordInboxDuplicates :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxDuplicates = recordCounter inboxDuplicates
recordInboxFailed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxFailed = recordCounter inboxFailed
recordInboxPoisoned :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxPoisoned = recordCounter inboxPoisoned
recordInboxBacklog :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordInboxBacklog = recordGaugeI64 inboxBacklog
recordTimerBacklog :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordTimerBacklog = recordGaugeI64 timerBacklog
recordTimerFireLag :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()
recordTimerFireLag = recordHistogram timerFireLag
recordTimerAttempts :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()
recordTimerAttempts = recordHistogram timerAttempts
recordTimerStuck :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordTimerStuck = recordGaugeI64 timerStuck
recordTimerRequeued :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordTimerRequeued = recordCounter timerRequeued
recordProjectionLag :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordProjectionLag = recordGaugeI64 projectionLag
recordProjectionWaitTimeouts :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordProjectionWaitTimeouts = recordCounter projectionWaitTimeouts
recordCommandConflicts :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordCommandConflicts = recordCounter commandConflicts
recordCommandRetries :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordCommandRetries = recordCounter commandRetries
recordCommandDuplicates :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordCommandDuplicates = recordCounter commandDuplicates
recordSnapshotWriteFailures :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordSnapshotWriteFailures = recordCounter snapshotWriteFailures
recordDispatchFailed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordDispatchFailed = recordCounter dispatchFailed
recordDispatchDuplicate :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordDispatchDuplicate = recordCounter dispatchDuplicates
recordDispatchPoison :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordDispatchPoison = recordCounter dispatchPoison
recordWorkflowStepExecuted :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowStepExecuted = recordCounter workflowStepsExecuted
recordWorkflowStepReplayed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowStepReplayed = recordCounter workflowStepsReplayed
recordWorkflowResumed :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowResumed = recordCounter workflowResumed
recordWorkflowActive :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowActive = recordGaugeI64 workflowActive
recordWorkflowJournalLength :: (MonadIO m) => Maybe KeiroMetrics -> Double -> m ()
recordWorkflowJournalLength = recordHistogram workflowJournalLength
recordWorkflowAwakeablesPending :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()
recordWorkflowAwakeablesPending = recordGaugeI64 workflowAwakeablesPending
