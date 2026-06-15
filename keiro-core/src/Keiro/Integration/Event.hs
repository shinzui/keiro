{- | Public integration-event envelope.

A keiro integration event is a public message that crosses from one bounded
context to another over Kafka (or another transport). It is distinct from a
private 'Kiroku.Store.Types.RecordedEvent': domain events are internal facts
of one event stream, while integration events are stable public contracts
versioned independently from the private model.

This module owns the wire shape, identity rules, and pure encode/decode
helpers. Storage of the envelope ('Keiro.Outbox', 'Keiro.Inbox') and
Kafka-specific producer/consumer wrappers consume this contract; they do
not redefine it.
-}
module Keiro.Integration.Event (
    -- * Envelope
    IntegrationEvent (..),
    IntegrationContentType (..),
    SchemaReference (..),
    TraceContext (..),
    IntegrationEventError (..),

    -- * JSON convenience helpers
    encodeJsonIntegrationEvent,
    decodeJsonIntegrationEvent,

    -- * Wire mapping
    integrationPayload,
    integrationHeaders,
    headerMessageId,
    headerSource,
    headerDestination,
    headerEventType,
    headerSchemaVersion,
    headerContentType,
    headerSchemaRegistry,
    headerSchemaSubject,
    headerSchemaVersionRef,
    headerSchemaId,
    headerSchemaFingerprint,
    headerSourceEventId,
    headerSourceGlobalPosition,
    headerCausationId,
    headerCorrelationId,
    headerTraceParent,
    headerTraceState,
    headerOccurredAt,
    headerAttributes,
    contentTypeText,
    parseContentType,
)
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.UUID qualified as UUID
import Keiro.Prelude
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))

