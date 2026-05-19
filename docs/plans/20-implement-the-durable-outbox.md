---
id: 20
slug: implement-the-durable-outbox
title: "Implement the durable outbox"
kind: exec-plan
created_at: 2026-05-17T19:38:22Z
intention: "intention_01krvpz783etasqe2n8q5ea2m6"
master_plan: "docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md"
---

# Implement the durable outbox

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a keiro application has a first-class outbox for outgoing integration work and a Kafka producer-subscription path that matches the prior cross-bounded-context design. The canonical pipeline has three stages: (1) a command commits a private domain event to the local event store; (2) a checkpointed service-owned producer subscription reads each durable private event, mints an application-level `message_id` (UUIDv7), maps the event to a public `IntegrationEvent`, and writes one `keiro_outbox` row in the same Postgres transaction that advances its checkpoint; (3) a separate publisher worker claims rows with `FOR UPDATE SKIP LOCKED`, publishes to Kafka, and marks each row sent or failed. The producer subscription does not publish to Kafka directly — the outbox row is the durable handoff between "we decided to publish this" and "we actually published this." If the publisher crashes after Kafka acknowledges the publish but before the row is marked sent, the retry may republish the same payload with the same `message_id`, and the receiving inbox is responsible for deduplication.

Inline outbox enqueue from `runCommandWithSqlEvents` is supported as an escape hatch for sagas, process managers, and command paths that need to emit an integration event without an intermediate private domain event. It is not the canonical Kafka-integration path.

The publisher worker enforces **per-key head-of-line blocking** by default. The claim query refuses to claim a row whose `(source, message_key)` has an earlier non-terminal sibling. Rows with `message_key IS NULL` bypass the block (Kafka does not promise cross-key order for null-keyed records). A row that fails `max_attempts` consecutive times (default 10) transitions to a terminal `dead` status, stops blocking its key, and remains in the table for operator inspection. This preserves per-partition Kafka ordering for the common `message_key = aggregate_id` pattern, contains blast radius to one aggregate at a time, and prevents a permanently-broken row from freezing its key forever.

The behavior is visible in tests: a command or transactional helper inserts an outbox row, a claim query locks it with `FOR UPDATE SKIP LOCKED`, a fake publisher marks it sent, and a retry test shows failed rows stay claimable without losing payload or identity.


## Progress

- [ ] Add `keiro_outbox` codd migration and runtime development initializer.
- [ ] Implement `Keiro.Outbox.Schema` storage functions for enqueue, claim, mark sent, mark failed, and lookup.
- [ ] Implement `Keiro.Outbox` public helpers that enqueue `IntegrationEvent` values from command transactions when a saga/process-manager flow needs the inline escape hatch.
- [ ] Implement the canonical producer-subscription helper that mints `message_id`, maps durable private recorded events to public `IntegrationEvent` values, and writes one outbox row per mapped event in the same transaction that advances its checkpoint.
- [ ] Implement the publisher worker that claims outbox rows with `FOR UPDATE SKIP LOCKED` *plus* per-key head-of-line blocking, converts each row to a Kafka `ProducerRecord`, publishes synchronously via `kafka-effectful`, and marks the row sent, failed (retryable), or dead (terminal after `max_attempts`).
- [ ] Add storage and worker tests, including retry, `SKIP LOCKED` behavior, per-key head-of-line ordering, auto-dead-letter after `max_attempts`, and a subscription test proving checkpoint+outbox-insert atomicity.
- [ ] Update user docs and migration tests.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Mark sent only after Kafka acknowledges publish.
  Rationale: Marking sent before publish risks losing a committed integration event. Marking after publish can duplicate on crash, but EP-21's inbox is explicitly designed to handle duplicates.
  Date: 2026-05-17.

- Decision: Use `FOR UPDATE SKIP LOCKED` for outbox claiming.
  Rationale: It matches the existing timer claim style in `src/Keiro/Timer/Schema.hs` and allows multiple publisher workers to drain the table concurrently without claiming the same row.
  Date: 2026-05-17.

- Decision: Canonical publisher pipeline is **subscription → outbox → worker**. The producer subscription writes one outbox row per mapped private event in the same transaction that advances its checkpoint; the worker is the only stage that talks to Kafka. The subscription does not publish to Kafka directly.
  Rationale: A bare publishing subscription with a checkpoint is itself a transactional outbox, but a single checkpoint cursor cannot park a poison message — one unpublishable event blocks every event behind it. A `keiro_outbox` row carries `attempts`, `last_error`, and status per message, supports per-row DLQ, makes "what is pending to Kafka right now?" a first-class SQL query, and gives sagas a place to enqueue out-of-band integration events. Inline enqueue via `runCommandWithSqlEvents` is preserved as an escape hatch but is not the canonical Kafka path.
  Date: 2026-05-18.

