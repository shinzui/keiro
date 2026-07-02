---
id: 82
slug: inbox-consume-throughput-single-insert-completion-off-hot-path-gauge-batched-intake-slim-persistence
title: "Inbox consume throughput: single-insert completion, off-hot-path gauge, batched intake, slim persistence"
kind: exec-plan
created_at: 2026-07-01T23:29:49Z
intention: intention_01kwg1jq4de7ya9gmrfeezb949
master_plan: "docs/masterplans/11-keiro-inbox-and-outbox-kafka-throughput-overhaul.md"
---

# Inbox consume throughput: single-insert completion, off-hot-path gauge, batched intake, slim persistence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro's idempotent inbox is the consuming side of cross-service integration events: when a Kafka consumer receives a message, the inbox records the message's identity in the Postgres table `keiro_inbox` and runs the local handler in the same transaction, so redeliveries become observable duplicates instead of double-executions. A 2026-07-01 performance review found that the inbox makes each consumed message more expensive than it needs to be, in four independent ways. When metrics are enabled, every message pays a *second* whole transaction just to run `SELECT COUNT(*)` for a backlog gauge — doubling Postgres round trips for a value that changes meaningfully over seconds, not per message. Every happy-path message writes its row twice inside one transaction (insert as `processing`, update to `completed`) even though the intermediate state is provably unobservable from any other transaction — pure dead-tuple and index churn. Every message durably persists its full payload and ~20 envelope columns even when the operator only wants dedupe. And the API is strictly one-message-one-commit, so consumer throughput per partition is capped by Postgres fsync latency even though the Kafka adapter polls messages in batches.

After this plan: the backlog gauge is recorded by an explicitly scheduled `sampleInboxBacklog` instead of inside the per-message path; successful messages insert their row exactly once, directly as `completed`; a batched intake variant processes N messages under a single commit and falls back to per-message processing when a handler fails, so one poison message cannot poison its batch-mates; payload persistence becomes configurable so dedupe-only deployments stop paying payload WAL on every success; and the write-only index `keiro_inbox_received_idx` is dropped. Observable outcome: a test processes a batch of 50 messages with one `runInboxTransactionBatch` call and the handler effects of all 50 are committed under a single transaction; a message processed with metrics enabled triggers no `COUNT(*)` query.

Dedupe semantics do not weaken: at-most-once handler execution per `(source, dedupe_key)` within the retention window is preserved by the same unique-constraint mechanism as today.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0: Create or extend the `keiro-bench` tasty-bench component with the inbox scenarios (`inbox.single-full`, `inbox.single-nometrics`) against the UNCHANGED code
- [ ] M0: Capture the "Before" measurements (`--csv`), paste the rendered table plus machine notes into Outcomes & Retrospective
- [ ] M1: Remove per-message backlog gauge from `runInboxTransactionWithKey` and `runInboxTransactionWithRetriesKey`; add `sampleInboxBacklog`
- [ ] M1: Update metrics tests; `cabal test keiro-test` green
- [ ] M2: Replace insert-`processing`-then-update with single insert-as-`completed` on the happy path
- [ ] M2: Haddock updates for the now-legacy `processing` status and `InboxInProgress` result; tests green
- [ ] M3: Migration dropping `keiro_inbox_received_idx`; regenerate expected schema; `cabal test keiro-migrations-test` green
- [ ] M4: `runInboxTransactionBatch` with within-batch dedupe, shared single transaction, and per-message poison fallback
- [ ] M4: Batch tests (happy path, in-batch duplicate, poison fallback, cross-batch duplicate)
- [ ] M5: `InboxPersistence` (`PersistFullEnvelope` / `PersistDedupeOnly`) threaded through intake; slim-row tests
- [ ] Final: Add the after-only benches (`inbox.batch-100` after M4, `inbox.single-slim` after M5); re-run all inbox scenarios; record the "After" table and before/after ratios in Outcomes & Retrospective
- [ ] Final: Commit `keiro/bench/baseline-inbox.csv` from the finished code and extend the `bench-regression` Justfile target with the inbox pattern line
- [ ] Final: `just haskell-build`, `cabal test keiro-test`, `cabal test keiro-migrations-test` all green; keiro-dsl conformance fixture still compiles


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The happy path inserts the row directly as `completed` *before* running the handler (insert-first, not handler-first).
  Rationale: Insert-first preserves today's concurrency mechanism unchanged — a concurrent duplicate delivery blocks on the unique index's speculative insert until the first transaction commits, then observes the conflict. Handler-first would require a new post-handler conflict dance (run handler, insert, detect conflict, condemn). Within the transaction the row claims `completed` before the handler has run, but that is invisible to every other transaction and the commit happens only after the handler succeeds; on handler failure the rollback removes the row exactly as today.
  Date: 2026-07-01

