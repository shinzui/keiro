---
id: 81
slug: outbox-publisher-throughput-run-claiming-batch-publish-off-hot-path-maintenance
title: "Outbox publisher throughput: run claiming, batch publish, off-hot-path maintenance"
kind: exec-plan
created_at: 2026-07-01T23:29:49Z
intention: intention_01kwg1jq4de7ya9gmrfeezb949
master_plan: "docs/masterplans/11-keiro-inbox-and-outbox-kafka-throughput-overhaul.md"
---

# Outbox publisher throughput: run claiming, batch publish, off-hot-path maintenance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro's durable outbox moves integration events from Postgres into Kafka. Today its publisher worker is throttled far below what Kafka can absorb, for two structural reasons. First, the claim query's ordering predicate admits at most **one row per message key per pass** (and one row per *source*, total, under the `PerSourceStream` policy): a row is skipped whenever any earlier same-key row is non-terminal, and "non-terminal" includes `pending` rows sitting right next to it in the same ready set. Ten pending events for one aggregate therefore drain one per worker pass, each pass costing several Postgres round trips. Second, the worker publishes strictly sequentially — one record, one broker acknowledgement, one `UPDATE` transaction, repeat — which defeats the Kafka producer's batching entirely.

After this plan, a burst of N same-key rows is claimed as one contiguous, ordered run and drained in a single pass; the whole claimed batch is handed to a batch-shaped publish function so a transport adapter can pipeline it; successful rows are marked `sent` in one bulk `UPDATE`; and the per-pass fixed costs (stuck-row sweeping, backlog gauge `COUNT(*)`) move out of the hot path into a separate maintenance pass the application schedules less frequently. A new partial index lets the claim scan walk rows in claim order and stop at the batch limit instead of sorting the whole backlog. Observable outcome: a test enqueues 10 events for one key, runs **one** `publishClaimedOutbox` pass, and all 10 are published in order and marked `sent` — today that takes 10 passes.

Per-key ordering guarantees do not weaken. The invariant before and after: for any message key, rows are handed to the transport in `(created_at, outbox_id)` order, and a failed row blocks later same-key rows until it is retried successfully or dead-lettered.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: Add the `keiro-bench` tasty-bench component with the outbox scenarios (`outbox.hot-key`, `outbox.hot-key-nolatency`, `outbox.multi-key`) against the UNCHANGED code (completed 2026-07-02T00:02:14Z)
- [x] M0: Capture the "Before" measurements (`--csv`), paste the rendered table plus machine notes into Outcomes & Retrospective (completed 2026-07-02T00:02:14Z)
- [ ] M1: Rewrite `claimStmt` SQL in `keiro/src/Keiro/Outbox/Schema.hs` to claim contiguous per-key (and per-source) runs
- [ ] M1: Update existing outbox claim tests in `keiro/test/Main.hs` that assert one-row-per-key claiming; add run-claiming tests
- [ ] M2: Add migration `keiro-migrations/sql-migrations/<timestamp>-keiro-outbox-claim-order-index.sql`
- [ ] M2: Regenerate expected schema (`cabal run keiro-write-expected-schema`) and pass `cabal test keiro-migrations-test`
- [ ] M3: Change `publishClaimedOutbox` publish argument to batch shape; add `markOutboxSentBatch` and `markOutboxSkippedTx` to `Keiro.Outbox.Schema`
- [ ] M3: Implement per-key prefix outcome processing (sent prefix, failed pivot, skipped suffix) and `StopTheLine` sequential mode
- [ ] M3: Update all `publishClaimedOutbox` call sites and tests
- [ ] M4: Add `outboxMaintenancePass` + `sampleOutboxBacklog`; remove sweep and backlog gauge from `publishClaimedOutbox`
- [ ] M4: Update tests that relied on the publish pass doing reclamation; full `just haskell-build` and `cabal test keiro-test` green
- [ ] Final: Re-run the identical benchmark scenarios on the finished code; record the "After" table and before/after ratios in Outcomes & Retrospective; check the advisory ratio expectations in Validation and Acceptance
- [ ] Final: Commit `keiro/bench/baseline-outbox.csv` from the finished code and add the `bench-regression` Justfile target (`--baseline` + `--fail-if-slower`) as the standing regression guard


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: `tasty-bench` measures CPU time by default; the outbox benchmark's simulated broker uses `threadDelay` to model acknowledgement latency, so the benchmark command must pass `--time-mode wall` or the 1 ms per publish invocation cost is largely invisible.
  Evidence:
  ```text
  tasty-bench README: --time-mode controls whether to measure CPU time (default) or wall-clock time.
  ```


## Decision Log

Record every decision made while working on the plan.

- Decision: Claim safety against concurrent workers is enforced by a two-stage filter (pre-filter on "blocked by a non-ready earlier row", post-filter on "earlier non-terminal row outside the locked candidate set") rather than a single predicate.
  Rationale: A single "earlier rows must be ready" predicate reintroduces a cross-worker ordering race: `FOR UPDATE SKIP LOCKED` silently drops a row another worker is claiming, and its successors would sail through. Membership in the locked candidate set is the only proof that *this* statement owns the predecessor. See "The new claim query" in Plan of Work for the full argument.
  Date: 2026-07-01

- Decision: Rows claimed but skipped because an earlier same-key row failed in the same batch are marked `failed` with `attempt_count` decremented back and `next_attempt_at = now`.
  Rationale: The claim increments `attempt_count` up front. Without the decrement, a persistently failing head with a deep tail would inflate the tail's attempt counts every pass and dead-letter rows that were never actually attempted.
  Date: 2026-07-01