- Decision: The producer subscription mints `message_id` as a UUIDv7 (or equivalent time-ordered UUID) when it writes the outbox row. `message_id` is independent of `sourceEventId`/`sourceGlobalPosition`, both of which are persisted as their own columns and headers.
  Rationale: Minting at outbox enqueue keeps `message_id` stable across publish retries (the row keeps its id), time-orders ids for index locality, and allows one source event to fan out to multiple integration events with distinct ids. Storing `sourceEventId` and `sourceGlobalPosition` alongside preserves traceability and lets a consuming service opt into source-position deduplication when it needs to suppress reissued public events that share an upstream cause.
  Date: 2026-05-18.

- Decision: Default `OrderingPolicy` is `PerKeyHeadOfLine`. The claim query excludes any row whose `(source, message_key)` has an earlier non-terminal sibling. Rows with `message_key IS NULL` bypass the block. `PerSourceStream`, `StopTheLine`, and `BestEffort` are available as explicit opt-ins via `OutboxPublishOptions`.
  Rationale: Skipping a failed row and publishing a later row with the same Kafka key silently violates per-partition ordering — consumers would see `OrderShipped` arrive before `OrderPaid` for the same order, lifecycle projections would apply updates to non-existent rows, sagas could progress past a step whose publish failed, and log-compacted topics would record a permanently lossy view. Per-key head-of-line is one `NOT EXISTS` clause backed by `keiro_outbox_head_of_line_idx`, contains blast radius to one aggregate, and matches the `message_key = aggregate_id` convention. Best-effort no-blocking is not safe as a silent default; surfacing it as an explicit option keeps the correctness cost visible.
  Date: 2026-05-18.

- Decision: A row that fails `max_attempts` consecutive times transitions to a terminal `dead` status. `max_attempts` defaults to 10 and is configurable via `OutboxPublishOptions`. Dead rows are not claimed, do not block their key, and remain in the table for operator inspection. v1 does not distinguish transient from permanent Kafka errors — every error counts an attempt.
  Rationale: Without a terminal state, a permanently-broken row (oversized payload, schema-registry reject, missing topic, unrecoverable serialization bug) blocks its key forever and forces immediate operator response on every poison message. Auto-dead-letter after a bounded number of attempts preserves liveness for healthy traffic on the same key while still surfacing the failure as a first-class operational artifact (`SELECT * FROM keiro_outbox WHERE status = 'dead'`). A retryable-vs-permanent Kafka-error taxonomy is valuable but out of scope for v1; the worker can add it later by classifying the error before calling `markOutboxFailed`.
  Date: 2026-05-18.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. The main library exposes modules in `keiro.cabal`. Database migrations live in the subpackage `keiro-migrations/`, created by `docs/plans/16-adopt-codd-for-database-migrations.md`. Its embedded SQL currently creates `keiro_snapshots`, `keiro_read_models`, and `keiro_timers` in `keiro-migrations/sql-migrations/2026-05-17-00-00-00-keiro-bootstrap.sql`. Do not edit that bootstrap migration if it has already been applied anywhere shared. Add a new timestamped forward migration for `keiro_outbox`.

The existing timer schema in `src/Keiro/Timer/Schema.hs` is the closest local pattern. It provides a runtime development initializer, a transactional insert helper `scheduleTimerTx`, and a claim query using `FOR UPDATE SKIP LOCKED`. The outbox should follow the same structure with `Keiro.Outbox.Schema` and a public `Keiro.Outbox` module.

The prior architecture design at `/Users/shinzui/Keikaku/business-application-applications/docs/ebook-principles/service-architecture-blueprint.md` §9 says cross-bounded-context Kafka events should be produced by a subscription that maps private domain events to public integration events. The local domain event is durable first; Kafka publishing happens afterward from a checkpointed subscription. That avoids making the command handler responsible for a Message DB plus Kafka dual write. This plan must implement that path explicitly.

The existing command transaction boundary is `runCommandWithSqlEvents` in `src/Keiro/Command.hs`. It runs Kiroku's append and a user-supplied `Hasql.Transaction.Transaction` inside one `runTransactionAppending` call. The outbox enqueue helper should still be usable inside that transaction for EP-3's original table-backed side-effect outbox, durable timers, and local external work. It is not the only Kafka integration producer path.

The integration-event contract is defined by `docs/plans/19-define-the-integration-event-contract.md`. This plan must not invent a second envelope shape. It consumes `Keiro.Integration.Event.IntegrationEvent`.

