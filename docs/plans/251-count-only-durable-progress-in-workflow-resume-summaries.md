---
id: 251
slug: count-only-durable-progress-in-workflow-resume-summaries
title: "Count only durable progress in workflow resume summaries"
kind: exec-plan
created_at: 2026-08-12T23:55:43Z
intention: "intention_01kzw6dkcserms9yr61sqdntep"
master_plan: "docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md"
---

# Count only durable progress in workflow resume summaries

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The workflow resume subsystem publishes a per-pass `ResumeSummary` whose `advanced`
field is documented as the drain-termination signal: an operator (or the
`keiro-ops wf resume-once` command) repeats bounded passes while the previous pass
reported `advanced > 0`, and stops to report the blocked pool when a pass advances
nothing. Today that signal lies. `bumpForOutcome` in
`keiro/src/Keiro/Workflow/Resume.hs` bumps `advanced` for every successfully processed
re-invocation — including a replay-only run that re-entered an unresolved sleep,
appended nothing durable, and re-suspended exactly where it started. A workflow
suspended on a sleep whose wake time has passed while the timer worker is behind or
down is rediscovered on every pass, re-invoked, re-suspended, and reported
`advanced = 1` forever, so the documented drain loop never terminates — precisely in
the standalone operator context (`keiro-ops wf resume-once`) the drain recipe was
written for.

After this plan, `advanced` means what its documentation says: it counts only
candidates whose re-invocation committed durable movement (a fresh journal append, a
terminal-failure record, or an externally delivered wake observed mid-pass). The
replay-only due-sleep candidate is instead classified into a new explicit blocked
category, `sleepDue`, that the summary, the Haddock drain recipe, and the
`keiro-ops wf resume-once` output all expose, telling the operator the actual remedy:
run or repair the timer worker, not another resume pass. A regression test proves a
bounded drain loop over a due sleep with no timer worker terminates in one pass
(it loops until an arbitrary bound today), and the two ADRs that carry this contract
(`docs/adr/0023-...` and `docs/adr/0025-...`) are amended to record the corrected
meaning.

How to see it working: `cabal test keiro-test --test-options='--match "due sleep with no timer worker"'`
fails before the fix (the drain loop exhausts its bound) and passes after;
`cabal test keiro-ops-test` shows `wf resume-once --force --json` reporting
`"advanced": 0` with `"sleep_due": 1` for that pool; and the full `just verify` gate
stays green.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-13 14:52Z) M1: added the red drain test "a bounded drain loop terminates over a due sleep with no timer worker" to `keiro/test/Main.hs` using only existing summary fields, and recorded the bound-exhaustion failure below.
- [x] (2026-08-13 14:58Z) M2: added `onJournalAppend :: !(Maybe (IO ()))` to `WorkflowRunOptions`, defaulted it to `Nothing`, and invoked it at every fresh-append site (step, patch, patch-set, completion, rotation).
- [x] (2026-08-13 14:58Z) M2: reshaped `ResumeSummary` with `sleepDue :: !Int`, threaded a per-candidate append witness through `advance`/`driveInstance`, and replaced `bumpForOutcome` with append-aware classification plus the post-suspension instance-row check.
- [x] (2026-08-13 14:58Z) M2: rewrote the `advanced` field documentation, module-header field recap, and both bounded-drain recipes in `Resume.hs`.
- [x] (2026-08-13 14:58Z) M2: updated every full-record summary assertion, changed `expectedMixedResumeSummary.advanced` from 3 to 2, extended the due-sleep test with stable `sleepDue` assertions, and passed all 545 `keiro-test` examples.
- [x] (2026-08-13 15:00Z) M3: rendered `sleep_due` in `keiro-ops` as a human column and JSON key, added the two-pass due-sleep command test, and passed all 42 `keiro-ops-test` examples.
- [ ] M4: update `docs/guides/durable-workflows.md`, `docs/user/durable-workflows.md`, and `docs/user/operations.md` drain/summary text.
- [ ] M4: CHANGELOG entries — rewrite the keiro Unreleased breaking-change bullet from plan 239 to the final shape; extend the keiro-ops Unreleased resume-once bullet.
- [ ] M4: amend ADR 0023 and ADR 0025, add `docs/adr/log.md` entries, `just adr-validate` green.
- [ ] M4: tick EP-2 in `docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md`, write Outcomes & Retrospective here, `just haskell-test` and `just verify` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Durable movement is detected by an explicit per-run append witness — a new
  `WorkflowRunOptions` field `onJournalAppend :: !(Maybe (IO ()))` invoked on every
  `JournalAppended` outcome inside a run — rather than by comparing journal head
  positions around the pass or by reshaping `WorkflowOutcome`.
  Rationale: the run entry point is the only place that knows which appends were
  fresh, so the witness is exact and free (no extra queries per candidate).
  `WorkflowOutcome` is pattern-matched throughout application code and must not
  change shape. Options-borne plumbing follows the existing `leaseHeartbeat`
  precedent and flows through `runChildWorkflow` unchanged, so child candidates are
  covered for free. Head-comparison would cost two queries per candidate on every
  pass and still misattribute concurrent writers.
  Date: 2026-08-12
- Decision: `advanced` counts a candidate when (a) its re-invocation fired the append
  witness at least once, (b) a crash reached the failure ceiling and recorded
  `WorkflowFailed` (the existing explicit bump), or (c) a no-append suspension's
  post-run instance check finds the row already flipped back to `running` (an external
  wake landed mid-pass). Nothing else counts: replay-only re-suspensions,
  `Cancelled`/`Failed` short-circuits that appended nothing, and a completion that
  found its marker already present are not advances.
  Rationale: (a) is the definition of durable journal movement; (b) is terminal-state
  movement recorded outside the run; (c) keeps the drain loop live when the wake it
  was waiting for arrives during the pass — stopping there would strand a now-runnable
  candidate behind a truthfully-zero summary. The excluded cases are all either
  no-movement (the defect) or terminal races whose candidates leave discovery by
  themselves, so excluding them never threatens termination and fixes the contract's
  truthfulness (the MasterPlan decision "fix the meaning, not the documentation").
  Date: 2026-08-12
