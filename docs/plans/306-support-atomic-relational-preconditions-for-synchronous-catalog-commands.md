---
id: 306
slug: support-atomic-relational-preconditions-for-synchronous-catalog-commands
title: "Support atomic relational preconditions for synchronous catalog commands"
kind: exec-plan
created_at: 2026-10-11T20:55:42Z
intention: "intention_01m4pbzn0feettj188pac22p2e"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-11T20:55:42Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T21:00:31Z
      mode: "other"
      note: "Draft the five-milestone IR-53 plan with serving-aware guards, same-database race evidence, and mixed-workload performance budgets"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T22:36:02Z
      mode: "update"
      note: "Validate source contracts; fix inline-only command selection and strengthen callback, concurrency, retry, and sustained performance acceptance"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T02:56:46Z
      mode: "implement"
      note: "Begin baseline capture and implementation against Kiroku 0.11.0.0"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T12:43:23Z
      mode: "implement"
      note: "Resume unchanged-budget measurements with host monitoring and investigate timing stability before readiness"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T14:23:44Z
      mode: "implement"
      note: "Resume performance acceptance using Kenshou runbook and remote Linux infrastructure"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T22:37:09Z
      verdict: "approved"
      note: "Updated plan is implementable after source validation; runtime race proof and performance gates remain mandatory and unmeasured"
---

# Support atomic relational preconditions for synchronous catalog commands


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current during implementation.
Promote durable decisions into the relevant ADRs when the implementation is
verified. This document plans work; it records no implementation or benchmark
success and does not authorize publication or downstream deployment.


## Purpose / Big Picture


Deliver [IR-53](../improvement-requests/support-atomic-relational-preconditions-for-catalog-domain-commands.md): let an application create one aggregate only if a relational identity is still absent, while retaining Keiro's synchronous projection, transaction, and rebuild guarantees. In the motivating note example, two concurrent callers propose different note IDs for the same anchor/property/state identity. Exactly one creation event and minimal identity-index row commit atomically. The rich note query view is asynchronous and contains one note after catch-up. Both callers receive the winning ID, with one reporting creation and the other reuse. Repeating the operation, including for an archived note, preserves the first content, tags, and provenance.

The extension is an opt-in sibling of `runDomainCommandWithCatalogProjections`. A synchronous or inline projection updates its SQL tables in the event append transaction. An asynchronous projection runs later in a subscription worker; it is outside this extension. The guard is a consumer-owned SQL precondition, not another aggregate command or a new domain decision evaluator.

The implementation is acceptable only with concurrency, rollback, catalog lifecycle, and performance evidence. A check after append holds Kiroku's global append lock longer and can slow unrelated writers. The plan intentionally measures that cost before considering a larger pre-append locking protocol. No package version, release tag, or downstream pin is selected here.


## Progress

- [x] (2026-10-12 14:34Z) Inspect the Kenshou exact-revision runbook, discover existing cloud infrastructure, correct Keiro's Mori upstream identity, and prepare a clean source bundle for the Linux builder. No catalog performance profile exists in the harness.
- [x] (2026-10-12 14:34Z) Durable fixture validation passes 36 focused examples including the settings assertion; test-support passes 11 examples, reporting passes six controls, and export/ADR/user-documentation checks pass.
- [x] (2026-10-12 14:40Z) Full regression with the revised fixture passes 755 examples in 168.34 seconds; strict ADR, documentation, IR and export checks pass. Commit `ff1126d4` retains the durable fixture and portability fixes.
- [x] (2026-10-12 14:54Z) Local benchmark smoke completes 100 attempts on durable PostgreSQL 18.6 with exactly 10,100 identities and 800 warm-up/measured events. Seven reporting/host-monitor controls pass, including live child processes named as a Nix-wrapped Cabal command and an external test. Archive this as harness validation, not an acceptance pair.
- [ ] Remote M1/M4: rebuild both binaries with the durable benchmark fixture and observed database settings; obtain uncontented paired measurements and the complete fixed-budget matrix.


- [x] (2026-10-11) Refine the plan and baseline guidance around minimum synchronous identity authority, asynchronous query models, and post-commit waits; runtime implementation remains pending.
- [x] (2026-10-11) Validate the design against current command/catalog code and Mori-located transaction dependencies; correct projection-set selection, callback restrictions, race coverage, and performance measurement requirements. This is source review, not runtime proof.
- [x] (2026-10-12) M1 dependency discovery: Cabal resolves Kiroku 0.11.0.0, Hasql 1.10.3.7, hasql-transaction 1.2.3.1, GHC 9.12.4; PostgreSQL is 18.6. Released transaction sources match Mori corpus byte-for-byte. Retain the ordinary executable and paused-worker latency samples.
- [x] (2026-10-12) M1 runtime/source checks: overlapping backends have distinct PIDs in the same database/schema; source-derived SQL/explicit-lock audit records no change on the ordinary path. The initial full suite passes 739 examples.
- [x] (2026-10-12) M1 enhanced executable: retain the original production library with the byte-verified shared workload/fixture harness; its source/build hashes and rebuild command are archived.
- [ ] M1 remaining: capture accepted alternating throughput/latency with both worker states. Initial latency-only samples are provenance, not acceptance denominators.
- [x] (2026-10-12 12:48Z) Attempt the unchanged-budget comparison in `candidate-idle-20261012`, recording executable identity and ten host samples. Stop after two alternating pairs when independent builds/tests start; all 40,000 completed attempts have expected event/cardinality counts. This is incomplete evidence, not an additional budget failure or pass.
- [ ] M1/M4 runner requirement: obtain a runner kept free of competing builds/tests for the complete matrix. An original-versus-original diagnostic remains available if failures persist there; do not select favorable repetitions on the shared host.
- [x] (2026-10-12) M2 implementation: additive result/context and guarded runner compile, sharing the existing delivery loop after complete fence admission.
- [x] (2026-10-12) M2 validation: initial full suite passes 739 examples; focused expanded selection passes 36 examples, including 34 new guarded examples. Public re-export policy and its nine tests pass. Shared delivery adds no ordinary-path SQL or explicit locks.
- [x] (2026-10-12) M3 focused matrix: independent-connection races in both orders, winner rollback, snapshot/effect rollback, complete batches, silent/OCC/driver retries, encode/query faults, archive/canonical reuse, both owner rebuilds, independent fencing, post-commit pending/ready/unavailable views, and writer-first/promotion-first versioned admission pass.
- [x] (2026-10-12) M3 full regression: 754 examples pass with zero failures in 161.56 seconds after the final fixture changes. Faulting handler positive controls prove refusal/all-fence admission skips delivery, and promotion-first calls permit exactly one creation across both calls.
- [ ] M4: Measure guarded and mixed traffic against the fixed regression budgets. The unchanged-code repeat passes six ordinary configurations, then stops on the eight-connection/four-event/paused-worker throughput ratio of 0.926574 (minimum 0.95); p95/p99 ratios 1.070584/1.064383 pass. Complete acceptance requires reliable measurements on an idle or isolated runner.
- [x] (2026-10-12) M4 diagnostic positive controls: million-row identity lookup uses its composite index; slow 20 ms guard degrades ordinary p95/p99 by 9.21/15.04 times; direct sequence counters observe 1,001 global updates and 201 guard evaluations for 1,000 outer attempts with one injected driver retry. Lock waits and guard/lock-lower-bound clocks are retained under `diagnostic-20261012`.
- [ ] M5: Publish the public recipe, distill ADR decisions, and run the final repository checks.
- [x] (2026-10-12) M5 documentation/export checks: guide, changelog and ADR-26/29/34 boundaries are recorded; strict ADR, user-documentation and IR validation and public export policy pass. The strengthened rebuild completion assertion passes in the 36-example focused selection.
- [x] (2026-10-12) M5 projection guard: all 12 cases pass; the five-run median read-model p95 ratio is 1.041806 and throughput ratio is 0.977885, within its 1.25/0.90 budgets.
- [ ] M5 regression/performance checks: the historical command CSV guard fails nine of fifteen current cases. A matching four-case selection fails three on the retained original binary and one on current; retain these pre-existing/noisy failures without changing the CSV. M4 acceptance remains pending.
- [x] (2026-10-12 12:48Z) Strengthen evidence reporting with all 190 required comparisons, paired-ratio medians/ranges, retained-sample checks, and `--require-complete`. Five Python tests pass in the Nix shell; the interrupted archive correctly reports `incomplete` and exits 2 with that flag.
- [x] (2026-10-12) Continuation checks: strict ADR (50 concepts), user-documentation, IR (53 concepts), and public re-export policy with nine tests pass in the Nix shell. `git diff --check` passes. No production change requires repeating the retained 754-example correctness suite or benchmark guards; performance measurements remain open.