Kafka producer APIs come from `kafka-effectful`, found with `mori registry show shinzui/kafka-effectful --full` at `/Users/shinzui/Keikaku/bokuno/kafka-effectful`. `Kafka.Effectful.Producer` exposes `ProducerRecord`, `ProducePartition`, `TopicName`, `headersFromList`, `produceMessageSync`, and `KafkaProducer`. The outbox worker should accept a publishing function for tests and provide a Kafka-specific wrapper for production.


## Plan of Work

Milestone 1 adds storage. Create `src/Keiro/Outbox/Schema.hs` and expose it in `keiro.cabal`. Add a new codd migration such as `keiro-migrations/sql-migrations/2026-05-17-01-00-00-keiro-outbox.sql`. The table should support durable retry and concurrent claim:

```sql
CREATE TABLE IF NOT EXISTS keiro_outbox (
  outbox_id UUID PRIMARY KEY,
  message_id TEXT NOT NULL,
  source TEXT NOT NULL,
  destination TEXT NOT NULL,
  message_key TEXT,
  event_type TEXT NOT NULL,
  schema_version BIGINT NOT NULL,
  content_type TEXT NOT NULL,
  schema_registry TEXT,
  schema_subject TEXT,
  schema_version_ref BIGINT,
  schema_id BIGINT,
  schema_fingerprint TEXT,
  payload_bytes BYTEA NOT NULL,
  payload_json JSONB,
  headers JSONB NOT NULL DEFAULT '{}'::jsonb,
  attributes JSONB,
  status TEXT NOT NULL DEFAULT 'pending',
  attempt_count BIGINT NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error TEXT,
  published_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source, message_id)
);

CREATE INDEX IF NOT EXISTS keiro_outbox_pending_idx
  ON keiro_outbox (status, next_attempt_at, created_at);

CREATE INDEX IF NOT EXISTS keiro_outbox_head_of_line_idx
  ON keiro_outbox (source, message_key, created_at)
  WHERE status NOT IN ('sent', 'dead') AND message_key IS NOT NULL;
```

Use `UUID` for `outbox_id` so callers can generate deterministic ids in tests or process-manager flows. Keep `(source, message_id)` unique so a retrying command cannot enqueue the same integration event twice. Status values are `pending`, `publishing`, `sent`, `failed` (retryable), and `dead` (terminal after `max_attempts`). `payload_bytes` is the canonical payload. `payload_json` is optional and exists only for v1 JSON debugging/query ergonomics; publisher code must send `payload_bytes`. The schema columns are nullable now so v1 can run without a registry, but they reserve the storage shape for future schema-registry integration.

The `keiro_outbox_head_of_line_idx` partial index supports the per-key head-of-line claim query: it makes "does this row have an earlier non-terminal sibling with the same key?" a fast index lookup rather than a full-table scan. The partial predicate keeps the index small by excluding terminal rows.

