---
type: Term
title: integration event
description: "A stable public message that carries a fact from one bounded context to another over a transport such as Kafka, in keiro's `IntegrationEvent` envelope."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-17
status: current
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

The envelope fixes the message id, source, destination, event type, schema version, and content
type. The [transactional outbox](transactional-outbox.md) sends integration events and the
[inbox](inbox.md) receives them; neither redefines the contract.
