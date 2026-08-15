---
title: "Canonical integration-event envelope"
type: Capability
description: "Exchange a transport-neutral public event envelope with stable message/source identity, schema and content metadata, causation/correlation, and W3C trace context."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
capabilityId: CAP-19
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro-core
interface:
  - Keiro.Integration.Event
requires: []
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Integration.Event' block exercises JSON payload round trips, identity and routing preservation, canonical schema/source/trace headers, content types, and typed decode failures."
  - kind: guide
    resource: docs/user/integration-events.md
    proves: "The complete public envelope, identity and routing rules, header mapping, schema-reference posture, and relationship to private domain events."
  - kind: module
    resource: keiro-core/src/Keiro/Integration/Event.hs
    proves: "The transport-neutral IntegrationEvent type, typed content/schema/trace values, and pure payload/header encode/decode boundary."
---

# Canonical integration-event envelope

`IntegrationEvent` is Keiro's public event contract between bounded contexts. It
is deliberately distinct from a private
[Kiroku](mori://shinzui/kiroku) `RecordedEvent` and can evolve on its own
contract schedule. The byte-oriented envelope carries a stable message id,
source and destination, optional partitioning key, event type, schema version,
content type and optional registry-neutral schema reference, source-event
identity, occurrence time, causation and correlation ids, W3C trace context,
and optional attributes.

Pure helpers project the payload and canonical transport headers and decode JSON
payloads without coupling the contract to a broker. The
[outbox (CAP-9)](transactional-outbox.md) and
[inbox (CAP-10)](idempotent-inbox.md) persist, publish, reconstruct, and dedupe
this same envelope; they do not define competing wire shapes.

`messageId` identifies one public message and is defined to remain stable across
publication retries; CAP-9 persists it with the row that enforces that rule.
Optional `sourceEventId` and `sourceGlobalPosition` identify the private fact
that caused it; one source event may intentionally produce several public
messages with distinct message ids. Consumers choose which identity matches
their deduplication contract.

## Shape

```haskell
import Keiro.Integration.Event

integrationEvent =
  IntegrationEvent
    { messageId = stableMessageId
    , source = "ordering"
    , destination = "billing.orders.v1"
    , key = Just orderId
    , eventType = "OrderPlaced"
    , schemaVersion = 1
    , contentType = ApplicationJson
    , schemaReference = Nothing
    , sourceEventId = Just privateEventId
    , sourceGlobalPosition = Just privatePosition
    , payloadBytes = encodedPayload
    , occurredAt = occurredAt
    , causationId = causationId
    , correlationId = correlationId
    , traceContext = traceContext
    , attributes = Nothing
    }
```

## Limits

- The envelope is a contract and pure wire mapping, not a publisher, inbox,
  registry client, or delivery guarantee. Adopt
  [CAP-9](transactional-outbox.md) and/or [CAP-10](idempotent-inbox.md) for
  durable transport behavior.
- JSON is the version-1 convenience encoding, but `OtherContentType` and the
  optional schema reference are registry-neutral metadata. Keiro does not fetch
  schemas or validate application payload compatibility against a registry.
- Applications own public contract versioning and destination rollout. A schema
  version field records the choice; it does not make incompatible consumers
  forward-compatible automatically.
