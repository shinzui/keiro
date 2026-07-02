---
id: 11
slug: keiro-inbox-and-outbox-kafka-throughput-overhaul
title: "Keiro inbox and outbox Kafka throughput overhaul"
kind: master-plan
created_at: 2026-07-01T23:29:41Z
intention: intention_01kwg1jq4de7ya9gmrfeezb949
---

# Keiro inbox and outbox Kafka throughput overhaul

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

keiro's integration-event outbox (`keiro/src/Keiro/Outbox.hs` and friends, table `keiro_outbox`) and idempotent inbox (`keiro/src/Keiro/Inbox.hs` and friends, table `keiro_inbox`) are correct but throttle Kafka far below what the broker can absorb. A 2026-07-01 performance review found five outbox problems and five inbox problems. The two most severe: the outbox claim query's head-of-line predicate admits at most **one row per message key per pass** (one row per *source* under `PerSourceStream`), so a burst on a single aggregate degrades to one publish per full worker cycle; and the publish loop is strictly sequential and synchronous per record, defeating librdkafka's batching entirely. On the inbox side, every consumed message pays a synchronous Postgres commit plus — when metrics are on — a second whole transaction just to record a backlog gauge, and every happy-path message writes the row twice (insert `processing`, update `completed`) even though the intermediate state is unobservable.

After this initiative, the outbox publisher claims *contiguous per-key runs* (restoring real batch sizes without weakening ordering), hands the whole claimed batch to a batch-shaped publish contract (letting the Kafka producer pipeline and batch), marks successful rows sent in one bulk `UPDATE`, and does stuck-row sweeping and backlog gauging in a separate maintenance pass instead of on every hot-path invocation. The inbox records its backlog gauge from a sampler instead of per message, inserts completed rows exactly once, offers a batched intake variant that amortizes one commit across N messages with per-message fallback for poison isolation, and can be configured to skip persisting payload bytes on the success path. Two supporting migrations adjust indexes (a claim-order partial index on `keiro_outbox`; dropping the write-only `keiro_inbox_received_idx`).

In scope: the `keiro` library package (Outbox, Inbox, Telemetry surface), `keiro-migrations` (two new forward SQL migrations plus regenerated expected schema), and `keiro/test/Main.hs` coverage for all new behavior. Out of scope: the transport adapters (`shibuya-kafka-adapter`, kafka-effectful) — the batch publish contract is defined here and documented, but wiring a real librdkafka batch producer to it is a separate initiative; also out of scope are outbox delete-on-sent/partitioning strategies and any changes to `keiro-dsl` scaffolding (the generated code only exports configuration values from `Keiro.Outbox.Types` / `Keiro.Inbox.Types`, which do not change shape).


## Decomposition Strategy

The initiative splits along the two independent data flows: the **outbox** (service → Postgres → Kafka producer) and the **inbox** (Kafka consumer → Postgres → handler). The two flows share no code paths — different modules, different tables, different workers — and each produces an independently verifiable behavior (outbox: a burst of same-key rows drains in one pass; inbox: N messages commit in one transaction and no per-message gauge query appears). That gives two child plans, matching the review's two finding groups and the user's explicit request for one plan per side.

Alternatives considered: a third plan isolating the migrations was rejected because each migration is meaningless without the code that exploits it (the claim-order index serves the rewritten claim query; the dropped inbox index is only safe once nothing depends on it), and codd migrations are forward-only single files that are cheap to carry inside each plan. Splitting the outbox plan into "claim semantics" and "publish contract" was rejected because both rewrite `publishClaimedOutbox` and its tests — two plans forced to modify the same function in the same release are one plan.

Both plans touch `keiro-migrations/expected-schema` and `keiro/test/Main.hs`, which is managed as an integration point (serialize the expected-schema regeneration) rather than a dependency.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Outbox publisher throughput: run claiming, batch publish, off-hot-path maintenance | docs/plans/81-outbox-publisher-throughput-run-claiming-batch-publish-off-hot-path-maintenance.md | None | None | Complete |
| 2 | Inbox consume throughput: single-insert completion, off-hot-path gauge, batched intake, slim persistence | docs/plans/82-inbox-consume-throughput-single-insert-completion-off-hot-path-gauge-batched-intake-slim-persistence.md | None | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are no hard dependencies: neither plan needs the other's artifacts to compile or make sense, and they can be implemented in either order or in parallel *sessions* (not parallel worktrees — see the expected-schema integration point). EP-1 and EP-2 each add one forward SQL migration to `keiro-migrations/sql-migrations/` and regenerate `keiro-migrations/expected-schema/` with `cabal run keiro-write-expected-schema`; codd migration files sort lexicographically by timestamp prefix and the expected-schema representation is a single on-disk snapshot, so whichever plan lands second must regenerate the expected schema on top of the first plan's committed state. If implemented concurrently in separate branches, the second to merge must re-run the regeneration and re-commit; implementing them sequentially in one branch avoids the conflict entirely and is the recommended order (EP-1 first, since the outbox findings dominate the throughput gap).


