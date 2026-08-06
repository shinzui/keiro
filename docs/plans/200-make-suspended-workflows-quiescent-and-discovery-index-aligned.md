---
id: 200
slug: make-suspended-workflows-quiescent-and-discovery-index-aligned
title: "Make suspended workflows quiescent and discovery index-aligned"
kind: exec-plan
created_at: 2026-08-06T00:12:20Z
intention: "intention_01kza6gjs5eg79n2hyrah7wnnn"
master_plan: "docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md"
---

# Make suspended workflows quiescent and discovery index-aligned

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today a durable workflow that is suspended waiting for an external signal (an
awakeable), a child workflow, or a far-future sleep is *re-executed on every resume
pass* — claimed, its journal replayed, its arming action re-run, and re-suspended —
once per second by default, and on every event-store append under the push-aware
resume worker. The work is all idempotent, so nothing breaks, but the idle cost of
the engine grows linearly with the number of parked workflows: a thousand parked
approval flows cost tens of thousands of no-progress database queries per second.
On top of that, the discovery query's `status NOT IN (...)` predicate cannot use the
partial index that was built for it, so every pass also sequentially scans the
`keiro_workflows` table.

After this plan, a suspended workflow costs the resume worker nothing until something
actually happens to it. Discovery returns a workflow only when it has progress to
make: its status row says `running` (a wake completion, cancellation, or crash left
work to do) or it is `suspended` with a due sleep hint. Every path that resolves or
abandons a wake now leaves the instance row discoverable, and the one race that made
this narrowing unsafe — a wake landing in the gap between a run's final journal check
and its suspended-status write — is closed with the same per-step advisory lock the
append path already uses. You can see it working by suspending a workflow on an
awakeable and watching `resumeWorkflowsOnce` return `discovered = 0` until the moment
the awakeable is signalled or cancelled, at which point exactly that workflow is
discovered and driven.


## Progress

- [x] Milestone 1 (2026-08-06): discovery predicate rewritten to `status IN ('running','suspended')`; index-usability test added (`Keiro.Workflow discovery index`, two examples); full suite green at 380 examples.
- [x] Milestone 2 (2026-08-06): `cancelAwakeable` flips the owner instance row to `running`; `workflowSleepFireAction` clears `wake_after` only on a fresh append. New group `Keiro.Workflow wake-lifecycle visibility` (two examples); ADR 7 amended and `just adr-validate` green; suite at 382 examples.
- [ ] Milestone 3: suspend/wake arbitration under the per-step advisory lock; discovery narrowed to exact wakes; redundant child seed removed; migration 0021 (index + backfill); crash-window tests green.
- [ ] ADR recorded for the exact-discovery contract; `just adr-validate` passes.
- [ ] Full suite green: `cabal test keiro-test` and `cabal test keiro-migrations-test`.


## Surprises & Discoveries

- The index-mismatch finding reproduces exactly as the re-audit described, and the
  new test discriminates. With the rewritten predicate the plan names the index;
  with the old predicate — under the same `SET LOCAL enable_seqscan = off` — the
  planner still seq-scans and marks the node as penalised rather than reaching for
  `keiro_workflows_active_idx`:

  ```text
  Sort  (cost=19.88..20.15 rows=109 width=64)
    Sort Key: workflow_name, workflow_id
    ->  Seq Scan on keiro_workflows  (cost=0.00..16.19 rows=109 width=64)
          Disabled: true
          Filter: ((status <> ALL ('{completed,cancelled,failed}'::text[]))
                   AND ((wake_after IS NULL) OR (wake_after <= now())))
  ```

  The committed test asserts only the positive case (the plan text mentions
  `keiro_workflows_active_idx`). Asserting the negative case would pin a planner
  limitation rather than our behaviour, and would break if a future Postgres
  learned to prove partial-index implication from the table's CHECK constraint.
  Date: 2026-08-06


## Decision Log

