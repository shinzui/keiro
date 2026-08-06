---
id: 201
slug: fold-terminal-checks-into-the-workflow-append-transaction-and-thin-the-step-hot-path
title: "Fold terminal checks into the workflow append transaction and thin the step hot path"
kind: exec-plan
created_at: 2026-08-06T00:12:21Z
intention: "intention_01kza6gjs5eg79n2hyrah7wnnn"
master_plan: "docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md"
---

# Fold terminal checks into the workflow append transaction and thin the step hot path

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The durable-workflow runtime stops a run at the next step boundary when someone
cancels the workflow, but it does *not* stop at a boundary when the workflow has been
marked terminally **failed**: the failure marker is checked once at run entry and
never again. A direct `runWorkflow` call that overlaps the resume worker's
`WorkflowFailed` marker (written when a workflow exhausts its crash attempts) keeps
executing fresh side effects past the failure. Cancellation, by contrast, is
re-checked with an extra database query before *and* after every fresh step action.

After this plan, both terminal markers are enforced at every step boundary, and the
enforcement is *cheaper* than today's cancellation-only checking: the checks move
inside the journal-append transaction — under the same advisory lock and in the same
round-trip that already re-checks the step index — so a fresh step costs one fewer
database query while gaining the failure check. The run-entry probe collapses from
two existence queries to one, and the resume worker stops re-deriving the workflow's
current generation with a redundant `MAX(generation)` query on every claim. You can
see it working by marking a workflow failed while a two-step run is between steps
and observing that the second step's action never commits — and that the run reports
`Failed` instead of continuing.


## Progress

- [ ] Milestone 1: entry probe collapsed to one query; `claimInstance` no longer resolves `currentGeneration`.
- [ ] Milestone 2: cancelled and failed markers checked inside `prepareJournalAppend`'s transaction; post-action standalone check removed; pre-action check covers both markers in one query.
- [ ] Milestone 3: boundary-asymmetry and refusal tests green; full suite green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Represent an append refused by a terminal marker as a new
  `JournalAppendOutcome` constructor rather than condemning the transaction.
  Rationale: The caller must distinguish "workflow is terminal, stop cleanly" from
  "append conflict, surface an error"; a constructor keeps the existing
  transaction-shaping (`condemn` only on real conflicts) and lets each caller map
  refusal to its own semantics.
  Date: 2026-08-06

- Decision: Keep a single cheap pre-action probe (now covering both markers) in
  addition to the in-transaction check, instead of relying on the append check
  alone.
  Rationale: The in-transaction check stops the *commit*; the pre-action probe
  stops the *side effect* from running at all in the common already-terminal case.
  One query buys skipping the user action entirely.
  Date: 2026-08-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The durable-workflow runtime is `keiro/src/Keiro/Workflow.hs`. A workflow's journal
