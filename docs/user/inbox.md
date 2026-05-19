# Idempotent Inbox

The `Keiro.Inbox` module guarantees that a local handler runs **at most
once** per integration event, even when Kafka redelivers the same
message. Kafka redelivery is not unusual — it happens on consumer
crash, rebalance, offset retry, or producer republish from the
[outbox][outbox] — and an inbox is the receiving side of the same
at-least-once contract.

[outbox]: ./outbox.md

## The transactional wrapper

`runInboxTransaction` runs in **one Postgres transaction**:

1. Compute the dedupe key from the chosen policy.
2. Try to insert a new `keiro_inbox` row with `status = 'processing'`.
3. If the insert succeeded → run the handler, then update the row to
   `completed`, all in this transaction.
4. If the insert conflicted on `(source, dedupe_key)` → look up the
   existing row and return `InboxDuplicate`, `InboxInProgress`, or
   `InboxPreviouslyFailed` based on its status.

If the handler raises an exception or calls `Tx.condemn`, the whole
transaction rolls back including the inbox row. The next delivery sees
no row and starts fresh. This is the smallest correctness-preserving
shape: there is no window between "we accepted this message" and "we
applied its effects".

## Dedupe policies

```haskell
data InboxDedupePolicy
  = PreferIntegrationMessageId   -- default
  | PreferSourceEventIdentity
  | KafkaDeliveryIdentity
  | CustomDedupeKey !Text
```

`PreferIntegrationMessageId` uses the `messageId` minted at the
producer's outbox (EP-20). Because the outbox row keeps that id stable
across publish retries, this is the natural primary dedupe key for
Kafka-delivered integration events.

`PreferSourceEventIdentity` uses the `sourceEventId` (or
`sourceGlobalPosition` as fallback) of the private event that produced
this integration event. Choose this when a producer may republish the
same logical fact with a fresh `messageId` (for example, after a
schema upgrade) and you want those republishes collapsed to one
handler run.

`KafkaDeliveryIdentity` uses `topic:partition:offset`. Use only when
the envelope carries neither `messageId` nor source identity — this
loses dedupe across producer retries because the same logical message
can land at different offsets.

`CustomDedupeKey` is the escape hatch for receivers that derive the
key from the payload or from a non-standard header. The consumer owns
collision resistance.

## Choosing a retention window

The `keiro_inbox` table grows with every received message. Garbage
collection removes completed rows older than a retention window:

```haskell
let day = 86400
deleted <- garbageCollectCompleted (30 * day) now
```

The retention window defines the duplicate-detection window: a
redelivery that arrives *after* a row has been deleted is processed as
new. Choose a window that exceeds the maximum delivery delay you
tolerate from the broker — Kafka can hold pending messages on a
partition for as long as `retention.ms` (default 7 days). 30 days is a
safe default for most consumers.

Failed rows are not deleted by `garbageCollectCompleted`; they remain
in the table for operator inspection until manually resolved.

## The Kafka decoder

`Keiro.Inbox.Kafka.integrationEventFromKafka` reconstructs an
`IntegrationEvent` from a transport-neutral `KafkaInboundRecord`:

```haskell
data KafkaInboundRecord = KafkaInboundRecord
  { topic      :: !Text
  , partition  :: !Int64
  , offset     :: !Int64
  , key        :: !(Maybe Text)
  , payload    :: !ByteString
  , headers    :: ![(Text, Text)]
  , receivedAt :: !UTCTime
  }
```

The keiro library does not depend on `hw-kafka-client` or
`shibuya-kafka-adapter`. EP-22 bridges from the broker library's record
shape into `KafkaInboundRecord` inside its own dependency scope.

Required envelope headers — `keiro-message-id`, `keiro-source`,
`keiro-destination`, `keiro-event-type`, `keiro-schema-version`,
`content-type` — produce `MissingHeader` errors when absent. Malformed
numeric or UUID headers produce `InvalidIntHeader` /
`InvalidUuidHeader`. Optional headers (schema reference, source event
id, trace context) are silently absent from the resulting envelope.

## Schema

The inbox table is created by `keiro-migrate` from
`2026-05-17-02-00-00-keiro-inbox.sql`:

```sql
CREATE TABLE keiro_inbox (
  source TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  message_id TEXT,
  source_event_id UUID,
  source_global_position BIGINT,
  destination TEXT,
  event_type TEXT,
  schema_version BIGINT,
  content_type TEXT NOT NULL,
  -- … schema reference, trace, kafka diagnostics …
  payload_bytes BYTEA NOT NULL,
  status TEXT NOT NULL DEFAULT 'processing',
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  last_error TEXT,
  PRIMARY KEY (source, dedupe_key)
);
```

The primary key is `(source, dedupe_key)`, so dedupe is scoped per
producing bounded context. Two different services can mint the same
`messageId` without colliding in the inbox.

## A worked example

```haskell
import Keiro.Inbox
import Keiro.Inbox.Kafka (KafkaInboundRecord (..), integrationEventFromKafka)

handleBillingMessage :: KafkaInboundRecord -> Eff es ()
handleBillingMessage record = case integrationEventFromKafka record of
  Left err -> liftIO (logDecodeFailure err)
  Right (event, kafkaRef) -> do
    result <- runInboxTransaction
      PreferIntegrationMessageId
      event
      (Just kafkaRef)
      runBillingHandler
    case result of
      Right (InboxProcessed ())     -> pure ()
      Right InboxDuplicate          -> liftIO (logDuplicate event)
      Right InboxInProgress         -> liftIO (logRetryLater event)
      Right (InboxPreviouslyFailed err)
                                    -> liftIO (logPermanentFailure event err)
      Left (DedupePolicyUnsatisfied policy)
                                    -> liftIO (logBadPolicy policy)
  where
    runBillingHandler :: IntegrationEvent -> Tx.Transaction ()
    runBillingHandler ev = case decodeJsonIntegrationEvent ev of
      Left e -> Tx.condemn  -- malformed payload aborts; row rolls back
      Right (OrderSubmitted oid qty) ->
        Tx.statement (oid, qty) reserveCreditStmt
```

The handler is just a `Tx.Transaction a` — anything that can run inside
a Postgres transaction works. The inbox guarantees that the handler
runs at most once per `(source, dedupe_key)`, even under the wildest
Kafka redelivery pathology.
