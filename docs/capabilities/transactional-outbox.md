---
title: "Transactional outbox with Kafka adapter"
type: Capability
description: "Durably map committed events to an ordered, retrying outbox, or enqueue inline with a command, then publish through a transport-neutral drain with Kafka support."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
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
  - kind: module
    resource: keiro/src/Keiro/Outbox.hs
    proves: "The transport-neutral enqueue, canonical producer-subscription, claim/publish, ordering, recovery, and maintenance APIs exposed to applications."
---

# Transactional outbox with Kafka adapter

A producer service normally runs a checkpointed `IntegrationProducer` that maps
each committed private event to a public integration event. It writes the outbox
row in the same Postgres transaction that advances the producer subscription,
retaining source-event identity and position. A saga can instead enqueue inline
with the command's append through `runCommandWithSql` from
[CAP-3](transactional-command-cycle.md). In both shapes, a crash before draining
loses nothing because the durable row remains.

The transport-neutral publisher claims rows with `SKIP LOCKED`, publishes a
batch through an application callback, and marks the successful prefix sent and
failures retryable or dead. Per-key head-of-line ordering is the default;
per-source, stop-the-line, and explicitly best-effort policies are available.
Configurable backoff and attempt ceilings prevent a poison row from retrying
forever, while a separate maintenance pass reclaims rows stranded by crashed
publishers. `Keiro.Outbox.Kafka` supplies the bundled Kafka conversion.

This is recorded separately from the
[inbox (CAP-10)](idempotent-inbox.md)
because a producer adopts and verifies the outbox on its own, without ever
running an inbox.

## Shape

```haskell
import Keiro.Outbox

runCommandWithSql options eventStream targetStream command $ \_appendResult ->
  enqueueIntegrationEventTx stableOutboxId integrationEvent
```

## Limits

- Delivery is at-least-once: the drain publishes then marks sent, so a crash
  between publish and mark re-publishes on restart. Downstream consumers must
  dedup — which is exactly what the [inbox (CAP-10)](idempotent-inbox.md)
  provides for a keiro consumer.
- An ordered policy constrains both claiming and result reporting: a publisher
  callback must not report a later same-key row as delivered after an earlier
  row failed. Dead rows remain operator-visible and stop blocking their key.
- The bundled adapter targets Kafka. Publishing to another broker means
  supplying your own drain sink against the outbox types; that path is not
  covered by the shipped adapter tests.
