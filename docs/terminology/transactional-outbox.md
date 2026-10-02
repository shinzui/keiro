---
type: Term
title: transactional outbox
description: "A transactional outbox is durable message storage whose enqueue commits atomically with its associated database changes."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-18
status: current
tags:
  - integration
aliases:
  - outbox
related:
  - TERM-17
  - TERM-19
anchors:
  - kind: module
    resource: Keiro.Outbox
  - kind: doc
    resource: docs/user/outbox.md
---

# transactional outbox

A transactional outbox is durable message storage whose enqueue commits atomically with its associated database changes.

A worker sends each saved [integration event](integration-event.md) and records the outcome. Publication can resume after a crash.

In Keiro's standard pipeline, a subscription maps committed domain events to outgoing messages. Message storage and checkpoint advancement commit together. This transaction follows the domain-event commit. Direct transactional enqueue is also available.

Publication is at least once. A crash after sending can cause redelivery before success is recorded. The receiving [inbox](inbox.md) deduplicates messages.

See [Durable Outbox](../user/outbox.md).
