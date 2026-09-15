-- | Frozen version-1 producer identities and canonical envelope comparisons.
module Keiro.Outbox.Identity
  ( ProducerEventKey (..),
    ProducerIdentity (..),
    ProducerEnqueueOutcome (..),
    ConflictField (..),
    producerIdentityBytes,
    deriveIdentity,
    producerContentDigest,
    differingContentFields,
    normalizeProducerEvent,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as Lazy
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..))
import Data.UUID qualified as UUID
import Data.Word (Word16, Word32)
import Keiro.Integration.Event
import Keiro.Outbox.Types (OutboxId (..))
import Keiro.Prelude
import Keiro.ReplayDigest (canonicalJsonBytes, replayDigest)
import Kiroku.Store.Types (EventId (..))

data ProducerEventKey = ProducerEventKey
  { sourceEventId :: !EventId,
    emissionIndex :: !Word32
  }
  deriving stock (Generic, Eq, Show)

data ProducerIdentity = ProducerIdentity
  { outboxId :: !OutboxId,
    messageId :: !Text,
    derivationVersion :: !Word16
  }
  deriving stock (Generic, Eq, Show)

-- | Field classes only: no payload or metadata values appear in conflicts.
data ConflictField
  = IdentityField
  | RoutingField
  | SchemaField
  | PayloadField
  | OccurredAtField
  | CausalField
  | TraceField
  | AttributesField
  | ProvenanceField
  deriving stock (Generic, Eq, Ord, Show)

data ProducerEnqueueOutcome
  = ProducerInserted !ProducerIdentity
  | ProducerDuplicateIdentical !ProducerIdentity
  | ProducerIdentityConflict !ProducerIdentity !(NonEmpty ConflictField)
  deriving stock (Generic, Eq, Show)

-- | Each field has an unsigned 64-bit big-endian byte length. Fields are
-- domain, version (two bytes), UTF-8 source/name, source UUID (16 network-order
-- bytes), and emission index (four bytes). The namespace labels the message ID;
-- changing it intentionally conflicts with the unchanged outbox UUID.
producerIdentityBytes :: Text -> Text -> ProducerEventKey -> BS.ByteString
producerIdentityBytes source name key =
  Lazy.toStrict . Builder.toLazyByteString . foldMap field $
    [ "keiro.producer.outbox",
      bytes (Builder.word16BE 1),
      TE.encodeUtf8 source,
      TE.encodeUtf8 name,
      bytes (Builder.word32BE a <> Builder.word32BE b <> Builder.word32BE c <> Builder.word32BE d),
      bytes (Builder.word32BE (key ^. #emissionIndex))
    ]
  where
    EventId uuid = key ^. #sourceEventId
    (a, b, c, d) = UUID.toWords uuid
    bytes = Lazy.toStrict . Builder.toLazyByteString
    field value = Builder.word64BE (fromIntegral (BS.length value)) <> Builder.byteString value

-- | SHA-256 of the canonical tuple. UUID uses the first 128 bits with RFC
-- variant and version 8 bits set. Message ID is namespace <> "_v1_" <> full
-- lowercase SHA-256 hex. No clock, random generator, or process state is read.
deriveIdentity :: Text -> Text -> Text -> ProducerEventKey -> ProducerIdentity
deriveIdentity source name namespace key =
  ProducerIdentity
    { outboxId = OutboxId (UUID.fromWords (word 0) ((word 4 .&. 0xffff0fff) .|. 0x8000) ((word 8 .&. 0x3fffffff) .|. 0x80000000) (word 12)),
      messageId = namespace <> "_v1_" <> TE.decodeUtf8 (Base16.encode digest),
      derivationVersion = 1
    }
  where
    digest = SHA256.hash (producerIdentityBytes source name key)
    word offset = BS.foldl' (\acc byte -> acc * 256 + fromIntegral byte) 0 (BS.take 4 (BS.drop offset digest))

-- | PostgreSQL stores whole microseconds. Normalize before writing so the
-- canonical timestamp is unchanged by the database round trip.
normalizeProducerEvent :: IntegrationEvent -> IntegrationEvent
normalizeProducerEvent event = event & #occurredAt .~ UTCTime day (fromRational (fromInteger micros / 1000000))
  where
    UTCTime day time = event ^. #occurredAt
    micros = floor (toRational time * 1000000) :: Integer

-- | RFC 8785 JSON of a fixed ordered list of field classes. Payload stays
-- byte-exact (hex); attributes are structured canonical JSON, not encoded text.
producerContentDigest :: IntegrationEvent -> Text
producerContentDigest = replayDigest . toJSON . fmap snd . contentFields

differingContentFields :: IntegrationEvent -> IntegrationEvent -> [ConflictField]
differingContentFields a b =
  [field | ((field, x), (_, y)) <- zip (contentFields a) (contentFields b), canonicalJsonBytes x /= canonicalJsonBytes y]

contentFields :: IntegrationEvent -> [(ConflictField, Value)]
contentFields original =
  [ (IdentityField, headers [headerMessageId, headerSource]),
    (RoutingField, toJSON (event ^. #destination, event ^. #key)),
    (SchemaField, headers [headerEventType, headerSchemaVersion, headerContentType, headerSchemaRegistry, headerSchemaSubject, headerSchemaVersionRef, headerSchemaId, headerSchemaFingerprint]),
    (PayloadField, toJSON (TE.decodeUtf8 (Base16.encode (event ^. #payloadBytes)))),
    (OccurredAtField, headers [headerOccurredAt]),
    (CausalField, headers [headerCausationId, headerCorrelationId]),
    (TraceField, headers [headerTraceParent, headerTraceState]),
    (AttributesField, toJSON (maybe [] pure (event ^. #attributes))),
    (ProvenanceField, headers [headerSourceEventId, headerSourceGlobalPosition])
  ]
  where
    event = normalizeProducerEvent original
    allHeaders = integrationHeaders event
    headers names = toJSON [(name, lookup name allHeaders) | name <- names]
