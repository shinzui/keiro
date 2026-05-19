---
id: 21
slug: implement-the-idempotent-inbox
title: "Implement the idempotent inbox"
kind: exec-plan
created_at: 2026-05-17T19:38:22Z
intention: "intention_01krvpz783etasqe2n8q5ea2m6"
master_plan: "docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md"
---

# Implement the idempotent inbox

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a keiro application can consume integration events from Kafka and guarantee that the local handler runs at most once for each retained dedupe key in `keiro_inbox`. Kafka may redeliver a message after a crash, rebalance, or offset retry, and the producer may republish the same public integration event after a crash. The inbox makes that safe by recording a stable external identity in the receiving bounded context's database before running the handler in the same transaction.

The behavior is visible in tests without Kafka: processing the same integration event twice increments a local counter or inserts a local row only once, and the second delivery returns a duplicate result rather than rerunning the handler.


## Progress

- [x] Add `keiro_inbox` codd migration and runtime development initializer. (2026-05-18)
- [x] Implement `Keiro.Inbox.Schema` storage functions for begin/complete/fail/lookup/GC. (2026-05-18)
- [x] Implement `Keiro.Inbox` transactional handler wrapper using EP-19 `IntegrationEvent`. (2026-05-18) — `runInboxTransaction` + `runInboxTransactionWithKey`, single Postgres transaction shared with the handler.
- [x] Add Kafka consumer decoding helper for `shibuya-kafka-adapter` `Ingested (Maybe ByteString)`. (2026-05-18) — `Keiro.Inbox.Kafka.integrationEventFromKafka` takes a transport-neutral `KafkaInboundRecord` so keiro itself stays free of `hw-kafka-client` / `shibuya-kafka-adapter`. EP-22 bridges to those broker types inside its own dependency scope.
- [x] Add duplicate, failure, and retention tests. (2026-05-18) — seven inbox tests + two `Keiro.Inbox.Kafka` decode tests in `test/Main.hs`.
- [x] Update docs and migration tests. (2026-05-18) — `docs/user/inbox.md` added and linked from the guide index; `keiro_inbox` added to `expectedTables` in `keiro-migrations/test/Main.hs`.


## Surprises & Discoveries

- The TH-driven `embedDir` in `Keiro.Migrations` caches the migration manifest at compile time. Adding a new SQL migration without re-running cabal's library compile silently keeps the old manifest. Resolved by deleting the keiro-migrations build output and forcing a recompile after the new SQL file was in place. (2026-05-18)
- `INSERT … ON CONFLICT DO NOTHING RETURNING TRUE` returns zero rows on conflict, not `FALSE`, so the hasql decoder needs `fromMaybe False . rowMaybe` rather than a single-row decoder. (2026-05-18)
- Inbox row reconstruction does not need to preserve the partition `key` separately, since the `kafka_topic/partition/offset` columns already carry per-delivery routing. The reconstructed `IntegrationEvent.key` field is set to `Nothing` for rows fetched from the inbox; receivers that need the original key can re-read it from the payload or store it on a domain-specific projection.


## Decision Log

- Decision: Default dedupe key is `(source, message_id)`. Source event identity and source global position are supported as alternate policies a consuming service can opt into.
  Rationale: EP-19 / EP-20 mint `message_id` as a UUIDv7 at outbox enqueue and keep it stable across publish retries, so `(source, message_id)` is the natural primary dedupe key. `sourceEventId` and `sourceGlobalPosition` remain useful when the consumer wants to suppress reissued public events that share an upstream cause (e.g. schema-upgrade republishes), or when a producer can republish the same logical event with a fresh `message_id`. Kafka topic/partition/offset is delivery metadata only and is recorded on the row for diagnostics but is not the canonical dedupe key, because retries from the outbox produce different offsets for the same logical message.
  Date: 2026-05-18.

- Decision: Record the inbox row before running the handler and complete it in the same transaction as the handler's local writes.
  Rationale: This gives the receiving bounded context one local atomic boundary. A duplicate that arrives after commit sees the completed row and does not rerun the handler.
  Date: 2026-05-17.


## Outcomes & Retrospective

- The inbox is implemented as four modules mirroring the outbox layout:
  `Keiro.Inbox.Types`, `Keiro.Inbox.Schema`, `Keiro.Inbox`, and
  `Keiro.Inbox.Kafka`.
- `runInboxTransaction` runs in a single Postgres transaction with the
  caller-supplied handler. On `Tx.condemn` or any exception, the inbox
  row insert and the handler's writes roll back together; the next
  delivery sees no row and tries fresh.
- Four dedupe policies are exposed: `PreferIntegrationMessageId`
  (default; matches the outbox-minted UUIDv7), `PreferSourceEventIdentity`
  (falls back to global position), `KafkaDeliveryIdentity`
  (topic:partition:offset), and `CustomDedupeKey` for caller-derived
  keys.
