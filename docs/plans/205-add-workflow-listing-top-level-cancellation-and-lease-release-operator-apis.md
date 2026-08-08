---
id: 205
slug: add-workflow-listing-top-level-cancellation-and-lease-release-operator-apis
title: "Add workflow listing, top-level cancellation, and lease-release operator APIs"
kind: exec-plan
created_at: 2026-08-06T03:02:06Z
intention: "intention_01kzagac32ehp93amx1sfar2ab"
master_plan: "docs/masterplans/31-build-the-keiro-ops-operational-cli.md"
---

# Add workflow listing, top-level cancellation, and lease-release operator APIs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Three operator capabilities that the upcoming `keiro-ops` CLI (MasterPlan 31) must
expose do not exist as library APIs today, and the CLI is forbidden from inventing
SQL to fake them. An operator cannot *enumerate* workflow instances — "show me every
failed workflow" has no supported answer because
`Keiro.Workflow.Instance.lookupInstance` is a point query. An operator cannot
*cancel* a top-level workflow — `Keiro.Workflow.Child.cancelChild` works only
through a `keiro_workflow_children` link row, so a workflow that is nobody's child
has no supported stop switch (the terminal dual, resurrection, exists:
`resurrectFailedWorkflow`). And an operator cannot *release a wedged lease* — if a
worker host dies unrecoverably mid-advance, its lease blocks other workers until
`leaseTtl` expires, and there is no supported way to clear it sooner.

After this plan, all three exist as tested `keiro` library functions:
`listWorkflowInstances` (filterable, keyset-paged), `cancelWorkflow` (idempotent,
race-safe, child-aware), and `forceReleaseInstanceLease`. They are useful to
applications directly and become thin CLI wrappers in
`docs/plans/206-create-the-keiro-ops-package-with-the-workflow-and-timer-command-domains.md`.


## Progress

- [x] (2026-08-08T23:16:21Z) `listWorkflowInstances` with status/name filters,
  bounded page size, and `(workflow_name, workflow_id)` keyset paging, tested.
- [x] (2026-08-08T23:16:21Z) `cancelWorkflow` with honest outcomes,
  child-aware parent delivery, append-only terminal state, and lifecycle race
  arbitration, tested.
- [x] (2026-08-08T23:16:21Z) `forceReleaseInstanceLease`, tested for immediate
  reclaim and a live old owner stopping at its next boundary.
- [x] (2026-08-08T23:16:21Z) Cancellation and lifecycle-marker contract recorded
  in `docs/adr/0027-workflow-lifecycle-markers-are-append-only-and-first-writer-wins.md`;
  ADR 6 amended and strict validation passed for 27 concepts.
- [x] (2026-08-08T23:16:21Z) Full suite green: `cabal test keiro-test` — 441
  examples, 0 failures. `nix fmt` and `git diff --check` also pass.


## Surprises & Discoveries

- The planned `cancelWorkflow` location exposed a real module cycle:
  `Keiro.Workflow` owned journal appends and imported `Keiro.Workflow.Instance`
  for instance upserts, while the new instance API needed to append a
  cancellation marker. The implementation extracted the shared append engine
  into internal `Keiro.Workflow.Journal` and the shared row state into
  `Keiro.Workflow.Instance.Schema`; the public API remains exactly where EP-2
  expects it.

- The pre-existing per-step advisory lock could deduplicate two writers of the
  same reserved marker, but it could not arbitrate completion, cancellation,
  failure, and rotation because they use different step names. A focused race
  test proved the required shape and led to one generation-scoped lifecycle
  lock. Rotation also had to commit its old-generation marker and
  new-generation seed in one transaction; otherwise cancellation could win on
  the old generation after the seed had already made a new generation current.

- No listing migration was necessary. The primary key and existing status
  indexes cover the selected order and filters well enough for this operator
  surface; EP-1 claims no migration number.


## Decision Log

- Decision: `cancelWorkflow` delegates to the child-cancellation path when a child
  link row exists, instead of refusing or appending only the child-journal marker.
  Rationale: Cancelling a child without writing the parent's await sentinel
  strands the parent forever; the existing `ensureChildCancelled` transaction
  already writes both markers atomically and is the single supported way to
  cancel a linked child (`keiro/src/Keiro/Workflow/Child.hs`).
  Date: 2026-08-06

- Decision: `cancelWorkflow` refuses to fabricate state for unknown workflows —
  it requires an existing instance row or step rows.
  Rationale: Appending a cancellation marker for a never-seen id would *create* a
  terminal instance row out of nothing; an operator typo must not mint state.
  Date: 2026-08-06