- Decision: Keep the `processing` status value, the `InboxProcessing`/`InboxInProgress` constructors, and `markFailedTx` in place; document `processing` as legacy.
  Rationale: Committed `processing` rows can exist in databases written by older code, and the decoder must keep parsing them. Removing constructors is churn with no perf value. The haddocks must state that new code never commits `processing`.
  Date: 2026-07-01

- Decision: The batch variant runs per-message statements inside one transaction rather than a 25-column `unnest` multi-row insert.
  Rationale: The dominant per-message cost is the commit (fsync), which batching already amortizes; handler statements are per-message and sequential regardless, so a multi-row insert does not change the asymptotics. The `unnest` encoder for 25 columns is significant complexity; note it as a future optimization if profiling demands it.
  Date: 2026-07-01

- Decision: On any handler exception inside the batch transaction, the whole batch rolls back and every message is reprocessed individually through the existing retrying single-message path.
  Rationale: Rollback means the batch attempt had no observable effects, so individual reprocessing is safe and reuses the existing, tested poison-message accounting (`recordFailedAttemptTx`, attempt ceiling, `InboxHandlerFailed`). The cost — reprocessing N-1 innocent messages once — is paid only when a batch contains a poison message.
  Date: 2026-07-01

- Decision: `PersistDedupeOnly` empties `payload_bytes` (zero-length, column stays `NOT NULL`) and nulls `attributes`, `traceparent`, `tracestate`, and the five `schema_*` columns; it keeps `message_id`, `event_type`, `source_event_id`, `source_global_position`, `causation_id`, `correlation_id`, `occurred_at`, and the Kafka delivery ref. The failure path (`recordFailedAttemptTx`) always persists the full envelope regardless of the setting.
  Rationale: The kept columns are small fixed-width diagnostics that make duplicate investigation possible; payload and free-form JSON are the WAL cost. A failed row is the operator's dead-letter record and must stay complete. Avoiding an `ALTER TABLE` (keeping `payload_bytes NOT NULL`) keeps M5 migration-free.
  Date: 2026-07-01

- Decision: Persistence is threaded as a new `InboxPersistence` argument on new `...With` variants; the existing exported functions keep their signatures and default to `PersistFullEnvelope`.
  Rationale: `runInboxTransaction` is called by the keiro-dsl conformance fixture (`keiro-dsl/test/conformance-intake-full/HospitalCapacity/IncidentInbox/Integration.hs`) and tests; keeping the old signatures compiling avoids touching generated-adjacent code for a feature those callers don't use.
  Date: 2026-07-01

- Decision: Accept a consciously-reviewed residual risk (raised during plan review, 2026-07-01): the batch transaction holds N speculative-insert locks plus handler row locks for the whole batch duration. During a Kafka consumer-group rebalance overlap, two consumers briefly processing the same partition can deadlock on those locks in opposite orders — where today's per-message transactions would merely block briefly. Postgres resolves the deadlock by aborting one transaction; `trySync` catches it and the per-message fallback path completes all messages correctly.
  Rationale: The failure mode is rare (rebalance windows), self-healing (the fallback is the same code path as the poison-message recovery, exercised by test (c) in M4), and costs only latency, never correctness — the aborted batch rolled back completely. Judged acceptable relative to amortizing one fsync across the batch.
  Date: 2026-07-01

- Decision: Add a tasty-bench benchmark milestone (M0) sharing the `keiro-bench` component with the outbox plan: `inbox.single-full` runs with metrics **enabled** (unlike the outbox benches) because the M1 win is precisely the metrics-gated backlog `COUNT(*)`; after-only benches (`inbox.batch-100`, `inbox.single-slim`) are added when their milestones land and compared against the finished code's single-message numbers; `keiro/bench/baseline-inbox.csv` is committed post-implementation and guarded by the shared `just bench-regression` target (`--baseline`/`--fail-if-slower 25`, manual/local, not CI).
  Rationale: Requested during plan review (2026-07-01) to replace modeled throughput claims with measurements and guard against future regressions. Separate per-area baseline CSVs (`baseline-outbox.csv` / `baseline-inbox.csv`) keep the two plans' final-milestone commits from conflicting on one file.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Haskell monorepo built with cabal; run all commands from the repo root. The `keiro` package hosts the inbox. Terms: an *integration event* (`Keiro.Integration.Event.IntegrationEvent` in `keiro-core`) is the public envelope one bounded context publishes for another — id headers, type/schema info, trace context, and raw `payloadBytes`. The *inbox* records each received event's stable identity `(source, dedupe_key)` in the `keiro_inbox` table and runs the consumer's handler in the same Postgres transaction, making redelivery idempotent. A *handler* here is a `Hasql.Transaction.Transaction a` — a sequence of SQL statements composed into the wrapper's transaction, not arbitrary IO.

