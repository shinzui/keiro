---
type: Term
title: subscription
description: "A consumer that follows a selected event history and processes events as they become available."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-34
status: current
tags:
  - read-side
related:
  - TERM-9
  - TERM-36
  - TERM-18
  - TERM-35
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# subscription

An [asynchronous projection](asynchronous-projection.md) can subscribe to all order streams through their [stream category](stream-category.md). An integration producer can follow events to populate the [outbox](transactional-outbox.md).

Durable subscriptions retain a [checkpoint](checkpoint.md) for recovery and must tolerate redelivery. The subscription machinery belongs to `mori://shinzui/kiroku`; Keiro declares its use in application contracts.

See [read models and projections](../user/read-models-and-projections.md) for details.