{- | The canonical integration-event envelope.

The envelope is byte-oriented so future schema-registry integration (Avro,
Protobuf, JSON Schema) does not require a table or API migration. JSON
remains the v1 encoding, but the contract itself does not commit to it.

Identity rules:

* 'messageId' is an application-level id (UUIDv7 or equivalent
  time-ordered UUID) minted by the producer subscription when it writes
  the outbox row. It is stable across publish retries because it lives in
  the row; Kafka topic/partition/offset are delivery metadata only and
  are /not/ the canonical dedupe key.
* 'sourceEventId' and 'sourceGlobalPosition' identify the private event
  that produced this integration event. A single source event can fan out
  to multiple integration events with distinct 'messageId's; consumers
  can opt into source-position deduplication when they want to suppress
  reissued public events sharing an upstream cause.

Routing:

* 'source' is the producing bounded context (e.g. @\"ordering\"@).
* 'destination' is the Kafka topic, conventionally including a contract
  version (@\"billing.orders.v1\"@).
* 'key' partitions per-aggregate within the destination topic. Consumers
  see events for the same 'key' in producer order under EP-20's per-key
  head-of-line publisher policy.
-}
data IntegrationEvent = IntegrationEvent
    { messageId :: !Text
    , source :: !Text
    , destination :: !Text
    , key :: !(Maybe Text)
    , eventType :: !Text
    , schemaVersion :: !Int
    , contentType :: !IntegrationContentType
    , schemaReference :: !(Maybe SchemaReference)
    , sourceEventId :: !(Maybe EventId)
    , sourceGlobalPosition :: !(Maybe GlobalPosition)
    , payloadBytes :: !ByteString
    , occurredAt :: !UTCTime
    , causationId :: !(Maybe EventId)
    , correlationId :: !(Maybe EventId)
    , traceContext :: !(Maybe TraceContext)
    , attributes :: !(Maybe Value)
    }
    deriving stock (Eq, Show, Generic)

{- | Content type of the payload bytes.

'ApplicationJson' is the v1 default. 'OtherContentType' is the open door
for Avro, Protobuf, or any future registry-backed binary format; a future
schema-registry adapter can populate 'schemaReference' alongside.
-}
data IntegrationContentType
    = ApplicationJson
    | OtherContentType !Text
    deriving stock (Eq, Show, Generic)

{- | Optional registry-neutral schema reference.

Every field is optional because v1 does not require a registry. A future
adapter may populate any combination of registry name, subject, version,
numeric schema id, or fingerprint depending on the registry vendor. The
core envelope preserves all fields verbatim through publish and consume.
-}
data SchemaReference = SchemaReference
    { registry :: !(Maybe Text)
    , subject :: !(Maybe Text)
    , version :: !(Maybe Int)
    , schemaId :: !(Maybe Int64)
    , fingerprint :: !(Maybe Text)
    }
    deriving stock (Eq, Show, Generic)

{- | W3C Trace Context propagation fields.

When a service captures @traceparent@ and (optionally) @tracestate@ from
the producing request and threads them through, both fields survive
publish and consume via Kafka headers so a consumer can continue the
same trace.
-}
data TraceContext = TraceContext
    { traceparent :: !Text
    , tracestate :: !(Maybe Text)
    }
    deriving stock (Eq, Show, Generic)

{- | Typed decode errors. The encode side cannot fail; the decode side can
fail if payload bytes are malformed JSON, the JSON does not satisfy the
target type, or required envelope metadata is missing.
-}
data IntegrationEventError
    = MalformedPayload !Text
    | DecodeFailed !Text
    | MissingField !Text
    | UnsupportedContentType !Text
    deriving stock (Eq, Show, Generic)

-- | The payload bytes as they should be put on the wire.
integrationPayload :: IntegrationEvent -> ByteString
integrationPayload = (^. #payloadBytes)

{- | The set of headers a transport should attach to a published message.

Every header value is a 'Text' for portability — Kafka header values are
arbitrary bytes, but text headers are the convention for human-readable
metadata. The publisher converts these to UTF-8 bytes; the consumer
decodes UTF-8 back to text.

Headers are emitted only when their source field is populated, so a
service that does not capture trace context, causation, or a schema
reference does not pay a header for it.
-}
integrationHeaders :: IntegrationEvent -> [(Text, Text)]
integrationHeaders event =
    concat
        [
            [ (headerMessageId, event ^. #messageId)
            , (headerSource, event ^. #source)
            , (headerDestination, event ^. #destination)
            , (headerEventType, event ^. #eventType)
            , (headerSchemaVersion, Text.pack (show (event ^. #schemaVersion)))
            , (headerContentType, contentTypeText (event ^. #contentType))
            ]
        , case event ^. #schemaReference of
            Nothing -> []
            Just ref ->
                concat
                    [ maybeHeader headerSchemaRegistry (ref ^. #registry)
                    , maybeHeader headerSchemaSubject (ref ^. #subject)
                    , maybeHeader headerSchemaVersionRef (fmap (Text.pack . show) (ref ^. #version))
                    , maybeHeader headerSchemaId (fmap (Text.pack . show) (ref ^. #schemaId))
                    , maybeHeader headerSchemaFingerprint (ref ^. #fingerprint)
                    ]
        , maybeHeader headerSourceEventId (fmap (UUID.toText . eventIdToUuid) (event ^. #sourceEventId))
        , maybeHeader headerSourceGlobalPosition (fmap globalPositionText (event ^. #sourceGlobalPosition))
        , maybeHeader headerCausationId (fmap (UUID.toText . eventIdToUuid) (event ^. #causationId))
        , maybeHeader headerCorrelationId (fmap (UUID.toText . eventIdToUuid) (event ^. #correlationId))
        , case event ^. #traceContext of
            Nothing -> []
            Just tc ->
                (headerTraceParent, tc ^. #traceparent)
                    : maybeHeader headerTraceState (tc ^. #tracestate)
        , [(headerOccurredAt, Text.pack (iso8601Show (event ^. #occurredAt)))]
        , maybeHeader headerAttributes (fmap (TextEncoding.decodeUtf8 . Lazy.toStrict . Aeson.encode) (event ^. #attributes))
        ]
  where
    maybeHeader name = maybe [] (\value -> [(name, value)])

-- | Canonical header names. Lower-case @kebab-case@ matches Kafka convention.
headerMessageId, headerSource, headerDestination, headerEventType, headerSchemaVersion, headerContentType :: Text
headerMessageId = "keiro-message-id"
headerSource = "keiro-source"
headerDestination = "keiro-destination"
headerEventType = "keiro-event-type"
headerSchemaVersion = "keiro-schema-version"
headerContentType = "content-type"

headerSchemaRegistry, headerSchemaSubject, headerSchemaVersionRef, headerSchemaId, headerSchemaFingerprint :: Text
headerSchemaRegistry = "keiro-schema-registry"
headerSchemaSubject = "keiro-schema-subject"
headerSchemaVersionRef = "keiro-schema-version-ref"
headerSchemaId = "keiro-schema-id"
headerSchemaFingerprint = "keiro-schema-fingerprint"

headerSourceEventId, headerSourceGlobalPosition, headerCausationId, headerCorrelationId :: Text
headerSourceEventId = "keiro-source-event-id"
headerSourceGlobalPosition = "keiro-source-global-position"
headerCausationId = "keiro-causation-id"
headerCorrelationId = "keiro-correlation-id"

headerTraceParent, headerTraceState :: Text
headerTraceParent = "traceparent"
headerTraceState = "tracestate"

headerOccurredAt, headerAttributes :: Text
headerOccurredAt = "keiro-occurred-at"
headerAttributes = "keiro-attributes"

-- | The canonical wire string for a 'IntegrationContentType'.
contentTypeText :: IntegrationContentType -> Text
contentTypeText = \case
    ApplicationJson -> "application/json"
    OtherContentType raw -> raw

{- | Parse a content-type header back into an 'IntegrationContentType'. The
JSON form round-trips to 'ApplicationJson'; everything else is preserved
verbatim as 'OtherContentType'.
-}
parseContentType :: Text -> IntegrationContentType
parseContentType raw
    | normalized == "application/json" = ApplicationJson
    | otherwise = OtherContentType raw
  where
    normalized = Text.toLower (Text.strip (Text.takeWhile (/= ';') raw))

{- | Build an 'IntegrationEvent' from a JSON-serializable business payload.

@encodeJsonIntegrationEvent envelope value@ replaces 'contentType' with
'ApplicationJson' and 'payloadBytes' with the UTF-8 encoding of
@value@'s JSON representation. Every other envelope field is taken from
@envelope@ verbatim, so the caller controls identity, routing, and
metadata.
-}
encodeJsonIntegrationEvent ::
    (ToJSON a) =>
    -- | Envelope template carrying identity, routing, and metadata.
    IntegrationEvent ->
    -- | Business payload to encode as JSON.
    a ->
    IntegrationEvent
encodeJsonIntegrationEvent envelope value =
    envelope
        & #contentType
        .~ ApplicationJson
        & #payloadBytes
        .~ Lazy.toStrict (Aeson.encode value)

{- | Decode the JSON payload of an 'IntegrationEvent' into a business
type.

Returns 'MalformedPayload' if the bytes are not valid JSON,
'DecodeFailed' if the JSON does not satisfy the target's 'FromJSON'
instance, and 'UnsupportedContentType' if the envelope's 'contentType'
is not 'ApplicationJson'.
-}
decodeJsonIntegrationEvent ::
    (FromJSON a) =>
    IntegrationEvent ->
    Either IntegrationEventError a
decodeJsonIntegrationEvent event = do
    case event ^. #contentType of
        ApplicationJson -> pure ()
        OtherContentType raw -> Left (UnsupportedContentType raw)
    parsed <- case Aeson.eitherDecodeStrict (event ^. #payloadBytes) of
        Left err -> Left (MalformedPayload (Text.pack err))
        Right value -> Right (value :: Value)
    case parseEither parseJSON parsed of
        Left err -> Left (DecodeFailed (Text.pack err))
        Right value -> Right value

eventIdToUuid :: EventId -> UUID.UUID
eventIdToUuid (EventId uuid) = uuid

globalPositionText :: GlobalPosition -> Text
globalPositionText (GlobalPosition pos) = Text.pack (show pos)