Key files:

- `keiro/src/Keiro/Inbox.hs` — the transactional wrappers. `runInboxTransaction` (line 69) computes a dedupe key from an `InboxDedupePolicy` and delegates to `runInboxTransactionWithKey` (line 90), which in one transaction calls `tryInsertProcessingTx`, then on fresh insert runs the handler and `markCompletedTx`, and on conflict branches on the existing row's status (`InboxCompleted → InboxDuplicate`, `InboxProcessing → InboxInProgress`, `InboxFailed → InboxPreviouslyFailed`). After the transaction it records classification counters, and — the hot-path problem — at lines 121–123 runs `for_ mMetrics $ \metrics -> do backlog <- countInboxBacklog; recordInboxBacklog (Just metrics) (fromIntegral backlog)`, a second full transaction per message. `runInboxTransactionWithRetriesKey` (line 161) is the poison-message-aware variant: it wraps the same transaction in `trySync`, records failed attempts via `recordFailedAttemptTx` in a second transaction on exception, retries previously-failed rows below an attempt ceiling, and repeats the same per-message backlog gauge at lines 210–212.
- `keiro/src/Keiro/Inbox/Schema.hs` — SQL. `tryInsertProcessingTx` (line 58): `INSERT ... ON CONFLICT (source, dedupe_key) DO NOTHING RETURNING TRUE` (25 params, status left to the column default `'processing'`), followed on conflict by `selectByKeyStmt` to fetch the existing row. `markCompletedTx` (line 77): `UPDATE ... SET status = 'completed', completed_at = $3, last_error = NULL`. `recordFailedAttemptTx` (line 92): upsert that creates or increments a `failed` row, returning the attempt count. `countInboxBacklog` (line 120): `SELECT COUNT(*) ... WHERE status IN ('processing','failed')`. `garbageCollectCompleted`, `lookupInbox`, `listInbox` complete the surface. Encoders are contravariant `E.Params` over an `EncodedInsert` record (line 148); the row decoder rebuilds an `InboxRow` including a reconstructed `IntegrationEvent`.
- `keiro/src/Keiro/Inbox/Types.hs` — `InboxDedupePolicy` (and the pure `dedupeKeyFor`), `InboxStatus` (`InboxProcessing | InboxCompleted | InboxFailed`), `InboxResult a` (`InboxProcessed a | InboxDuplicate | InboxInProgress | InboxPreviouslyFailed (Maybe Text) | InboxHandlerFailed Text Int`), `InboxError`, `KafkaDeliveryRef`, `parseInboxStatus`.
- `keiro/src/Keiro/Telemetry.hs` — `recordInboxProcessed`/`Duplicates`/`Failed`/`Poisoned` (counters), `recordInboxBacklog` (gauge, line 761).
- `keiro/test/Main.hs` — hspec suite (`cabal test keiro-test`), Postgres-backed via the suite-level template-database fixture from `keiro-test-support` (`withMigratedSuite`, `withFreshStore`); inbox examples live in this file alongside `describe "Keiro.Telemetry metrics"` (line 308).
- `keiro-dsl/test/conformance-intake-full/HospitalCapacity/IncidentInbox/Integration.hs` — the only out-of-package caller: `runInboxTransaction Nothing inboxDedupePolicy event kafka handler` (line 29). Its signature must keep compiling.
- `keiro-migrations/sql-migrations/2026-05-17-02-00-00-keiro-inbox.sql` — creates `keiro_inbox` (primary key `(source, dedupe_key)`, `payload_bytes BYTEA NOT NULL`, `status TEXT NOT NULL DEFAULT 'processing'`) plus `keiro_inbox_received_idx (received_at)` and the partial `keiro_inbox_completed_idx (completed_at) WHERE status = 'completed'`. `2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql` later added `attempt_count` and the partial `keiro_inbox_backlog_idx (status) WHERE status IN ('processing','failed')`. Migrations are forward-only codd files applied into the `kiroku` schema; `keiro-migrations/expected-schema/` is the drift snapshot regenerated by `cabal run keiro-write-expected-schema` and checked by `cabal test keiro-migrations-test`.

Why the double write is safe to remove: the `processing` row inserted by `tryInsertProcessingTx` lives only inside the uncommitted transaction. A concurrent transaction inserting the same `(source, dedupe_key)` does not see it and does not skip — it *blocks* on the unique index's speculative insertion lock until the first transaction commits or aborts, then either conflicts (first committed; the row it reads is already `completed`) or proceeds (first aborted; no row). So no observer can ever witness `processing` from this code path, and the insert-then-update is pure write amplification: one dead tuple per message plus non-HOT update overhead (the status change touches `keiro_inbox_backlog_idx`'s predicate and `completed_at` is `keiro_inbox_completed_idx`'s key, so the update maintains indexes rather than staying heap-only).