- Decision: Keep `cancelWorkflow` in `Keiro.Workflow.Instance` and factor the
  shared journal/instance storage machinery into internal modules.
  Rationale: This preserves the public contract consumed by EP-2 and keeps one
  transactional append implementation. Duplicating journal SQL inside the
  operator API would violate the MasterPlan's central ownership rule.
  Date: 2026-08-08

- Decision: All distinct generation lifecycle markers share one advisory lock,
  and rotation commits its marker and next-generation seed atomically.
  Rationale: Per-marker locks cannot prevent contradictory terminal markers;
  atomic rotation is required so cancellation either stops the old generation
  or follows a fully committed rotation to the new current generation.
  Date: 2026-08-08

- Decision: Record the cancellation contract in new ADR 27 and amend ADR 6,
  rather than broadening failure-specific ADR 8.
  Rationale: The durable rule governs completion, cancellation, failure, and
  rotation together; ADR 8 remains the narrower resurrection exception for
  failed workflows.
  Date: 2026-08-08


## Outcomes & Retrospective

Complete, 2026-08-08. The `keiro` library now exposes the three primitives EP-2
needs without any CLI-side SQL: filtered, stable workflow enumeration;
top-level and linked-child cancellation with honest outcomes; and immediate
operator lease release. The public surface is re-exported from `Keiro.Workflow`,
and 441 examples pass.

The most important result is stronger than the initial API checklist. Workflow
lifecycle markers now have one first-writer-wins contract across normal runtime
completion, operator cancellation, failure, and `continueAsNew`. A cancellation
cannot coexist with a completion marker, and a cancellation racing rotation
cannot strand a runnable new generation. Linked children retain their atomic
child-row, child-marker, and parent-sentinel behavior.

No database migration or new dependency was needed. The internal module split
is deliberately not a second public surface: `Keiro.Workflow.Journal`,
`Keiro.Workflow.Instance.Schema`, and `Keiro.Workflow.Child.Cancel` exist only so
runtime execution and operator APIs share the same invariants without a module
cycle.


## Context and Orientation

The durable-workflow engine lives under `keiro/src/Keiro/Workflow*`. Per-instance
summary state is one row per logical workflow in `keiro.keiro_workflows`
(`keiro-migrations/migrations/0011-keiro-workflows-instances.sql`: primary key
`(workflow_id, workflow_name)`, `status` in
running/suspended/completed/cancelled/failed with a CHECK constraint, crash
`attempts`/`next_attempt_at`, lease columns `leased_by`/`lease_expires_at`,
timestamps, `wake_after`). Row maintenance goes through
`keiro/src/Keiro/Workflow/Instance.hs`. Journal writes go through
`prepareJournalAppend` in `keiro/src/Keiro/Workflow/Journal.hs` (re-exported by
`Keiro.Workflow`): one transaction taking a
per-step advisory lock, re-checking the `keiro.keiro_workflow_steps` index,
appending to the kiroku stream, writing the index row, and upserting the instance
row — terminal markers are index rows under reserved names from
`keiro/src/Keiro/Workflow/Types.hs` (`cancelledStepName`, `failedStepName`,
`completedStepName`). A run whose journal carries the cancelled marker
short-circuits to `Cancelled` and re-checks the marker at step boundaries.

Cancellation today: `cancelChild` (`keiro/src/Keiro/Workflow/Child.hs`) flips the
`keiro_workflow_children` row and, via `ensureChildCancelled`, writes the child's
`WorkflowCancelled` marker and the parent's `{"cancelled": true}` await-step
sentinel in one transaction. There is no entry point for a workflow without a link
row. Resurrection (the reverse direction) is
`resurrectFailedWorkflow` in `keiro/src/Keiro/Workflow/Instance.hs`, whose contract
is `docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md`:
append-only journal history, revivable derived state. Terminal races are governed
by `docs/adr/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md`
(in-transaction arbitration). Sleep timers owned by a cancelled workflow need no
special handling here: the fire action cancels itself against a terminal instance
row (`docs/adr/0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md`)
and workflow GC deletes owned timers.

Leases: the resume worker (`keiro/src/Keiro/Workflow/Resume.hs`) claims an
instance via `claimInstance` (expiry-based row lease; a live foreign lease skips
the instance), renews at fresh boundaries (`renewInstanceLease` — an UPDATE
guarded by `leased_by = owner` returning whether it matched), and releases in a
`finally`. A run whose renewal returns `False` throws `WorkflowLeaseLost` and
stops before further side effects. That guard is what makes an operator
force-release safe: after clearing `leased_by`, a still-running old owner fails
its next renewal and stops cleanly.

Listing indexes that already exist on `keiro_workflows`: the primary key
(`workflow_id, workflow_name`), the partial `keiro_workflows_active_idx`
(migration 0011; possibly reshaped to `(status, wake_after)` by MasterPlan 30's
plan 200 — coordinate if both are in flight), and `keiro_workflows_gc_idx
(status, completed_at)` (migration 0012), which covers terminal-status scans. A
new listing index is not expected; if profiling during implementation disagrees,
claim the next free migration number after MasterPlan 30's plan 200 (which holds
0021) and reconcile the pinned counts in `cabal test keiro-migrations-test`.