- Decision: Close the suspend-vs-wake race with the existing per-step advisory lock
  rather than a status-guarded UPDATE or serializable transactions.
  Rationale: Every wake delivery already serializes on
  `lockWorkflowStepTx` for the awaited step (inside `prepareJournalAppend`); taking
  the same lock in the suspend write gives total ordering with no new locking
  concept, no isolation-level change, and no reliance on read-committed
  EvalPlanQual subtleties.
  Date: 2026-08-06

- Decision: Backfill every `suspended` instance row to `running` in the migration
  rather than attempting to classify legacy suspensions.
  Rationale: A workflow suspended before this change may be parked on an
  already-cancelled awakeable that will never produce another wake; one extra
  re-examination per legacy instance is cheap and converges every case through the
  new arbitration.
  Date: 2026-08-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The durable-execution engine lives in `keiro/src/Keiro/Workflow.hs` and the modules
under `keiro/src/Keiro/Workflow/`. A *workflow* is an ordinary Haskell computation
whose named steps are journaled into a kiroku event stream (`wf:<name>-<id>`, one
stream per *generation* — `continueAsNew` rotates onto `wf:<name>-<id>#<g>`); replay
returns recorded results instead of re-running side effects. A workflow *suspends*
when it reaches an `awaitStep` whose result is not yet journaled: it runs an
idempotent *arming* action (schedule a timer, register an awakeable row, nothing for
a child) and unwinds. A *wake source* (a fired sleep timer, `signalAwakeable`, a
child finishing) later appends the awaited step's result, and the *resume worker*
(`keiro/src/Keiro/Workflow/Resume.hs`) re-invokes the workflow so it proceeds.

Discovery is `findUnfinishedWorkflowIds` in `keiro/src/Keiro/Workflow/Schema.hs`
(statement `findUnfinishedWorkflowIdsStmt`), which reads the per-instance summary
table `keiro.keiro_workflows` (created by
`keiro-migrations/migrations/0011-keiro-workflows-instances.sql`, wake hint added by
`0013-keiro-workflows-wake-after.sql`):

```sql
SELECT workflow_id, workflow_name
FROM keiro.keiro_workflows
WHERE status NOT IN ('completed', 'cancelled', 'failed')
  AND (wake_after IS NULL OR wake_after <= $1)
ORDER BY workflow_name, workflow_id
```

Three facts make this the hot spot. First, only the sleep arm ever sets `wake_after`
(`Keiro.Workflow.Sleep.sleepNamed` writes it when its `scheduleTimerOnceTx` insert
wins), so a workflow suspended on an awakeable or child has `wake_after IS NULL` and
is returned by *every* pass; the resume worker then claims it, replays its whole
journal (`snapshotPolicy` defaults to `Never`), re-runs the arm, and re-suspends —
roughly a dozen round-trips for zero progress, per instance, per pass. Second, the
partial index from migration 0011,
`keiro_workflows_active_idx ON keiro.keiro_workflows (status) WHERE status IN
('running','suspended')`, is unusable for this query: Postgres proves partial-index
applicability from the query predicate alone (it does not consult the table's CHECK
constraint), and `status NOT IN ('completed','cancelled','failed')` does not imply
`status IN ('running','suspended')` to the prover — so the pass seq-scans
`keiro_workflows`. Third, `resumeWorkflowsOnce` unions discovery with
`findRunningChildIds` (`keiro/src/Keiro/Workflow/Child/Schema.hs`), a full read of
all `running` child-link rows on every pass; that seed predates migration 0011 —
since 0011 backfilled running children into `keiro_workflows` and `spawnChild`
(`keiro/src/Keiro/Workflow/Child.hs`) upserts the child's instance row inside the
spawn step's transaction, every child is already visible to the main query.

