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
module Keiro.Telemetry
  ( -- * Span helpers
    Tracer
  , withProducerSpan
  , withConsumerSpan
  , withCommandSpan

    -- * W3C TraceContext bridge
  , traceContextFromCurrentSpan
  , traceContextFromHeaders
  , injectTraceContext

    -- * Re-exported semantic-convention 'AttributeKey's
    --
    -- $semconv_keys
  , messaging_operation_type
  , messaging_operation_name
  , messaging_destination_partition_id
  , messaging_consumer_group_name
  , messaging_client_id
  , messaging_kafka_offset
  , db_system_name
  , db_namespace
  , db_collection_name
  , db_operation_name

    -- * Bespoke keiro 'AttributeKey's
  , keiro_stream_name
  , keiro_retry_attempt
  , keiro_events_appended
  )
where

import "base" Control.Exception (bracket)
import "bytestring" Data.ByteString qualified as ByteString
import "base" GHC.Stack (HasCallStack)
import "hs-opentelemetry-api" OpenTelemetry.Context (insertSpan, lookupSpan)
import "hs-opentelemetry-api" OpenTelemetry.Attributes.Key (AttributeKey (..))
import "hs-opentelemetry-api" OpenTelemetry.Context.ThreadLocal
  ( attachContext
  , detachContext
  , getContext
  )
import "hs-opentelemetry-api" OpenTelemetry.Trace.Core
  ( Span
  , SpanArguments (..)
  , SpanKind (..)
  , Tracer
  , addAttribute
  , defaultSpanArguments
  , inSpan'
  , wrapSpanContext
  )
import "hs-opentelemetry-semantic-conventions" OpenTelemetry.SemanticConventions
  ( messaging_system
  , messaging_operation_type
  , messaging_operation_name
  , messaging_destination_name
  , messaging_destination_partition_id
  , messaging_consumer_group_name
  , messaging_client_id
  , messaging_message_id
  , messaging_kafka_message_key
  , messaging_kafka_offset
  , db_system_name
  , db_namespace
  , db_collection_name
  , db_operation_name
  )
import "text" Data.Text qualified as Text
import "text" Data.Text.Encoding qualified as TE
import "unliftio-core" Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)

import Keiro.Inbox.Kafka (KafkaInboundRecord)
import Keiro.Integration.Event
  ( IntegrationEvent
  , TraceContext (..)
  , headerTraceParent
  , headerTraceState
  )
import Keiro.Outbox.Kafka (KafkaProducerRecord)
import Keiro.Prelude

import "hs-opentelemetry-propagator-w3c" OpenTelemetry.Propagator.W3CTraceContext
  ( decodeSpanContext
  , encodeSpanContext
  )

-- ---------------------------------------------------------------------------
-- Bespoke keiro AttributeKeys
-- ---------------------------------------------------------------------------

-- $semconv_keys
-- The messaging.* / db.* 'AttributeKey's re-exported here are imported
-- directly from 'OpenTelemetry.SemanticConventions'
-- (@hs-opentelemetry-semantic-conventions@ @1.40.0.0@). They are surfaced
-- from this module so 'Keiro.Telemetry' stays the single telemetry import
-- for the library; their definitions live upstream.
--
-- The @keiro_*@ keys below are bespoke to keiro and have no upstream
-- equivalent, so they are defined locally.

keiro_stream_name :: AttributeKey Text
keiro_stream_name = AttributeKey "keiro.stream.name"

keiro_retry_attempt :: AttributeKey Int64
keiro_retry_attempt = AttributeKey "keiro.retry.attempt"

keiro_events_appended :: AttributeKey Int64
keiro_events_appended = AttributeKey "keiro.events.appended"

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
withProducerSpan
  :: (MonadUnliftIO m, HasCallStack)
  => Maybe Tracer
  -> IntegrationEvent
  -> KafkaProducerRecord
  -> (Maybe Span -> m a)
  -> m a
withProducerSpan Nothing _ _ body = body Nothing
withProducerSpan (Just tracer) event record body =
  inSpan' tracer name args $ \sp -> do
    setProducerAttributes sp event record
    body (Just sp)
  where
    name = "send " <> (event ^. #destination)
    args = defaultSpanArguments {kind = Producer}

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
withConsumerSpan
  :: (MonadUnliftIO m, HasCallStack)
  => Maybe Tracer
  -> Maybe Text
  -- ^ consumer group name (optional)
  -> KafkaInboundRecord
  -> Maybe IntegrationEvent
  -- ^ decoded envelope; 'Nothing' on a decode failure path
  -> (Maybe Span -> m a)
  -> m a
withConsumerSpan Nothing _ _ _ body = body Nothing
withConsumerSpan (Just tracer) consumerGroup record mEvent body =
  withRemoteParent (record ^. #headers) $
    inSpan' tracer name args $ \sp -> do
      setConsumerAttributes sp consumerGroup record mEvent
      body (Just sp)
  where
    name = "process " <> (record ^. #topic)
    args = defaultSpanArguments {kind = Consumer}

{- | Run @body@ with the OpenTelemetry context temporarily augmented by a
parent span extracted from the supplied header list via the W3C
TraceContext propagator.

When no @traceparent@ header is present (or it cannot be parsed) the
body runs unwrapped, so the helper is safe to call unconditionally.

This is the bridge that makes a 'Consumer'-kind span open in this
process a *child* of the 'Producer'-kind span that emitted the message
in the upstream process, joining the two traces by trace id.
-}
withRemoteParent
  :: (MonadUnliftIO m) => [(Text, Text)] -> m a -> m a
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
withCommandSpan
  :: (MonadUnliftIO m, HasCallStack)
  => Maybe Tracer
  -> Text
  -- ^ resolved stream name
  -> Maybe Int64
  -- ^ retry attempt (1-based); 'Nothing' to omit
  -> (Maybe Span -> m a)
  -> m a
withCommandSpan Nothing _ _ body = body Nothing
withCommandSpan (Just tracer) streamName retryAttempt body =
  inSpan' tracer streamName args $ \sp -> do
    addAttribute sp (unkey keiro_stream_name) streamName
    case retryAttempt of
      Nothing -> pure ()
      Just n -> addAttribute sp (unkey keiro_retry_attempt) n
    body (Just sp)
  where
    args = defaultSpanArguments {kind = Internal}

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

setProducerAttributes
  :: (MonadIO m) => Span -> IntegrationEvent -> KafkaProducerRecord -> m ()
setProducerAttributes sp event _record = do
  addAttribute sp (unkey messaging_system) ("kafka" :: Text)
  addAttribute sp (unkey messaging_operation_type) ("publish" :: Text)
  addAttribute sp (unkey messaging_operation_name) ("send" :: Text)
  addAttribute sp (unkey messaging_destination_name) (event ^. #destination)
  addAttribute sp (unkey messaging_message_id) (event ^. #messageId)
  case event ^. #key of
    Nothing -> pure ()
    Just k -> addAttribute sp (unkey messaging_kafka_message_key) k

setConsumerAttributes
  :: (MonadIO m)
  => Span
  -> Maybe Text
  -> KafkaInboundRecord
  -> Maybe IntegrationEvent
  -> m ()
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
