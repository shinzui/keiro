---
title: "Transactional outbox with Kafka adapter"
type: Capability
description: "Enqueue outbound messages in the same Postgres transaction as the events that produced them, then drain them to Kafka so a published message can never disagree with committed state."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-9
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
interface:
  - Keiro.Outbox
  - Keiro.Outbox.Kafka
  - Keiro.Outbox.Types
requires:
  - CAP-3
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Outbox' and 'Keiro.Outbox.Kafka' describe blocks exercise writing outbox rows in the command transaction, draining them, and the Kafka adapter's publish and trace propagation."
  - kind: guide
    resource: docs/user/outbox.md
    proves: "How to enqueue to the outbox inside a command and run the drain worker to publish."
  - kind: example
    resource: jitsurei/src/Jitsurei/ShipmentNotices.hs
    proves: "A runnable service producing outbound notices from domain events (via the queue/outbox path)."
---

# Transactional outbox with Kafka adapter

A producer service enqueues an outbound message into an outbox table *in the same
Postgres transaction* as the command that produced it
([CAP-3](transactional-command-cycle.md)), using `runCommandWithSql`. A drain
worker then publishes those rows — to Kafka via the bundled adapter — and marks
them sent. Because the message and the state change commit atomically, a
published message can never describe state that did not commit, and a crash
before draining loses nothing: the row is still there to publish.

This is recorded separately from the inbox (CAP-10)
because a producer adopts and verifies the outbox on its own, without ever
running an inbox.

## Shape

```haskell
import Keiro.Outbox

runCommandWithSql stream sid cmd $ \events ->
  enqueueOutbox topic (renderMessages events)  -- committed with the append
```

## Limits

- Delivery is at-least-once: the drain publishes then marks sent, so a crash
  between publish and mark re-publishes on restart. Downstream consumers must
  dedup — which is exactly what the inbox (CAP-10)
  provides for a keiro consumer.
- The bundled adapter targets Kafka. Publishing to another broker means
  supplying your own drain sink against the outbox types; that path is not
  covered by the shipped adapter tests.
