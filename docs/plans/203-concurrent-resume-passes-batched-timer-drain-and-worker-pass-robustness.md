---
id: 203
slug: concurrent-resume-passes-batched-timer-drain-and-worker-pass-robustness
title: "Concurrent resume passes, batched timer drain, and worker pass robustness"
kind: exec-plan
created_at: 2026-08-06T00:12:21Z
intention: "intention_01kza6gjs5eg79n2hyrah7wnnn"
master_plan: "docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md"
---

# Concurrent resume passes, batched timer drain, and worker pass robustness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Three workers move the durable-execution engine forward: the resume worker
re-invokes unfinished workflows, the timer worker fires due sleep timers, and the GC
worker deletes old terminal instances. All three have cost or robustness ceilings
that show up under load. The resume worker advances discovered workflows strictly
one at a time, so one slow step body delays every other workflow in the pass. The
timer worker claims exactly one due timer per invocation (and re-runs its
requeue-and-gauges preamble every time), so a backlog of due sleeps drains at one
row per poll tick. A workflow that goes terminal in the small window while its crash
is being recorded makes the crash-recording UPDATE match zero rows, which blows up a
single-row decoder and aborts the *rest of the resume pass*. And the GC worker's
`forever` loop has no per-pass error handling at all: the first transient database
error kills garbage collection until the process restarts.

After this plan: a resume pass can advance up to N workflows concurrently (default
1, today's behavior — the leases and the per-step append serialization already make
concurrent advancement safe, this only exploits it); a timer pass can drain up to N
due timers with one preamble; a crash-record race is logged and skipped instead of
aborting the pass; and a GC pass failure is logged and retried next tick like every
other keiro worker. Observable as: two workflows with deliberately slow steps
complete in overlapping wall-clock time under concurrency 2; a backlog of ten due
timers drains in one pass; and a resume pass that hits the crash-record race still
advances the other discovered workflows.


## Progress

- [x] (2026-08-06) Milestone 1: `recordCrashTx` tolerates zero rows; race no
  longer aborts a pass. Verified by temporarily restoring the single-row decoder
  — the new example fails, then passes.
- [x] (2026-08-06) Milestone 2: GC per-workflow isolation, per-pass isolation in
  the new `runWorkflowGcWorkerWith`, and an honest scanned/deleted summary.
- [ ] Milestone 3: batched timer drain (`drainDueTimers`) with tests.
- [ ] Milestone 4: bounded concurrent advancement in `resumeWorkflowsOnce` with overlap and isolation tests.
- [ ] Full suite green: `cabal test keiro-test`.


## Surprises & Discoveries

- Milestone 1's abort blast radius is wider than "the rest of the pass": because
  the crash record runs outside every per-advance catch, the zero-row decoder
  failure propagates out of `resumeWorkflowsOnce` itself, so the pass returns
  `Left` and reports *nothing* — the candidates it already advanced are not
  summarised either. That makes the regression test order-independent (it does
  not matter whether the racing workflow is discovered first or last), which is
  what let the test be written as a plain summary equality.

- Milestone 2 needed a deterministic way to make one deletion fail, and the
  plan's two suggestions do not fail: deleting the instance row mid-flight just
  makes the final `DELETE` match nothing, and `lookupStreamId` returns `Nothing`
  for an absent stream without erroring. The lever that does work is kiroku's
  `maxStreamNameBytes = 512` validation — `hardDeleteStream` rejects an
  over-long stream name every time. A `keiro_workflows` row written directly
  with a 600-character workflow id derives such a stream name, so the sabotage
  needs no timing, no concurrency, and no fault injection hooks.

- `gcWorkflowsOnce` did not need `IOE :> es` after all (`-Wredundant-constraints`
  caught it): the isolation uses `Effectful.Error.Static.catchError` and
  `Effectful.Exception.catchSync`, neither of which needs `IOE`. Only the loop
  driver does, for `threadDelay`. The published constraint change is therefore
  `Error StoreError :> es` alone.


## Decision Log

- Decision: Bound resume concurrency with a `maxConcurrentAdvances` option
  defaulting to 1.
  Rationale: Concurrency multiplies per-advance database load and competes for the
  store's connection pool; defaulting to today's serial behavior makes the change
  purely opt-in and keeps the plan independent of
  `docs/plans/200-make-suspended-workflows-quiescent-and-discovery-index-aligned.md`
  (which removes the no-progress advances that would otherwise be multiplied —
  the MasterPlan records this as a soft dependency).
  Date: 2026-08-06