## Integration Points

**`keiro-migrations/expected-schema/` snapshot (EP-1, EP-2).** codd's drift check compares the live schema against a single on-disk representation regenerated by `cabal run keiro-write-expected-schema`. Both plans add a migration and regenerate. The plan that lands second regenerates over the first's result. Each plan's validation includes `cabal test keiro-migrations-test`, which fails loudly on drift, so a stale regeneration cannot land silently.

**Backlog-gauge sampling pattern in `keiro/src/Keiro/Telemetry.hs` (EP-1 defines, EP-2 follows).** Both plans remove inline backlog gauging (`recordOutboxBacklog` / `recordInboxBacklog` calls) from hot paths and move it behind explicit sampling functions the application schedules on a timer. EP-1 introduces the convention — a `sampleOutboxBacklog :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> Eff es ()` helper in `Keiro.Outbox` that composes the existing `countOutboxBacklog` count with the existing `recordOutboxBacklog` gauge write. EP-2 mirrors it as `sampleInboxBacklog` in `Keiro.Inbox` with the same shape and naming. The telemetry metric names and instruments themselves do not change; only the call sites move.

**`keiro/test/Main.hs` (EP-1, EP-2).** Both plans extend the same hspec file (currently ~8100 lines; `describe "Keiro.Outbox"` around line 2502, inbox specs elsewhere in the same file). The blocks are disjoint `describe` groups, so textual conflicts are unlikely; each plan runs the full `cabal test keiro-test` before completion.

**`keiro-bench` benchmark component and `bench-regression` Justfile target (EP-1, EP-2).** Both plans add tasty-bench scenarios to one shared `benchmark keiro-bench` stanza in `keiro/keiro.cabal` (sources in `keiro/bench/Main.hs`). Whichever plan is implemented first creates the component (and the `tasty-bench` dependency, plus any nix override) and the `bench-regression` Justfile target; the second plan appends its benches and its target line. Namespaces are disjoint — EP-1 owns `outbox.*` benches and `keiro/bench/baseline-outbox.csv`, EP-2 owns `inbox.*` and `keiro/bench/baseline-inbox.csv` — and the per-area baseline CSVs exist specifically so the two plans' final-milestone commits never conflict on one file. Each plan's M0 runs against unchanged code to record its "Before" baseline in its own Outcomes & Retrospective section; each plan's final milestone records the "After" comparison and commits its baseline CSV as the standing regression guard (`--baseline`, `--fail-if-slower 25`; manual/local by design, not part of `just verify` or CI).

