# Durable Outbox

The `Keiro.Outbox` module gives an application a durable handoff
between "this service has decided to publish an integration event" and
"this service has actually published it to Kafka". Without an outbox,
publishing inline would either (a) commit a domain event and then crash
before the Kafka publish — losing the integration event — or (b)
publish to Kafka before the domain event is committed — leaking events
that did not happen.

The outbox solves both. A producer-subscription writes one
`keiro_outbox` row per mapped private event in the same Postgres
transaction that advances its subscription checkpoint. A separate
publisher worker drains the rows into Kafka and marks each row sent,
retryable, or dead.

Publish semantics are **at-least-once**: if the publisher crashes after
Kafka acknowledges a record but before the row is marked sent, the
retry will republish the same payload with the same `messageId`. The
receiving inbox ([EP-21 idempotent inbox][inbox]) is responsible for
deduplication.

[inbox]: ./inbox.md

## The canonical pipeline

```
  command  →  private domain event  →  IntegrationProducer  →  keiro_outbox row
                                                                       │
                                                                       ▼
                                                              publishClaimedOutbox
                                                                       │
                                                                       ▼
                                                                     Kafka
```

1. A command commits a private domain event to the local event store.
2. A checkpointed `IntegrationProducer` subscription reads each
   recorded private event, maps it to a public
   `IntegrationEventDraft`, mints a fresh `messageId` (a TypeID-shaped
   UUIDv7), and writes one `keiro_outbox` row in the same transaction
   that advances its subscription cursor.
3. The publisher worker (`publishClaimedOutbox`) claims rows with
   `FOR UPDATE SKIP LOCKED` plus a configurable ordering policy,
   publishes via a caller-supplied function, and marks each row sent
   or failed.

The producer subscription never publishes to Kafka directly; the
outbox row is the durable handoff. This places `attempts`,
`last_error`, and per-row status into first-class SQL and gives
operators a single place to inspect what is pending.

## The escape hatch

Sagas and process managers that need to emit an integration event
without an intermediate domain event can call `enqueueIntegrationEventTx`
inside the transaction passed to `runCommandWithSqlEvents`:

```haskell
runCommandWithSqlEvents options eventStream targetStream cmd $ \_events _appendResult -> do
  outboxId <- liftIO V7.genUUID
  enqueueIntegrationEventTx (OutboxId outboxId) integrationEvent
```

This is intentionally a single primitive, not a workflow — anything
beyond an inline emit should go through the canonical
`IntegrationProducer` path so the row carries `sourceEventId` and
`sourceGlobalPosition`.

## Ordering policy

The publisher worker enforces a configurable ordering policy at claim
time. The default is **per-key head-of-line blocking**: within a
`source`, a non-terminal row with key `k` blocks every later row with
the same key. Rows with `key = Nothing` bypass the block (Kafka does
not promise cross-key order for null-keyed records).

| Policy             | Behaviour                                                     | When to choose                                                            |
|--------------------|---------------------------------------------------------------|---------------------------------------------------------------------------|
| `PerKeyHeadOfLine` | Default. One stuck row blocks only its key.                   | The common case where `key = aggregate_id`.                               |
| `PerSourceStream`  | Any non-terminal row blocks every later row in the source.    | Ordering matters across keys (rare).                                      |
| `StopTheLine`      | First failure halts the publisher; operator action required.  | Correctness requires manual review on every failure.                      |
| `BestEffort`       | Failed rows do not block later rows.                          | Events have no per-key or causal relationship; explicit opt-in only.      |

Skipping a failed row and publishing a later row with the same Kafka
key silently violates per-partition order — consumers would see
`OrderShipped` arrive before `OrderPaid` for the same order, lifecycle
projections would apply updates to non-existent rows, and log-compacted
topics would record a permanently lossy view. Per-key head-of-line is
the default because it contains blast radius to one aggregate.

## Auto dead-letter

A row that fails `maxAttempts` consecutive times (default 10) is
transitioned to a terminal `dead` status. Dead rows are not claimed and
no longer block their key. They remain in the table for operator
inspection:

```sql
SELECT * FROM keiro_outbox WHERE status = 'dead';
```

