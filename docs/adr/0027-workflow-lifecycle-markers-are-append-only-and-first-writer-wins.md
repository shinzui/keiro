---
type: Architecture Decision Record
title: Workflow lifecycle markers are append-only and first writer wins
description: Distinct workflow completion, cancellation, failure, and rotation markers arbitrate under one generation lifecycle lock and cancellation never rewrites history.
timestamp: 2026-08-08T23:02:27Z
docId: ADR-27
status: Accepted
date: 2026-08-08
---

# 27. Workflow lifecycle markers are append-only and first writer wins

Date: 2026-08-08

Status: Accepted


## Context

Operator cancellation must use the same journal and derived-index path as normal
workflow execution. Writing only `keiro_workflows.status` would let a replay
ignore the operator action; deleting or replacing journal history would violate
the event-store contract established for failure recovery by
[ADR 8](0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md).

The journal append path historically locked one step name at a time. That makes
retries of one marker idempotent, but completion, cancellation, failure, and
`continueAsNew` use different reserved step names. Two distinct lifecycle
writers could therefore both append before the terminal guard on the instance
summary rejected the second derived-status update. The row would show one
winner while the journal and step index contained contradictory lifecycle
markers.


## Decision

Every generation lifecycle marker — `WorkflowCompleted`,
`WorkflowCancelled`, `WorkflowFailed`, and `WorkflowContinuedAsNew` — takes one
shared generation-scoped lifecycle advisory lock before its normal per-marker
lock. Under that lock the append transaction first checks whether the exact
marker already exists, preserving idempotent retries, then refuses a distinct
existing lifecycle marker with `JournalRefusedTerminal`. The first committed
lifecycle marker is therefore the only marker recorded for that generation.

Operator `cancelWorkflow` is a supported library operation. It refuses an
unknown workflow rather than creating state from a typo. For a top-level
workflow it appends `WorkflowCancelled` to the current generation through the
standard append transaction. If rotation wins first, cancellation resolves the
new current generation and retries there. For a linked child it delegates to
the existing child-cancellation transaction so the child marker, child-row
transition, and parent's cancelled await sentinel remain atomic.

Cancellation is append-only and stops fresh work at the next workflow boundary.
One action already in flight may finish and journal idempotently. Cancellation
does not cascade to descendants, and cancelled workflows have no resurrection
operation; operators cancel children explicitly. Failure resurrection remains
the narrower derived-state recovery operation defined by ADR 8.


## Consequences

- The journal, generation-scoped step index, and instance summary agree on one
  lifecycle winner even when cancellation races completion, failure, or
  rotation.
- Repeating cancellation reports the existing terminal state without appending
  another event. Cancelling a completed or failed workflow reports that state
  and preserves its history.
- Linked-child cancellation continues to wake the parent with the typed
  cancellation result; a CLI or other operator surface must not reproduce that
  transaction with ad hoc SQL.
- A cancellation that loses to `continueAsNew` follows the rotation and marks
  the new current generation instead of leaving the logical workflow runnable.
- The common lifecycle lock is scoped to one workflow generation, so unrelated
  workflows and ordinary step appends do not contend on it.


## Related decisions

- [ADR 6](0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md)
  governs wake-source delivery when cancellation or failure has already won.
- [ADR 8](0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md)
  defines the exceptional recovery contract for failed workflows while keeping
  immutable failure history.
