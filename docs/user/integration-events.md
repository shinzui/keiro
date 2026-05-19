# Integration Events

A **domain event** is a private fact in one event stream of one bounded
context. An **integration event** is a public message that crosses from
one bounded context to another over Kafka (or another transport). The
two are different contracts:

- Domain events are recorded in the local event store. They are internal
  and may change shape as the domain model evolves.
- Integration events are stable public contracts. Other services consume
  them and must not be broken by an internal refactor.

The `Keiro.Integration.Event` module owns the public envelope shape, the
identity rules, and pure encode/decode helpers. The durable outbox
(`Keiro.Outbox`, see EP-20) and idempotent inbox (`Keiro.Inbox`, see
EP-21) consume this contract; they do not redefine it.

## The envelope

```haskell
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
```

The envelope is **byte-oriented**: `payloadBytes` is whatever the producer
serialized. JSON is the v1 default (`ApplicationJson`), but the contract
itself does not commit to it. A future schema-registry adapter can
populate `schemaReference` and use `OtherContentType "application/vnd.apache.avro.binary"`
without changing the outbox or inbox tables.

## Message identity

`messageId` is an **application-level** identifier (UUIDv7 or equivalent
time-ordered UUID) minted by the producer subscription when it writes
the outbox row. It is:

- **Stable across publish retries.** The outbox row keeps its
  `messageId` until it is marked `sent` (or `dead`); if the publisher
  crashes after Kafka acknowledges the publish but before the row is
  marked sent, the retry republishes the same `messageId`. The
  consumer's inbox deduplicates on `(source, messageId)` so the local
  handler still runs at most once.
- **Independent of source identity.** `sourceEventId` and
  `sourceGlobalPosition` identify the private event that produced this
  integration event. A single source event can fan out to multiple
  integration events with distinct `messageId`s; consumers can opt into
  source-position deduplication when they want to suppress reissued
  public events sharing an upstream cause.
- **Not the Kafka delivery identity.** Kafka topic/partition/offset
  describe *how* a message arrived. They change between deliveries (the
  same logical message published twice gets two offsets) and are
  recorded on the inbox row for diagnostics only. They are not the
  canonical dedupe key.

## Routing

- `source` is the producing bounded context (e.g. `"ordering"`).
- `destination` is the Kafka topic, by convention including the
  contract's major version (`"billing.orders.v1"`).
- `key` is the Kafka partition key, typically the aggregate id
  (`"order-123"`). Consumers see events for the same `key` in producer
  order under EP-20's per-key head-of-line publisher policy. Events
  with `key = Nothing` are partitioned round-robin and carry no
  cross-message ordering guarantee.

## Wire headers

`integrationHeaders` returns the canonical text headers that the Kafka
producer (or any other transport) should attach to each message. Header
values are emitted only when the corresponding envelope field is
populated:

| Header                         | Source                                  |
|--------------------------------|-----------------------------------------|
| `keiro-message-id`             | `messageId`                             |
| `keiro-source`                 | `source`                                |
| `keiro-destination`            | `destination`                           |
| `keiro-event-type`             | `eventType`                             |
| `keiro-schema-version`         | `schemaVersion`                         |
| `content-type`                 | `contentType`                           |
| `keiro-schema-registry`        | `schemaReference.registry`              |
| `keiro-schema-subject`         | `schemaReference.subject`               |
| `keiro-schema-version-ref`     | `schemaReference.version`               |
| `keiro-schema-id`              | `schemaReference.schemaId`              |
| `keiro-schema-fingerprint`     | `schemaReference.fingerprint`           |
| `keiro-source-event-id`        | `sourceEventId`                         |
| `keiro-source-global-position` | `sourceGlobalPosition`                  |
| `keiro-causation-id`           | `causationId`                           |
| `keiro-correlation-id`         | `correlationId`                         |
| `traceparent`                  | `traceContext.traceparent` (W3C)        |
| `tracestate`                   | `traceContext.tracestate`  (W3C)        |

## JSON convenience helpers

`encodeJsonIntegrationEvent envelope payload` returns an
`IntegrationEvent` whose `payloadBytes` is the UTF-8 JSON encoding of
`payload`, with `contentType` set to `ApplicationJson`. Every other
field is taken from `envelope` verbatim, so the caller controls
identity, routing, and metadata.

`decodeJsonIntegrationEvent event` decodes the JSON payload back into a
business type. It returns:

- `MalformedPayload` if the bytes are not valid JSON,
- `DecodeFailed` if the JSON does not satisfy the target's `FromJSON`
  instance,
- `UnsupportedContentType` if the envelope's `contentType` is not
  `ApplicationJson`.

## Future schema registry

v1 does not contact a schema registry. The envelope already carries the
metadata a future adapter needs:

- `contentType` says whether the payload is JSON, Avro, Protobuf, or
  something else.
- `schemaReference` carries optional registry name, subject, version,
  numeric schema id, and fingerprint. A future adapter can populate or
  validate these without changing the outbox/inbox tables.

The byte-oriented `payloadBytes` field lets a registry-backed encoder
write Confluent-framed Avro, Apicurio-framed JSON Schema, or any other
binary format; the inbox and outbox preserve those bytes verbatim.

## Worked example

```haskell
import Keiro.Integration.Event

submitted :: IntegrationEvent
submitted = IntegrationEvent
  { messageId = "018f0f18-17aa-7000-8000-0000000000aa"  -- minted by producer subscription
  , source = "ordering"
  , destination = "billing.orders.v1"
  , key = Just "order-123"
  , eventType = "OrderSubmitted"
  , schemaVersion = 1
  , contentType = ApplicationJson
  , schemaReference = Just SchemaReference
      { registry = Nothing
      , subject = Just "billing.orders.v1.OrderSubmitted"
      , version = Just 1
      , schemaId = Nothing
      , fingerprint = Nothing
      }
  , sourceEventId = Just sourceEvent.eventId
  , sourceGlobalPosition = Just sourceEvent.globalPosition
  , payloadBytes = ""  -- filled by encodeJsonIntegrationEvent
  , occurredAt = now
  , causationId = Nothing
  , correlationId = Nothing
  , traceContext = Nothing
  , attributes = Nothing
  }

wire = encodeJsonIntegrationEvent submitted (OrderSubmitted "order-123" 5)
-- wire ^. #payloadBytes == "{\"orderId\":\"order-123\",\"quantity\":5}"
```

The producer subscription in EP-20 mints `messageId`, sets
`sourceEventId` / `sourceGlobalPosition` from the recorded event, and
inserts one outbox row per mapped private event in the same Postgres
transaction that advances its checkpoint. The publisher worker drains
the outbox into Kafka and marks each row `sent` (or, after
`max_attempts`, `dead`).