Why discovery cannot be narrowed naively: the instance row's `status` is maintained
by the journal-append transaction. `prepareJournalAppend` in
`keiro/src/Keiro/Workflow.hs` takes a per-step advisory lock
(`lockWorkflowStepTx` in `keiro/src/Keiro/Workflow/Schema.hs`, keyed on
`<wid>/<name>/<gen>/<stepName>`), re-checks the step index, appends, writes the
index row, and upserts `keiro_workflows` — for a `StepRecorded` event the upsert
sets `status = 'running'`. So every wake *delivery* already flips a suspended
instance to `running`. Two gaps remain. Gap one: `cancelAwakeable`
(`keiro/src/Keiro/Workflow/Awakeable.hs`) writes **no** journal entry (there is no
result value) and touches no instance row — today the hot poll is what re-runs the
workflow so its arm can observe the `cancelled` row and throw
`WorkflowAwakeableCancelled`; narrow discovery without fixing this and a workflow
parked on a cancelled awakeable is stranded forever. Gap two: the suspend write
itself races wake delivery. `runWorkflowWith`'s `Await` miss path consults the step
index (`lookupStepResult`), runs the arm, and throws an internal `WorkflowSuspend`
sentinel; the outcome handler then calls `markInstanceSuspended`
(`keiro/src/Keiro/Workflow/Instance.hs`), a plain upsert to `status = 'suspended'`.
If a wake commits between the index miss and the suspend write, the wake's
`running` is overwritten by `suspended`, the wake hint is `NULL`, and under narrowed
discovery nothing would ever return — today the hot poll masks this window too.

One more wake-hint defect rides along. `workflowSleepFireAction`
(`keiro/src/Keiro/Workflow/Sleep.hs`) runs
`runTransaction (appendTx <* clearWorkflowWakeAfterTx name wid)` — it clears
`wake_after` even when the append reports `JournalAlreadyPresent` (a re-fire of a
timer whose first fire committed its append but crashed before being marked fired).
If the workflow has since armed a *different* sleep, that sleep's hint is erased and
never rewritten (only the first-arm insert writes the hint, by design), so the
workflow is hot-polled until the second timer actually fires.

Relevant ADRs, per `agents/skills/exec-plan/ADR.md` (the corpus in `docs/adr/` is a
profile-governed OKF bundle — allocate ids with `okf id next`, keep `log.md` current,
validate with `just adr-validate`):

- `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md` —
  the step index is the authoritative record of journaled steps; the `Await` miss
  path must consult it before arming. This plan's arbitration *reuses* that
  authority (the suspend write checks the same index under the same lock) and must
  not weaken it.
- `docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md` —
  wake-source rows (awakeables, child links) are the durable authority for exposure
  and terminal lifecycle; journal entries deliver results. This plan extends the
  rule: every row-lifecycle transition must also leave the *instance row*
  discoverable.
- `docs/adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md` —
  the first-arm insert owns `fire_at` and the `wake_after` hint, and "a successful
  fire clears `wake_after` in the same transaction as its journal append". The
  re-fire guard in Milestone 2 aligns the implementation with the word
  *successful*: only a fresh append is a successful fire.
- `docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md`
  — resurrection sets `status = 'running'`, which the narrowed discovery naturally
  picks up; no interaction beyond that.

The sibling plan
`docs/plans/201-fold-terminal-checks-into-the-workflow-append-transaction-and-thin-the-step-hot-path.md`
edits other functions in `keiro/src/Keiro/Workflow.hs` and
`keiro/src/Keiro/Workflow/Schema.hs`; this plan exclusively owns
`findUnfinishedWorkflowIdsStmt`, `markInstanceSuspended`, the sleep fire's
wake-hint clear, and `cancelAwakeable`. Merge order with plan 201 is mechanical.

Tests live in `keiro/test/Main.hs` (hspec; the suite provisions ephemeral Postgres
template databases through `keiro-test-support`, so `cabal test keiro-test` from the
repository root is self-contained). Migration pin-count tests live in the
`keiro-migrations` package (`cabal test keiro-migrations-test`).


## Plan of Work

### Milestone 1 — index-aligned discovery predicate