**`Maybe KeiroMetrics` parameters stay in place (EP-1, EP-2).** Removing inline gauge recording must not change the *signatures* of `publishClaimedOutbox`, `runInboxTransaction`, or `runInboxTransactionWithRetries` beyond what each plan explicitly specifies — counters (published/retried/dead, processed/duplicates/failed/poisoned) still record through the passed `Maybe KeiroMetrics`. Only the backlog gauge calls move out.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 M0: tasty-bench `keiro-bench` outbox scenarios + recorded "Before" baseline on unchanged code (completed 2026-07-02T00:02:14Z)
- [x] EP-1 M1: Contiguous per-key/per-source run claiming in `claimOutboxBatch` with regression tests (completed 2026-07-02T00:11:43Z)
- [x] EP-1 M2: Claim-order partial index migration and regenerated expected schema (completed 2026-07-02T00:15:12Z)
- [x] EP-1 M3: Batch-shaped publish contract in `publishClaimedOutbox` with bulk sent-marking (completed 2026-07-02T00:25:25Z)
- [x] EP-1 M4: Maintenance extracted to `outboxMaintenancePass`; gauges/sweep off the hot path (completed 2026-07-02T00:37:38Z)
- [x] EP-1 Final: "After" benchmark run recorded with before/after ratios; `baseline-outbox.csv` committed; `bench-regression` guard in place (completed 2026-07-02T00:40:12Z)
- [x] EP-2 M0: tasty-bench inbox scenarios + recorded "Before" baseline on unchanged code (completed 2026-07-02T00:43:56Z)
- [x] EP-2 M1: Backlog gauge removed from per-message inbox path; `sampleInboxBacklog` added (completed 2026-07-02T00:48:52Z)
- [x] EP-2 M2: Single-insert completed rows (drop the unobservable `processing` intermediate write) (completed 2026-07-02T00:54:45Z)
- [x] EP-2 M3: Inbox migration (drop `keiro_inbox_received_idx`) and regenerated expected schema (completed 2026-07-02T00:57:48Z)
- [x] EP-2 M4: Batched intake variant `runInboxTransactionBatch` with per-message poison fallback (completed 2026-07-02T01:06:53Z)
- [x] EP-2 M5: Slim payload persistence option (`InboxPersistence`) (completed 2026-07-02T01:13:12Z)
- [x] EP-2 Final: "After" benchmark run recorded with before/after ratios; `baseline-inbox.csv` committed; `bench-regression` extended (completed 2026-07-02T01:19:53Z)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery: The batch publish contract changes the worker span from per-row to per-publish-call; real per-record visibility now belongs in the Kafka adapter.
  Evidence: EP-1 M3 updated `Keiro.Outbox.Kafka` module documentation and the outbox span test to expect one producer span around the publish batch, with `error.type = publish_failed` when any row outcome fails.

- Discovery: The outbox backlog sampler mirrors the inbox plan's naming, but its keiro `Eff` signature needs `IOE` as well as `Store`.
  Evidence: `sampleOutboxBacklog` records OpenTelemetry metrics after counting rows; `recordOutboxBacklog` performs metric IO in this effect stack.

- Discovery: The outbox benchmark CSV path is package-relative when passed through Cabal benchmark options.
  Evidence: `--csv bench/baseline-outbox.csv` writes the committed repo file `keiro/bench/baseline-outbox.csv`; `--csv keiro/bench/baseline-outbox.csv` looks for a nested path from inside the package.

- Discovery: Inbox benchmarks use wall-clock timing for the same reason as outbox benchmarks.
  Evidence: EP-2 M0 runs with `--time-mode wall` because the workload is dominated by Postgres transaction latency and the metrics-on backlog-count transaction.

- Discovery: Both backlog samplers need `IOE` as well as `Store`.
  Evidence: `sampleOutboxBacklog` and `sampleInboxBacklog` each record OpenTelemetry metrics after a store count; metric recording performs IO in keiro's `Eff` stack.

- Discovery: EP-2 M2 removed an accidental overwrite of handler-set inbox failure marks.
  Evidence: With the fresh-path `markCompletedTx` gone, a handler that calls public `markFailedTx` and returns successfully leaves the row `failed` with its last error instead of being overwritten to `completed`.