Milestone 2 adds the Haskell storage API. Implement transactional `enqueueOutboxTx :: OutboxMessage -> Tx.Transaction ()`, `claimOutboxBatch :: ClaimOptions -> UTCTime -> Eff es [OutboxRow]`, `markOutboxSent :: OutboxId -> UTCTime -> Eff es ()`, `markOutboxFailed :: OutboxId -> Text -> UTCTime -> Eff es OutboxStatus` (which returns the row's resulting status — `failed` if still retryable, `dead` if `attempt_count >= max_attempts` after the failure), and lookup helpers for tests.

The claim query must enforce per-key head-of-line ordering. Concretely:

```sql
WITH ready AS (
  SELECT outbox_id
  FROM keiro_outbox r
  WHERE r.status IN ('pending', 'failed')
    AND r.next_attempt_at <= :now
    AND (
      r.message_key IS NULL
      OR NOT EXISTS (
        SELECT 1
        FROM keiro_outbox earlier
        WHERE earlier.source = r.source
          AND earlier.message_key = r.message_key
          AND earlier.created_at < r.created_at
          AND earlier.status NOT IN ('sent', 'dead')
      )
    )
  ORDER BY r.created_at
  LIMIT :batch_size
  FOR UPDATE SKIP LOCKED
)
UPDATE keiro_outbox
SET status = 'publishing',
    attempt_count = attempt_count + 1,
    updated_at = :now
WHERE outbox_id IN (SELECT outbox_id FROM ready)
RETURNING *;
```

Rows with `message_key IS NULL` bypass the head-of-line check because Kafka makes no cross-key order promise for null-keyed records — they get round-robined across partitions. Rows with the same `(source, message_key)` are claimed strictly in `created_at` order; a row in `pending`, `publishing`, or `failed` status blocks every later sibling on its key. Only `sent` and `dead` siblings are out of the way.

`markOutboxFailed` reads `attempt_count` and `max_attempts` (from `ClaimOptions` or a per-row column if added later — v1 uses a worker-wide configurable default), compares them, and writes either `status = 'failed'` with a new `next_attempt_at` (using a backoff function chosen during implementation) or `status = 'dead'` if the failed row has reached the cap. The Decision Log entry must record the chosen backoff curve and default `max_attempts`.

Milestone 3 adds the inline escape hatch and the canonical producer-subscription helper. Create `src/Keiro/Outbox.hs` that exports `OutboxMessage`, `OutboxRow`, `enqueueOutboxTx`, and a helper such as `runCommandWithOutbox` if it removes boilerplate around `runCommandWithSqlEvents`. The command-side surface is small and exists only to let sagas/process managers call `enqueueOutboxTx` inside the transaction supplied to `runCommandWithSqlEvents`. It is not the canonical Kafka path.

The canonical path is a producer-subscription helper whose shape is roughly:

```haskell
data IntegrationProducer e = IntegrationProducer
  { name :: !Text
  , source :: !Text
  , mapEvent :: !(RecordedEvent -> e -> Maybe IntegrationEventDraft)
  }
```

`IntegrationEventDraft` is everything in `IntegrationEvent` except `messageId` — the helper mints `messageId` as a UUIDv7 (or equivalent time-ordered UUID) when it writes the outbox row. The helper should decode each private recorded event with the service's `Codec e`, call `mapEvent`, and — when the mapper returns `Just` — insert one outbox row in the same Postgres transaction that advances the subscription checkpoint. The subscription does not publish to Kafka. The mapper must receive the `RecordedEvent` so the helper can persist `sourceEventId` and `sourceGlobalPosition` on the row alongside the minted `messageId`.

Milestone 4 adds the publisher worker that drains the outbox into Kafka. Provide a transport-neutral function:

```haskell
publishClaimedOutbox
  :: (OutboxRow -> Eff es (Either Text ()))
  -> OutboxPublishOptions
  -> Eff es OutboxPublishSummary

data OutboxPublishOptions = OutboxPublishOptions
  { batchSize :: !Int
  , maxAttempts :: !Int                 -- default 10
  , backoff :: !BackoffSchedule
  , orderingPolicy :: !OrderingPolicy   -- default PerKeyHeadOfLine
  }

data OrderingPolicy
  = PerKeyHeadOfLine          -- default; one failed row blocks only its key
  | PerSourceStream           -- one failed row blocks all later rows in source
  | StopTheLine               -- any failure halts the publisher until operator intervention
  | BestEffort                -- failed rows do not block; explicit opt-in only
```

`publishClaimedOutbox` claims rows under the active `orderingPolicy`, calls the supplied publish function, and on result either marks the row `sent`, or calls `markOutboxFailed` (which decides `failed` vs `dead` based on `maxAttempts`). `PerKeyHeadOfLine` uses the claim query shown in Milestone 2. `PerSourceStream` strengthens the `NOT EXISTS` clause to ignore `message_key` entirely (any earlier non-terminal row in the same `source` blocks). `StopTheLine` returns immediately from `publishClaimedOutbox` after the first failure and surfaces the offending row id in the summary. `BestEffort` drops the `NOT EXISTS` clause entirely; choose it only when the publisher's events have no per-key/causal relationship.

Then provide a Kafka wrapper that converts `OutboxRow` to `Kafka.Producer.Types.ProducerRecord` and calls `Kafka.Effectful.Producer.produceMessageSync`. Topic comes from `destination`, key comes from `message_key`, payload comes from EP-19 `payloadBytes`, and headers include message id, source, event type, schema version, content type, schema reference fields when present, source event id/global position when present, causation id, correlation id, and W3C trace headers when present. Do not add schema-registry network calls in this plan; the worker should preserve the metadata so a future wrapper can register or look up schemas before publish.

Milestone 5 adds tests and docs. Extend `keiro-migrations/test/Main.hs` to assert `keiro_outbox` exists after `runAllKeiroMigrations`. Add storage tests to `test/Main.hs` or a split module. Add documentation explaining the at-least-once publish guarantee and why inbox deduplication is required.


## Concrete Steps

Run the dependency checks first:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori show --full
mori registry show shinzui/kafka-effectful --full
```

After adding the migration and modules, run:

```bash
cabal build keiro
cabal build keiro-migrations
cabal test keiro-migrations-test
cabal test keiro-test
```

Expected migration-test evidence includes the table list containing:

```text
keiro_outbox
```

If `keiro-test` still fails due to the known Keiki multi-event output API migration, record the current failure in Surprises & Discoveries and keep the outbox-specific tests isolated enough to run once that blocker is cleared.


## Validation and Acceptance

Acceptance requires:

- Running `cabal test keiro-migrations-test` against a fresh ephemeral Postgres database proves `keiro_outbox` exists and a second migration run is harmless.
- A storage test enqueues an `IntegrationEvent` inside a transaction and verifies the row has status `pending`, `attempt_count = 0`, the expected destination, message id, content type, optional schema reference, and payload bytes.
- A claim test inserts two pending rows, calls the claim function with limit `1`, and observes exactly one row transition to `publishing` with `attempt_count = 1`.
- A mark-sent test observes `status = sent` and `published_at` set only after the fake publish function succeeds.
- A mark-failed test observes the row remain retryable with `last_error` recorded.
- A Kafka conversion test constructs an outbox row and verifies the resulting `ProducerRecord` has the expected topic, key, payload bytes, content-type/schema-reference headers, and other identity headers.
- A producer-subscription test feeds a private recorded event and its decoded private event to a mapper, observes one `keiro_outbox` row written with a freshly minted UUIDv7 `message_id`, `sourceEventId` and `sourceGlobalPosition` populated from the recorded event, and verifies that the subscription checkpoint advances atomically with the row insert (a failed insert leaves the checkpoint unchanged).
- A worker test feeds two claimed outbox rows to a fake publish function: one succeeds (row marked `sent`), one fails transiently (row marked retryable with `last_error` recorded and `attempt_count` incremented).
- A head-of-line test inserts three rows: A1 (key=k1, pending), A2 (key=k1, pending), B1 (key=k2, pending) with A1 earliest. The publish function fails A1 transiently. The next claim returns only B1 — A2 is blocked because A1 is non-terminal. After A1 publishes successfully, the next claim returns A2.
- A null-key bypass test inserts two rows with `message_key = NULL` from the same source. The first fails transiently; the next claim still returns the second (null-keyed rows do not head-of-line block each other).
- A dead-letter test inserts one row and configures `maxAttempts = 3`. The publish function fails three times; on the third failure the row transitions to `status = 'dead'`, is not returned by subsequent claims, and a later sibling with the same key is then claimable.
- A `PerSourceStream` policy test inserts two rows with different keys in the same source. The first fails; the second is *not* claimable until the first reaches a terminal state. Switching the same fixture to `BestEffort` lets the second publish independently.


## Idempotence and Recovery

All Haskell edits are additive. The codd migration is forward-only: do not rename it after it has been applied to a shared database. If the DDL needs a fix after sharing, add a new timestamped migration. Runtime development initialization may use `CREATE TABLE IF NOT EXISTS` for local tests, but production must use `keiro-migrate`.

If a publisher crashes after claiming rows, rows left in `publishing` need a recovery rule. Implement either `next_attempt_at` reset during claim for stale `publishing` rows or a separate `releaseStaleOutboxClaims` helper. Record the chosen timeout in the Decision Log during implementation.


## Interfaces and Dependencies

Local dependencies include `Hasql.Transaction` for transactional enqueue, `Kiroku.Store.Transaction.runTransaction` for storage helpers, `Data.UUID` for outbox ids, `bytestring` for payload bytes, `aeson` for optional JSON payload views and header/attribute JSON, `time` for claim and publish timestamps, and `Keiro.Integration.Event` from EP-19.

Kafka dependencies include `Kafka.Effectful.Producer` from `/Users/shinzui/Keikaku/bokuno/kafka-effectful`. If the main library imports Kafka producer types, add `kafka-effectful` and any required `hw-kafka-client` package to `keiro.cabal` and `cabal.project` using Mori-discovered source paths or released package bounds.

The final public surface should include:

```haskell
module Keiro.Outbox
  ( OutboxId (..)
  , OutboxMessage (..)
  , OutboxRow (..)
  , OutboxStatus (..)         -- Pending | Publishing | Sent | Failed | Dead
  , OrderingPolicy (..)       -- PerKeyHeadOfLine | PerSourceStream | StopTheLine | BestEffort
  , OutboxPublishOptions (..)
  , OutboxPublishSummary (..)
  , BackoffSchedule (..)
  , enqueueOutboxTx
  , claimOutboxBatch
  , markOutboxSent
  , markOutboxFailed
  , publishClaimedOutbox
  , IntegrationProducer (..)
  , runIntegrationProducerOnce
  )
```

If the Kafka publisher is large or introduces heavy dependencies, place it in `Keiro.Outbox.Kafka` and expose that module separately.