`keiro_inbox_received_idx` is maintained on every insert but serves only `listInbox`'s `ORDER BY received_at, dedupe_key` — a documented test helper ("Used by tests; not intended for application traffic", `Schema.hs:109`). Dropping it removes one index write per consumed message; `listInbox` degrades to a seq-scan sort, which is fine for its stated purpose.


## Plan of Work


### Milestone 0 — benchmark scenarios and baseline capture

Scope: measured before/after evidence for the inbox changes, plus a standing regression guard, built on the shared `keiro-bench` component. This milestone is implemented, run, and committed **before any behavior change**.

The `keiro-bench` component is a registered integration point with the outbox plan (`docs/plans/81-outbox-publisher-throughput-run-claiming-batch-publish-off-hot-path-maintenance.md`, Milestone 0): a `benchmark` stanza in `keiro/keiro.cabal` (`type: exitcode-stdio-1.0`, `hs-source-dirs: bench`, `main-is: Main.hs`) whose one new dependency is **`tasty-bench`** — chosen for its built-in recording and regression tooling (`--csv FILE` records measurements, `--baseline FILE` compares against a recorded CSV, `--fail-if-slower N` exits non-zero on a regression above N percent). If the outbox plan has already landed, the component exists — add the `inbox.*` benches to `keiro/bench/Main.hs`. If not, create the component exactly as that plan's Milestone 0 describes (including the nix note: if the flake cannot resolve `tasty-bench`, add it to the Haskell package overrides in `nix/`) and add only the inbox scenarios; the outbox plan will append its own.