Tests live in `keiro/test/Main.hs`; `cabal test keiro-test` from the repository
root provisions ephemeral Postgres via `keiro-test-support`.


## Plan of Work

### Milestone 1 — `listWorkflowInstances`

In `keiro/src/Keiro/Workflow/Instance.hs`, add a filter record and a listing
function:

    data WorkflowInstanceFilter = WorkflowInstanceFilter
      { statuses :: !(Maybe (NonEmpty WorkflowStatus)),  -- Nothing = all
        workflowName :: !(Maybe Text),                    -- exact name match
        afterKey :: !(Maybe (Text, Text)),                -- keyset cursor: (name, id) of the last row seen
        pageSize :: !Int
      }

    listWorkflowInstances ::
      (Store :> es) => WorkflowInstanceFilter -> Eff es [WorkflowInstanceRow]

The statement selects the full `WorkflowInstanceRow` column set (reuse
`instanceRowDecoder`), filtered by `status = ANY($1)` when statuses are given and
by name when given, ordered by `(workflow_name, workflow_id)` (the primary-key
order the resume worker's discovery already uses), with the keyset predicate
`(workflow_name, workflow_id) > ($after_name, $after_id)` when a cursor is given,
`LIMIT` by `pageSize`. Keyset paging rather than OFFSET so an operator paging
through a large deployment sees stable pages under concurrent writes. Export the
filter type, a `defaultWorkflowInstanceFilter` (no filters, page size 100), and
the function from `Keiro.Workflow.Instance`; re-export from `Keiro.Workflow` next
to `findUnfinishedWorkflowIds`.

Tests: seed a mix of statuses and names; assert status filtering, name
filtering, ordering, and that walking pages with the cursor visits every row
exactly once with page size 2.

### Milestone 2 — `cancelWorkflow`

In `keiro/src/Keiro/Workflow/Instance.hs` (beside `resurrectFailedWorkflow`, its
dual), add:

    data CancelWorkflowOutcome
      = WorkflowCancelRecorded          -- this call wrote the cancellation
      | WorkflowAlreadyTerminal !WorkflowStatus
      | WorkflowCancelUnknown           -- no instance row and no step rows: refused

    cancelWorkflow ::
      (IOE :> es, Store :> es) =>
      WorkflowName -> WorkflowId -> Eff es CancelWorkflowOutcome

Behavior, in order. Resolve existence: look up the instance row; if absent, check
`currentGeneration`/step rows; if neither exists, return `WorkflowCancelUnknown`
(refuse to mint state — Decision Log). If the instance status is already
terminal, return `WorkflowAlreadyTerminal` without writing (idempotent re-cancel
of a cancelled workflow reports `WorkflowAlreadyTerminal WfCancelled`; keep it
distinct from `WorkflowCancelRecorded` so the CLI can render honestly). Otherwise
look up a child link row (`lookupChild` from
`keiro/src/Keiro/Workflow/Child/Schema.hs`): when one exists, cancel through the
child path so the parent sentinel is written — reuse the logic of
`ensureChildCancelled`. The landed implementation shares that transaction
through internal `keiro/src/Keiro/Workflow/Child/Cancel.hs`, rather than
duplicating it or widening the public child module.
When no link row exists, append `WorkflowCancelled` on the *current generation*
through `appendJournalEntry`'s machinery (`prepareJournalAppend` + one
`runTransaction`), which freezes the instance row in the same transaction via the
standard upsert. All paths are idempotent and race-safe by construction: the
landed append path takes a common generation-lifecycle lock before its per-step
advisory lock and index re-check, so completion, cancellation, failure, and
rotation are first-writer-wins. Rotation commits its old-generation marker and
next-generation seed atomically, allowing a losing cancellation to follow the
new current generation. ADR 27 records that durable contract and ADR 6 retains
the wake-source arbitration rules.

Interplay note for the haddock: cancellation stops *step progress* at the next
boundary (entry check plus the boundary checks in `keiro/src/Keiro/Workflow.hs`;
if MasterPlan 30's plan 201 has landed, wake-source appends are additionally
refused in-transaction); owned sleep timers self-cancel on their next fire
attempt against the terminal instance row and are collected by workflow GC; a
cancelled workflow's *children* are not cascaded — the operator cancels children
explicitly (document this deliberately; automatic cascade is a policy decision
this plan does not take).

