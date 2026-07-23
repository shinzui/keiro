# 7. Workflow sleep timers are generation-owned lifecycle state

Date: 2026-07-23

Status: Accepted


## Context

A workflow sleep is represented by a row in `keiro.keiro_timers`. The row is
armed by one journal generation, later appends that sleep step's result, and
uses the workflow instance's `wake_after` column as a discovery hint. Earlier
implementations treated these pieces independently.

A timer fire resolved the workflow's current generation at fire time. A timer
left in `firing` after its append committed could therefore be requeued after
`continueAsNew` and resolve a same-named sleep on the next generation. Every
replay arm also rewrote `wake_after` even though the insert-only timer retained
its original `fire_at`, postponing discovery after the timer became due.
Finally, workflow garbage collection deleted only terminal timer rows. A
scheduled timer could survive deletion of the journal and instance, fire later,
and recreate the workflow from incomplete history.

ADR 5 requires all generation-scoped await results to remain recoverable from
the workflow step index. This decision supplies the complementary ownership and
lifecycle rules for the sleep timer that produces such a result.


## Decision

The workflow generation that first arms a sleep owns that timer and its
completion. New workflow-sleep payloads carry the arming generation, and firing
appends directly to that generation through `prepareJournalAppend`. Legacy
payloads recover the generation by matching their deterministic timer id
against candidate generation ids. A stale re-fire therefore becomes an
idempotent append check on its original generation and never targets a later
generation.

The timer insert that wins first-arm-wins scheduling owns both `fire_at` and
the workflow instance's `wake_after` hint. `scheduleTimerOnceTx` reports whether
it inserted; only that successful insert writes the hint. A successful fire
clears `wake_after` in the same transaction as its journal append.

Workflow garbage collection removes every workflow-sleep timer owned by an
eligible terminal instance, regardless of timer status. As defense in depth, a
claimed timer whose instance row still exists with `completed`, `cancelled`, or
`failed` status cancels itself and appends nothing.

A missing instance row is not treated as terminal. A workflow can crash after
arming a first-operation sleep but before recording its suspended instance; in
that case the fire is allowed to append, and the append transaction recreates
the discoverable running instance.


## Consequences

- A sleep completion is generation-scoped even across timer-worker retries and
  `continueAsNew`.
- Re-entering a due or already-fired sleep cannot extend its discovery delay.
- A fired sleep becomes immediately discoverable because its journal append
  and wake-hint clear commit atomically.
- Collecting a terminal workflow also collects scheduled, firing, fired,
  cancelled, and dead workflow-sleep timers.
- Terminal instance status prevents a surviving timer from recreating deleted
  journal data during a partial-GC recovery window.
- The missing-instance recovery path remains valid and is covered separately
  from terminal-instance refusal.
- `scheduleTimerOnceTx` now returns `Bool`; callers that do not need insertion
  ownership may discard it with `void`.
