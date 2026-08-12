---
id: 239
slug: close-the-awakeable-cancel-versus-suspend-race-and-fix-the-drain-contract
title: "Close the awakeable cancel-versus-suspend race and fix the drain contract"
kind: exec-plan
created_at: 2026-08-11T23:37:31Z
intention: "intention_01kzsjzp13e28vvrz7jfdve3dt"
master_plan: "docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md"
---

# Close the awakeable cancel-versus-suspend race and fix the drain contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This plan fixes two confirmed defects from the 2026-08-11 pre-0.12 release review, both in
the durable-workflow lifecycle surface of the `keiro` package (EP-3 of
`docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md`).

Defect A: cancelling an awakeable (`cancelAwakeable` in
`keiro/src/Keiro/Workflow/Awakeable.hs`) can race a concurrent run that is suspending on
that same awakeable. If the cancel commits first and the run's stale suspend write commits
second, the workflow's instance row ends up `suspended` with no wake hint. Since exact
discovery shipped (commit `f0171e72`, migration
`keiro-migrations/migrations/0021-keiro-workflows-exact-discovery.sql`,
`docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`),
such a row is never returned by `findUnfinishedWorkflowIds`, and signalling a cancelled
awakeable transitions nothing — the workflow is stranded forever and never observes
`WorkflowAwakeableCancelled`. Before exact discovery the old broad sweep re-examined every
non-terminal instance each pass, so this race self-healed; exact discovery silently turned
it into a permanent stranding. After this plan, cancellation serializes with the suspend
write under the same per-step advisory-lock discipline the signal path already uses, so
whichever writer commits second observes the other and the workflow always stays
discoverable.

Defect B: `resumeWorkflowsOnceUpTo` in `keiro/src/Keiro/Workflow/Resume.hs` documents that
"a caller can safely repeat bounded passes until it reaches zero" (its `discovered` count).
That contract is false: an instance that is discovered but cannot advance — a crashed
workflow paced by `claimInstance`'s `next_attempt_at` backoff gate, or a workflow whose
name is absent from the registry — counts toward `discovered` on every pass without ever
leaving the pool, so a compliant drain-until-zero driver never terminates. After this plan,
the per-pass `ResumeSummary` distinguishes instances that ADVANCED (their durable journal
or terminal state moved) from instances that were discovered but blocked in place (paced
crash retries, unregistered names, foreign leases), the documented drain contract is
"repeat while `advanced > 0`", and the `keiro-ops` `wf resume-once` output surfaces the
distinction, including which workflow names are unregistered.

How to see it working: the new cancel-versus-suspend interleaving tests (both commit
orders) pass in `cabal test keiro-test` and the cancel-lands-first order demonstrably fails
on the pre-fix code; the new drain-termination test shows a bounded drain loop over a pool
containing one crashed and one unregistered workflow terminating in one pass; and
`keiro-ops wf resume-once --force --json` reports `advanced`, `paced`, and
`unregistered_names` alongside the existing counts.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: add the cancel-lands-first interleaving test to `keiro/test/Main.hs` and observe it fail on current code (instance stays `suspended`)
- [ ] M1: add the suspend-lands-first interleaving test (documents the order the current cancel upsert already wins)
- [ ] M1: broaden the suspend re-check in `markInstanceSuspendedAwaiting` (`keiro/src/Keiro/Workflow/Instance.hs`) to consult the awakeable row's terminal status for `awk:`-prefixed awaited steps
- [ ] M1: take the per-step advisory lock in `cancelAwakeable` (`keiro/src/Keiro/Workflow/Awakeable.hs`), deriving the lock key from the owner row and current generation
- [ ] M1: both interleaving tests pass; full `cabal test keiro-test` green
- [ ] M2: change `claimInstance` to return a `ClaimOutcome` that distinguishes acquired / lease-held / paced / unavailable
- [ ] M2: extend `ResumeSummary` with `advanced`, `paced`, and `unregisteredNames`; update `emptyResumeSummary`, the `Semigroup` instance, and every bump site in `Resume.hs`
- [ ] M2: rewrite the `resumeWorkflowsOnce` / `resumeWorkflowsOnceUpTo` haddock to state the honest drain contract
- [ ] M2: update the existing full-record `ResumeSummary` assertions and `claimInstance` call sites in `keiro/test/Main.hs`
- [ ] M2: add the drain-termination test (one crashed + one unregistered workflow; loop on `advanced > 0` terminates; `discovered` provably never reaches zero)
- [ ] M2: add claim-classification assertions (paced after a recorded crash; lease-held under a live foreign lease)
- [ ] M3: extend `resumeSummaryResult` in `keiro-ops/src/Keiro/Ops/Workflow.hs` with the new columns and JSON keys
- [ ] M3: extend the keiro-ops resume test in `keiro-ops/test/Main.hs` to cover `advanced` and `unregistered_names`
- [ ] M4: CHANGELOG entries (breaking API change + bug fixes) under Unreleased
- [ ] M4: amend `docs/adr/0023` (cancel joins the per-step lock discipline; suspend arbitration consults the awakeable row) and `docs/adr/0025` (pass summaries distinguish advanced from blocked; drain termination), record both in `docs/adr/log.md`, run `just adr-validate`
- [ ] M4: tick EP-3 checkboxes and registry status in `docs/masterplans/37-...md`
- [ ] M4: `just haskell-test` and `just verify` green; Outcomes & Retrospective written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Cancellation serializes via the per-step advisory lock plus a broadened
  suspend re-check; it does NOT write a `keiro_workflow_steps` row.
  Rationale: The signal path wins its race because `prepareJournalAppend` holds the
  per-step advisory lock while writing the step-index row and the instance upsert in one
  transaction, and `markInstanceSuspendedAwaiting` re-checks that step index under the same
  lock. Cancellation has no result value, and a fabricated step row would be returned as
  the awaited step's resolved value by the ADR-5 index fallback
  (`docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`) —
  replay would decode garbage instead of throwing `WorkflowAwakeableCancelled`. So the
  step-visible artifact the suspend re-check consults for `awk:` steps becomes the
  awakeable row's own terminal status, which ADR-6 already names the durable authority for
  wake-source lifecycle.
  Date: 2026-08-11
