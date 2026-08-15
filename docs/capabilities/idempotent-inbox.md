---
title: "Idempotent inbox with Kafka adapter"
type: Capability
description: "Run an inbound database handler at most once per retained (source, dedupe-key) identity, with selectable envelope/source/Kafka/custom policies and a canonical Kafka decoder."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
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
Postgres inbox table, in the same transaction as the handler's database effects.
Those effects may include the transactional command primitives from
[CAP-3](transactional-command-cycle.md). A redelivered message — which
at-least-once transports and the [outbox drain (CAP-9)](transactional-outbox.md)
both produce — is recognized by its recorded identity and skipped before it can
apply its effect a second time. The bundled Kafka decoder reconstructs Keiro's
canonical integration envelope and Kafka delivery reference; the caller chooses
message-id, source-event, topic/partition/offset, or custom deduplication identity.

The basic runner rolls back both the row and handler effects on an exception so
a redelivery can try from scratch. The opt-in retrying runner instead records
failed attempts in a second transaction, retries up to a caller-selected
ceiling, and then leaves an operator-visible failed row as the poison-message
record. Successful rows can retain the full envelope or only the deduplication
facts; failed rows always retain the full envelope for diagnosis.

This is recorded separately from the outbox because a consumer adopts and
verifies the inbox on its own — a service that only consumes never runs an
outbox.

## Shape

```haskell
import Keiro.Inbox

runInboxTransaction
  Nothing
  PreferIntegrationMessageId
  integrationEvent
  (Just kafkaDeliveryRef)
  transactionalHandler
```

## Limits

- The chosen identity must be stable. The default integration-message policy
  cannot deduplicate a producer that mints a new message id on every retry; use
  source-event or a reviewed custom key when that is the intended contract.
- Dedup covers the effect that runs in the inbox transaction. Effects a handler
  performs outside that transaction are not covered by the inbox record.
- Garbage collection defines the deduplication window. A delivery that arrives
  after its completed row is removed is new work to the inbox.
- Failed rows are deliberately excluded from completed-row garbage collection;
  resolving or removing a poison message is an operator decision.
