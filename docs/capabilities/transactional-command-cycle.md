---
title: "The transactional command cycle"
type: Capability
description: "Run the load → streaming replay → decide → append-batch command cycle with optimistic concurrency, duplicate-event probes, immediate replay verification, and optional transactional side effects."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
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
    proves: "The 'Keiro.Command', 'Keiro.Command enrichment parity', and 'typed domain command outcomes' blocks exercise streamed hydration, decide, duplicate probes, retry/fixpoint handling, append-time replay verification, and transactional SQL/projection variants."
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
mechanism the [transactional outbox (CAP-9)](transactional-outbox.md) and
[durable timers (CAP-7)](process-managers-routers-timers.md) rely on.
Every successful append is replayed immediately from its pre-command state so a
bad just-committed batch is reported through telemetry at the point it poisons
the stream. Caller-supplied event ids also make an externally retried submission
detectable without a second append.

Consumers that need business-level accepted/rejected/no-op results use the same
cycle through the outcome-aware runners described in
[CAP-18](typed-domain-command-outcomes.md); those runners preserve the retry and
transaction boundaries here.

## Shape

```haskell
import Keiro.Command

runCommand options validatedStream targetStream command       -- append-only
runCommandWithSql options validatedStream targetStream command $ \appendResult ->
  -- extra writes committed in the same transaction as the append
```

## Limits

- Optimistic concurrency means a hot stream under contention will see append
  conflicts and will retry only within the configured budget. A repeated
  conflict against a stream hidden by a truncate marker terminates as a typed
  conflict fixpoint rather than looping forever.
- The transactional step commits only what runs inside the one Postgres
  transaction — cross-database or cross-service effects are not covered and
  belong to the outbox/inbox path, not to `runCommandWithSql`.
