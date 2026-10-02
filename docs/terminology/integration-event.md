---
type: Term
title: integration event
description: "An integration event is a published business fact that forms a contract for consumers outside its owning bounded context."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

An integration event is a published business fact that forms a contract for consumers outside its owning bounded context.

An ordering context can publish `OrderReadyForShipping` without exposing its complete domain history. Schema changes must account for consumers.

Keiro adds message identity, routing information, and schema metadata to the payload. The [transactional outbox](transactional-outbox.md) supports reliable sending. The receiving [inbox](inbox.md) handles duplicate delivery.

See [Integration Events](../user/integration-events.md).