## Surprises & Discoveries

2026-10-12 — The builder stops at 14:47Z during the cold Cabal build despite the SSH transport being connected. Cloud status confirms `TERMINATED`; restart only that authorized VM and retain the interrupted log. Preparation resumes from installed packages, in a new log, at exact candidate `7233bd1e`. Arm the owned eight-hour `keiro-306-restore-idle.timer` before temporarily stopping the existing idle timer, following the infrastructure's earlier bounded-hold precedent. Restore the original timer at the terminal checkpoint; no measurement ran before the interruption.

2026-10-12 — Remote-run preparation discovers that the shared benchmark fixture inherits `mori://shinzui/ephemeral-pg/packages/ephemeral-pg` test defaults: `fsync`, `synchronous_commit`, and `full_page_writes` are off. Historical catalog samples therefore describe non-durable test storage and cannot establish production performance acceptance. Add a separate durable benchmark fixture, query and retain actual database settings in every raw sample, and reject missing/off durability evidence in the final gate. Correctness fixtures retain their existing test settings. Rebuild both retained baseline and candidate with the byte-identical new workload/fixture before timing; budgets and production code remain unchanged.

2026-10-12 — Consult the comparison runbook in `mori://shinzui/keiro-runtime-kenshou`, project-relative path `docs/runbooks/compare-runtime-revision-performance.md` (artifact-level URI pending). At harness commit `1ebfbda`, its performance catalog contains only the uncalibrated Shibuya core/PGMQ profiles, which do not cover this catalog workload. The first planning attempt exits 2 because Keiro's Mori repository record has no upstream; add its existing GitHub identity. Cloud discovery finds the authorized Linux builder running and the alpha/beta cells stopped. Initial builder observation contains unrelated `nagarectl-test` processes; later they finish. Preparation uses the builder's existing local Unix account because the Nix PostgreSQL binary cannot resolve the OS Login user. The second planner attempt reaches upstream verification but exits 4 because candidate commit `66e7d62f` has not been pushed; direct source-bundle preparation retains that exact committed tree without publishing it. No remote measurement is accepted at this preparation checkpoint.

2026-10-12 — The resumed comparison began without an observed competing GHC/Cabal job, but independent compilation and runtime/harness verification started during the first case. Ten host snapshots in `candidate-idle-20261012/host-activity.jsonl` retain the overlap, including a GHC process at 60.7% CPU. Interrupt only the owned benchmark (PID 2661), which exits through Cabal with code -2. Two complete pairs retain 40,000 actual attempts; duplicate process/control archives represent the same samples and are not additional attempts. No five-pair report exists, so no budget verdict is possible. This does not establish a production regression or a noise-free control.

2026-10-12 — The existing evidence summarizer returned success for a partial directory with no failed reports, without enumerating the missing matrix. Add a separate completeness inventory and optional failing gate rather than changing any performance budget. The required matrix has 16 ordinary refactor, 32 successful-guard, 32 pure-hit, 96 mixed, 12 fixed-arrival, and two sustained comparison reports. Passing latency budgets still require a separate storage/backlog interpretation. Five tests cover ratio calculation, empty/partial evidence, complete coverage including storage, and the failing CLI gate.

2026-10-12 — Implementation checkout is `ad78efae0d21d849c8106eac73df0f8bb5719e1f`, with Kiroku already bounded at `^>=0.11.0.0`. No dependency bound change is needed. Published Kiroku 0.11.0.0 `Transaction.hs` and Hasql transaction 1.2.3.1 retry interpreter match the Mori-discovered corpus byte-for-byte. Baseline environment and retained executable digest are in `keiro/bench/results/guarded-catalog/baseline/environment.json`. Initial latency samples overlap compilation and are provenance only; they do not establish M4 acceptance.

The existing `ProjectionWriteBinding` type was exported only by a private module, despite appearing inside the public fence value. Export it from `Keiro.Projection` alongside the opaque context so consumers can name and inspect the supported binding type.

2026-10-12 — The expanded focused selection passes 36 examples in 7.94 seconds. Real same-revision and schema-changing promotions were exercised in both lock orders. Promotion-first admission either obtains a coherent new binding or returns the existing typed invalid/unavailable outcome, and a fresh call succeeds. No resolver change or extra old-path statement was needed. The note fixture declares no stream-scoped targeted repair; that conditional repair scenario does not apply. Catalog rebuilds require the rich subscription checkpoint even with the worker paused; the fixture now initializes it before rebuilding.

2026-10-12 — The initial retained harness records latency but not elapsed throughput or active-worker conditions. Build an enhanced harness against the untouched original production library using `scripts/build-guarded-catalog-baseline.py`; both binaries share byte-identical fixture/request/timing modules. Record their hashes and preserve the original latency archive. This corrects an evidence gap, without substituting historical samples for alternating controls.

2026-10-12 — The first M4 ordinary refactor comparison (10,000 initial identities, one connection, one event, paused worker) completes all five 10,000-attempt pairs but fails the fixed budgets: median throughput/p95/p99 ratios are 0.895126/1.479831/2.067761. Raw evidence is retained in `candidate-20261012`. Unrelated host builds/tests were active. A separate one-pair RTS diagnostic shows original/current allocations of 2,382,670,576/2,362,643,872 bytes and elapsed workload times of 26.319418/12.587346 seconds; it does not reproduce the slowdown and cannot establish acceptance or its cause. Repeat the complete five-pair comparison without code or budget changes; do not select individual favorable samples.

2026-10-12 — The unchanged-code repeat in `candidate-repeat-20261012` passes the first six ordinary configurations. The initially failing case now has median throughput/p95/p99 ratios 0.996619/1.021928/1.012687. The seventh configuration (10,000 initial identities, eight connections, four events, paused worker) fails throughput at 0.926574; p95/p99 1.070584/1.064383 pass. All 700,000 measured attempts complete with expected counts. A separate diagnostic for that configuration allocates 3,245,478,168/3,245,877,264 bytes with mutator CPU 3.680/3.674 seconds (original/current); workload elapsed time is 6.644878/6.564350 seconds. Ordinary source still issues the same SQL and explicit locks. Host records show concurrent GHC/Python jobs, but these observations do not isolate the failure's cause. Do not add speculative optimizations or repeatedly select favorable timings. An idle/isolated runner is requested before further acceptance measurements; budgets and remaining matrix stay unchanged.

2026-10-12 — The normal command benchmark reuses a growing primary fixture and includes hard-delete/reset work. Its full current run fails nine of fifteen historical guards; an identical selected four cases fail three on the retained original binary and one on current, with lower current means for three of the four selected cases. PostgreSQL observation finds I/O wait in affected-history lookup and a 112 MB `stream_events` relation. Unrelated host builds/tests also overlapped part of the full normal run. Preserve the raw results under `regression-20261012`, classify them separately from fresh-database catalog comparisons, and do not refresh the historical CSV or attribute these failures to the guarded runner without paired evidence.

2026-10-12 — Final review strengthens two runtime proofs: an accepted promotion-first call must make the fresh call reuse the same note, with exactly one creation event; a deliberately faulting inline handler proves both refusal and unavailable-second-group admission execute no delivery. The full suite passes 754 examples. Ordinary refactor pairs launch both binaries in fresh RTS processes, avoiding different garbage-collection histories from a long-lived parent versus freshly launched controls; setup and warm-up remain outside measurement.


Documentation review found guidance recommending inline delivery for immediate readers. Existing `WaitForPosition` supports that need after commit, so the baseline guides, ADR-26, and agent-facing runtime patterns now recommend async query models. Runtime behavior and performance remain unmeasured.

