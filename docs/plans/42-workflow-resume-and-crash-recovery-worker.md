---
id: 42
slug: workflow-resume-and-crash-recovery-worker
title: "Workflow resume and crash-recovery worker"
kind: exec-plan
created_at: 2026-06-03T14:39:45Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
master_plan: "docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md"
---

# Workflow resume and crash-recovery worker

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan delivers the engine that makes "durable execution" actually durable across
crashes: a **background resume worker**. EP-38
(`docs/plans/38-workflow-journal-and-named-step-replay-core.md`) gave us a workflow that
journals each named step and, when re-invoked with the same id, replays — short-circuiting
steps already in the journal so their side effects do not re-run. But EP-38 only re-invokes
a workflow if *someone calls `runWorkflow` again*. Nothing in the runtime notices that a
workflow exists, has steps, and lacks a terminal `WorkflowCompleted` event — i.e. that it
crashed mid-run, or is parked on a `sleep`/`awakeable` whose wake source has now resolved.
This plan is what notices.

After this plan, an operator runs a worker that, on each pass, asks the database "which
workflows have steps but no completion?" (`findUnfinishedWorkflowIds`, EP-38), and for each
one re-invokes the workflow's function so it proceeds from its first un-journaled step. The
**observable promise**: drive a workflow to journal step 1 of 3, kill the process before it
finishes, restart, run `resumeWorkflowsOnce` against a registry that maps the workflow's
name to its full 3-step definition, and watch it reach `Completed` — with steps 2 and 3
running exactly once and step 1 *not* re-running (proven by a shared counter). And the
suspension case: a workflow suspended on a `sleep` or `awakeable`, once its wake source
resolves (the timer fires and journals `StepRecorded "sleep:.."`, or `signalAwakeable`
journals `StepRecorded "awk:.."`), is driven to `Completed` by the very next resume pass.

What a user gains that they could not before: a workflow no longer needs a bespoke caller to
restart it after a crash or a wake. A single long-lived worker — driven on a poll interval,
exactly like the existing outbox and timer workers — recovers every unfinished workflow in
the deployment. This is the operational piece that turns EP-38's "a step replays in-process"
into "the runtime resumes a crashed workflow on startup".

The central design problem this plan resolves: to re-invoke a workflow the worker needs the
workflow's *function* (the `Eff (Workflow : es) a` do-block) for a given workflow name — and
that function is **application code, not stored in the database**. The database holds the
journal (what already ran) but not the program (what to run next). So the worker takes an
application-supplied **registry** mapping each workflow name to its definition. That registry
shape (`WorkflowRegistry` / `WorkflowDef`) and the per-pass `ResumeSummary` are the two new
cross-plan contracts this plan introduces.

Term definitions used throughout (define-on-first-use, per the plan spec):

- *resume worker* — a background loop that discovers unfinished workflows and re-invokes
  each one so it proceeds. Modelled on the existing claim/process/poll worker shape in
  `keiro/src/Keiro/Outbox.hs` (`publishClaimedOutbox`) and `keiro/src/Keiro/Timer.hs`
  (`runTimerWorker`/`runTimerWorkerWith`).
- *unfinished workflow* — a workflow whose journal stream `wf:<name>-<id>` has at least one
  `StepRecorded` event but no terminal `WorkflowCompleted` event. EP-38's
  `findUnfinishedWorkflowIds` returns exactly these as `(workflow_id, workflow_name)` pairs
  by querying the `keiro_workflow_steps` index for rows lacking a
  `step_name = '__workflow_completed__'` row. **No kiroku `wf:` prefix subscription is used
  or needed** — discovery is this index query only.
- *registry* — the application-supplied `Map WorkflowName (WorkflowDef es)` telling the
  worker, for each workflow name, how to re-build the `Eff (Workflow : es) a` to re-invoke.
- *wake source* — an external mechanism (a fired durable `sleep` timer per EP-39, a signalled
  `awakeable` per EP-40, a finished child per EP-43) that resolves a `Suspended` workflow's
  await by journaling the awaited `StepRecorded`. The resume worker re-invokes the workflow
  so the now-resolved await takes its hit path and the workflow proceeds.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-06-03) — `Keiro.Workflow.Resume`: `WorkflowDef`/`WorkflowRegistry` (existential
  over the result type), `WorkflowResumeOptions` (carrying EP-41's `WorkflowRunOptions`, a poll
  interval, and a *reserved* `useAdvisoryLock`), `ResumeSummary`/`emptyResumeSummary`, and
  `resumeWorkflowsOnce`. Added to `keiro.cabal` exposed-modules; `cabal build keiro` green.
- [x] M2 (2026-06-03) — Crash-mid-run proof: a 3-step workflow journals step 1 then throws
  `SimulatedCrash` (caught by the test); `resumeWorkflowsOnce` with the full 3-step definition
  drives it to `Completed`; counter reads 3 (step 1 short-circuited, steps 2-3 ran once); the
  journal holds s1/s2/s3/WorkflowCompleted; a second pass returns `emptyResumeSummary`.
- [x] M3 (2026-06-03) — Suspension-driven proof: a workflow suspends on `awaitStep "awk:approval"`,
  a manual `appendJournalEntry (StepRecorded "awk:approval" ...)` resolves it, and one resume
  pass reaches `Completed` (`use` step ran once). EP-39/EP-40 wake sources journal the *same*
  `StepRecorded`, so this becomes an end-to-end test verbatim once they drive it.
