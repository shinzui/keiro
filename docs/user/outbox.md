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
   publishes each claimed batch via a caller-supplied function, and
   marks each row sent or failed. A separate maintenance pass
   (`outboxMaintenancePass`) reclaims crashed-worker rows and samples
   the backlog gauge.

The producer subscription never publishes to Kafka directly; the
outbox row is the durable handoff. This places `attempts`,
`last_error`, and per-row status into first-class SQL and gives
operators a single place to inspect what is pending.

## The escape hatch

Sagas and process managers that need to emit an integration event
without an intermediate domain event can call `enqueueIntegrationEventTx`
inside the transaction passed to `runCommandWithSqlEvents`:

```haskell
runCommandWithSqlEvents options validatedEventStream targetStream cmd $ \_events _appendResult -> do
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

`publishClaimedOutbox` hands a claimed batch to the publish callback in
claim order. For ordered policies, the callback must not report a later
same-key record as delivered after reporting an earlier same-key record
failed. If a row fails, keiro marks the successful prefix sent, marks
the failed pivot retryable or dead, and returns the suffix to retryable
state without consuming an attempt.

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

## Maintenance

Schedule `outboxMaintenancePass defaultMaintenanceOptions metrics` on a
separate, slower interval than publish passes. Maintenance owns two
tasks that are deliberately off the publish hot path:

- reclaim rows left in `publishing` after a crashed worker, using
  `publishingTimeout`
- record the `keiro.outbox.backlog` gauge

Use `sampleOutboxBacklog metrics` when you only want to record the
backlog gauge without running the crash-reclaim sweep.

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

The outbox table is created by `keiro-migrate` from the native Keiro component's
embedded `0002-keiro-outbox.sql` migration:

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

The enqueue `ON CONFLICT` target is `(source, message_id)`, so a retried
attempt that reuses the same `messageId` is idempotent at the row level —
re-inserting is a no-op. (The canonical producer path mints a fresh
`messageId` per attempt, so reuse the message id explicitly when you want
this de-duplication.)

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
          , schemaReference = Just SchemaReference
              { registry = Nothing
              , subject = Just "billing.orders.v1.OrderSubmitted"
              , version = Nothing
              , schemaId = Nothing
              , fingerprint = Nothing
              }
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
    (\rows -> traverse publishOne rows)
    defaultPublishOptions
    Nothing
  where
    publishOne row = do
      outcome <- liftIO (kafkaProduce (outboxRowToKafkaRecord row))
      pure (row ^. #outboxId, outcome)

-- 3. A slower maintenance worker reclaims crashed publishers and samples backlog.
runOutboxMaintenance :: Eff es ()
runOutboxMaintenance = void $
  outboxMaintenancePass
    defaultMaintenanceOptions
    Nothing
```

A future schema-registry adapter populates `schemaReference` (and may
swap `contentType` to Avro or Protobuf). The envelope already carries
every field a registry needs, so no further migration is required.
