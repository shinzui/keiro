---
id: 271
slug: apply-async-projections-and-advance-checkpoints-atomically
title: "Evaluate the need and performance of atomic async projection checkpointing"
kind: exec-plan
intention: intention_01m1zd0qx4ehv9tvtd1f52tt3j
created_at: 2026-09-08T02:15:51Z
---


# Evaluate the need and performance of atomic async projection checkpointing


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during execution. Follow `agents/skills/exec-plan/PLANS.md` and `agents/skills/exec-plan/ADR.md`. Preserve plan ID 271, its existing slug/path, and its linked intention so existing references remain valid.

## Purpose / Big Picture


Determine whether Keiro should support atomic asynchronous projection application and subscription checkpoint advancement. Deliver a reproducible database experiment and an evidence-backed decision: retain the existing delivery model, pursue ownership fencing separately, or propose a narrowly scoped atomic mode. Deferring atomic mode is a successful outcome when its incremental benefit does not justify its cost.

[IR-10](../improvement-requests/support-atomic-async-projection-apply-and-checkpoint-advancement.md) identifies a real separation between target application and checkpoint commit. It does not establish an unmet application requirement: existing transactionally retained deduplication already suppresses duplicate target SQL after a crash. The original plan prematurely committed to upstream releases and a second public runner. This revision gates that work on a concrete use case, correctness evidence, and measured performance. Execution of this plan delivers an evaluation, not production adoption.

## Progress


- [x] (2026-09-07) Validate the split transaction against Keiro and Mori-resolved dependency source; create the plan and link intention `intention_01m1zd0qx4ehv9tvtd1f52tt3j`.
- [x] (2026-09-07) Reframe the plan around need, independent ownership fencing, and performance after user review.
- [ ] Establish a concrete consumer requirement and a reproducible baseline with explicit acceptance budgets.
- [ ] Evaluate ownership fencing independently and build only the minimal justified atomic prototypes.
- [ ] Measure eligible alternatives and verify their crash, ordering, ownership, and rebuild behavior.
- [ ] Record a proceed, fencing-only, or defer decision and archive reproducible evidence.

## Surprises & Discoveries


The current recommended path already commits one projection transaction per event. With N successful events and checkpoint batch size B, its approximate commit count is N + ceil(N/B); a per-event atomic path can use N commits. Atomic mode does not inherently add commit flushes. It increases checkpoint updates from approximately ceil(N/B) to N while retaining dedup writes and adding coordination. Evidence: `docs/guides/asynchronous-projections.md` runs `Store.runTransaction` per delivery and documents batch checkpoint saves; `applyAsyncProjectionFromCatalog` in `keiro/src/Keiro/Projection.hs` includes dedup and application SQL.

No workload requirement beyond the mechanism request, measured overhead, or benchmark result has been established. A checkpoint-write multiplier is not a total workload slowdown estimate. A batch size of 100 can imply roughly 100 times as many checkpoint updates for per-event atomic processing, without implying 100 times as much database work.

## Decision Log


Decision (2026-09-07, initial): IR-10 describes a real missing transaction boundary. Keiro must not implement it through private Kiroku SQL or misuse the all-member reset API. This technical finding remains valid.

Decision (2026-09-07, revised after user review): Replace the original five production milestones with four evaluation milestones. Existing deduplication handles ordinary crash redelivery; atomic mode retains dedup for migration and rebuild, so storage/retention savings are not an established benefit. No new production API, dependency release, migration, or default change is part of this evaluation.

Decision (2026-09-07): Separate ownership fencing from atomic checkpointing. Rejecting stale owners may be valuable under the current delivery model. Measure a fencing-only alternative and do not credit its benefit solely to atomic commits. Poison-event halt policy, filtering restrictions, and fixed topology are experiment controls rather than adopted product policy.

Decision (2026-09-07): Compare current per-event application with batched checkpoints, that path plus ownership fencing, atomic per-event processing, and bounded atomic batches. Keep deduplication and application work comparable. Batching must have both a size bound and a maximum fill delay and must preserve per-member ordering. A speedup caused by batching is not automatically evidence for a second public delivery mode.

Decision (2026-09-07): A concrete unmet need and predeclared budgets are required to recommend proceeding. If no such need is found, complete the baseline evidence and conclude defer; expensive upstream prototypes are unnecessary. A proceed recommendation still ends this evaluation and requires a separately scoped implementation plan. The earlier commitments to `Keiro.Projection.Atomic`, adapter releases, telemetry instruments, and migration changes are superseded.

