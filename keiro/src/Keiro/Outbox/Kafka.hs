{- | Transport-neutral Kafka representation for outbox rows.

This module owns the conversion from 'Keiro.Outbox.Types.OutboxRow' to a
neutral 'KafkaProducerRecord' value. It deliberately does not import
@hw-kafka-client@ or @kafka-effectful@: keiro itself remains free of
librdkafka system-library requirements. The integration test package
(EP-22) bridges 'KafkaProducerRecord' to
@Kafka.Producer.Types.ProducerRecord@ from @hw-kafka-client@ inside its
own dependency scope.

A 'KafkaProducerRecord' carries everything the broker layer needs:
topic, optional partition key, the raw payload bytes from the EP-19
envelope, and the canonical header set. Building the record is pure;
publishing is the caller's responsibility.

The outbox worker opens one producer span around each claimed publish batch.
Adapters that need per-record broker visibility should add their own spans
around the actual Kafka produce calls.
-}
module Keiro.Outbox.Kafka (
    KafkaProducerRecord (..),
    outboxRowToKafkaRecord,
    integrationEventToKafkaRecord,
)
where

import Data.ByteString (ByteString)
import Data.Text.Encoding qualified as TE
import Keiro.Integration.Event (IntegrationEvent, integrationHeaders, integrationPayload)
import Keiro.Outbox.Types (OutboxRow (..))
import Keiro.Prelude

{- | A neutral Kafka producer record.

Fields:

* 'topic' — Kafka topic, taken from 'IntegrationEvent.destination'.
* 'key' — partition key bytes (UTF-8 encoded). 'Nothing' means
  Kafka round-robins the record across partitions and skips per-key
  ordering.
* 'payload' — exactly the bytes from
  'Keiro.Integration.Event.integrationPayload'.
* 'headers' — UTF-8 encoded view of
  'Keiro.Integration.Event.integrationHeaders'.

The byte encoding for keys and headers is UTF-8 by convention; Kafka
treats both as opaque bytes, so a future binary-key transport can drop
the encoding by populating 'key' directly.
-}
data KafkaProducerRecord = KafkaProducerRecord
    { topic :: !Text
    , key :: !(Maybe ByteString)
    , payload :: !ByteString
    , headers :: ![(ByteString, ByteString)]
    }
    deriving stock (Generic, Eq, Show)

-- | Build a 'KafkaProducerRecord' from a published outbox row.
outboxRowToKafkaRecord :: OutboxRow -> KafkaProducerRecord
outboxRowToKafkaRecord row = integrationEventToKafkaRecord (row ^. #event)

-- | Build a 'KafkaProducerRecord' directly from an 'IntegrationEvent'.
integrationEventToKafkaRecord :: IntegrationEvent -> KafkaProducerRecord
integrationEventToKafkaRecord event =
    KafkaProducerRecord
        { topic = event ^. #destination
        , key = fmap TE.encodeUtf8 (event ^. #key)
        , payload = integrationPayload event
        , headers = [(TE.encodeUtf8 n, TE.encodeUtf8 v) | (n, v) <- integrationHeaders event]
        }
