{- | Reconstruct an 'IntegrationEvent' from Kafka payload bytes plus
headers.

This module is the receiving-side counterpart of
'Keiro.Outbox.Kafka.integrationEventToKafkaRecord'. It is pure: the
caller supplies the bytes and the @Text@-keyed header map produced by
its Kafka adapter, and gets back a decoded envelope or a typed error.

@keiro@ itself does not depend on @hw-kafka-client@ or
@shibuya-kafka-adapter@; the consumer adapter in EP-22 bridges the
broker library's header type to @[(Text, Text)]@ before calling
'integrationEventFromKafka'.
-}
module Keiro.Inbox.Kafka (
    KafkaInboundRecord (..),
    KafkaDecodeError (..),
    integrationEventFromKafka,
)
where

import Data.ByteString (ByteString)
import Data.Maybe (mapMaybe)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Data.UUID qualified as UUID
import Keiro.Inbox.Types (KafkaDeliveryRef (..))
import Keiro.Integration.Event (
    IntegrationContentType (..),
    IntegrationEvent (..),
    SchemaReference (..),
    TraceContext (..),
    headerCausationId,
    headerContentType,
    headerCorrelationId,
    headerDestination,
    headerEventType,
    headerMessageId,
    headerSchemaFingerprint,
    headerSchemaId,
    headerSchemaRegistry,
    headerSchemaSubject,
    headerSchemaVersion,
    headerSchemaVersionRef,
    headerSource,
    headerSourceEventId,
    headerSourceGlobalPosition,
    headerTraceParent,
    headerTraceState,
    parseContentType,
 )
import Keiro.Prelude
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))

{- | A Kafka record as seen by the consumer-side adapter, decoupled from
the broker library's record type.
-}
data KafkaInboundRecord = KafkaInboundRecord
    { topic :: !Text
    , partition :: !Int64
    , offset :: !Int64
    , key :: !(Maybe Text)
    , payload :: !ByteString
    , headers :: ![(Text, Text)]
    , receivedAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)

-- | Typed failures from 'integrationEventFromKafka'.
data KafkaDecodeError
    = MissingHeader !Text
    | InvalidIntHeader !Text !Text
    | InvalidUuidHeader !Text !Text
    deriving stock (Generic, Eq, Show)

{- | Reconstruct a full 'IntegrationEvent' plus the 'KafkaDeliveryRef'
recorded for diagnostics.

The reconstruction is faithful to the canonical header names defined
by 'Keiro.Integration.Event' (e.g. @keiro-message-id@, @keiro-source@,
@traceparent@). Missing required headers (@keiro-source@,
@keiro-destination@, @keiro-event-type@, @keiro-schema-version@,
@content-type@, @keiro-message-id@) produce 'MissingHeader'; malformed
numeric or UUID headers produce 'InvalidIntHeader' / 'InvalidUuidHeader'.
Optional headers are silently absent in the resulting envelope.
-}
integrationEventFromKafka ::
    KafkaInboundRecord ->
    Either KafkaDecodeError (IntegrationEvent, KafkaDeliveryRef)
integrationEventFromKafka record = do
    let hs = record ^. #headers
    source <- requireHeader hs headerSource
    destination <- requireHeader hs headerDestination
    eventType <- requireHeader hs headerEventType
    schemaVersionText <- requireHeader hs headerSchemaVersion
    schemaVersion <- parseInt headerSchemaVersion schemaVersionText
    contentTypeRaw <- requireHeader hs headerContentType
    messageId <- requireHeader hs headerMessageId
    schemaReference <- buildSchemaReference hs
    sourceEventId <- traverseLookup hs headerSourceEventId (fmap EventId . parseUuid headerSourceEventId)
    sourceGlobalPosition <-
        traverseLookup hs headerSourceGlobalPosition (fmap GlobalPosition . parseInt headerSourceGlobalPosition)
    causationId <- traverseLookup hs headerCausationId (fmap EventId . parseUuid headerCausationId)
    correlationId <- traverseLookup hs headerCorrelationId (fmap EventId . parseUuid headerCorrelationId)
    let traceContext = case Prelude.lookup headerTraceParent hs of
            Nothing -> Nothing
            Just tp -> Just (TraceContext tp (Prelude.lookup headerTraceState hs))
        event =
            IntegrationEvent
                { messageId
                , source
                , destination
                , key = record ^. #key
                , eventType
                , schemaVersion
                , contentType = parseContentType contentTypeRaw
                , schemaReference
                , sourceEventId
                , sourceGlobalPosition
                , payloadBytes = record ^. #payload
                , occurredAt = record ^. #receivedAt
                , -- The producer side does not propagate occurredAt as a
                  -- canonical header; receivers that need the producer's
                  -- wall-clock can read it from the payload. Inbox storage
                  -- preserves the field so future header conventions can add
                  -- one without a migration.
                  causationId
                , correlationId
                , traceContext
                , attributes = Nothing
                }
        kafka =
            KafkaDeliveryRef
                { topic = record ^. #topic
                , partition = record ^. #partition
                , offset = record ^. #offset
                }
    pure (event, kafka)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

requireHeader :: [(Text, Text)] -> Text -> Either KafkaDecodeError Text
requireHeader hs name = case Prelude.lookup name hs of
    Just v -> Right v
    Nothing -> Left (MissingHeader name)

traverseLookup ::
    [(Text, Text)] ->
    Text ->
    (Text -> Either KafkaDecodeError a) ->
    Either KafkaDecodeError (Maybe a)
traverseLookup hs name parser = case Prelude.lookup name hs of
    Nothing -> Right Nothing
    Just raw -> fmap Just (parser raw)

parseInt :: (Integral a) => Text -> Text -> Either KafkaDecodeError a
parseInt name raw = case TextRead.signed TextRead.decimal raw of
    Right (n, rest) | Text.null rest -> Right n
    _ -> Left (InvalidIntHeader name raw)

parseUuid :: Text -> Text -> Either KafkaDecodeError UUID.UUID
parseUuid name raw = case UUID.fromText raw of
    Just u -> Right u
    Nothing -> Left (InvalidUuidHeader name raw)

buildSchemaReference ::
    [(Text, Text)] ->
    Either KafkaDecodeError (Maybe SchemaReference)
buildSchemaReference hs = do
    let registry = Prelude.lookup headerSchemaRegistry hs
        subject = Prelude.lookup headerSchemaSubject hs
        fingerprint = Prelude.lookup headerSchemaFingerprint hs
    versionRef <- traverseLookup hs headerSchemaVersionRef (parseInt headerSchemaVersionRef)
    schemaId <- traverseLookup hs headerSchemaId (parseInt headerSchemaId)
    let presentFields =
            mapMaybe id [registry, subject, fmap (Text.pack . show) versionRef, fmap (Text.pack . show) schemaId, fingerprint]
    if null presentFields
        then pure Nothing
        else
            pure
                ( Just
                    ( SchemaReference
                        { registry
                        , subject
                        , version = versionRef
                        , schemaId
                        , fingerprint
                        }
                    )
                )

{- | Silence unused-import warning when 'IntegrationContentType' is
imported only via the open re-export but referenced through
'parseContentType'.
-}
_unusedKeepContentType :: IntegrationContentType -> ()
_unusedKeepContentType _ = ()
