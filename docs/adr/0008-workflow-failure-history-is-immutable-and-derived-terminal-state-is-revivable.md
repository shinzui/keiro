# 8. Workflow failure history is immutable and derived terminal state is revivable

Date: 2026-07-23

Status: Accepted


## Context

A terminal workflow failure exists in three related forms: an append-only
`WorkflowFailed` journal event, a `__workflow_failed__` row in the
generation-scoped workflow step index, and `failed` status on the logical
workflow instance. The index marker makes direct runs return `Failed`; the
instance status removes the workflow from resume discovery.

The failure policy deliberately gives synchronous application exceptions a
bounded retry budget. Previously, reaching that budget had no supported
recovery path. Operators had to coordinate manual SQL against the index and
instance tables after deploying a repair.

Deleting journal history is not an acceptable recovery mechanism. It would
violate the append-only event-store contract and erase the evidence needed to
understand repeated failure. Retaining the old event creates a second concern:
the historical implementation derived the failure event id from workflow,
generation, and the fixed failure step name, so re-failing after resurrection
would collide with the first event.


## Decision

Terminal failure history is immutable, while its derived runnable-state
projections are explicitly revivable.

`resurrectFailedWorkflow` changes a workflow only when its instance status is
`failed`. In one transaction it resets status, attempts, error, retry time,
lease, and completion metadata; deletes the current generation's
`__workflow_failed__` step-index row; and revives a failed child link when one
exists. It appends no audit event and never deletes the historical
`WorkflowFailed` event.

`WorkflowFailed` journal events use store-generated UUIDv7 ids. Concurrent
failure writers remain deduplicated by the existing workflow-step advisory lock
and in-transaction index check. A later failure after resurrection can therefore
append a distinct historical event on the same generation.

Child-link revival is part of the resurrection transaction because a failed
child row is otherwise excluded from discovery and short-circuits child runs.
A failure sentinel already delivered to the parent journal is immutable and is
not retracted. Operators resurrect the parent separately when its own terminal
state should be retried.


## Consequences

- Operators have a supported, transactional alternative to manual recovery SQL.
- Completed steps remain replayable after resurrection, so their side effects
  do not rerun merely because the failure state was cleared.
- Repeated fail/resurrect cycles on one generation preserve each failure event
  with a distinct id.
- A second resurrection call after a successful revival is a guarded no-op
  reported as `WorkflowNotFailed`; an unknown instance reports
  `WorkflowNotFound`.
- Failure audit identity such as operator and ticket remains the caller's
  responsibility; the runtime journal records failures, not administrative
  commands.
- Parent and child recovery are explicit, independently controlled lifecycle
  operations because their journals are independently append-only.
