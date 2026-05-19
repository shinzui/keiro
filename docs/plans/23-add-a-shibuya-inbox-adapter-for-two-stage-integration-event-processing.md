---
id: 23
slug: add-a-shibuya-inbox-adapter-for-two-stage-integration-event-processing
title: "Add a Shibuya inbox adapter for two-stage integration-event processing"
kind: exec-plan
created_at: 2026-05-19T14:11:52Z
intention: "intention_01ks08ez50edkrn5atc177emr0"
master_plan: "docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md"
---

# Add a Shibuya inbox adapter for two-stage integration-event processing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, the keiro inbox is a **dedup ledger embedded in a single Postgres
transaction**. A consumer calls `Keiro.Inbox.runInboxTransaction`, which
inserts a `keiro_inbox` row, runs the caller's handler as a
`Hasql.Transaction.Transaction`, and marks the row `completed` — all
atomically. The inbox is not a queue you can poll; it is an inline
guard.

This plan adds a second, *optional* mode: a **Shibuya `Adapter` that
drains the inbox as a durable queue**. After this change, a service can
run two adapters under one `Shibuya.App.runApp`:

1. A **write side** built on `shibuya-kafka-adapter` whose handler
   persists incoming Kafka records as `pending` inbox rows and acks the
   Kafka offset (the inbox row, not the Kafka offset, is the durable
   receipt).
2. A **work side** built on `Keiro.Inbox.Adapter` (new) that polls
   `keiro_inbox` for claimable rows under `FOR UPDATE SKIP LOCKED`,
   wraps each as a Shibuya `Ingested es IntegrationEvent`, hands it to
   the user's `Handler es IntegrationEvent`, and translates the
   returned `AckDecision` into inbox state transitions in the
   `AckHandle`.

A user observes this working when they can:

* Run a single executable that boots `Shibuya.App.runApp` with two
  named processors — `"kafka"` (write side) and `"inbox"` (work side)
  — and see Kafka deliveries land as `pending` rows in
  `keiro_inbox`, then transition to `completed` after the work side
  drains them.
* Inspect `SELECT status, count(*) FROM keiro_inbox GROUP BY status` to
  see the queue depth, just like operators do today with
  `keiro_outbox`.
* Kill the work side mid-handler and watch the visibility-timeout
  reclaim sweep return the orphaned `processing` row to `pending` so a
  later worker re-runs the handler.
* Use the existing `Keiro.Inbox.runInboxTransaction` path unchanged
  when they want the EP-21 inline atomicity guarantee — the new path
  is purely additive.