Scope: make the existing discovery query able to use the existing partial index,
with no semantic change. In `keiro/src/Keiro/Workflow/Schema.hs`, rewrite
`findUnfinishedWorkflowIdsStmt`'s predicate from
`status NOT IN ('completed', 'cancelled', 'failed')` to
`status IN ('running', 'suspended')`. The two are equivalent because migration 0011
constrains `status` with `CHECK (status IN ('running','suspended','completed',
'cancelled','failed'))`; the rewrite only matters to the planner's partial-index
prover. Update the statement's comment: the literals must continue to match
`Keiro.Workflow.Instance.statusToText` for `running` and `suspended` (today the
comment names the terminal trio; after this change the *active* pair is the coupled
set).

Add a test to `keiro/test/Main.hs` (new group, e.g.
`describe "Keiro.Workflow discovery index"`) that proves index usability: insert a
handful of instance rows in mixed statuses, then run
`SET LOCAL enable_seqscan = off` followed by
`EXPLAIN (FORMAT TEXT) SELECT workflow_id, workflow_name FROM keiro.keiro_workflows
WHERE status IN ('running','suspended') AND (wake_after IS NULL OR wake_after <=
now())` through a raw `Tx.sql`/statement, and assert the plan text mentions
`keiro_workflows_active_idx`. (With seq scans discouraged, a usable partial index
appears in the plan even on a tiny table; the *old* predicate under the same
settings still seq-scans, which is worth asserting as the counterexample while the
old text is still in the git history — the test only needs the positive case.)
Also assert functional equivalence: the rewritten `findUnfinishedWorkflowIds`
returns exactly the non-terminal, wake-due rows it returned before.

Acceptance: the new test passes; the whole suite stays green.

### Milestone 2 — every wake-lifecycle transition is discoverable

Scope: close the two paths that change wake state without leaving the instance row
discoverable. Both changes are safe and useful under today's broad discovery, so
this milestone lands independently of Milestone 3.

First, `cancelAwakeable`. In `keiro/src/Keiro/Workflow/Awakeable/Schema.hs`, extend
the cancel statement so the caller learns the owner coordinates of the row it
transitioned: change `cancelAwakeableStmt` to
`UPDATE ... WHERE awakeable_id = $1 AND status = 'pending' RETURNING
owner_workflow_name, owner_workflow_id` decoded with `D.rowMaybe`, and change
`cancelAwakeableTx :: UUID -> Tx.Transaction (Maybe (Text, Text))` accordingly
(returning `Just (name, wid)` exactly when this call performed the transition). In
`keiro/src/Keiro/Workflow/Awakeable.hs`, `cancelAwakeable` becomes: run one
transaction that performs the guarded cancel and, when it transitioned, upserts the
owner instance to `running` via `Keiro.Workflow.Instance.upsertInstanceTx` with
generation 0 (the upsert takes `GREATEST` of stored and supplied generation, so 0
preserves the stored one) and no error text; return `True` iff transitioned. The
`running` status is exactly what a wake completion writes and means "this workflow
has progress to make" — here, observing the cancellation and throwing
`WorkflowAwakeableCancelled` from the arm. Keep the function's signature
`cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool` unchanged.

