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
| 1 | Outbox publisher throughput: run claiming, batch publish, off-hot-path maintenance | docs/plans/81-outbox-publisher-throughput-run-claiming-batch-publish-off-hot-path-maintenance.md | None | None | In Progress |
| 2 | Inbox consume throughput: single-insert completion, off-hot-path gauge, batched intake, slim persistence | docs/plans/82-inbox-consume-throughput-single-insert-completion-off-hot-path-gauge-batched-intake-slim-persistence.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are no hard dependencies: neither plan needs the other's artifacts to compile or make sense, and they can be implemented in either order or in parallel *sessions* (not parallel worktrees — see the expected-schema integration point). EP-1 and EP-2 each add one forward SQL migration to `keiro-migrations/sql-migrations/` and regenerate `keiro-migrations/expected-schema/` with `cabal run keiro-write-expected-schema`; codd migration files sort lexicographically by timestamp prefix and the expected-schema representation is a single on-disk snapshot, so whichever plan lands second must regenerate the expected schema on top of the first plan's committed state. If implemented concurrently in separate branches, the second to merge must re-run the regeneration and re-commit; implementing them sequentially in one branch avoids the conflict entirely and is the recommended order (EP-1 first, since the outbox findings dominate the throughput gap).


## Integration Points

**`keiro-migrations/expected-schema/` snapshot (EP-1, EP-2).** codd's drift check compares the live schema against a single on-disk representation regenerated by `cabal run keiro-write-expected-schema`. Both plans add a migration and regenerate. The plan that lands second regenerates over the first's result. Each plan's validation includes `cabal test keiro-migrations-test`, which fails loudly on drift, so a stale regeneration cannot land silently.

**Backlog-gauge sampling pattern in `keiro/src/Keiro/Telemetry.hs` (EP-1 defines, EP-2 follows).** Both plans remove inline backlog gauging (`recordOutboxBacklog` / `recordInboxBacklog` calls) from hot paths and move it behind explicit sampling functions the application schedules on a timer. EP-1 introduces the convention — a `sampleOutboxBacklog :: (Store :> es) => Maybe KeiroMetrics -> Eff es ()` helper in `Keiro.Outbox` that composes the existing `countOutboxBacklog` count with the existing `recordOutboxBacklog` gauge write. EP-2 mirrors it as `sampleInboxBacklog` in `Keiro.Inbox` with the same shape and naming. The telemetry metric names and instruments themselves do not change; only the call sites move.

**`keiro/test/Main.hs` (EP-1, EP-2).** Both plans extend the same hspec file (currently ~8100 lines; `describe "Keiro.Outbox"` around line 2502, inbox specs elsewhere in the same file). The blocks are disjoint `describe` groups, so textual conflicts are unlikely; each plan runs the full `cabal test keiro-test` before completion.

**`keiro-bench` benchmark component and `bench-regression` Justfile target (EP-1, EP-2).** Both plans add tasty-bench scenarios to one shared `benchmark keiro-bench` stanza in `keiro/keiro.cabal` (sources in `keiro/bench/Main.hs`). Whichever plan is implemented first creates the component (and the `tasty-bench` dependency, plus any nix override) and the `bench-regression` Justfile target; the second plan appends its benches and its target line. Namespaces are disjoint — EP-1 owns `outbox.*` benches and `keiro/bench/baseline-outbox.csv`, EP-2 owns `inbox.*` and `keiro/bench/baseline-inbox.csv` — and the per-area baseline CSVs exist specifically so the two plans' final-milestone commits never conflict on one file. Each plan's M0 runs against unchanged code to record its "Before" baseline in its own Outcomes & Retrospective section; each plan's final milestone records the "After" comparison and commits its baseline CSV as the standing regression guard (`--baseline`, `--fail-if-slower 25`; manual/local by design, not part of `just verify` or CI).

**`Maybe KeiroMetrics` parameters stay in place (EP-1, EP-2).** Removing inline gauge recording must not change the *signatures* of `publishClaimedOutbox`, `runInboxTransaction`, or `runInboxTransactionWithRetries` beyond what each plan explicitly specifies — counters (published/retried/dead, processed/duplicates/failed/poisoned) still record through the passed `Maybe KeiroMetrics`. Only the backlog gauge calls move out.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 M0: tasty-bench `keiro-bench` outbox scenarios + recorded "Before" baseline on unchanged code (completed 2026-07-02T00:02:14Z)
- [x] EP-1 M1: Contiguous per-key/per-source run claiming in `claimOutboxBatch` with regression tests (completed 2026-07-02T00:11:43Z)
- [ ] EP-1 M2: Claim-order partial index migration and regenerated expected schema
- [ ] EP-1 M3: Batch-shaped publish contract in `publishClaimedOutbox` with bulk sent-marking
- [ ] EP-1 M4: Maintenance extracted to `outboxMaintenancePass`; gauges/sweep off the hot path
- [ ] EP-1 Final: "After" benchmark run recorded with before/after ratios; `baseline-outbox.csv` committed; `bench-regression` guard in place
- [ ] EP-2 M0: tasty-bench inbox scenarios + recorded "Before" baseline on unchanged code
- [ ] EP-2 M1: Backlog gauge removed from per-message inbox path; `sampleInboxBacklog` added
- [ ] EP-2 M2: Single-insert completed rows (drop the unobservable `processing` intermediate write)
- [ ] EP-2 M3: Inbox migration (drop `keiro_inbox_received_idx`) and regenerated expected schema
- [ ] EP-2 M4: Batched intake variant `runInboxTransactionBatch` with per-message poison fallback
- [ ] EP-2 M5: Slim payload persistence option (`InboxPersistence`)
- [ ] EP-2 Final: "After" benchmark run recorded with before/after ratios; `baseline-inbox.csv` committed; `bench-regression` extended


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

(None yet.)


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

(To be filled during and after implementation.)

---

Revision note (2026-07-01): Added the benchmarking stage across the initiative at the user's request: a shared tasty-bench `keiro-bench` component (new integration point, including the shared `bench-regression` Justfile target and per-area committed baseline CSVs), M0/final-comparison milestones in both child plans, corresponding Progress entries, and a Decision Log entry covering methodology and the regression guard. Child plans 81 and 82 were revised in the same pass; see their revision notes.