- Decision: The broadened re-check treats ANY terminal awakeable status (`Cancelled` or
  `Completed`) as "write `running`", not only `Cancelled`.
  Rationale: A `Completed` row without a step-index row can only be a historical wedge
  (the atomic signal path writes both together), and the await arm's existing
  self-repair appends the journal entry from the stored payload on the next run — but only
  if the workflow is discoverable. Treating both terminal statuses identically costs the
  same single point-read and closes the residual wedge class for free.
  Date: 2026-08-11
- Decision: `cancelAwakeable` derives the lock-key generation with `currentGeneration`
  before its transaction, exactly as `signalAwakeableFrom` does, and keeps passing
  generation 0 to the instance upsert.
  Rationale: Two writers are ordered only if they derive the identical
  `workflowStepLockKey`, whose components include the generation; the suspending run
  passes the generation it ran on, which is the current generation while it is parked
  (a parked run cannot rotate concurrently). Mirroring the signal path keeps one
  discipline. The upsert's generation-0 argument preserves the existing
  "GREATEST(stored, supplied), never revives a terminal instance" semantics untouched.
  Date: 2026-08-11
- Decision: `claimInstance` changes its return type from `Bool` to a new `ClaimOutcome`
  (`ClaimAcquired | ClaimLeaseHeld | ClaimPaced | ClaimUnavailable`) rather than adding a
  parallel function.
  Rationale: The pass summary cannot distinguish "paced by backoff" from "another worker
  holds the lease" without the claim path saying why it refused; a single honest API beats
  a Bool wrapper that hides the reason. The 0.12.0.0 release is a major version, so the
  breaking change is legal and is recorded in the CHANGELOG. All call sites live in
  `keiro/src/Keiro/Workflow/Resume.hs` and `keiro/test/Main.hs`.
  Date: 2026-08-11
- Decision: `ResumeSummary` gains `advanced :: Int`, `paced :: Int`, and
  `unregisteredNames :: Set Text`. `advanced` counts candidates whose durable state moved
  this pass: every `AdvOk` outcome (completed, suspended, cancelled, failed,
  continued-as-new) plus a crash that reached the failure ceiling and appended
  `WorkflowFailed`. A sub-ceiling crash, a transient store error, a lease skip, a paced
  claim, and an unknown name are not advances.
  Rationale: "Advanced" must mean "the pool is converging". A sub-ceiling crash writes
  only pacing state (`attempts`/`next_attempt_at`), and treating it as progress would keep
  a drain loop spinning against the backoff gate; the very next pass reports it `paced`,
  so the loop terminates either way, but the stricter definition stops one pass earlier
  and reports the truth.
  Date: 2026-08-11
- Decision: The documented drain contract becomes "repeat bounded passes while
  `advanced > 0`; when a pass advances nothing, stop and report the remaining pool".
  Rationale: `discovered` is pool size, not progress. A pass whose only activity is
  transient store errors also reports `advanced == 0` and stops; for an operator-facing
  bounded drain, an honest stop-and-report (rerun after the blip) is better than spinning.
  This is the ADR-25 partial-progress principle applied to the drain driver.
  Date: 2026-08-11
- Decision: `ClaimUnavailable` (the instance vanished or went terminal between discovery
  and claim) is counted in `leaseSkipped`, and the `keiro.workflow.lease.skipped`
  telemetry counter keeps firing for all three non-acquired claim outcomes.
  Rationale: The instance self-resolves out of the pool next pass, so it threatens
  neither termination nor honesty; keeping it in the existing bucket avoids a
  one-in-a-million summary field, and keeping the EP-44 metric's meaning ("claims that
  did not acquire") unchanged avoids a silent telemetry semantic break.
  Date: 2026-08-11
- Decision: Unregistered workflow names are surfaced as a distinct operator-visible
  condition: the summary carries the deduplicated name set and `keiro-ops wf resume-once`
  renders it (`unregistered` column, `unregistered_names` JSON array).
  Rationale: A drain that stops with `unknown_name > 0` is only actionable if the operator
  learns WHICH names need registry entries (a deploy dropped code while instances were in
  flight). The per-item stderr log already names them, but the `--json` consumer sees only
  counts today.
  Date: 2026-08-11
