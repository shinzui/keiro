---
title: "Durable execution (the Workflow effect)"
type: Capability
description: "Write a long-running process as an ordinary effectful computation whose named steps journal into a Kiroku stream, so a crash resumes from the last recorded step with sleep, external signals, and child workflows as journaled suspensions."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-8
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
interface:
  - Keiro.Workflow
  - Keiro.Workflow.Sleep
  - Keiro.Workflow.Awakeable
  - Keiro.Workflow.Child
  - Keiro.Workflow.Resume
requires:
  - CAP-1
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Workflow', 'Keiro.Workflow.Resume', 'Keiro.Workflow.Sleep', 'Keiro.Workflow.Awakeable', 'Keiro.Workflow exact discovery', and 'Keiro.Workflow terminal boundaries' describe blocks exercise named-step replay keyed by step name, crash resume, sleep/awakeable/child suspension, and terminal-marker arbitration against concurrent wakes."
  - kind: guide
    resource: docs/user/durable-workflows.md
    proves: "How to write a durable workflow, what each suspension primitive journals, and how the resume worker recovers in-flight runs."
  - kind: example
    resource: jitsurei/src/Jitsurei/DurableWorkflow.hs
    proves: "A runnable order-fulfillment workflow exercising step, sleepNamed, awakeableNamed resolved by signalAwakeable, and a spawnChild child workflow."
---

# Durable execution (the Workflow effect)

keiro's second engine. A consumer writes a long-running process as an ordinary
`effectful` computation and marks durable points with `step`; each named step
journals its result into a Kiroku stream (`wf:<name>-<id>`), so a crash resumes
from the last recorded step without re-running committed work. Suspension
primitives — `sleepNamed`, `awakeableNamed` (wait for an external signal), and
`spawnChild` (child workflows) — journal as ordinary step records, and a resume
worker recovers in-flight runs. Replay is keyed by step *name*, not source
position, so the workflow body can be refactored without breaking recovery.

It shares the Kiroku substrate and codec contract
([CAP-1](typed-event-model.md)) with the event-sourcing engine but is a distinct
engine: it does not go through the aggregate command cycle, and a consumer adopts
it independently for orchestration work that is awkward to model as an aggregate.

## Shape

```haskell
import Keiro.Workflow
import Keiro.Workflow.Awakeable
import Keiro.Workflow.Child
import Keiro.Workflow.Sleep

fulfillment orderId = do
  reserved <- step (StepName "reserve-stock") (reserveStock orderId)
  sleepNamed (StepName "cool-off") (hours 1)
  (awakeableId, awaitPayment) <- awakeableNamed (StepName "await-payment")
  _ <- step (StepName "publish-await-payment") (publishAwakeableId awakeableId)
  payment <- awaitPayment
  child <-
    spawnChild
      (WorkflowName "ship-order")
      (WorkflowId (orderIdText orderId <> "-ship"))
      (shipOrder orderId payment reserved)
  awaitChild child
```

## Limits

- Replay keyed by step name means step names must be **stable and unique within
  a run**: renaming a step orphans its journaled result and re-runs it, and
  reusing a name collides. This is a real authoring constraint, not a detail.
- Steps are journaled at-least-once with respect to their side effects: a crash
  after a side effect but before the journal append re-runs that step on resume,
  so a step's effect should be idempotent. The engine guarantees the recorded
  *result* is reused, not that an un-journaled external effect ran exactly once.
- Discovery is exact as of the current line (a parked workflow is not re-claimed
  every pass), but a third-party wake source that transitions its own durable row
  without appending to the journal must now flip the owning instance row itself —
  an operational contract a naive integration can get wrong (see
  `docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`).