Second, the sleep re-fire guard. In `keiro/src/Keiro/Workflow/Sleep.hs`, change
`workflowSleepFireAction`'s transaction from `appendTx <* clearWorkflowWakeAfterTx
name wid` to a conditional: bind the append outcome, and run
`clearWorkflowWakeAfterTx` only when the outcome is `JournalAppended` — a fresh
append is the one "successful fire" in ADR 7's sense. A `JournalAlreadyPresent`
re-fire (first fire committed, worker crashed before marking the timer fired) then
leaves any newer sleep's hint intact. The append and the (conditional) clear remain
one transaction, preserving ADR 7's atomicity consequence. Update ADR 7's
Consequences wording in the same change if the implementation note there reads as
unconditional (`docs/adr/0007-...md`), and bump its `timestamp` plus run
`okf log add` per the bundle contract.

Tests, in `keiro/test/Main.hs`: (a) suspend a workflow on an awakeable, cancel the
awakeable, and assert `lookupInstance` now reports `WfRunning` and
`findUnfinishedWorkflowIds` includes the workflow; drive a pass and assert the run
crashes with `WorkflowAwakeableCancelled` and the crash is recorded (attempts = 1).
(b) arm sleep A with a short delay, fire it through `workflowSleepFireAction`, then
simulate the crash-before-marking by resetting the timer row's status to `pending`
with raw SQL; resume the workflow so it arms sleep B (long delay, `wake_after` far
future); re-fire the stale row and assert the workflow's `wake_after` is unchanged
(and the re-fire still returns the deterministic event id, i.e. stays idempotent).

Acceptance: both tests pass; the full suite stays green.

### Milestone 3 — exact discovery

Scope: close the suspend-vs-wake race, then narrow discovery so suspension is
quiescent; remove the redundant child seed; ship the migration and the ADR. This is
the milestone that changes the engine's liveness argument, so its tests are the
plan's center of gravity.

Suspend/wake arbitration. The internal suspension sentinel in
`keiro/src/Keiro/Workflow.hs` currently carries nothing
(`data WorkflowSuspend = WorkflowSuspend`). Change it to carry the awaited step
name: `newtype WorkflowSuspend = WorkflowSuspend Text`, thrown by the `Await` miss
path with the key it parked on (the handler already has `key` in scope). In the
outcome handler, replace the `markInstanceSuspended name wid` call with a new
arbitrating write, `markInstanceSuspendedAwaiting name wid gen awaitedStep`
(implemented in `keiro/src/Keiro/Workflow/Instance.hs`, replacing
`markInstanceSuspended` — update its export and the one call site; the old function
also resolved `currentGeneration` internally, which the new signature makes
unnecessary because `runWorkflowWith` already holds `gen`). The new function runs
one transaction that:

1. takes the same advisory lock the append path takes for this step —
   `lockWorkflowStepTx` with the identical key derivation
   `<wid>/<name>/<gen>/<awaitedStep>` (extract the key-building into a small shared
   helper in `keiro/src/Keiro/Workflow/Schema.hs`, e.g. `workflowStepLockKey`, and
   use it from both `prepareJournalAppend` and here so the two can never drift);
2. re-checks the step index with `lookupStepResultTx` for the awaited step on this
   generation;
3. upserts the instance to `suspended` when the step is still absent, or to
   `running` when a wake has landed.

Because every wake delivery holds that same lock while it appends and flips the
instance row, the two writers are totally ordered: if the suspend write wins the
lock, the wake (waiting behind it) will set `running` afterwards; if the wake wins,
the suspend write observes the index row and writes `running` itself. No
interleaving leaves a resolved wake behind a `suspended` status.

Narrowed discovery. Rewrite `findUnfinishedWorkflowIdsStmt` (again — this plan owns
it) to:

```sql
SELECT workflow_id, workflow_name
FROM keiro.keiro_workflows
WHERE status = 'running'
   OR (status = 'suspended' AND wake_after IS NOT NULL AND wake_after <= $1)
ORDER BY workflow_name, workflow_id
```

Read the semantics as: `running` means a wake, cancellation-flip, crash, rotation,
or resurrection left work to do (crash retries stay visible because
`claimInstance`'s `next_attempt_at` gate, not discovery, is what paces backoff);
`suspended` with a due hint means a sleep whose timer is due but whose fire has not
yet landed (the fire itself flips to `running`, so this arm mostly matters when the
timer worker is behind). A `suspended` instance with no due hint is parked on a
wake source and is intentionally invisible.

Remove the `findRunningChildIds` union from `resumeWorkflowsOnce` in
`keiro/src/Keiro/Workflow/Resume.hs` (and the now-unused import): the seed is
redundant since migration 0011 backfilled running children into `keiro_workflows`
and `spawnChild` upserts the child instance row transactionally with the spawn
step. Keep the function exported from `Keiro.Workflow.Child.Schema` for operator
inspection, and note the removal in its haddock.

Migration `keiro-migrations/migrations/0021-keiro-workflows-exact-discovery.sql`
(next free number per the MasterPlan's integration points; if another plan claimed
0021 first, take the next free number and update this plan) with two statements and
a comment block explaining both:

```sql
-- Exact discovery: replace the status-only active index with one that also
-- serves the suspended-and-due arm of the narrowed discovery predicate.
DROP INDEX IF EXISTS keiro.keiro_workflows_active_idx;
CREATE INDEX IF NOT EXISTS keiro_workflows_active_idx
  ON keiro.keiro_workflows (status, wake_after)
  WHERE status IN ('running', 'suspended');