Harness pattern: provision one migrated scratch database for the run via the `keiro-test-support` fixture machinery (`Keiro.Test.Postgres`; see `keiro/test/Main.hs`'s `withMigratedSuite` usage), acquire a store handle once, and give every bench a self-contained action that starts with `TRUNCATE keiro_inbox` and then processes a fixed workload — tasty-bench runs each action many times, so the clean-slate step must live inside the action. Truncation and event synthesis are identical before and after the change, so they dilute the measured ratio slightly but only in the conservative direction; note this beside the recorded numbers.

Inbox scenarios (fixed constants in `bench/Main.hs`; select with `-p` patterns):

- `inbox.single-full` — synthesize 2,000 distinct `IntegrationEvent`s (1 KiB payloads, distinct `messageId`s, a `KafkaDeliveryRef` each), process them one at a time with `runInboxTransaction`, a trivial `pure ()` handler, and **metrics enabled** — construct the `KeiroMetrics` once outside the action, using the same in-memory meter-provider setup the telemetry specs use (see `describe "Keiro.Telemetry metrics"` in `keiro/test/Main.hs`). Metrics-on is essential here: the per-message backlog `COUNT(*)` transaction that Milestone 1 removes only runs with metrics enabled, so this scenario is the one that shows M1's win.
- `inbox.single-nometrics` — the same workload with `Nothing` metrics, isolating the M2 single-insert win from the M1 gauge win.

After-only benches, added in the milestone that creates each capability (they have no "before" — their baseline is the finished code's `inbox.single-*` numbers): `inbox.batch-100` (Milestone 4: the same 2,000 messages via `runInboxTransactionBatch` in batches of 100) and `inbox.single-slim` (Milestone 5: `runInboxTransactionWith` and `PersistDedupeOnly`).

Baseline protocol: on an idle machine, run

```bash
cabal bench keiro-bench --benchmark-options="-p inbox --csv bench-before-inbox.csv"
```

and paste the rendered table (mean time per action, ±stdev) into Outcomes & Retrospective under "Baseline (before)" with a one-line machine note (CPU, storage, local-socket vs networked Postgres — fsync latency dominates this workload). Keep `bench-before-inbox.csv` out of git; it is scratch for the final comparison.

Final comparison (after Milestone 5): re-run all `inbox.*` benches, record the "After" table and per-scenario ratios in Outcomes & Retrospective, write the finished code's measurements to `keiro/bench/baseline-inbox.csv`, **commit that CSV**, and extend the `bench-regression` Justfile target (created by whichever plan lands first) with the inbox line:

```text
[group('haskell')]
bench-regression:
    cabal bench keiro-bench --benchmark-options="-p outbox --baseline keiro/bench/baseline-outbox.csv --fail-if-slower 25"
    cabal bench keiro-bench --benchmark-options="-p inbox --baseline keiro/bench/baseline-inbox.csv --fail-if-slower 25"
```

The committed baseline reflects the primary dev machine; `bench-regression` is a local/manual guard, deliberately not wired into `just verify` or CI where shared-runner noise would make a percentage gate flaky.

Acceptance for M0: `cabal bench keiro-bench --benchmark-options="-p inbox"` runs both scenarios to completion against unchanged code and the baseline table is recorded in this plan.


### Milestone 1 — backlog gauge off the per-message path

Scope: no gauge work inside message processing; an explicit sampler the application schedules. At the end, processing a message with metrics enabled issues exactly one transaction (the handler transaction) on the happy path.

In `keiro/src/Keiro/Inbox.hs`, delete the two `for_ mMetrics …` blocks (lines 121–123 and 210–212). The classification counters (`recordInboxProcessed` etc.) stay exactly where they are. Add and export:

```haskell
-- | Count the inbox backlog (non-terminal rows: legacy 'processing' rows and
-- 'failed' rows) and record the gauge. Does nothing when metrics are 'Nothing'.
-- Schedule this on its own interval; it is intentionally not part of the
-- per-message intake path.
sampleInboxBacklog :: (Store :> es) => Maybe KeiroMetrics -> Eff es ()
sampleInboxBacklog mMetrics =
    for_ mMetrics $ \metrics -> do
        backlog <- countInboxBacklog
        recordInboxBacklog (Just metrics) (fromIntegral backlog)
```

The name and shape mirror `sampleOutboxBacklog` from the outbox plan (`docs/plans/81-outbox-publisher-throughput-run-claiming-batch-publish-off-hot-path-maintenance.md`, Milestone 4) — a deliberate integration point recorded in the MasterPlan (`docs/masterplans/11-keiro-inbox-and-outbox-kafka-throughput-overhaul.md`); if this plan is implemented first, establish the convention here. Update any example under `describe "Keiro.Telemetry metrics"` in `keiro/test/Main.hs` that asserts the inbox backlog gauge is recorded by `runInboxTransaction*`; replace with examples asserting `sampleInboxBacklog` records it and the wrappers do not. Acceptance: `cabal test keiro-test` green.


### Milestone 2 — single-insert completion

Scope: the happy path writes the inbox row once. At the end, a successfully processed fresh message produces a row whose only version is `completed`.

In `keiro/src/Keiro/Inbox/Schema.hs`, rename `tryInsertProcessingTx` to `tryInsertCompletedTx` (update the export list and both call sites in `Keiro.Inbox`) and change `tryInsertStmt` to set the terminal state at insert: add `status` and `completed_at` to the column list with values `'completed'` and `$25` (`received_at` and `completed_at` can share the existing `now` parameter — they are the same instant in this design, and the commit only happens after the handler succeeds, so the timestamp is truthful to within the transaction's duration; if that tolerance is unacceptable, add a 26th parameter, but sharing is simpler).

In `keiro/src/Keiro/Inbox.hs`, remove the `markCompletedTx src dedupe now` call from the fresh-insert branch of both wrappers (`Inbox.hs:107` and `:181`) — the row is already complete. Keep `markCompletedTx` itself and keep calling it in `runInboxTransactionWithRetriesKey`'s retry branch (`Inbox.hs:189-192`), where a committed `failed` row genuinely transitions to `completed`.

Update haddocks: the module header of `Keiro.Inbox` (the "Inserts the inbox row with status @processing@" sentence and the transaction-lifecycle paragraph), `tryInsertCompletedTx`'s docs, and `InboxStatus`/`InboxResult` in `keiro/src/Keiro/Inbox/Types.hs` — state that `processing` is a legacy on-disk value that current code never commits and that `InboxInProgress` is only reachable when reading such legacy rows. Do not change the table's `DEFAULT 'processing'` — the insert now always supplies `status` explicitly, and changing the default would need a migration for zero benefit.

Tests in `keiro/test/Main.hs`: after a successful `runInboxTransaction`, `lookupInbox` shows `status = InboxCompleted` with `completedAt` set (verify whether already asserted); add an example that a handler exception under plain `runInboxTransaction` leaves *no* row (rollback), and one that a redelivery after success returns `InboxDuplicate` without re-running the handler (count invocations with an `IORef`, or by counting rows the handler writes to a scratch table). These pin the semantics the rewrite must preserve. Acceptance: `cabal test keiro-test` green.


### Milestone 3 — drop the write-only received_at index

Scope: one fewer index maintenance per consumed message. Create `keiro-migrations/sql-migrations/<now>-keiro-inbox-drop-received-idx.sql` (real current timestamp, `YYYY-MM-DD-HH-MM-SS-` prefix, sorting after all existing files):

```sql
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database.
SET search_path TO kiroku, pg_catalog;

-- keiro_inbox_received_idx served only the listInbox test helper's ordering
-- but was maintained on every consumed message. Retention GC uses
-- keiro_inbox_completed_idx; the backlog gauge uses keiro_inbox_backlog_idx.
DROP INDEX IF EXISTS keiro_inbox_received_idx;
```

Regenerate the expected schema and run the drift test (Concrete Steps). Coordination note from the MasterPlan: the outbox plan (`docs/plans/81-...md`) also adds a migration and regenerates `keiro-migrations/expected-schema/`; whichever plan lands second must regenerate on top of the other's committed state. Acceptance: `cabal test keiro-migrations-test` green; the expected-schema diff removes exactly `keiro_inbox_received_idx`.


### Milestone 4 — batched intake

Scope: amortize one commit across a poll batch. At the end this exists in `keiro/src/Keiro/Inbox.hs` (the `InboxPersistence` parameter arrives in Milestone 5; if implementing M4 first, build it without and add the parameter in M5):

```haskell
-- | Process a batch of deliveries under one transaction and one commit.
-- Results are returned in input order. Within-batch duplicates (same
-- computed dedupe key) run the handler for the first occurrence only;
-- later occurrences report 'InboxDuplicate'. If any handler throws, the
-- whole batch rolls back (no effects) and every delivery is reprocessed
-- individually via the retrying single-message path, so one poison
-- message costs its batch-mates one extra attempt but never their results.
runInboxTransactionBatch ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Int ->                                   -- attempt ceiling, as in runInboxTransactionWithRetries
    InboxDedupePolicy ->
    [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es [Either InboxError (InboxResult a)]
```

Implementation shape. First compute each delivery's dedupe key with the existing pure `dedupeKeyFor`; deliveries whose key computation fails become `Left` results immediately and take no further part. Mark within-batch repeats: for keys seen earlier in the batch, the later delivery's result is fixed to `Right InboxDuplicate` without touching the database (first occurrence wins — the same outcome a redelivery would get after commit). Then run **one** `runTransaction` that, for each remaining delivery in input order, executes the same per-message logic as `runInboxTransactionWithRetriesKey`'s transaction body: `tryInsertCompletedTx`; on fresh insert run the handler; on conflict branch on the existing row's status, including the retry-below-ceiling branch (handler + `markCompletedTx`) and the at-ceiling `InboxPreviouslyFailed` branch. Factor that shared per-message body out of `runInboxTransactionWithRetriesKey` into an internal function (suggested shape: `attemptOneTx :: Int -> Text -> Text -> IntegrationEvent -> Maybe KafkaDeliveryRef -> UTCTime -> (IntegrationEvent -> Tx.Transaction a) -> Tx.Transaction (InboxResult a)`) so the batch and single paths cannot drift.

Wrap the batch transaction in `trySync`. On `Left _` (any handler threw, or the transaction was condemned), the rollback guarantees nothing happened; reprocess every delivery — including the ones earlier marked as within-batch duplicates, whose "first occurrence" no longer committed, so recompute the whole plan per message — by calling the existing `runInboxTransactionWithRetriesKey` one message at a time, and return those results in input order. This fallback records failed attempts and poison accounting exactly as the single-message API does today. On `Right results`, record the classification counters once per result (the same mapping the single path uses at `Inbox.hs:202-209`). Do not record any backlog gauge here (Milestone 1's rule).

Tests in `keiro/test/Main.hs`: (a) 50 distinct messages, handler inserts a row into a scratch table → one call returns 50 `InboxProcessed`, all scratch rows present, `listInbox` shows 50 `completed` rows; (b) in-batch duplicate: the same event twice in one batch → first `InboxProcessed`, second `InboxDuplicate`, handler effects present once; (c) poison fallback: batch of 5 where message 3's handler throws → messages 1, 2, 4, 5 end `InboxProcessed` (via fallback), message 3 ends `InboxHandlerFailed` with attempt count 1 and a `failed` row recording the error, and the scratch-table effects of 1, 2, 4, 5 are present exactly once; (d) cross-batch duplicate: a message processed in an earlier batch reports `InboxDuplicate` in a later one. Test (c) also structurally proves single-transaction batching: if members committed separately, the poison message could not have rolled back its batch-mates' first attempt. Acceptance: `cabal test keiro-test` green.


### Milestone 5 — slim payload persistence

Scope: make success-path payload persistence opt-out. In `keiro/src/Keiro/Inbox/Types.hs` add:

```haskell
-- | How much of the integration-event envelope the inbox persists on the
-- success path. The failure path always persists the full envelope: a failed
-- inbox row is the dead-letter record and must be complete.
data InboxPersistence
    = PersistFullEnvelope   -- ^ Today's behavior; the default everywhere.
    | PersistDedupeOnly     -- ^ Empty payload; no attributes, trace, or schema columns.
    deriving stock (Generic, Eq, Show)
```

In `keiro/src/Keiro/Inbox/Schema.hs`, give `toEncodedInsert` (and therefore `tryInsertCompletedTx`) an `InboxPersistence` parameter. Under `PersistDedupeOnly` set: `payloadBytes = ""` (zero-length strict `ByteString`; the column stays `NOT NULL`, no migration), `attributes = Nothing`, `traceparent = Nothing`, `tracestate = Nothing`, and all five `schema_*` fields `Nothing`; keep `message_id`, `event_type`, `destination`, `source_event_id`, `source_global_position`, `causation_id`, `correlation_id`, `occurred_at`, and the Kafka topic/partition/offset. `recordFailedAttemptTx` keeps building its insert with `PersistFullEnvelope` unconditionally.

In `keiro/src/Keiro/Inbox.hs`, thread the setting through new `...With` variants — `runInboxTransactionWith` and `runInboxTransactionWithRetriesWith` (full signatures in Interfaces and Dependencies) — and add the `InboxPersistence` parameter to `runInboxTransactionBatch` (new in this plan, so it takes the parameter directly rather than growing a variant). The existing exported functions delegate with `PersistFullEnvelope`, keeping `keiro/test/Main.hs` call sites and `keiro-dsl/test/conformance-intake-full/HospitalCapacity/IncidentInbox/Integration.hs` compiling unchanged. Document on `InboxRow` (`Keiro.Inbox.Types`) that rows written under `PersistDedupeOnly` decode with an empty `payloadBytes`.

Tests: process a message with `PersistDedupeOnly` → `InboxProcessed`, `lookupInbox` shows empty payload, `Nothing` attributes/trace, but intact `message_id` and Kafka ref; redelivery still reports `InboxDuplicate`; a *failing* handler under `PersistDedupeOnly` (retries variant) leaves a `failed` row with the **full** payload. Acceptance: `cabal test keiro-test` green.


## Concrete Steps

All commands from the repo root; the suites need local Postgres:

```bash
just postgres-start                    # idempotent
cabal build keiro                      # after each code milestone
cabal test keiro-test                  # Postgres-backed hspec suite
```

Milestone 0 (before any behavior change) and again after Milestone 5:

```bash
cabal bench keiro-bench --benchmark-options="-p inbox --csv bench-before-inbox.csv"      # M0 baseline
cabal bench keiro-bench --benchmark-options="-p inbox --csv keiro/bench/baseline-inbox.csv"  # after M5; commit this CSV
just bench-regression                  # standing guard: --baseline + --fail-if-slower 25
```

Milestone 3 additionally:

```bash
cabal run keiro-write-expected-schema
git diff -- keiro-migrations/sql-migrations keiro-migrations/expected-schema
cabal test keiro-migrations-test
```

Expected: the expected-schema diff deletes `.../schemas/kiroku/tables/keiro_inbox/indexes/keiro_inbox_received_idx` and nothing unexplained; both suites report success. Before finishing, confirm the keiro-dsl conformance packages still build (they consume `Keiro.Inbox`): `cabal build all` (or the narrower `cabal build keiro-dsl` plus its test targets listed in `keiro-dsl/keiro-dsl.cabal`).

Commit after each milestone with a conventional-commit message and both trailers, e.g.:

```text
perf(keiro): insert inbox rows once, directly as completed

MasterPlan: docs/masterplans/11-keiro-inbox-and-outbox-kafka-throughput-overhaul.md
ExecPlan: docs/plans/82-inbox-consume-throughput-single-insert-completion-off-hot-path-gauge-batched-intake-slim-persistence.md
```


## Validation and Acceptance

Behavioral acceptance, all as `cabal test keiro-test` examples:

1. Gauge off hot path: with metrics enabled, `runInboxTransaction` records processed/duplicate counters but never the backlog gauge; `sampleInboxBacklog` records it on demand.
2. Single write: a fresh successful message yields a `completed` row with `completedAt` set; a handler exception yields no row; a redelivery yields `InboxDuplicate` with the handler having run exactly once. (The single-version property is additionally validated structurally: `markCompletedTx` no longer appears in the fresh-insert path.)
3. Batch: 50 messages, one `runInboxTransactionBatch` call → 50 `InboxProcessed` and all handler effects committed; a batch with one poison message completes the other members via fallback and accounts the poison one with `InboxHandlerFailed` and attempt count 1.
4. Slim persistence: dedupe-only rows have empty payload but full dedupe behavior; failure rows keep the full payload regardless of the setting.
5. Schema: `cabal test keiro-migrations-test` green with `keiro_inbox_received_idx` gone.
6. Compatibility: keiro-dsl conformance intake fixtures compile and their suites pass unchanged.

7. Measured throughput: the M0 tasty-bench scenarios re-run on the finished code show, on the same machine as the baseline, at least **1.5×** improvement on `inbox.single-full` (M1 gauge removal plus M2 single insert; the modeled estimate is ~2×) and at least **1.2×** on `inbox.single-nometrics` (M2 alone); and the after-only `inbox.batch-100` bench is at least **3×** faster than the finished code's own `inbox.single-full`. Advisory acceptance recorded in Outcomes & Retrospective, not CI gates — wall-clock database benchmarks are machine-dependent; falling short is a stop-and-investigate signal.
8. Regression guard in place: `keiro/bench/baseline-inbox.csv` is committed from the finished code and `just bench-regression` exits zero against it (and would exit non-zero if a future change slowed a scenario by more than 25 %).

The benchmark exercises the inbox against a trivial handler, so it measures keiro's per-message overhead — real deployments add handler work on top. The commit-amortization claim is additionally validated structurally through test 3's rollback behavior (impossible if batch members committed separately).


## Idempotence and Recovery

Code milestones are ordinary edits; rebuild and retest freely. The migration is `DROP INDEX IF EXISTS` — re-runnable; codd is forward-only, so if the index turns out to be wanted after the migration has reached a shared database, add a new forward migration recreating it (`CREATE INDEX IF NOT EXISTS keiro_inbox_received_idx ON keiro_inbox (received_at)`) rather than editing history. `cabal run keiro-write-expected-schema` is deterministic from the migration set; if its diff shows outbox objects this plan didn't touch, the outbox plan (`docs/plans/81-...md`) merged first — rebase and regenerate. Milestone 4's fallback path is itself the recovery mechanism for batch failures; it reuses the single-message path verbatim (via the shared `attemptOneTx`), so a defect there would equally affect the existing API and be caught by its existing tests.


## Interfaces and Dependencies

The library changes need no new packages: `hasql`/`hasql-transaction` (statements, `Tx.Transaction`), `effectful` (`Eff`, `IOE`, `trySync`), `kiroku` (`Store`, `runTransaction`), existing telemetry. The one new package is `tasty-bench`, confined to the shared `keiro-bench` benchmark stanza (see Milestone 0 and the outbox plan's Milestone 0); it never enters the library dependency graph. End-state additions to module `Keiro.Inbox` (full signatures):

```haskell
sampleInboxBacklog :: (Store :> es) => Maybe KeiroMetrics -> Eff es ()

runInboxTransactionBatch ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics -> Int -> InboxDedupePolicy -> InboxPersistence ->
    [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es [Either InboxError (InboxResult a)]

runInboxTransactionWith ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics -> InboxPersistence -> InboxDedupePolicy ->
    IntegrationEvent -> Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))

runInboxTransactionWithRetriesWith ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics -> InboxPersistence -> Int -> InboxDedupePolicy ->
    IntegrationEvent -> Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))
```

`Keiro.Inbox.Types` gains `InboxPersistence`. `Keiro.Inbox.Schema`'s `tryInsertProcessingTx` becomes `tryInsertCompletedTx` with an added `InboxPersistence` parameter (`Schema` is an internal surface; its only importers are `Keiro.Inbox` and tests). All currently exported functions — `runInboxTransaction`, `runInboxTransactionWithKey`, `runInboxTransactionWithRetries`, `runInboxTransactionWithRetriesKey`, `markFailedTx`, `lookupInbox`, `listInbox`, `garbageCollectCompleted`, `countInboxBacklog` — keep their exact signatures, so the keiro-dsl conformance fixture and any downstream service code compile without edits.


---

Revision note (2026-07-01): Added a Decision Log entry recording the residual batch-transaction deadlock risk during consumer-group rebalance overlap (self-healing via the per-message fallback), surfaced during pre-implementation review. No milestone content changed.

Revision note (2026-07-01, later): Added Milestone 0 — inbox scenarios (`inbox.single-full` with metrics enabled, `inbox.single-nometrics`) on the shared tasty-bench `keiro-bench` component, run against unchanged code for a recorded "Before" baseline; after-only benches (`inbox.batch-100`, `inbox.single-slim`) added as their milestones land; final re-run recorded as a before/after comparison, with `keiro/bench/baseline-inbox.csv` committed and the shared `just bench-regression` target extended as a standing regression guard. Progress, Concrete Steps, Validation and Acceptance (advisory ratio gates 1.5×/1.2×/3×), Interfaces (tasty-bench, bench-only), and the Decision Log were updated accordingly. Requested by the user to measure before/after and protect the improvement going forward.