- Decision: A fresh sleep arm (timer insert plus `wake_after` hint) and a fresh
  awakeable-row creation do not fire the witness and are not advances.
  Rationale: they are wake-source state, not journal movement, and they never make
  the candidate advanceable by another resume pass — a freshly armed future sleep
  leaves discovery entirely, and a due one is blocked on the timer worker, which is
  exactly what `sleepDue` now reports. Counting them would cost one extra futile
  drain pass and blur the field's meaning.
  Date: 2026-08-12
- Decision: The blocked category is a counter, `sleepDue :: !Int` (JSON `sleep_due`),
  not an identity set like `unregisteredNames`.
  Rationale: the remedy is cause-level (start/repair the timer worker, or repair an
  operator-cancelled sleep timer), not per-instance; identities are already one
  `keiro-ops wf list --status suspended` away. `unregisteredNames` carries names
  because its remedy is a per-name code deploy.
  Date: 2026-08-12
- Decision: `sleepDue` is classified by a post-run point read of the instance row
  (status `suspended`, `wake_after` non-null and due), performed only on the
  no-append suspension path.
  Rationale: the run may itself change `wake_after` (a first arm writes it), so
  discovery-time data cannot classify; the point read is one primary-key lookup on
  the rare no-progress path only. The same read distinguishes the mid-pass external
  wake (row `running`) and the mid-pass terminal race (row terminal or gone).
  Date: 2026-08-12
- Decision: `ClaimOutcome` is unchanged, and `releaseInstance`'s attempt-reset flag
  keeps its current meaning (every `AdvOk` run releases with `progressed = True`,
  appended or not).
  Rationale: claim classification was fixed correctly by plan 239 and is orthogonal;
  a replay-only suspension is still a successful run, so clearing crash pacing on it
  remains right — the append witness and the release flag answer different questions
  and must not be conflated.
  Date: 2026-08-12
- Decision: `ContinuedAsNew` is counted through the witness like everything else
  (rotation appends fire it), accepting that the never-observed cross-process race in
  which another runner committed the same rotation first reports no advance.
  Rationale: under the instance lease two resume workers cannot race one candidate;
  only a concurrent direct `runWorkflowWith` call could, and the cost is a drain that
  stops one pass early with a truthful summary and a still-discoverable candidate —
  recoverable by rerunning, never a non-termination.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This is a Haskell multi-package cabal repository. This plan touches the `keiro`
package (the durable-execution runtime, sources under `keiro/src/`, hspec suite
`keiro-test` at `keiro/test/Main.hs`) and the `keiro-ops` package (the operational
CLI library, sources under `keiro-ops/src/`, suite `keiro-ops-test` at
`keiro-ops/test/Main.hs`). Package versions in the cabal files are still 0.11.0.0;
everything in flight ships as the unreleased 0.12.0.0 major line, so breaking API
reshapes are legal, recorded under each package's `CHANGELOG.md` "Unreleased"
heading. No database migration is involved — the fix is code-level.

Vocabulary, from scratch. A "workflow" is application Haskell code re-invoked
against a durable journal: each named step's result is recorded once (an event in a
per-workflow stream plus a row in the derived `keiro.keiro_workflow_steps` index,
written in one transaction by `prepareJournalAppend` in
`keiro/src/Keiro/Workflow/Journal.hs`), and re-running the workflow replays recorded
steps and executes only the un-journaled tail. Running a workflow goes through one
entry point, `runWorkflowWith` in `keiro/src/Keiro/Workflow.hs`, which returns a
`WorkflowOutcome`: `Completed`, `Suspended` (the run parked on an unresolved
`awaitStep`), `Cancelled`, `Failed`, or `ContinuedAsNew` (the run rotated onto a new
journal generation). A "sleep" (`keiro/src/Keiro/Workflow/Sleep.hs`) is a durable
pause: on first encounter the run arms a `keiro_timers` row and suspends; the sleep
resolves only when a separate timer worker fires that row
(`workflowSleepFireAction`), which appends the sleep's completion step to the
journal. The module header of `Sleep.hs` is explicit (near lines 68-75): a sleep
whose timer is never drained stays suspended forever, and (near lines 59-62) "every
resume that re-enters the not-yet-resolved sleep leaves the row untouched" — the arm
is an insert-if-absent, so re-invocation writes nothing.

The "instance row" is one row per workflow in `keiro.keiro_workflows`
(`keiro/src/Keiro/Workflow/Instance.hs`, storage in
`keiro/src/Keiro/Workflow/Instance/Schema.hs`): `status`
(`running`/`suspended`/terminal), crash pacing (`attempts`, `next_attempt_at`), an
advance lease, and the sleep-only wake hint `wake_after`. The "resume worker"
(`keiro/src/Keiro/Workflow/Resume.hs`) discovers work with one exact query,
`findUnfinishedWorkflowIds` (`keiro/src/Keiro/Workflow/Schema.hs`, statement near
line 385): rows with `status = 'running'`, or `status = 'suspended' AND wake_after
IS NOT NULL AND wake_after <= now`. The second arm's stated purpose (Schema.hs near
lines 212-214) is "a sleep whose timer is due but whose fire has not landed yet ...
this arm mostly matters when the timer worker is behind". For each discovered
candidate the worker claims a lease (`claimInstance`, returning the typed
`ClaimOutcome` plan 239 introduced), re-invokes through `runWorkflowWith` (or
`runChildWorkflow` in `keiro/src/Keiro/Workflow/Child.hs`, which wraps
`runWorkflowWith` with the same options), and folds the outcome into the per-pass
`ResumeSummary`.

