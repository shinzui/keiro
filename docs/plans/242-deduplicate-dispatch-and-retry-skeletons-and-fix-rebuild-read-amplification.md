---
id: 242
slug: deduplicate-dispatch-and-retry-skeletons-and-fix-rebuild-read-amplification
title: "Deduplicate dispatch and retry skeletons and fix rebuild read amplification"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjzp13e28vvrz7jfdve3dt"
master_plan: "docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md"
---

# Deduplicate dispatch and retry skeletons and fix rebuild read amplification

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The 2026-08-11 pre-release review of the `keiro` package (the runtime library of this
repository, currently versioned 0.11.0.0 in `keiro/keiro.cabal` and heading into 0.12.0.0,
the first stable release) confirmed three quality findings. None is a live bug. All three
are verified defect *risks*: correctness-critical logic that exists in several hand-copied
variants, so the next change to retry semantics, duplicate-detection probes, or rebuild
paging could land in some copies and not others, giving different entry points silently
different conflict or dedup behavior. The third finding is additionally a measurable
inefficiency: a catalog read-model rebuild with k event sources reads each stored event up
to k times.

This plan is the Wave-2 quality stream of its parent MasterPlan,
`docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md`
(child EP-6). The masterplan's Decision Log records that this is the only child plan whose
deferral would not ship a known bug — EP-1 through EP-5 fix confirmed correctness defects,
while this plan removes duplication and read amplification. That is exactly why every
change here must be behavior-preserving: the whole value of the plan is that future fixes
land once, and the proof obligation is that the existing test suite passes unmodified,
plus benchmark parity for the consolidations and a read-count demonstration for the paging
fix.

After this plan completes, a reader of `keiro/src/Keiro/Command.hs` finds one
optimistic-concurrency retry loop per append mechanic (one plain, one transactional)
instead of four; a reader of `keiro/src/Keiro/Router.hs` and
`keiro/src/Keiro/ProcessManager.hs` finds the idempotent-dispatch probe written once
instead of four times; and a three-source catalog rebuild demonstrably reads each event
once instead of three times, verified by an instrumented read counter and a new benchmark.
Every public function keeps its exact name, signature, and observable behavior, including
telemetry.


## Progress

- [x] Research complete: all duplicated sites read in full, test-name coupling enumerated,
      bench targets identified, wrapper design type-checked against `forgetDomainDecision`
      and `SilentDomainDecision` (2026-08-11, plan drafting).
- [ ] Milestone 1: extract the two shared attempt loops in `keiro/src/Keiro/Command.hs`.
- [ ] Milestone 1: rewrite `runCommand` and `runCommandWithSqlEventsControlled` as
      wrappers; add `silentNoOpHandler` and `forgetDomainSqlOutcome`.
- [ ] Milestone 1: factor the duplicated `applyCatalogProjections` callback in
      `keiro/src/Keiro/Projection.hs` into one top-level helper.
- [ ] Milestone 1: full suite green with zero test edits; `command` bench parity recorded.
- [ ] Milestone 2 (blocked until `docs/plans/240-…` lands): re-read the post-240 dispatch
      code and record the exact probe chain per site in this plan.
- [ ] Milestone 2: add `dispatchDeduplicatedCommand` to `keiro/src/Keiro/ProcessManager.hs`
      and `annotateRouterOccurrences` to `keiro/src/Keiro/Router.hs`; convert all four
      dispatch sites.
- [ ] Milestone 2: full suite green with zero test edits (including plan 240's bridge
      tests); fan-out bench parity recorded.
- [ ] Milestone 3 (blocked until `docs/plans/237-…` lands): rebase over the canonicalized
      `rebuildContract`; confirm the contract computation is untouched.
- [ ] Milestone 3: add the read-counting spec example and record the pre-fix counts here.
- [ ] Milestone 3: implement buffered paging in
      `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`; hoist per-chunk inspection; guard
      cursor advancement.
- [ ] Milestone 3: read-counting example asserts single-read behavior; new `rebuild` bench
      group added and before/after wall times recorded here.
- [ ] ADR distillation pass; masterplan Progress and Status updated.


## Surprises & Discoveries

Findings from plan research (2026-08-11), recorded because they shaped the design:

- keiki defines `stepEither` literally as a projection of `stepDetailedEither`
  (`/…/keiki/src/Keiki/Core.hs`, lines 1597–1607 in the registered corpus checkout:
  `stepEither t seed ci = case stepDetailedEither t seed ci of …`). This makes the
  legacy-runner-as-wrapper design semantically exact, not merely plausible: the legacy
  plan preparation (`prepareCommandPlan` via `evaluateCommand`/`stepEither`) and the
  domain preparation (`prepareDomainCommandPlan` via `stepDetailedEither`) select the same
  edge, produce the same outputs, and map failures to the same `CommandError`s.
- The review's "same pattern in `keiro/src/Keiro/Projection.hs` (~288)" is not a fifth
  copy of the retry loop. `Keiro.Projection` contains no retry logic at all; line 288 is
  the `applyCatalogProjections` transaction callback, duplicated verbatim between
  `runCommandWithCatalogProjections` and `runDomainCommandWithCatalogProjections`. The
  retry loops those two delegate to are the `…WithSqlEventsControlled` pair in
  `Keiro.Command`. Milestone 1 therefore treats Projection.hs as callback duplication, not
  loop duplication.
- The `keiro-bench` suite has no rebuild, projection, or read-model benchmark at all
  (groups are `outbox`, `inbox`, `command` only), so Milestone 3 cannot reuse an existing
  baseline and must add both its instrumented-count test and a new bench group.
- Kiroku's `Store` effect is dynamically dispatched and every operation is first-order
  (`data Store :: Effect` with `type instance DispatchOf Store = Dynamic`, no constructor
  mentioning the carrier monad), so an `interpose`-based counting wrapper in the test
  suite is straightforward — no higher-order delegation needed.

(Implementation surprises go here as they occur.)


## Decision Log