## Outcomes & Retrospective


The planning revision is complete. Evaluation and benchmarks have not started. The current supported architecture remains unchanged. At evaluation completion, record the selected outcome, measured tradeoffs, remaining uncertainty, and whether any independent ownership defect warrants a separate fix. Do not describe a prototype or an anticipated gain as shipped functionality.

## Context and Orientation


A projection converts persisted events into queryable tables. An asynchronous projection runs after the command has committed. A subscription member owns a durable checkpoint, meaning the last position it has safely resolved. Deduplication records a stable event identity so a repeated delivery does not repeat application SQL. A fence is a database check and lock that excludes a writer during rebuild or after ownership changes. An ownership generation is a monotonically changing token identifying one acquisition; it prevents a worker that loses and later reacquires the same member from accepting an old delivery.

The validation evidence is concrete. `keiro/src/Keiro/Projection.hs` defines `applyAsyncProjectionFromCatalog`, returning `Tx.Transaction CatalogAsyncApplyOutcome`. It locks the rebuild group, selects the persisted serving revision when applicable, and inserts dedup evidence with target SQL. It neither receives a subscription delivery token nor saves the checkpoint. `docs/guides/asynchronous-projections.md` explicitly documents the crash between target application and batch checkpoint save. `keiro/src/Keiro/Subscription/Shard/Worker.hs` acknowledges after handlers return and explicitly admits that a zombie can continue briefly after missing lease renewal; a monotonic checkpoint prevents regression but does not prevent stale target writes or forward skipping.

The dependency owner is `mori://shinzui/kiroku`. Its packages `mori://shinzui/kiroku/packages/kiroku-store` and `mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` own subscription persistence and adapter delivery. In that project, inspect project-relative `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` (`processEvents`, `saveCheckpoint`), `kiroku-store/src/Kiroku/Store/Subscription/Checkpoint.hs` (`resetSubscriptionCheckpointsTx`), `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`, and `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` (artifact-level source URIs pending). The worker calls the handler, then separately saves through its pool. The adapter supplies an acknowledgement channel, not a transaction resource. Its group guard is a startup probe, not a lifetime fence. Reset changes every existing member of named subscriptions to an exact position and is deliberately allowed to rewind; using it for live delivery could skip another member's work.

On 2026-09-07, Hackage preferred-version JSON and upstream tags agreed on store 0.8.0.0 and adapter 0.5.1.1. Both release tags dereference to `7726d23028cd4edfba69762edf659485b9547da4`. The Mori checkout inspected was `7051b12`; its examined delivery path still has the split transaction. Keiro currently bounds the store at `>=0.8 && <0.9` and does not depend directly on the adapter. These observations are evidence, not future version pins. Recheck release truth at implementation time. Related pending topology work is `mori://shinzui/kiroku/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps`; its downstream adoption is coordinated by `mori://shinzui/kiroku/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption`. Do not duplicate that resize work or assume it supplies atomic handler execution.

Local files to extend are `keiro/src/Keiro/Projection/Catalog.hs` for existing registration lookup, `keiro/src/Keiro/ReadModel.hs` for freshness waits, `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`, `keiro/src/Keiro/ReadModel/Rebuild/Versioned.hs`, and `keiro/src/Keiro/ReadModel/Rebuild/Stream.hs` for rebuild coordination. Shard ownership lives in `keiro/src/Keiro/Subscription/Shard.hs`, `keiro/src/Keiro/Subscription/Shard/Schema.hs`, and `keiro/src/Keiro/Subscription/Shard/Worker.hs`. Telemetry lives in `keiro/src/Keiro/Telemetry.hs`. The Hspec test suite is registered by `keiro/test/Main.hs` and `keiro/keiro.cabal`; `keiro-test-support/src/Keiro/Test/Postgres.hs` creates migrated temporary PostgreSQL databases per example. Existing relevant suites include `keiro/test/ProjectionReplaySpec.hs`, `keiro/test/VersionedRebuildSpec.hs`, `keiro/test/ReadModelSpec.hs`, and `keiro/test/CatalogSpec.hs`.