The defect. `ResumeSummary.advanced` (Resume.hs near lines 284-286) is documented as
"Candidates whose durable journal or terminal state moved this pass. Use this, not
'discovered', as the bounded-drain continuation signal", and the Haddock drain
recipe (near lines 372-375 on `resumeWorkflowsOnce`, near lines 394-395 on
`resumeWorkflowsOnceUpTo`) says "repeat bounded passes while the previous summary
reports `advanced > 0`; stop and report the remaining blocked candidates when
`advanced == 0`", naming the blocked categories as "pacing, unregistered
definitions, leases, or transient errors". But `bumpForOutcome` (near lines 601-621)
bumps `advanced` for every `AdvOk` outcome constructor unconditionally — Completed,
Suspended, Cancelled, Failed, ContinuedAsNew — with no detection of whether the run
appended anything. The reachable non-terminating state: a workflow suspended on a
due sleep while no timer worker runs. Discovery's second arm returns it every pass;
the re-invocation replays the journal, re-enters the unresolved sleep idempotently
(the arm's `scheduleTimerOnceTx` inserts nothing because the timer row exists, and
only an insert writes the wake hint — Sleep.hs near lines 286-291), appends nothing,
and re-suspends through `markInstanceSuspendedAwaiting`, whose
`upsertInstanceTx` SQL (Instance/Schema.hs near lines 52-71) never touches
`wake_after`. Only a successful timer fire clears the hint (Sleep.hs near line 362).
The row stays `suspended` and due, is rediscovered next pass, and reports
`advanced = 1` forever. No pacing applies — `next_attempt_at` is written only by
`recordCrashTx`, and a successful replay-only run releases its lease with the
attempt-resetting flag. `keiro-ops wf resume-once`
(`keiro-ops/src/Keiro/Ops/Workflow.hs`, `runResumeOnce` near lines 283-297) runs
exactly one such pass and renders the summary (`resumeSummaryResult`, near lines
315-353), so a compliant operator drain against this pool spins forever. Two smaller
truthfulness gaps ride along: a workflow cancelled or failed between discovery and
re-invocation short-circuits inside `runWorkflowWith` (the marker probe near lines
550-553, the mid-run sentinels near lines 582-583, and the refused-completion
mapping near lines 626-629 of `keiro/src/Keiro/Workflow.hs`) and returns
`Cancelled`/`Failed` having appended nothing, yet counts as advanced — terminal rows
leave discovery, so this is a one-pass over-count, not a loop, but it still violates
the field's contract and this plan fixes it under the same rule.

This behavior shipped in
`docs/plans/239-close-the-awakeable-cancel-versus-suspend-race-and-fix-the-drain-contract.md`
(commit `9c4b431f`, "fix(workflow)!: report advancing resume passes honestly"). That
plan's Decision Log explicitly chose "`advanced` counts ... every `AdvOk` outcome
(completed, suspended, cancelled, failed, continued-as-new)" — it fixed the paced
and unregistered blocked shapes and missed the replay-only-suspension shape, whose
canonical instance is the due sleep. The existing drain-termination test
(`keiro/test/Main.hs` near lines 10721-10760, in
`describe "Keiro.Workflow exact discovery"`) covers only a paced crash plus an
unregistered name.

Where fresh appends happen inside one run, all in `keiro/src/Keiro/Workflow.hs`
unless noted — this is the complete list the append witness must cover:

1. the `Step` handler's miss path (`appendJournal ... (StepRecorded ...)`,
   `JournalAppended` arm near line 696);
2. the `Patch` handler's miss path (`JournalAppended` arm near line 786);
3. `recordPatchSetIfFresh` (fresh-journal patch-set record, `JournalAppended` arm
   near line 656);
4. the completion append (`appendCompletion` result's `JournalAppended` arm near
   line 612);
5. `rotateGeneration` (rotation marker, next-generation seed, and optional patch-set
   appends, near lines 910-1005).