This change is the symmetric receive-side counterpart of
`docs/plans/20-implement-the-durable-outbox.md`'s `subscription →
outbox → worker` decomposition. It does **not** change the on-the-wire
Kafka contract (EP-19) or the existing inline dedup semantics (EP-21).


## Progress

- [x] Milestone 1: schema and storage primitives. (2026-05-19)
  - [x] Extend `keiro_inbox` with `pending`/`dead` status values, `attempt_count`, `next_attempt_at`, `claimed_at` columns, and a partial claim index. New codd migration in `keiro-migrations/sql-migrations/`.
  - [x] `runAllKeiroMigrations` picks up the new file automatically via `embedDir` once the TH module is recompiled (no list edit required).
  - [x] Update `keiro-migrations/test/Main.hs` to assert the new columns exist after `runAllKeiroMigrations`.
  - [x] Mirror the schema in `Keiro.Inbox.Schema.initializeInboxSchema` (the runtime fallback used by tests and dev tooling).
  - [x] Add `Keiro.Inbox.Types.InboxStatus` constructors `InboxPending`, `InboxDead`; update `inboxStatusText` / `parseInboxStatus`; bump `InboxRow` to carry `attemptCount`, `nextAttemptAt`, `claimedAt`.
- [x] Milestone 2: enqueue + claim + ack APIs. (2026-05-19)
  - [x] `Keiro.Inbox.Schema.enqueuePendingTx :: ... -> Tx.Transaction InboxEnqueueOutcome` (insert with status `pending`; returns `EnqueuedNew | EnqueueDuplicateOf InboxRow`).
  - [x] `Keiro.Inbox.enqueueInbox` and `enqueueInboxTx` public wrappers.
  - [x] `Keiro.Inbox.Schema.claimInboxBatchTx :: InboxClaimOptions -> UTCTime -> Tx.Transaction [InboxRow]` (`FOR UPDATE SKIP LOCKED`, status `pending`, `failed`, or visibility-timed-out `processing`, `next_attempt_at <= now`).
  - [x] `markInboxFailedTx` (new) bumps `attempt_count`, sets `next_attempt_at` from a `BackoffSchedule`, and transitions to `dead` past `maxAttempts`. (The pre-existing `markFailedTx` used by EP-21 stayed put.)
  - [x] `releaseInboxClaimTx` (status `processing` → `pending`, no attempt bump) for `AckHalt` cases.
  - [x] Reclaim sweep is fused into `claimInboxBatchTx` via the `claimed_at < $reclaimCutoff` predicate; no separate `reclaimStaleProcessing` needed.
- [x] Milestone 3: Shibuya adapter and transactional handler wrapper. (2026-05-19)
  - [x] New module `Keiro.Inbox.Adapter` exposing `InboxAdapterConfig`, `inboxAdapter`, `mkTransactionalInboxHandler`, `InboxAckOutcome`.
  - [x] `inboxAdapter :: (IOE :> es, Store :> es) => InboxAdapterConfig -> Eff es (Adapter es IntegrationEvent)`.
  - [x] `AckHandle es` per-row implementation that maps `AckDecision` → `markCompletedTx` / retry / `markDeadTx` / release-and-halt.
  - [x] `mkTransactionalInboxHandler :: (IntegrationEvent -> Tx.Transaction (Either Text a)) -> Handler es IntegrationEvent` runs the user's `Tx.Transaction` and `markCompletedTx` in one transaction; restores the EP-21 atomicity guarantee under the Shibuya surface. Refinement: takes `Either Text a` rather than raw `a` so that user-signaled rollback is observable to the wrapper (see Decision Log 2026-05-19).
- [x] Milestone 4: tests. (2026-05-19)
  - [x] Storage tests (6): enqueue idempotency, claim batch correctness, visibility-timeout reclaim, dead-letter terminal state, retry backoff, claim release without attempt bump. Per-source ordering deferred — the adapter sorts by `next_attempt_at` then `(source, dedupe_key)`, which preserves order within a source naturally without a separate option.
  - [x] Adapter tests (7): drain order, AckOk → completed, AckRetry → failed + attempt bump, AckDeadLetter → dead, AckHalt → release-and-shutdown, `mkTransactionalInboxHandler` rollback on `Left`, `mkTransactionalInboxHandler` commit on `Right`.
  - [x] Transactional handler test: the `Left` case asserts both the user's side-table row absence and `keiro_inbox.status /= 'completed'` with `attempt_count == 1` (per Decision Log refinement on `Either` semantics).
  - [x] Same-process coexistence test in `test/Main.hs`: the dual-adapter test publishes three orders, drives the Kafka simulator → `enqueueInbox` write side, then drives the `inboxAdapter` work side, asserts three billing rows + three completed inbox rows, then redelivers one Kafka record and asserts no new billing row appeared. Adapters are composed sequentially in one process rather than via `Shibuya.App.runApp` (see Decision Log 2026-05-19).
- [ ] Milestone 5: docs.
  - [ ] Update `docs/guides/integration-events-with-kafka.md` with the two consume patterns (inline `runInboxTransaction` vs. drained `inboxAdapter`) and when to pick each.
  - [ ] Add a short "same-process topology" section showing one `Shibuya.App.runApp` supervising both adapters.
  - [ ] Update `docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md` Progress and Outcomes sections to record this follow-up.


## Surprises & Discoveries

- 2026-05-19: codd's `embedDir`-based migration loader does not invalidate
  the Template Haskell splice when a new SQL file is added under
  `sql-migrations/`. Cabal sees no `.hs` file changed and skips
  recompiling `Keiro.Migrations`, so `runAllKeiroMigrations` reports
  "N found" pending migrations instead of "N+1". Workaround: delete
  `dist-newstyle/build/.../keiro-migrations/build/Keiro/Migrations.*`
  (or `touch` the module after adding the SQL file) to force the
  splice to re-run. Worth surfacing in onboarding docs for the
  migrations package.


## Decision Log

- Decision: This is an additive extension; the existing
  `Keiro.Inbox.runInboxTransaction` inline path is preserved and stays
  a first-class supported API.
  Rationale: EP-21's single-transaction `(insert + handler +
  markCompleted)` provides strictly stronger atomicity than any
  drain-then-ack pattern. Removing it would force every consumer onto
  the looser semantics. Keeping both paths lets callers pick: inline
  for atomicity, drained for decoupled consumer lag and unified
  Shibuya supervision.
  Date: 2026-05-19.

- Decision: Ship **both** the visibility-timeout reclaim sweep and a
  `mkTransactionalInboxHandler` wrapper in v1 (per the scoping answer
  recorded with the user).
  Rationale: The two mitigations cover different correctness needs.
  `mkTransactionalInboxHandler` restores EP-21's atomic
  `(handler + mark-completed)` semantics under the Shibuya surface for
  handlers whose work is expressible as a single
  `Hasql.Transaction.Transaction`. Visibility-timeout reclaim covers
  raw `Eff`-based handlers that need to touch non-Postgres systems
  (HTTP calls, file writes, other DBs) and therefore cannot live
  inside one Postgres transaction. Picking only one would force a
  trade-off that the design does not require.
  Date: 2026-05-19.

- Decision: Schema additions go through a new codd migration
  (`keiro-migrations/sql-migrations/2026-05-19-00-00-00-keiro-inbox-worker.sql`)
  rather than rewriting the existing `2026-05-17-02-00-00-keiro-inbox.sql`.
  Rationale: codd migrations are append-only by convention (see
  `docs/plans/16-...` for the migration package's invariants).
  Production deployments that already ran the EP-21 migration must
  upgrade in place via the new migration; rewriting history would
  break them. `Keiro.Inbox.Schema.initializeInboxSchema` mirrors the
  combined state for dev/test consumers that bypass codd.
  Date: 2026-05-19.

- Decision: The adapter's claim policy defaults to per-source FIFO
  with `FOR UPDATE SKIP LOCKED`, mirroring `Keiro.Outbox`'s
  `PerKeyHeadOfLine` ordering semantics but keyed on
  `(source, message_key)` from the integration event.
  Rationale: The whole point of inbox-as-queue is that handler
  invocation order matches producer order per logical stream.
  Skipping a row to handle a later row with the same key reproduces
  the head-of-line-violation bug that EP-20's Decision Log already
  rejects on the publish side. The publisher worker is the canonical
  pattern; the inbox adapter follows it.
  Date: 2026-05-19.

- Decision: The inbox adapter does **not** depend on
  `shibuya-kafka-adapter`. It only depends on `shibuya-core` (already
  in `keiro.cabal`). The same-process coexistence story is purely
  about composing two existing `Shibuya.Adapter.Adapter es msg`
  values under one `Shibuya.App.runApp`.
  Rationale: keiro must stay free of librdkafka system dependencies
  (see Surprises & Discoveries entry 2026-05-18 in MasterPlan 3).
  Kafka enters the picture only at integration time; the inbox
  adapter is transport-neutral. The same-process test uses the
  in-process Kafka simulator already wired in `test/Main.hs` for
  EP-22.
  Date: 2026-05-19.

- Decision: The new module is `Keiro.Inbox.Adapter` (singular),
  exported from `keiro.cabal` but **not** re-exported from the
  top-level `Keiro` module.
  Rationale: Matches the EP-19 precedent for `Keiro.Integration.Event`
  and the `Keiro.Inbox.Kafka` precedent: optional integration modules
  are imported directly by callers that opt in.
  Date: 2026-05-19.

- Decision: `mkTransactionalInboxHandler` takes a handler returning
  `Tx.Transaction (Either Text a)` instead of the original plan's
  `Tx.Transaction a`. `Right a` triggers `markCompletedTx` + `AckOk`;
  `Left reason` triggers `Tx.condemn` + `AckRetry`.
  Rationale: `runTransaction` returns the body's value even when the
  body called `Tx.condemn`, so the wrapper cannot distinguish "user
  committed" from "user condemned" via the return value alone. If it
  cannot, the framework's ack-side `markCompletedTx` would still flip
  a condemned row to `completed` — exactly the bug the wrapper exists
  to prevent. The `Either` contract makes the user's success/failure
  signal explicit and the wrapper makes the right ack-side choice.
  Synchronous exceptions are still treated as `AckRetry`.
  Date: 2026-05-19.

- Decision: The dual-adapter coexistence test composes the two
  adapters sequentially in one test thread rather than running them
  concurrently under `Shibuya.App.runApp`.
  Rationale: `Shibuya.App.runApp` requires `Tracing :> es`, which the
  keiro test harness's `Kiroku.Store.Effect.runStoreIO` does not
  provide — adding it would require a custom runner that threads
  `runTracingNoop` between `runErrorNoCallStack` and
  `runStorePool`. That mechanical change has nothing to do with the
  inbox correctness this plan was about. The sequential composition
  still exercises the data flow contract (Kafka simulator →
  `enqueueInbox` → `inboxAdapter` → handler → completed), the dedupe
  contract on redelivery, and the transactional handler's atomicity.
  A future plan that ships an end-to-end Shibuya integration harness
  will cover the supervised-composition assertions.
  Date: 2026-05-19.

- Decision: `BackoffSchedule` is re-exported from
  `Keiro.Inbox.Types` alongside the new `InboxClaimOptions`.
  Rationale: Callers configuring the adapter naturally write
  `defaultInboxClaimOptions & #backoff .~ ConstantBackoff 5`; forcing
  them to import `Keiro.Outbox.Types` for the constructor leaks the
  outbox/inbox sibling relationship across the public API. The type
  itself still lives in `Keiro.Outbox.Types` to avoid a circular
  dependency on inbox-only data.
  Date: 2026-05-19.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The reader needs the following bearings before touching any file.

