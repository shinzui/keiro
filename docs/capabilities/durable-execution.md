---
title: "Durable execution (the Workflow effect)"
type: Capability
description: "Write a long-running effectful computation whose named steps journal durably, with crash-safe resume, exact discovery, suspension, children, version patches, generation rotation, snapshots, and lifecycle operations."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
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
  - Keiro.Workflow.Awakeable.Compatibility
  - Keiro.Workflow.Child
  - Keiro.Workflow.Instance
  - Keiro.Workflow.Resume
  - Keiro.Workflow.Snapshot
  - Keiro.Workflow.Gc
requires:
  - CAP-1
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The workflow, resume, sleep, awakeable, child, exact-discovery, snapshot, cancellation, GC, and terminal-boundary blocks exercise named-step replay, durable instance progress, suspension/wake races, pacing, and lifecycle cleanup."
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
journals its result into a [Kiroku](mori://shinzui/kiroku) stream
(`wf:<name>-<id>`), so a crash resumes
from the last recorded step without re-running committed work. Suspension
primitives — `sleepNamed`, `awakeableNamed` (wait for an external signal), and
`spawnChild` (child workflows) — journal as ordinary step records, and a resume
worker recovers in-flight runs. Replay is keyed by step *name*, not source
position, so compatible refactors can move code while retaining stable step
names and control flow.

The instance row is the complete discovery and wake ledger. A suspended workflow
is absent from ordinary discovery until its durable `wake_after` becomes due or
a wake source moves the instance back to running. Claims distinguish acquired,
leased, paced, and unavailable work, and a bounded resume pass reports durable
movement separately from blocked or unregistered instances so an operator does
not spin on work that cannot advance. Optional journal snapshots accelerate
long runs without replacing the journal as the source of truth. Active
instances can be cancelled; failed instances can be resurrected; and lifecycle
state can be inspected and collected through the APIs and
[CAP-16](operational-console.md).

Long-lived definitions can evolve explicitly. `patch` journals one stable
old-versus-new branch decision per instance, while `continueAsNew` rotates an
unbounded run to a fresh journal generation with a carried seed. Rotation keeps
history bounded but allocates fresh opaque awakeable ids, which must be
republished by the application.

It shares the [Kiroku](mori://shinzui/kiroku) substrate and codec contract
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

The allocated `AwakeableId` is opaque. Publish and later signal the exact value
returned by `awakeableNamed`; application code must not derive it from workflow
coordinates. Allocation/publication should be idempotent because a crash can
occur after publishing the id but before journaling the step result.

## Limits

- Replay keyed by step name means step names must be **stable and unique within
  a generation**: renaming a step deliberately re-runs it, and reusing a name
  collides. Changing a journaled result type in place breaks resume. This is a
  real authoring constraint, not a detail.
- `PatchId` values are permanent instance-history identities and must never be
  reused for a different branch. `continueAsNew` bounds each generation, not the
  number of generations or the lifecycle rows an operator must eventually
  collect.
- Steps are journaled at-least-once with respect to their side effects: a crash
  after a side effect but before the journal append re-runs that step on resume,
  so a step's effect should be idempotent. The engine guarantees the recorded
  *result* is reused, not that an un-journaled external effect ran exactly once.
- Discovery is exact in the 0.12 runtime (a parked workflow is not re-claimed
  every pass), but a third-party wake source that transitions its own durable row
  without appending to the journal must now flip the owning instance row itself —
  an operational contract a naive integration can get wrong (see
  `docs/adr/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md`).
- A resume registry must contain a definition for every workflow name still in
  flight. Missing names are reported and left durable; they are not guessed,
  skipped as success, or decoded through a different definition.
