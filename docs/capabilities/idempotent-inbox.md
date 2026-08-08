---
title: "Idempotent inbox with Kafka adapter"
type: Capability
description: "Consume inbound messages exactly once with respect to their effect by recording message identity in Postgres, so a redelivered message is recognized and skipped before it drives a command."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-10
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro
interface:
  - Keiro.Inbox
  - Keiro.Inbox.Kafka
  - Keiro.Inbox.Types
requires:
  - CAP-3
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Inbox', 'Keiro.Inbox.Kafka', and 'Keiro cross-context Kafka integration' describe blocks exercise recording message identity, skipping a redelivered message, and driving a command from an accepted message end to end over Kafka."
  - kind: guide
    resource: docs/user/inbox.md
    proves: "How to wire the inbox in front of a command handler so redeliveries are absorbed."
  - kind: guide
    resource: docs/guides/integration-events-with-kafka.md
    proves: "The producer-to-consumer flow across services using the outbox and inbox together over Kafka."
---

# Idempotent inbox with Kafka adapter

A consumer service records the identity of every inbound message it accepts in a
Postgres inbox table, in the same transaction that drives the resulting command
([CAP-3](transactional-command-cycle.md)). A redelivered message — which
at-least-once transports and the outbox drain (CAP-9)
both produce — is recognized by its recorded identity and skipped before it can
apply its effect a second time. The bundled Kafka adapter reads keiro's canonical
envelope headers to derive that identity.

This is recorded separately from the outbox because a consumer adopts and
verifies the inbox on its own — a service that only consumes never runs an
outbox.

## Shape

```haskell
import Keiro.Inbox

withInbox messageId $ \accept ->
  when accept $ runCommand stream sid (commandFor message)  -- second delivery is skipped
```

## Limits

- Idempotency is keyed on the message identity carried in keiro's canonical
  envelope headers; a producer that does not stamp a stable identity, or that
  rewrites it on retry, defeats the dedup. The Kafka inbox reads a **fixed**
  header set and cannot be remapped to arbitrary headers.
- Dedup covers the effect that runs in the inbox transaction. Effects a handler
  performs outside that transaction are not covered by the inbox record.