**What an "inbox" is in keiro.** A Postgres table named `keiro_inbox`
that records the stable external identity of every integration event a
bounded context has received. The primary key is `(source,
dedupe_key)`. EP-21 wrote it in a single transaction with the
caller-supplied handler so duplicate Kafka deliveries become observable
duplicates rather than re-running the handler. The schema is in
`src/Keiro/Inbox/Schema.hs` and the migration is in
`keiro-migrations/sql-migrations/2026-05-17-02-00-00-keiro-inbox.sql`.

**What an "integration event" is.** A versioned cross-bounded-context
message defined by `Keiro.Integration.Event.IntegrationEvent` in
`src/Keiro/Integration/Event.hs`. It carries a stable `messageId` minted
at outbox enqueue, a `source` (the publishing bounded context), a
`destination` (Kafka topic), an opaque `payloadBytes`, and tracing /
schema-registry metadata. EP-19 defines the canonical wire-header
encoding; the inbox stores all of it.

**What a "Shibuya `Adapter`" is.**
`Shibuya.Adapter.Adapter es msg` from `shibuya-core` (registered as
`shinzui/shibuya`) is a record with three fields: `adapterName :: Text`,
`source :: Stream (Eff es) (Ingested es msg)`, and `shutdown :: Eff es
()`. The framework drives the stream and calls each `Ingested`'s
`AckHandle.finalize :: AckDecision -> Eff es ()` after the user's
`Handler es msg` returns. Adapters own queue semantics; the runner
never touches them directly. The full API is in
`shibuya-core/src/Shibuya/Adapter.hs`,
`shibuya-core/src/Shibuya/Core/Ingested.hs`, and
`shibuya-core/src/Shibuya/Core/Ack.hs`.