- Discovery (post-implementation review, 2026-07-02): `runInboxTransactionBatch`'s poison fallback never fires on `Tx.condemn`, contradicting its haddock.
  Evidence: kiroku's `runTransaction` rolls back a condemned transaction but returns the body's value (`kiroku-store/src/Kiroku/Store/Transaction.hs:93-96`), so the `trySync` at `keiro/src/Keiro/Inbox.hs:290` yields `Right` and the batch reports `InboxProcessed` for every message while nothing committed — a handler that condemns (kiroku's documented idiom for `appendToStreamTx` conflicts) silently loses the whole batch once Kafka offsets commit. The single-message path has the same documented self-inflicted behavior, but the batch extends it to innocent batch-mates and its haddock (`Inbox.hs:270`) promises the opposite.

- Discovery (post-implementation review, 2026-07-02): under `PerSourceStream` the outbox outcome grouping collapses the whole claimed batch into one group, so a failure in one source's run skips and republishes already-delivered rows of unrelated sources.
  Evidence: `OutcomeGroupKey`'s `SourceGroup` carries no source (`keiro/src/Keiro/Outbox.hs:508-534`) while the PerSourceStream claim predicate admits runs from multiple sources into one batch; a batch [srcA-1, srcB-1, srcA-2 fails, srcB-2] marks the delivered srcB-2 `failed`/skipped and republishes it next pass. Safe under at-least-once, but a guaranteed duplicate with no ordering justification.

- Discovery (post-implementation review, 2026-07-02): the inbox batch benchmark shortfall (1.56x vs 3x target) is explained by the test harness, not the implementation.
  Evidence: the ephemeral-pg fixture runs with `fsync=off`, `synchronous_commit=off`, `wal_level=minimal` (`ephemeral-pg/src/EphemeralPg/Config.hs:174-183`), so the per-message commit-durability cost the batch amortizes is absent from the measurement; the remaining ~68µs/message floor is the per-message INSERT round trip inside the batch transaction (hasql does not pipeline; multi-row `unnest` was consciously rejected). On a production Postgres with durability on, the batch win should be substantially larger than measured.


## Decision Log

- Decision: Two child plans split by data flow (outbox vs inbox), no migrations plan.
  Rationale: The flows share no code; each is independently verifiable; migrations are meaningless without the code that uses them. Matches the review's structure and the user's request.
  Date: 2026-07-01

- Decision: No hard dependency between EP-1 and EP-2; recommend implementing EP-1 first, sequentially.
  Rationale: Outbox findings dominate the throughput gap (one-row-per-key claiming plus sync per-record publish). Sequential implementation sidesteps the expected-schema regeneration conflict.
  Date: 2026-07-01

- Decision: Transport adapter work (wiring shibuya-kafka-adapter / kafka-effectful to the new batch publish contract) is out of scope.
  Rationale: keiro deliberately does not depend on librdkafka (`Keiro.Outbox.Kafka` is transport-neutral by design). The batch contract is defined and tested against an in-memory publisher here; the adapter lives in a different repository (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`) with its own release cadence.
  Date: 2026-07-01

- Decision: Breaking API changes to `publishClaimedOutbox` (publish argument becomes batch-shaped) and behavioral changes to gauge recording are acceptable without deprecation shims.
  Rationale: keiro is a pre-1.0 framework in a private monorepo; a repo-wide grep shows the only callers are `keiro/test/Main.hs` and the keiro-dsl conformance fixtures, both updated in the same plans. `keiro-dsl` scaffolding only imports configuration types (`OrderingPolicy`, `BackoffSchedule`, `InboxDedupePolicy`, `InboxResult`), which keep their shapes.
  Date: 2026-07-01

- Decision: `StopTheLine` ordering policy keeps sequential per-record publishing inside the new batch worker.
  Rationale: The policy exists for operator-reviewed correctness ("any failure halts the worker"); publishing rows after the failure point in the same batch violates its intent. Throughput-sensitive services use the other policies.
  Date: 2026-07-01

- Decision: Both plans gain a Milestone 0 benchmark stage built on tasty-bench, sharing one `keiro-bench` component: baseline captured on unchanged code before any edit, identical scenarios re-run after the final milestone with the comparison recorded in each plan's Outcomes & Retrospective, and per-area baseline CSVs committed and guarded by a manual `just bench-regression` target (`--baseline`, `--fail-if-slower 25`).
  Rationale: User request (2026-07-01) — replace modeled throughput estimates with measurements and guard the wins against future regressions. tasty-bench chosen over a hand-rolled timer because recording (`--csv`) and regression gating (`--baseline`/`--fail-if-slower`) are built in; the guard stays out of CI because wall-clock database benchmarks on shared runners make percentage gates flaky. Advisory improvement ratios are deliberately conservative (seed/truncate work inside the measured actions dilutes ratios; outbox benches run metrics-off, understating the old code's cost).
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

### EP-1 M3 — Batch Publish Contract

`publishClaimedOutbox` now accepts `[OutboxRow] -> Eff es [(OutboxId, PublishOutcome)]`, marks successful rows with one bulk `UPDATE`, and enforces ordered group outcome processing in the worker: sent prefix, failed pivot, skipped suffix. `StopTheLine` keeps singleton publish calls and halts on the first failure, then skips the rest of the claimed batch without consuming attempts.

Validation:

```text
cabal build keiro:lib:keiro keiro:bench:keiro-bench keiro:test:keiro-test
cabal test keiro-test --test-options="--match Keiro.Outbox"  # 32 examples, 0 failures
cabal test keiro-test                                      # 265 examples, 0 failures
```

### EP-1 M4 — Outbox Maintenance Split

`publishClaimedOutbox` no longer runs the stuck-row sweeper or backlog `COUNT(*)`. Applications now schedule `outboxMaintenancePass defaultMaintenanceOptions metrics` separately to reclaim crashed publishers and sample backlog, or call `sampleOutboxBacklog` for gauge-only sampling.

Validation:

```text
cabal build keiro:lib:keiro keiro:test:keiro-test keiro:bench:keiro-bench
cabal test keiro-test --test-options="--match Keiro.Outbox"  # 32 examples, 0 failures
cabal test keiro-test                                      # 265 examples, 0 failures
just haskell-build                                        # passed
```

### EP-1 Final — Benchmark Guard

The finished outbox path exceeds every advisory benchmark gate on the same machine as the M0 baseline:

```text
All.outbox.hot-key           22.384 s -> 778 ms  (28.78x faster)
All.outbox.hot-key-nolatency 18.933 s -> 609 ms  (31.09x faster)
All.outbox.multi-key          4.838 s -> 454 ms  (10.66x faster)
```

Committed `keiro/bench/baseline-outbox.csv` and added `just bench-regression`, a manual/local target that compares future runs against that baseline with `--fail-if-slower 25`. Validation:

```text
cabal bench keiro-bench --benchmark-options="-p outbox --time-mode wall --csv bench/baseline-outbox.csv"
just bench-regression
```

### EP-2 M0 — Inbox Baseline

Added `inbox.single-full` and `inbox.single-nometrics` to the shared `keiro-bench` component and captured the before baseline against the current inbox implementation:

```text
All.inbox.single-full      436 ms +/- 31 ms
All.inbox.single-nometrics 313 ms +/- 18 ms
```

Command:

```text
cabal bench keiro-bench --benchmark-options="-p inbox --time-mode wall --csv bench-before-inbox.csv"
```

### EP-2 M1 — Inbox Gauge Sampler

`runInboxTransactionWithKey` and `runInboxTransactionWithRetriesKey` no longer run the backlog `COUNT(*)` on every message. They still record classification counters, and `sampleInboxBacklog` now owns the gauge query.

Validation:

```text
cabal build keiro:lib:keiro keiro:test:keiro-test keiro:bench:keiro-bench
cabal test keiro-test --test-options="--match Keiro.Inbox"  # 17 examples, 0 failures
cabal test keiro-test                                      # 265 examples, 0 failures
```

### EP-2 M2 — Single-Insert Completion

Fresh inbox processing now inserts rows directly as `completed`, with `completed_at` set in the insert. The legacy `processing` status remains decodable, and retrying a committed `failed` row still uses `markCompletedTx`.

Validation:

```text
cabal build keiro:lib:keiro keiro:test:keiro-test keiro:bench:keiro-bench
cabal test keiro-test --test-options="--match Keiro.Inbox"  # 18 examples, 0 failures
cabal test keiro-test                                      # 266 examples, 0 failures
```

### EP-2 M3 — Inbox Received Index Drop

Added migration `2026-07-02-00-55-00-keiro-inbox-drop-received-idx.sql` and regenerated expected schema so `keiro_inbox_received_idx` is no longer present. Validation:

```text
cabal run keiro-write-expected-schema
cabal test keiro-migrations-test  # 2 examples, 0 failures
```

### EP-2 M4 — Batched Inbox Intake

`runInboxTransactionBatch` now processes unique valid inbox deliveries under one transaction, returns input-order results, treats repeated in-batch dedupe keys as duplicates, and falls back to the existing retrying single-message path if the batch transaction fails. The batch and single retry paths share the same transactional classification helper, and result counter recording is factored through one helper.

Validation:

```text
cabal build keiro:lib:keiro keiro:test:keiro-test keiro:bench:keiro-bench
cabal test keiro-test --test-options="--match Keiro.Inbox"  # 22 examples, 0 failures
cabal test keiro-test                                      # 270 examples, 0 failures
```

### EP-2 M5 — Slim Inbox Persistence

Added `InboxPersistence`, with existing single-message APIs defaulting to `PersistFullEnvelope`, new `...With` variants exposing `PersistDedupeOnly`, and batch intake taking the persistence mode directly. Dedupe-only successful rows omit payload, attributes, schema, and trace columns while retaining dedupe/correlation metadata; failed rows always persist the full envelope.

Validation:

```text
cabal build keiro:lib:keiro keiro:test:keiro-test keiro:bench:keiro-bench
cabal test keiro-test --test-options="--match Keiro.Inbox"  # 24 examples, 0 failures
cabal test keiro-test                                      # 272 examples, 0 failures
```

### EP-2 Final — Inbox Benchmark Guard

Added `inbox.batch-100` and `inbox.single-slim` to `keiro-bench`, committed `keiro/bench/baseline-inbox.csv`, and extended `just bench-regression` with the inbox baseline line.

Finished-code comparison:

```text
All.inbox.single-full      435.873 ms -> 213.851 ms  (2.04x faster)
All.inbox.single-nometrics 313.328 ms -> 212.447 ms  (1.48x faster)
All.inbox.batch-100        213.851 ms -> 136.879 ms  (1.56x faster than finished single-full)
All.inbox.single-slim      212.447 ms -> 216.187 ms  (same as finished single-nometrics within noise)
```

The two single-message advisory gates passed. The batch after-only gate did not: `batch-100` measured 1.56x faster than finished `single-full`, below the planned 3x target. The implemented behavior remains correct and covered; the committed baseline records the actual local result and guards it against future regressions.

Validation:

```text
cabal bench keiro-bench --benchmark-options="-p inbox --time-mode wall --csv bench/baseline-inbox.csv"
just bench-regression
just haskell-build
cabal test keiro-test                                      # 272 examples, 0 failures
cabal test keiro-migrations-test                          # 2 examples, 0 failures
```

### Post-Implementation Review (2026-07-02)

An independent review of the full implementation (commits `3f0778a..76aa269`) confirmed both headline bottlenecks are genuinely fixed in code, with independent re-validation on a fresh checkout:

```text
cabal test keiro-test              # 272 examples, 0 failures
cabal test keiro-migrations-test   # 2 examples, 0 failures
just bench-regression              # all 7 scenarios within the 25% gate
```

Regression-guard reproduction: `outbox.hot-key` 839 ms (+7% vs baseline, i.e. still ~27x faster than the 22.4 s "Before"), `outbox.hot-key-nolatency` +10%, `outbox.multi-key` +11%, `inbox.single-full` +23% (noisy but under the gate), other inbox scenarios at baseline. The outbox claim query was additionally verified live: `EXPLAIN ANALYZE` over a 50k-row backlog uses `keiro_outbox_claim_order_idx` and stops at the LIMIT (~1 ms total); two-session tests confirmed contiguous same-key runs claim in one pass and the post-filter closes the SKIP LOCKED race (second worker claims zero rows while the head's claim is uncommitted). The inbox happy path runs exactly one transaction per message (or per batch), with no residual `COUNT(*)`.

Review verdict: bottleneck gone; ship-blocking defects none; follow-ups identified and resolved 2026-07-02 (commits `894e126..d000871`):

1. Major — `runInboxTransactionBatch` misreported condemned batches as processed (see Surprises & Discoveries). **Fixed** (`070590d`): after the batch transaction returns, the batch re-reads the first row classified `InboxProcessed`; if it is not `completed`, the transaction was condemned and the per-message fallback runs. Verified against hasql-transaction source: `condemn = put False` on the `StateT Bool Session` commit flag, and `commitOrAbort` rolls back while still returning the body's value.
2. Minor — PerSourceStream batch outcome grouping collapsed all sources into one group, causing cross-source collateral skip/republish. **Fixed** (`5395da0`): `SourceGroup` now carries the source text; `StopTheLine` keeps deliberate whole-batch grouping via a new `BatchGroup` key.
3. Minor — `markFailedStmt` lacked the `status = 'publishing'` guard that `markSentBatchStmt`/`markSkippedStmt` have. **Fixed** (`894e126`): late failure marks now no-op on rows that already reached `sent`/`dead` or were requeued. Residual accepted race: a row re-claimed into `publishing` by another worker can still receive a late mark; closing it needs claim epochs, out of scope under at-least-once semantics.
4. Minor — stale `OutboxPublishSummary` haddock (`published + retried + dead + halted = claimed`) **fixed** in `5395da0`. Still open, accepted as classification-only: in-batch duplicate of a dead-lettered key reports `InboxDuplicate` instead of `InboxPreviouslyFailed`; `PersistDedupeOnly` also nulls the event's own `schema_version` (decoder defaults it to 0).
5. Test gaps — **closed** (`d000871`, six new examples; suite now 278): legacy `processing` rows classify as `InboxInProgress` without running the handler; a two-connection uncommitted claim-hold race claims nothing; a two-worker same-dedupe-key race runs the handler once; condemn-in-batch falls back per message; plus regression tests for findings 2 and 3. Still open, accepted: nothing in code enforces that deployments schedule `outboxMaintenancePass` alongside `publishClaimedOutbox` (docs-only mitigation, per the Decision Log).

The batch-100 advisory shortfall recorded in EP-2 Final is attributed to the benchmark harness, not the code: ephemeral-pg disables commit durability, so the measurement excludes exactly the cost batching amortizes (see Surprises & Discoveries). The committed baseline remains valid as a regression guard for the measured regime.

---

Revision note (2026-07-01): Added the benchmarking stage across the initiative at the user's request: a shared tasty-bench `keiro-bench` component (new integration point, including the shared `bench-regression` Justfile target and per-area committed baseline CSVs), M0/final-comparison milestones in both child plans, corresponding Progress entries, and a Decision Log entry covering methodology and the regression guard. Child plans 81 and 82 were revised in the same pass; see their revision notes.

Revision note (2026-07-02): Marked EP-1 M3 complete after implementing the batch-shaped outbox publish contract, bulk sent marking, ordered suffix skipping, and updated benchmark/test call sites. Recorded focused and full `keiro-test` validation evidence.

Revision note (2026-07-02, M4): Marked EP-1 M4 complete after extracting outbox maintenance from the publish hot path, updating tests/docs for explicit maintenance scheduling, and recording passing focused/full tests plus `just haskell-build`.

Revision note (2026-07-02, EP-1 Final): Marked EP-1 complete after recording the after benchmark, committing `keiro/bench/baseline-outbox.csv`, adding the manual `bench-regression` target, validating it, and recording before/after ratios.

Revision note (2026-07-02, EP-2 M0): Marked EP-2 in progress after adding inbox benchmark scenarios to `keiro-bench` and recording the wall-clock before baseline for `inbox.single-full` and `inbox.single-nometrics`.

Revision note (2026-07-02, EP-2 M1): Marked EP-2 M1 complete after moving inbox backlog gauge recording behind `sampleInboxBacklog`, updating the metrics test, and recording focused/full test validation.

Revision note (2026-07-02, EP-2 M2): Marked EP-2 M2 complete after changing fresh inbox intake to insert directly as completed, documenting legacy processing status semantics, and recording focused/full test validation.

Revision note (2026-07-02, EP-2 M3): Marked EP-2 M3 complete after adding the inbox received-index drop migration, regenerating expected schema, restoring unrelated generated newline churn, and recording migration test validation.

Revision note (2026-07-02, EP-2 M4): Marked EP-2 M4 complete after adding the batched inbox intake API, shared transaction/result helpers, batch behavior tests, and focused/full `keiro-test` validation.

Revision note (2026-07-02, EP-2 M5): Marked EP-2 M5 complete after adding `InboxPersistence`, exposing dedupe-only intake variants, keeping failed rows full-envelope, and recording build/focused/full `keiro-test` validation.

Revision note (2026-07-02, EP-2 Final): Marked EP-2 and the master plan complete after adding inbox after-only benchmarks, committing `baseline-inbox.csv`, extending `bench-regression`, recording before/after ratios and the batch advisory shortfall, and recording final benchmark/build/test/migration validation.

Revision note (2026-07-02, post-implementation review): Recorded an independent review of the completed initiative — re-ran tests and the benchmark regression guard, confirmed both headline bottlenecks fixed in code (with live claim-query/EXPLAIN verification), added a Post-Implementation Review section to Outcomes & Retrospective with follow-up findings (batch condemn misreporting, PerSourceStream cross-source skip, `markFailedStmt` guard, test gaps), and added Surprises & Discoveries entries including the ephemeral-pg durability-off explanation for the batch-100 benchmark shortfall.

Revision note (2026-07-02, review follow-up fixes): Implemented all review follow-ups in four commits — `markFailedStmt` publishing guard (`894e126`), per-source outcome grouping with `BatchGroup` for StopTheLine plus the summary-haddock correction (`5395da0`), condemned-batch detection with per-message fallback (`070590d`), and six new tests covering the fixes plus the legacy-processing, claim-hold, and dedupe-race gaps (`d000871`). Full suite 278 examples 0 failures; `just bench-regression` re-validated after the changes. Updated the Post-Implementation Review section with per-finding resolution status and the accepted residual risks.