Record the contract in `docs/adr/`: either extend
`docs/adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md`
with the cancellation dual (operator cancellation is an append-only terminal
marker; derived state freezes; no cascade) or allocate a new record with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR` — decide during
implementation, log the choice in this plan's Decision Log, keep `log.md` current
(`okf log add`), and pass `just adr-validate`.

Tests: cancel a running two-step workflow between runs and assert the next
`runWorkflow` returns `Cancelled` with no further step rows; cancel a suspended
workflow and assert discovery drops it; double-cancel returns
`WorkflowAlreadyTerminal WfCancelled`; cancel a completed workflow returns
`WorkflowAlreadyTerminal WfCompleted` and appends nothing; cancel an id with no
state returns `WorkflowCancelUnknown` and creates no rows; cancel a *child*
(spawned via `spawnChild`) and assert the parent's await throws
`WorkflowChildCancelled` on its next run (the sentinel was written); cancel racing
a wake — signal an awakeable and cancel concurrently-orderable via direct calls,
assert exactly one of completion-value/cancellation is observed by the workflow,
never both compensation and completion (mirror the existing ADR-6 race tests).

### Milestone 3 — `forceReleaseInstanceLease`

In `keiro/src/Keiro/Workflow/Instance.hs`:

    forceReleaseInstanceLease ::
      (Store :> es) => WorkflowName -> WorkflowId -> Eff es Bool

One UPDATE clearing `leased_by`/`lease_expires_at` unconditionally for the key,
returning whether a live lease (non-null `leased_by`) was actually cleared. The
haddock must state the safety argument and the caveat: the previous owner, if
still alive, fails its next `renewInstanceLease` (owner-guarded UPDATE matches
zero rows) and stops with `WorkflowLeaseLost` before further side effects — but
any single step action already in flight completes and journals idempotently, so
force-release does not abort in-flight work, it only prevents *further* boundary
crossings and frees the instance for other claimants immediately.

Tests: claim with owner A, force-release, claim with owner B succeeds
immediately (no TTL wait); and the mid-run case — a workflow with a slow step
running under owner A's lease heartbeat, force-released mid-step, asserts A's run
ends in `WorkflowLeaseLost` (surfaced as the resume worker's `leaseSkipped`
classification) and B's subsequent run completes the workflow without duplicated
step rows.


## Concrete Steps

All commands run from the repository root.

    cabal build keiro
    cabal test keiro-test
    just adr-validate          # after the ADR edit in Milestone 2

Expected and observed: suite ends `441 examples, 0 failures`. Commit per
milestone:

    feat(workflow): add operator listing, cancellation, and lease-release APIs

    MasterPlan: docs/masterplans/31-build-the-keiro-ops-operational-cli.md
    ExecPlan: docs/plans/205-add-workflow-listing-top-level-cancellation-and-lease-release-operator-apis.md
    Intention: intention_01kzagac32ehp93amx1sfar2ab


## Validation and Acceptance

Acceptance is behavioral: an operator (or test) can enumerate every failed
workflow with one call and page through a large set stably; can stop any workflow
— top-level or child — with one call whose outcome value honestly reports what
happened, after which the workflow makes no further step progress and its parent
(if any) is woken with the typed cancellation; and can free a dead worker's lease
without waiting out the TTL, with a live old owner stopping at its next boundary
instead of running duplicated work. The Milestone 2 race tests and the Milestone 3
mid-run test are the proof beyond compilation.


## Idempotence and Recovery

All three APIs are idempotent by design (keyset listing is read-only; re-cancel
reports `WorkflowAlreadyTerminal`; re-release returns `False`). No migration is
expected; if a listing index becomes necessary, it is forward-only and
`CREATE INDEX IF NOT EXISTS`. A cancellation cannot be rolled back by this plan's
APIs — that is deliberate (append-only history); the recovery path for a
mis-cancelled workflow is the existing resurrection contract only if it was
*failed*, so the CLI plan (206) must gate `wf cancel` behind `--force` with an
affected-row preview.


## Interfaces and Dependencies

No new libraries. End-state additions to `keiro`:
`Keiro.Workflow.Instance.{WorkflowInstanceFilter, defaultWorkflowInstanceFilter,
listWorkflowInstances, CancelWorkflowOutcome, cancelWorkflow,
forceReleaseInstanceLease}`, re-exported from `Keiro.Workflow` as appropriate;
internal `Keiro.Workflow.Journal`, `Keiro.Workflow.Instance.Schema`, and
`Keiro.Workflow.Child.Cancel` hold shared implementation without becoming new
public modules. The
consumer is `docs/plans/206-create-the-keiro-ops-package-with-the-workflow-and-timer-command-domains.md`,
which must use these signatures unchanged (MasterPlan 31 Integration Points).


Revision note: Completed all milestones, reconciled the planned module ownership
with the landed cycle-free shared internals, and recorded the lifecycle-race
contract and validation evidence, 2026-08-08.