Relevant ADRs were consulted. [ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md) requires reporting actual progress and propagating cancellation; its per-item isolation cannot skip an ordered predecessor. [ADR-26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md) separates query freshness from delivery and makes the validated catalog authoritative. [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md) forbids private dependency SQL. [ADR-31](../adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md) preserves exact member checkpoint identity and atomic dedup restoration during rebuild. [ADR-33](../adr/0033-consistency-waits-target-reachable-visible-heads.md) waits for reachable visible positions using the slowest durable member. [ADR-34](../adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md) selects live revision handlers under the group lock and separates prepared checkpoints from serving-generation promotion. The plan must preserve all these contracts.

The evidence above describes the inspected checkout, not a guarantee that dependency releases remain unchanged. Use Mori again before unfamiliar dependency API work. No dependency bounds are being chosen in this revision.

`keiro/bench/Main.hs` and `keiro/bench/ReadModelBench.hs` provide existing PostgreSQL benchmark conventions. `keiro/keiro.cabal` registers the `keiro-bench` component. These microbenchmarks are useful context, but end-to-end delivery, checkpoint, and reassignment measurements need a dedicated experiment harness. A percentile such as p99 is the latency below which 99 percent of measured events fall. WAL is PostgreSQL's write-ahead recovery log; record its generated bytes as one measure of write cost. A bounded batch groups consecutive member deliveries into one transaction, limited by both event count and waiting time.

## Plan of Work


### Milestone 1: Establish the need and the existing baseline


Produce `docs/plans/271-evaluation/decision.md` describing the consumer scenario, the existing guarantee, and the specific unsatisfied requirement. Search registered dependents through `mori registry dependents shinzui/keiro --packages` and inspect relevant local application wiring; identify cross-repository evidence by canonical Mori URI. A mechanism request or a preference for the words exactly-once is insufficient. State whether the actual issue is duplicate SQL, stale ownership, cursor freshness, retention work, or recovery time. Include a reproducible triggering scenario and explain why retained deduplication does or does not solve it. If no consumer evidence exists, explicitly record that absence without inventing a requirement.

Add an isolated executable experiment component `keiro-projection-evaluation` in `keiro/keiro.cabal`, using `keiro/bench/ProjectionEvaluationMain.hs` and `keiro/bench/ProjectionEvaluation.hs`. Keep all new modules outside the exposed library. Reuse `Keiro.Test.Postgres` fixtures, current catalog-aware application SQL, and released Kiroku subscription APIs. The baseline must run real delivery through its actual batch checkpoint path; a loop that merely imitates checkpoint timing is not equivalent. Use a counter projection with non-idempotent increments and retained dedup keys to expose duplicate application. Add an indexed multi-row projection scenario to avoid drawing conclusions only from a trivial counter.

Demonstrate killing a worker after target/dedup commit but before checkpoint persistence, restarting, and observing one increment despite redelivery. Capture both durable state and recovery time. Record the observed checkpoint batch size and commit/update counts rather than assuming every configured fetch ends as a full batch.

Before measuring alternatives, write application-derived throughput, p95/p99 end-to-end lag, recovery/reassignment, and rebuild-delay budgets into `decision.md`, with their source and rationale. End-to-end lag starts when the source append commits and ends when the effect is durably applied; separately measure when the supplying checkpoint makes a freshness wait eligible. Budgets must not be chosen after seeing a favored result. If no consumer and no defensible budget are available, run the baseline smoke/correctness experiment and finish with defer. No user input is required merely to conclude insufficient evidence. Verify this milestone with the baseline commands below and captured raw output.

### Milestone 2: Isolate ownership benefits and prototype only necessary boundaries


If milestone 1 supports further investigation, add a fencing-only experiment with the same per-event projection and batch checkpoint behavior as baseline. An ownership fence checks and locks the member's current acquisition generation through target commit, preventing a stale worker from writing after effective transfer. Generation must change on release/reacquisition as well as reassignment; a process UUID alone cannot distinguish two acquisitions by the same process. Implement temporary Keiro-owned experiment state in the isolated database or a non-exported experimental combinator, not a production migration. Document exactly which parts match current shard coordination and which are prototypes.

Test a paused old worker after transfer and a transfer racing an in-flight transaction. Transfer may wait for the old transaction's lock, but a superseded generation must then be unable to commit. Include the checkpoint-save path: fencing target writes alone does not prove that an old worker cannot acknowledge or advance a later position. If the existing dependency API prevents safe fencing of that path, record the limitation and evaluate the minimum owning-library extension separately. Do not label partial target fencing an end-to-end solution.