The resume worker's own terminal-failure appends (`appendJournalEntry ...
WorkflowFailed` and `appendFailedChildAndWakeParent` in Resume.hs) happen outside
the run and are already counted by an explicit `advanced` bump in the
crash-at-ceiling arm (near lines 530-539); that bump stays.

Relevant ADRs, all local (no relevant cross-repository ADR exists; the mori registry
was consulted during MasterPlan 40 planning and none applies):

- `docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`
  — discovery is exact; a suspended row with a due `wake_after` is returned by
  design until the fire lands; its Consequences already note that an
  operator-cancelled sleep timer leaves a workflow "discoverable-and-idle from the
  hint's due time onward". This plan does not change discovery; it amends this ADR
  to record how the resume summary now classifies that rediscovered-but-unmovable
  shape (`sleepDue`) instead of calling it an advance. Amended by plan 239; amended
  again here.
- `docs/adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md`
  — "report finished work, not attempted work". Its Decision section currently
  codifies the defect ("`ResumeSummary.advanced` counts ... every successful
  workflow outcome"); this plan amends that paragraph to the witness-based
  definition and adds the due-sleep blocked category to the drain-driver contract.
  Amended by plan 239; amended again here.
- `docs/adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md` —
  `wake_after` is a sleep-only hint owned by the first arm. Read-only context here;
  it is why the blocked category is named `sleepDue` and why classification can key
  on the hint.

The `docs/adr` directory is a profile-governed OKF bundle (`docs/adr/profile.dhall`,
reserved `log.md`); amendments bump each record's frontmatter `timestamp`, add a
`log.md` entry, and must pass `just adr-validate` (which runs strict OKF profile
enforcement).

Testing infrastructure: `keiro/test/Main.hs` is one large hspec module driven by the
suite-level ephemeral-Postgres template fixture from
`keiro-test-support/src/Keiro/Test/Postgres.hs` — `withMigratedSuite` migrates one
template database once per suite and `around (withFreshStore fixture)` clones a
fresh database per example. Never migrate per example; follow the surrounding
examples' shape exactly. Useful existing helpers: `sleepDemoNamed` (near line
12238: step "a", `sleepNamed`, step "b", with an `IORef` counter proving which
steps executed), `workflowWakeAfter` (reads the row's hint, used near line 10688),
and the drain-loop recursion in the existing termination test (near lines
10737-10742). The keiro-ops suite uses the same fixture pattern with helpers
`seedStep`, `workflowStatus`, `jsonInteger`, `jsonStringArray`, and `opsEnv`
(near lines 440-480).

Downstream consumers of the touched types: `keiro-ops/src/Keiro/Ops/Workflow.hs`
(`resumeSummaryResult` rendering) and `jitsurei/app/Main.hs` (prints the summary
with `show`, so it compiles unchanged). The MasterPlan's integration-point rule:
this plan alone owns the `ClaimOutcome`/`ResumeSummary` shapes, the keiro-ops
rendering, the Haddock drain recipe, and the ADR amendments; no sibling plan
touches these files.


## Plan of Work

### Milestone 1 — reproduce the non-terminating drain (red test)

Scope: `keiro/test/Main.hs` only. At the end, a committed test exists that encodes
the correct behavior (a bounded drain over a due-sleep-no-timer-worker pool
terminates after one pass), demonstrably fails on current code, and uses only
fields that exist today so it compiles before the fix.

In `keiro/test/Main.hs`, inside `describe "Keiro.Workflow exact discovery"`,
directly after the existing test "a bounded drain loop terminates over a pool that
cannot advance" (near line 10760), add a test named
"a bounded drain loop terminates over a due sleep with no timer worker". Body,
following the sibling's shape:

```haskell
it "a bounded drain loop terminates over a due sleep with no timer worker" $ \storeHandle -> do
  counter <- newIORef (0 :: Int)
  let name = WorkflowName "drain-due-sleep"
      wid = WorkflowId "dds-1"
      opts = defaultWorkflowResumeOptions & #logEvent .~ const (pure ())
      registry =
        Map.singleton name (WorkflowDef (\_ -> sleepDemoNamed counter (StepName "wait") (-1)))
      pass = Store.runStoreIO storeHandle (resumeWorkflowsOnce opts registry)
      drain 0 acc = pure acc
      drain n acc = do
        Right summary <- pass
        if advanced summary > 0
          then drain (n - 1 :: Int) (acc <> [summary])
          else pure (acc <> [summary])
  -- Arm the sleep with an already-due fire time: step "a" runs, the timer row is
  -- inserted with fire_at in the past, the wake hint is written, and the run
  -- suspends. No timer worker ever fires it.
  Right Suspended <-
    Store.runStoreIO storeHandle $
      runWorkflow name wid (sleepDemoNamed counter (StepName "wait") (-1))
  readIORef counter `shouldReturn` 1
  passes <- drain 5 []
  -- The honest contract: one pass, advanced == 0, candidate reported blocked.
  length passes `shouldBe` 1
  case passes of
    [summary] ->
      (discovered summary, resumed summary, stillSuspended summary, advanced summary)
        `shouldBe` (1, 1, 1, 0)
    other -> expectationFailure ("expected one drain pass, got " <> show other)
  -- Replay-only: neither step body re-ran.
  readIORef counter `shouldReturn` 1
  -- The candidate is still discoverable — blocked on the timer worker, not lost.
  Right (Just row) <- Store.runStoreIO storeHandle $ Instance.lookupInstance name wid
  row ^. #status `shouldBe` Instance.WfSuspended
  Right hint <- Store.runStoreIO storeHandle $ workflowWakeAfter name wid
  hint `shouldSatisfy` isJust
```

The negative duration makes `fireAt = addUTCTime (-1) now`, so the wake hint is due
the moment the run suspends and `findUnfinishedWorkflowIds` returns the candidate on
every pass — the exact shape of a timer worker that is behind or down. Run the test
and record its failure in Concrete Steps: on current code every pass reports
`advanced = 1`, the loop exhausts its bound of 5, and `length passes` is 5, not 1.
Commit the red test together with the M2 fix (the suite must not be left red on its
own commit); the pre-fix failure is reproducible at any time with the `git stash`
recipe in Concrete Steps.

Acceptance for this milestone is the recorded failure itself: the test encodes the
contract, current code violates it, and the failure output is captured below.

### Milestone 2 — the append witness, truthful counting, and the sleepDue category

Scope: `keiro/src/Keiro/Workflow.hs`, `keiro/src/Keiro/Workflow/Resume.hs`, test
updates in `keiro/test/Main.hs`. At the end, `advanced` counts only durable
movement, the due-sleep candidate is classified `sleepDue`, the M1 test passes with
its new-field assertions added, and the whole `keiro-test` suite is green.

First, the witness. In `keiro/src/Keiro/Workflow.hs`, add a final field to
`WorkflowRunOptions` (near line 389):

```haskell
    -- | When 'Just', invoked once for each fresh journal append this run
    --     commits (every 'JournalAppended' outcome: an executed step, a patch
    --     decision, the patch-set record, the completion marker, and the
    --     rotation marker/seed). Replays, idempotent re-appends, and refused
    --     appends do not fire it, and neither do wake-source writes that touch
    --     no journal (a sleep's timer arm, an awakeable row insert). The resume
    --     worker threads a witness here to count durable movement per candidate
    --     ('ResumeSummary.advanced'). 'Nothing' (the default) observes nothing.
    onJournalAppend :: !(Maybe (IO ()))
```

and `onJournalAppend = Nothing` in `defaultWorkflowRunOptions`. The field is
exported automatically (`WorkflowRunOptions (..)` is already in the export list) and
addressable as `#onJournalAppend` via the existing generic-lens idiom. Add a local
helper inside `runWorkflowWith`'s `where` block (alongside `mMetrics`/`mTracer`):

```haskell
    fireAppendWitness :: Eff es ()
    fireAppendWitness = for_ (options ^. #onJournalAppend) liftIO
```

and call it in exactly the five fresh-append arms enumerated in Context and
Orientation: the `Step` handler's `JournalAppended` arm, the `Patch` handler's
`JournalAppended` arm, `recordPatchSetIfFresh`'s `JournalAppended` arm, and the
completion append's `JournalAppended` arm. For rotation, change the internal
`rotateGeneration` (near line 910; it is not exported) to take the whole
`WorkflowRunOptions` in place of its current `Maybe KeiroMetrics` and `Set PatchId`
parameters, read those two through the options inside, and fire the witness once
when the rotation transaction's outcomes include any `JournalAppended` (the
rotation marker, the seed, or the patch-set append). Update its single call site in
the `WorkflowRotate` catch. Do not fire on `JournalAlreadyPresent`: an idempotent
re-append means another writer already moved the journal, and every such candidate
either leaves discovery on its own (terminal markers) or is advanced by the run's
subsequent fresh appends.