Source validation at Keiro `36af358b1188de16fbe40473bba427c47190b6dd` found that `typedProjectionRebuildGroups` includes every definition in the supplied `ProjectionSet`, including async-only definitions. Separate groups alone do not give the promised independent availability. `projectionSetBelongs` accepts a subset of the catalog's projection IDs for a source; retain a separate typed command set containing every required inline owner and no async-only owners. Do not change the existing runner's group selection to hide this fixture error.

The reviewed dependency sources were `mori://shinzui/kiroku/packages/kiroku-store` at project commit `ff113e96bbdb95f3bacd5ac3eb5082cf284ff752` and `mori://hasql/hasql/packages/hasql-transaction` at repository commit `8a1ea3525b9208cd92c1ac592443a75140b8da11`. Kiroku's append SQL updates stream ID zero and its runner requests `ReadCommitted`; Hasql retries both SQLSTATE `40001` and `40P01` and preserves the body's return value after condemnation. This confirms the proposed serialization mechanism at source level, but also means a callback that calls `Tx.condemn` and returns success can defeat truthful acceptance. Supported guards must use their `Either` result for refusal and leave transaction control to the runner. These corpus revisions are inspected evidence, not a claim about the eventual Cabal-resolved build.

The catalog lock query obtains a group row and joins generation metadata in one SQL statement. Under `ReadCommitted`, a row returned after a lock wait can be newer than other data read by that statement. Writer-first promotion tests alone therefore do not cover admission after waiting for promotion. Require the opposite ordering and verify either a coherent binding or an existing typed refusal before any guard runs; never assume the entire joined statement automatically gets a fresh snapshot after a wait.

Review checks: the public re-export check and its nine policy tests pass. The two downstream Rei artifact URIs currently fail `mori path` resolution; retain their canonical identities and recheck registry coverage during adoption. No runtime race or benchmark was executed for this plan update.


## Decision Log

2026-10-12 — Keep the plan's workload and fixed numeric budgets as the acceptance contract. Kenshou's uncalibrated, unrelated quick profiles cannot replace the 190 required comparisons. Prepare the exact original-library overlay and candidate in the project Nix shell on the authorized Linux builder; record host activity and stop any measurement if other builds/tests compete. A leased cell requires an explicitly supplied durable external database, supported by `withMigratedBenchmarkSuite` through `KEIRO_GUARDED_CATALOG_PG_ADMIN` (libpq keyword connection string). The fixture creates and drops only its uniquely named template and cloned databases.

2026-10-12 — Stop the resumed measurement when competing host work appears instead of collecting another known-contended five-pair result. Retain every complete sample, host observation, and the explicit interruption in the log. Do not interrupt other contributors' jobs or treat normal desktop/VM activity as an isolation guarantee. The acceptance blocker is still measurement infrastructure, not evidence justifying speculative production edits or a budget revision.


2026-10-11 — Owner discussion selected a small opt-in synchronous catalog runner. Rei owns identity lookup and duplicate-to-reuse policy; Keiro owns transaction rollback, catalog fences, and delivery. Existing runners retain their signatures, outcomes, and SQL/lock counts.

2026-10-11 — Resolve all catalog fences and serving bindings before invoking the guard. The earlier exploratory prototype invoked the guard first, allowing duplicate refusal to mask an unavailable catalog and permitting a lookup without lifecycle protection. The prototype is evidence to inspect, not a patch to cherry-pick.

2026-10-11 — Initially rely on the documented Kiroku `$all` append serialization and `ReadCommitted` statement snapshots. Every live writer affecting the invariant must participate in that protocol, and catalog reconstruction must obey the catalog fences. The API does not claim to protect arbitrary external SQL or lagging subscription projections.

2026-10-11 — Supply an opaque guard context exposing the already resolved public `ProjectionWriteBinding` values. A bare transaction closure is insufficient guidance for a schema-changing serving revision. The context is available only after validation and introduces no second metadata lookup.

2026-10-11 — Measure overhead against explicit initial budgets derived from the nearby projection benchmark's throughput/p95 convention, with a separately stated p99 budget below. These are engineering acceptance targets, not measured results or a production service-level agreement. Do not silently relax them to make the implementation pass.

2026-10-11 — Moving the check before append, adding a new pre-append identity reservation protocol, extending the DSL, changing asynchronous delivery, or changing Kiroku's global append architecture is deferred. Any such expansion requires a recorded design revision after evidence shows why this scope is insufficient.

2026-10-11 — Owner discussion selected async query models as the default. The Rei-shaped example keeps only a synchronous identity-to-winning-note index; content/tags, display joins, search, and reporting are asynchronous. This index is event-derived command authority, not the deferred pre-append reservation protocol. Separate catalog owners and rebuild groups where dependencies permit, and prove behavior while the rich-view worker is stopped. Reader freshness uses a bounded post-commit wait, never more inline work for response convenience.

2026-10-11 — Source review keeps the existing runtime API and group-selection behavior intact. The example and benchmarks pass an inline-only command set while registering both synchronous and asynchronous owners in the full catalog. A mixed set intentionally fences both groups and is tested as a negative control.

2026-10-11 — Treat the callback as trusted, retryable transaction-local code. Require bounded indexed reads for the example, forbid callback transaction control and nontransactional effects, and distinguish driver retries from OCC retries. Add promotion-first admission and multi-group fence tests before claiming correctness.

2026-10-11 — Retain the numeric performance budgets, but make the workload, per-cohort latency, rollback storage costs, and offered-load comparison reproducible. A short closed-loop benchmark alone cannot establish ordinary-writer latency under sustained duplicate traffic. These are implementation acceptance refinements; ADRs are updated when the proposed runtime contract is implemented and verified.


## Outcomes & Retrospective

2026-10-12 remote preparation checkpoint: previous API/correctness work remains committed. Benchmark durability and executable portability are corrected; six reporting controls pass. Source preparation is underway on the existing Linux builder, with no measured remote acceptance yet. Historical non-durable samples remain retained and are not acceptance denominators. The revised full regression passes 755 examples with zero failures in 168.34 seconds. The comparison wrapper checks shared-source/executable hashes, compiler and dependency inventories, retains host observations every five seconds, and interrupts only its owned benchmark if another build/test appears. That observation is not a cloud cell lease.

2026-10-12 continuation checkpoint: the benchmark builds in the Nix shell and the evidence-reporting tests pass. The resumed run is deliberately interrupted after external jobs begin; its complete samples pass event/cardinality accounting but supply no acceptance verdict. Reporting now identifies incomplete matrices explicitly and fails `--require-complete` until all required evidence and budget results exist. M1 paired acceptance, M4, and the performance portion of M5 remain open pending a suitable measurement runner. Production code, dependency versions, and numeric budgets are unchanged in this continuation.

2026-10-12 implementation checkpoint: the additive runner compiles; the final full suite passes 754 examples, including 35 guarded examples. The example covers snapshots, both owner rebuilds, fresh OCC/driver outcomes, versioned promotion in both orders, and post-commit view errors. The ordinary-path source audit records unchanged SQL/explicit locks. Strict ADR, user documentation, improvement request, and public export checks and the projection benchmark guard pass. The historical command guard also fails on original source; retained raw evidence separates that drift from this feature. Forty paused-worker latency samples remain provenance. Enhanced alternating controls and M4 throughput/queueing/sustained acceptance remain outstanding. The API and fixture are not yet a performance-ready handoff.


At the original planning checkpoint, guidance distinguished the atomic identity index from the asynchronous rich-note view, including independent fencing and committed-but-pending response requirements. Source review corrected the async-group selection gap and made callback safety, promotion admission, driver retries, and sustained duplicate costs explicit. All runtime milestones were pending at that checkpoint; the later implementation checkpoints above describe the delivered feature and its still-open performance acceptance.


## Context and Orientation


The original inspected Keiro baseline was `2a38ee169d165c571a142cb47d08bab1e7ad7652`; this validation pass inspected `36af358b1188de16fbe40473bba427c47190b6dd`. Reconfirm paths and dependency behavior against the checkout being implemented. An aggregate stream is one entity's ordered event history. Optimistic concurrency control (OCC) compares the stream version expected by the caller with the version at append and retries a conflicting command from hydration, which reconstructs entity state from its history. Different note IDs name different streams, so OCC alone cannot establish a shared relational identity.