For atomic candidates, resolve `mori://shinzui/kiroku` and make the minimum experimental transaction boundary in the owning project's store/adapter code, following its local instructions. Keiro must not write private dependency tables or repurpose `resetSubscriptionCheckpointsTx`. A prototype may use an isolated local Cabal project override without changing committed release bounds. Record exact checkout revisions and patches with canonical owning-project references. A released API is required for any later production adoption, not for this experiment.

Compare atomic per-event execution and bounded atomic batches. Both must commit application SQL, retained deduplication, and the exact member's valid ordered checkpoint together. They need ownership generation checks and expected durable predecessor validation. Consecutive means consecutive in the selected member/source sequence, not adjacent numeric global positions. For a batch, apply all events and dedup entries in order, then advance once to the batch tail; any failure rolls back the whole batch. Bound count at configurable values and maximum fill delay; never keep a database transaction open merely while waiting for a batch to fill. Bind each batch to one ownership generation and source/topology identity.

Use group-before-checkpoint lock order consistently with rebuild. Keep transactions bounded and do not hold a database connection across an unbounded adapter acknowledgement wait. Keep handler failure policy, selectors, member topology, and target SQL identical across variants wherever possible; label any unavoidable difference. Unit count limits alone cannot bound time spent in slow application SQL, so configure and record statement/transaction deadlines. This milestone is verified by experimental atomicity and ownership tests, not by a public runner API or an upstream release.

### Milestone 3: Measure the costs and prove comparable correctness


The experiment executable must support baseline, fenced, atomic-event, and atomic-batch variants. Register `self-test` for deterministic correctness checks and `measure` for timed runs using the CLI contract below. Reject unavailable variants with a nonzero exit and a clear explanation; never silently substitute a simulated or baseline implementation.

Measure one and four subscription members, small counter and indexed multi-row SQL, idle/low-rate traffic, sustained traffic, and a deliberately slow handler. Use checkpoint batch sizes 1 and 100 for the existing path and batch sizes 10 and 100 with maximum fill delays 5 ms and 20 ms for atomic batches. These are experimental points, not production defaults. If consumers need another rate or topology, add it before comparing results. Fix the event set, source selection, indexes, dedup retention, and offered load for paired comparisons. If a no-atomic application-batched control is feasible, include it to distinguish batching gains from atomicity gains; otherwise explicitly qualify that attribution.

Warm up each variant for 10 seconds and collect at least five independent 60-second measurement runs per sustained scenario, rotating variant order. For low traffic, measure enough events to make tail percentiles meaningful and include batch-fill waiting in latency. Run timed trials sequentially on otherwise idle infrastructure. Record hardware, PostgreSQL/GHC versions, dependency revisions, pool size, synchronous commit and replication settings, event size, database size, offered rate, and initial dedup state. Keep durability settings identical; do not trade crash guarantees for an apparent speedup. Record backlog growth when offered load exceeds capacity rather than reporting only the latency of completed events.

Collect events per second, p50/p95/p99 apply lag and checkpoint/freshness lag, checkpoint updates per event, transaction commits, WAL bytes per event, CPU use, lock waits, connection utilization, and database/table growth. Use PostgreSQL statistics supported by the actual server version, discovered through its documentation, and isolate runs so unrelated activity does not pollute deltas. Distinguish logical commits from observed WAL flushes; concurrent commits can share flush work. Report median results and run-to-run ranges, not a single favorable run. Missing metrics must be marked unavailable with a reason.

Measure ownership transfer delay and rebuild fence acquisition delay under a slow handler. Test one failed predecessor with later events pending, two members with one blocked, before/after-commit child termination, cancellation while waiting for locks, connection loss around commit, explicit transaction condemnation, and rollback after dedup insertion. For atomic batches, prove entire-batch rollback, ordered replay, bounded low-rate fill delay, and no checkpoint past an unprocessed member predecessor. A lost commit response is an unknown client outcome resolved by durable state on restart.

Exercise existing offline rebuild, online preparation/promotion, and targeted stream repair. Online preparation may advance checkpoints while reads remain fenced; it must not expose a candidate generation early. Keep dedup keys in all comparisons because these workflows still depend on them. A missing adapter/rebuild integration proof disqualifies a production proceed recommendation even if the SQL microbenchmark looks fast. Save raw JSONL and reproduction metadata under `docs/plans/271-evaluation/`, then summarize the tradeoffs in `decision.md`.

### Milestone 4: Make the adoption decision and close the evaluation