Second, the summary reshape and counting, all in
`keiro/src/Keiro/Workflow/Resume.hs`.

Add the field to `ResumeSummary`, after `paced`:

```haskell
    -- | Candidates that re-suspended without any durable movement while their
    -- instance row still carries an already-due wake hint. Discovery returns
    -- them every pass by design, but only a timer-worker fire (or operator
    -- repair of a cancelled sleep timer) can move them, so a bounded drain must
    -- report them as blocked rather than spin. See ADR 23 and ADR 25.
    sleepDue :: !Int,
```

Update `emptyResumeSummary` (`sleepDue = 0`) and the `Semigroup` instance
(`sleepDue = sleepDue a + sleepDue b`). Refresh the module-header contract recap
(near lines 39-44) to the full current field list, and rewrite the `advanced` field
doc to the witness-based meaning: "Candidates whose durable state moved this pass: a
fresh journal append committed by the re-invocation, a terminal failure recorded at
the crash ceiling, or an external wake observed to have flipped the row back to
running mid-pass. A replay-only re-suspension is not an advance."

Thread the witness through `advance`. In the `ClaimAcquired` branch (near line 465),
allocate `appendedRef <- liftIO (newIORef False)` beside the existing
`progressedRef`, pass it to `driveInstance`, and read it before classifying:

```haskell
ClaimAcquired -> do
  progressedRef <- liftIO (newIORef False)
  appendedRef <- liftIO (newIORef False)
  ( do
      attempt <-
        Error.catchError
          @StoreError
          (AdvOk <$> driveInstance appendedRef owner name wid runDef)
          (\_ e -> pure (AdvTransient e))
          `catch` (\WorkflowLeaseLost -> pure AdvLeaseLost)
          `catchSync` (pure . AdvCrashed)
      recordWorkflowResumed mMetrics 1
      appended <- liftIO (readIORef appendedRef)
      (delta, progressed) <- handleAttempt appended emptyResumeSummary name wid attempt
      liftIO (writeIORef progressedRef progressed)
      pure delta
    )
    `finally` do
      progressed <- liftIO (readIORef progressedRef)
      releaseInstance owner progressed name wid
```

In `driveInstance`, extend the built run options:

```haskell
let runOpts =
      runOptions opts
        & #leaseHeartbeat .~ Just LeaseHeartbeat {owner, ttl = leaseTtl opts}
        & #onJournalAppend .~ Just (writeIORef appendedRef True)
```

Replace `bumpForOutcome` with an effectful, append-aware classifier and change
`handleAttempt`'s `AdvOk` arm to use it (the other arms take the new `appended`
parameter and ignore it):

```haskell
    handleAttempt :: Bool -> ResumeSummary -> WorkflowName -> WorkflowId -> AdvanceResult a -> Eff es (ResumeSummary, Bool)
    handleAttempt appended acc name wid = \case
      AdvOk outcome -> do
        delta <- classifyOutcome appended name wid outcome acc
        pure (delta, True)
      ... -- AdvTransient / AdvLeaseLost / AdvCrashed arms unchanged, including
          -- the crash-ceiling arm's explicit advanced bump.

-- | Fold one re-invocation's outcome into the running summary, counting
-- 'advanced' only for durable movement. The existential result is discarded.
classifyOutcome ::
  (IOE :> es, Store :> es) =>
  Bool -> WorkflowName -> WorkflowId -> WorkflowOutcome a -> ResumeSummary -> Eff es ResumeSummary
classifyOutcome appended name wid outcome acc = case outcome of
  Completed _ -> pure base {completed = completed base + 1}
  ContinuedAsNew -> pure base
  Cancelled -> pure base
  Failed -> pure base
  Suspended
    | appended -> pure base {stillSuspended = stillSuspended base + 1}
    | otherwise -> do
        -- Nothing durable was appended: decide whether this candidate is
        -- parked (leaves discovery), blocked on a due wake hint (rediscovered
        -- forever until a timer fire), or was woken externally mid-pass.
        now <- liftIO getCurrentTime
        row <- lookupInstance name wid
        let suspendedBase = base {stillSuspended = stillSuspended base + 1}
        pure $ case row of
          Just r
            | r ^. #status == WfSuspended,
              Just wake <- r ^. #wakeAfter,
              wake <= now ->
                suspendedBase {sleepDue = sleepDue suspendedBase + 1}
          Just r
            | r ^. #status == WfRunning ->
                -- An external wake landed between the suspend write and this
                -- check: the row moved durably during the pass, so the drain
                -- must run another pass rather than stop under it.
                suspendedBase {advanced = advanced suspendedBase + 1}
          _ -> suspendedBase
  where
    base =
      acc
        { resumed = resumed acc + 1,
          advanced = advanced acc + (if appended then 1 else 0)
        }
```