`keiro/src/Keiro/Command.hs` defines `SqlTransactionDecision`, `DomainSqlCommandOutcome`, `runDomainCommandWithSqlEventsControlled`, and `domainSqlCommandAttempts`. Accepted batches enter a transaction, call `appendToStreamTx`, then invoke a SQL callback. `RollbackSqlTransaction` condemns the entire transaction while retaining a typed value. Snapshot verification/advancement attributable to the accepted append happens only after commit. Selected domain rejection and no-op take the silent path and invoke no callback. `retryOrFail` bounds OCC attempts using `RunCommandOptions.retryLimit`; that setting does not bound Hasql's separate transaction retry loop.

`keiro/src/Keiro/Projection.hs` contains the public domain catalog runner and private `applyCatalogProjectionsTx`. The private helper both locks groups and delivers events. `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` defines `lockProjectionGroupsTx`, `ProjectionWriteFence`, and `ProjectionWriteBinding`. Distinct group rows are locked `FOR SHARE` in sorted order. These shared locks prevent lifecycle changes while permitting other ordinary writers; they are not the identity serialization mechanism. A fence is the typed refusal to write while catalog lifecycle or serving bindings are unavailable. Keep the exact existing distinctions, including the current handling of failed/offline groups, rather than inventing a new generic fence error.

`keiro/src/Keiro/Projection/Catalog.hs` exports `PhysicalTargets`, `QualifiedTable`, `resolvePhysicalTarget`, and revision-specific live handlers. A serving revision is the code/schema version currently receiving live writes. Its physical targets are the actual tables selected for that revision. An online rebuild populates separate candidate tables while the old revision serves; promotion atomically selects the new generation. The guard must read the protected serving generation, and accepted events must reach the same bindings. A guard is not re-run during event replay: the committed creation event must carry enough identity and payload to reconstruct the note.

The dependency is `mori://shinzui/kiroku/packages/kiroku-store`, bounded by `^>=0.11.0.0` in the implementation checkout's `keiro/keiro.cabal` (the earlier source inspection used `^>=0.10.0.0`). Its `Kiroku.Store.Transaction.appendToStreamTx` contract documents an update of the global `$all` row and retention of that row lock through commit or rollback. Its runner uses `ReadCommitted`, under which each subsequent SQL statement sees commits preceding that statement. Thus a loser waiting on append serialization can query the committed winner afterwards. This proof depends on a separate guard statement after the append, the same database/store schema, synchronous identity updates, and all relevant live writers participating. Reads performed before append or in the same append statement's old snapshot do not inherit the proof. Existing catalog maintenance supplies its separate lifecycle protection. Locate dependency code with Mori, never by traversing `/nix/store`.

The consumer fixture has a synchronous `state_note_identity` target mapping `(anchor type, anchor ID, property definition ID, state ID)` to the winning note ID, and a separate asynchronous rich-note target. Store only additional metadata demonstrably needed for the invariant or a retained winning receipt; do not duplicate content/tags or display joins in the synchronous index. Use separate catalog owners and groups so rich-view unavailability need not fence ensure commands, provided declared dependencies allow independent lifecycles. The identity row refers to the aggregate identity, not a foreign key to an asynchronous row that may not exist yet. Keep real dependencies explicit and do not claim independence for tables that require a shared lifecycle. Fencing the identity group must fail ensure closed. For this fixture, all four identity columns are `NOT NULL` and the unique key covers exactly those four canonical values; do not add an archive filter to the guard or index. Normalize values before both lookup and event creation so equality cannot differ between guard, writer, and replay. Archive retains the mapping. The fixture forbids deletion or re-anchoring of an indexed note and requires legacy duplicates to be reconciled before index activation; downstream policy changes require their own migration and invariant proof. Every creation path must both participate in append serialization and enforce the invariant, not merely acquire the same lock. A bypass path that only hits the unique constraint remains an operational error, never typed reuse.

The consumer requirement belongs to `mori://shinzui/rei/plans/249-expose-categories-and-custom-properties-with-shared-typed-assignment-semantics`, coordinated by `mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`. This plan delivers a runnable Rei-shaped example inside Keiro and a public adoption recipe. Actual Rei package changes and deployment are separate downstream work. The old unapproved local prototype is commit `3f9aba4e`; it checks the guard before the catalog fence and lacks the required full evidence. Its historical plan number is not this plan's identity.

Relevant architecture context is [ADR-29](../adr/0029-typed-domain-decisions-are-successful-additive-command-outcomes.md), which keeps selected domain decisions separate from command faults and forbids fabricated acceptance on rollback; [ADR-26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md), which gives the catalog one projection owner and makes application SQL an explicitly unchecked boundary; and [ADR-34](../adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md), which requires live delivery to use persisted serving revisions and physical generations under a group lock. The extension must preserve these decisions. The callback type cannot statically prove a query is bounded, that arbitrary SQL obeys ownership, or that it leaves transaction control untouched. This API is a trusted application-SQL boundary, not a sandbox.

`keiro/test/Main.hs` has existing domain command/catalog rollback and retry fixtures. `keiro/test/VersionedRebuildSpec.hs` supplies versioned lifecycle patterns. Add focused cases in `keiro/test/GuardedCatalogSpec.hs` and a reusable public-API note example in `keiro/test/GuardedCatalogExample.hs`, wiring both into `keiro/keiro.cabal` and `Main.hs`. `keiro-test-support/src/Keiro/Test/Postgres.hs` starts ephemeral PostgreSQL, migrates once, and clones a database per test. Its `withFreshStores2` opens two different databases and must not be used for this race. Use `withFreshDatabase` to get one connection string and open two independent resource-aware stores against it, factoring a same-database helper if needed.

The full validated catalog registers both note owners, but the `ProjectionSet` passed to the command runner contains only the identity owner's inline definition (and any other inline owners genuinely required for that command). Build it from those same typed definitions, preserving their source and IDs. `typedProjectionRebuildGroups` does not filter on handler kind. Passing a set that also contains the rich-view owner would lock and fence its group even though delivery invokes only inline handlers. Keep that broad-set behavior unchanged and prove the example uses the narrow set through a rich-group fence test.

Existing measurements live in `keiro/bench/Main.hs` and `keiro/bench/ReadModelBench.hs`. The latter already uses warmed alternating samples because sequential growing-store measurements can be misleading. Add `keiro/bench/GuardedCatalogBench.hs` with its own opt-in evidence mode, keeping benchmark instrumentation out of production code.


## Plan of Work


### Milestone 1: Establish the transaction contract and ordinary baseline


Before production edits, verify the installed dependency source through Mori and record the actual Kiroku, Hasql transaction, PostgreSQL, compiler, and source revisions used. Read `appendToStreamTx`, its SQL implementation, and the transaction interpreter to confirm the `$all` update and snapshot/retry behavior. If a dependency bound change becomes necessary, verify the current registry release and upstream tag first; the local corpus alone is not version authority. No bound change is expected. Resolve the actual built dependency versions from Cabal's plan metadata and compare their source with the reviewed corpus before treating source inspection as executable evidence. Do not follow build-output paths into `/nix/store`. Record the lock order (the sequence in which transactions acquire resources) for command append, catalog preparation/promotion, and targeted stream repair: the command reaches its catalog locks only after append, while `keiro/src/Keiro/ReadModel/Rebuild/Stream.hs` takes its history guard before the repair group lock. Guard SQL must not acquire other stream or group locks, append recursively, or introduce an opposite order.

Build the same-database test helper and an ordinary catalog benchmark fixture with an indexed minimal identity table with a fixed initial cardinality per paired run, distinct note streams, realistic content/tags in the events and separate async query target, and both one-event and multi-event batches. Keep async-worker activity identical across benchmark pairs and record it; include paused and active worker conditions to distinguish append-lock cost from shared database contention. Record baseline ordinary runner SQL/lock counts and warmed throughput/p95/p99 before refactoring. The benchmark module and cabal registration can land before the guarded API so its ordinary mode runs on this baseline. Save raw evidence under `keiro/bench/results/guarded-catalog/` with machine/tool versions, workload inputs, and commit IDs. Retain the project-built ordinary benchmark executable and its build configuration before production edits, so M4 can run the old and new binaries alternately on the same machine and equivalent fresh databases. Historical baseline files alone cannot supply contemporaneous paired ratios. Locate the executable with `cabal list-bin keiro:bench:keiro-bench` from the development shell; retain it only from the project build directory, without reading `/nix/store`. Verify two overlapping transactions have distinct PostgreSQL backend PIDs but the same database and schema. Run `keiro-test` and the ordinary benchmark mode described below. Acceptance is a reproducible baseline and a connection fixture that demonstrably tests contention in one store, without a runtime behavior change.