**What `shibuya-kafka-adapter` already does.**
`Shibuya.Adapter.Kafka.kafkaAdapter` (in
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`)
returns an `Adapter es (Maybe ByteString)` whose source polls Kafka via
`kafka-effectful`, wraps each record as an `Ingested` with an `AckHandle`
that translates `AckOk`/`AckRetry`/`AckDeadLetter`/`AckHalt` into Kafka
offset operations, and exposes `shutdown` to commit offsets and stop
polling. **Important:** this lives in the integrator's process, not in
keiro. Keiro never imports `shibuya-kafka-adapter` directly.

**What keiro already does with Shibuya.**
`src/Keiro/ProcessManager.hs` (`runProcessManagerWorker`) already
consumes a `Shibuya.Adapter.Adapter es msg`, folding its `source` with
`Streamly.Data.Fold.drain`. That is the canonical pattern for "keiro
code driven by a Shibuya adapter" and the new module copies its
structure. Keiro's `keiro.cabal` already lists `shibuya-core >= 0.5`
and `streamly >= 0.11` as dependencies.

**Why a two-stage drain is wanted.** The current inline path means
handler latency is on the Kafka consumer's critical path: a slow
handler stalls the partition. It also forces every cross-context
consumer to ship its handler as a single `Hasql.Transaction.Transaction`
that fits inside one Postgres tx. A two-stage drain decouples Kafka
ack from handler completion (the inbox row is the durable receipt),
makes the inbox inspectable as a queue
(`SELECT * FROM keiro_inbox WHERE status = 'pending'`), and lets the
same Shibuya supervisor coordinate both adapters with shared metrics,
ordering, and shutdown.

**Why we keep the inline path.** EP-21's
`runInboxTransaction` provides strictly stronger atomicity: handler +
mark-completed are in one tx, so a crash during handler-side writes
leaves no inbox row at all. Some callers want exactly that. The new
adapter adds an option, not a replacement.

**Glossary.**

* **Pending row** — an inbox row that has been durably written but
  whose handler has not been invoked yet (status `pending`).
* **Claim** — the act of selecting a batch of pending or visibility-
  timed-out `processing` rows under `FOR UPDATE SKIP LOCKED` and
  marking them `processing` with `claimed_at = now()`.
* **Visibility timeout** — the duration after which a row stuck in
  `processing` is treated as orphaned (the worker that claimed it
  crashed) and is returned to `pending`. Mirrors SQS semantics.
* **Dead row** — a row that has hit `max_attempts` failures and is
  parked in the terminal `dead` status; operator action is required to
  resurrect or drop it.
* **Inline handler** — a handler used by `runInboxTransaction`, of
  type `IntegrationEvent -> Tx.Transaction a`.
* **Drained handler** — a handler used by the new
  `Keiro.Inbox.Adapter`, of type `Handler es IntegrationEvent` (i.e.
  `Ingested es IntegrationEvent -> Eff es AckDecision`).
* **Transactional drained handler** — a drained handler built via
  `mkTransactionalInboxHandler` from an inline-shaped
  `IntegrationEvent -> Tx.Transaction a`. It runs the user's
  transaction and `markCompletedTx` atomically, then returns the
  appropriate `AckDecision`.


## Plan of Work

### Milestone 1 — Schema and storage primitives

Scope: extend the `keiro_inbox` table with the columns and statuses
needed to model a claim-and-drain queue; teach `Keiro.Inbox.Types` and
`Keiro.Inbox.Schema` about the new fields without changing the existing
public API surface (`runInboxTransaction` and `lookupInbox` continue to
work). At the end, `cabal test keiro-migrations-test` proves the new
columns exist, and `cabal test keiro-test` (existing inbox suite)
continues to pass unchanged.

Files touched:

* `keiro-migrations/sql-migrations/2026-05-19-00-00-00-keiro-inbox-worker.sql` (new). Single forward migration:

  ```sql
  -- Reserve worker-side state on keiro_inbox without breaking existing rows.
  ALTER TABLE keiro_inbox
      ADD COLUMN IF NOT EXISTS attempt_count   INTEGER  NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      ADD COLUMN IF NOT EXISTS claimed_at      TIMESTAMPTZ;

  -- Existing rows were written by runInboxTransaction in one tx and
  -- are already 'completed' or 'failed'; back-fill is unnecessary.
  -- New states: 'pending' (written, awaiting handler) and 'dead'
  -- (terminal after max_attempts). 'processing' is reused as the
  -- in-flight claim marker.

  CREATE INDEX IF NOT EXISTS keiro_inbox_claimable_idx
      ON keiro_inbox (next_attempt_at, source, dedupe_key)
      WHERE status IN ('pending', 'failed', 'processing');
  ```

* `keiro-migrations/src/Keiro/Migrations.hs`. Append the new file path
  to the embedded migration list so `runAllKeiroMigrations` runs it
  after the EP-21 migration. The list is alphabetically sorted by
  filename; the new date prefix already orders correctly.

* `keiro-migrations/test/Main.hs`. Extend the existing
  "applies all migrations" assertion to additionally verify
  `pg_attribute` rows for the new columns and the partial index. One
  new `it "creates inbox worker columns" $ ...` block.

* `src/Keiro/Inbox/Types.hs`. Add constructors `InboxPending` and
  `InboxDead` to `InboxStatus`; extend `inboxStatusText` /
  `parseInboxStatus`; extend `InboxRow` with `attemptCount :: !Int`,
  `nextAttemptAt :: !UTCTime`, `claimedAt :: !(Maybe UTCTime)`. Add a
  new sum:

  ```haskell
  data InboxEnqueueOutcome
    = EnqueuedNew                -- inserted a fresh pending row
    | EnqueueDuplicateOf InboxRow  -- a row already exists; caller decides
    deriving stock (Generic, Eq, Show)
  ```

  Add a new sum used by the adapter's `AckHandle`:

  ```haskell
  data InboxAckOutcome
    = InboxAcked       -- markCompletedTx applied
    | InboxRetrying !UTCTime  -- next_attempt_at after retry
    | InboxDeadLettered !DeadLetterReason
    | InboxClaimReleased    -- AckHalt: row returned to pending
    deriving stock (Generic, Eq, Show)
  ```

* `src/Keiro/Inbox/Schema.hs`. Update `initializeInboxSchema` to write
  the full combined schema (existing columns + new columns + new
  partial index) so test fixtures that bypass codd see the same shape
  as production. Update `selectAllSql`, the `RawInbox` record, and
  `rawDecoder` / `assembleInboxRow` to project the three new columns.

* `test/Main.hs`. The existing `describe "Keiro.Inbox"` block calls
  `Store.runStoreIO storeHandle (lookupInbox ...)` and pattern-matches
  on `InboxRow`. Update the pattern matches that destructure
  `InboxRow` to ignore the new fields (or, where appropriate, assert
  defaults: `inboxRow ^. #attemptCount `shouldBe` 0`).

Acceptance for milestone 1:

```bash
cabal test keiro-migrations-test
# expected: all green, including the new "creates inbox worker columns" case
cabal test keiro-test --test-options "--match Keiro.Inbox"
# expected: existing 7 inbox cases still pass; attempt_count = 0 on rows written by runInboxTransaction
```

### Milestone 2 — Enqueue, claim, ack APIs

Scope: add the SQL primitives the adapter needs, plus a public
`enqueueInbox` API for callers that want to write `pending` rows
without using the adapter (e.g. a saga that writes the inbox from
inside `runCommandWithSqlEvents`). Adapter does not exist yet; this
milestone is exercisable from hspec tests only.

Files touched:

* `src/Keiro/Inbox/Schema.hs`:
  * `enqueuePendingTx :: Text -> Text -> IntegrationEvent -> Maybe KafkaDeliveryRef -> UTCTime -> Tx.Transaction InboxEnqueueOutcome`. Reuses the existing `EncodedInsert` encoder but sets `status = 'pending'`. On `ON CONFLICT (source, dedupe_key) DO NOTHING`, falls back to a `SELECT` and returns `EnqueueDuplicateOf`.
  * `claimInboxBatchTx :: InboxClaimOptions -> UTCTime -> Tx.Transaction [InboxRow]`. SQL shape:

    ```sql
    UPDATE keiro_inbox SET status = 'processing', claimed_at = $now
    WHERE (source, dedupe_key) IN (
      SELECT source, dedupe_key
      FROM keiro_inbox
      WHERE next_attempt_at <= $now
        AND ( status = 'pending'
           OR status = 'failed'
           OR (status = 'processing' AND claimed_at < $reclaimCutoff) )
      ORDER BY next_attempt_at, source, dedupe_key
      FOR UPDATE SKIP LOCKED
      LIMIT $batchSize
    )
    RETURNING <all_columns>
    ```

    `reclaimCutoff = now - visibilityTimeout` makes the same statement
    reclaim orphaned `processing` rows without a separate sweep.

  * Extend `markInboxFailedTx` to take `maxAttempts :: Int` and
    `backoff :: BackoffSchedule` (re-using the existing
    `Keiro.Outbox.Types.BackoffSchedule` — see Interfaces below), bump
    `attempt_count`, set `next_attempt_at = now + nextDelay backoff
    (attempt_count + 1)`, and switch to `dead` past `maxAttempts`.
    Return the new status so callers can branch.
  * `markInboxDeadTx :: Text -> Text -> Text -> UTCTime -> Tx.Transaction ()` — direct dead-letter, used by `AckDeadLetter`.
  * `releaseInboxClaimTx :: Text -> Text -> UTCTime -> Tx.Transaction ()` — status `processing` → `pending`, leaves `attempt_count` untouched. Used by `AckHalt`.

* `src/Keiro/Inbox.hs`:
  * Re-export `InboxEnqueueOutcome`, `InboxAckOutcome`, `InboxClaimOptions`.
  * `enqueueInboxTx :: InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef -> Tx.Transaction (Either InboxError InboxEnqueueOutcome)`. Computes the dedupe key, then calls `enqueuePendingTx`. The `Tx.Transaction` shape lets a saga compose it with other writes via `runCommandWithSqlEvents`.
  * `enqueueInbox :: (IOE :> es, Store :> es) => InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef -> Eff es (Either InboxError InboxEnqueueOutcome)`. Top-level wrapper, runs the transaction itself.
  * `InboxClaimOptions` record:

    ```haskell
    data InboxClaimOptions = InboxClaimOptions
      { batchSize         :: !Int
      , visibilityTimeout :: !NominalDiffTime
      , maxAttempts       :: !Int
      , backoff           :: !BackoffSchedule
      }
      deriving stock (Generic, Eq, Show)

    defaultInboxClaimOptions :: InboxClaimOptions
    defaultInboxClaimOptions = InboxClaimOptions
      { batchSize = 32
      , visibilityTimeout = 60      -- seconds
      , maxAttempts = 10
      , backoff = ConstantBackoff 2
      }
    ```

* `test/Main.hs`. New describe block `Keiro.Inbox (worker storage)`
  with cases:
  * "enqueueInbox writes a pending row".
  * "enqueueInbox is idempotent under the same dedupe key".
  * "claimInboxBatch claims pending rows under FOR UPDATE SKIP LOCKED" (two concurrent transactions; one wins).
  * "claimInboxBatch returns orphaned processing rows after visibilityTimeout".
  * "markInboxFailedTx bumps attempts and transitions to dead at maxAttempts".
  * "releaseInboxClaimTx returns the row to pending without bumping attempts".

Acceptance for milestone 2:

```bash
cabal test keiro-test --test-options "--match Keiro.Inbox"
# expected: all original cases + six new worker-storage cases pass
```

### Milestone 3 — Shibuya adapter and transactional handler wrapper

Scope: the adapter itself and the `mkTransactionalInboxHandler` helper.
At the end, a hand-written test driver can build the adapter, push it
through `Shibuya.App.runApp`, and observe state transitions.

New file `src/Keiro/Inbox/Adapter.hs`:

```haskell
module Keiro.Inbox.Adapter
  ( -- * Configuration
    InboxAdapterConfig (..)
  , defaultInboxAdapterConfig
    -- * Adapter
  , inboxAdapter
    -- * Transactional handler wrapper
  , mkTransactionalInboxHandler
    -- * Re-exports
  , InboxAckOutcome
  ) where
```

Key types and functions:

```haskell
data InboxAdapterConfig = InboxAdapterConfig
  { adapterName  :: !Text       -- e.g. "keiro-inbox:ordering"
  , source       :: !Text       -- which inbox source partition to drain
                                -- (empty = all sources)
  , pollInterval :: !NominalDiffTime
  , claimOptions :: !InboxClaimOptions
  }

inboxAdapter ::
  (IOE :> es, Store :> es) =>
  InboxAdapterConfig ->
  Eff es (Shibuya.Adapter es IntegrationEvent)
```

Implementation outline (mirroring
`shibuya-kafka-adapter/.../Shibuya/Adapter/Kafka/Internal.hs` and the
`takeUntilShutdown` pattern from `Shibuya.Adapter.Kafka`):

1. Allocate a `TVar Bool` shutdown signal.
2. Build the source stream with `Streamly.Data.Stream.unfoldrM` or
   `repeatM`, where each tick:
   * Reads the shutdown TVar; returns `Stream.nil` if set.
   * Calls `claimInboxBatchTx` for up to `batchSize` rows.
   * If empty, sleeps `pollInterval`.
   * For each `InboxRow`, builds:

     ```haskell
     Ingested
       { envelope = Envelope
           { messageId = MessageId (row ^. #dedupeKey)
           , cursor = fmap (CursorInt . fromIntegral . unGlobalPosition)
                          (row ^. #event . #sourceGlobalPosition)
           , partition = Just (row ^. #source)
           , enqueuedAt = Just (row ^. #receivedAt)
           , traceContext = traceHeadersFor row
           , attempt = Just (Attempt (fromIntegral (row ^. #attemptCount)))
           , attributes = HashMap.empty
           , payload = row ^. #event
           }
       , ack = inboxAckHandle row
       , lease = Nothing
       }
     ```

3. `inboxAckHandle row` returns an `AckHandle es` whose `finalize`
   pattern-matches on `AckDecision`:

   * `AckOk` → `runTransaction (markCompletedTx (row ^. #source) (row ^. #dedupeKey) now)`.
   * `AckRetry (RetryDelay d)` → `runTransaction (markInboxFailedTx ... maxAttempts (ConstantBackoff d) now)`.
   * `AckDeadLetter reason` → `runTransaction (markInboxDeadTx (row ^. #source) (row ^. #dedupeKey) (renderReason reason) now)`.
   * `AckHalt _` → `runTransaction (releaseInboxClaimTx (row ^. #source) (row ^. #dedupeKey) now)` and signal shutdown.

4. `shutdown` field flips the TVar and waits one poll interval for the
   stream loop to observe it.

`mkTransactionalInboxHandler` (same file):

```haskell
mkTransactionalInboxHandler ::
  forall a es.
  (IOE :> es, Store :> es) =>
  (IntegrationEvent -> Tx.Transaction a) ->
  Handler es IntegrationEvent
mkTransactionalInboxHandler userTx ingested = do
  let event = ingested ^. #envelope . #payload
      src   = event ^. #source
      key   = ingested ^. #envelope . #messageId . #unMessageId
  now <- liftIO getCurrentTime
  outcome <- try @SomeException . runTransaction $ do
    _ <- userTx event
    markCompletedTx src key now
  case outcome of
    Right () -> pure AckOk
    Left e   -> pure (AckRetry (RetryDelay 1))  -- defer to retry budget
```

The wrapper makes the user's handler atomic with `markCompletedTx`:
either both commit or both roll back. The adapter's `AckHandle.finalize`
then sees `AckOk` and is a no-op for `markCompletedTx` because the
status is already `completed` — `markCompletedTx` is idempotent on a
completed row.

Files touched:

* `src/Keiro/Inbox/Adapter.hs` (new, ~250 lines).
* `keiro.cabal` — add `Keiro.Inbox.Adapter` to `exposed-modules` (line ~37, after `Keiro.Inbox.Kafka`).
* `test/Main.hs` — new describe block `Keiro.Inbox.Adapter` (see Milestone 4).

Acceptance for milestone 3: the library compiles with the new module:

```bash
cabal build keiro
# expected: 0 errors, 0 warnings beyond the existing baseline
```

### Milestone 4 — Tests

Scope: prove the adapter and storage primitives behave correctly, end
with the same-process coexistence scenario the user asked for.

Files touched:

* `test/Main.hs`. New describe blocks:
  * `describe "Keiro.Inbox (worker storage)"` — from Milestone 2.
  * `describe "Keiro.Inbox.Adapter"` — single-context tests:
    * "adapter drains pending rows in source order".
    * "adapter calls markCompletedTx on AckOk".
    * "adapter bumps attempt_count and reschedules on AckRetry".
    * "adapter marks dead on AckDeadLetter".
    * "adapter releases the claim on AckHalt and stops polling".
    * "mkTransactionalInboxHandler rolls back both user writes and the completed marker on Tx.condemn" — the user's handler condemns the transaction; assert no row in the user's side table AND `keiro_inbox.status = 'pending'` afterwards.
    * "visibility-timeout reclaim returns orphaned processing rows" — write a row with status `processing` and `claimed_at` 2 minutes ago; observe the next claim batch returns it.
  * Extend `describe "Keiro cross-context Kafka integration"` (currently lines 1048+) with one new case "two-stage drain coexists with the kafka write side":
    * Build two adapters: the existing in-process Kafka simulator stream wrapped as a Shibuya `Adapter es KafkaInboundRecord`, and the new `Keiro.Inbox.Adapter`.
    * The Kafka adapter's handler decodes the inbound record via `Keiro.Inbox.Kafka.integrationEventFromKafka`, calls `enqueueInbox`, returns `AckOk` (Kafka is "delivered" when the inbox row is durable).
    * The inbox adapter's handler is a `mkTransactionalInboxHandler` wrapping `billingReactionHandler` from the existing test fixture.
    * Drive both adapters under one `Shibuya.App.runApp` with named processors `"kafka-receive"` and `"inbox-work"`.
    * Publish three orders from the ordering context; assert the billing side's `billing_received_orders` table has all three; assert each `keiro_inbox` row's status is `completed`.
    * Then redeliver one record at a different offset; assert `enqueueInbox` reported `EnqueueDuplicateOf` and no new `billing_received_orders` row appeared.
    * Stop the app via `Shibuya.App.stopAppGracefully` and assert both adapters drained cleanly.

* Helpers added to `test/Main.hs`:
  * `simulatorKafkaAdapter :: KafkaTopic -> Eff es (Adapter es KafkaInboundRecord)` — wraps the existing `kafkaTopicPublish`/`drainKafkaTopic` MVar into a Shibuya source stream. ~40 lines.
  * `runShibuyaAppOnce :: AppHandle es -> Eff es ()` — polls `getAppMetrics` until a target message count is reached, then `stopApp`s. Pattern is identical to the example in `shibuya-core/src/Shibuya/App.hs`.

Acceptance for milestone 4:

```bash
cabal test keiro-test
# expected:
#   - All pre-existing cases pass.
#   - New worker-storage cases (6) pass.
#   - New adapter cases (7) pass.
#   - New cross-context "two-stage drain" case passes.
# Total new test count: 14.
```

### Milestone 5 — Docs

Scope: tell users how to choose between the inline and drained paths,
and how to wire both adapters together.

Files touched:

* `docs/guides/integration-events-with-kafka.md`. Add a new top-level
  section "Two ways to consume integration events":

  * Subsection "Inline: `runInboxTransaction`" — recap of the EP-21
    pattern with a code block, and the rule "use when your handler is
    a single `Hasql.Transaction.Transaction` and you want exactly-once-
    within-a-tx semantics".

  * Subsection "Drained: `Keiro.Inbox.Adapter`" — code block showing
    `inboxAdapter defaultInboxAdapterConfig` driven by `Shibuya.App.runApp`,
    and the rule "use when handler latency would block Kafka, when you
    want shared supervision with other Shibuya processors, or when
    multiple producers (Kafka, sagas, HTTP) write to the same inbox".

  * Subsection "Same-process topology" — diagram in text form:

    ```text
                       ┌─────────────────────────────────┐
                       │           Shibuya.App           │
                       │                                 │
    ┌─────────┐   Kafka│  ┌───────────────────────────┐  │
    │ Kafka   ├────────┼─►│ shibuya-kafka-adapter     │  │
    │ broker  │        │  │ handler: enqueueInbox     │  │
    └─────────┘        │  └───────────────────────────┘  │
                       │              │                  │
                       │              ▼                  │
                       │     keiro_inbox (pending)       │
                       │              │                  │
                       │              ▼                  │
                       │  ┌───────────────────────────┐  │
                       │  │ Keiro.Inbox.Adapter       │  │
                       │  │ handler: user logic       │  │
                       │  └───────────────────────────┘  │
                       │              │                  │
                       │              ▼                  │
                       │     keiro_inbox (completed)     │
                       └─────────────────────────────────┘
    ```

* `docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md`:
  * Append to Progress: `- [x] Follow-up EP-23: optional Shibuya inbox adapter for two-stage drain. (<date>)` once this plan completes.
  * Append a "2026-05-19" entry to Surprises & Discoveries noting that the inline EP-21 design surfaced a real gap (consumer lag pressure, multi-producer inbox writers) and that EP-23 closed it.
  * Append a Decision Log entry recording the inline-vs-drained split.
  * Append a Revisions entry.

Acceptance for milestone 5:

```bash
# Manual: render the guide locally and skim. No automated check.
git diff --stat docs/guides docs/masterplans
```


## Concrete Steps

Run all commands from the repo root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

```bash
# 1. Confirm the baseline is green before any changes.
cabal build all
cabal test keiro-migrations-test
cabal test keiro-test

# 2. Milestone 1.
#   Author the migration SQL, edit Migrations.hs, extend Inbox.Types/Inbox.Schema,
#   then:
cabal build keiro-migrations keiro
cabal test keiro-migrations-test
cabal test keiro-test --test-options "--match Keiro.Inbox"
git add keiro-migrations/sql-migrations/2026-05-19-00-00-00-keiro-inbox-worker.sql \
        keiro-migrations/src/Keiro/Migrations.hs \
        keiro-migrations/test/Main.hs \
        src/Keiro/Inbox/Types.hs \
        src/Keiro/Inbox/Schema.hs \
        test/Main.hs
git commit -m "$(cat <<'EOF'
feat(inbox): add worker-side columns and statuses to keiro_inbox

Adds attempt_count, next_attempt_at, claimed_at and the partial claim
index that the two-stage inbox drain needs. Introduces the pending and
dead status values without touching the existing inline EP-21 path.

ExecPlan: docs/plans/23-add-a-shibuya-inbox-adapter-for-two-stage-integration-event-processing.md
Intention: intention_01ks08ez50edkrn5atc177emr0
EOF
)"

# 3. Milestone 2.
#   Add enqueuePendingTx, claimInboxBatchTx, markInboxFailedTx (extended),
#   markInboxDeadTx, releaseInboxClaimTx, plus the public enqueueInbox APIs.
#   Then:
cabal test keiro-test --test-options "--match Keiro.Inbox"
git add src/Keiro/Inbox.hs src/Keiro/Inbox/Schema.hs test/Main.hs
git commit -m "$(cat <<'EOF'
feat(inbox): claim/retry/release/dead transitions for two-stage drain

Adds enqueueInbox, claimInboxBatchTx (FOR UPDATE SKIP LOCKED with
visibility-timeout reclaim baked in), the extended markInboxFailedTx,
markInboxDeadTx, and releaseInboxClaimTx. Six new storage tests cover
the new transitions.

ExecPlan: docs/plans/23-add-a-shibuya-inbox-adapter-for-two-stage-integration-event-processing.md
Intention: intention_01ks08ez50edkrn5atc177emr0
EOF
)"

# 4. Milestone 3.
cabal build keiro
git add src/Keiro/Inbox/Adapter.hs keiro.cabal
git commit -m "$(cat <<'EOF'
feat(inbox): introduce Keiro.Inbox.Adapter (Shibuya adapter + tx wrapper)

inboxAdapter polls keiro_inbox, hands rows to a Handler es
IntegrationEvent, and reflects AckDecision back as inbox state
transitions. mkTransactionalInboxHandler restores EP-21 atomic
(handler + mark-completed) semantics under the Shibuya surface.

ExecPlan: docs/plans/23-add-a-shibuya-inbox-adapter-for-two-stage-integration-event-processing.md
Intention: intention_01ks08ez50edkrn5atc177emr0
EOF
)"

# 5. Milestone 4.
cabal test keiro-test
git add test/Main.hs
git commit -m "$(cat <<'EOF'
test(inbox): adapter cases plus dual-adapter coexistence under Shibuya.App

Adds Keiro.Inbox.Adapter cases (drain order, ack mapping, visibility
reclaim, transactional rollback) and extends the cross-context
scenario with a same-process topology: shibuya-kafka-adapter (write
side, via the existing simulator) and Keiro.Inbox.Adapter (work side)
running under one Shibuya.App.runApp.

ExecPlan: docs/plans/23-add-a-shibuya-inbox-adapter-for-two-stage-integration-event-processing.md
Intention: intention_01ks08ez50edkrn5atc177emr0
EOF
)"

# 6. Milestone 5.
git add docs/guides/integration-events-with-kafka.md \
        docs/masterplans/3-implement-inbox-and-outbox-for-kafka-integration-events.md
git commit -m "$(cat <<'EOF'
docs(inbox): document inline vs drained paths and same-process topology

Updates the integration-events guide with the two consume patterns and
the dual-adapter topology. Records EP-23 in MasterPlan 3's Progress,
Decision Log, and Revisions.

ExecPlan: docs/plans/23-add-a-shibuya-inbox-adapter-for-two-stage-integration-event-processing.md
Intention: intention_01ks08ez50edkrn5atc177emr0
EOF
)"
```


## Validation and Acceptance

The plan is complete when **all** of the following are observable:

1. **Schema correctness.** `cabal test keiro-migrations-test` passes,
   including the assertion that `attempt_count`, `next_attempt_at`,
   `claimed_at`, and `keiro_inbox_claimable_idx` exist on a freshly
   migrated database.

2. **Backward compatibility.** Every pre-existing `Keiro.Inbox` test
   case (currently 7 under `describe "Keiro.Inbox"`, plus the 3 under
   `describe "Keiro.Inbox.Kafka"`, plus the 3 cross-context cases)
   passes without modification beyond pattern updates that ignore the
   new `InboxRow` fields.

3. **New storage behavior.** Six new cases under `describe "Keiro.Inbox
   (worker storage)"` pass, covering: pending insert, idempotent
   re-enqueue, concurrent claim with `FOR UPDATE SKIP LOCKED`,
   visibility-timeout reclaim, retry-then-dead transition, claim
   release without attempt bump.

4. **New adapter behavior.** Seven new cases under
   `describe "Keiro.Inbox.Adapter"` pass, covering: source order,
   `AckOk`/`AckRetry`/`AckDeadLetter`/`AckHalt` mapping, visibility
   reclaim through the adapter, and `mkTransactionalInboxHandler`
   rollback when the user's `Tx.Transaction` condemns.

5. **Same-process topology.** The extended
   `describe "Keiro cross-context Kafka integration"` block contains
   a "two-stage drain coexists with the kafka write side" case that:
   * Runs both adapters under one `Shibuya.App.runApp`.
   * Sees three orders flow Kafka → `enqueueInbox` → `inboxAdapter` →
     billing read model.
   * Verifies duplicate Kafka redelivery is suppressed by
     `enqueueInbox` returning `EnqueueDuplicateOf` (no new billing
     row).
   * Drains cleanly via `Shibuya.App.stopAppGracefully` within the
     30-second default timeout.

6. **Docs.** `docs/guides/integration-events-with-kafka.md` contains
   a "Two ways to consume integration events" section with both
   subsections and the topology ASCII diagram.
   `docs/masterplans/3-...md` Progress, Surprises & Discoveries,
   Decision Log, and Revisions sections reflect the follow-up.

Human-observable demonstration (manual):

```bash
# In one terminal, start an ephemeral Postgres and run the keiro-migrate binary.
# In another, start a small executable that runs Shibuya.App.runApp with the
# two adapters from the test fixture against that database, then publish a
# few orders into the simulator. Run:
psql $DB -c "SELECT status, count(*) FROM keiro_inbox GROUP BY status"
# expected: rows transition pending -> processing -> completed within seconds.
```


## Idempotence and Recovery

* **Schema.** The migration is forward-only and uses `IF NOT EXISTS`
  for both columns and the index, so a re-run is a no-op. `codd` is
  responsible for not re-applying a successful migration in the first
  place.

* **Enqueue.** `enqueueInbox` is idempotent under `(source,
  dedupe_key)` — `ON CONFLICT DO NOTHING` plus a `SELECT` fallback
  returns `EnqueueDuplicateOf` rather than failing. Safe to retry on
  any error.

* **Claim.** `claimInboxBatchTx` is exactly-once-per-row because it
  takes `FOR UPDATE SKIP LOCKED` and updates `status = 'processing'`
  atomically. A concurrent worker either sees the row already locked
  (skips it) or sees its status as `processing` after the holder
  commits (filters it out via the `WHERE` clause). No double-claim is
  possible.

* **Crash recovery.** A worker that crashes between claim and ack
  leaves rows in `processing` with stale `claimed_at`. The next claim
  cycle reclaims them via the `claimed_at < $reclaimCutoff` predicate.
  Setting `visibilityTimeout` too low causes premature reclaim (handler
  runs twice for slow events); too high causes long stalls. The
  default of 60 seconds is conservative for typical handler latencies;
  callers should override based on their P99 handler duration.

* **Rollback.** All changes are additive. Reverting the plan means:
  drop the new module, drop the new migration (write a `DROP COLUMN`
  follow-up migration; do **not** drop the table). Existing callers
  of `runInboxTransaction` continue to function regardless.

* **Adapter shutdown.** `Shibuya.App.stopAppGracefully` calls
  `Adapter.shutdown` which flips the TVar and waits one poll interval.
  Any in-flight handler completes (because the ack happens inside
  `processOne` in Shibuya), and any unclaimed rows simply stay in
  `pending`.


## Interfaces and Dependencies

**Libraries already in `keiro.cabal`, reused by this plan:**

* `shibuya-core >= 0.5` — `Shibuya.Adapter.Adapter`, `Shibuya.Core.Ingested.Ingested`, `Shibuya.Core.AckHandle.AckHandle`, `Shibuya.Core.Ack.AckDecision`, `Shibuya.Handler.Handler`. No version bump required.
* `streamly >= 0.11` — `Streamly.Data.Stream` for the adapter's source stream.
* `hasql`, `hasql-transaction`, `hasql-pool` — already used by `Keiro.Inbox.Schema`. No new pool-level helpers needed; `claimInboxBatchTx` is a regular `Hasql.Transaction.Transaction`.
* `time` — `NominalDiffTime` / `UTCTime`.
* `effectful`, `effectful-core` — `Eff es`, `Store :> es`, `IOE :> es`.

**Libraries explicitly **not** added:** `shibuya-kafka-adapter`,
`hw-kafka-client`, `kafka-effectful`. The inbox adapter is transport-
neutral; the same-process test composes the existing in-process Kafka
simulator (already in `test/Main.hs` for EP-22) with the new adapter,
neither of which touches librdkafka.

**New module signatures (final, expected at end of Milestone 3):**

```haskell
module Keiro.Inbox.Adapter where

import Shibuya.Adapter (Adapter (..))
import Shibuya.Handler (Handler)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Keiro.Integration.Event (IntegrationEvent)
import Keiro.Inbox.Types

data InboxAdapterConfig = InboxAdapterConfig
  { adapterName  :: !Text
  , source       :: !Text
  , pollInterval :: !NominalDiffTime
  , claimOptions :: !InboxClaimOptions
  }

defaultInboxAdapterConfig :: Text -> InboxAdapterConfig

inboxAdapter ::
  (IOE :> es, Store :> es) =>
  InboxAdapterConfig ->
  Eff es (Adapter es IntegrationEvent)

mkTransactionalInboxHandler ::
  forall a es.
  (IOE :> es, Store :> es) =>
  (IntegrationEvent -> Tx.Transaction a) ->
  Handler es IntegrationEvent
```

**New types added to `Keiro.Inbox.Types`:**

```haskell
data InboxClaimOptions = InboxClaimOptions
  { batchSize         :: !Int
  , visibilityTimeout :: !NominalDiffTime
  , maxAttempts       :: !Int
  , backoff           :: !BackoffSchedule  -- imported from Keiro.Outbox.Types
  }

data InboxEnqueueOutcome
  = EnqueuedNew
  | EnqueueDuplicateOf !InboxRow

data InboxAckOutcome
  = InboxAcked
  | InboxRetrying !UTCTime
  | InboxDeadLettered !DeadLetterReason
  | InboxClaimReleased

-- InboxStatus gains two constructors:
data InboxStatus
  = InboxPending     -- NEW: written, awaiting handler
  | InboxProcessing
  | InboxCompleted
  | InboxFailed
  | InboxDead        -- NEW: terminal after max_attempts
```

**New functions added to `Keiro.Inbox.Schema`:**

```haskell
enqueuePendingTx ::
  Text -> Text -> IntegrationEvent -> Maybe KafkaDeliveryRef -> UTCTime ->
  Tx.Transaction InboxEnqueueOutcome

claimInboxBatchTx ::
  InboxClaimOptions -> UTCTime -> Tx.Transaction [InboxRow]

markInboxFailedTx ::
  Text -> Text -> Text -> Int -> BackoffSchedule -> UTCTime ->
  Tx.Transaction InboxStatus     -- returns InboxFailed or InboxDead

markInboxDeadTx ::
  Text -> Text -> Text -> UTCTime -> Tx.Transaction ()

releaseInboxClaimTx ::
  Text -> Text -> UTCTime -> Tx.Transaction ()
```

**New functions added to `Keiro.Inbox`:**

```haskell
enqueueInbox ::
  (IOE :> es, Store :> es) =>
  InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef ->
  Eff es (Either InboxError InboxEnqueueOutcome)

enqueueInboxTx ::
  InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef ->
  Tx.Transaction (Either InboxError InboxEnqueueOutcome)
```

**Cross-references to existing code that this plan depends on:**

* `Keiro.Outbox.Types.BackoffSchedule`, `nextDelay`, `ExponentialBackoffOptions` — reused verbatim; the publisher and the inbox adapter share retry semantics by design.
* `Keiro.Outbox.publishClaimedOutbox` — structural reference for the claim loop. Read it once before writing the new claim worker so the SQL and the `drainBatch` recursion match.
* `Shibuya.Adapter.Kafka.kafkaAdapter` + `takeUntilShutdown` (`shibuya-kafka-adapter/.../Shibuya/Adapter/Kafka.hs`) — structural reference for shutdown signaling.
* `Shibuya.Adapter.Mock.listAdapter` (`shibuya-core/.../Shibuya/Adapter/Mock.hs`) — minimal adapter shape for the test fixture.
* `Keiro.ProcessManager.runProcessManagerWorker` (`src/Keiro/ProcessManager.hs`) — reference for "drive a `Shibuya.Adapter` from keiro code".
* `withTwoContexts` and `KafkaTopic` in `test/Main.hs:1248-1314` — reused as-is for the same-process coexistence test.