- Decision: Use `effectful`'s own `Effectful.Concurrent` machinery (interpreted
  locally with `runConcurrent`) rather than adding an `async`/`unliftio`
  dependency.
  Rationale: `keiro` already depends on `effectful >= 2.6`, which ships
  `Effectful.Concurrent.Async` with correct environment cloning for concurrent
  dynamic-effect dispatch; the kiroku `Store` runs on a thread-safe connection
  pool. No new dependency, no hand-rolled unlift strategy.
  Date: 2026-08-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The resume worker is `keiro/src/Keiro/Workflow/Resume.hs`. One pass,
`resumeWorkflowsOnce`, samples a gauge, discovers unfinished workflows
(`findUnfinishedWorkflowIds` plus, today, a child seed), deduplicates, and then
`foldM`s an `advance` function over the candidates *sequentially*: each advance
claims a per-instance lease (`claimInstance` in
`keiro/src/Keiro/Workflow/Instance.hs` — an expiry-based row lease in
`keiro.keiro_workflows`; a live foreign lease skips the instance), re-invokes the
workflow through `runWorkflowWith`/`runChildWorkflow`, classifies the outcome into
an `AdvanceResult` (ok / transient store error / lease lost / crashed), updates a
`ResumeSummary`, and releases the lease in a `finally`. Concurrency across
*processes* is already safe: leases prevent duplicate steady-state work and the
per-step advisory lock plus in-transaction step-index check in
`Keiro.Workflow.prepareJournalAppend` serialize same-step writers (see
`docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`).
Nothing exploits that safety *within* one pass.

The crash path: when an advance crashes (`AdvCrashed`), `handleAttempt` runs
`recordCrashTx` (`keiro/src/Keiro/Workflow/Instance.hs`) — an
`UPDATE ... SET attempts = attempts + 1 ... WHERE ... AND status NOT IN
('completed','cancelled','failed') RETURNING attempts` decoded with
`D.singleRow`. If the workflow went terminal between the crash and this UPDATE
(for example a parent's `cancelChild` landed), zero rows return, `D.singleRow`
fails the statement, the resulting store error propagates out of `handleAttempt` —
which sits *outside* the per-advance catches — and the remainder of the pass's
candidates are skipped until the next tick. Self-healing but noisy, and one poisoned
race starves everyone behind it for a pass.

The timer worker is `keiro/src/Keiro/Timer.hs`. `runTimerWorkerWith` runs a
preamble (requeue stale `Firing` rows, record backlog/stuck gauges), claims *at
most one* due timer with `claimDueTimer` (a `FOR UPDATE SKIP LOCKED` single-row
claim that increments `attempts`), optionally dead-letters it past the attempt
ceiling, otherwise runs the caller's `fire` action and marks the timer `Fired`.
Draining a backlog of K due timers therefore costs K full invocations including K
preambles — with the workflow-sleep fire action
(`Keiro.Workflow.Sleep.workflowSleepFireAction`,
`runWorkflowTimerWorker` in the same module) this bounds how fast sleeping
workflows wake when many sleeps become due together. The sleep-timer lifecycle
contract is
`docs/adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md`;
nothing here may change fire semantics, only how many claims happen per pass.

The GC worker is `keiro/src/Keiro/Workflow/Gc.hs`. `gcWorkflowsOnce` selects
eligible terminal instances and `traverse`s `deleteWorkflow` over them; its summary
reports `deleted = length eligible` unconditionally (the traverse either fully
succeeds or throws). `runWorkflowGcWorker` is a bare `forever` with a
`threadDelay` — no catch of any kind, unlike the resume loop
(`runWorkflowResumeWorkerWith` catches `StoreError` and sync exceptions per pass)
— so the first transient error terminates the loop. No ADR governs worker loop
shape; the resume worker's per-pass isolation is the established in-repo
convention this plan extends. No new ADR is expected from this plan (per
`agents/skills/exec-plan/ADR.md`, that absence is stated deliberately); if
implementation reveals a durable decision, record it and update this section.

Concurrency substrate: `keiro` depends on `effectful >= 2.6 && < 2.7`
(`keiro/keiro.cabal`), which provides `Effectful.Concurrent` /
`Effectful.Concurrent.Async` (a `Concurrent` effect interpretable locally with
`runConcurrent`; its `mapConcurrently` clones the effect environment per thread).
The kiroku store handle behind the `Store` effect wraps a hasql connection pool
and is safe for concurrent use — the sharded subscription worker
(`Keiro.Subscription.Shard`) already runs concurrent store traffic in one process.
The `async`/`unliftio` packages are *not* dependencies; do not add them.

Tests are in `keiro/test/Main.hs`; `cabal test keiro-test` from the repository
root provisions ephemeral Postgres via `keiro-test-support`. Sibling-plan
boundaries (MasterPlan 30 Integration Points): this plan must not touch
`findUnfinishedWorkflowIdsStmt`, the suspend write, the sleep fire's wake-hint
clear (all owned by plan 200), `prepareJournalAppend`'s transaction body (plan
201), or id derivation (plan 202). If plan 200 has already landed, its narrowed
discovery changes none of this plan's edits; if it has not, the concurrency tests
here must not assert `discovered` counts that depend on it.


