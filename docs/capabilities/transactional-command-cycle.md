---
title: "The transactional command cycle"
type: Capability
description: "Run the load → streaming replay → decide → append-batch command cycle with optimistic concurrency, optionally committing events, inline projections, and outbox/timer rows in one Postgres transaction."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-3
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
interface:
  - Keiro.Command
  - Keiro.Connection
requires:
  - CAP-1
  - CAP-2
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Command' and 'Keiro.Command enrichment parity' describe blocks exercise streaming replay, decide, append-batch with optimistic-concurrency conflict handling, and the transactional 'runCommandWithSql' step that appends events and writes inline projections/outbox/timer rows atomically."
  - kind: guide
    resource: docs/user/command-cycle.md
    proves: "The canonical command cycle end to end, including when to use the plain runner versus the transactional runner."
  - kind: example
    resource: jitsurei/src/Jitsurei/CreditLimit.hs
    proves: "A runnable aggregate deciding commands into events through the real command runner."
---

# The transactional command cycle

The command cycle is how a consumer changes state: load a stream, replay its
history (streamed, not held in memory) through the typed event model
([CAP-1](typed-event-model.md)), decide the incoming command against the current
state via a validated transducer ([CAP-2](replay-safety-validation.md)), and
append the resulting events as one optimistic-concurrency batch keyed on the
expected stream version. A conflicting concurrent append is reported so the
caller can retry.

`runCommandWithSql` extends the append into a single Postgres transaction that
also updates inline projections and writes outbox and timer rows, so a command
and its immediate side effects commit or roll back together. This is the
mechanism the transactional outbox (CAP-9) and durable timers (CAP-7) rely on.

## Shape

```haskell
import Keiro.Command

runCommand validatedStream streamId command       -- append-only
runCommandWithSql validatedStream streamId command $ \events ->
  -- extra writes committed in the same transaction as the append
```

## Limits

- Optimistic concurrency means a hot stream under contention will see append
  conflicts and must retry; there is no server-side serialization queue. Model
  aggregates so a single stream is not a global write bottleneck.
- The transactional step commits only what runs inside the one Postgres
  transaction — cross-database or cross-service effects are not covered and
  belong to the outbox/inbox path, not to `runCommandWithSql`.
