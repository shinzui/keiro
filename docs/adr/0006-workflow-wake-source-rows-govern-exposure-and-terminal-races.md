# 6. Workflow wake-source rows govern exposure and terminal races

Date: 2026-07-23

Status: Accepted


## Context

Workflow wake results are journaled on a specific generation, while the rows
that represent awakeables and parent-child links live for the logical workflow
execution. That distinction is necessary: `continueAsNew` rotates journal
history, but an external promise or child execution may still be terminal.

Three gaps violated that lifecycle. A failed child stored no reason on its link
row, so a later-generation `awaitChild` could not reproduce the failure after
rotating past the original failure journal entry. An awakeable id was journaled
and could be handed to an external system before its row was registered, so an
immediate signal looked like an unknown id. Finally, `signalAwakeable` decided
whether to append from a row snapshot read before its transaction, allowing a
concurrent cancel and signal to both appear to win.

ADR 5 establishes the generation-scoped step index as the authoritative lookup
for a journaled result. It deliberately does not let an earlier generation
resolve a later one, so durable wake-source lifecycle state needs its own rule.


## Decision

Wake-source rows are the durable authority for exposure and terminal lifecycle;
generation-scoped journal entries deliver their results to a particular run.

An awakeable row is registered inside the journaled allocation step's action,
before the allocation result can be appended, returned, or handed off. The
await arm retains its idempotent registration as a repair path for historical
allocations whose journal entry exists without a row.

A child link persists its terminal failure reason. On an `awaitChild` journal
miss, a `ChildFailed` row raises `WorkflowChildFailed` directly on any parent
generation. Rows created before the reason column use the child instance's
`last_error`, then a stable generic message, as compatibility fallbacks.

Terminal row transitions and their journal delivery are arbitrated inside one
database transaction. A signal appends when it performs the pending-to-completed
transition, when it repairs an already-completed row from the stored payload,
or when an in-transaction status read observes that another signal completed
the row. If cancellation won, the signal appends nothing and returns `False`.


## Consequences

- Migration `0020-keiro-workflow-children-failure-reason.sql` adds the nullable
  child failure reason without backfilling or rewriting existing rows.
- A parent can observe a failed child after `continueAsNew` without importing a
  prior generation's journal result.
- An awakeable id is signalable as soon as workflow code can observe it.
- Cancellation and completion are mutually exclusive terminal outcomes from
  the workflow's perspective; a cancellation winner cannot leak a value into
  the journal.
- Existing idempotent repair remains supported for completed rows missing a
  journal entry and for historical allocation rows missing before the await.
- A crash after awakeable row registration but before allocation journaling may
  leave an unreachable pending row. Workflow garbage collection already removes
  awakeables by owner coordinates, and the id was never exposed.
- `signalAwakeableFrom` is public as a narrow deterministic race-test seam.
  Ordinary callers should continue to use `signalAwakeable`.