Extend the `Keiro.Workflow.Instance` import list in `Resume.hs` with
`lookupInstance` and `WorkflowStatus (..)` (both already exported). Note the
deliberate asymmetries: `Cancelled`/`Failed` short-circuits no longer count (they
appended nothing; the terminal row leaves discovery by itself), and a completion
whose marker was already present likewise does not count — both were the "one-time
over-count" cases the review flagged, now fixed under the same rule.

Rewrite the drain documentation. On `resumeWorkflowsOnce` (near lines 372-375):
"A bounded drain repeats while the previous summary reports `advanced > 0`. When a
pass advances nothing, the remaining candidates are blocked in place by pacing,
unregistered definitions, leases, transient errors, or due sleeps awaiting a timer
worker (`sleepDue`), and the caller must stop and report them rather than spin on
`discovered`." Mirror the same list on `resumeWorkflowsOnceUpTo` (near lines
388-395), and state explicitly that a replay-only re-suspension reports no advance.

Third, test updates in `keiro/test/Main.hs`. The compiler enumerates the sites
under this repo's `-Werror`:

- The three full-record `ResumeSummary` constructions (near lines 8228, 8274, 8315)
  gain `sleepDue = 0`.
- `expectedMixedResumeSummary` (near line 11886) changes `advanced = 3` to
  `advanced = 2`: its `neverArmingWorkflow` candidate is a replay-only suspension
  that appends nothing and parks without a hint, so under the honest contract it is
  `stillSuspended` but no longer `advanced`. The healthy completion and the
  ceiling-failed poison remain the two advances. Add `sleepDue = 0` explicitly if
  the partial-update construction style there needs it (it uses
  `emptyResumeSummary {...}`, so it does not, but the `advanced` value change is
  mandatory).
- Extend the M1 test with the new-field assertions: the single drain pass reports
  `sleepDue summary == 1`, and a follow-up manual pass reports the same
  `(discovered, stillSuspended, advanced, sleepDue) == (1, 1, 0, 1)` — the
  falsification of the pre-fix behavior, since `discovered` never reaches zero yet
  the drain terminates.
- The existing drain test (near line 10721), the crash-pacing test, and the
  completion-path tests (near lines 8228 and 8274) keep their `advanced` values:
  completions append their marker, ceiling failures keep the explicit bump, and the
  paced/unregistered pool already reported zero.

Acceptance: `cabal test keiro-test` green, including the previously failing M1 test
with its `sleepDue` assertions.

### Milestone 3 — surface sleepDue through keiro-ops

Scope: `keiro-ops/src/Keiro/Ops/Workflow.hs`, `keiro-ops/test/Main.hs`. At the end,
an operator running `wf resume-once --force` sees the due-sleep blockage in both the
human table and the JSON.

In `resumeSummaryResult` (near line 315), append a `sleep_due` column after `paced`
(before the `unregistered` name column) and a `"sleep_due" .= summary.sleepDue` JSON
key, extending the `counts` list in the same position so headers and rows stay
aligned. Existing keys keep their names and meanings; the change is additive in
rendering shape.

In `keiro-ops/test/Main.hs`, inside `describe "workflow handlers"`, add a sibling of
"reports advanced work and the exact unregistered workflow names" (near line 463)
named "classifies a due sleep with no timer worker as blocked, not advanced": seed a
workflow (`seedStep store ref "received" Aeson.Null`) whose registry definition
durably sleeps in the past —

```haskell
registry =
  Map.singleton
    (WorkflowName "approval")
    (WorkflowDef (\_ -> sleepNamed (StepName "wait") (-1) *> pure ("done" :: Text)))
```

(import `sleepNamed` from `Keiro.Workflow.Sleep` and `StepName` from
`Keiro.Workflow`) — then run the forced `ResumeOnce` command twice through
`runCommandWithResume`. The first forced pass arms the already-due timer and
suspends; assert on it `jsonInteger "discovered" == Just 1`,
`jsonInteger "advanced" == Just 0`, `jsonInteger "still_suspended" == Just 1`, and
`jsonInteger "sleep_due" == Just 1`. The second pass replays only and must report
the identical four values — the CLI-level proof that the drain predicate stops
immediately while the summary names the blockage. Update the two existing resume
examples only if the compiler or a changed rendering width requires it (their
`advanced` values are completion-append advances and stay 1).

Acceptance: `cabal test keiro-ops-test` green with the new example.

### Milestone 4 — documentation, changelogs, ADR amendments, full gate

Scope: `docs/guides/durable-workflows.md`, `docs/user/durable-workflows.md`,
`docs/user/operations.md`, `keiro/CHANGELOG.md`, `keiro-ops/CHANGELOG.md`,
`docs/adr/0023-...md`, `docs/adr/0025-...md`, `docs/adr/log.md`,
`docs/masterplans/40-...md`, this plan.

Guides and user docs. In `docs/guides/durable-workflows.md` (the `ResumeSummary`
parenthetical near line 243 and the "Operational notes" bullets near line 488):
bring the field list current (`discovered`/`advanced`/`resumed`/`completed`/
`stillSuspended`/`unknownName`/`failed`/`transientErrors`/`leaseSkipped`/`paced`/
`sleepDue`/`unregisteredNames`) and add the drain sentence: repeat bounded passes
while `advanced > 0`; a stop with `sleep_due > 0` means the timer worker is behind,
down, or a sleep timer was cancelled — run the timer worker (or the embedded
`yourapp ops timer drain-once --limit N`) rather than more resume passes. Make the
same field-list update in `docs/user/durable-workflows.md` (near line 154) and add
the drain-and-remedy sentence to the "Resume worker" bullet in
`docs/user/operations.md` (near line 340).

