# Integration Events With Kafka

This guide describes the canonical topology for exchanging integration
events between two keiro-backed bounded contexts over Kafka, and the
operational guarantees that come with it. The mechanics are
machine-tested by the cross-context section of `test/Main.hs` (the
"Keiro cross-context Kafka integration" describe block), which runs
two isolated ephemeral Postgres instances joined by an in-process
Kafka simulator.

For the broker-backed integration test (a real Redpanda or Kafka
instance), see [Operational follow-ups](#operational-follow-ups).

## The topology

```
                    Ordering bounded context                                 Billing bounded context
  ┌──────────────────────────────────────────────────┐                ┌──────────────────────────────────────────────┐
  │                                                  │                │                                              │
  │  command  → private domain event                 │                │  Kafka consumer                              │
  │             (kiroku, local Postgres A)           │                │   │                                          │
  │                                                  │                │   ▼                                          │
  │  ▼                                               │                │  Keiro.Inbox.Kafka.integrationEventFromKafka │
  │  IntegrationProducer subscription                │                │   │                                          │
  │   │  reads RecordedEvent, mints messageId,       │                │   ▼                                          │
  │   │  builds IntegrationEvent, writes ONE         │                │  runInboxTransaction                         │
  │   │  keiro_outbox row in same txn as checkpoint  │                │   │                                          │
  │   ▼                                              │                │   ▼                                          │
  │  keiro_outbox                                    │                │  local handler                               │
  │   │                                              │                │   (kiroku, local Postgres B)                 │
  │   ▼                                              │                │                                              │
  │  publishClaimedOutbox worker                     │                │                                              │
  │   │  FOR UPDATE SKIP LOCKED + per-key            │                │                                              │
  │   │  head-of-line + auto-dead-letter             │                │                                              │
  │   ▼                                              │                │                                              │
  │  Kafka.Effectful.Producer.produceMessageSync ─── │ ─── Kafka ─── ►│                                              │
  └──────────────────────────────────────────────────┘                └──────────────────────────────────────────────┘
```

Each context owns its database, its event streams, and its read models.
The only shared state is the Kafka topic.

## Step-by-step

### 1. Command commits a private domain event

The ordering service handles `SubmitOrder` through `runCommand`. The
command appends a private `OrderSubmittedLocal` event to a kiroku
stream in the ordering Postgres database. Nothing public has happened
yet.

### 2. IntegrationProducer maps it to a public envelope

A checkpointed subscription reads each new private event. The
`IntegrationProducer.mapEvent` mapper translates the private event
into an `IntegrationEventDraft` with a stable public contract:

```haskell
ordersIntegrationProducer :: IntegrationProducer OrderEvent
ordersIntegrationProducer = IntegrationProducer
  { name = "ordering-integration-producer"
  , source = "ordering"
  , messageIdPrefix = "msg"
  , mapEvent = \recorded -> \case
      OrderSubmittedLocal orderId quantity ->
        Just IntegrationEventDraft
          { destination = "billing.orders.v1"
          , key = Just orderId
          , eventType = "OrderSubmitted"
          , schemaVersion = 1
          , contentType = ApplicationJson
          , schemaReference = Nothing  -- or registry metadata
          , sourceEventId = Just (recorded ^. #eventId)
          , sourceGlobalPosition = Just (recorded ^. #globalPosition)
          , payloadBytes = Lazy.toStrict (Aeson.encode (OrderSubmittedPayload orderId quantity))
          , occurredAt = recorded ^. #createdAt
          , causationId = Nothing
          , correlationId = Nothing
          , traceContext = Nothing
          , attributes = Nothing
          }
      _ -> Nothing
  }
```

The mapper mints `messageId` as a TypeID-shaped UUIDv7 *when the
outbox row is written*. The id is stable across publish retries
because it lives on the row; Kafka topic/partition/offset are delivery
metadata and are **not** the canonical dedupe key.

### 3. publishClaimedOutbox drains the row into Kafka

A separate worker calls `publishClaimedOutbox` periodically. The
worker claims pending rows with `FOR UPDATE SKIP LOCKED` and the
configured `OrderingPolicy` (default `PerKeyHeadOfLine`), calls the
caller-supplied publish function (`Kafka.Effectful.Producer.produceMessageSync`
in production), and marks each row sent, retryable, or dead.

### 4. The Billing consumer decodes and dedupes

The consuming service reads from the topic with
`shibuya-kafka-adapter` (or any other Kafka consumer). Each record
becomes a `KafkaInboundRecord`, then `integrationEventFromKafka`
reconstructs the EP-19 envelope from headers and payload bytes.
`runInboxTransaction` records the receipt in `keiro_inbox` and runs
the local handler in the same Postgres transaction.

If Kafka redelivers the same message (consumer rebalance, offset
retry, producer republish), the inbox sees the existing
`(source, dedupe_key)` row and returns `InboxDuplicate` — the handler
runs at most once.

## Guarantees, in plain language

The end-to-end story is **at-least-once transport with idempotent
receive**.

- **Outbox** gives durable at-least-once publish. The same outbox row
  may be sent to Kafka more than once if the worker crashes between
  publish and marking sent. Both attempts carry the same `messageId`.
- **Per-key head-of-line ordering (default)** preserves per-partition
  Kafka order for events sharing a `message_key`. A row that fails
  blocks only its key, not the whole publisher.
- **Auto dead-letter** transitions a row to `status = 'dead'` after
  `maxAttempts` consecutive failures so a permanently-broken row stops
  freezing its key. Operators see stuck messages with
  `SELECT * FROM keiro_outbox WHERE status = 'dead';`.
- **Kafka** gives at-least-once delivery and per-partition ordering
  for records sharing a key. It does not give cross-key order; it does
  not give exactly-once across topics or services.
- **Inbox** gives idempotent receive within the retention window,
  keyed on `(source, dedupe_key)` where `dedupe_key` is derived from
  the chosen `InboxDedupePolicy`. A redelivery after retention GC is
  treated as new.

The combination does *not* promise an exactly-once cross-service
distributed transaction. No single transaction can cover both Postgres
and Kafka. The promise instead is: the receiving local Postgres effect
is observed at most once per `(source, dedupe_key)` within the
retention window.

## When to change the default ordering policy

`OrderingPolicy.PerKeyHeadOfLine` is the safe default. Choose
otherwise only with intent:

- `PerSourceStream` — ordering matters across keys (rare). One stuck
  row blocks every later row in the same source. Use when the producer
  context guarantees cross-aggregate ordering is part of the contract.
- `StopTheLine` — correctness requires manual review on every failure.
  Use for compliance- or safety-critical streams where an operator
  must clear each stuck row before traffic resumes.
- `BestEffort` — failed rows do not block later rows. Use only when
  the published events have no per-key or causal relationship. Skipping
  a failed row and publishing a later row with the same Kafka key
  silently violates per-partition order.

## Choosing inbox retention

The inbox table grows with every received message.
`garbageCollectCompleted keepFor now` deletes completed rows older
than `keepFor`. The retention window is the duplicate-detection
window: a redelivery that arrives later than `keepFor` is processed as
new.

Kafka itself has a default `retention.ms` of 7 days. 30 days is a
safe default for an inbox: it absorbs Kafka redelivery from a fresh
consumer group plus typical operator-led replay scenarios. Tune up if
the broker keeps messages longer than that.

Failed rows are not garbage-collected; they remain for operator
inspection until manually resolved.

## Operational follow-ups

- **Broker-backed integration test.** The cross-context test in
  `test/Main.hs` uses an in-process Kafka simulator (an MVar acting as
  a topic) so the suite runs without librdkafka. The keiro library
  itself stays free of `hw-kafka-client` (which would otherwise pull
  in librdkafka as a system dep). To exercise the same scenario
  against a real Redpanda or Kafka broker, wire
  `Kafka.Effectful.Producer.produceMessageSync` into the `publish`
  callback and `shibuya-kafka-adapter` into the consume loop. This
  bridge lives outside the keiro library so the broker dependency is
  scoped to the deployment that uses it.
- **Schema registry.** The `IntegrationEvent.schemaReference` field is
  registry-neutral. A future Avro or Protobuf adapter populates the
  field at publish time and the inbox preserves it for the consumer.
  No envelope or table migration is required.
- **Observability.** `traceparent` and `tracestate` (W3C Trace
  Context) propagate through `integrationHeaders` and are restored by
  `integrationEventFromKafka` so a downstream OpenTelemetry SDK can
  continue the trace.
