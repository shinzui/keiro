---
type: Review
title: Jitsurei durable workflow example
description: The example signals an id the workflow did not allocate, remains suspended, and nevertheless reports that durability was proven.
generated:
  by: process:codex
  at: "2026-08-14T12:59:14Z"
reviewId: REV-3
subject: mori://shinzui/keiro
subjectKind: component
component: Jitsurei.DurableWorkflow
reviewedSha: 7ddeaabf1850449241aaf0bd114c41a25455de9d
coverage: full
reviewedAt: "2026-08-14T12:59:14Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-5
effort: unspecified
outcome: changes-requested
dimensions:
  - correctness
  - test-coverage
  - documentation
context: >-
  Read the complete Jitsurei.DurableWorkflow module and the workflow driver's
  runDurableWorkflowDemo path, then exercised it against a freshly initialized
  review database as part of the repository verification flow.
---

# Jitsurei durable workflow example

## Release blocker

`paymentWebhookAwakeableId` derives the legacy coordinate-based id and claims it
is exactly what `awakeableNamed` allocates. The workflow discards the real id
returned by `awakeableNamed`, so the driver has no valid id to signal. On a fresh
review database the demo printed:

```text
signalAwakeable payment-webhook -> False
final outcome: Suspended
durability proven: the completed workflow was NOT re-executed from scratch
```

The final success message is a false positive. Exact workflow discovery omits a
workflow parked on an unresolved awakeable, so “no unfinished work discovered”
does not mean the workflow completed. The driver prints the signal result and
final outcome but asserts neither; there is no focused test for
`paymentWebhookAwakeableId` or for the demo reaching `Completed`.

Release should remain blocked until the example hands out and later signals the
actual allocated id, requires `signalAwakeable` to return `True`, requires the
final outcome to be `Completed`, and has a regression test that fails when the
workflow remains parked. The module's claims that steps never repeat also need
to state the runtime's at-least-once crash-window contract.

## Evidence

- `orderFulfillmentWorkflow` binds `(_awkId, awaitPayment)` and discards the
  actual allocation.
- `runDurableWorkflowDemo` signals `paymentWebhookAwakeableId orderId`, prints
  the returned `Bool`, and continues regardless of `False`.
- The restart proof tests exact discovery rather than terminal status or a
  `Completed` outcome.
- The parent journal stopped after the awakeable allocation and the child
  journal was empty in the fresh-database run.