- `garbageCollectCompleted` deletes completed rows older than a
  caller-supplied retention window. Failed rows are not collected; they
  remain for operator review.
- `Keiro.Inbox.Kafka.integrationEventFromKafka` reconstructs the EP-19
  envelope from `[(Text, Text)]` headers plus payload bytes. EP-22's
  integration tests bridge the broker library's header type to this
  shape inside their own dependency scope.
- Nine new tests in `test/Main.hs` (seven inbox + two
  `Keiro.Inbox.Kafka`) cover the duplicate, alternate-policy, custom
  Kafka identity, missing-field, rollback, and retention scenarios.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. The inbox is the receiving-side counterpart to the outbox in `docs/plans/20-implement-the-durable-outbox.md`, and both consume the integration-event contract in `docs/plans/19-define-the-integration-event-contract.md`.

The existing migration package is `keiro-migrations/`. Add a new forward migration for `keiro_inbox` rather than editing the bootstrap migration from `docs/plans/16-adopt-codd-for-database-migrations.md`.

The existing read-model and timer schema modules show the repository style for Postgres helpers. `src/Keiro/ReadModel/Schema.hs` has simple metadata transitions through `Kiroku.Store.Transaction.runTransaction`. `src/Keiro/Timer/Schema.hs` has status values and claim/update helpers. The inbox should follow those patterns in `src/Keiro/Inbox/Schema.hs`.

Kafka consumption is provided by `shibuya-kafka-adapter`, found with Mori at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. Its public `Shibuya.Adapter.Kafka.kafkaAdapter` returns an `Adapter es (Maybe ByteString)`. Each `Ingested` has a Shibuya `Envelope` whose payload is the Kafka value and whose `messageId` is topic-partition-offset. The keiro inbox should decode the EP-19 integration event from the payload and dedupe on `(source, integration-event message_id)` by default. Alternate policies can fall back to source event identity or source global position, and Kafka topic/partition/offset is recorded on the row for diagnostics but is not the canonical dedupe key.

The prior consumer design in `/Users/shinzui/Keikaku/business-application-applications/docs/ebook-principles/service-architecture-blueprint.md` §10 says a consuming service translates foreign integration events into local commands, local read-model updates, or local queue jobs. The foreign bounded-context type should not leak throughout the service. This plan should make that translation boundary explicit: the inbox gives the handler a decoded public integration event, and the handler converts it into local concepts.

EP-20's publisher worker enforces per-key head-of-line blocking, so for any single `message_key` the Kafka topic receives events in the same order they were produced. The inbox therefore does not need to re-order or buffer to recover per-key sequence — it only needs to suppress duplicate redeliveries of the same `(source, message_id)`. If the consuming service genuinely needs cross-key ordering (rare), that's a consumer-side concern and not solved by this plan.


## Plan of Work

Milestone 1 adds the schema and migration. Create `keiro-migrations/sql-migrations/2026-05-17-02-00-00-keiro-inbox.sql` or the next timestamp after EP-20's outbox migration. Create `src/Keiro/Inbox/Schema.hs` and expose it. The table should track processing state and make duplicate detection cheap:

```sql
CREATE TABLE IF NOT EXISTS keiro_inbox (
  source TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  message_id TEXT,
  source_event_id UUID,
  source_global_position BIGINT,
  kafka_topic TEXT,
  kafka_partition BIGINT,
  kafka_offset BIGINT,
  content_type TEXT NOT NULL,
  schema_registry TEXT,
  schema_subject TEXT,
  schema_version_ref BIGINT,
  schema_id BIGINT,
  schema_fingerprint TEXT,
  status TEXT NOT NULL DEFAULT 'processing',
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  last_error TEXT,
  payload_bytes BYTEA NOT NULL,
  payload_json JSONB,
  attributes JSONB,
  PRIMARY KEY (source, dedupe_key)
);

CREATE INDEX IF NOT EXISTS keiro_inbox_received_idx
  ON keiro_inbox (received_at);
```

Status values should be `processing`, `completed`, and `failed`. The retention GC can delete old `completed` rows after a configurable window; default documentation should recommend 30 days, matching the research note. `payload_bytes` is canonical; `payload_json` is optional for JSON consumers and diagnostics. The nullable schema columns preserve registry metadata from EP-19 without requiring a registry client in v1.

Milestone 2 adds storage and transaction semantics. Implement a function that tries to insert a processing row and reports whether this delivery is new or duplicate. Then provide a higher-level wrapper:

```haskell
runInboxTransaction
  :: IntegrationEvent
  -> (IntegrationEvent -> Tx.Transaction a)
  -> Eff es (Either InboxError (InboxResult a))
```

The wrapper should run in one `Kiroku.Store.Transaction.runTransaction` call. On a new message, insert the inbox row, run the handler transaction, mark completed, and return `InboxProcessed a`. On an already completed message, do not run the handler and return `InboxDuplicate`. If the previous status is `processing` or `failed`, choose a clear policy during implementation: either allow retry by taking ownership of stale rows after a timeout, or surface `InboxInProgress` / `InboxPreviouslyFailed` so the Kafka handler can retry later. Record the choice in the Decision Log.

