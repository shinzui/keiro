---
title: "Event-sourced process managers, routers, and durable timers"
type: Capability
description: "React to source events with process-manager commands, custom or bounded declarative router fan-out, and durable timers, using deterministic dispatch identity and replay-safe state."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
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
  - Keiro.Router.Selection
  - Keiro.Timer
  - Keiro.Wake
requires:
  - CAP-3
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The process-manager, router, RouterSelection, and timer blocks exercise deterministic dispatch ids and compatibility bridges, typed outcomes, duplicate suppression, bounded stable-union fan-out, failure policy, and durable timer scheduling/firing."
  - kind: conformance
    resource: keiro-dsl/test/conformance-declarative-router/Main.hs
    proves: "A complete generated declarative router compiles with typed query selection, bounded normalized recipients, dispatch mapping, and the closed empty/failure/redelivery policy contract."
  - kind: guide
    resource: docs/user/process-managers-and-timers.md
    proves: "How process managers and timers are modelled as transducers with register slots and how dispatch and timers are made durable."
  - kind: example
    resource: jitsurei/src/Jitsurei/EscalationProcess.hs
    proves: "A runnable on-call escalation process manager with a timer, plus 'Jitsurei/AgentQualRouter.hs' for a router that fans out to overlapping targets."
---

# Event-sourced process managers, routers, and durable timers

These are three expressions of one mechanism: a worker consumes source events
and produces target commands, with correlation
ids, retry counters, and timer handles held as typed register slots. A *process
manager* coordinates a long-running domain saga; a *router* fans a source event
out to matching targets; a *durable timer*
schedules a future action that fires after it becomes due, journaled so a crash does
not lose it. Dispatch ids are derived deterministically from a fixed tuple, so a
replay re-derives the same id and never double-dispatches. All of it is
event-sourced through the command cycle
([CAP-3](transactional-command-cycle.md)) and therefore replay-safe.

They are one capability because adopting a router after a process manager is the
same decision again — the same transducer shape, the same dispatch and durable
follow-up mechanism, the same evidence — and timers are the suspension primitive
process managers and routers both use.

Declarative routers add a closed runtime selection contract. For each source
event an application-owned query returns candidate target commands; Keiro sorts
by target stream, collapses exact duplicates, rejects conflicting commands,
applies a positive recipient cap, and preserves a target-keyed stable union
across redelivery. Empty results and query/evaluation failures follow explicit
ack/retry/dead-letter/halt policies, and a later target failure retains earlier
successful dispatches. Language 5 checks and generates the same contract.

Outcome-aware coordinator variants carry the accepted/rejected/no-op result from
[CAP-18](typed-domain-command-outcomes.md). Typed silent decisions are handled
successfully and do not become dispatch failures merely because they emitted no
event.

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
- Declarative selection is intentionally bounded and has one fixed normalization
  model. Arbitrary ordering, unbounded broadcast, or custom redelivery merging
  remains a hand-written router responsibility.
- Timer firing is polled and drained in batches; it is durable and ordered but
  not a real-time scheduler — a timer fires at or after its due time, under the
  worker's drain cadence, not to the millisecond.
- Rejected dispatches are recorded and replayed by a separate capability
  ([CAP-11](dead-letter-tooling.md)); this record covers issuing dispatch, not
  its dead-letter lifecycle.