- Decision: Wrap the legacy command runners over shared internal attempt loops rather
  than over the public domain runners. The review sketched "legacy runners become thin
  wrappers over the domain runners (classify = const silent no-op)". Taken literally —
  `runCommand = fmap forgetDomainDecision <$> runDomainCommand …` — that compiles (the
  types line up; see Interfaces and Dependencies) but is not behavior-preserving:
  `runDomainCommand` records domain-decision telemetry (`recordDomainCommandOutcome`
  adds the `keiro.command.decision` span attribute and a `recordCommandDecision` metric)
  that the legacy runners have never emitted, and tests such as `test/Main.hs:1360`
  ("records only bounded decision classes on successful spans and metrics") and
  `test/Main.hs:2241` ("runCommand emits a Command span with the stream name,
  db.system.name, and keiro.events.appended") pin span/metric behavior. So the extraction
  point is one level lower: the `attempt`/`runPlan`/`appendOnce` loop is extracted once
  per append mechanic, and each public runner keeps its own span-outcome recording
  exactly as today. Four loops still collapse to two; telemetry stays byte-identical.
  Rationale: "tests stay green, outputs unchanged" is the acceptance bar; telemetry is an
  output.
  Date: 2026-08-11
- Decision: Place the shared dispatch helper in `Keiro.ProcessManager`, next to
  `eventAlreadyIn` and `confirmBenignDuplicate`, and have `Keiro.Router` import it, as it
  already imports those two. `test/Main.hs` imports `Keiro.ProcessManager` by name (line
  171), so adding an export there is safe while removing or renaming existing exports
  (`confirmBenignDuplicate` is named in four test examples) is not.
  Rationale: minimal import churn; keeps the idempotency primitives in one module.
  Date: 2026-08-11
- Decision: Scope Milestone 2 to the four per-command dispatch sites (legacy router,
  domain router, legacy process-manager, domain process-manager). The two manager-state
  advance sites (`runProcessManagerOnce` lines ~524–540 and
  `advanceDomainProcessManager` lines ~665–686) reuse `eventAlreadyIn` and
  `confirmBenignDuplicate` but have a different shape (a non-benign failure propagates as
  the whole runner's `Left`, and the success continuation performs effects — timer
  scheduling), and the awakeable journal probe in `keiro/src/Keiro/Workflow/Awakeable.hs`
  is plan 240's own surface. Folding either into the helper is deferred; revisit after
  240 lands if its bridge places probe logic in a shareable function.
  Rationale: the finding names the command-dispatch copies; widening the net grows risk
  without growing the consolidation payoff.
  Date: 2026-08-11
- Decision: Milestone order 1 → 2 → 3, with Milestone 2 waiting for plan 240
  (`docs/plans/240-bridge-deterministic-id-deduplication-across-the-utf-8-encoding-upgrade.md`)
  and Milestone 3 waiting for plan 237
  (`docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md`).
  Both orderings are the masterplan's recorded soft dependencies: 240 is redefining the
  very dedup probe Milestone 2 consolidates (consolidating after means the bridged probe
  is written once, in the helper), and 237 edits `rebuildContract` in the same module
  Milestone 3 restructures (rebase-order preference only; the functions are disjoint).
  Milestone 1 has no dependency and starts immediately.
  Date: 2026-08-11
- Decision: Milestone 3's primary evidence is an instrumented read-count assertion using
  an effectful `interpose` wrapper over the `Store` effect in a new
  `ProjectionReplaySpec` example, plus a new `rebuild` group in `keiro-bench` for
  wall-clock evidence. PostgreSQL-side counting (`pg_stat_statements`,
  `pg_stat_user_tables`) was rejected: the extension is not provisioned by the
  ephemeral-pg fixture and table-level counters are noisy across the suite's shared
  server.
  Rationale: the Store effect is dynamic and first-order (see Surprises), making
  interposition deterministic and cheap; the masterplan's progress row for this milestone
  promises "benchmark evidence", which the new bench group supplies.
  Date: 2026-08-11
- Decision: In Milestone 3, keep the per-chunk `lockActiveRunStmt` fence and add a
  cursor guard to source advancement, instead of trusting retained in-memory buffers
  unconditionally. The chunk transaction only ever advances a source cursor from the
  exact position the driver's buffer was read at; a mismatch condemns the transaction and
  the driver falls back to a full re-inspection and fresh page reads.
  Rationale: today's loop re-reads everything every iteration, so a concurrent driver is
  merely wasteful; with retained buffers it would be unsound (stale tails double-applying
  events). The guard makes the optimized loop degrade to exactly the pre-fix behavior
  under interference rather than misbehave.
  Date: 2026-08-11


## Outcomes & Retrospective

(To be filled during and after implementation. At completion: compare against the Purpose
section, then run the ADR distillation pass — the consolidation itself is unlikely to need
a new ADR, but if Milestone 3's buffered-paging invariants prove subtle enough to be
durable context, extend the rebuild-related ADRs or add one.)


## Context and Orientation

This repository is a Haskell multi-package cabal project. The package this plan touches is
`keiro/` (library `keiro`, one test suite `keiro-test`, one benchmark `keiro-bench`).
`keiro-test-support/` provides the database fixture used by both tests and benches: it
boots one cached ephemeral PostgreSQL server per suite run, migrates a template database
named `keiro_template` once, and clones it per example with `CREATE DATABASE … TEMPLATE`.
No external database is needed; `cabal test keiro-test` from the repository root is fully
self-contained.

Three vocabulary items, defined once:

*Optimistic-concurrency retry* — every keiro command append targets a stream at an
expected version. If another writer got there first, the store rejects the append, and the
runner re-hydrates the stream and retries up to `retryLimit` (a field of
`RunCommandOptions`), with jittered exponential backoff (`backoffDelay`) and a
"conflict fixpoint" escape hatch (`conflictFixpoint`) that fails fast when a retry
observes the exact same stream version as the previous conflict, which indicates a
soft-deleted stream that reads empty but still collides on append.

*Idempotent dispatch probe* — routers and process managers dispatch commands to target
streams with deterministic event ids (version-5 UUIDs over seed text), so an at-least-once
delivery collapses to exactly-once effects. Before dispatching, the code probes whether
the id is already in the target stream (`eventAlreadyIn`); after a failed append it asks
whether the failure was a benign duplicate of our own earlier write
(`confirmBenignDuplicate`). Router dispatch additionally probes a *legacy* positional id
(the pre-upgrade derivation) so dispatches written by older keiro versions still
deduplicate — and plan 240 is extending this probe chain with a frozen
truncating-encoding id to bridge the UTF-8 seed-encoding switch recorded in
`docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`.

*Catalog rebuild* — `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` replays event history
into a read model. A rebuild run row tracks per-source progress (a cursor position and a
target position per source; a source is a category or the whole log). The drive loop
reads a page of events from each incomplete source, merges them in global-position order,
applies one page-size chunk through replay adapters inside one transaction (which also
advances cursors and is fenced by `lockActiveRunStmt`, a row lock that verifies the run is
still active and the contract fingerprint matches), and repeats until all sources are
exhausted, then verifies and promotes.

### Finding 1 — the command retry skeleton exists four times

`keiro/src/Keiro/Command.hs` contains four functions that each carry a private copy of
the same retry loop — a `where`-block of `attempt` (hydrate, then run the plan),
`runPlan` (check `conflictFixpoint`, prepare the command plan, no-op/silent short-circuit
or append), and `appendOnce`/`appendWithSqlOnce` (append, then `verifyAndSnapshot` on
success or `retryOrFail` on store error). At the time of writing (before plans 237–241
land) the four are: `runCommand` (line ~731), `runDomainCommand` (~782),
`runCommandWithSqlEventsControlled` (~905), and
`runDomainCommandWithSqlEventsControlled` (~1027). They differ only in (a) plan
preparation — `prepareCommandPlan` versus `prepareDomainCommandPlan`, which as noted
under Surprises are provably equivalent because keiki's `stepEither` is defined as a
projection of `stepDetailedEither` — and (b) the outcome constructors:
`CommandResult`/`SqlCommandOutcome` on the legacy side versus
`DomainCommandOutcome`/`DomainSqlCommandOutcome` on the domain side. The two
"WithSqlEventsControlled" variants share transactional append mechanics
(`appendToStreamTx` with event enrichment and an in-transaction callback that may
condemn); the two plain variants share `appendToStream`.

The module already ships the collapse adapter:

```haskell
forgetDomainDecision :: DomainCommandOutcome target co rejection noOp -> CommandResult target
forgetDomainDecision DomainCommandOutcome {result} = result
```

and the silent-classification type is `SilentDomainDecision rejection noOp` with
constructors `SilentRejected !rejection | SilentNoOp !noOp`
(`keiro/src/Keiro/Command/Domain.hs`). A handler whose classifier is
`\_ -> SilentNoOp ()` makes the domain plan preparation produce, for an empty output
word, exactly the legacy no-op: both branches build their result with
`noOpResult targetStream current` (compare `prepareCommandPlan`'s `toPlan []` at ~1127
with `prepareDomainCommandPlan`'s silent branch at ~1147–1158).

`keiro/src/Keiro/Projection.hs` carries the related (callback, not loop) duplication:
`runCommandWithCatalogProjections` (~207) and `runDomainCommandWithCatalogProjections`
(~262) each define an identical `applyCatalogProjections` transaction callback (lock the
rebuild groups, apply every inline projection to every event pair, commit or roll back on
the fence) and near-identical fence-outcome mappings.

The risk being mitigated: a future retry-semantics change — a backoff cap, a
conflict-fixpoint refinement, a `verifyAndSnapshot` ordering change — applied to only
some copies gives different entry points different conflict behavior. `retryOrFail`,
`conflictFixpoint`, and `backoffDelay` are already shared helpers; it is the *loop
wiring* (what is retried, what is checked before each attempt, what runs after a
successful append) that is copied.

### Finding 2 — the router/process-manager dispatch shape exists four times

`keiro/src/Keiro/Router.hs` has, at the time of writing:

- `dispatchRouterCommands` (~279): the shared helper used by the legacy `runRouterOnce`
  and the declarative `runDeclarativeRouterOnce`. It annotates each resolved command with
  its emit index and same-target-stream occurrence (the `occurrenceStep`/`mapAccumL`
  fold), derives the primary id with `deterministicRouterCommandId` and the legacy
  positional id with `Keiro.ProcessManager.deterministicCommandId`, probes the primary id
  then (only if absent) the legacy id via `eventAlreadyIn`, dispatches through
  `Keiro.Projection.runCommandWithProjections`, and on failure folds
  `confirmBenignDuplicate` into `PMCommandDuplicate`, otherwise `PMCommandFailed`;
  success is `PMCommandAppended`.
- `resolveDomainRouterCommands` (~427) + `dispatchDomainRouterCommand` (~454): a
  re-implementation of exactly that annotation and probe logic for the domain router
  (used by `runDomainRouterOnce` and, via `foldDomainRouterSummary`, by
  `runDomainRouterWorkerWith` around line ~593), differing only in dispatching through
  `runDomainCommandWithProjections` and producing `DomainPMCommandHandled` /
  `DomainPMCommandDuplicate` / `DomainPMCommandFailed`.

`keiro/src/Keiro/ProcessManager.hs` has the same shape twice more, with a single
positional id and no legacy probe (positional ids are sound there because `handle` is
pure, per the comment block above `deterministicCommandId` at ~460): the legacy
`dispatchCommand` local of `runProcessManagerOnce` (~564–584) and
`dispatchDomainProcessManagerCommand` (~735–778).

So the probe-and-recover sequence — probe primary id, probe legacy ids, set
`#eventIds .~ [primary]` on the options, dispatch, confirm benign duplicate on failure —
is written four times, varying only in the id chain, the runner invoked, and the result
constructors. Plan 240 is redefining the probe chain (adding a frozen
legacy-truncating-encoding id so non-ASCII seeds deduplicate across the encoding switch);
this plan lands after 240 and must preserve the bridged semantics exactly, ending with
the probe written once.

### Finding 3 — rebuild read amplification

`driveCatalogRebuild` in `keiro/src/Keiro/ReadModel/Rebuild/Runner.hs` (~352–413 at the
time of writing) does, per loop iteration: (1) a full four-query progress inspection
(`inspectCatalogRebuildMaybe`: the run row, plus its sources, adapters, and verifications
— lines ~295–314); (2) `readSourcePage` for *every* incomplete source (line ~374); (3) a
merge of all pages (`orderedCandidates`), a duplicate-position invariant check, and then
`Prelude.take pageSize` — consuming at most one pageSize of the merged union (line ~383).
Every event beyond the chunk boundary is thrown away and re-read next iteration, so with
k incomplete sources each event is fetched up to k times, and with a single source events
near the end of a page are still re-read once per iteration in which they are not
consumed. A sibling inefficiency sits inside `applyChunkTx`: `completedSources` re-scans
every page's events against the chunk (`eventConsumed`, ~555–568), quadratic in page
size. The chunk transaction itself (locking, applying adapters, advancing cursors via
`advanceSourceStmt`, completing sources via `completeSourceStmt`) is sound and stays
structurally as-is.

`driveCatalogRebuild` and `inspectCatalogRebuildMaybe` are internal: the module
`Keiro.ReadModel.Rebuild.Runner` is an `other-module`, neither function is exported from
`Keiro.ReadModel.Rebuild`, and no test names them. Tests reach the loop only through
`startCatalogRebuild` / `resumeCatalogRebuild` / `inspectCatalogRebuild` /
`abandonCatalogRebuild`.

### The safety net: tests and benches

The single test suite is `keiro-test` (hspec; `keiro/test/Main.hs` plus `CatalogSpec`,
`CatalogOperationsSpec`, `GroupRebuildSpec`, `ProjectionReplaySpec`). The groups that
cover the surfaces this plan refactors, by their exact `describe` strings:

For Milestone 1: "Keiro.Command" (including the nested "typed domain command outcomes"
block and the optimistic-concurrency examples — notably "retries an optimistic conflict
after rehydrating the winning event", "reports true retry attempts and command conflict
metrics when the retry budget is exhausted", "records the successful retry attempt on the
command span", "counts duplicate deterministic command events", "fails fast when a
soft-deleted stream causes a conflict fixpoint", and "discards an accepted conflict
attempt and returns the rehydrated silent decision"), "Keiro.Command enrichment parity",
"catalog-fenced inline projections", and the `runCommandWithProjections` examples under
"Keiro.ReadModel" and "Keiro.Connection projection schema".

For Milestone 2: "Keiro.Router" (notably "reports every dispatch as a duplicate on
replay, writing no new events", "dedups by target identity when a redelivered resolve
reorders targets after a partial dispatch", "dispatches a target added by resolve drift
instead of misreading it as a duplicate", "keeps repeated commands to one target distinct
within a resolve batch", "folds a concurrent duplicate router dispatch to
PMCommandDuplicate", and "dedups a pre-upgrade positional router dispatch during the
transition"), "Keiro.ProcessManager" (notably "treats duplicate input delivery as
idempotent state and command dispatch", "folds a concurrent duplicate target dispatch to
PMCommandDuplicate", "folds a concurrent duplicate manager-state append to
PMStateDuplicate"), "Keiro.ProcessManager duplicate confirmation" (the
`confirmBenignDuplicate` unit group), "Keiro deterministic id derivation", plus whatever
golden-vector tests plan 240 adds.

For Milestone 3: "catalog replay runner" in `keiro/test/ProjectionReplaySpec.hs` (seven
examples; the first, "merges interleaved categories in global order and promotes only
complete evidence", already drives a three-category-source rebuild at page size 2 —
exactly the shape whose reads Milestone 3 counts), "catalog rebuild groups" in
`GroupRebuildSpec.hs`, and "projection catalog operations actions" in
`CatalogOperationsSpec.hs`.

Name coupling that constrains the refactor (verified by reading the test imports):
`test/Main.hs` imports the umbrella module `Keiro` (so anything re-exported through
`keiro/src/Keiro.hs` may move between modules but must keep its name and umbrella
re-export) and imports `Keiro.ProcessManager`, `Keiro.Projection`, `Keiro.ReadModel`, and
`Keiro.ReadModel.Rebuild` by name (so existing exports of those modules must not move
out). Functions named directly in test code — renaming any breaks compilation:
`runCommand`, `runDomainCommand`, `forgetDomainDecision`, `deterministicRouterCommandId`,
`confirmBenignDuplicate`. One out-of-process test is extra-brittle: "rejects a bare
EventStream at runCommand (compile-time)" (`test/Main.hs:1077`) compiles
`test/ReplaySafetyTypeProbe.hs` with `cabal exec ghc` and greps stderr for
`ValidatedEventStream`; it requires `runCommand` to keep its exact
`ValidatedEventStream`-taking signature and umbrella export. All internal functions this
plan touches (`runCommandWithSqlEventsControlled`,
`runDomainCommandWithSqlEventsControlled`, `dispatchRouterCommands`,
`resolveDomainRouterCommands`, `dispatchDomainRouterCommand`, `driveCatalogRebuild`,
`inspectCatalogRebuildMaybe`) are named by no test and are free to change.

The benchmark suite is `keiro-bench` (`keiro/bench/Main.hs`, tasty-bench, also
ephemeral-pg backed). Its `command` group carries the fan-out heap benchmarks added in
commits `2da1f4e5` and `2c3e42c8`: dotted names
`All.command.legacy.{accepted-1,accepted-large,no-op}`, `All.command.control.accepted-1`,
`All.command.domain-warmup.accepted-1`,
`All.command.domain.{accepted-1,accepted-large,rejected,no-op}`,
`All.command.domain.router-fanout.{10,100,1000}`, and
`All.command.domain.process-manager-fanout.{10,100,1000}`, gated against the committed
baseline `keiro/bench/baseline-command.csv` by the root `Justfile`'s `bench-regression`
recipe (25% slowdown budget; wall-time mode). The `legacy` benches call `runCommand`, the
`domain` benches call `runDomainCommand`, and the fan-out benches drive
`runDomainRouterWorker` / `runDomainProcessManagerWorker` — so this one recipe is the
no-regression evidence for Milestones 1 and 2. The bench group and bench names are a hard
contract with the baseline CSV: do not rename any of them. There is no rebuild bench;
Milestone 3 adds one.

### Relevant ADRs

- `docs/adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md`
  (ADR-24): every deterministic id hashes the UTF-8 bytes of its seed and the derivation
  is frozen replay identity. Milestone 2 consolidates the probe chain that plan 240 is
  extending under this ADR; the consolidation must not alter any id derivation or probe
  order, and ADR-24's bridge section (added by 240) is the specification Milestone 2
  preserves.
- `docs/adr/0029-typed-domain-decisions-are-successful-additive-command-outcomes.md`
  (ADR-29): domain runners return typed decisions (`DomainAccepted`/`DomainRejected`/
  `DomainNoOp`) as successful outcomes while unmatched commands and infrastructure
  failures stay `CommandError`; the domain runners are the canonical evaluation path.
  Milestone 1 makes the code structure agree with this ADR: the legacy runners become
  decision-forgetting views of the domain loop.
- `docs/adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md`
  (ADR-25): a background worker never lets one bad item end its batch and reports work
  finished, not attempted. The router/process-manager workers whose dispatch internals
  Milestone 2 consolidates observe this contract; consolidation must keep per-item
  failure isolation (each dispatched command returns its own result; the summary fold is
  untouched).

No cross-repository ADR applies (the masterplan's ADR scan reached the same conclusion).

### Sibling plans this plan coordinates with

- `docs/plans/240-bridge-deterministic-id-deduplication-across-the-utf-8-encoding-upgrade.md`
  (EP-4): redefines the dedup probe to also check a frozen legacy-truncating-encoding id.
  Soft dependency: Milestone 2 starts only after 240 is Complete, and its first step is
  re-reading the then-current dispatch code (line numbers in this plan will have
  shifted).
- `docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md`
  (EP-1): canonicalizes the `rebuildContract` preimage in the same
  `Rebuild/Runner.hs` module Milestone 3 edits. Soft dependency (rebase-order
  preference): Milestone 3 starts after 237 is Complete and must not alter the contract
  computation, the fingerprint comparison in `resumeCatalogRebuild`/`abandonCatalogRebuild`,
  or any checkpoint/cursor persistence semantics.


## Plan of Work

The work is three milestones matching the three findings, in order. Each is independently
landable (its own commit series, its own green suite) and independently verifiable. Do not
start Milestone 2 before plan 240 is Complete, nor Milestone 3 before plan 237 is
Complete; Milestone 1 can begin immediately.

### Milestone 1 — collapse the four command retry loops to two

Scope: `keiro/src/Keiro/Command.hs` and `keiro/src/Keiro/Projection.hs` only. At the end
of this milestone the module contains exactly two copies of the
attempt/runPlan/appendOnce loop — one for plain appends, one for controlled transactional
appends — both living in the domain-typed code path, with the two legacy runners as thin
decision-forgetting wrappers. No public name, signature, export, or telemetry changes.

Work, in order:

First, in `keiro/src/Keiro/Command.hs`, extract the body of `runDomainCommand`'s
`withCommandSpan` block *minus* the `recordDomainCommandOutcome` call into a new internal
function (suggested name `domainCommandAttempts`) that takes the options, a
`DomainCommandHandler`, the target stream, the command, and the `Maybe Span`, and returns
the `(Either CommandError (DomainCommandOutcome …), Int)` pair (outcome and final attempt
number). Its `where`-block is verbatim today's `attempt`/`runPlan`/`appendOnce` from
`runDomainCommand`. Rewrite `runDomainCommand` as: open the span with `withCommandSpan`
exactly as today, call `domainCommandAttempts`, call `recordDomainCommandOutcome`, return
the outcome. Its behavior is unchanged by construction.

Second, add the silent handler and rewrite `runCommand`:

```haskell
-- Internal. Every silent edge is a successful no-op; the rejection type is
-- uninhabited because the classifier never constructs SilentRejected.
silentNoOpHandler :: ValidatedEventStream phi rs s ci co -> DomainCommandHandler phi rs s ci co Void ()
silentNoOpHandler ves = DomainCommandHandler {eventStream = ves, classifySilent = \_ -> SilentNoOp ()}
```

(`Void` needs `import Data.Void (Void)`, which `Keiro/Command.hs` does not yet have.)
`runCommand` keeps its exact exported signature and becomes: open the span exactly as
today, call `domainCommandAttempts options (silentNoOpHandler validatedEventStream) …`,
apply `fmap forgetDomainDecision` to the outcome, call `recordCommandOutcome mSpan
(^. #eventsAppended) attemptNo` on the *forgotten* result exactly as today, return it.
Delete `runCommand`'s now-dead `where`-block loop and, once nothing references them,
`prepareCommandPlan`/`evaluateCommand` if they become unused (check first —
`evaluateCommand` may have other callers; delete only what is genuinely dead, and note
what was deleted in Progress). The equivalence argument to keep in mind while editing (and
to cite in the commit message): keiki's `stepEither` is a projection of
`stepDetailedEither`, both preparations produce `noOpResult targetStream current` for an
empty output word, both map step failures through the same `CommandRejected`/
`CommandAmbiguous` translation, and both encode the same batch with the same
`assignEventIds`/`encodeEvents` calls.

Third, repeat the same two moves for the controlled pair: extract
`domainSqlCommandAttempts` from `runDomainCommandWithSqlEventsControlled` (again minus
its `recordDomainSqlCommandOutcome` call), rewrite that function as span + loop + record,
and rewrite `runCommandWithSqlEventsControlled` as span + loop-with-`silentNoOpHandler` +
its own existing `recordCommandOutcome eventCount` + a new internal total mapping

```haskell
forgetDomainSqlOutcome :: DomainSqlCommandOutcome target co rejection noOp a -> SqlCommandOutcome target a
forgetDomainSqlOutcome = \case
  DomainSqlCommandSilent outcome -> SqlCommandNoOp (forgetDomainDecision outcome)
  DomainSqlCommandCommitted outcome a -> SqlCommandCommitted (forgetDomainDecision outcome) a
  DomainSqlCommandRolledBack a -> SqlCommandRolledBack a
```

The callback types already agree exactly (`[(co, RecordedEvent)] -> AppendResult ->
Tx.Transaction (SqlTransactionDecision a)` on both sides), and the silent path opens no
transaction on either side, so a legacy no-op command still never invokes the callback.
`runCommandWithSql`, `runCommandWithSqlEvents`, `runDomainCommandWithSql`, and
`runDomainCommandWithSqlEvents` are already delegating wrappers and need no edits.

Fourth, in `keiro/src/Keiro/Projection.hs`, lift the duplicated `applyCatalogProjections`
`where`-binding (identical in `runCommandWithCatalogProjections` and
`runDomainCommandWithCatalogProjections`) to one top-level internal function:

```haskell
applyCatalogProjectionsTx ::
  [InlineProjection co] ->
  [RebuildGroupId] ->
  [(co, RecordedEvent)] ->
  Tx.Transaction (SqlTransactionDecision ProjectionWriteFence)
```

whose body is the existing binding (lock groups, apply projections on
`ProjectionWritesAllowed`, commit the fence; roll back carrying the fence otherwise), and
have both runners pass it. Leave the two `toProjectionOutcome`/`fenceOutcome` mappings
alone — they translate to different result types and are not correctness-critical
duplication.

Acceptance: the full suite green with zero test-file edits, plus command-bench parity
(the `bcompareWithin 0 1.25` domain-versus-control gates inside the bench, and the
baseline CSV gate) — exact commands under Concrete Steps. Watch the two named couplings:
`runCommand`'s signature (the compile-time probe test) and `forgetDomainDecision`'s
export (named in three test examples).

### Milestone 2 — consolidate the idempotent dispatch probe into one helper

Precondition: plan 240 is Complete. Scope: `keiro/src/Keiro/ProcessManager.hs` and
`keiro/src/Keiro/Router.hs`. At the end of this milestone the probe-and-recover sequence
(including 240's bridged id chain) exists in exactly one function, and the occurrence
annotation exists in exactly one function.

First step, mandatory: re-read the post-240 versions of `dispatchRouterCommands`,
`dispatchDomainRouterCommand`/`resolveDomainRouterCommands`, `runProcessManagerOnce`'s
`dispatchCommand`, and `dispatchDomainProcessManagerCommand`, and record in this plan
(under Progress or Surprises) the exact per-site probe chain 240 left behind — which ids,
derived how, probed in which order, and which id each duplicate result carries. The
consolidation below is stated against the pre-240 shape (primary router id, then one
legacy positional id, probed only when the primary is absent; process manager: single
positional id); if 240 added a third frozen id or changed the order, the helper's probe
list simply carries it — the *sequence semantics* written once must be byte-for-byte what
240 shipped.

Then add to `keiro/src/Keiro/ProcessManager.hs`, beside `eventAlreadyIn` and
`confirmBenignDuplicate`, the single shared dispatcher:

```haskell
-- | Probe-then-dispatch with benign-duplicate recovery. The first probe hit
-- short-circuits to the duplicate result carrying the id that hit; otherwise the
-- action runs and a failed append is folded to a duplicate only after
-- confirmBenignDuplicate proves the primary id landed in the target stream.
dispatchDeduplicatedCommand ::
  (Store :> es) =>
  RunCommandOptions ->
  StoreTypes.StreamName ->
  -- | Primary deterministic id: probed first, used for benign-duplicate confirmation.
  EventId ->
  -- | Legacy probe ids, in order; probed only when the primary id is absent.
  [EventId] ->
  -- | Duplicate result constructor (receives whichever id hit).
  (EventId -> result) ->
  -- | Failure result constructor.
  (CommandError -> result) ->
  -- | Success result constructor.
  (r -> result) ->
  -- | The dispatch action; the caller has already set @#eventIds .~ [primary]@.
  Eff es (Either CommandError r) ->
  Eff es result
```

with the body being today's shared sequence: probe the primary via `eventAlreadyIn`; if
present return `duplicate primary`; else probe each legacy id in order and return
`duplicate legacyId` on the first hit; else run the action; on `Right r` return
`success r`; on `Left err` run `confirmBenignDuplicate streamName primary err` and return
`duplicate primary` when confirmed, `failure err` otherwise. Export it from
`Keiro.ProcessManager` (additive export — safe) and re-export from `Keiro.Router`'s
idempotency section for symmetry if desired (optional).

Add to `keiro/src/Keiro/Router.hs` the single occurrence annotator, lifted verbatim from
the two identical `occurrenceStep` folds:

```haskell
-- | Pair each resolved command with its emit index, its occurrence among
-- commands addressing the same target stream (0 for the first), and that
-- resolved stream name.
annotateRouterOccurrences ::
  (PMCommand targetCi -> StreamName) ->
  [PMCommand targetCi] ->
  [(Int, Int, StreamName, PMCommand targetCi)]
```

Convert the four sites: `dispatchRouterCommands`'s `dispatchCommand` local becomes a
`dispatchDeduplicatedCommand` call with duplicate `PMCommandDuplicate`, failure
`PMCommandFailed targetStreamName`, success `PMCommandAppended`, action
`runCommandWithProjections targetOptions …`; `dispatchDomainRouterCommand` becomes the
same call with the `DomainPMCommand*` constructors and
`runDomainCommandWithProjections`; both router sites build the identical probe-id chain
(primary `deterministicRouterCommandId`, then the legacy ids as 240 left them) — extract
that chain construction into one shared local or top-level function in `Router.hs` so it,
too, exists once. The two process-manager sites (`runProcessManagerOnce.dispatchCommand`
and `dispatchDomainProcessManagerCommand`) become calls with their positional primary id
and whatever legacy list 240 gave them (empty pre-240). `resolveDomainRouterCommands` and
`dispatchRouterCommands` both switch to `annotateRouterOccurrences`. Delete the four
inlined copies. Do not touch: the manager-state advance probes, the summary folds
(`foldDomainRouterSummary`, `dispatchDomainProcessManagerSummary`,
`summarizeDomainCommandResult`), worker ack policy, or anything in
`Keiro/Workflow/Awakeable.hs` (see Decision Log for why).

Behavioral invariants to preserve exactly (all are observable in tests): probe order and
short-circuiting (legacy ids probed only when the primary is absent); the duplicate
result carries the id that hit, so a legacy-probe hit reports the *legacy* id
("dedups a pre-upgrade positional router dispatch during the transition" pins this);
`#eventIds` is set to the primary id only; `confirmBenignDuplicate` is called with the
primary id and the resolved target stream name; per-item isolation (one command's failure
never affects its siblings' results).

Acceptance: full suite green with zero test edits — including plan 240's bridge/golden
tests — and fan-out bench parity. Exact commands under Concrete Steps.

### Milestone 3 — rebuild paging reads each event once

Precondition: plan 237 is Complete; rebase over it and confirm `rebuildContract` and
every fingerprint comparison are untouched by this milestone. Scope:
`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`, one new spec example in
`keiro/test/ProjectionReplaySpec.hs`, one new bench group in `keiro/bench/Main.hs`, and
one guarded SQL statement.

Step A — evidence first. Add a new example to the "catalog replay runner" group in
`keiro/test/ProjectionReplaySpec.hs` (an *addition*; no existing example changes),
suggested name "reads each source event once while draining a multi-source rebuild".
Fixture: three category sources (mirror the existing first example's orders/customers/
billing shape), six events per category interleaved in global order, page size 2. Wrap
the `startCatalogRebuild` call in a counting interposer over the `Store` effect —
`Store` is dynamically dispatched and first-order, so the interposer pattern-matches
every constructor, increments `IORef` counters on `ReadCategoryForward` (count calls and
sum returned row counts; count `ReadAllForward` too for `AllStreams` completeness) and
re-sends every operation unchanged. Run it against the *current* code and record the
observed counts in this plan (expected order of magnitude: with 18 events, page size 2,
and 3 sources, roughly 9–10 chunk iterations × 3 page reads each, so ~27–30
`ReadCategoryForward` calls fetching ~50+ event rows against 18 distinct events). Assert,
initially, the *post-fix* bound so the example fails red before the fix:

  total events fetched across all category page reads ≤ 18 + 3 × 2 (each source may
  read one final proving page beyond its last event), and page-read calls per source ≤
  ceil(6 / 2) + 1.

Step B — the fix. Restructure `driveCatalogRebuild`'s `go` loop to carry state across
iterations instead of re-deriving everything from the database:

- Per-source buffer: the source's progress row as last known, its unconsumed event tail
  (ascending global position), and the `pageProvesExhaustion` flag from its last read.
  `readSourcePage` itself is unchanged; it is now called only for incomplete sources
  whose buffer is empty (a streaming k-way refill) instead of for every incomplete source
  every iteration.
- Merge and chunk: merge the buffered tails by global position (the existing
  `orderedCandidates` logic over buffers), run the existing `duplicatePosition` check
  over the merged view *before* taking the chunk — a duplicate pair is always visible
  together in some merged view no later than the iteration that would consume its second
  element, so detection is at least as early as today — then `take pageSize` as now.
- Chunk transaction: keep `applyChunkTx`'s fence (`lockActiveRunStmt`), adapter
  application, and per-source advancement, with two changes. (1) Source advancement
  becomes guarded: extend `advanceSourceStmt` (or add a guarded variant) with a
  `WHERE cursor_position = $expected` clause carrying the cursor the buffer was read at,
  and check the affected-row count; a mismatch condemns the transaction. On that
  condemnation the driver discards all buffers and falls back to one full
  `inspectCatalogRebuildMaybe` + fresh reads — the pre-fix behavior — making interference
  degrade to today's semantics instead of double-applying stale events. (2)
  `completedSources`/`eventConsumed` are replaced by buffer bookkeeping: a source
  completes in the chunk transaction that consumes its last buffered event while its
  exhaustion flag is set (and a refill that returns an empty-but-proving page completes
  the source in the next transaction, which must still run even with an empty chunk —
  today's code has exactly this empty-chunk completion pass; preserve it). This deletes
  the quadratic rescan.
- Inspection hoisting: run `inspectCatalogRebuildMaybe` once on entry (keeping today's
  entry checks verbatim: unknown run → `CatalogRebuildRunNotFound`, promoted →
  `Right report`, not running → `CatalogRebuildRunNotActive`), then maintain progress in
  memory. Mid-drive liveness is already policed by `lockActiveRunStmt` inside every chunk
  transaction, and its failure already maps to the same `CatalogRebuildRunNotActive` the
  hoisted check produced, so the error surface is unchanged. Promotion still goes through
  `verifyAndPromote`, whose `completionProofStmt` re-derives completion from the database
  — an in-memory bookkeeping bug can therefore stall with a typed error but can never
  promote an incomplete run. The final report still comes from a fresh
  `inspectCatalogRebuild`.

Do not change: `rebuildContract` (plan 237's), `captureHead`, `verifyAndPromote`,
`readSourcePage`'s eligibility/exhaustion computation, any statement other than the
guarded `advanceSourceStmt`, or any persisted schema.

Step C — flip the new example's assertion to green (it now passes), re-run the whole
"catalog replay runner" group (the existing seven examples pass unmodified — they pin
merge order, chunk rollback/resume, verification, drift refusal, and promotion evidence),
and record the post-fix counts here next to the pre-fix counts.

Step D — benchmark evidence. Add a `bgroup "rebuild"` to `keiro/bench/Main.hs` (a new
group; the existing `outbox`/`inbox`/`command` names and the three baseline CSVs are
untouched and their `-p` filters do not match the new group): one bench that seeds three
categories × N events (N around 200, sized so a run takes tens of milliseconds), then
`nfIO` a full `startCatalogRebuild` drive at a small page size, hard-deleting and
re-seeding between iterations following the existing `commandScenarioBench` cleanup
pattern (`Lifecycle.hardDeleteStream` per stream, not TRUNCATE). Run it before and after
the fix and record both wall times in this plan. No baseline CSV gate is added for it in
this plan (a committed baseline can follow once the numbers stabilize on the primary dev
machine).


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

Build the library and the test suite:

```bash
cabal build keiro keiro-test-support
cabal build keiro:keiro-test
```

Run the targeted groups while iterating (hspec `-m` matches substrings of the flattened
spec path):

```bash
# Milestone 1
cabal test keiro-test --test-options='-m "Keiro.Command"'
cabal test keiro-test --test-options='-m "catalog-fenced inline projections"'

# Milestone 2
cabal test keiro-test --test-options='-m "Keiro.Router"'
cabal test keiro-test --test-options='-m "Keiro.ProcessManager"'
cabal test keiro-test --test-options='-m "deterministic id derivation"'

# Milestone 3
cabal test keiro-test --test-options='-m "catalog replay runner"'
cabal test keiro-test --test-options='-m "catalog rebuild groups"'
cabal test keiro-test --test-options='-m "projection catalog operations"'
```

Expected shape of a passing targeted run (counts vary by group):

```text
Finished in 42.10 seconds
36 examples, 0 failures
```

Full gate after each milestone (this is the acceptance command; it runs every declared
suite in the repository, so it also proves the DSL and jitsurei layers still compile and
pass against the refactored runtime):

```bash
just haskell-test
```

Every suite must end `0 failures`. Zero test files are modified except the two additions
this plan itself makes (the Milestone 3 spec example and bench group); `git status` under
`keiro/test/` must show only `ProjectionReplaySpec.hs` (Milestone 3) as changed, and
`git diff keiro/test/` must contain additions only.

Benchmark parity for Milestones 1 and 2 (run on the primary dev machine, where the
committed baseline was captured; elsewhere the numbers are informational):

```bash
cabal bench keiro-bench --benchmark-options="-p command --time-mode wall --hide-progress --baseline bench/baseline-command.csv --fail-if-slower 25"
```

Expected shape of the relevant lines (the internal `bcompareWithin 0 1.25` gates fail the
run themselves if the domain/control ratio regresses):

```text
All.command.legacy.accepted-1:        OK
  1.83 ms ± 91 μs, same as baseline
All.command.domain.router-fanout.100: OK
  212  ms ± 8.2 ms, same as baseline
```

Milestone 3's bench, before and after the paging fix (no baseline yet; record both
numbers in this plan):

```bash
cabal bench keiro-bench --benchmark-options="-p rebuild --time-mode wall"
```

Commit after each independently green step, conventional-commit style, e.g.
`refactor(command): extract shared domain attempt loops`, `refactor(dispatch): consolidate
idempotent dispatch probe`, `perf(rebuild): retain page tails across chunks`.


## Validation and Acceptance

Milestone 1 is accepted when: `just haskell-test` is fully green with `git diff
keiro/test/` empty; `runCommand` and `runCommandWithSqlEventsControlled` contain no
retry-loop `where`-block (inspect the file — each body is span + shared loop + record +
forget, under ten lines); the compile-time probe example "rejects a bare EventStream at
runCommand (compile-time)" still passes (proving the exported signature survived); the
retry examples listed in Context (conflict retry, retry exhaustion, retry-attempt span,
duplicate counting, conflict fixpoint, and the domain-side "discards an accepted conflict
attempt…") all pass, which together exercise every branch of the shared loops from both
the legacy and domain entry points; and the `command` bench run against the baseline
passes its 25% gate with the in-bench domain-versus-control comparisons intact.

Milestone 2 is accepted when: `just haskell-test` is fully green with `git diff
keiro/test/` empty (plan 240's bridge and golden-vector tests included — they now
exercise the shared helper, since it is the only probe implementation left); `grep -n
"eventAlreadyIn" keiro/src/Keiro/Router.hs keiro/src/Keiro/ProcessManager.hs` shows the
probe called from exactly one dispatch implementation (plus the two manager-advance
sites, which are explicitly out of scope); the duplicate-identity examples pass —
in particular "dedups a pre-upgrade positional router dispatch during the transition"
(legacy id reported), "keeps repeated commands to one target distinct within a resolve
batch" (occurrence annotation), and both "folds a concurrent duplicate … to
PMCommandDuplicate" examples (benign-duplicate recovery) — and the
`router-fanout`/`process-manager-fanout` bench entries pass the baseline gate.

Milestone 3 is accepted when: the new spec example passes with its single-read bound
(each category source's page reads ≤ ceil(events/pageSize) + 1 and total fetched event
rows ≤ distinct events + sources × pageSize), and this plan records the measured before/
after counts — before: each event fetched up to 3 times (≈27+ page reads); after: each
event fetched once (≤ 12 page reads for the 3×6/page-2 fixture); the seven existing
"catalog replay runner" examples pass unmodified (rollback/resume, contract drift
refusal, verification, promotion evidence, capture-head fencing all preserved); `just
haskell-test` is fully green; and the new `rebuild` bench shows the improvement in wall
time with both numbers recorded here. Additionally verify by inspection and state in the
completion note: `rebuildContract` untouched, `advanceSourceStmt` guard present, empty-
chunk completion pass preserved.

The plan as a whole is accepted when all three milestones are accepted, the masterplan's
three EP-6 progress rows are checked with its Status flipped to Complete, and the ADR
distillation pass has run (update ADRs only if implementation surfaced durable context;
the expectation is none, and that expectation being wrong belongs in Surprises &
Discoveries).


## Idempotence and Recovery

Every step is a source edit plus a test run; all are safely repeatable. The milestones
are independently landable: stopping after Milestone 1 (or 2) leaves the tree strictly
better than before with no half-migrated state, because each milestone deletes the copies
it replaces within the same commit series that introduces the shared code. If a milestone
regresses something mid-flight, `git revert` of its commits restores the prior shape —
there are no schema migrations and no persisted-format changes anywhere in this plan (the
Milestone 3 statement change is a `WHERE` guard on an `UPDATE`, not a schema change).

Two recovery notes. If Milestone 2's conversion produces a behavior difference under plan
240's bridge tests, do not adapt the tests: the helper is wrong; re-derive its probe
sequence from the pre-consolidation code, which remains visible in git history and in
this plan's Milestone 2 first-step record. If Milestone 3's counting example reveals the
buffered loop re-reading more than the bound allows, the guarded-advance fallback path is
the likely culprit (each fallback legitimately re-reads); assert the example runs with no
concurrent driver so zero fallbacks occur.


## Interfaces and Dependencies

No new external dependencies. Internal dependencies: `effectful` (already a dependency)
for the Milestone 3 test interposer (`interpose` over Kiroku's dynamic `Store` effect);
`tasty-bench` (already the bench driver) for the new `rebuild` group; everything else is
code motion within the `keiro` library.

At the end of Milestone 1, `keiro/src/Keiro/Command.hs` contains (internal, not
exported):

```haskell
domainCommandAttempts ::
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  Maybe Span ->
  Eff es (Either CommandError (DomainCommandOutcome (EventStream phi rs s ci co) co rejection noOp), Int)

domainSqlCommandAttempts ::
  (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es, KirokuStoreResource :> es, BoolAlg phi (RegFile rs, ci), Eq co) =>
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  ([(co, RecordedEvent)] -> AppendResult -> Tx.Transaction (SqlTransactionDecision a)) ->
  Maybe Span ->
  Eff es (Either CommandError (DomainSqlCommandOutcome (EventStream phi rs s ci co) co rejection noOp a), Int)

silentNoOpHandler :: ValidatedEventStream phi rs s ci co -> DomainCommandHandler phi rs s ci co Void ()

forgetDomainSqlOutcome :: DomainSqlCommandOutcome target co rejection noOp a -> SqlCommandOutcome target a
```

and `keiro/src/Keiro/Projection.hs` contains (internal) `applyCatalogProjectionsTx ::
[InlineProjection co] -> [RebuildGroupId] -> [(co, RecordedEvent)] -> Tx.Transaction
(SqlTransactionDecision ProjectionWriteFence)`. All public signatures in both modules are
unchanged; `Data.Void (Void)` is newly imported in `Command.hs`.

At the end of Milestone 2, `keiro/src/Keiro/ProcessManager.hs` exports
`dispatchDeduplicatedCommand` with the signature given in Plan of Work (its final probe
argument shape may be adjusted to whatever plan 240 requires — e.g. a richer probe record
instead of `[EventId]` — as long as the sequence is written once), and
`keiro/src/Keiro/Router.hs` contains (internal) `annotateRouterOccurrences` and exactly
one construction of the router probe-id chain. No existing export of either module is
removed or renamed.

At the end of Milestone 3, `Keiro.ReadModel.Rebuild.Runner` (still an `other-module`)
contains the buffered drive loop — an internal per-source buffer type carrying the
progress row, unconsumed tail, and exhaustion flag — and a guarded source-advance
statement; the module's exported surface through `Keiro.ReadModel.Rebuild`
(`startCatalogRebuild`, `resumeCatalogRebuild`, `inspectCatalogRebuild`,
`abandonCatalogRebuild`) is byte-identical in type and behavior.

---

Revision note (2026-08-11): initial plan authored from the init-script skeleton after
reading all named functions in full, the test suite's coverage of each surface, the bench
inventory, keiki's step functions, and Kiroku's Store effect; the review's
wrapper-over-public-runner sketch was amended to wrapper-over-shared-loop to keep
telemetry byte-identical (see Decision Log).