The dedupe helper should expose a policy type:

```haskell
data InboxDedupePolicy
  = PreferIntegrationMessageId
  | PreferSourceEventIdentity
  | KafkaDeliveryIdentity
```

The default for Kafka integration events is `PreferIntegrationMessageId`, because EP-19 / EP-20 mint `messageId` as a UUIDv7 at outbox enqueue and keep it stable across publish retries. `PreferSourceEventIdentity` is available for services that want to suppress reissued public events sharing an upstream cause (e.g. schema-upgrade republishes), and `KafkaDeliveryIdentity` is the fallback only when neither `messageId` nor source position is available. The chosen key is recorded in the `dedupe_key` column; Kafka topic/partition/offset is stored on the row for diagnostics regardless.

Milestone 3 adds the Kafka-facing helper. Create `src/Keiro/Inbox.hs` and, if Kafka dependencies are needed, `src/Keiro/Inbox/Kafka.hs`. The Kafka helper should accept `Ingested es (Maybe ByteString)`, reconstruct the EP-19 `IntegrationEvent` from Kafka payload bytes plus headers, run `runInboxTransaction`, and map results to Shibuya `AckDecision`: processed and duplicate return `AckOk`; decode failure returns `AckDeadLetter`; transient database failure should surface as `AckRetry` if the adapter semantics make retry useful, or `AckHalt` with an explicit reason if continuing would commit offsets incorrectly. V1 JSON handlers can call `decodeJsonIntegrationEvent`, but the inbox must store and pass through payload bytes and schema reference metadata even when it cannot decode the business payload itself.

Milestone 4 adds tests. Storage tests should not require Kafka. Add a fake handler that inserts into a test table keyed by `message_id`, process the same event twice, and assert one local row plus one inbox row. Add a failure test where the handler transaction aborts and the inbox row does not claim completion. Add a GC test for old completed rows.

Milestone 5 updates documentation. Explain that the inbox lives in the receiving bounded context's database, not the publisher's database, and that retention length defines the duplicate-detection window.


## Concrete Steps

Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori show --full
mori registry show shinzui/shibuya-kafka-adapter --full
```

After adding schema, modules, and tests:

```bash
cabal build keiro
cabal build keiro-migrations
cabal test keiro-migrations-test
cabal test keiro-test
```

The migration test should include:

```text
keiro_inbox
```

The inbox duplicate test should demonstrate one handler side effect after two deliveries of the same `source` and `message_id`.


## Validation and Acceptance

Acceptance requires:

- `keiro_inbox` is present after `runAllKeiroMigrations` on a fresh database.
- A new integration event runs the supplied handler and records status `completed`.
- A duplicate integration event with the same `(source, message_id)` returns a duplicate result and does not run the supplied handler, even if the Kafka delivery offset differs.
- Selecting `PreferSourceEventIdentity` causes two integration events with distinct `message_id` values but the same `sourceEventId` to deduplicate to one handler run.
- A malformed Kafka payload is classified as a permanent decode failure.
- Schema reference metadata from Kafka headers is stored with the inbox row and is available to the handler for future registry-backed decoding.
- A handler failure does not mark the inbox row completed.
- A retention helper deletes old completed rows but leaves recent rows and non-completed rows alone.


## Idempotence and Recovery

The migration is forward-only. Do not rename it after applying to a shared database. If the status model changes after sharing, add a new migration. Tests should use fresh message ids or clean test-only tables so they can be rerun.

The hardest recovery case is a crash after inserting `processing` but before completing the handler. If the insert and handler are in one Postgres transaction, the row rolls back with the handler and the next delivery can try again. If implementation introduces a two-phase path for Kafka convenience, it must include stale-processing recovery before completion. Prefer the single-transaction wrapper to avoid this risk.


## Interfaces and Dependencies

Use `Keiro.Integration.Event` from EP-19, `Hasql.Transaction` for handler composition, `Kiroku.Store.Transaction.runTransaction` for the local receiving transaction, and Shibuya `AckDecision` / `Ingested` for the Kafka adapter edge. If `Keiro.Inbox.Kafka` imports `Shibuya.Adapter.Kafka`, add `shibuya-kafka-adapter` to the relevant Cabal dependency list and update `cabal.project` using the Mori-discovered source path if it is not on Hackage in this workspace.

The public surface should include:

```haskell
module Keiro.Inbox
  ( InboxDedupePolicy (..)
  , InboxStatus (..)
  , InboxResult (..)
  , InboxError (..)
  , runInboxTransaction
  , garbageCollectInbox
  )
```

If Kafka handling lives in a separate module, expose:

```haskell
module Keiro.Inbox.Kafka
  ( handleKafkaIntegrationEvent
  )
```