- [x] M4 (2026-06-03) — Unknown-name + idempotency proofs: an empty registry skips an orphan
  workflow, logs it, and counts `unknownName = 1` with the journal unchanged; resume on an
  already-completed workflow returns `emptyResumeSummary` and is stable across two passes
  (counter unchanged).
- [x] M5 (2026-06-03) — `runWorkflowResumeWorker`/`runWorkflowResumeWorkerWith` loop drivers and
  the Haddock contract recap (for EP-43/EP-44) shipped in `Keiro.Workflow.Resume`. Full
  `cabal test keiro` green (123 examples, 0 failures); `cabal build all` (incl. jitsurei) green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (M1): **The `useAdvisoryLock` advisory-lock path is not implementable as the plan
  described it, and is shipped reserved (a no-op).** The plan proposed wrapping each
  re-invocation in a transaction holding `pg_try_advisory_xact_lock(hashtext(id))`. But a
  re-invocation (`runWorkflowWith`) spans *several* transactions — one `runTransactionAppending`
  per step append — and the kiroku `Store` is backed by a `Hasql.Pool`
  (`kiroku-store/src/Kiroku/Store/Connection.hs`), so: (a) a *transaction-scoped*
  `pg_try_advisory_xact_lock` releases when its own probe transaction commits, long before the
  run's later transactions, giving zero mutual exclusion across the run; and (b) a
  *session-scoped* `pg_advisory_lock` has no connection affinity through the pool, so a lock
  taken on one pooled connection is invisible to the next transaction's connection. Holding a
  lock across the whole run is therefore not achievable with the pooled Store. Resolution: keep
  the `useAdvisoryLock` field (default `False`) for forward compatibility but leave it
  **unwired** with a Haddock note, because concurrency is already safe by construction —
  EP-38's deterministic step ids + pre-load short-circuit mean two workers racing the same
  workflow converge to the same journal with each side effect at most once (the
  idempotency-first decision below). EP-44/EP-45 should not document the lock as functional.
- 2026-06-03 (M2): **`StoreError` is `Kiroku.Store.StoreError`** — the test annotates the
  `try` result as `Either SomeException (Either Store.StoreError (WorkflowOutcome ...))`. A
  `SimulatedCrash` thrown inside the body propagates as an ordinary IO exception through
  `Store.runStoreIO` (it is not a `StoreError`), so `try @SomeException` catches it while the
  step-1 append — committed in its own prior transaction — survives, exactly the crash-mid-run
  state the resume worker must recover.
- 2026-06-03 (M5): the **umbrella `Keiro` module does not re-export workers** (Timer, Outbox,
  etc. are imported directly), so `Keiro.Workflow.Resume` is intentionally *not* added to
  `Keiro.hs` — matching the established convention rather than the plan's conditional.


## Decision Log

Record every decision made while working on the plan.

- Decision: The resume worker takes an application-supplied registry
  `type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)` where
  `data WorkflowDef es = forall a. WorkflowDef { runDef :: WorkflowId -> Eff (Workflow : es) a }`,
  rather than trying to reconstruct a workflow's function from the database.
  Rationale: A workflow's body is application Haskell code; only its *journal* (the recorded
  results) is in the database. The worker can replay-short-circuit a journal only if it has
  the function to replay through. The registry is the minimal, honest way to supply that:
  the application owns the mapping from name to definition, exactly as it owns the `fire`
  action it hands `runTimerWorker`. The existential over the result type `a` lets one
  registry hold workflows of differing return types; the worker discards the result (it cares
  only about `Completed` vs `Suspended`), so the hidden `a` never needs to escape.
  Date: 2026-06-03.

- Decision: Discover unfinished workflows via EP-38's `findUnfinishedWorkflowIds` (the
  `keiro_workflow_steps` index "lacks `__workflow_completed__`" query) — **never** a kiroku
  `wf:` prefix subscription.
  Rationale: This MasterPlan's Decision Log and Surprises both fix this: prefix subscriptions
  are an open upstream item (`docs/research/11-upstream-roadmap.md`); routing discovery
  through the already-existing index keeps this initiative free of any upstream dependency.
  The index exists for the hot-path step lookup, so reusing it for discovery adds no storage.
  Date: 2026-06-03.

- Decision: Default concurrency strategy is **rely on idempotency** (option (a)), not a
  Postgres advisory lock (option (b)).
  Rationale: Re-invoking the same workflow concurrently from two workers is already *safe*
  because EP-38 journals each step under a deterministic event id (`DuplicateEvent`-as-
  success) and short-circuits already-journaled steps — two racing runs converge to the same
  journal with no double side effect. Idempotency is therefore the correct default and costs
  nothing. A per-workflow `pg_try_advisory_xact_lock(hashtext(workflow_id))` is offered as a
  documented *optimization* to let multiple worker processes claim disjoint workflows and
  avoid wasted re-invocation, but it is not required for correctness and is left as an opt-in
  flag (`useAdvisoryLock`) defaulting to off. Picking idempotency-first matches how
  EP-38's deterministic-id journaling already makes the whole runtime race-tolerant.
  Date: 2026-06-03.

