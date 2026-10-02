---
type: Term
title: subscription
description: "A subscription is a consumer that follows selected event history and processes available events."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A subscription is a consumer that follows selected event history and processes available events.

An asynchronous projection can follow all order streams through their [stream category](stream-category.md). An integration producer can follow events to populate the [outbox](transactional-outbox.md).

Durable subscriptions retain a [checkpoint](checkpoint.md) for recovery. They must tolerate redelivery. Subscription machinery belongs to `mori://shinzui/kiroku`.

See [read models and projections](../user/read-models-and-projections.md).
