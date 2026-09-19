---
type: Term
title: integration event
description: A published business fact designed as a stable contract for consumers outside the bounded context that produced it.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-17
status: current
tags:
  - integration
related:
  - TERM-16
  - TERM-18
  - TERM-19
anchors:
  - kind: module
    resource: Keiro.Integration.Event
  - kind: type
    resource: Keiro.Integration.Event.IntegrationEvent
  - kind: doc
    resource: docs/user/integration-events.md
---

# integration event

An integration event exposes the information another context needs. For example, an
ordering context might publish `OrderReadyForShipping` for fulfillment without exposing
its complete internal [domain-event](domain-event.md) history. Its schema must evolve
with its consumers in mind.

Keiro wraps the payload with message identity, routing information, and schema metadata.
The [transactional outbox](transactional-outbox.md) handles reliable sending, and the
[inbox](inbox.md) handles duplicate delivery at the receiver. See
[Integration Events](../user/integration-events.md) for the message contract.