Changelogs. In `keiro/CHANGELOG.md` under "Unreleased", rewrite plan 239's existing
Breaking Changes bullet (the one beginning "`Keiro.Workflow.Instance.claimInstance`
now returns `ClaimOutcome` ...") so it describes the final 0.12 shape once, since
both reshapes ship unreleased in the same version: keep the `ClaimOutcome`
sentence, then state that `ResumeSummary` adds `advanced`, `paced`, `sleepDue`, and
`unregisteredNames`; that `advanced` counts only durable movement (a fresh journal
append by the re-invocation, a terminal failure recorded at the crash ceiling, or an
externally delivered wake observed mid-pass) so replay-only re-suspensions and
terminal short-circuit races report zero and bounded drains terminate on every
reachable pool; and that `WorkflowRunOptions` gains `onJournalAppend` (direct record
constructions must initialize it; `defaultWorkflowRunOptions` users are unaffected).
Add a Fixed bullet naming the defect: a workflow suspended on a due sleep with no
timer worker made the documented `advanced > 0` drain loop spin forever. In
`keiro-ops/CHANGELOG.md` under "Unreleased", extend the existing
`wf resume-once` Added bullet with the `sleep_due` column/JSON key and its meaning.

ADR amendments. In
`docs/adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md`,
replace the Decision paragraph that defines `ResumeSummary.advanced` ("counts
candidates whose durable journal or terminal state moved: every successful workflow
outcome and a crash that reaches the failure ceiling ...") with the witness-based
definition: advanced counts a candidate only when its re-invocation committed at
least one fresh journal append, when a crash at the failure ceiling recorded
`WorkflowFailed`, or when an external wake was observed to have returned the row to
`running` mid-pass; a replay-only re-suspension — canonically a due sleep whose
timer worker is behind or down — is not an advance and is reported in the blocked
category `sleepDue`; terminal short-circuit races report no advance and leave the
pool on their own. Extend the drain-driver paragraph's blocked list accordingly. In
`docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`,
amend the Consequences: the suspended-with-due-hint arm keeps returning the
candidate every pass by design, and the resume summary now reports such a candidate
as `sleepDue` rather than `advanced`, so bounded drains terminate while the
instance stays discoverable; note this also covers the previously documented
operator-cancelled-timer shape. Bump each record's frontmatter `timestamp`, add one
`log.md` entry per amendment following the bundle's existing format, and run
`just adr-validate` until clean.

Bookkeeping. Flip EP-2's registry row to Complete and record milestone-level
progress in
`docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md`,
write the Outcomes & Retrospective entry in this plan, and perform the ADR
distillation pass (the durable context — the witness-based advanced definition and
the sleepDue category — lands in the two amended ADRs; execution details stay
here).

Acceptance: `just haskell-test`, `just adr-validate`, and `just verify` all succeed
from the repository root.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.
The Haskell test suites boot their own ephemeral Postgres through the
keiro-test-support template fixture; no external database is needed.

Build after each edit:

```bash
cabal build all
```

Iterate on the new drain test (hspec substring match):

```bash
cabal test keiro-test --test-options='--match "due sleep with no timer worker"'
```

Observed BEFORE the M2 fix:

```text
Keiro.Workflow exact discovery
  a bounded drain loop terminates over a due sleep with no timer worker [✘]

Failures:

  test/Main.hs:10784:21:
  1) Keiro.Workflow exact discovery a bounded drain loop terminates over a due sleep with no timer worker
       expected: 1
        but got: 5

Finished in 0.1812 seconds
1 example, 1 failure
```

(`5` is the drain bound: every pre-fix pass reports `advanced = 1`, so the loop
never stops on its own.) Observed AFTER the fix:

```text
Keiro.Workflow exact discovery
  a bounded drain loop terminates over a due sleep with no timer worker [✔]

Finished in 0.1702 seconds
1 example, 0 failures
```

The full runtime suite also passed:

```text
Finished in 103.4349 seconds
545 examples, 0 failures
```

To
re-demonstrate the failure later, stash the fix and rerun:

```bash
git stash push -- keiro/src/Keiro/Workflow.hs keiro/src/Keiro/Workflow/Resume.hs
cabal test keiro-test --test-options='--match "due sleep with no timer worker"'
git stash pop
```

(While stashed, the test file's `sleepDue` assertions added in M2 will not compile
against the stashed library; the pure red form from M1 — bound, tuple, counter, and
row assertions only — is the one to demonstrate, so capture the red output before
adding the `sleepDue` assertions.)

Milestone suites and the full gates:

```bash
cabal test keiro-test
cabal test keiro-ops-test
just haskell-test
just adr-validate
just verify
```

Expected: each suite prints `N examples, 0 failures` (keiro-test is the slow,
DB-backed one); `just adr-validate` prints the strict OKF validation success for
`docs/adr`; `just verify` runs the whole repository gate chain and exits 0.

Milestone 3 observed both the focused operator proof and the full suite:

```text
workflow handlers
  classifies a due sleep with no timer worker as blocked, not advanced [✔]

Finished in 0.1754 seconds
1 example, 0 failures

Finished in 7.1707 seconds
42 examples, 0 failures
```

### Commit and trailer convention

Commit per milestone using Conventional Commits, and include on every commit the
trailers:

```text
MasterPlan: docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/251-count-only-durable-progress-in-workflow-resume-summaries.md
Intention: intention_01kzw6dkcserms9yr61sqdntep
```

Suggested subjects:

```text
test(workflow): reproduce the non-terminating due-sleep resume drain
fix(workflow)!: count only durable movement as an advancing resume pass
feat(ops): report sleep_due blockage in wf resume-once
docs(adr): record the witness-based advanced contract and the sleepDue category
```


## Validation and Acceptance

Acceptance is behavioral, in four parts.

1. Drain termination on the due-sleep pool. The new keiro-test example passes: after
   arming a sleep whose fire time is already past and running no timer worker, an
   `advanced > 0` drain loop stops after exactly one pass reporting
   `(discovered, resumed, stillSuspended, advanced, sleepDue) = (1, 1, 1, 0, 1)`;
   the step counter proves the pass was replay-only; the instance row remains
   `suspended` with a due wake hint (still discoverable, honestly blocked). The
   same test fails before the fix with the drain bound exhausted (`5` passes), and
   that failure output is captured in Concrete Steps.

2. Truthful advanced semantics elsewhere. The updated mixed-pool expectation
   (`expectedMixedResumeSummary`) passes with `advanced = 2`: the completing and
   ceiling-failing candidates count, the replay-only suspension does not. All
   pre-existing completion, crash-pacing, poison-isolation, and drain tests pass
   with unchanged values.

3. Operator surface. `cabal test keiro-ops-test` passes including the new example:
   two consecutive forced `wf resume-once` passes over the due-sleep pool each
   render `"advanced": 0`, `"still_suspended": 1`, `"sleep_due": 1` (and the
   matching human column), so a compliant CLI drain stops immediately with the
   blockage named. Equivalently, in an embedded binary,
   `yourapp ops wf resume-once --limit 10 --force --json` now prints `sleep_due`.

4. No regressions and durable records. `just haskell-test` and `just verify` are
   green; `just adr-validate` passes with ADR 0023 and ADR 0025 amended and logged;
   both package changelogs describe the final unreleased shape (the plan-239 keiro
   bullet rewritten rather than contradicted).


## Idempotence and Recovery

Every step is safe to repeat. All edits are ordinary source and documentation edits
guarded by the test suites; each DB-backed example runs in a fresh clone of the
template database that is dropped afterwards, so re-running any `cabal test` or
`just` command is side-effect-free. There is no schema migration and no data
backfill; recovery from a bad intermediate state is `git checkout -- <file>` or a
`git stash` of the affected files. The milestones leave the tree compiling and
green at each boundary: M1's test commits together with M2's fix, M3 is additive
rendering, M4 is documentation. If an interruption loses partial test edits, the
compiler reconstructs the required call-site updates — `-Werror` missing-field
warnings enumerate every `ResumeSummary` construction, and the `handleAttempt`
signature change flags its uses. The witness field is additive with a `Nothing`
default, so any application code built mid-milestone behaves exactly as before.


## Interfaces and Dependencies

No new packages, no new modules, no schema changes. All work stays inside the
existing `keiro` and `keiro-ops` packages against already-depended-on libraries.
The signatures that must exist at the end:

In `Keiro.Workflow` (`keiro/src/Keiro/Workflow.hs`) — one added options field
(breaking for direct record construction; `defaultWorkflowRunOptions` gains the
`Nothing` default):

```haskell
data WorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy :: !(SnapshotPolicy WorkflowState),
    pageSize :: !Int32,
    metrics :: !(Maybe KeiroMetrics),
    tracer :: !(Maybe Tracer),
    activePatches :: !(Set PatchId),
    leaseHeartbeat :: !(Maybe LeaseHeartbeat),
    onJournalAppend :: !(Maybe (IO ()))
  }
```

`runWorkflow`, `runWorkflowWith`, and `Keiro.Workflow.Child.runChildWorkflow` keep
their signatures; the internal `rotateGeneration` changes to take
`WorkflowRunOptions` in place of its metrics and patch-set parameters (not
exported, single call site).

In `Keiro.Workflow.Resume` (`keiro/src/Keiro/Workflow/Resume.hs`) — the reshaped
summary (breaking; `Semigroup`/`Monoid` preserved with field-wise addition):

```haskell
data ResumeSummary = ResumeSummary
  { discovered :: !Int,
    advanced :: !Int,
    resumed :: !Int,
    completed :: !Int,
    stillSuspended :: !Int,
    unknownName :: !Int,
    failed :: !Int,
    transientErrors :: !Int,
    leaseSkipped :: !Int,
    paced :: !Int,
    sleepDue :: !Int,
    unregisteredNames :: !(Set Text)
  }
```

`resumeWorkflowsOnce` and `resumeWorkflowsOnceUpTo` keep their signatures; only
their counting behavior and documented drain contract change. `ClaimOutcome` and
`claimInstance` in `Keiro.Workflow.Instance` are untouched; `Resume.hs` additionally
imports `lookupInstance` and `WorkflowStatus (..)` from that module (both already
exported; the module graph is unchanged). In `Keiro.Ops.Workflow`
(`keiro-ops/src/Keiro/Ops/Workflow.hs`), `resumeSummaryResult :: ResumeSummary ->
OpsResult` keeps its signature and gains the `sleep_due` column and JSON key.
`jitsurei/app/Main.hs` prints summaries via `show` and compiles unchanged.

---

Revision note (2026-08-13): initial authoring — fleshed out the skeleton into the
full plan after reading `Resume.hs`, `Workflow.hs`, `Journal.hs`, `Sleep.hs`,
`Schema.hs`, `Instance.hs`, `Instance/Schema.hs`, `Child.hs`, the keiro-ops
resume command and tests, the existing drain-termination and mixed-pool tests,
plan 239 (commit `9c4b431f`), and ADRs 7, 23, and 25; the detection-mechanism and
classification choices are recorded in the Decision Log.