Without a terminal state, a permanently broken row (oversized payload,
schema-registry reject, missing topic, unrecoverable serialization bug)
would freeze its key indefinitely. v1 does not distinguish transient
from permanent Kafka errors — every error counts an attempt. A future
worker can refine this by classifying the error before calling
`markOutboxFailedTx`.

## Backoff

`OutboxPublishOptions.backoff :: BackoffSchedule` controls how
`next_attempt_at` is set after a failure:

```haskell
ConstantBackoff 2   -- 2 second delay between every retry
ExponentialBackoff (ExponentialBackoffOptions 1 60 2.0)
  -- 1s, 2s, 4s, 8s, … capped at 60s
```

## The Kafka conversion

`Keiro.Outbox.Kafka.outboxRowToKafkaRecord` converts an `OutboxRow` to
a transport-neutral `KafkaProducerRecord`:

```haskell
data KafkaProducerRecord = KafkaProducerRecord
  { topic   :: !Text
  , key     :: !(Maybe ByteString)
  , payload :: !ByteString
  , headers :: ![(ByteString, ByteString)]
  }
```

`keiro` itself does not depend on `hw-kafka-client` or
`kafka-effectful` so the library stays free of librdkafka system-library
requirements. An integration-level adapter (see EP-22) bridges
`KafkaProducerRecord` to `Kafka.Producer.Types.ProducerRecord` inside
its own dependency scope.

The mapping is:

- `topic` ← `IntegrationEvent.destination`
- `key` ← UTF-8 of `IntegrationEvent.key` (`Nothing` is round-robin)
- `payload` ← `integrationPayload`
- `headers` ← UTF-8 of `integrationHeaders`

## Schema and storage

The outbox table is created by `keiro-migrate` from the embedded codd
migration `2026-05-17-01-00-00-keiro-outbox.sql`:

```sql
CREATE TABLE keiro_outbox (
  outbox_id UUID PRIMARY KEY,
  message_id TEXT NOT NULL,
  source TEXT NOT NULL,
  destination TEXT NOT NULL,
  message_key TEXT,
  -- … envelope columns …
  status TEXT NOT NULL DEFAULT 'pending',
  attempt_count BIGINT NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error TEXT,
  published_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source, message_id)
);
```

Two supporting indexes:

- `keiro_outbox_pending_idx` on `(status, next_attempt_at, created_at)`
  — backs the claim query's filter.
- `keiro_outbox_head_of_line_idx` on `(source, message_key, created_at)`
  partial `WHERE status NOT IN ('sent', 'dead') AND message_key IS NOT NULL`
  — backs the per-key head-of-line predicate.

The `(source, message_id)` unique constraint means a retried saga
attempt with the same `outboxId` is idempotent at the row level —
re-inserting is a no-op.

## A worked example

```haskell
import Keiro.Outbox
import Keiro.Integration.Event

-- 1. Define the producer subscription.
ordersIntegrationProducer :: IntegrationProducer OrderEvent
ordersIntegrationProducer = IntegrationProducer
  { name = "ordering-integration-producer"
  , source = "ordering"
  , messageIdPrefix = "msg"
  , mapEvent = \recorded -> \case
      OrderSubmitted orderId quantity ->
        Just IntegrationEventDraft
          { destination = "billing.orders.v1"
          , key = Just orderId
          , eventType = "OrderSubmitted"
          , schemaVersion = 1
          , contentType = ApplicationJson
          , schemaReference = Just (subjectReference "billing.orders.v1.OrderSubmitted")
          , sourceEventId = Just (recorded ^. #eventId)
          , sourceGlobalPosition = Just (recorded ^. #globalPosition)
          , payloadBytes = Lazy.toStrict (Aeson.encode (orderSubmittedJson orderId quantity))
          , occurredAt = recorded ^. #createdAt
          , causationId = Nothing
          , correlationId = Nothing
          , traceContext = Nothing
          , attributes = Nothing
          }
      _ -> Nothing
  }

-- 2. The publisher worker drains rows into Kafka.
runPublisher :: Eff es ()
runPublisher = void $
  publishClaimedOutbox
    (\row -> liftIO (kafkaProduce (outboxRowToKafkaRecord row)))
    defaultPublishOptions
```

A future schema-registry adapter populates `schemaReference` (and may
swap `contentType` to Avro or Protobuf). The envelope already carries
every field a registry needs, so no further migration is required.