-- Legacy suspensions predate exact discovery: a pre-change 'suspended' row may
-- be parked on a wake that already resolved or a promise already cancelled and
-- will never be flipped again. Return them all to the runnable pool once; the
-- next pass re-examines each through the new suspend/wake arbitration.
UPDATE keiro.keiro_workflows SET status = 'running', updated_at = now()
WHERE status = 'suspended';
```

Update the migration manifest and the pinned counts in the `keiro-migrations`
test-suite (the suite asserts the exact number of Keiro and composed migrations;
after this plan they increase by one — find the pins by running the suite and
following the failure).

Remember the build gotcha recorded in `keiro/src/Keiro/Workflow.hs`'s module
header: adding a `.sql` file does not retrigger the Template Haskell `embedDir` in
`keiro-migrations/src/Keiro/Migrations.hs`; touch a comment in that module or
`cabal clean` before trusting a build.

New ADR. Allocate the next id (`okf id list docs/adr --profile
docs/adr/profile.dhall` then `okf id next docs/adr --profile docs/adr/profile.dhall
ADR` — expected ADR-23) for a record titled along the lines of "Workflow discovery
is exact and the instance row is the complete wake ledger": the decision that every
wake-source lifecycle transition (delivery, cancellation, failure, resurrection)
must leave `keiro_workflows` discoverable in the same transaction; that the suspend
write arbitrates against wake delivery under the per-step advisory lock; and that
`wake_after` is a sleep-only scheduling hint, not a general wake mechanism. Record
the deliberate consequence that a workflow-sleep timer cancelled by an operator
(`Keiro.Timer.cancelTimer`) leaves its workflow discoverable-and-idle from
`wake_after` due-time onward exactly as today, and that third-party wake sources
inherit the flip-the-instance-row obligation (the documentation plan,
`docs/plans/204-document-the-wake-source-contract-and-the-durable-execution-scale-posture.md`,
carries the author-facing wording). Maintain `log.md` with `okf log add` and pass
`just adr-validate`.

Tests, in `keiro/test/Main.hs` (new group, e.g. `describe "Keiro.Workflow exact
discovery"`):

- Quiescence: suspend one workflow on an awakeable and one on a child; assert
  `findUnfinishedWorkflowIds` returns neither; assert a `resumeWorkflowsOnce` pass
  reports `discovered = 0`. Signal the awakeable; assert exactly the owner is
  discovered and a pass completes it. Complete the child through
  `runChildWorkflow`; assert exactly the parent is discovered and a pass completes
  it.
- Suspend-vs-signal race, wake-wins ordering: drive a workflow to its `Await` miss
  *deterministically* — run the workflow once so the awakeable row exists and the
  instance is suspended, then (simulating the in-gap wake) call `signalAwakeable`,
  then call `markInstanceSuspendedAwaiting` directly with the awaited step (this is
  the exact write the racing run would perform after its stale index miss) and
  assert the instance ends `running`, discovery returns the workflow, and the next
  pass completes it. This pins the arbitration's index re-check.
- Suspend-vs-signal race, suspend-wins ordering: call
  `markInstanceSuspendedAwaiting` first (instance `suspended`, invisible), then
  `signalAwakeable`, and assert the signal's append flipped the instance to
  `running` and the workflow completes on the next pass. This pins the wake-side
  flip.
- Sleep visibility: suspend on a short `sleepNamed`; assert the workflow is
  invisible to discovery *before* `fire_at` (pass `now` earlier than the deadline)
  and visible after; fire the timer and assert it is discovered via the `running`
  arm with `wake_after` cleared.