is a kiroku event stream; each executed step appends a `StepRecorded` event through
`prepareJournalAppend`, which builds one database transaction that: takes a per-step
advisory lock (`lockWorkflowStepTx` from `keiro/src/Keiro/Workflow/Schema.hs`,
keyed `<wid>/<name>/<gen>/<stepName>`), re-checks the step index
(`lookupStepResultTx`) so a raced or replayed write returns
`JournalAlreadyPresent`, appends to the stream, writes the
`keiro.keiro_workflow_steps` index row (`recordStepTx`), and upserts the
`keiro.keiro_workflows` instance row (`upsertInstanceTx` from
`keiro/src/Keiro/Workflow/Instance.hs`; terminal instances are frozen by that
statement's `WHERE`). The outcome type is `JournalAppendOutcome` with constructors
`JournalAppended`, `JournalAlreadyPresent`, and `JournalAppendConflict`, and it is
exported from `Keiro.Workflow` for wake sources.

Terminal markers are ordinary index rows under reserved step names
(`keiro/src/Keiro/Workflow/Types.hs`): `cancelledStepName`
(`__workflow_cancelled__`), `failedStepName` (`__workflow_failed__`),
`completedStepName`, and `continuedAsNewStepName`. `runWorkflowWith` probes
cancelled and failed once at entry with two separate `stepExists` calls
(`keiro/src/Keiro/Workflow.hs`, start of `runWorkflowWith`), short-circuiting to
`Cancelled`/`Failed`. Mid-run, `checkCancellationPending` — a `stepExists` on
`cancelledStepName` only — runs before a fresh step action, after it returns, and
before an unresolved await's arm; a hit throws the internal `WorkflowCancelPending`
sentinel which the run entry catches and maps to the `Cancelled` outcome. Nothing
re-checks `failedStepName` after entry: that is the asymmetry this plan closes. The
failure marker is written by the resume worker
(`keiro/src/Keiro/Workflow/Resume.hs`, `handleAttempt`'s `AdvCrashed` branch at the
`maxAttempts` ceiling) and can land while another runner — typically a direct
`runWorkflow` call from application code, which takes no lease — is mid-run.

Who else calls `prepareJournalAppend`: the wake sources. `signalAwakeable`
(`keiro/src/Keiro/Workflow/Awakeable.hs`) delivers an awakeable result;
`childCompletionHook`, `ensureChildCancelled`, and the resume worker's
`appendFailedChildAndWakeParent` (`keiro/src/Keiro/Workflow/Child.hs`,
`keiro/src/Keiro/Workflow/Resume.hs`) deliver child results and sentinels;
`workflowSleepFireAction` (`keiro/src/Keiro/Workflow/Sleep.hs`) delivers sleep
completions; `rotateGeneration` and `appendCompletion` (both in
`keiro/src/Keiro/Workflow.hs`) write rotation seeds and terminal markers. Any
change to `prepareJournalAppend`'s outcome type touches all of them; all are
in-repo, and each mapping is spelled out in the Plan of Work.

Also in scope, two redundant queries on the resume path.
`Keiro.Workflow.Instance.claimInstance` resolves `currentGeneration` (a
`MAX(generation)` query) merely to feed `ensureInstanceStmt`, an
`ON CONFLICT DO NOTHING` insert that only matters for rows that do not exist —
and since migration `0011-keiro-workflows-instances.sql` backfilled instances and
`spawnChild` upserts child instances at spawn, discovered workflows always have a
row; where the insert does fire, generation 0 is correct because
`upsertInstanceTx`'s conflict arm takes `GREATEST(stored, supplied)`, so a later
truthful writer can only raise it. And `runWorkflowWith`'s entry makes two
`stepExists` round-trips where one statement can answer "which terminal markers
exist" in a single probe.

Relevant ADRs, per `agents/skills/exec-plan/ADR.md`:
`docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md`
is the governing record for failure semantics — the failure *journal event* is
immutable history while the derived index row and instance status are revivable by
`resurrectFailedWorkflow`, which deletes the `failedStepName` index row. The
boundary check added here reads exactly that index row, so a resurrected workflow
passes the check again by construction; no ADR change is expected unless
implementation contradicts this.
`docs/adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md`
establishes the step index as authoritative and transactional with every append,
which is precisely why an in-transaction terminal check is sound. The sibling plan
`docs/plans/200-make-suspended-workflows-quiescent-and-discovery-index-aligned.md`
owns `findUnfinishedWorkflowIdsStmt`, `markInstanceSuspended` (and its successor),
and the sleep fire's wake-hint clear; this plan must not touch those (see the
MasterPlan's Integration Points).

Tests are in `keiro/test/Main.hs`; `cabal test keiro-test` from the repository root
provisions its own ephemeral Postgres via `keiro-test-support`.


## Plan of Work

### Milestone 1 — one entry probe, no redundant generation query

Scope: mechanical round-trip removal with no semantic change.

In `keiro/src/Keiro/Workflow/Schema.hs`, add a statement that returns the set of
terminal-marker step names present for `(workflow_id, workflow_name, generation)`
in one query — `SELECT step_name FROM keiro.keiro_workflow_steps WHERE workflow_id
= $1 AND workflow_name = $2 AND generation = $3 AND step_name IN ($4, $5)` decoded
with `D.rowList`, wrapped as `terminalMarkers :: (Store :> es) => WorkflowName ->
WorkflowId -> Int -> Eff es [Text]` (pass `cancelledStepName` and `failedStepName`
as the two parameters so the literals stay defined once, in
`Keiro.Workflow.Types`). In `runWorkflowWith`, replace the two `stepExists` calls
with one `terminalMarkers` call; cancelled takes precedence over failed exactly as
the current tuple-case does.

In `keiro/src/Keiro/Workflow/Instance.hs`, delete the `currentGeneration` call from
`claimInstance` and pass generation 0 to `ensureInstanceStmt`, with a comment
stating why 0 is safe (fresh-row-only insert; `GREATEST` conflict arm on the
upsert; discovered workflows have rows since migration 0011).

Acceptance: suite green; behavior unchanged (all existing entry-shortcircuit tests
pass unmodified).

### Milestone 2 — terminal checks inside the append transaction

Scope: the correctness change and the hot-path thinning, together, because they are
the same edit.

Extend `JournalAppendOutcome` in `keiro/src/Keiro/Workflow.hs` with a constructor
`JournalRefusedTerminal !Text` carrying the reserved step name of the marker that
refused the append. In `prepareJournalAppend`, for `StepRecorded` events only
(terminal markers, rotation markers, and completion events keep today's behavior —
their idempotence and first-terminal-wins arbitration are established contracts),
add to the transaction after the advisory lock and the step-index re-check: query
the two terminal-marker rows for this generation (reuse Milestone 1's statement in
a `Tx.Transaction` form, `terminalMarkersTx`); if either exists, return
`JournalRefusedTerminal <markerName>` without appending. The check adds no
round-trip from the application's perspective — it rides the transaction that was
already being executed — and it is race-free under the advisory lock together with
ordinary transaction atomicity: a terminal marker committing after this
transaction's snapshot began will refuse the *next* boundary, which is exactly the
documented at-least-once boundary semantics that already govern cancellation.

Map the new outcome at every call site:

- The `Step` handler in `runWorkflowWith`: `JournalRefusedTerminal m` throws
  `WorkflowCancelPending` when `m == cancelledStepName`, otherwise a new internal
  sentinel `WorkflowFailPending`; add a `catch` for `WorkflowFailPending` in
  `runActive` mapping to the `Failed` outcome (the `Failed` branch of the outcome
  case already exists and does nothing further). The `Patch` handler maps
  identically.
- With the in-transaction check in place, delete the *post-action*
  `checkCancellationPending` call in the `Step` miss path (the append now enforces
  it) and widen the *pre-action* probe to both markers by replacing
  `checkCancellationPending` with `checkTerminalPending`, which calls Milestone 1's
  `terminalMarkers` once and throws the matching sentinel. Net round-trips per
  fresh step: today lease-renew, cancel-check, action, cancel-check, append; after,
  lease-renew, terminal-check, action, append. The await-arm path keeps its single
  pre-arm probe, likewise widened.
- `appendCompletion`, `rotateGeneration`, `recordPatchSetIfFresh`: the seed and
  patch-set appends in `rotateGeneration` target a *fresh* generation that cannot
  carry terminal markers, and `recordPatchSetIfFresh` runs only on fresh journals,
  so treat `JournalRefusedTerminal` there as an invariant violation: map it to
  `WorkflowJournalAppendError` like a conflict.
- Wake sources — `signalAwakeableFrom`, `childCompletionHook`,
  `ensureChildCancelled`, `appendFailedChildAndWakeParent`,
  `workflowSleepFireAction`, and the generic `appendJournalEntry` /
  `appendJournalEntryReturningId`: a refusal means "the owning workflow is already
  terminal; do not deliver". Each treats `JournalRefusedTerminal` as the
  no-append/no-error case its logic already has: `signalAwakeableFrom` keeps its
  row transition (the promise is still resolved durably) but skips the journal
  entry and does not condemn; `workflowSleepFireAction` returns the deterministic
  id as it does for `JournalAlreadyPresent`, so the timer is still marked fired;
  `childCompletionHook` and `ensureChildCancelled` skip the parent delivery (the
  child row remains the durable authority per
  `docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md`,
  so a later resurrected parent still recovers through the await arm);
  `appendJournalEntryReturningId` returns the would-be id without erroring, and its
  haddock gains a sentence saying so.
- Terminal-event appends themselves (`WorkflowFailed` in the resume worker,
  `WorkflowCancelled` in `ensureChildCancelled`) skip the check by construction;
  their `case` expressions only gain the exhaustive new arm.

This is an exported-type extension: compile errors enumerate every case expression
needing the new arm — iterate `cabal build keiro` until every site is deliberate.
Update the `JournalAppendOutcome` haddock to document the refusal contract, and add
a breaking-change note to `keiro/CHANGELOG.md` (the type is exported, even though
all known consumers are in-repo).

### Milestone 3 — tests

In `keiro/test/Main.hs`, a new group (e.g. `describe "Keiro.Workflow terminal
boundaries"`):

- Boundary asymmetry closed: build a two-step workflow whose first step's action
  appends the `WorkflowFailed` marker for the *same* workflow via
  `appendJournalEntry` (simulating the resume worker's concurrent marking between
  boundaries). Assert the run returns `Failed`, the second step's action never ran
  (observe via an `IORef` counter), and no index row exists for the second step.
  Mirror the existing cancellation-mid-run test shape.
- Refusal outcome: with a cancelled workflow, call `appendJournalEntry` for an
  ordinary step and assert it is a no-op (no index row added, no exception); with
  a failed workflow, call `signalAwakeable` on a pending awakeable owned by it and
  assert the row still transitions to `completed` but no journal entry is
  appended.
- Post-resurrection delivery: fail a workflow, resurrect it with
  `resurrectFailedWorkflow`, and assert a subsequent wake append is accepted
  (refusal reads the revivable index row, per
  `docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md`).
- Sleep-fire refusal: cancel a workflow after its sleep timer became claimable and
  fire the timer — assert the timer is still marked fired and no journal entry
  lands.

Acceptance: new tests pass; the full suite stays green, including the
MasterPlan-16 crash-window groups (snapshot wake-safety, child failure, sleep
generations, GC, resurrection, lease renewal).


## Concrete Steps

All commands run from the repository root.

```bash
cabal build keiro          # iterate until the new constructor is handled everywhere
cabal test keiro-test      # full engine suite (ephemeral Postgres via keiro-test-support)
```

Expected: the suite ends `N examples, 0 failures`. Commit per milestone:

```text
feat(workflow): enforce cancelled and failed markers inside the append transaction

MasterPlan: docs/masterplans/30-harden-and-scale-the-durable-execution-engine-surfaced-by-the-2026-08-re-audit.md
ExecPlan: docs/plans/201-fold-terminal-checks-into-the-workflow-append-transaction-and-thin-the-step-hot-path.md
Intention: intention_01kza6gjs5eg79n2hyrah7wnnn
```


## Validation and Acceptance

The user-visible contract after this plan: a workflow that has been cancelled *or*
terminally failed makes no further step progress past the current boundary, from
any runner, leased or not; wake sources deliver nothing into terminal workflows but
still settle their own durable rows; and a fresh step costs one fewer query than
before while checking strictly more. The Milestone 3 tests are the acceptance;
"beyond compilation" evidence is the two-step asymmetry test failing before the
change (step two commits today) and passing after.


## Idempotence and Recovery

All edits are code-only — no migration, no data movement. The new refusal path is
strictly conservative (it declines writes that previously succeeded into terminal
journals), so rolling back is a plain revert. The only breaking surface is the new
`JournalAppendOutcome` constructor for out-of-repo pattern matches; record it in
`keiro/CHANGELOG.md`.


## Interfaces and Dependencies

No new libraries. End-state interface deltas, all in the `keiro` package:
`JournalAppendOutcome` gains `JournalRefusedTerminal !Text`;
`Keiro.Workflow.Schema` gains `terminalMarkers` (Eff-level) and
`terminalMarkersTx` (transaction-level) returning the present terminal-marker
names for `(name, wid, generation)`; the internal `checkCancellationPending` is
replaced by `checkTerminalPending`; `Keiro.Workflow.Instance.claimInstance` loses
its internal `currentGeneration` call (public signature unchanged). This plan must
not touch `findUnfinishedWorkflowIdsStmt`, `markInstanceSuspended` or its
successor, or `workflowSleepFireAction`'s wake-hint clear — those belong to
`docs/plans/200-make-suspended-workflows-quiescent-and-discovery-index-aligned.md`.
