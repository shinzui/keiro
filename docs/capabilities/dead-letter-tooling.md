---
title: "Dead-letter records and controlled replay"
type: Capability
description: "Durably record a dispatch that could not be delivered, inspect a subscription's records, and replay them with an explicit idempotent handler so rejected messages are not silently lost."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
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
    proves: "The 'Keiro.DeadLetter' describe block exercises durable rejected-dispatch records, bounded listing, replay outcome classification, missing-source handling, and caller-controlled duplicate suppression."
  - kind: guide
    resource: docs/user/dead-letters.md
    proves: "When a dispatch is dead-lettered, what the record contains, and how to replay the dead-letter queue safely."
  - kind: module
    resource: keiro/src/Keiro/DeadLetter.hs
    proves: "The dispatch dead-letter record types and the dispatcher-kind taxonomy that classifies which subscription produced a rejected dispatch."
---

# Dead-letter records and controlled replay

When a process-manager or router dispatch ([CAP-7](process-managers-routers-timers.md))
cannot be delivered, keiro writes a durable dead-letter row rather than dropping
it, tagged with the dispatcher kind that produced it. `Keiro.DeadLetter.Replay`
can list a bounded set of records for one subscription and replay them through a
caller-supplied handler. Each attempted record is classified as freshly replayed,
already applied, failed, or missing from the source stream. The original
[Kiroku](mori://shinzui/kiroku) dead-letter row is retained as an audit record;
replay neither deletes it nor marks it settled.

This is its own capability because it is adopted and verified as an operational
tool distinct from issuing dispatch: a consumer wires dead-letter replay into its
recovery runbook, and its evidence is separate from the dispatch mechanism.

## Shape

```haskell
import Keiro.DeadLetter.Replay

outcomes <- replaySubscriptionDeadLetters subscription 100 $ \recorded -> do
  -- Use a deterministic event/message id in this handler.
  replayRecordedEvent recorded
```

## Limits

- Replay safety comes from the supplied handler's idempotency or deterministic
  identifiers, not from mutable state on the dead-letter row. A repeated pass
  calls the handler again; the handler reports `ReplayedDuplicate` when the
  intended effect already exists.
- The scan is bounded by the requested limit. A hard-deleted source event is
  reported as `ReplaySourceMissing`; it cannot be reconstructed from the
  dead-letter record alone.
- Dead-lettering covers dispatch rejection and subscription DLQ replay. The PGMQ
  work queue keeps its own DLQ ([CAP-12](postgres-work-queues.md)); the two are
  separate surfaces and this record does not cover the pgmq DLQ.