### Milestone 2: Implement the additive guarded runner


In `keiro/src/Keiro/Projection.hs`, extract the existing event delivery loop into a private helper that accepts the bindings already obtained by `lockProjectionGroupsTx`. Keep `applyCatalogProjectionsTx` as the current lock/validate/apply composition for existing callers. The new runner uses the same validation and delivery helper, but invokes the consumer guard between them. It must acquire each existing group lock only once and retain stable group ordering.

Add the result and callback context described in Interfaces and Dependencies. Reuse `runDomainCommandWithSqlEventsControlled`; do not implement a second hydrate/decide/append/OCC loop. Preserve early projection-set/catalog mismatch handling. Map silent domain outcomes and all existing catalog outcomes through the new wrapper. A guard refusal carries no `CommandResult` or `DomainAccepted` value. An invalid catalog returns its existing catalog outcome before the guard runs. A successful guard applies the complete ordered batch using exactly the bindings handed to the guard. Preserve existing delivery order: sorted groups, then the existing handler order within each group, then event order within each handler. Do not silently transpose this to event-major execution when extracting the helper. Test two groups, multiple handlers, and a multi-event batch with an order trace.

Preserve the old runners' allocation paths where practical; do not route every existing caller through new result wrappers solely to avoid a few mapping lines. Share the correctness-sensitive delivery implementation, not a second copy of revision dispatch. The guard context is callback-scoped information, not a transferable lock lease: document that retained bindings have no authority in another transaction.

Add focused rollback, acceptance, and silent-decision tests. Include a guard that writes a transactional marker and refuses; neither marker nor event batch nor projections may remain. Inject a SQL failure and verify it remains an operational fault. Document that guards must not call `Tx.condemn`, issue `BEGIN`/`COMMIT`/`ROLLBACK`, alter isolation, or manage savepoints; return `Left refusal` instead. Transaction-local marker writes are allowed in rollback tests, but production identity guards use reads only. Sequences, session advisory locks, external effects through SQL functions, and other effects that survive rollback are outside the contract. Never promise that arbitrary SQL is undone. The guard sees the tentative event append in its own transaction; it must not mistake that event for independently committed identity authority. Use existing rollback telemetry: do not label a refused append accepted or rejected by the pure domain, and never render the refusal payload into logs, span attributes, or metric dimensions. Build `keiro:lib:keiro` and run the focused Hspec group. Acceptance is a usable public API with the original runner tests still passing and no added SQL on the old path.


### Milestone 3: Prove the identity and catalog lifecycle behavior


Implement `ensureStateNoteExample` in `keiro/test/GuardedCatalogExample.hs` using only public APIs. Use the composite `(anchor type, anchor ID, property definition ID, state ID)` identity and separate candidate stream IDs. Supply the inline-only command set described above while registering both owners in the full catalog. Query only the indexed synchronous identity target from the guard, retaining mappings for archived notes; return `ExistingNote noteId` as the refusal payload and map it to `(noteId, False)`. Accepted creation returns `(candidateId, True)`. Never convert a general SQL/codec/store error to reuse. Keep the unique index. Creation facts contain the winning identity/content/tags/provenance so normal replay reconstructs the minimal index and rich query view through their respective owners without invoking the command guard. Implement the fixture policy above for deletion/re-anchoring, non-null canonical keys, and legacy duplicate reconciliation; document which downstream choices remain application-owned.

Race two independent resource stores connected to the same test database, using different candidate IDs and payloads for one identity. Synchronize starts outside the SQL callback. For deterministic lock-wait evidence, use a third observer/controller connection and a bounded test-only SQL gate or PostgreSQL lock observation; do not insert arbitrary IO into a transaction callback or rely only on sleeps. Give every worker and observer a timeout and release gates in cleanup. With the rich-view worker paused, observe one committed creation, one identity-index row, no rich-note row yet, identical returned IDs, and exactly one changed result. Start/drain the worker and then observe exactly one rich note with the winner's original content, tags, and provenance. Reverse which caller starts first and test winner rollback so a waiting caller can become the winner. Repeat on an archived note and inspect content, tags, and provenance, not only row counts.

For refusals, inspect source stream events, `$all` links, callback markers, inline projection rows, snapshots, and fixture outbox/reactor markers attributable to the losing batch. No losing effects may commit and projection handlers must not execute. Exercise multi-event acceptance, OCC retry followed by a fresh guard result, retry followed by a silent decision, exhaustion, encode failure, unmatched command, and genuine query failure. An OCC-conflicting append never reaches the guard; prove a successful retry performs its first guard read against current state. Separately inject a one-time SQLSTATE `40001` after a guard evaluation using test-only instrumentation that survives rollback, then prove Hasql reruns the body, resolves bindings again, and obtains a fresh guard result. Use a third transaction to change the identity between attempts under the same supported append protocol, with bounded SQL gates controlling the order. Keep nontransactional instrumentation confined to tests. Cover `40P01` retry behavior or explicitly verify its identical driver dispatch from the resolved source; do not rely on a recurring deadlock that the driver's unbounded loop could conceal. Use backend-local instrumentation or SQL observer evidence where callback invocation itself must be proved; rollback of a marker alone cannot prove the callback never ran. Preserve Hasql transaction retry semantics and document that `retryLimit` applies to the outer OCC loop only.

Test a guard designed to refuse against missing, offline rebuilding, failed, mismatched, unknown-serving-revision, and invalid-serving-binding cases: the catalog outcome wins and the guard does not execute. Extend versioned fixtures to hold a guarded writer while another connection attempts promotion; after release, either the writer completes against the protected old revision before promotion or is fenced/re-evaluated through a new call. A later successful call resolves the promoted revision. The guard and handler must observe the same physical generation and revision, never the candidate or retired table. Also start promotion first, hold its exclusive group lock, and begin a writer so its fence statement waits across the metadata change. On release, require a coherent newly serving binding or an existing typed unavailable/invalid-binding outcome with no guard execution, followed by a fresh call that succeeds. Include a same-revision new-generation promotion as well as a schema-changing revision. A false-positive valid stale binding blocks completion: fix it in the shared resolver and explicitly revisit the old-path SQL-count constraint if correctness needs another statement. Do not work around it only in the new guard. Test a writable first group followed by an unavailable second group, proving no guard or handler ran before all required fences passed. Exercise a concurrent targeted repair when the fixture declares stream-scoped repair, and fail on deadlock/retry churn rather than counting eventual success alone. Rebuild the identity and rich-note targets through their separate catalog groups and verify retained identity and payload. Fence the rich-view group alone and prove ensure/reuse still works; fence the identity group and prove it fails closed before guard execution.

Use the focused test command below and the full `keiro-test` suite. Acceptance is the complete behavior matrix with independent-connection evidence, not merely sequential duplicate calls or one successful race.


Also demonstrate bounded read-your-write after a confirmed accepted command: retain its `CommandResult.globalPosition`, invoke `runQueryWithFreshness` with `WaitForPosition` outside the append transaction, and distinguish ready, committed-but-pending on timeout, and view-unavailable configuration/lifecycle errors. Resume a paused worker and retry the query using the same receipt without reissuing creation. No-op/refusal supplies no new committed position; duplicate reuse returns the canonical identity, using an independently retained winner receipt only when one exists. Never wait on the rolled-back candidate's position. Preserve store/transport failures separately from read-model errors and command commit uncertainty.

### Milestone 4: Measure the global append cost


