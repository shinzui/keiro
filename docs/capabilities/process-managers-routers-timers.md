---
title: "Event-sourced process managers, routers, and durable timers"
type: Capability
description: "React to one category's events by issuing another category's commands — with correlation ids, retry counters, and durable timers carried as typed register slots — all event-sourced and replay-safe."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-7
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
interface:
  - Keiro.ProcessManager
  - Keiro.Router
  - Keiro.Timer
  - Keiro.Wake
requires:
  - CAP-3
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.ProcessManager', 'Keiro.ProcessManager snapshots', 'Keiro.Router', and 'Keiro.Timer' describe blocks exercise event-sourced reaction, deterministic dispatch-id derivation, duplicate-confirmation suppression, effectful router fan-out, and durable timer scheduling and firing."
  - kind: guide
    resource: docs/user/process-managers-and-timers.md
    proves: "How process managers and timers are modelled as transducers with register slots and how dispatch and timers are made durable."
  - kind: example
    resource: jitsurei/src/Jitsurei/EscalationProcess.hs
    proves: "A runnable on-call escalation process manager with a timer, plus 'Jitsurei/AgentQualRouter.hs' for a router that fans out to overlapping targets."
---

# Event-sourced process managers, routers, and durable timers

These are three expressions of one mechanism: a keiki transducer that consumes
one category's events and produces another category's commands, with correlation
ids, retry counters, and timer handles held as typed register slots. A *process
manager* coordinates a long-running domain saga; a *router* fans a source event
out to every matching target (including effectful fan-out); a *durable timer*
schedules a future action that fires exactly when due, journaled so a crash does
not lose it. Dispatch ids are derived deterministically from a fixed tuple, so a
replay re-derives the same id and never double-dispatches. All of it is
event-sourced through the command cycle
([CAP-3](transactional-command-cycle.md)) and therefore replay-safe.

They are one capability because adopting a router after a process manager is the
same decision again — the same transducer shape, the same dispatch and durable
follow-up mechanism, the same evidence — and timers are the suspension primitive
process managers and routers both use.

## Shape

```haskell
import Keiro.ProcessManager
import Keiro.Router
import Keiro.Timer

-- react to OrderShipped by commanding the shipment domain, and
-- scheduleTimerOnceTx to escalate if no acknowledgement arrives in time
```

## Limits

- Dispatch is deterministic and idempotent by construction, but the *effect* a
  router fans out to must itself tolerate at-least-once delivery on replay; the
  framework guarantees the same dispatch id, not that a downstream side effect is
  itself idempotent.
- Timer firing is polled and drained in batches; it is durable and ordered but
  not a real-time scheduler — a timer fires at or after its due time, under the
  worker's drain cadence, not to the millisecond.
- Rejected dispatches are recorded and replayed by a separate capability
  (CAP-11); this record covers issuing dispatch, not its dead-letter lifecycle.