- Decision (revised 2026-06-03 during M1): The `useAdvisoryLock` option is **reserved and
  unwired**, not the transaction-scoped lock the original decision described.
  Rationale: implementation revealed the pooled `Store` plus the multi-transaction shape of a
  re-invocation makes a lock-held-across-the-run impossible (see Surprises & Discoveries
  2026-06-03 M1). Since the idempotency-first decision already guarantees correctness under
  concurrent workers, the lock was only ever an optimization; rather than ship a misleading
  no-op-with-overhead, the flag is kept for forward compatibility (default `False`) and has no
  effect. If a future change pins a connection per workflow run, the flag can be wired then.
  Date: 2026-06-03.

- Decision: Re-invoke through EP-41's `runWorkflowWith :: WorkflowRunOptions -> ...` (carried
  inside `WorkflowResumeOptions`) so resumed workflows honor the same snapshot/telemetry
  options as their first run; fall back to `runWorkflow` only if EP-41 has not landed at
  implementation time, and record the upgrade as a follow-up.
  Rationale: A resumed workflow must behave identically to its in-process counterpart —
  same snapshot policy (EP-41), same telemetry handle (EP-44). Threading a
  `WorkflowRunOptions` through `WorkflowResumeOptions` keeps that guarantee in one place and
  matches the options-record convention `runTimerWorkerWith` already uses.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-03.** All five milestones landed; `cabal test keiro` is green (123
examples, 0 failures, incl. 4 new resume tests) and `cabal build all` (incl. jitsurei) is
green. The purpose — make durable execution durable across crashes via a background worker
that discovers and re-invokes unfinished workflows — is met:

- `keiro/src/Keiro/Workflow/Resume.hs` owns `WorkflowDef`/`WorkflowRegistry`,
  `WorkflowResumeOptions`/`defaultWorkflowResumeOptions`, `ResumeSummary`/`emptyResumeSummary`,
  the single-pass `resumeWorkflowsOnce`, and the `runWorkflowResumeWorker(With)` poll-loop
  drivers. No new table, no migration; discovery is EP-38's `findUnfinishedWorkflowIds` index
  query only — **no kiroku `wf:` prefix subscription** anywhere (zero upstream dependency).
- Re-invocation goes through EP-41's `runWorkflowWith` carrying `runOptions`, so resumed runs
  honour the same snapshot/telemetry options as their first run.

**Observable validations (all green):** crash-mid-run recovery (counter proves step 1 did not
re-run; journal ends in `WorkflowCompleted`; second pass discovers 0); suspension-driven
recovery (suspended → journaled await → `Completed`, `use` step ran once); unknown-name
visibility (`unknownName = 1`, journal unchanged); idempotency/no-op on a completed workflow
(stable across two passes).