Extend `GuardedCatalogBench.hs` with unguarded, empty-success-guard, indexed-miss, indexed-hit/refusal, and mixed traffic modes. Measure one and eight concurrent connections. Persist a workload manifest before candidate measurement: use initial identity cardinalities of 10,000 and 1,000,000, batch sizes of one and four events, a fixed 1 KiB creation payload with four tags, deterministic key/request seeds, and the same pool sizing and compiler/runtime options in each pair. For shared-key traffic, explicitly schedule creators and subsequent duplicate attempts so measured duplicate rates are known; an all-unique control uses a fresh identity for each corresponding attempt. Include warm-up rows in the recorded initial sizes or reset after warm-up. Successful runs grow the tables; record ending cardinalities instead of calling them fixed-size. Use durable PostgreSQL with `fsync`, `synchronous_commit`, `full_page_writes`, and `autovacuum` all enabled. The benchmark must check these settings and retain them in each raw sample; non-durable or unverified historical samples cannot establish acceptance. Seed and analyze the identity index before timing, warm each case, then collect at least five alternating paired runs of 10,000 completed attempts per case with equivalent initial database size and bounded setup outside timing. Count attempts, accepted batches, refused batches, and committed events separately: duplicate reuse has fewer committed events and must not masquerade as increased append throughput. Fail on unexpected outcomes or timeouts rather than omitting samples. Measure end-to-end call latency from submission through pool wait, hydration, all retries, commit/rollback, and result delivery. Report ordinary, guarded-accepted, and guarded-refused cohorts separately, with p50/p95/p99 and maximum, and record actual driver and OCC attempt counts in diagnostic runs. Keep the 80/20 mix in a common deterministic request schedule; assigning one permanently slower worker to guards can silently change the completed traffic mix.

The required mixed workload is 80% ordinary commands and 20% guarded ensure attempts. Run guard duplicate rates of 0%, 50%, and 100%, with both repeated shared identities and distributed identities. Compare to the same concurrency and 80/20 command/batch mix in an unguarded all-unique control, acknowledging the different commit counts. This control measures the added cost of offering the stronger operation, not semantic equivalence of duplicate handling. Also compare unchanged ordinary callers before/after the refactor and compare empty-success guards with the ordinary API on identical all-unique data.

Before collecting candidate results, persist these initial budgets in the harness configuration and report: the ordinary-only refactor must retain at least 95% of baseline attempt throughput and keep p95/p99 within 1.10 times baseline; empty-success guards and indexed all-unique guards must retain at least 90% throughput and keep p95 within 1.25 times and p99 within 1.50 times the comparable ordinary control. In each required mixed case, overall attempt throughput must retain at least 90% of its control, and the ordinary cohort's p95/p99 must stay within 1.25/1.50 times its control cohort. Judge the median of paired run ratios and report every run, spread, sample count, and absolute latency as well. Repeat a noisy comparison with an explained cause rather than selecting favorable runs. These targets are initial engineering budgets; a failure prevents a performance-ready conclusion until design changes or an explicit owner-reviewed budget revision.

Use the retained M1 executable for ordinary-before/after pairs; use the current ordinary API as control for guarded/unguarded pairs. The one/eight-connection runs above are closed-loop: each worker submits its next command only after the previous one completes. Add a fixed-arrival-rate mixed run to expose queueing they can hide. Before candidate measurement, measure the comparable ordinary control's stable capacity and fix offered rates at 50% and 80% of that rate for both control and candidate, with eight connections. For each duplicate rate and both worker states, collect at least 10,000 scheduled attempts per paired run with five alternating pairs. Measure latency from scheduled arrival, include client queueing, and count unfinished/time-limited attempts as failures. Require the ordinary cohort's p95/p99 ratios to meet the same 1.25/1.50 budgets and all scheduled work to finish within the declared harness deadline; do not substitute closed-loop latency for this result.

Add paired sustained duplicate-heavy/control diagnostics of at least ten minutes each after warm-up, with ordinary writers sharing the store, 1,000,000 initial identities, four-event candidate batches, eight connections, and the same fixed offered rate (80% of control capacity). Use 100% guarded duplicates in the 20% ensure cohort, distributed over preseeded identities, with the rich worker active; repeat with it paused to separate contention from expected backlog accumulation. Rolled-back inserts/updates still produce WAL (the database recovery log) and leave dead row versions for vacuum to reclaim; resetting the database after every short run hides this cost. Record WAL bytes per completed attempt, relation/index sizes, dead-row and autovacuum statistics, and ordinary latency by minute, preserving normal vacuum behavior. Record the paused/active async worker state and its backlog. Unexplained continuing backlog or storage growth, retry churn, or ordinary-latency budget failure blocks a performance-ready conclusion pending investigation; this run does not establish a universal storage bound. Use the supported PostgreSQL version's statistics and report any metric that is unavailable rather than inventing a proxy.

Use a separate diagnostic run to collect PostgreSQL lock-wait evidence and guard/post-append duration with test-only instrumentation. Report what is directly measured versus an upper bound or proxy for `$all` hold time. Do not put extra timing statements into the measured production path. Verify that the identity query uses an index at representative cardinality with `EXPLAIN (ANALYZE, BUFFERS)` outside the timing loop. Include a deliberately slow test guard to demonstrate that the harness detects ordinary-writer degradation; this diagnostic is not a supported workload or a passing performance sample.

If the post-append design fails, first eliminate extra SQL, incorrect query plans, or redundant fence work. Do not silently move a SELECT before append. A pre-append alternative requires a revised plan with a shared identity lock/reservation protocol, participation by every writer, and deadlock-safe ordering relative to append and catalog locks. Acceptance is archived raw measurements and a computed pass/fail report, with no claim that correctness tests establish performance.

Aggregate the chosen run with `scripts/summarize-guarded-catalog-evidence.py` and use `--require-complete` for the final evidence gate. The inventory requires 190 reports: 16 ordinary refactor, 32 successful-guard, 32 pure-hit cost, 96 mixed, 12 fixed-arrival, and two sustained comparisons. It verifies observed durability/vacuum settings, five pairs and retained canonical raw samples for each paired report and the raw/storage files for sustained reports, and reports the median and range for each paired metric. Exit 2 means missing matrix evidence or a failed budget. A complete passing matrix still requires the storage/backlog interpretation described above; the tool labels that state `storage-review-required`, not a completed performance handoff.


### Milestone 5: Document the supported boundary and finish validation


Add `docs/guides/guarded-catalog-commands.md` following the existing guide frontmatter/profile conventions. Explain the transaction order, result matching, context-based physical table resolution, archived reuse, synchronous authority, writer participation, replay behavior, lock costs, and separate OCC/driver retries, callback transaction-control restrictions, the explicit inline-only command set, canonical non-null identity keys, and the cost of sustained rollbacks. Include the compiled Rei-shaped example with separate minimal identity/rich-view owners, archive and rebuild behavior, post-commit waits, and committed-but-pending responses. Link the async-first guidance and explain that richer synchronous query maintenance is not required by this API. Identify any additional downstream adoption work through its canonical Mori plan URI. Package publication and actual Rei dependency updates remain separate work.

Update the unreleased section of `keiro/CHANGELOG.md`, export the new API consistently with `keiro/src/Keiro.hs`, and update ADR-29 for transactional refusal versus pure domain decisions and ADR-26/ADR-34 for guarded serving-target access and the unchecked SQL boundary. Keep their existing stable `docId` values, update meaningful revision timestamps, and add bundle log entries. Do not claim arbitrary callbacks are automatically safe or bounded. Update IR-53 and this plan with real test/benchmark evidence and remaining downstream obligations; do not mark downstream adoption complete based on the local example.

Run the full affected test suite, normal command/projection benchmark guards, public re-export checks, and strict documentation validation. Review the final diff for unrelated changes and dependency/version bumps. Distill the global-lock and fence-order lessons into the ADRs before marking this implementation plan complete. Acceptance is the documented, tested, measured additive feature and a clear release/adoption handoff, not publication.


## Concrete Steps


For remote preparation, transfer a Git bundle containing the committed candidate into a fresh checkout on `nix-builder-x86` in project `tan-nb-exp`, zone `us-west1-a`, using the IAP transport from `mori://shinzui/load-testing-infra`, project-relative path `scripts/iap-ssh.sh` (artifact-level URI pending). Use the existing `builder` Unix account for PostgreSQL compatibility. Build and freeze the candidate before building the original-library overlay; both run in the project Nix shell. The wrapper rejects mismatched dependencies, compiler, source hashes or executable hashes, and records its direct host-observation scope without claiming a cell lease. Run these commands in the clean candidate checkout with unused worktree/output paths:

```bash
nix develop -c cabal build keiro:bench:keiro-bench
nix develop -c cabal freeze --enable-benchmarks
nix develop -c python3 scripts/build-guarded-catalog-baseline.py --worktree /home/builder/keiro-306-original --output /home/builder/keiro-306-baseline
nix develop -c python3 scripts/run-guarded-catalog-comparison.py --baseline /home/builder/keiro-306-baseline --output /home/builder/keiro-306-comparison
```

Keep the SSH transport connected while the command runs so the builder's normal idle shutdown does not interrupt it. Do not change global cloud configuration, stop other work, or run on a contaminated host. If the builder's existing idle watchdog stops active Cabal preparation, first arm a bounded transient systemd timer to restore `idle-shutdown.timer`, then temporarily stop that idle timer. Restore its previously active state on every terminal path, and cancel only the owned restoration timer after restoration. The 2026-10-12 preparation uses `keiro-306-restore-idle.timer` with an eight-hour backstop; it changes no installed watchdog code or cell idle policy. Retain the wrapper's `candidate-environment.json`, `host-activity.jsonl`, `comparison.log`, `execution.json`, and aggregate/raw evidence. A preflight refusal retains host observations and runs no comparison. A complete passing report still needs the sustained storage/backlog review.

Run commands from the Keiro repository root. Use the repository's Nix development environment for Cabal and PostgreSQL tools; tests start isolated ephemeral databases and do not require a running production database. Use an already active development shell instead of nesting `nix develop` when appropriate. No command should search `/nix/store` or the filesystem root.

```bash
mori registry list
mori registry search kiroku-store
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori path mori://shinzui/kiroku/packages/kiroku-store
mori registry search hasql-transaction
mori registry show hasql/hasql --full
mori registry docs hasql/hasql
```

Read the located dependency modules directly. Before choosing any new dependency bounds, check the package's authoritative Hackage preferred versions and upstream release tags; record the exact results here. No dependency selection is made by the discovery commands.

```bash
nix develop -c cabal build keiro:lib:keiro keiro:test:keiro-test keiro:bench:keiro-bench
nix develop -c cabal test keiro-test --test-show-details=direct --test-options='--match "guarded catalog commands"'
nix develop -c cabal test keiro-test --test-show-details=direct
```

The first focused command is meaningful after M2 registers that describe group; zero selected examples is a failure of this plan's validation. Expected final output includes executed guarded examples and zero failures. The full suite must pass as well.

Implement the following benchmark environment switches in M1/M4. They are proposed harness interfaces, not existing commands today. `ordinary` exits after baseline capture; `compare` runs candidate/control pairs and exits nonzero on a budget failure; `diagnostic` records lock behavior without using its instrumented samples for acceptance. Use unique run output directories to retain evidence.

```bash
nix develop -c python3 scripts/build-guarded-catalog-baseline.py --worktree /tmp/keiro-306-original --output /tmp/keiro-306-enhanced-baseline-v2
cp /tmp/keiro-306-enhanced-baseline-v2/enhanced-environment.json keiro/bench/results/guarded-catalog/baseline/enhanced-environment.json
nix develop -c env KEIRO_GUARDED_CATALOG_EVIDENCE=ordinary KEIRO_GUARDED_CATALOG_OUTPUT=bench/results/guarded-catalog/baseline cabal bench keiro-bench --benchmark-options='+RTS -N2 -RTS'
nix develop -c env KEIRO_GUARDED_CATALOG_EVIDENCE=compare KEIRO_GUARDED_CATALOG_BASELINE=bench/results/guarded-catalog/baseline KEIRO_GUARDED_CATALOG_OUTPUT=bench/results/guarded-catalog/candidate cabal bench keiro-bench --benchmark-options='+RTS -N2 -RTS'
nix develop -c env KEIRO_GUARDED_CATALOG_EVIDENCE=diagnostic KEIRO_GUARDED_CATALOG_OUTPUT=bench/results/guarded-catalog/diagnostic cabal bench keiro-bench --benchmark-options='+RTS -N2 -RTS'
nix develop -c python3 scripts/summarize-guarded-catalog-evidence.py keiro/bench/results/guarded-catalog/candidate-idle-20261012 --require-complete
```

The summary command above demonstrates the retained interrupted run: expect `performanceAcceptance: incomplete` and exit 2. For final acceptance, replace that directory with the chosen complete run directory.

Dispatch evidence modes in `keiro/bench/Main.hs` before unrelated fixture setup and `defaultMain`, so `ordinary`, `compare`, and `diagnostic` run only their requested harness and exit. Add `GuardedCatalogBench` to the benchmark stanza's `other-modules`; record all workload choices in its output manifest. Cabal runs the benchmark in the `keiro` package directory, so those output paths resolve beneath `keiro/bench/results/guarded-catalog`. Choose unused output directories when repeating any command; the harness and baseline builder refuse to overwrite evidence. The enhanced builder overlays only harness/test-support files on the recorded original revision, leaves production sources untouched, records resolved dependencies/compiler/runtime options, and retains the project-built binary outside the repository. The harness reads that manifest, verifies executable/shared-source hashes, reruns the retained ordinary executable between candidate samples, and emits reports plus gzip-compressed raw JSON samples. Historical latency-only samples remain provenance, not the denominator for alternating measurements. Record the exact accepted report here during implementation; do not paste hypothetical numbers.

```bash
nix develop -c cabal bench keiro-bench --benchmark-options='-p command --time-mode wall --hide-progress --baseline bench/baseline-command.csv --fail-if-slower 25'
nix develop -c env KEIRO_READ_MODEL_P95=1 cabal bench keiro-bench --benchmark-options='-p projection --time-mode wall --hide-progress --timeout 1 --baseline bench/baseline-projection.csv --fail-if-slower 25'
just keiro-reexports
just adr-validate
just user-documentation-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
git diff --check
```

Use `okf log add` with the relevant bundle whenever a concept timestamp advances. Documentation validation must distinguish pre-existing corpus issues from introduced errors; record any baseline failure and do not silently fix unrelated documents. Implementation commits use Conventional Commits on the current branch, with `ExecPlan: docs/plans/306-support-atomic-relational-preconditions-for-synchronous-catalog-commands.md` and `Intention: intention_01m4pbzn0feettj188pac22p2e` trailers.


## Validation and Acceptance


For one identity, race candidates A and B with different content and tags. The observable successful result set is exactly `(winner, True)` and `(winner, False)`, regardless of which candidate wins. Read both aggregate streams, the global event links, and all fixture projection/effect tables. With the async worker paused, exactly one creation fact and one identity row exist and ensure/reuse succeeds without a rich-note row. After catch-up exactly one rich note exists; losing effects and snapshot advancement do not. Repeats and archive/repeat preserve winner payload and provenance. Replaying the committed winner reconstructs that same identity and rich view without a command guard. Rich-view fencing does not stop ensure; identity-group fencing does. A post-commit wait can time out and later succeed using the same accepted receipt without another creation command.

An accepted multi-event command applies every event and every declared inline handler atomically. A refusing guard returns only its refusal, and a failing query returns an operational error. For a catalog-compatible set, silent decisions run neither callback nor catalog SQL; the existing early set/catalog mismatch still takes precedence over command evaluation. OCC conflicts discard stale domain decisions before guard execution; only the final committed attempt or typed rollback result is returned. A fault, timeout, or retry exhaustion is never reported as reuse.

A catalog fault takes precedence over a guard that would report an existing identity. A writable online rebuild may continue on its serving revision; an offline or fenced catalog prevents guard execution. Under real competing promotion, lookup and delivery use the same protected revision and target generation. Unknown revisions and invalid bindings fail through the existing typed outcomes.

Driver retries also discard rolled-back guard results and resolve/query again. Supported callbacks leave transaction control to the runner. The inline-only fixture remains writable while the async-only group is fenced; the broad-set negative control is fenced. Both promotion orderings, multi-group validation, and handler/event delivery order have observable tests.

