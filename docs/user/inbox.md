---
type: Reference
title: Idempotent Inbox
description: Reference inbox deduplication policies and transactional handler semantics.
docId: DOC-10
tags: [keiro, inbox, idempotency, reference]
generated:
  by: human:nadeem
  at: 2026-09-18T04:05:10Z
timestamp: 2026-11-18T22:00:00Z
---

# Idempotent Inbox

`Keiro.Inbox` commits a handler's transactional SQL together with a durable
receipt keyed by source and dedupe identity. Retained completed receipts prevent
that work from committing twice on redelivery. The handler can execute again
after rollback or a transaction retry; network effects outside PostgreSQL need
their own idempotency. Kafka can redeliver after a crash, rebalance, offset
retry, or producer republish from the [outbox][outbox].

[outbox]: ./outbox.md

## The transactional wrapper

`runInboxTransaction` runs in **one Postgres transaction**:

1. Compute the dedupe key from the chosen policy.
2. Try to insert a new `keiro.keiro_inbox` row with `status = 'processing'`.
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

`PreferIntegrationMessageId` uses the opaque `messageId` selected at enqueue.
Canonical producers derive it from stable source-event coordinates, preserving
identity across both producer replay and publication retries. This is the natural
primary dedupe key for Kafka-delivered integration events.

`PreferSourceEventIdentity` uses the `sourceEventId` (or
`sourceGlobalPosition` as fallback) of the private event that produced
this integration event. Choose this when a producer may republish the
same logical fact with a new `messageId` (for example, after a deliberate
producer-name/version cutover) and you want those republishes collapsed to one
handler run.

`KafkaDeliveryIdentity` uses `topic:partition:offset`. Use only when
the envelope carries neither `messageId` nor source identity — this
loses dedupe across producer retries because the same logical message
can land at different offsets.

`CustomDedupeKey` is the escape hatch for receivers that derive the
key from the payload or from a non-standard header. The consumer owns
collision resistance.

## Choosing a retention window

The `keiro.keiro_inbox` table grows with every received message. Garbage
collection removes completed rows older than a retention window:

```haskell
let day = 86400
deleted <- garbageCollectCompleted (30 * day) now
```

The retention window defines the duplicate-detection window: a
redelivery that arrives *after* a row has been deleted is processed as
new. Choose a window that exceeds the maximum delivery delay you
tolerate from the broker, producer replay, retained dead letters, and operator
redrive. Derive the window from those policies rather than assuming that one
broker retention setting covers every source of replay.

Failed rows are not deleted by `garbageCollectCompleted`; they remain
in the table for operator inspection until manually resolved.

## Delegated idempotence

`runInboxDelegated`, `runInboxDelegatedWithRetries`, and
`runInboxDelegatedBatch` are the no-`Store` alternative for consumers whose
downstream state transition already records the durable receipt. They compute
the same dedupe key, pass it to the handler, and write **no** `keiro.keiro_inbox`
row; the handler reports `DelegatedFresh a` or `DelegatedDuplicate`, which map
to `InboxProcessed` and `InboxDuplicate`. `runInboxDelegatedWithRetries` takes
a caller-owned `DelegatedRetryContext` (built with `mkDelegatedRetryContext`).

`Keiro.Inbox.Delegated` supplies the safe handler adapters:
`delegatedEventId` derives the deterministic first-event receipt,
`delegatedCommand` protects one atomic command append with it, and
`delegatedFromPMCommand` adapts one deterministic process-manager dispatch.
Both reject failed commands and commands that append no event with
`DelegatedCommandError`. When to choose delegation, and what inspection surface
it gives up, is covered in
[Choosing inbox idempotence ownership](integration-events.md#choosing-inbox-idempotence-ownership).

### Typed no-op receipts

`delegatedDomainCommand` is the third adapter. It is for a command that is
sometimes a legitimate no-op, for example a delivery status that never moves
backwards. Its callback runs one typed domain command (`runDomainCommand` or a
`WithSql` variant) and returns its `DomainCommandOutcome`. A
`DelegatedNoOpReceipt` names the consumer, operation, dedupe key, delivered
envelope, Kafka reference and row persistence:

```haskell
handler dedupe event =
  delegatedDomainCommand receipt defaultRunCommandOptions (streamName target) (\prepared ->
    runDomainCommand prepared deliveryHandler target (RecordOutcome outcome))
    >>= either (throwError . DeliveryRefused) pure
  where
    receipt = DelegatedNoOpReceipt
      { consumer = "reputation", operation = "record-outcome", dedupeKey = dedupe
      , event, kafka = Nothing, persistence = PersistFullEnvelope }
```

The guarantee:

- An accepted command commits its deterministic marker
  (`delegatedEventId consumer source dedupeKey target operation`) as its first
  event, exactly as with `delegatedCommand`. It writes no inbox row.
- A typed no-op qualifies only when the caller guarantees that replaying that
  delivery remains a no-op across every later reachable state. This includes
  retries after a crash and replays after retention. The callback must use the
  supplied options and target, run one domain command, and keep every protected
  effect inside its append. A silent decision performs no side effects.
- A qualifying no-op is fresh (`DelegatedDomainNoOp`) only after the adapter
  commits a completed `keiro.keiro_inbox` row at the envelope `source` and the
  reserved key `delegatedNoOpReceiptKey marker`, which is
  `keiro/inbox-delegated-noop/1:<marker uuid>`. The key is scoped by consumer,
  target and operation, so an ordinary table-intake row for the raw message id
  never answers for it.
- A matching marker in the target stream or a matching completed row proves a
  duplicate, and the callback is not invoked. A competing marker takes
  precedence when dispatch observes the no-op or rejection left by that append:
  the adapter rechecks the marker after both decisions.
- A crash after the silent decision and before the receipt commit leaves the
  delivery unacknowledged, and a retry evaluates the command again. Set
  retention beyond the required redelivery horizon. Once
  `garbageCollectCompleted` removes a row, a later replay may report fresh
  again and must still append nothing.
- A typed rejection (`DelegatedDomainRejected`), an unconfirmed command
  failure, an existing non-completed row (`DelegatedNoOpReceiptUnavailable`), a
  missing receipt after an insert conflict (`DelegatedNoOpReceiptLost`, which
  is retryable), and an untyped zero-event success provide no basis for
  acknowledgement. They return `Left`; store and commit failures propagate
  through the store's error channel. Keep the rejection payload in the typed
  value and out of logs and telemetry.

A service adopting this handler needs `SELECT` on `keiro.keiro_inbox` for every
marker miss and `INSERT` for every no-op. Before enabling it, check that no other
writer for the source can use the `keiro/inbox-delegated-noop/1:` key prefix and
that no historical rows already occupy it.

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

The payload decoder is ordinary `FromJSON`, so cross-service schema rollout is
manual. See
[Deploy Ordering](deploy-ordering.md#7-coordinate-integration-contracts-manually)
before changing a producer or consumer shape.

## Schema

The inbox table is created by `keiro-migrate` from the native Keiro component's
embedded `0003-keiro-inbox.sql` migration and extended by later migrations.
This excerpt omits envelope fields; the crash-recovery migration also adds
`attempt_count` for bounded failure accounting:

```sql
CREATE TABLE keiro.keiro_inbox (
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
  attempt_count BIGINT NOT NULL DEFAULT 0,
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
      Nothing                      -- Maybe KeiroMetrics
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