- Decision: The interleaving tests reuse the deterministic interposition technique of the
  existing signal-versus-suspend tests ("writes running when the wake landed before the
  suspend write", `keiro/test/Main.hs` around line 10160): after a real run suspends, the
  test calls `Instance.markInstanceSuspendedAwaiting` directly to replay the run's stale
  suspend write at a chosen point relative to the external transition. No threads or
  latches.
  Rationale: `markInstanceSuspendedAwaiting` is exactly the write a run performs after its
  stale index miss, so calling it directly reproduces each commit order deterministically;
  the advisory lock guarantees there is no third interleaving to test.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This is a Haskell multi-package repository. The packages touched here are `keiro` (the
durable-execution runtime library, sources under `keiro/src/`, one hspec test suite at
`keiro/test/Main.hs` named `keiro-test`) and `keiro-ops` (the operational CLI library,
sources under `keiro-ops/src/`, test suite `keiro-ops-test` at `keiro-ops/test/Main.hs`).
Package versions are still 0.11.0.0 in the cabal files; the work in flight (including this
plan) ships as the 0.12.0.0 major release, so breaking API changes are legal here and go
in `CHANGELOG.md` under "Unreleased". No database migration is needed by this plan — both
fixes are code-level.

Vocabulary, defined from scratch:

A "workflow" is application Haskell code re-invoked against a durable journal: each named
step's result is recorded once (an event in a per-workflow stream plus a row in the derived
`keiro.keiro_workflow_steps` index, written in the same transaction), and re-running the
workflow replays recorded steps and executes only the un-journaled tail. An "awakeable" is
a durable promise: the workflow allocates an opaque UUID, hands it to an external system,
and suspends; the external system later calls `signalAwakeable` (deliver a result) or
`cancelAwakeable` (abandon the promise). Awakeable rows live in `keiro.keiro_awakeables`
(`keiro/src/Keiro/Workflow/Awakeable/Schema.hs`) with status `pending`, `completed`, or
`cancelled`. A workflow re-entering the await of a cancelled awakeable throws
`WorkflowAwakeableCancelled` so the author can run compensation.

The "instance row" is one row per logical workflow in `keiro.keiro_workflows`
(`keiro/src/Keiro/Workflow/Instance.hs` and `Instance/Schema.hs`) carrying `status`
(`running`/`suspended`/terminal), crash pacing (`attempts`, `next_attempt_at`), a lease
(`leased_by`, `lease_expires_at`), and the sleep-timer hint `wake_after`. The "resume
worker" (`keiro/src/Keiro/Workflow/Resume.hs`) discovers work with one query,
`findUnfinishedWorkflowIds` (`keiro/src/Keiro/Workflow/Schema.hs`, statement at line
~385): it returns instances with `status = 'running'`, or `status = 'suspended'` with a
due `wake_after`. This is "exact discovery" (ADR 23): a suspended instance with no due
hint is deliberately invisible, so every path that resolves or abandons a wake source MUST
leave the instance row discoverable in the same transaction. The instance row is thus "the
complete wake ledger".

A "per-step advisory lock" is a transaction-scoped Postgres advisory lock
(`pg_advisory_xact_lock`) keyed by `workflowStepLockKey wid name generation stepName`
(`keiro/src/Keiro/Workflow/Schema.hs` line ~112). Two writers are totally ordered only
when they derive the identical key.

How the three writers behave today:

The signal path: `signalAwakeable` / `signalAwakeableFrom`
(`keiro/src/Keiro/Workflow/Awakeable.hs` lines ~306-369) resolves the owner coordinates
and current generation, then in one transaction flips the row `pending -> completed` and
runs the prepared journal append. That append transaction
(`keiro/src/Keiro/Workflow/Journal.hs`, `prepareJournalAppend`, lines ~61-116) takes the
per-step advisory lock on the awaited step name (`awk:<uuid>`), checks the step index for
idempotency, appends the `StepRecorded` event, writes the `keiro_workflow_steps` row
(`recordStepTx`), and upserts the instance row to `running` — all under the lock.