**Cross-plan contracts delivered:** `WorkflowRegistry`/`WorkflowDef` (consumed by EP-43's
parent resumption) and `ResumeSummary` (consumed by EP-44's `keiro.workflow.resumed`). EP-44
may thread a `Maybe KeiroMetrics` into `WorkflowResumeOptions`/`resumeWorkflowsOnce` following
the no-op-under-`Nothing` idiom.

**Gaps / deferred:** the `useAdvisoryLock` multi-worker optimization is reserved/unwired — the
pooled `Store` cannot hold a lock across a re-invocation's several transactions, and
idempotency already makes concurrent re-invocation correct (see Surprises & Decision Log). The
suspension test simulates the wake source via `appendJournalEntry`; it upgrades to an
end-to-end EP-39/EP-40 test with no assertion changes once those drive it.


## Context and Orientation

The working tree is at `/Users/shinzui/Keikaku/bokuno/keiro`. The library packages are
`keiro-core` (pure contracts), `keiro` (the runtime), `keiro-migrations` (embedded SQL),
`keiro-test-support` (PostgreSQL test fixtures), and `jitsurei` (worked examples). This plan
adds **one** new module to the `keiro` package — `Keiro.Workflow.Resume` — and **no**
migration (it reuses EP-38's `keiro_workflow_steps` index). It is in MasterPlan 5's Wave 3:
it hard-depends on EP-38 and soft-depends on EP-39/EP-40.

You will build on these existing and EP-38 pieces. Read them before starting; line numbers
are guides, not guarantees.

**EP-38's consumed surface (the contracts this plan stands on),** from
`docs/plans/38-workflow-journal-and-named-step-replay-core.md`:

```haskell
-- Keiro.Workflow.Types
newtype WorkflowName = WorkflowName Text
newtype WorkflowId   = WorkflowId Text
data WorkflowOutcome a = Completed a | Suspended      -- result of runWorkflow
completedStepName :: Text                             -- "__workflow_completed__"

-- Keiro.Workflow.Schema
findUnfinishedWorkflowIds :: (Store :> es) => Eff es [(Text, Text)]   -- (workflow_id, workflow_name)

-- Keiro.Workflow
data Workflow :: Effect
runWorkflow        :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
appendJournalEntry :: (Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()
```

`findUnfinishedWorkflowIds` is the discovery seam — it returns every `(workflow_id,
workflow_name)` that has step rows but no `completedStepName` row. `runWorkflow` re-invokes a
workflow: on a journal that already holds steps, each `step`/`awaitStep` hits its recorded
result and short-circuits, so re-invocation is cheap and runs only the un-journaled tail. Its
outcome is `Completed a` (now finished, a `WorkflowCompleted` was journaled) or `Suspended`
(still parked on an unresolved await — fine, it will be retried next pass). EP-38's M3 test
already demonstrates the manual `appendJournalEntry (StepRecorded "awk:test" ...)` →
`runWorkflow` → `Completed` cycle this plan automates.

**The `WorkflowRunOptions` / `runWorkflowWith` contract (EP-41).** EP-41
(`docs/plans/41-workflow-journal-snapshots-and-step-result-compaction.md`) introduces

```haskell
data WorkflowRunOptions    -- carries snapshotPolicy and (via EP-44) a Maybe KeiroMetrics
defaultWorkflowRunOptions :: WorkflowRunOptions
runWorkflowWith :: (IOE :> es, Store :> es) => WorkflowRunOptions -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
```

This plan re-invokes through `runWorkflowWith` and carries a `WorkflowRunOptions` inside its
own `WorkflowResumeOptions` so resumed workflows honor the same snapshot/telemetry behaviour.
**If EP-41 has not landed when you implement this**, define `WorkflowResumeOptions` without
the `runOptions` field, call EP-38's plain `runWorkflow`, and add a one-line note in
Surprises & Discoveries recording the upgrade to `runWorkflowWith` once EP-41 lands. Do not
block on EP-41.

**The worker-loop pattern to copy.** Two existing workers establish the shape this plan
mirrors:

- `keiro/src/Keiro/Outbox.hs` — `publishClaimedOutbox` does one pass (claim a batch, process
  each row, record a summary) and **returns** an `OutboxPublishSummary`; the application
  loops it on an interval. It does not loop indefinitely itself.
- `keiro/src/Keiro/Timer.hs` — `runTimerWorker` / `runTimerWorkerWith` does one pass (claim
  one due timer, fire it) and returns the claimed row; `runTimerWorkerWith` takes an options
  record (`TimerWorkerOptions`) and `runTimerWorker` is the defaulted convenience wrapper.
  Note both take a `Maybe KeiroMetrics` as an explicit argument (the no-op-under-`Nothing`
  idiom MasterPlan 4 settled on).

This plan follows both: `resumeWorkflowsOnce` is the single-pass worker (like
`publishClaimedOutbox`); `runWorkflowResumeWorker` / `runWorkflowResumeWorkerWith` is the
options-driven loop driver (like the timer pair). The loop body sleeps on an interval and
re-runs `resumeWorkflowsOnce`, exactly as an application schedules `publishClaimedOutbox` per
tick.

**The effect rows.** The worker runs in `Eff es` where `es` provides `IOE` and `Store`. The
registry's `WorkflowDef` carries an `Eff (Workflow : es) a` — i.e. the workflow body in the
**same** base row `es` plus the `Workflow` effect on top, which is exactly what `runWorkflow`
peels off (`Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)`). The base row `es` is a
type parameter of `WorkflowRegistry es`; the application chooses it (typically `[Store, IOE]`
plus whatever its steps need).

**Why a registry, restated.** The database row for an unfinished workflow tells the worker
its *name* and *id*. To re-invoke it the worker must turn the name into a function
`WorkflowId -> Eff (Workflow : es) a`. There is no way to materialize a closure from a
string, so the application registers the mapping. This is structurally identical to how the
timer worker takes a caller-supplied `fire :: TimerRow -> Eff es (Maybe EventId)` — the
worker owns the loop and the database access; the application owns the domain behaviour.


## Plan of Work

Five milestones. Each is independently verifiable; commit after each. The only production
module is `keiro/src/Keiro/Workflow/Resume.hs`; M2–M4 are tests in `keiro/test/Main.hs`.

### Milestone 1 — `Keiro.Workflow.Resume`: types, options, and `resumeWorkflowsOnce`

Create `keiro/src/Keiro/Workflow/Resume.hs`. Define the registry, options, summary, and the
single-pass worker.

The registry and definition (the new cross-plan contract — export them):

```haskell
-- | How to re-build a workflow's body from its id, for one workflow name.
-- The result type @a@ is existential: the worker discards it (it cares only
-- whether the run reached 'Completed' or 'Suspended'), so one registry can
-- hold workflows of different return types.
data WorkflowDef es = forall a. WorkflowDef
  { runDef :: WorkflowId -> Eff (Workflow : es) a
  }

-- | Application-supplied map from workflow name to its definition. The worker
-- looks up each discovered workflow's name here; an absent name is skipped
-- and counted as 'unknownName' (a deploy that dropped a workflow while
-- instances were still in flight — surfaced, not silently lost).
type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)
```

The options record (mirrors `TimerWorkerOptions`, but carries the run options and the loop
interval):

```haskell
data WorkflowResumeOptions = WorkflowResumeOptions
  { runOptions      :: !WorkflowRunOptions   -- ^ snapshot/telemetry options, threaded into runWorkflowWith
  , pollInterval    :: !Int                  -- ^ microseconds between passes for the loop driver
  , useAdvisoryLock :: !Bool                 -- ^ opt-in pg_try_advisory_xact_lock per workflow id (default False)
  }
  deriving stock (Generic)

defaultWorkflowResumeOptions :: WorkflowResumeOptions
defaultWorkflowResumeOptions = WorkflowResumeOptions
  { runOptions      = defaultWorkflowRunOptions  -- from EP-41; see fallback note below
  , pollInterval    = 1_000_000                  -- 1 second
  , useAdvisoryLock = False
  }
```

> If EP-41 has not landed, drop the `runOptions` field (and the `defaultWorkflowRunOptions`
> reference), have `resumeWorkflowsOnce` call EP-38's `runWorkflow`, and record the upgrade in
> Surprises & Discoveries. Everything else in this plan is unchanged.

The per-pass summary (the second new cross-plan contract — EP-44 reads it for the
`keiro.workflow.resumed` instrument):

```haskell
data ResumeSummary = ResumeSummary
  { discovered     :: !Int  -- ^ unfinished workflows findUnfinishedWorkflowIds returned this pass
  , resumed        :: !Int  -- ^ workflows re-invoked (found in the registry and run)
  , completed      :: !Int  -- ^ re-invocations that reached 'Completed' this pass
  , stillSuspended :: !Int  -- ^ re-invocations that returned 'Suspended' (wake source not yet resolved)
  , unknownName    :: !Int  -- ^ discovered workflows whose name was absent from the registry (skipped + logged)
  }
  deriving stock (Generic, Eq, Show)

emptyResumeSummary :: ResumeSummary
emptyResumeSummary = ResumeSummary 0 0 0 0 0
```

Then `resumeWorkflowsOnce` — one discover-and-reinvoke pass:

```haskell
resumeWorkflowsOnce ::
  forall es.
  (IOE :> es, Store :> es) =>
  WorkflowResumeOptions ->
  WorkflowRegistry es ->
  Eff es ResumeSummary
```

Algorithm:

1. Call `findUnfinishedWorkflowIds` → `[(Text, Text)]` of `(workflow_id, workflow_name)`.
   Seed `acc = emptyResumeSummary { discovered = length pairs }`.
2. Fold over the pairs. For each `(widText, wnameText)`:
   - Look up `WorkflowName wnameText` in the registry.
   - **Absent:** log a warning ("resume worker: no registry entry for workflow %s (id %s);
     skipping") and increment `unknownName`. Continue. (A workflow whose code was removed
     while instances were in flight must be visible, not silently dropped.)
   - **Present (`WorkflowDef runDef`):** let `wid = WorkflowId widText`. Re-invoke through
     `runWorkflowWith (runOptions opts) (WorkflowName wnameText) wid (runDef wid)`. The
     journal pre-load short-circuits every already-journaled step, so only the un-journaled
     tail actually runs. Inspect the `WorkflowOutcome a`:
     - `Completed _` → increment `resumed` and `completed`.
     - `Suspended`   → increment `resumed` and `stillSuspended` (the workflow re-armed its
       wake source and parked again; next pass retries once the wake source resolves).
   - When `useAdvisoryLock` is `True`, wrap the per-workflow re-invocation in a transaction
     that first runs `SELECT pg_try_advisory_xact_lock(hashtext($1))` with `$1 = widText`;
     if the lock is not acquired (another worker holds it), skip this workflow this pass
     **without** counting it as resumed (it is being handled elsewhere). The advisory lock is
     transaction-scoped so it releases automatically. This branch is the documented
     optimization; the default `False` path takes no lock and relies on EP-38's idempotent
     journaling for safety.
3. Return the accumulated `ResumeSummary`.

`runWorkflowWith`'s outcome carries the hidden existential `a` from `WorkflowDef`; since the
worker only matches `Completed`/`Suspended` and discards the payload, the existential never
escapes — pattern-match it locally inside the fold (use a small helper
`bumpForOutcome :: WorkflowOutcome a -> ResumeSummary -> ResumeSummary` that ignores the `a`).

Logging: use whatever lightweight logging the package already uses in workers (grep
`Keiro.Outbox`/`Keiro.Timer` for how they surface warnings; if they simply rely on the
caller, a `liftIO (hPutStrLn stderr ...)` behind the `unknownName` branch is acceptable and
testable by asserting the count rather than the text).

Acceptance for M1: `cabal build keiro` succeeds with `Keiro.Workflow.Resume` added to
`exposed-modules`; the module exports `WorkflowDef`, `WorkflowRegistry`,
`WorkflowResumeOptions`, `defaultWorkflowResumeOptions`, `ResumeSummary`,
`emptyResumeSummary`, and `resumeWorkflowsOnce`.

### Milestone 2 — Crash-mid-run resume proof

Add a DB-backed test group to `keiro/test/Main.hs` (the single exitcode-stdio suite that
runs against an ephemeral PostgreSQL database via `keiro-test-support`; use the suite-level
template-database fixture per the project memory, matching the existing timer/outbox/snapshot
groups).

Define a 3-step workflow keyed on a shared `IORef Int` counter, where each step does
`liftIO (modifyIORef' counter (+1)) >> liftIO (readIORef counter)`:

```haskell
threeStep :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es (Int, Int, Int)
threeStep counter = do
  a <- step (StepName "s1") (bump counter)
  b <- step (StepName "s2") (bump counter)
  c <- step (StepName "s3") (bump counter)
  pure (a, b, c)
  where bump r = liftIO (modifyIORef' r (+1) >> readIORef r)
```

Simulate a crash after step 1: run a *truncated* workflow that performs only `step "s1"` and
then throws (caught by the test) — OR, simpler and deterministic, run a one-step workflow
`step (StepName "s1") (bump counter) >> someAbort` whose `someAbort` is an `error`/`throwIO`
the test catches *after* the `s1` append committed, leaving the journal with one
`StepRecorded "s1"` and no `WorkflowCompleted`. (EP-38 commits each step's append in its own
transaction, so the journal genuinely holds `s1` even though the run did not finish.)

Then build the registry mapping the workflow's name to the **full** `threeStep` definition
and run one resume pass:

```haskell
let registry = Map.singleton (WorkflowName "crash-demo")
                 (WorkflowDef (\_wid -> threeStep counter))
summary <- resumeWorkflowsOnce defaultWorkflowResumeOptions registry
```

Assert:

- The counter is `3` (step 1 ran during the crash run; steps 2 and 3 ran during resume; step
  1 did **not** re-run — it short-circuited to its recorded result).
- `summary` has `discovered = 1`, `resumed = 1`, `completed = 1`, `stillSuspended = 0`,
  `unknownName = 0`.
- Reading the journal `wf:crash-demo-<wid>` back shows exactly four events: `StepRecorded
  "s1"`, `StepRecorded "s2"`, `StepRecorded "s3"`, `WorkflowCompleted`.
- A **second** `resumeWorkflowsOnce` returns `discovered = 0` (the workflow now has a
  `__workflow_completed__` index row, so `findUnfinishedWorkflowIds` no longer lists it).

Acceptance for M2: the test is green in `cabal test keiro` and the counter assertion proves
no side effect re-ran.

### Milestone 3 — Suspension-driven resume proof

This milestone proves the second half of the promise: a workflow suspended on a wake source
is driven to `Completed` once that source resolves. Because EP-39/EP-40 are *soft* deps, the
test uses the EP-38 simulation technique (manual `appendJournalEntry`) so it does not block on
them, and notes that it is strengthened once a real wake source lands.

Define a workflow that awaits before finishing:

```haskell
awaiting :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Text
awaiting counter = do
  decision <- awaitStep (StepName "awk:approval") (pure ())   -- never-arming arm; EP-38 suspends here
  _ <- step (StepName "use") (liftIO (modifyIORef' counter (+1)) >> pure (decision <> "!"))
  pure (decision <> "-done")
```

First run suspends:

```haskell
out0 <- runWorkflowWith defaultWorkflowRunOptions (WorkflowName "await-demo") wid (awaiting counter)
-- out0 == Suspended ; journal has no WorkflowCompleted
```

Now simulate the wake source resolving (exactly as EP-38's M3 test does — when EP-40 has
landed, replace this with `signalAwakeable aid "ok"`):

```haskell
appendJournalEntry (WorkflowName "await-demo") wid
  (StepRecorded { stepName = "awk:approval", result = toJSON ("ok" :: Text), recordedAt = now })
```

Run a resume pass with the registry:

```haskell
let registry = Map.singleton (WorkflowName "await-demo")
                 (WorkflowDef (\_wid -> awaiting counter))
summary <- resumeWorkflowsOnce defaultWorkflowResumeOptions registry
```

Assert: `summary` has `discovered = 1`, `resumed = 1`, `completed = 1`; the counter is `1`
(the `use` step ran exactly once); the journal now holds `WorkflowCompleted`. Add a one-line
comment in the test recording that this becomes an end-to-end EP-39 (timer fires →
`StepRecorded "sleep:.."`) or EP-40 (`signalAwakeable` → `StepRecorded "awk:.."`) test once
those plans land; the suspension-aware assertions are unchanged.

Acceptance for M3: the test is green; the suspend → external-completion → resume-worker cycle
reaches `Completed` with no wake-source plan required.

### Milestone 4 — Unknown-name and idempotency proofs

Two small tests in the same group:

- **Unknown name:** journal a workflow named `"orphan"` with one un-completed step (reuse the
  M2 crash technique). Run `resumeWorkflowsOnce` with an **empty** registry. Assert `summary`
  has `discovered = 1`, `resumed = 0`, `completed = 0`, `unknownName = 1`, and the journal is
  unchanged (no `WorkflowCompleted`) — the worker surfaced the orphan rather than completing
  or crashing on it.
- **Idempotency / no-op on completed:** run the M2 `threeStep` workflow straight through to
  `Completed` via `runWorkflowWith` (no crash). Then `resumeWorkflowsOnce` returns `discovered
  = 0` and a counter unchanged from the original run — a completed workflow is not in
  `findUnfinishedWorkflowIds`, so resume is a genuine no-op. Run it twice to confirm stability.

Acceptance for M4: both tests green; the unknown-name path is observable via the
`unknownName` count.

### Milestone 5 — Loop driver, cabal wiring, contract recap

Add the loop driver that production uses, mirroring the `runTimerWorker`/`runTimerWorkerWith`
pair:

```haskell
-- | Poll-and-resume loop. Runs 'resumeWorkflowsOnce' on the configured interval
-- forever. Mirrors how an application schedules 'publishClaimedOutbox' /
-- 'runTimerWorker' per tick; kept as a convenience so callers do not re-implement
-- the sleep loop. The single-pass 'resumeWorkflowsOnce' remains the testable unit.
runWorkflowResumeWorkerWith ::
  (IOE :> es, Store :> es) =>
  WorkflowResumeOptions ->
  WorkflowRegistry es ->
  Eff es ()
runWorkflowResumeWorkerWith opts registry = forever $ do
  _summary <- resumeWorkflowsOnce opts registry
  liftIO (threadDelay (pollInterval opts))

runWorkflowResumeWorker ::
  (IOE :> es, Store :> es) =>
  WorkflowRegistry es ->
  Eff es ()
runWorkflowResumeWorker = runWorkflowResumeWorkerWith defaultWorkflowResumeOptions
```

(If you want the loop to surface its per-pass summaries — e.g. for EP-44 metrics — accept an
optional `ResumeSummary -> Eff es ()` callback or thread a `Maybe KeiroMetrics` argument
exactly as `runTimerWorkerWith` does; record the choice in the Decision Log. The minimal
version above is sufficient for this plan; EP-44 reconciles the metrics threading.)

Then:

- Add `Keiro.Workflow.Resume` to the `exposed-modules` stanza in `keiro/keiro.cabal` (append
  after EP-38's `Keiro.Workflow.*` entries; do not reorder the existing list — sibling plans
  append their own modules to the same stanza and minimal diffs avoid merge churn, per the
  MasterPlan's module-layout integration point).
- If `Keiro` (the umbrella module, `keiro/src/Keiro.hs`) re-exports the other workers, add
  the resume surface there to match the convention.
- Write a Haddock contract-recap block at the top of `Keiro.Workflow.Resume` summarizing for
  EP-43/EP-44: the `WorkflowDef`/`WorkflowRegistry` shape, `WorkflowResumeOptions`,
  `ResumeSummary` (and its fields), `resumeWorkflowsOnce`, and the loop drivers — plus the
  note that EP-43 (child workflows) relies on this worker to wake a parent when a child
  completes (the child's completion journals the parent's awaited `child:` step; the next
  resume pass re-invokes the parent), and EP-44 reads `ResumeSummary` for
  `keiro.workflow.resumed`.

Acceptance for M5: full `cabal test keiro` green; `cabal build all` (including jitsurei)
green; the contract recap is present.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. Use the project's
toolchain (the repo builds with `cabal` under a Nix-provided GHC).

```bash
# M1
$EDITOR keiro/src/Keiro/Workflow/Resume.hs        # registry, options, summary, resumeWorkflowsOnce
$EDITOR keiro/keiro.cabal                           # add Keiro.Workflow.Resume to exposed-modules
cabal build keiro

# M2–M4 (tests)
$EDITOR keiro/test/Main.hs                          # add the resume-worker test group
cabal test keiro

# M5
$EDITOR keiro/src/Keiro/Workflow/Resume.hs        # add runWorkflowResumeWorker / *With loop driver + Haddock recap
$EDITOR keiro/src/Keiro.hs                          # re-export if that is the package convention
cabal test keiro
cabal build all
```

Expected `cabal test keiro` transcript fragment once the group is green (names illustrative;
match the suite's `tasty`/`hspec` style):

```text
Workflow resume worker
  crash-mid-run: resumes to Completed, steps 2-3 run once, step 1 does not re-run:    OK
  crash-mid-run: a second pass is a no-op (workflow no longer unfinished):            OK
  suspension: an awaited workflow reaches Completed after the wake source resolves:   OK
  unknown name: an orphan workflow is skipped and counted, journal unchanged:         OK
  idempotency: resume on a completed workflow discovers nothing:                      OK

All N tests passed
```

The test suite is a single `keiro/test/Main.hs` (exitcode-stdio) that runs against an
ephemeral PostgreSQL database via `keiro-test-support`. Acquire a store and apply
`allKeiroMigrations` the way the existing timer/outbox/snapshot groups do, using the
suite-level template-database fixture (project memory: do not migrate per example).


## Validation and Acceptance

The plan is accepted when `cabal test keiro` is green and the resume behaviour is observable:

- **Crash-mid-run recovery (the headline):** a workflow with step 1 of 3 journaled and no
  `WorkflowCompleted`, after one `resumeWorkflowsOnce` with a registry of its full
  definition, reaches `Completed`; the shared counter reads `3` (steps 2 and 3 ran, step 1
  did **not** re-run); the journal holds four events ending in `WorkflowCompleted`.
- **Suspension-driven recovery:** a workflow that returned `Suspended` on an awaited step,
  once that step's completion is journaled (manually for now, or by an EP-39/EP-40 wake
  source once landed), is driven to `Completed` by the next resume pass; the post-await step
  ran exactly once.
- **Discovery is index-only:** the worker finds unfinished workflows purely through
  `findUnfinishedWorkflowIds` (the `keiro_workflow_steps` "lacks `__workflow_completed__`"
  query) — there is no kiroku `wf:` prefix subscription anywhere in the implementation
  (assert by inspection / grep; no subscription API is imported).
- **Unknown-name visibility:** a discovered workflow whose name is absent from the registry
  is counted in `unknownName` and logged, not silently dropped or fatal.
- **Idempotency / no-op:** `resumeWorkflowsOnce` on an already-completed workflow returns a
  summary with `discovered = 0` and changes nothing; running it twice is stable.

Capture the green test transcript in this section's final revision as evidence.


## Idempotence and Recovery

The resume worker is idempotent by construction and safe to re-run at any cadence:

- **Re-invoking an unfinished workflow is idempotent.** EP-38 journals each step under a
  deterministic event id and treats kiroku's `DuplicateEvent` as success, and the replay
  pre-load short-circuits already-journaled steps. So a workflow that is re-invoked twice — by
  two passes, or by two worker processes racing — converges to the same journal with each
  side effect run at most once. No advisory lock is required for correctness (see the
  concurrency decision); the optional `useAdvisoryLock = True` path is a pure optimization
  that lets multiple processes partition the unfinished set and avoid wasted re-invocation,
  and a transaction-scoped `pg_try_advisory_xact_lock` releases automatically on commit or
  crash.
- **A pass that crashes partway is safe to repeat.** `resumeWorkflowsOnce` holds no state
  between workflows beyond the in-memory summary; a crashed pass simply leaves some workflows
  un-advanced, and the next pass rediscovers and re-invokes them. There is nothing to roll
  back.
- **A `Suspended` outcome is not an error.** It means the workflow re-armed its wake source
  and parked again; the worker counts it `stillSuspended` and moves on. The next pass retries
  it once the wake source resolves. The `arm` action EP-39/EP-40/EP-43 supply is required by
  EP-38 to be idempotent, so re-arming on every resume collapses to a no-op.
- **Completed workflows drop out of discovery automatically** — once a workflow journals
  `WorkflowCompleted` it has a `__workflow_completed__` index row and
  `findUnfinishedWorkflowIds` no longer returns it, so the worker never touches it again.
- **The template-database fixture** gives each suite run a fresh database, so tests that leave
  workflow journals behind need no manual cleanup.


## Interfaces and Dependencies

Libraries/modules used and why: `effectful` (`Eff`/`IOE`/`(:>)`, the `Workflow` effect from
EP-38); `Keiro.Workflow` and `Keiro.Workflow.Types` and `Keiro.Workflow.Schema` from EP-38
(`runWorkflow`/`runWorkflowWith`, `findUnfinishedWorkflowIds`, `WorkflowOutcome`,
`WorkflowName`/`WorkflowId`, `appendJournalEntry`, `completedStepName`); kiroku's `Store`
effect re-exported by Keiro (transactions for the optional advisory lock); `containers`
(`Map` for the registry); `base` (`Control.Monad.forever`, `Control.Concurrent.threadDelay`,
`Data.IORef` in tests). No new migration and no new table — the worker reuses EP-38's
`keiro_workflow_steps` index for discovery.

Types, signatures, and modules that must exist at the end of this plan (the contracts EP-43
and EP-44 consume — keep these stable):

```haskell
-- Keiro.Workflow.Resume
data WorkflowDef es = forall a. WorkflowDef { runDef :: WorkflowId -> Eff (Workflow : es) a }
type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)

data WorkflowResumeOptions = WorkflowResumeOptions
  { runOptions :: WorkflowRunOptions, pollInterval :: Int, useAdvisoryLock :: Bool }   -- runOptions omitted if EP-41 unlanded
defaultWorkflowResumeOptions :: WorkflowResumeOptions

data ResumeSummary = ResumeSummary
  { discovered :: Int, resumed :: Int, completed :: Int, stillSuspended :: Int, unknownName :: Int }
emptyResumeSummary :: ResumeSummary

resumeWorkflowsOnce         :: (IOE :> es, Store :> es) => WorkflowResumeOptions -> WorkflowRegistry es -> Eff es ResumeSummary
runWorkflowResumeWorkerWith :: (IOE :> es, Store :> es) => WorkflowResumeOptions -> WorkflowRegistry es -> Eff es ()
runWorkflowResumeWorker     :: (IOE :> es, Store :> es) => WorkflowRegistry es -> Eff es ()
```

Downstream consumers and what they take from here:

- EP-43 (child workflows): relies on this worker to wake a parent once a child finishes —
  the child's completion journals the parent's awaited `child:<id>` `StepRecorded`, and the
  next resume pass re-invokes the parent so it proceeds past its child-wait. EP-43's
  parent-resumption acceptance is demonstrated by running `resumeWorkflowsOnce` with the
  parent in the registry.
- EP-44 (observability): reads `ResumeSummary` to feed `keiro.workflow.resumed` (and may
  thread a `Maybe KeiroMetrics` into `WorkflowResumeOptions` / `resumeWorkflowsOnce`
  following the no-op-under-`Nothing` idiom the timer and outbox workers use); the
  `discovered`/`resumed`/`completed`/`stillSuspended`/`unknownName` counts are the natural
  resume-worker instrument set.
- EP-45 (worked example + docs): documents running `runWorkflowResumeWorker` with an
  application registry as the operational recovery story.

**New cross-plan contracts this plan adds — the MasterPlan should record them in its
Integration Points / Surprises:**

1. **`WorkflowRegistry es = Map WorkflowName (WorkflowDef es)`** with
   `data WorkflowDef es = forall a. WorkflowDef { runDef :: WorkflowId -> Eff (Workflow : es) a }`
   — the application-supplied name → definition map the resume worker (and, transitively,
   EP-43's parent resumption) needs because a workflow's body is code, not data. This is the
   resume-worker analogue of the timer worker's caller-supplied `fire` action.
2. **`ResumeSummary`** (`discovered`, `resumed`, `completed`, `stillSuspended`,
   `unknownName`) — the per-pass observability record EP-44 instruments under
   `keiro.workflow.resumed`.

Every commit while implementing this plan must carry all three git trailers:

```text
MasterPlan: docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md
ExecPlan: docs/plans/42-workflow-resume-and-crash-recovery-worker.md
Intention: intention_01kt6y4cb6eqz9mq48kf2xw8n1
```