- Decision: `StopTheLine` publishes sequentially (singleton batches through the same batch-shaped publish function), halting at the first failure. All other policies publish the full claimed batch in one call.
  Rationale: `StopTheLine` exists for operator-reviewed correctness; publishing rows after the failure point violates its intent. Unifying on the batch signature keeps one publish contract.
  Date: 2026-07-01

- Decision: Per-row OpenTelemetry producer spans are replaced by one producer span per publish batch; per-record spans become the transport adapter's responsibility.
  Rationale: The worker no longer wraps individual produce calls, so a per-row span would measure nothing real. The batch span keeps failure visibility (`error.type`, error status) at the worker level.
  Date: 2026-07-01

- Decision: Existing indexes (`keiro_outbox_pending_idx`, `keiro_outbox_head_of_line_idx`, `keiro_outbox_source_order_idx`, `keiro_outbox_sent_gc_idx`) are kept unchanged; this plan only adds `keiro_outbox_claim_order_idx`.
  Rationale: The head-of-line partial indexes serve the rewritten `NOT EXISTS` probes; `pending_idx` serves the backlog count and sweeps. Index consolidation is a separate concern with its own risk profile.
  Date: 2026-07-01

- Decision: Accept two consciously-reviewed residual risks (raised during plan review, 2026-07-01). (a) The per-key prefix-failure guarantee ("if row i of key k failed, no later row of k was delivered by the same publish call") moves from being true by construction (sequential awaited publishes) to a documented transport contract; keiro's worker-side tests enforce the marking logic but cannot enforce a real adapter's producer configuration (idempotent producer, bounded in-flight, purge-on-terminal-failure, or per-key chunking). (b) After maintenance extraction, a deployment that schedules the publisher but not `outboxMaintenancePass` never reclaims crashed-worker `publishing` rows, which then block their keys indefinitely — previously reclamation happened implicitly on every publish pass.
  Rationale: (a) is inherent to batched publishing and is the industry-standard trade (Kafka's own ordering guarantee has the same shape); the contract is stated in the `publishClaimedOutbox` haddock and this plan's M3. (b) is mitigated by the M4 doc updates, `defaultMaintenanceOptions`, and the explicit test that a publish pass does not reclaim — making the split visible rather than accidental. Both risks were judged acceptable relative to the ~2 orders of magnitude of publish throughput recovered.
  Date: 2026-07-01

- Decision: Add a tasty-bench benchmark milestone (M0) that runs before any behavior change, with a simulated broker (fixed 1 ms per publish invocation + 10 µs per record) instead of a real Kafka cluster, `Nothing` metrics, and seed/truncate inside the measured action; after implementation, commit `keiro/bench/baseline-outbox.csv` and add a `just bench-regression` target using tasty-bench's `--baseline`/`--fail-if-slower 25` as a standing, manually-run regression guard (not wired into `just verify`/CI).
  Rationale: Requested during plan review (2026-07-01) to replace modeled throughput claims with measurements and to guard the win against future regressions. The simulated broker keeps the benchmark hermetic and deterministic while modeling exactly the cost batching amortizes (awaited round trips per invocation); `Nothing` metrics and in-action seeding both bias conservatively against the new code; the guard stays out of CI because wall-clock database benchmarks on shared runners would make a percentage gate flaky.
  Date: 2026-07-01

- Decision: Run the outbox benchmark with `--time-mode wall`.
  Rationale: The simulated broker uses `threadDelay` to model network/broker acknowledgement latency. `tasty-bench` defaults to CPU time, which is useful for pure CPU benchmarks but would under-measure the latency this plan is explicitly trying to amortize.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### Baseline (Before) — Milestone 0

Command:

```bash
cabal bench keiro-bench --benchmark-options="-p outbox --time-mode wall --csv bench-before-outbox.csv"
```

Machine note: Darwin arm64 on Apple M1 Max; the benchmark used the suite-level ephemeral PostgreSQL fixture over a local Unix socket. The CSV was written by Cabal under `keiro/bench-before-outbox.csv`; it is scratch baseline data for the final comparison and is intentionally not committed. Each measured action truncates and reseeds `keiro_outbox`, so the absolute times include setup work that is identical before and after and conservatively dilutes the expected speedup.

Rendered output:

```text
All
  outbox
    hot-key:            OK
      22.384 s +/- 3.15 s
    hot-key-nolatency:  OK
      18.933 s +/- 287 ms
    multi-key:          OK
      4.838 s +/- 333 ms

All 3 tests passed (137.77s)
```

CSV evidence:

```text
Name,Mean (ps),2*Stdev (ps)
All.outbox.hot-key,22383601399807,3146036735370
All.outbox.hot-key-nolatency,18933346000177,287227403730
All.outbox.multi-key,4838196799998,332607956520
```


## Context and Orientation

This repository is a Haskell monorepo built with cabal (run all commands from the repo root, `/Users/shinzui/Keikaku/bokuno/keiro`, or wherever the repo is checked out — everything below uses repo-relative paths). The `keiro` package is an event-sourcing framework; the *outbox* is its durable handoff for publishing integration events to Kafka: a service decides to publish by inserting a row into the Postgres table `keiro_outbox` (inside its own transaction), and a separate *publisher worker* later drains rows to the broker and records the result. keiro deliberately has no Kafka library dependency: the worker takes a caller-supplied publish function, and `keiro/src/Keiro/Outbox/Kafka.hs` only converts rows to a transport-neutral `KafkaProducerRecord`.

Key files:

- `keiro/src/Keiro/Outbox.hs` — the worker `publishClaimedOutbox` (currently lines 279–356) and the producer-subscription helpers. The worker today: calls `requeueStuckOutbox` (stuck-row sweep), records reclaimed/dead-letter counters, calls `claimOutboxBatch`, records a backlog gauge via `countOutboxBacklog` when metrics are on, then `drainBatch` walks the claimed rows one at a time — each row gets a `withProducerSpan`-wrapped call to `publish :: OutboxRow -> Eff es PublishOutcome`, then either `markOutboxSent` (its own transaction) or `markOutboxFailedTx`.
- `keiro/src/Keiro/Outbox/Schema.hs` — all SQL. `claimSql` (lines 359–397) builds the claim statement from a per-policy predicate (`policyPredicate`, lines 332–357). `markSentStmt` (line 493) updates one row. `enqueueOutboxStmt`, `requeueStuckStmt`, `deadLetterStuckStmt`, `countBacklogStmt`, `gcSentStmt` are the rest of the surface. Statements are `preparable` hasql `Statement`s with contravariant `E.Params` encoders and a shared 29-column `outboxRowDecoder`.
- `keiro/src/Keiro/Outbox/Types.hs` — `OrderingPolicy` (`PerKeyHeadOfLine` default, `PerSourceStream`, `StopTheLine`, `BestEffort`), `OutboxPublishOptions` (`batchSize` 32, `maxAttempts` 10, `backoff`, `orderingPolicy`, `publishingTimeout` 300 s, `tracer`), `PublishOutcome` (`PublishSucceeded | PublishFailed Text`) — note `PublishOutcome` is currently *exported from* `Keiro.Outbox`, not Types — `OutboxPublishSummary`, `nextDelay`.
- `keiro/src/Keiro/Telemetry.hs` — `recordOutboxBacklog` (gauge), `recordOutboxPublished`/`Retried`/`Deadlettered`/`Reclaimed` (counters), `withProducerSpan`.
- `keiro/test/Main.hs` — hspec suite (`cabal test keiro-test`); `describe "Keiro.Outbox"` starts near line 2502 and exercises claim/publish/requeue against a real Postgres via the `withMigratedSuite`/`withFreshStore` fixtures from `keiro-test-support` (a template-database-per-suite fixture; each example gets a fresh database cloned from a migrated template).
- `keiro-migrations/sql-migrations/` — forward-only codd SQL migrations, lexicographic timestamp-prefixed file names (existing outbox files: `2026-05-17-01-00-00-keiro-outbox.sql`, `2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql`). `keiro-migrations/expected-schema/` holds codd's on-disk schema snapshot, regenerated by `cabal run keiro-write-expected-schema` and checked by `cabal test keiro-migrations-test`.

The `keiro_outbox` table (created in `2026-05-17-01-00-00-keiro-outbox.sql`): one row per integration event with envelope columns, `payload_bytes BYTEA`, and worker state — `status TEXT` (`pending`/`publishing`/`sent`/`failed`/`dead`), `attempt_count`, `next_attempt_at`, `created_at`, `updated_at`. Existing indexes: `keiro_outbox_pending_idx (status, next_attempt_at, created_at)`; partial `keiro_outbox_head_of_line_idx (source, message_key, created_at) WHERE status NOT IN ('sent','dead') AND message_key IS NOT NULL`; partial `keiro_outbox_source_order_idx (source, created_at, outbox_id) WHERE status NOT IN ('sent','dead')`; partial `keiro_outbox_sent_gc_idx (published_at) WHERE status = 'sent'`.

The current claim statement, in full (predicate shown for `PerKeyHeadOfLine`):

```sql
WITH ready AS (
  SELECT r.outbox_id, r.created_at AS claim_created_at
  FROM keiro_outbox r
  WHERE r.status IN ('pending', 'failed')
    AND r.next_attempt_at <= $2
    AND ( r.message_key IS NULL OR NOT EXISTS (
          SELECT 1 FROM keiro_outbox earlier
          WHERE earlier.source = r.source
            AND earlier.message_key = r.message_key
            AND (earlier.created_at, earlier.outbox_id) < (r.created_at, r.outbox_id)
            AND earlier.status NOT IN ('sent', 'dead') ) )
  ORDER BY r.created_at, r.outbox_id
  LIMIT $1
  FOR UPDATE SKIP LOCKED
),
updated AS (
  UPDATE keiro_outbox kt
  SET status = 'publishing', attempt_count = kt.attempt_count + 1, updated_at = $2
  FROM ready
  WHERE kt.outbox_id = ready.outbox_id
  RETURNING ready.claim_created_at, kt.*  -- (in reality an explicit 29-column list)
)
SELECT ... FROM updated ORDER BY claim_created_at, outbox_id
```

The defect: for two pending rows of key `k` created at `t1 < t2`, the `t2` row's `NOT EXISTS` finds the `t1` row (status `pending` — not in `('sent','dead')`) and excludes it. Only each key's head row is ever claimable, no matter the batch size. Under `PerSourceStream` (predicate ignores the key), only the single earliest non-terminal row *per source* is claimable. `FOR UPDATE SKIP LOCKED` means concurrent workers skip rather than block on rows another worker holds locked — that is what makes multiple workers safe today, and the rewrite must preserve it.

A *run* in this plan means a maximal contiguous prefix of a key's queue: rows `r1 < r2 < … < rn` of the same `(source, message_key)` ordered by `(created_at, outbox_id)`, all ready to publish, with no earlier non-terminal same-key row outside the set.


## Plan of Work


### Milestone 0 — benchmark harness and baseline capture

Scope: measured (not modeled) before/after evidence, plus a standing regression guard for the future. This milestone is implemented, run, and committed **before any behavior change**, so the same benchmark code (modulo the M3 signature adaptation described below) measures both sides.

Add a `benchmark` stanza to `keiro/keiro.cabal` named `keiro-bench` (`type: exitcode-stdio-1.0`, `hs-source-dirs: bench`, `main-is: Main.hs`), mirroring the test-suite stanza's `default-language` and ghc-options. Dependencies: `keiro`, `keiro-core`, `keiro-test-support`, `kiroku`, `hasql-transaction`, `effectful`, `text`, `bytestring`, `time`, and **`tasty-bench`** — the one new package. tasty-bench is a minimal-overhead benchmarking framework (tasty-compatible) chosen deliberately for its built-in recording and regression tooling: `--csv FILE` writes measurements, `--baseline FILE` compares a run against a recorded CSV, and `--fail-if-slower N` makes the run exit non-zero when a benchmark regresses by more than N percent. If the nix build cannot resolve `tasty-bench`, add it to the flake's Haskell package overrides the same way existing extra deps are handled in `nix/`.

`keiro/bench/Main.hs` uses `Test.Tasty.Bench.defaultMain` with self-contained IO actions. Provision one migrated scratch database for the whole run using the same `keiro-test-support` fixture machinery the test suite uses (`Keiro.Test.Postgres`; see `keiro/test/Main.hs`'s `withMigratedSuite` for the pattern), acquire a store handle once, and pass it to the benches. Because tasty-bench runs each action many times, every action must start from a clean slate: begin with `TRUNCATE keiro_outbox`, then seed, then drain. Seeding and truncation are identical before and after the change, so they dilute the measured ratio slightly but never bias its direction — state this next to the recorded numbers.

Outbox scenarios (fixed constants at the top of `bench/Main.hs`; tasty-bench owns the CLI, so select benches with `-p` patterns rather than custom flags):

- `outbox.hot-key` — seed 2,000 `pending` rows for **one** message key (1 KiB payloads, distinct `messageId`/`outboxId`, batched seed transactions of 500), then loop `publishClaimedOutbox` with `defaultPublishOptions` until `countOutboxBacklog` returns 0 (safety cap: at most 2,000 passes). The simulated publisher charges `threadDelay 1000` (1 ms) per publish **invocation** plus 10 µs per record, always succeeding — the per-invocation charge models the broker round trip a real producer awaits, which is exactly what batching amortizes.
- `outbox.hot-key-nolatency` — same with a 0 µs broker, isolating the Postgres round-trip and claim-query costs from the transport model.
- `outbox.multi-key` — 2,000 rows round-robined across 200 keys, 1 ms broker.

Metrics are `Nothing` throughout, which *understates* the "before" cost (the old code's per-pass backlog `COUNT(*)` only runs with metrics on) — the comparison is conservative in the new code's disfavor, which is the right direction for evidence.

When Milestone 3 changes the publish argument to `[OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]`, adapt the simulated publisher **in the same commit**, keeping the identical cost model: one 1 ms charge per invocation, 10 µs per row. The scenario semantics never change; only the number of invocations the new worker makes does.

Baseline protocol: on an idle machine, run

```bash
cabal bench keiro-bench --benchmark-options="-p outbox --time-mode wall --csv bench-before-outbox.csv"
```

and paste the rendered table (mean time per drain, ±stdev) into Outcomes & Retrospective under a "Baseline (before)" heading, with a one-line machine note (CPU, storage type — fsync latency dominates; and whether Postgres runs on a local socket). The `bench-before-outbox.csv` file is working scratch for the final comparison — keep it out of git.

Final comparison (after Milestone 4): re-run the identical command, record the "After" table and per-scenario ratios in Outcomes & Retrospective, then write the finished code's measurements to `keiro/bench/baseline-outbox.csv`, **commit that CSV**, and add a Justfile target so the improvement is guarded going forward:

```text
[group('haskell')]
bench-regression:
cabal bench keiro-bench --benchmark-options="-p outbox --time-mode wall --baseline keiro/bench/baseline-outbox.csv --fail-if-slower 25"
```

The committed baseline is machine-specific by nature; document (in a comment above the target) that it reflects the primary dev machine and that `bench-regression` is a local/manual guard, deliberately not wired into `just verify` or CI where shared-runner noise would make a 25 % gate flaky. The inbox plan (`docs/plans/82-...md`) extends this same component with `inbox.*` benches and its own `baseline-inbox.csv`; whichever plan is implemented first creates the component and the Justfile target (the other appends its pattern line) — this is a registered integration point in the MasterPlan.

Acceptance for M0: `cabal bench keiro-bench` runs all three scenarios to completion against unchanged code and the baseline table is recorded in this plan.


### Milestone 1 — contiguous run claiming

Scope: rewrite the claim SQL so a single pass claims whole per-key runs (per-source runs under `PerSourceStream`), preserving both the ordering invariant and concurrent-worker safety, without changing any Haskell signatures. At the end, `claimOutboxBatch PerKeyHeadOfLine 10` over ten same-key pending rows returns all ten in order.

**The new claim query.** In `keiro/src/Keiro/Outbox/Schema.hs`, replace `claimSql` and `policyPredicate` with a three-CTE statement. For `PerKeyHeadOfLine` (and `StopTheLine`, which shares its claim shape):

```sql
WITH candidate AS (
  SELECT r.outbox_id, r.source, r.message_key, r.created_at
  FROM keiro_outbox r
  WHERE r.status IN ('pending', 'failed')
    AND r.next_attempt_at <= $2
    AND ( r.message_key IS NULL OR NOT EXISTS (
          SELECT 1 FROM keiro_outbox earlier
          WHERE earlier.source = r.source
            AND earlier.message_key = r.message_key
            AND (earlier.created_at, earlier.outbox_id) < (r.created_at, r.outbox_id)
            AND earlier.status NOT IN ('sent', 'dead')
            AND NOT (earlier.status IN ('pending', 'failed') AND earlier.next_attempt_at <= $2) ) )
  ORDER BY r.created_at, r.outbox_id
  LIMIT $1
  FOR UPDATE SKIP LOCKED
),
ready AS (
  SELECT c.outbox_id, c.created_at AS claim_created_at
  FROM candidate c
  WHERE c.message_key IS NULL OR NOT EXISTS (
        SELECT 1 FROM keiro_outbox earlier
        WHERE earlier.source = c.source
          AND earlier.message_key = c.message_key
          AND (earlier.created_at, earlier.outbox_id) < (c.created_at, c.outbox_id)
          AND earlier.status NOT IN ('sent', 'dead')
          AND NOT EXISTS (SELECT 1 FROM candidate c2 WHERE c2.outbox_id = earlier.outbox_id) )
),
updated AS (
  UPDATE keiro_outbox kt
  SET status = 'publishing', attempt_count = kt.attempt_count + 1, updated_at = $2
  FROM ready
  WHERE kt.outbox_id = ready.outbox_id
  RETURNING ready.claim_created_at, <the existing 29-column rowColumns list>
)
SELECT <unqualifiedRowColumns> FROM updated ORDER BY claim_created_at, outbox_id
```

Why two filters. The `candidate` pre-filter relaxes the old predicate: an earlier same-key row blocks only if it is non-terminal **and not itself ready** (i.e. `publishing`, or `failed` waiting out its backoff). Ready predecessors no longer block — they will be claimed alongside. This is what turns heads-only claiming into run claiming, and it also prevents a starvation regression: a key whose head is in backoff contributes *no* candidate rows (every row of that key is blocked by the non-ready head, transitively — the head blocks the whole tail directly since it is earlier than all of them), so it cannot fill the `LIMIT` window and starve other keys.

The pre-filter alone would be unsafe with concurrent workers: if worker A is mid-claim on key `k`'s head, the head is still `pending`+ready in worker B's snapshot (A has not committed), so B's pre-filter would admit rows 2..n of `k` — while `SKIP LOCKED` silently drops the locked head from B's candidate set. B would claim the tail while A publishes the head: cross-worker per-key reordering. The `ready` post-filter closes this: a candidate row is claimable only if every earlier same-key non-terminal row is **in the candidate set itself** — that is, locked by this very statement. A predecessor dropped by `SKIP LOCKED`, cut off by the `LIMIT`, or excluded by its own pre-filter is "outside the set" and blocks its successors for this pass. Transitivity holds without extra machinery: if candidate row X (same key, earlier than c) is itself blocked by out-of-set row B, then B is also earlier than c and same-key, so B blocks c directly.

Net invariant, which must be stated in the haddock of `claimOutboxBatch`: *a row is claimed only if every earlier same-key non-terminal row is claimed by the same statement, and the returned list preserves `(created_at, outbox_id)` order; therefore per-key subsequences of the batch are gapless, ordered runs.* One behavior change to document: the `LIMIT` now applies before the post-filter, so a pass may claim fewer than `batchSize` rows even when more are claimable (candidates spent on rows that the post-filter then rejects). Those rows are picked up next pass; this only occurs in the presence of concurrent claimers or limit-window truncation.

For `PerSourceStream`, both filters are the same with `earlier.message_key = r.message_key` dropped (any earlier same-source row blocks) and no `message_key IS NULL` bypass. For `BestEffort`, both filters are `TRUE` (candidate = the plain ready scan). Keep the existing `claimStmt :: OrderingPolicy -> Statement (Int64, UTCTime) [OutboxRow]` signature; build the SQL by splicing two policy-specific predicate fragments (pre and post) instead of today's one.

**Tests.** In `keiro/test/Main.hs` under `describe "Keiro.Outbox"`: the existing examples that encode heads-only behavior (e.g. the one near line 2584 asserting a claim returns `[_]` when two same-key rows are pending) must be updated to the new expectation — this flip is the proof the fix works. Add examples: (a) enqueue 5 rows for key `A` and 3 for key `B`, claim with limit 10 → all 8 returned, and the per-key subsequences are in enqueue order; (b) enqueue rows for key `A`, mark `A`'s head `failed` with `next_attempt_at` in the future (use `markOutboxFailedTx`), enqueue rows for key `B` created *after* `A`'s tail → claim returns only `B`'s rows (backoff head blocks its tail; `B` not starved); (c) `PerSourceStream`: 4 rows across 2 keys in one source → one claim returns all 4 in global order; (d) NULL-key rows still claim freely alongside; (e) two consecutive claims: the second returns nothing while the first batch is still `publishing` (the out-of-set `publishing` head blocks). Acceptance: `cabal test keiro-test` green.


### Milestone 2 — claim-order partial index

Scope: give the candidate scan an index that matches its access pattern — filter on claimable statuses, walk in `(created_at, outbox_id)` order, stop at the limit — so a deep backlog no longer costs a full gather-and-sort per pass. (`keiro_outbox_pending_idx (status, next_attempt_at, created_at)` orders by `next_attempt_at` within each status, so it cannot serve an ordered walk by `created_at`.)

Create `keiro-migrations/sql-migrations/<now>-keiro-outbox-claim-order-index.sql` (name it with the actual current timestamp in the established `YYYY-MM-DD-HH-MM-SS-` format; it must sort after `2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql`):

```sql
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database.
SET search_path TO kiroku, pg_catalog;

-- Serves the outbox claim query's candidate scan: ordered walk by
-- (created_at, outbox_id) over claimable rows, stopping at the batch limit.
-- next_attempt_at is a residual filter (almost always satisfied for pending rows).
CREATE INDEX IF NOT EXISTS keiro_outbox_claim_order_idx
  ON keiro_outbox (created_at, outbox_id)
  WHERE status IN ('pending', 'failed');
```

Then regenerate the expected schema and run the drift test (commands in Concrete Steps). Acceptance: `cabal test keiro-migrations-test` passes; `git diff keiro-migrations/expected-schema` shows the new index and nothing unexplained. Coordination note from the MasterPlan (`docs/masterplans/11-keiro-inbox-and-outbox-kafka-throughput-overhaul.md`): the inbox plan (`docs/plans/82-...md`) also adds a migration and regenerates this snapshot; whichever lands second regenerates on top of the other's committed state.


### Milestone 3 — batch-shaped publish contract

Scope: change `publishClaimedOutbox` so the transport sees the whole claimed batch, successful rows are marked in one statement, and per-key failure semantics are enforced by the worker. At the end, one pass over a 10-row run performs one publish call and two Postgres statements (claim, bulk mark) instead of ten publish calls and eleven transactions.

**New signature** in `keiro/src/Keiro/Outbox.hs`:

```haskell
publishClaimedOutbox ::
    forall es.
    (IOE :> es, Store :> es) =>
    ([OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]) ->
    OutboxPublishOptions ->
    Maybe KeiroMetrics ->
    Eff es OutboxPublishSummary
```

Document the publish contract in the haddock, verbatim requirements: rows arrive in claim order and per-key subsequences must be produced to the broker in that order; the result must contain exactly one outcome per input row (a missing outcome is treated as `PublishFailed "publisher returned no outcome"`); and if the transport reports a row failed, it must not have successfully delivered any *later* same-key row from the same call (a real Kafka adapter achieves this with an idempotent producer — `enable.idempotence`, bounded `max.in.flight` — or by chunking per key; the in-repo tests use in-memory publishers that satisfy it trivially). Exceptions from `publish` are caught with `trySync` and treated as every row failing with the exception text.

**Outcome processing** replaces `drainBatch`. Group the claimed rows by `(source, message key)` preserving order (`Nothing`-keyed rows are each their own group). Within each group walk in order: rows before the first failure with a `PublishSucceeded` outcome are *sent*; the first failed row is marked with `markOutboxFailedTx` exactly as today (attempt-count read, backoff `nextDelay`, `failed` or `dead`); every row after the first failure — regardless of its reported outcome — is *skipped*. Collect all sent ids across groups into one `markOutboxSentBatch` call; mark each skipped row with the new `markOutboxSkippedTx`. Run the failure/skip marks inside one `runTransaction` to bound round trips. Summary counters: `published` = sent rows, `retried`/`dead` from the failure pivots as today, and skipped rows count into `retried` (they will be retried; note this in the haddock of `OutboxPublishSummary`).

New statements in `keiro/src/Keiro/Outbox/Schema.hs`:

```haskell
-- | Mark many rows sent in one statement. Only rows still in 'publishing'
-- transition; returns how many did (callers treat a shortfall as benign —
-- a sweeper or operator moved the row mid-publish; delivery is at-least-once).
markOutboxSentBatch :: (Store :> es) => [OutboxId] -> UTCTime -> Eff es Int
```

backed by `UPDATE keiro_outbox SET status = 'sent', published_at = $2, last_error = NULL, updated_at = $2 WHERE outbox_id = ANY($1) AND status = 'publishing'` (encoder: `E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))` for the id list; decoder `D.rowsAffected`), and

```haskell
-- | Return a claimed row to 'failed' without consuming an attempt: used for
-- rows skipped because an earlier same-key row failed in the same batch.
markOutboxSkippedTx :: OutboxId -> Text -> UTCTime -> Tx.Transaction ()
```

backed by `UPDATE keiro_outbox SET status = 'failed', attempt_count = GREATEST(attempt_count - 1, 0), last_error = $2, next_attempt_at = $3, updated_at = $3 WHERE outbox_id = $1 AND status = 'publishing'` with error text `"skipped: earlier record for the same key failed"` and `next_attempt_at = now` (the head-of-line predicate keeps the run blocked behind its failed head anyway; the decrement compensates the claim-time `attempt_count + 1` so never-attempted rows cannot creep toward dead-letter).

**Policy split.** For `PerKeyHeadOfLine`, `PerSourceStream`, `BestEffort`: one `publish` call with the full batch. For `StopTheLine`: call `publish` with singleton lists row by row, stop at the first failure, set `haltedOn`, and mark all unattempted remaining rows skipped. (`PerSourceStream` outcome processing treats the entire batch as one group — a failure pivots the whole remainder to skipped.)

**Tracing.** Replace the per-row `withProducerSpan` with one producer-kind span per publish call: keep using `withProducerSpan` but give it batch attributes (destination of the first row, batch size as an attribute) — or, if its signature fights the batch shape, add a small `withPublishBatchSpan` beside it in `keiro/src/Keiro/Telemetry.hs` (span name `keiro.outbox publish`, attributes for row count and distinct destinations, `error.type`/`Error` status when any outcome failed). Per-record spans are now the adapter's job; say so in the module haddock of `Keiro.Outbox.Kafka`.

**Call sites.** Repo-wide, only `keiro/test/Main.hs` calls `publishClaimedOutbox` (the keiro-dsl conformance fixtures import only config types). Update every test publisher from `OutboxRow -> Eff es PublishOutcome` to the batch shape — a helper `perRow :: (OutboxRow -> Eff es PublishOutcome) -> [OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]` in the test file keeps the diffs small. Add new examples: (a) 10-row single-key run, publisher records invocation count → one invocation, all rows `sent`, summary `published = 10`; (b) mid-run failure: rows 1–2 succeed, row 3 fails, rows 4–5 reported succeeded by a misbehaving publisher → rows 1–2 `sent`, row 3 `failed` with backoff and `attempt_count = 1`, rows 4–5 `failed` with `attempt_count = 0` and the skip error text; (c) `StopTheLine`: publisher fails row 2 of 4 → `haltedOn` is row 2's id, rows 3–4 skipped, publisher saw exactly 2 invocations; (d) missing outcome for a row → that row `failed` with the "no outcome" error. Acceptance: `cabal test keiro-test` green.


### Milestone 4 — maintenance off the hot path

Scope: stop paying the stuck-row sweep and the backlog `COUNT(*)` on every publish pass. At the end, `publishClaimedOutbox` performs exactly: claim → publish → mark; a new `outboxMaintenancePass` owns reclamation and gauging and is scheduled independently (the keiro pattern for workers is "the application schedules passes", see the existing haddock note "once per process-compose tick" — maintenance is simply a second, slower tick, and `Keiro.Wake` does not apply since maintenance is time-based, not append-driven).

In `keiro/src/Keiro/Outbox.hs` add:

```haskell
data OutboxMaintenanceOptions = OutboxMaintenanceOptions
    { maxAttempts :: !Int              -- same meaning as OutboxPublishOptions.maxAttempts
    , publishingTimeout :: !NominalDiffTime
    }

data OutboxMaintenanceSummary = OutboxMaintenanceSummary
    { requeued :: !Int, deadLettered :: !Int, backlog :: !Int }

-- | Reclaim rows stranded in 'publishing' and record the backlog gauge.
-- Schedule this on its own interval (seconds, not per publish pass).
outboxMaintenancePass ::
    (IOE :> es, Store :> es) =>
    OutboxMaintenanceOptions -> Maybe KeiroMetrics -> Eff es OutboxMaintenanceSummary

-- | Count the publishable backlog and record the gauge. No-op count avoidance:
-- does nothing when metrics are Nothing.
sampleOutboxBacklog :: (Store :> es) => Maybe KeiroMetrics -> Eff es ()
```

`outboxMaintenancePass` = `requeueStuckOutbox` + `recordOutboxReclaimed`/`recordOutboxDeadlettered` + `sampleOutboxBacklog` (which is `for_ mMetrics $ \m -> countOutboxBacklog >>= recordOutboxBacklog (Just m) . fromIntegral`). Delete the corresponding lines from `publishClaimedOutbox` (currently `Outbox.hs:287-300`). Types live in `Keiro.Outbox.Types` if that matches the module's convention (config types live there today); re-export from `Keiro.Outbox`. The `sampleOutboxBacklog` name and shape are an integration point with the inbox plan, which mirrors it as `sampleInboxBacklog` — keep the naming symmetric.

Tests: the existing requeue/reclaim examples in `keiro/test/Main.hs` (which today go through `publishClaimedOutbox`) switch to `outboxMaintenancePass`; add an assertion that a publish pass over a store containing a stuck `publishing` row does *not* reclaim it (proving the sweep left the hot path), and that `outboxMaintenancePass` does. Keep `defaultPublishOptions`'s `maxAttempts`/`publishingTimeout` fields — they still parameterize dead-lettering (`markOutboxFailedTx`) and are the natural source for `OutboxMaintenanceOptions`; add a `defaultMaintenanceOptions` mirroring them. Also grep `docs/` for prose describing the old single-pass behavior (the outbox user guide) and update the worker-scheduling description.


## Concrete Steps

All commands run from the repo root. The test suites need the local Postgres fixture:

```bash
just postgres-start   # idempotent; initializes db/db on first run
```

Per milestone:

```bash
cabal build keiro                      # compile the library changes
cabal test keiro-test                  # full keiro suite (hspec; Postgres-backed)
```

Milestone 0 (before any behavior change) and again after Milestone 4:

```bash
cabal bench keiro-bench --benchmark-options="-p outbox --time-mode wall --csv bench-before-outbox.csv"   # M0 baseline
cabal bench keiro-bench --benchmark-options="-p outbox --time-mode wall --csv keiro/bench/baseline-outbox.csv"  # after M4; commit this CSV
just bench-regression                  # standing guard: --baseline + --fail-if-slower 25
```

Milestone 2 additionally:

```bash
cabal run keiro-write-expected-schema  # regenerates keiro-migrations/expected-schema from an ephemeral DB
git diff -- keiro-migrations/sql-migrations keiro-migrations/expected-schema
cabal test keiro-migrations-test
```

Expected: the diff shows exactly one new index object under `keiro-migrations/expected-schema/*/schemas/kiroku/tables/keiro_outbox/indexes/keiro_outbox_claim_order_idx` (plus any version-directory rename the tool performs), and both test commands end with `All N examples passed` / test suite `PASS`.

Before finishing, run the repo's aggregate check:

```bash
just haskell-build && cabal test keiro-test && cabal test keiro-migrations-test
```

Commit after each milestone with a conventional-commit message and both trailers, e.g.:

```text
feat(keiro): claim contiguous per-key runs in the outbox publisher

MasterPlan: docs/masterplans/11-keiro-inbox-and-outbox-kafka-throughput-overhaul.md
ExecPlan: docs/plans/81-outbox-publisher-throughput-run-claiming-batch-publish-off-hot-path-maintenance.md
```


## Validation and Acceptance

Behavioral acceptance, all demonstrated by `cabal test keiro-test` examples that fail before and pass after:

1. Run claiming: 10 pending rows for one key, `claimOutboxBatch PerKeyHeadOfLine 32` returns all 10 in enqueue order (before: returns 1).
2. One-pass drain: the same 10 rows are all `sent` after a single `publishClaimedOutbox` pass whose publisher was invoked exactly once with 10 rows (before: 10 passes, 10 invocations).
3. Ordering preserved: with key `A`'s head `failed` and in backoff, a claim returns only other keys' rows; after the backoff elapses, `A`'s full run is claimed in order.
4. Failure isolation: a mid-run failure marks the prefix `sent`, the pivot `failed` (attempt consumed, backoff applied), and the suffix `failed` with `attempt_count` unchanged net of the claim (0 after decrement) — verified by reading rows back with `lookupOutbox`.
5. Maintenance split: a stuck `publishing` row older than `publishingTimeout` is untouched by a publish pass and reclaimed by `outboxMaintenancePass`, whose summary reports it; when metrics are enabled, the backlog gauge is recorded by the maintenance pass and not by the publish pass (assert via the metrics test harness already used in `describe "Keiro.Telemetry metrics"`).
6. Schema: `cabal test keiro-migrations-test` passes with the new index in the expected schema.

7. Measured throughput: the M0 tasty-bench scenarios re-run on the finished code show, on the same machine as the baseline, at least **5×** improvement on `outbox.hot-key` (expected: far more — the modeled estimate is two orders of magnitude; 5× is the conservative gate accounting for seed/truncate dilution in the measured action), at least **3×** on `outbox.multi-key`, and at least **1.5×** on `outbox.hot-key-nolatency`. These ratios are advisory acceptance recorded in Outcomes & Retrospective, not CI gates — wall-clock database benchmarks are machine-dependent. Falling short of a ratio is a stop-and-investigate signal, not an automatic failure.
8. Regression guard in place: `keiro/bench/baseline-outbox.csv` is committed from the finished code and `just bench-regression` exits zero against it (and would exit non-zero if a future change slowed a scenario by more than 25 %).

The benchmark measures keiro's orchestration cost against a simulated broker (fixed per-invocation plus per-record latency), not a real Kafka cluster; end-to-end numbers with librdkafka belong to the transport-adapter repository. If additional manual evidence is wanted, the jitsurei example app (`just jitsurei` targets) can be pointed at a seeded outbox before/after, but this is optional and must not gate the plan.


## Idempotence and Recovery

All library edits are ordinary code changes; re-running builds and tests is safe. The migration uses `CREATE INDEX IF NOT EXISTS`, so re-applying is safe; codd is forward-only, so if the migration file needs correction *after* it has been applied to any shared database, add a new forward migration rather than editing the file (per `keiro-migrations/README.md`). `cabal run keiro-write-expected-schema` is deterministic from the migration set and can be re-run at any time; if it produces unexpected diffs, check for an unmerged migration from `docs/plans/82-...` (the inbox plan) and regenerate after rebasing. If Milestone 3's contract change breaks an out-of-repo consumer (none are known; the transport adapters live in other repositories and do not import `publishClaimedOutbox`), the old behavior is recoverable per row via the `perRow` adapter shape shown in Milestone 3.


## Interfaces and Dependencies

The library changes stay within existing dependencies: `hasql`/`hasql-transaction` (statements), `effectful` (`Eff`, `IOE`, `trySync`), `kiroku` (`Store`, `runTransaction`), `hs-opentelemetry` (spans). The one new package is `tasty-bench`, confined to the new `keiro-bench` benchmark stanza in `keiro/keiro.cabal` (sources under `keiro/bench/`); it never enters the library dependency graph.

End-state surface of `keiro/src/Keiro/Outbox.hs` (module `Keiro.Outbox`), in addition to today's exports minus nothing:

```haskell
publishClaimedOutbox ::
    (IOE :> es, Store :> es) =>
    ([OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]) ->
    OutboxPublishOptions -> Maybe KeiroMetrics -> Eff es OutboxPublishSummary

outboxMaintenancePass ::
    (IOE :> es, Store :> es) =>
    OutboxMaintenanceOptions -> Maybe KeiroMetrics -> Eff es OutboxMaintenanceSummary

sampleOutboxBacklog :: (Store :> es) => Maybe KeiroMetrics -> Eff es ()

defaultMaintenanceOptions :: OutboxMaintenanceOptions
```

`Keiro.Outbox.Schema` additionally exports `markOutboxSentBatch` and `markOutboxSkippedTx`. `Keiro.Outbox.Types` gains `OutboxMaintenanceOptions` and `OutboxMaintenanceSummary` (both `Generic`, `Eq`, `Show` where fields allow). `OrderingPolicy`, `OutboxPublishOptions`, `OutboxPublishSummary`, `PublishOutcome`, and all enqueue-side APIs are unchanged in shape, which is what keeps `keiro-dsl` scaffolding (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` imports only `BackoffSchedule`/`OrderingPolicy`) and the conformance fixtures compiling untouched except for their config re-exports.


---

Revision note (2026-07-01): Added a Decision Log entry recording the two residual risks surfaced during pre-implementation review — the transport-side prefix-failure contract and the mandatory scheduling of `outboxMaintenancePass` — so implementers treat them as accepted trade-offs with named mitigations rather than rediscovering them. No milestone content changed.

Revision note (2026-07-01, later): Added Milestone 0 — a tasty-bench `keiro-bench` component with three outbox scenarios, run against unchanged code to capture a recorded "Before" baseline, re-run after Milestone 4 for a recorded before/after comparison, with `keiro/bench/baseline-outbox.csv` committed and a `just bench-regression` target (`--baseline`, `--fail-if-slower 25`) as a standing regression guard. Progress, Concrete Steps, Validation and Acceptance (advisory ratio gates 5×/3×/1.5×), Interfaces (tasty-bench dependency, bench-only), and the Decision Log were updated accordingly. Requested by the user to replace modeled throughput claims with measurements and to protect the improvement going forward.

Revision note (2026-07-02): Implemented Milestone 0 against unchanged runtime code by adding the `keiro-bench` benchmark component and outbox scenarios, running the baseline with `--time-mode wall`, recording the before table and CSV evidence in Outcomes & Retrospective, and marking the M0 progress items complete. The benchmark commands were revised to include `--time-mode wall` because the simulated broker latency is represented with `threadDelay`, which CPU-time measurement would undercount.