The suspend path: a run that misses its awaited step unwinds
(`keiro/src/Keiro/Workflow.hs` line ~600) to `markInstanceSuspendedAwaiting`
(`keiro/src/Keiro/Workflow/Instance.hs` lines ~163-177), which takes the same per-step
advisory lock, re-checks ONLY the step index (`lookupStepResultTx`), and writes
`suspended` when the step is absent, `running` when present. Because the signal path
writes the step row under the same lock, signal-versus-suspend converges in both orders —
that is exactly what the two existing tests at `keiro/test/Main.hs` lines ~10160-10207
prove ("writes running when the wake landed before the suspend write" and "flips a
suspended instance to running when the wake lands after the suspend write").

The cancel path — Defect A: `cancelAwakeable`
(`keiro/src/Keiro/Workflow/Awakeable.hs` lines ~404-411) runs one transaction with NO
advisory lock: `cancelAwakeableTx` (guarded UPDATE `pending -> cancelled`, returning the
owner coordinates) then `upsertInstanceTx owner 0 WfRunning Nothing`. It writes no
journal entry and no step row (there is no result value). The race: a run misses the
awakeable step, arms, and unwinds toward `markInstanceSuspendedAwaiting`; concurrently
`cancelAwakeable` commits (row `cancelled`, instance `running`). The suspend write then
takes the lock, re-checks the step index, finds nothing (cancellation never writes a step
row), and commits `suspended` with no wake hint. Nothing will ever flip it back:
`findUnfinishedWorkflowIds` never returns it, and `signalAwakeable` on a `cancelled` row
returns `False` without appending or touching the instance (`signalAwakeableFrom`'s first
guard). The workflow never reaches its await arm and never observes
`WorkflowAwakeableCancelled`. The existing test at lines ~10041-10067 ("flips the owner
instance to running when its awakeable is cancelled") covers only the no-contention case;
no test covers cancel racing a concurrent suspend in either order.

The drain contract — Defect B: `resumeWorkflowsOnceUpTo`
(`keiro/src/Keiro/Workflow/Resume.hs` lines ~357-389) admits at most `limit` discovered
candidates and its haddock states "The summary's 'discovered' count is the number admitted
to this pass, so a caller can safely repeat bounded passes until it reaches zero." But a
candidate can be discovered on every pass without ever leaving the pool: a crashed
workflow keeps `status = 'running'` (discovery returns it) while `claimInstance`'s
`next_attempt_at` gate (`keiro/src/Keiro/Workflow/Instance.hs`, `claimInstanceStmt` lines
~460-482) refuses the claim, reported only as `leaseSkipped`; and a workflow whose name is
absent from the registry is skipped as `unknownName` forever. The test at lines
~10238-10259 ("keeps a crashed workflow discovered while its backoff gate paces retries")
documents the pacing behavior. A compliant drain-until-zero driver therefore never
terminates. `keiro-ops` exposes this entry point as `wf resume-once`
(`keiro-ops/src/Keiro/Ops/Workflow.hs`, `runResumeOnce` lines ~289-303, rendering in
`resumeSummaryResult` lines ~321-349); the pass summary is also what jitsurei's demo
prints (`jitsurei/app/Main.hs`, `show`n only, so it compiles unchanged).

Relevant ADRs, all local (no relevant cross-repository ADR was found; the mori registry
was consulted during MasterPlan 37 planning and none applies):

- `docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`
  — discovery is exact; every wake-source lifecycle transition must leave the instance
  discoverable in the same transaction; the suspend write arbitrates under the append
  path's per-step lock against the step index. Defect A is a hole in exactly this
  contract: cancellation writes the instance row but does not serialize with the suspend
  arbitration, and the arbitration cannot see it. M4 amends this ADR.
- `docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md` — wake
  source rows (`keiro_awakeables`) are the durable authority for exposure and terminal
  lifecycle; terminal row transitions and journal delivery are arbitrated in one
  transaction; a winning cancellation gets no journal append. The fix leans on this: the
  awakeable row's terminal status is the artifact the suspend re-check consults.
- `docs/adr/0027-workflow-lifecycle-markers-are-append-only-and-first-writer-wins.md` —
  workflow-level lifecycle markers arbitrate under a generation lifecycle lock;
  first-writer-wins; history is never rewritten. Constrains the fix: cancellation must not
  fabricate journal history, which is why no step row is written.
- `docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md` — the
  step index is authoritative for awaited results; anything present there is returned as
  the awaited value. This is why cancel must NOT write a step row (see Decision Log).
- `docs/adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md`
  — worker summaries must count work finished, not work attempted. Defect B is this
  principle applied to the drain driver's termination signal. M4 amends this ADR.

Testing infrastructure: `keiro/test/Main.hs` (one ~15k-line hspec module) runs against a
suite-level ephemeral-Postgres template fixture from
`keiro-test-support/src/Keiro/Test/Postgres.hs`: `main = withMigratedSuite $ \fixture ->
hspec $ ...` migrates one template database once, and `around (withFreshStore fixture)`
clones a fresh migrated database per example — never migrate per example. Test helpers
live near the bottom of the file: `approvalFlowWithId` (line ~11611) allocates an
awakeable named "approval", publishes its id through an `IORef`, awaits, then records a
step "use"; `readRequiredAwakeableId` (line ~11696) reads the ref. The keiro-ops suite
uses the same fixture pattern with helpers `seedStep`, `workflowStatus`, `jsonInteger`,
`opsEnv` (see `keiro-ops/test/Main.hs` around lines 260-290).


## Plan of Work

### Milestone 1 — close the cancel-versus-suspend race

Scope: `keiro/src/Keiro/Workflow/Instance.hs`, `keiro/src/Keiro/Workflow/Awakeable.hs`,
tests in `keiro/test/Main.hs`. At the end of this milestone, cancellation and the suspend
write are totally ordered under the per-step advisory lock, both commit orders leave the
workflow discoverable, and two new interleaving tests prove it — with the cancel-first
test having been observed to fail before the fix.

Write the failing test first. In `keiro/test/Main.hs`, inside the
`describe "Keiro.Workflow exact discovery"` block, directly after the existing
signal-order pair (after the test ending near line 10207), add a test named
"stays discoverable when a cancel lands before the stale suspend write". Body, following
the existing pattern exactly: allocate an `IORef`, run `runWorkflow name wid
(approvalFlowWithId aidRef)` and pattern-match `Right Suspended`; read the id with
`readRequiredAwakeableId`; `cancelAwakeable aid` and assert `Right True`; then replay the
run's stale suspend write with `Instance.markInstanceSuspendedAwaiting name wid 0
(awakeableStepPrefix <> awakeableIdText aid)`; assert the instance status is
`Instance.WfRunning`; assert `findUnfinishedWorkflowIds now` returns the pair; run
`resumeWorkflowsOnce` with a registry mapping the name to `approvalFlowWithId aidRef` and
a silenced `logEvent`, and assert the pass discovered and resumed 1 with 0 completed;
finally assert the instance row has `attempts == 1` and `lastError` containing
`"WorkflowAwakeableCancelled"` (this mirrors the assertions of the existing
cancel-visibility test at line ~10041). Run this test and record its failure: on current
code the status assertion reports `WfSuspended`, the discovery assertion reports `[]`.

Add the second order in the same block: "flips a suspended instance to running when the
cancel lands after the suspend write". Same setup, but call
`markInstanceSuspendedAwaiting` BEFORE `cancelAwakeable`: assert the instance is
`WfSuspended` and invisible to discovery after the suspend write, then cancel, assert
`WfRunning` and discoverable, then the same resume-pass and crash-recording assertions.
This order already passes on current code (the cancel-side upsert wins the wake race); it
is added to pin the contract from both sides.

Now the fix, part one — make the suspend arbitration able to observe a committed cancel.
In `keiro/src/Keiro/Workflow/Instance.hs`, extend `markInstanceSuspendedAwaiting`: after
the existing `lookupStepResultTx` re-check returns `Nothing`, and only when the awaited
step name carries the awakeable prefix, look up the awakeable row's status in the same
transaction and treat a terminal status as "resolved". Concretely:

```haskell
markInstanceSuspendedAwaiting (WorkflowName nameText) (WorkflowId widText) gen awaitedStep =
  runTransaction $ do
    lockWorkflowStepTx (workflowStepLockKey widText nameText gen awaitedStep)
    resolved <- lookupStepResultTx widText nameText gen awaitedStep
    abandoned <- case resolved of
      Just _ -> pure False
      Nothing -> case awakeableUuidFromStep awaitedStep of
        Nothing -> pure False
        Just aid ->
          maybe False (/= Pending) <$> lookupAwakeableStatusTx aid
    let status = if isJust resolved || abandoned then WfRunning else WfSuspended
    upsertInstanceTx widText nameText (fromIntegral gen) status Nothing

awakeableUuidFromStep :: Text -> Maybe UUID
awakeableUuidFromStep stepName =
  UUID.fromText =<< Text.stripPrefix awakeableStepPrefix stepName
```

Imports to add to `Instance.hs`: `AwakeableStatus (..)` and `lookupAwakeableStatusTx`
from `Keiro.Workflow.Awakeable.Schema` (that module imports no workflow modules, so no
import cycle — verify with `cabal build keiro`), `awakeableStepPrefix` added to the
existing `Keiro.Workflow.Types` import list, `Data.UUID (UUID)` plus
`Data.UUID qualified as UUID`. Extend the function's haddock (lines ~138-162): the
re-check now consults the step index AND, for an awakeable await, the wake-source row
that ADR 6 makes authoritative, because awakeable cancellation is the one wake transition
that resolves an await without a step row. Sleeps and children are unaffected: their
prefixes fail the `stripPrefix`, so they pay nothing.

Part two — order the cancel against the suspend write. In
`keiro/src/Keiro/Workflow/Awakeable.hs`, rewrite `cancelAwakeable` (keeping its
`(Store :> es) => AwakeableId -> Eff es Bool` signature) to mirror
`signalAwakeableFrom`'s preamble: read the row first for the owner coordinates, resolve
the current generation, then take the per-step lock inside the transaction before the
guarded transition:

```haskell
cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool
cancelAwakeable aid =
  lookupAwakeable (awakeableIdToUuid aid) >>= \case
    Nothing -> pure False
    Just row -> do
      let ownerName = WorkflowName (row ^. #ownerWorkflowName)
          ownerId = WorkflowId (row ^. #ownerWorkflowId)
      gen <- currentGeneration ownerName ownerId
      runTransaction $ do
        lockWorkflowStepTx
          ( workflowStepLockKey
              (unWorkflowId ownerId)
              (unWorkflowName ownerName)
              gen
              (awakeableStepPrefix <> awakeableIdText aid)
          )
        cancelAwakeableTx (awakeableIdToUuid aid) >>= \case
          Nothing -> pure False
          Just (ownerNameText, ownerIdText) -> do
            upsertInstanceTx ownerIdText ownerNameText 0 WfRunning Nothing
            pure True
```

Imports to add: `lockWorkflowStepTx` and `workflowStepLockKey` from
`Keiro.Workflow.Schema` (and note `currentGeneration` is already imported from
`Keiro.Workflow`). The pre-read is advisory only (lock-key derivation); correctness still
rests on the in-transaction `status = 'pending'` guard, exactly as the signal path treats
its possibly-stale row. Unknown ids still return `False` from the pre-read. Update the
function's haddock: cancellation is now serialized with the suspend write under the same
per-step lock as every other writer of that step, so either cancel commits first and the
suspend re-check observes the `cancelled` row (workflow stays discoverable and its next
run throws `WorkflowAwakeableCancelled`), or suspend commits first and cancel's instance
upsert flips `suspended` to `running`.

Why both parts are needed: the lock alone orders the transactions but the pre-fix
re-check consults only the step index, which cancel never writes — so a cancel that
commits first would still be invisible to the suspend write. The re-check broadening
alone closes the observed stranding for a fully-committed cancel, but without the lock a
cancel could commit BETWEEN the suspend transaction's re-check and its commit, recreating
the window. Together they reproduce exactly the signal path's proven discipline.

Acceptance: both new tests pass; the previously-failing one now passes; the whole
`keiro-test` suite is green (the existing cancel-visibility, signal-order, and
awakeable-cancellation tests must not regress).

### Milestone 2 — honest claim outcomes and the advanced-versus-blocked pass summary

Scope: `keiro/src/Keiro/Workflow/Instance.hs`, `keiro/src/Keiro/Workflow/Resume.hs`,
tests in `keiro/test/Main.hs`. At the end, a drain driver has a sound termination
predicate, documented, and a test proves a drain loop over an un-advanceable pool
terminates.

First, teach the claim to say why it refused. In `Instance.hs`, add:

```haskell
-- | Why 'claimInstance' did or did not acquire the advance lease.
data ClaimOutcome
  = -- | This caller now holds the lease.
    ClaimAcquired
  | -- | Another live lease exists; the instance is being advanced elsewhere.
    ClaimLeaseHeld
  | -- | The crash-backoff gate (@next_attempt_at@) is still in the future.
    ClaimPaced
  | -- | The row is terminal or gone; it will drop out of discovery by itself.
    ClaimUnavailable
  deriving stock (Generic, Eq, Show)
```

and change `claimInstance` to return `Eff es ClaimOutcome`. Implementation: keep the
existing transaction (`ensureInstanceStmt` then the guarded `claimInstanceStmt` UPDATE);
when the UPDATE matches, return `ClaimAcquired`; otherwise run a classification SELECT in
the same transaction against the same `now` the UPDATE used:

```sql
SELECT status, lease_expires_at, next_attempt_at
FROM keiro.keiro_workflows
WHERE workflow_id = $1 AND workflow_name = $2
```

and decode: no row or status not in (`running`,`suspended`) -> `ClaimUnavailable`; else a
`lease_expires_at` at or after `now` -> `ClaimLeaseHeld`; else a `next_attempt_at` after
`now` -> `ClaimPaced`; else `ClaimUnavailable` (a concurrent claim committed between the
two statements; under read-committed the SELECT sees its lease, so this arm is a
belt-and-braces fallback). Export `ClaimOutcome (..)` from `Instance.hs`. Precedence note
for the haddock: a live lease outranks pacing because a leased instance is being advanced
by someone, which is the more truthful report.

Second, reshape the summary. In `Resume.hs`, extend `ResumeSummary` with three fields
(full record shown in Interfaces and Dependencies): `advanced` (candidates whose durable
journal or terminal state moved this pass), `paced` (claims refused by the backoff gate),
and `unregisteredNames` (deduplicated `Set Text` of names absent from the registry;
`Data.Set` import needed, `Semigroup` combines with union). Rewrite `emptyResumeSummary`
with record syntax so future field additions cannot silently misalign positionally.
Update the `Semigroup` instance. Bump sites:

- `advance`, registry miss: `unknownName = 1` and
  `unregisteredNames = Set.singleton wnameText`.
- `advance`, claim refusal: `ClaimLeaseHeld` -> `leaseSkipped = 1`; `ClaimPaced` ->
  `paced = 1`; `ClaimUnavailable` -> `leaseSkipped = 1`. All three keep calling
  `recordWorkflowLeaseSkipped mMetrics 1` (see Decision Log).
- `bumpForOutcome`: every arm additionally sets `advanced = advanced acc + 1`.
- `handleAttempt`, `AdvCrashed` at the failure ceiling: add `advanced = 1` to the delta
  it already builds (`WorkflowFailed` was appended; the instance left the pool).
  Sub-ceiling crashes, `AdvTransient`, and `AdvLeaseLost` do not bump `advanced`.

Third, fix the lie. Rewrite the haddock of `resumeWorkflowsOnceUpTo` (and touch up
`resumeWorkflowsOnce` and the `ResumeSummary` field docs): `discovered` is the pool size
admitted to the pass and is NOT a termination signal, because paced crash retries and
unregistered names are re-discovered every pass without leaving the pool. The supported
drain contract: repeat bounded passes while the previous pass reported `advanced > 0`;
when a pass advances nothing, every remaining candidate is blocked in place (`paced`,
`unknownName` — names listed in `unregisteredNames` — `leaseSkipped`, or
`transientErrors`) and the driver must stop and report rather than spin.

Fourth, tests. Update the existing full-record `ResumeSummary` assertions in
`keiro/test/Main.hs` (constructions like the one near line 7918; find all with
`grep -n "ResumeSummary$" keiro/test/Main.hs` and by compiler error) to include
`advanced`, `paced`, and `unregisteredNames` — the compiler's missing-field warnings under
this repo's `-Werror` will enumerate them. Update the direct `claimInstance` call sites
(lines ~7457-8519) from `Bool` matches to `ClaimOutcome` matches; while there, extend the
lease tests: after `recordCrashTx` paces an instance, `claimInstance` returns
`ClaimPaced`; under a live foreign lease it returns `ClaimLeaseHeld`. Update the
crash-pacing test at line ~10238 to additionally assert pass two reports `paced == 1`
(its lease-skip assertion moves to the new field).

Then the headline test, in the same exact-discovery describe block, named
"a bounded drain loop terminates over a pool that cannot advance": seed workflow A under
name "drain-crash" with a registry entry that always throws (reuse the
`SimulatedCrash`-style def from the crash-pacing test, `maxAttempts` 3, silenced
`logEvent`) by appending a seed `StepRecorded`; seed workflow B under name "drain-ghost"
the same way but with NO registry entry. Drive:

```haskell
let pass = Store.runStoreIO storeHandle (resumeWorkflowsOnce opts registry)
    drain 0 acc = pure acc
    drain n acc = do
      Right s <- pass
      if advanced s > 0 then drain (n - 1 :: Int) (acc <> [s]) else pure (acc <> [s])
passes <- drain 10 []
```

Assert the loop ran exactly one pass; that pass reports `discovered == 2`,
`resumed == 1` (the crash attempt), `unknownName == 1`, `advanced == 0`, and
`unregisteredNames == Set.fromList ["drain-ghost"]`. Then run one more manual pass and
assert `discovered == 2`, `paced == 1`, `unknownName == 1`, `advanced == 0` — the
falsification of the old contract: `discovered` never reaches zero, in either pass, so
the pre-fix documented predicate provably never terminates while the new predicate stops
after one pass.

Acceptance: `cabal test keiro-test` green including the new drain and claim tests.

### Milestone 3 — surface the distinction in keiro-ops

Scope: `keiro-ops/src/Keiro/Ops/Workflow.hs`, `keiro-ops/test/Main.hs`. At the end,
`wf resume-once --force` output lets an operator see progress versus blockage.

In `resumeSummaryResult` (line ~321), append three columns after the existing eight —
`advanced`, `paced`, and `unregistered` (the name set comma-joined, `-` when empty) — and
three JSON keys: `advanced`, `paced`, `unregistered_names` (JSON array of strings,
`Set.toAscList`). Existing keys keep their names and meanings; the change is additive in
shape even though the library type change beneath is breaking.

Extend the keiro-ops resume test ("previews and runs one bounded application-registry
resume pass", `keiro-ops/test/Main.hs` line ~271): after the existing applied-pass
assertions, add `jsonInteger "advanced" applied \`shouldBe\` Just 1`. Add a sibling test
seeding one registered workflow (definition `pure "done"`) and one workflow under an
unregistered name, running `ResumeOnce` with limit 2 and force: assert
`jsonInteger "advanced" == Just 1`, `jsonInteger "unknown_name" == Just 1`, and that the
rendered JSON's `unregistered_names` equals the ghost name (add a small `jsonStringArray`
helper beside `jsonInteger` if none exists).

Acceptance: `cabal test keiro-ops-test` green; the JSON assertions demonstrate the new
fields end to end through the CLI's own rendering path.

### Milestone 4 — documentation, changelog, ADR distillation, full verification

Scope: `CHANGELOG.md`, `docs/adr/0023-...md`, `docs/adr/0025-...md`, `docs/adr/log.md`,
`docs/masterplans/37-...md`, this plan. In `CHANGELOG.md` under "Unreleased": a Breaking
Changes entry for **keiro** (`claimInstance` returns `ClaimOutcome`; `ResumeSummary` gains
`advanced`, `paced`, `unregisteredNames`; the drain contract of
`resumeWorkflowsOnceUpTo` is now advanced-based) and Bug Fixes entries for the
cancel-versus-suspend stranding and the non-terminating drain contract, plus a
**keiro-ops** note for the new resume-once columns/JSON keys.

Amend ADR 0023's Decision section: awakeable cancellation now takes the per-step advisory
lock for the awaited step, and the suspend arbitration's re-check consults the awakeable
row's terminal status (the ADR-6 authority) in addition to the step index, because
cancellation is the one wake transition without a step row. Amend ADR 0025: pass
summaries distinguish work that advanced from candidates blocked in place, and drain
drivers terminate on `advanced == 0`. Record both amendments in `docs/adr/log.md`
following the bundle's existing entry format, keep frontmatter conventions intact, and
run `just adr-validate` (strict OKF profile enforcement) until clean. Tick the two EP-3
checkboxes (lines ~154-155) and flip the registry row for plan 239 to Complete in
`docs/masterplans/37-...md`. Write the Outcomes & Retrospective entry here.

Acceptance: `just haskell-test` and `just verify` both succeed from the repository root.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`. The
test suites boot their own ephemeral Postgres via the keiro-test-support template
fixture; no external database or `just postgres-start` is required for them.

Build after each edit:

```bash
cabal build all
```

Run only the new interleaving tests while iterating (hspec substring match):

```bash
cabal test keiro-test --test-options='--match "cancel lands"'
```

Expected BEFORE the M1 fix (the demonstration that the test catches the pre-fix bug —
run it once at this point and capture the output here):

```text
Keiro.Workflow exact discovery
  stays discoverable when a cancel lands before the stale suspend write FAILED [1]

  1) ... expected: WfRunning
          but got: WfSuspended

1 example, 1 failure
```

Expected AFTER the fix: the match reports both cancel-order examples, 0 failures. To
re-demonstrate the failure later (for review), stash the two fix files and rerun:

```bash
git stash push -- keiro/src/Keiro/Workflow/Awakeable.hs keiro/src/Keiro/Workflow/Instance.hs
cabal test keiro-test --test-options='--match "cancel lands before"'
git stash pop
```

Milestone-2 iteration:

```bash
cabal test keiro-test --test-options='--match "bounded drain loop"'
```

Expected: `1 example, 0 failures`, completing in a few seconds (one real pass, one manual
pass, no polling loops).

Full suites and repo gates:

```bash
cabal test keiro-test
cabal test keiro-ops-test
just haskell-test
just adr-validate
just verify
```

Expected: every suite prints `N examples, 0 failures` (keiro-test is the slow one — it is
a large DB-backed suite); `just adr-validate` prints the OKF validation success for
`docs/adr`; `just verify` runs the whole gate chain (process-compose check, jitsurei,
haskell build+tests, docs validations, policy scripts, migrations test) and exits 0.

Commit per milestone with conventional-commit messages, for example:

```text
fix(workflow): serialize awakeable cancellation with the suspend write
fix(workflow)!: report advanced-versus-blocked resume passes so drains terminate
feat(ops): surface advanced, paced, and unregistered names in wf resume-once
docs(adr): record the cancel lock discipline and the drain termination contract
```


## Validation and Acceptance

Acceptance is behavioral, in four parts.

1. Cancel-versus-suspend, both orders. After M1,
   `cabal test keiro-test --test-options='--match "cancel lands"'` runs the two new
   examples and reports 0 failures. The cancel-first example asserts, in order: the stale
   suspend write leaves the instance `running` (not `suspended`);
   `findUnfinishedWorkflowIds` returns the workflow; a resume pass re-invokes it; the
   instance then carries `attempts == 1` with `lastError` containing
   `WorkflowAwakeableCancelled` — i.e. the workflow OBSERVED the cancellation instead of
   being stranded. The suspend-first example asserts the mirror ordering. The pre-fix
   failure of the first example was captured in Concrete Steps and can be reproduced with
   the `git stash` recipe there.

2. Drain termination. The "bounded drain loop terminates over a pool that cannot
   advance" example passes: an `advanced > 0` drain loop over one crashed and one
   unregistered workflow stops after one pass with `discovered == 2`, `advanced == 0`,
   `unknownName == 1`, `unregisteredNames == fromList ["drain-ghost"]`, and a follow-up
   pass reports `paced == 1` while `discovered` is still 2 — proving the old
   drain-until-`discovered`-zero contract could never terminate on this pool.

3. Operator surface. `cabal test keiro-ops-test` passes with the extended resume
   assertions: the applied `wf resume-once` JSON contains `"advanced": 1`, and the
   mixed-pool example shows `"unknown_name": 1` with `"unregistered_names"` naming the
   ghost workflow. (Equivalently, in an embedded binary,
   `keiro-ops wf resume-once --limit 10 --force --json` now prints the three new keys.)

4. No regressions. `just haskell-test` and `just verify` are green: in particular the
   pre-existing signal-versus-suspend pair, the cancel-visibility test, the
   crash-pacing test (updated for `paced`), the lease tests (updated for
   `ClaimOutcome`), and the keiro-ops preview/mutation tests all still pass.


## Idempotence and Recovery

Every step is safe to repeat. All edits are ordinary source edits guarded by the test
suites; re-running any `cabal test` or `just` command is side-effect-free (each DB-backed
example runs in a fresh clone of the template database that is dropped afterwards). There
is no schema migration and no data backfill in this plan, so there is nothing destructive
to roll back; recovery from a bad intermediate state is `git checkout -- <file>` or
`git stash` of the affected files. The two defect fixes are independent: M1 can ship
without M2/M3 and vice versa, and each milestone leaves the tree compiling and green, so
work can stop and restart at any milestone boundary using only this document. If a rebase
or interruption loses partial test edits, the compiler reconstructs the required call-site
updates: build errors at `ResumeSummary` record constructions and `claimInstance` matches
enumerate every site the M2 API change touches.


## Interfaces and Dependencies

No new packages, no new modules, and no schema changes. All work is within the existing
`keiro` and `keiro-ops` packages against the already-depended-on libraries (`hasql`
statements via the existing `Kiroku.Store` transaction seam, `aeson`, `containers`,
`uuid`). The signatures that must exist at the end:

In `Keiro.Workflow.Awakeable` (`keiro/src/Keiro/Workflow/Awakeable.hs`) — unchanged
signature, changed behavior (per-step lock, owner/generation preamble):

```haskell
cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool
```

In `Keiro.Workflow.Instance` (`keiro/src/Keiro/Workflow/Instance.hs`) — broadened suspend
arbitration (unchanged signature) and the new claim outcome (breaking change, exported):

```haskell
markInstanceSuspendedAwaiting ::
  (Store :> es) => WorkflowName -> WorkflowId -> Int -> Text -> Eff es ()

data ClaimOutcome = ClaimAcquired | ClaimLeaseHeld | ClaimPaced | ClaimUnavailable

claimInstance ::
  (IOE :> es, Store :> es) =>
  Text -> NominalDiffTime -> WorkflowName -> WorkflowId -> Eff es ClaimOutcome
```

In `Keiro.Workflow.Resume` (`keiro/src/Keiro/Workflow/Resume.hs`) — the extended per-pass
summary (breaking change; `Semigroup`/`Monoid` preserved, `unregisteredNames` combining
by set union):

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
    unregisteredNames :: !(Set Text)
  }
```

`resumeWorkflowsOnce` and `resumeWorkflowsOnceUpTo` keep their signatures; only their
documentation contract changes. In `Keiro.Ops.Workflow`
(`keiro-ops/src/Keiro/Ops/Workflow.hs`), `resumeSummaryResult :: ResumeSummary ->
OpsResult` keeps its signature and gains the `advanced`, `paced`, and `unregistered`
columns plus the `advanced`, `paced`, and `unregistered_names` JSON keys. Dependency
check: `Keiro.Workflow.Instance` newly imports `Keiro.Workflow.Awakeable.Schema`
(`AwakeableStatus (..)`, `lookupAwakeableStatusTx`), which imports no workflow module, so
the module graph stays acyclic; `Keiro.Workflow.Awakeable` newly imports
`lockWorkflowStepTx` and `workflowStepLockKey` from `Keiro.Workflow.Schema`, which it
already sits above.

---

Revision note (2026-08-11): initial authoring — fleshed out the init-script skeleton into
the full plan after reading the awakeable/instance/schema/journal/resume sources, the
existing signal-versus-suspend and crash-pacing tests, migration 0021, the keiro-ops
caller, and ADRs 5, 6, 23, 25, and 27; design choices recorded in the Decision Log.
