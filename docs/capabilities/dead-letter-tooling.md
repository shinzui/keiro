---
title: "Dead-letter records and idempotent replay"
type: Capability
description: "Durably record a dispatch that could not be delivered and replay a subscription's dead-letter queue idempotently, so a rejected message is never silently lost and never double-applied on replay."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-11
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
interface:
  - Keiro.DeadLetter
  - Keiro.DeadLetter.Replay
requires:
  - CAP-7
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.DeadLetter' describe block exercises recording a rejected dispatch as a durable row and replaying a subscription dead-letter queue without re-applying an already-settled entry."
  - kind: guide
    resource: docs/user/dead-letters.md
    proves: "When a dispatch is dead-lettered, what the record contains, and how to replay the dead-letter queue safely."
  - kind: module
    resource: keiro/src/Keiro/DeadLetter.hs
    proves: "The dispatch dead-letter record types and the dispatcher-kind taxonomy that classifies which subscription produced a rejected dispatch."
---

# Dead-letter records and idempotent replay

When a process-manager or router dispatch ([CAP-7](process-managers-routers-timers.md))
cannot be delivered, keiro writes a durable dead-letter row rather than dropping
it, tagged with the dispatcher kind that produced it. `Keiro.DeadLetter.Replay`
replays a subscription's dead-letter queue idempotently: an entry that has
already been settled is recognized and not applied again, so a replay pass can be
re-run safely after a partial failure.

This is its own capability because it is adopted and verified as an operational
tool distinct from issuing dispatch: a consumer wires dead-letter replay into its
recovery runbook, and its evidence is separate from the dispatch mechanism.

## Shape

```haskell
import Keiro.DeadLetter.Replay

replayDeadLetters subscription  -- re-drives unsettled entries; settled ones are skipped
```

## Limits

- Replay is idempotent with respect to the dead-letter record's settled state; it
  is not a general poison-message policy. Deciding *why* an entry keeps failing
  and whether to retry, drop, or fix-and-replay is left to the operator.
- Dead-lettering covers dispatch rejection and subscription DLQ replay. The PGMQ
  work queue keeps its own DLQ (CAP-12); the two are
  separate surfaces and this record does not cover the pgmq DLQ.
