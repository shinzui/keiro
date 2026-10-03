---
type: Bug Report
title: Child completion crash strands the waiting parent
description: A child workflow process killed after its completion marker commits and before the parent wake commits leaves the parent suspended permanently.
generated:
  by: process:claude-code
  at: "2026-10-03T13:15:15Z"
bugId: BUG-8
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: PostgreSQL 18 with durable settings; keiro 0.17.0.0; one parent parked on awaitChild, the child run in a separate process, and two resume workers.
observed: The child process was killed by SIGKILL immediately after its WorkflowCompleted marker committed. Afterwards the child instance was completed, its keiro_workflow_children link stayed running, the parent journal had no child result step, and the parent instance stayed suspended. Two resume workers ran for 120 seconds without changing any of these rows.
expected: The parent-child relationship should survive the crash. The child's completion should be delivered to the parent, so that the parent's next run returns the child's result from awaitChild.
reproduction:
  - Build the released cohort used by mori://shinzui/keiro-runtime-kenshou and start durable PostgreSQL 18.
  - Run `nix develop -c cabal run kenshou -- run keiro/workflow/concurrency/child-completion-crash-window --dim pg.durability=durable --out runs/` from the Kenshou repository.
  - The scenario parks a parent on awaitChild, runs the one-step child through runChildWorkflow in a separate process, and sends SIGKILL from an onJournalAppend hook on the child's second committed append, which is its completion marker.
  - Inspect the `window-reached-between-marker-and-wake` and `parent-completes-after-child-marker-crash` verdicts. The control arm kills the child after its first append instead, and its parent completes in the same run.
workaround: Detect links that are still running although their child instance is completed, then call childCompletionHook for each one with the child's recorded result. The hook marks the link completed and appends the parent's result step in one transaction. The reproducing scenario has not exercised this repair.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-03T13:20:00Z"
    document_timestamp: "2026-10-03T13:15:15Z"
    scope: content-and-metadata
    outcome: commented
    provider: Anthropic
    model: claude-opus-5-5
    effort: low
    context: Checked the report against Kenshou finding 63 and its three runs, runChildWorkflow, childCompletionHook and the awaitChild arm in keiro-0.17.0.0 and keiro-0.19.0.0, discovery in Keiro.Workflow.Schema, and ADR-23. The workaround and the possible repairs are untested.
---

# Child completion crash strands the waiting parent

The Kenshou scenario failed three times out of three, and only
`parent-completes-after-child-marker-crash` was violated each time. Two runs
used a dirty development harness: `01a10018-e79a-713d-b832-07dc38133015`
(default seed) and `01a1003a-a622-750b-82a4-be08f2a490e6` (seed 7). The third
used a clean harness at revision `cb9f003d0dc60a3463213593855846922c2f28c0`:
`01a10041-1c12-7327-b58a-812d0f118088` (seed 11). In every run the precondition
verdict `window-reached-between-marker-and-wake` held, so the kill landed
between the child's completion marker and the parent's wake. Run artifacts are
under `mori://shinzui/keiro-runtime-kenshou` at `runs/<run-id>`; the
artifact-level Mori URI for run directories is pending. The report source is
`mori://shinzui/keiro-runtime-kenshou` at
`docs/findings/63-keiro-child-completion-crash-strands-parent.md`; the
finding-level URI is pending.

`runChildWorkflow` in `keiro/src/Keiro/Workflow/Child.hs` commits the child's
completion marker inside `runWorkflowWith` and calls `childCompletionHook` in a
later transaction. A process death between those transactions leaves no route
to the parent:

- The child instance is terminal, so `findUnfinishedWorkflowIds` no longer
  returns it, and no worker runs `runChildWorkflow` for it again.
- The link row is still `running`. The `awaitChild` arm delivers only from a
  `ChildCompleted` link with a stored result, so it re-arms nothing.
- The parent is suspended with no due wake, so discovery never returns it.

[ADR-23](../adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md)
states that a wake source which transitions its durable row without writing the
instance row strands its workflow permanently. Here the completed child
instance is that unpaired transition. The module documentation also promises
that the relationship survives a crash. Plan 200 removed the
`findRunningChildIds` discovery seed, which may previously have rediscovered
the running link and replayed the hook. That history is unverified, so this
report records no `lastWorkingVersion`.

The source of `Keiro.Workflow.Child` and `Keiro.Workflow.Resume` is unchanged
between `keiro-0.17.0.0` and `keiro-0.19.0.0`, so the window appears to remain
in the current release; only 0.17.0.0 has been run.

Possible repairs: commit the child's completion marker, the link transition
and the parent append in one transaction, or keep a completed child whose link
is still `running` discoverable until its hook has run. A change to the
`awaitChild` arm alone would not help, because the stranded parent is never
run. This report does not prescribe a repair.