## Plan of Work

### Milestone 1 — crash-record race tolerance

In `keiro/src/Keiro/Workflow/Instance.hs`, change `recordCrashStmt`'s decoder from
`D.singleRow` to `D.rowMaybe` and `recordCrashTx`'s type to
`Text -> Text -> Text -> Tx.Transaction (Maybe Int32)` (Nothing = the workflow was
already terminal, nothing recorded). In `keiro/src/Keiro/Workflow/Resume.hs`,
`handleAttempt`'s `AdvCrashed` branch handles `Nothing` by logging a new
`ResumeLogEvent` constructor `ResumeCrashRecordSkipped !Text !Text` ("workflow
went terminal while its crash was being recorded; skipping") and counting the
instance under `transientErrors` without marking anything failed. `ResumeLogEvent`
is an exported sum type; note the additive constructor in `keiro/CHANGELOG.md`.

Test: suspend-free two-workflow scenario where workflow A's registry body throws
and, before the pass runs, A is cancelled via a child-row-free direct
`appendJournalEntry` of `WorkflowCancelled`… — simpler and deterministic: call
`recordCrashTx` directly against a cancelled instance and assert `Nothing`; then
an integration case where a pass containing a crashing-but-just-cancelled A and a
healthy B still completes B and reports one transient error. Acceptance: pass
completes; before the change the same scenario aborts the pass (assert the old
behavior once in the test comment, not in code).

### Milestone 2 — GC pass isolation and honest summary

In `keiro/src/Keiro/Workflow/Gc.hs`: give `deleteWorkflow` per-workflow error
isolation — catch synchronous exceptions and `StoreError` around each workflow's
deletion, return `Bool` success, and let `gcWorkflowsOnce` report
`deleted = length (filter id results)` with `scanned = length eligible` (the two
finally mean different things). Add `runWorkflowGcWorkerWith ::
(IOE :> es, Store :> es, Error StoreError :> es) => WorkflowGcPolicy -> Int ->
(Text -> IO ()) -> Eff es ()` whose loop catches `StoreError` and sync exceptions
per pass, logs through the supplied hook, and always sleeps and continues —
mirroring `runWorkflowResumeWorkerWith`'s shape in
`keiro/src/Keiro/Workflow/Resume.hs`. Keep `runWorkflowGcWorker` with its current
signature delegating with a default stderr logger; its constraint set gains
`Error StoreError :> es` — note in `keiro/CHANGELOG.md`.

Test: a GC pass over a mix where one eligible workflow's deletion is sabotaged
(delete its instance row out from under the pass mid-flight, or point
`hardDeleteStream` at an already-deleted stream — choose whatever
`keiro-test-support` makes deterministic) reports `scanned = 2, deleted = 1` and
the worker loop survives to a second pass. Partial-deletion recovery is already
converging by design (eligibility re-selects leftovers next pass); assert that
too: the sabotaged workflow is re-scanned on the following pass.

### Milestone 3 — batched timer drain

In `keiro/src/Keiro/Timer.hs`, factor the per-claim body of `runTimerWorkerWith`
(claim, ceiling check, dead-letter or fire, mark fired) into an internal helper,
then add `drainDueTimersWith :: (IOE :> es, Store :> es) => Maybe KeiroMetrics ->
TimerWorkerOptions -> UTCTime -> Int -> (TimerRow -> Eff es (Maybe EventId)) ->
Eff es Int` that runs the preamble (requeue + gauges) once and loops the claim
helper until it claims nothing or the batch limit is reached, returning the number
of timers processed. `runTimerWorkerWith` becomes `drainDueTimersWith` with limit
1 modulo return shape — keep its exact signature and semantics. In
`keiro/src/Keiro/Workflow/Sleep.hs`, add the parallel convenience
`drainWorkflowSleepTimers` mirroring `runWorkflowTimerWorker` (workflow-sleep fire
action with process-manager fallback) over the batch entry point. Per-claim
`fire_at`-ordering and at-least-once semantics are untouched; the histogram and
per-claim metrics record per claimed row exactly as today.

Test: schedule ten immediately-due timers (mixed workflow sleeps and plain PM
payloads), run one `drainDueTimersWith` pass with limit 20, assert all ten fired
(and the sleep completions journaled); run with limit 3 and assert exactly three
fired and seven remain claimable.

### Milestone 4 — bounded concurrent advancement

In `keiro/src/Keiro/Workflow/Resume.hs`: add `maxConcurrentAdvances :: !Int` to
`WorkflowResumeOptions` (default 1 in `defaultWorkflowResumeOptions`; document
that values above 1 multiply per-advance database traffic and should follow the
connection pool's headroom). Restructure `resumeWorkflowsOnce`'s drive loop: keep
discovery, dedupe, and the single pass-scoped `owner` UUID exactly as they are;
replace the `foldM` with per-candidate advancement that returns a *summary delta*
(a `ResumeSummary` for just that instance — the existing `advance` already
computes exactly this shape against `emptyResumeSummary`), run the candidates
through a bounded-concurrency map when `maxConcurrentAdvances > 1` (locally
`runConcurrent` + `Effectful.Concurrent.Async.mapConcurrently` over chunks, or a
`QSemN`-bounded `mapConcurrently` — implementer's choice; chunking is simpler and
adequate), and fold the deltas monoidally at the end (give `ResumeSummary` a
`Semigroup`/`Monoid` instance that adds fields, or a local `addSummary`). The
per-advance `finally`-release, catch classification, and `progressedRef` all stay
per-candidate and therefore thread-local. The `logEvent` hook may now be called
from multiple threads — document that requirement on the field's haddock
(`hPutStrLn stderr` interleaves but does not corrupt; users supplying fancier
hooks must make them thread-safe).

Keep the lease semantics untouched: each candidate is claimed with the same
pass-scoped owner; two *candidates* never share an instance (dedupe), so
concurrent claims here never contend with each other, only with other processes,
exactly as before.

Tests: (a) overlap — two workflows whose step actions sleep ~300 ms and record
wall-clock timestamps into an `MVar`; with `maxConcurrentAdvances = 2` assert
their execution windows overlap, with the default assert they do not (generous
tolerances; this is an ordering assertion, not a benchmark). (b) isolation under
concurrency — re-run the existing poison-workflow scenario (one crashing, one
healthy, see the current "isolates a poison workflow" example in
`keiro/test/Main.hs`) with concurrency 2 and assert the healthy workflow
completes and the summary matches the serial case. (c) summary associativity —
the folded summary equals the serial summary for a mixed pass (completed +
suspended + unknown-name).


## Concrete Steps

All commands run from the repository root.

```bash
cabal build keiro
cabal test keiro-test
```

Expected: `N examples, 0 failures`, N grown by the new examples. Commit per
milestone, for example:

```text
feat(workflow): advance resume candidates with bounded concurrency

MasterPlan: docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md
ExecPlan: docs/plans/203-concurrent-resume-passes-batched-timer-drain-and-worker-pass-robustness.md
Intention: intention_01kza6gjs5eg79n2hyrah7wnnn
```


## Validation and Acceptance

Acceptance is the four milestone tests plus an unchanged-defaults guarantee: with
`defaultWorkflowResumeOptions` (concurrency 1) and `runTimerWorkerWith`, every
pre-existing test passes unmodified, because every change is opt-in
(`maxConcurrentAdvances`, `drainDueTimersWith`) or strictly more tolerant
(crash-record race, GC isolation). The "beyond compilation" demonstrations: the
overlap test's timestamps, the ten-timer single-pass drain, and a resume pass that
survives the crash-record race while completing its other candidate.


## Idempotence and Recovery

Code-only; no migrations. All new behavior is opt-in or fail-soft, so rollback is
a revert. Concurrency bugs, if any surface later, are neutralized operationally by
setting `maxConcurrentAdvances = 1` without a deploy of old code.


## Interfaces and Dependencies

No new packages (concurrency via `effectful`'s `Effectful.Concurrent`, already a
dependency). End-state deltas: `WorkflowResumeOptions` gains
`maxConcurrentAdvances :: !Int`; `ResumeSummary` gains a
`Semigroup`/`Monoid` (or an internal `addSummary`); `ResumeLogEvent` gains
`ResumeCrashRecordSkipped`; `Keiro.Workflow.Instance.recordCrashTx` returns
`Maybe Int32`; `Keiro.Timer` gains `drainDueTimersWith`;
`Keiro.Workflow.Sleep` gains `drainWorkflowSleepTimers`; `Keiro.Workflow.Gc`
gains `runWorkflowGcWorkerWith` and `gcWorkflowsOnce` reports a truthful
`deleted`. Changed constraints and additive constructors are CHANGELOG items, not
silent edits.