The original API signatures, unguarded SQL/lock counts, and existing behavior remain intact unless M3 exposes a pre-existing resolver correctness defect requiring an explicitly recorded shared fix. The ordinary, guarded, and mixed benchmark cases pass M4's fixed budgets with raw evidence and declared environment. The required evidence includes per-cohort end-to-end latency, fixed-arrival-rate queueing, and sustained rollback/vacuum diagnostics. No numeric improvement or regression is asserted until measured. The compiled public-API example and guide provide the downstream handoff; actual release and adoption remain separately tracked.


## Idempotence and Recovery


Use fresh ephemeral databases for each correctness fixture and equivalent fresh seeded databases for benchmark pairs. Re-running tests must not depend on leftover note IDs, locks, or previous benchmark rows. Bound controller waits, cancel worker threads on failure, and close all connections so test locks are released. Keep run output directories separate rather than overwriting baseline evidence.

No framework migration or consumer data rewrite is expected. Guard refusal rolls back the prospective event batch and all transactional row writes. Sequence increments and other nontransactional SQL effects are not covered; supported production guards avoid them. Database faults retain existing error semantics, including uncertainty if the connection fails around commit; do not translate that uncertainty into a known duplicate or proven rollback. Return the winner only after the controlled runner has produced its refusal outcome.

If the implementation is abandoned, the original public runner remains available. Do not cherry-pick the unapproved prototype or reset another contributor's changes. If the benchmark fails, preserve the evidence and revise the design before declaring completion. Never resolve performance failure by weakening atomicity, bypassing fences, relaxing unique constraints, or hiding latency in an unmeasured retry loop.


## Interfaces and Dependencies


Keep the feature in `Keiro.Projection`, backed by existing `Keiro.Command` and catalog/rebuild types. Proposed public types are:

```haskell
data GuardedCatalogOutcome target co rejection noOp refusal
  = CatalogCommandOutcome
      !(DomainProjectionCommandOutcome target co rejection noOp)
  | PreconditionRefused !refusal

-- Constructor private; no consumer constructs an allegedly locked context.
newtype CatalogPreconditionContext = CatalogPreconditionContext [ProjectionWriteBinding]

catalogPreconditionBindings ::
  CatalogPreconditionContext -> [ProjectionWriteBinding]

runDomainCommandWithCatalogProjectionsGuarded ::
  forall phi rs s ci co rejection noOp refusal es.
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es,
   KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  ValidatedProjectionCatalog ->
  ProjectionSet co ->
  (CatalogPreconditionContext -> Tx.Transaction (Either refusal ())) ->
  Eff es
    (Either CommandError
      (GuardedCatalogOutcome (EventStream phi rs s ci co) co rejection noOp refusal))
```

Names may change to avoid an existing export collision, but the result distinction and context contract may not. Bindings contain group ID, optional serving revision ID, and `PhysicalTargets`; reuse these existing public types rather than a second revision model. Only the groups already fenced for this command belong in the context. Consumers resolve known declared target IDs with `resolvePhysicalTarget` and quote `QualifiedTable` coordinates with `Keiro.Connection.qualifyTable`. Validate consumer target membership before calling the runner and handle the context's schema/revision cases explicitly. In the note example, use a consumer guard-result sum with `ExistingNote NoteId` and a distinct `GuardConfigurationFault Text`; map only the former to reuse and the latter to an application configuration error. An absent target or unsupported schema must never become `ExistingNote` or fallback to an old table. Database/codec/command faults remain in their existing framework error channels. The guide and example must show these distinctions. The context does not certify freshness of asynchronously maintained tables or extend protection to other groups. The example passes a `ProjectionSet` containing only the required inline owners, not the full source set containing async-only owners. The callback may run more than once due to driver retries and must return its decision solely through `Either`; it must not condemn or otherwise control the surrounding transaction. This restriction is contractual because `Tx.Transaction` exposes operations that the type cannot prohibit.

Use `mori://hasql/hasql/packages/hasql-transaction` for database-local callbacks and rollback. Use `mori://shinzui/kiroku/packages/kiroku-store` for append and transaction effects. Reuse the repository's PostgreSQL fixture, Hspec tests, and benchmark tooling. No new lock service, reservation schema, package, isolation level, telemetry payload, or runtime dependency is planned.


Revision note (2026-10-11): Created from the owner discussion of IR-53. The plan fixes fence-before-guard ordering, makes serving-target access explicit, and includes global-lock performance acceptance before release readiness.

Revision note (2026-10-11): Refined the consumer model to minimum synchronous identity authority plus asynchronous rich views, with paused-worker, independent-fence, replay, and post-commit freshness acceptance. Existing runtime implementation milestones remain pending; this revision implements guidance only.


Revision note (2026-10-11): Validated the current command, catalog, rebuild, and Mori-located transaction sources. Corrected async-owner fencing by specifying an inline-only command set; clarified callback control and rollback limits, identity-key policy, retry and promotion admission tests, and delivery ordering. Preserved numeric budgets while adding reproducible workloads, queue-inclusive cohort measurements, and sustained duplicate-cost evidence. Only planning and source checks were performed; implementation and performance acceptance remain pending.


Revision note (2026-10-12): Begin implementation against the actual released dependency versions, retain ordinary baseline evidence, add same-database resource fixtures and the public guarded runner. Runtime and full performance acceptance remain pending; no readiness claim is made.


Revision note (2026-10-12): Record the expanded correctness matrix, unchanged ordinary-path source audit, and initial full regression result. Add reproducible enhanced original-library controls because the first retained harness omitted elapsed throughput and active-worker measurements; M4 and final verification remain pending.


Revision note (2026-10-12): Archive direct slow-guard/driver/lock diagnostics and distinguish historical normal-command benchmark failures from the unchanged original binary. Strengthen real catalog rebuild completion assertions and distill promotion-first admission into ADR-34. Fixed acceptance budgets and required matrix remain unchanged.


Revision note (2026-10-12): Close the correctness matrix with positive-control handler faults and a single-creation promotion assertion. Record the 754-example suite and passing projection guard. Align ordinary paired process lifetimes before fixed-budget measurements.


Revision note (2026-10-12): Preserve both fixed-budget attempts and RTS diagnostics. Six ordinary configurations pass in the repeat, while the seventh fails throughput. Keep M4 open and request an idle/isolated measurement environment; no code or budget change is made. Correct the historical command comparison to three of four lower current means.


Revision note (2026-10-12): Resume implementation from the committed correctness/documentation checkpoint. The benchmark builds in the Nix shell. Start another complete comparison with unchanged production code, workloads, and budgets after observing no competing GHC/Cabal jobs, retaining regular host samples and exact executable identity. Normal desktop/VM activity remains; investigate original-binary timing stability if acceptance fails instead of selecting favorable repetitions.


Revision note (2026-10-12): Stop the resumed run after competing workloads start, retaining two complete pairs and ten host observations. Make the 190-comparison inventory and raw-evidence completeness observable, add ratio medians/ranges and a failing `--require-complete` reporting gate, and verify it with five tests. Preserve the original fixed budgets and leave performance acceptance open until an appropriate runner is available; no API or dependency change is made.


Revision note (2026-10-12): Resume through the Kenshou runbook and authorized Linux builder. Correct missing Mori upstream metadata, separate durable benchmark fixtures from fast correctness fixtures, retain actual PostgreSQL settings, and remove the runtime Cabal-checkout dependency from candidate subprocess execution. Rebuild both enhanced controls before measuring; keep all fixed budgets and remaining acceptance requirements.


Revision note (2026-10-12): Record the 755-example full regression and add a reproducible remote comparison wrapper with dependency/compiler/source checks and five-second host monitoring. Freeze the candidate dependency selection into the enhanced baseline build; do not pool contaminated samples, retry budget failures automatically, or claim an exclusive lease from host observations.


Revision note (2026-10-12): Retain the remote cold-build interruption and resume against candidate `7233bd1e`. Replace the ineffective SSH-only idle assumption with an explicitly bounded, automatically restoring preparation/measurement hold on the existing builder watchdog. No acceptance sample or budget verdict is inferred from the interrupted build.


Revision note (2026-10-12): Verify the durable measurement output with a 100-attempt active-worker smoke and live contamination controls. Normalize wrapped compiler/build executable names in host monitoring, recognize external test binaries, and retain process identities/resource use without command arguments. The complete fixed-budget remote matrix remains outstanding.