- Cancelled-awakeable liveness (extends Milestone 2's test under narrowed
  discovery): suspend on an awakeable, assert invisible, `cancelAwakeable`, assert
  discovered, drive a pass, assert `WorkflowAwakeableCancelled` surfaces as a
  recorded crash attempt.
- Crash-retry visibility: make a workflow crash (a step action that throws),
  assert it stays discovered across passes (status `running`) while
  `claimInstance`'s `next_attempt_at` gate paces retries, and that it terminally
  fails at `maxAttempts` exactly as before (reusing the existing poison-workflow
  test shape at `keiro/test/Main.hs` around the current "isolates a poison
  workflow" example).

Acceptance: all new tests pass; every pre-existing workflow test (including the
MasterPlan-16 crash-window groups for snapshot wake-safety, child failure, sleep
generations, GC, resurrection, and lease renewal) stays green unmodified except
where a test asserted the old always-discovered behavior — such assertions must be
updated deliberately and called out in the Decision Log.


## Concrete Steps

All commands run from the repository root.

```bash
cabal build keiro                 # after each milestone's edits
cabal test keiro-test             # full engine suite (provisions ephemeral Postgres)
cabal test keiro-migrations-test  # after Milestone 3's migration (expect pinned counts to need +1)
just adr-validate                 # after the ADR edits in Milestones 2 and 3
```

Expected shapes: `cabal test keiro-test` ends with `N examples, 0 failures` (N grows
by the new examples); `keiro-migrations-test` fails on the pinned counts until they
are updated to include migration 0021, then passes; `just adr-validate` prints no
violations.

Commit per milestone with conventional-commit messages and the required trailers,
for example:

```text
feat(workflow): make suspended workflows quiescent under exact discovery

MasterPlan: docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md
ExecPlan: docs/plans/200-make-suspended-workflows-quiescent-and-discovery-index-aligned.md
Intention: intention_01kza6gjs5eg79n2hyrah7wnnn
```


## Validation and Acceptance

Beyond the suite: the observable behavior is the `ResumeSummary`. Before this plan,
a process with one workflow parked on an awakeable reports `discovered = 1` on every
`resumeWorkflowsOnce` call; after this plan it reports `discovered = 0` until
`signalAwakeable`/`cancelAwakeable`, then `discovered = 1` exactly once through to
completion (or the recorded cancellation crash). The Milestone 1 EXPLAIN test is the
acceptance for index alignment; the Milestone 3 race tests are the acceptance for
liveness. Nothing in the public authoring surface (`step`, `awaitStep`, `sleep*`,
`awakeable*`, `spawnChild`/`awaitChild`/`cancelChild`, `runWorkflow*`) changes
signature or semantics.


## Idempotence and Recovery

Every edit is code plus one forward-only migration. The migration's index swap is
`DROP IF EXISTS`/`CREATE IF NOT EXISTS` and its backfill is a status flip that the
engine converges on its own (a re-examined workflow re-suspends through the new
arbitration), so re-running the plan's steps or re-applying the migration to a
half-migrated database is safe. If Milestone 3 must be rolled back after deploy,
reverting the code alone is sufficient: broad discovery is a superset of exact
discovery, and the `(status, wake_after)` index serves the old predicate too.


## Interfaces and Dependencies

No new libraries. Changed internal interfaces at end state:
`Keiro.Workflow.Instance.markInstanceSuspendedAwaiting :: WorkflowName ->
WorkflowId -> Int -> Text -> Eff es ()` replaces `markInstanceSuspended` (module
export updated; the only caller is `runWorkflowWith`);
`Keiro.Workflow.Awakeable.Schema.cancelAwakeableTx :: UUID -> Tx.Transaction
(Maybe (Text, Text))` (owner coordinates when this call transitioned);
`Keiro.Workflow.Schema.workflowStepLockKey :: Text -> Text -> Int -> Text -> Text`
shared by append and suspend paths. `Keiro.Workflow.Awakeable.cancelAwakeable`
keeps its public signature. The sibling plans must not touch these functions; see
the MasterPlan's Integration Points.