Compare every eligible variant against the requirement and budgets declared in milestone 1. A proceed recommendation requires an unmet consumer requirement beyond retained deduplication, full relevant correctness proofs, and acceptable measured throughput, tail latency, write cost, reassignment, and rebuild delay. Compare against fencing-only as well as baseline. A marginal mechanism improvement does not justify maintaining a second mode when the simpler alternative meets the requirement.

Record exactly one recommendation in `decision.md`: `defer`, `fencing-only`, or `proceed`. Defer when no unmet need exists, required evidence is missing, or costs exceed budgets. Fencing-only means propose a separate ownership hardening task while retaining the current checkpoint model. Proceed means identify the smallest justified execution mode, batch limits and deadlines if applicable, exact dependency work, known limitations, and required migration/release tests. It does not authorize shipping a production mode within this evaluation.

For a proceed outcome, preserve the future requirements: an explicit supported capability with no silent fallback; released owning-library APIs; exact catalog/member identity; atomic rollback; stale generation exclusion; rebuild/read compatibility; retained deduplication; and stop/drain migration without rewriting checkpoints. Do not automatically carry forward the original proposed public names, poison-event policy, or rejection of filters. Decide those against the demonstrated consumer requirement in a follow-on implementation plan.

At closure, update this plan's Progress, Outcomes, and Decision Log with evidence paths and remaining limitations. Keep the experiment reproducible but outside production exports and dependencies where possible; remove temporary overrides from normal builds. Review the existing ADRs and promote only a durable decision or finding once supported by evidence. The current planning revision changes no accepted architectural contract and therefore does not amend ADR-31 or other ADRs merely to announce an experiment. If the evaluation yields a lasting architecture decision, follow the ADR profile workflow below at that time.

## Concrete Steps


Run from the Keiro repository root with GHC 9.12, Cabal, and PostgreSQL executables available; use `nix develop` if required. Do not search or read `/nix/store` or traverse the filesystem root. The fixture creates isolated temporary databases, not application development data.

```bash
mori registry list
mori registry search kiroku
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori registry dependents shinzui/keiro --packages
mori path mori://shinzui/kiroku/packages/kiroku-store
mori path mori://shinzui/kiroku/packages/shibuya-kiroku-adapter
```

Before selecting a dependency bound, pin, or compatibility workaround, check authoritative release metadata and upstream tags. These endpoints verify the releases of `mori://shinzui/kiroku` and do not replace canonical project references.

```bash
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
curl -fsSL https://hackage.haskell.org/package/shibuya-kiroku-adapter/preferred.json
git ls-remote --tags https://github.com/shinzui/kiroku.git
```

The following executable and flags are deliverables of this plan, not existing commands. `--variant all` selects every implemented variant and refuses a supposedly complete comparison if any required variant is unavailable. `--matrix standard` executes the workload matrix in milestone 3. Baseline alone is sufficient for the explicit early-defer path.

```bash
cabal build keiro:exe:keiro-projection-evaluation
cabal run keiro:exe:keiro-projection-evaluation -- self-test --variant baseline
cabal run keiro:exe:keiro-projection-evaluation -- measure --variant baseline --matrix standard --warmup-seconds 10 --seconds 60 --repetitions 5 --output docs/plans/271-evaluation/baseline.jsonl
cabal run keiro:exe:keiro-projection-evaluation -- self-test --variant all
cabal run keiro:exe:keiro-projection-evaluation -- measure --variant all --matrix standard --warmup-seconds 10 --seconds 60 --repetitions 5 --output docs/plans/271-evaluation/comparison.jsonl
cabal test keiro-test --test-show-details=direct
git diff --check
```

For an early defer, use a single short baseline smoke trial with `--seconds 5 --repetitions 1` instead of the sustained matrix; label it smoke evidence, not a performance conclusion. Record actual command lines including any local project override needed for upstream experiments. Each self-test must print a positive scenario count with zero failures; unavailable variants and zero-test selections are errors. Measurements exit successfully only after verifying final target counts and checkpoint outcomes. Refuse overwriting existing result files unless an explicit overwrite option is passed; use distinct result filenames for later runs.

If an ADR changes at evaluation completion, inspect the local contract before writing it:

```bash
mori show --full
dhall --file docs/adr/profile.dhall
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
just adr-validate
```

Preserve existing ADR IDs; allocate a new one only when creating a record. Maintain timestamps and the bundle log through the installed `okf log add` interface. Record exact upstream experiment test commands after resolving their actual Cabal components. Every commit uses Conventional Commits and both trailers:

```text
ExecPlan: docs/plans/271-apply-async-projections-and-advance-checkpoints-atomically.md
Intention: intention_01m1zd0qx4ehv9tvtd1f52tt3j
```

## Validation and Acceptance


The evaluation succeeds when a reader can reproduce its baseline demonstration, inspect its consumer requirement and predeclared budgets, and follow the evidence to a clear adoption decision. For an early defer, the report must show current crash/dedup behavior and state that no unmet consumer requirement was found; it must not claim atomic mode was benchmarked. A later defer may be supported by failed correctness proofs or unacceptable measured costs. Those are useful negative results, not reasons to quietly narrow acceptance.

A fencing-only recommendation must separate proven target fencing from the full checkpoint/acknowledgement ownership contract. A proceed recommendation needs actual upstream transaction composition and adapter behavior, all eligible comparisons, and the crash/ownership/ordering/rebuild tests in milestone 3. A mocked checkpoint, invented generation check, or private dependency-table write in Keiro cannot establish feasibility.

Performance claims require matched work, matched durability, included batch-fill delay, reproducible environments, and repeated measurements. Correct the commit accounting explicitly: baseline normally has per-event projection commits plus batch checkpoint commits; atomic-event combines each update/checkpoint but increases checkpoint row update frequency. Retained dedup remains present in both. Do not claim retention savings or extrapolate checkpoint-update ratios into overall slowdowns. Report absolute consumer budgets as well as relative changes and noise.

No production atomic runner, migration, dependency release, or change of supported delivery defaults is required for completion. A supported follow-on direction must be justified rather than presumed.

## Idempotence and Recovery


Use fresh isolated databases and deterministic event fixtures for every comparison. Stop and join child workers in cleanup, including failed fault-injection runs. Reset fixtures between trials; distinguish setup cost from steady-state measurements and keep starting data volumes comparable. Preserve raw outputs instead of replacing inconvenient runs.

Experimental upstream changes stay in their owning project and are identified by canonical project URI, revision, and project-relative patch paths where source artifact URIs are pending. Use an isolated Cabal override for prototypes; never silently change normal dependency bounds or rewrite released migrations. Retain a buildable baseline if an experiment is unavailable. Before continuing another contributor's checkout, inspect existing edits and do not revert unrelated work.

Failure before atomic commit rolls back the entire event or batch. Failure after commit but before confirmation is resolved from durable state on restart. Never manually rewind a production checkpoint to make a test pass, prune dedup evidence to improve an atomic-only benchmark, or force a rebuilding group live. Discarding an experimental candidate does not require undoing production data because the evaluation never uses it.

## Interfaces and Dependencies


Production interfaces remain unchanged, including `applyAsyncProjectionFromCatalog :: ValidatedProjectionCatalog -> ProjectionId -> AsyncProjection -> RecordedEvent -> Tx.Transaction CatalogAsyncApplyOutcome`. The deliverable interface is the isolated `keiro-projection-evaluation` executable with the `self-test` and `measure` contracts above. Its internal variant selector distinguishes baseline, fencing-only, atomic-event, and atomic-batch; no new exposed library module is prescribed.

Each JSONL measurement record must identify variant, workload, run, member count, offered rate, checkpoint/batch size and maximum fill delay, completed count, backlog, duration, latency percentiles, commit/checkpoint counts, available resource metrics, correctness result, and environment/revision metadata or the path to a shared metadata record. Include units in field names. Keep unavailable metrics explicit rather than encoding them as zero. `decision.md` records the need, budgets, evidence, alternative comparison, and selected recommendation in prose.

Use `mori://shinzui/kiroku/packages/kiroku-store` for event/checkpoint persistence and its experimental transaction authority, `mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` for adapter behavior, and `mori://shinzui/shibuya/packages/shibuya-core` for the existing processing framework. Discover dependency source with Mori before using unfamiliar APIs. If a prototype requires unreleased operations, mark them experimental and record exact signatures after implementing them in the owning project. Only a later production implementation requires verified released prerequisites.

Revision note (2026-09-07): Originally created to implement IR-10 and linked to an intention created with `mina ci --json`. After reviewing the existing dedup guarantee and performance concerns, comprehensively replaced the production roadmap with a need, ownership, correctness, and performance evaluation. Corrected commit-cost assumptions, added per-event and bounded-batch comparisons, and made defer a successful outcome. Retained plan identity and intention; no architecture or runtime contract changed.
