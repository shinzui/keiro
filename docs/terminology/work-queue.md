---
type: Term
title: work queue
description: "A work queue is a durable queue of jobs for background processing by a service."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-45
status: current
tags:
  - work-queues
related:
  - TERM-46
  - TERM-18
anchors:
  - kind: doc
    resource: docs/user/work-queues.md
---

# work queue

A work queue is a durable queue of jobs for background processing by a service.

A queue can hold thumbnail or reminder jobs. Delivery is at least once, so handlers must tolerate retries.

The queue carries work for this service. The [outbox](transactional-outbox.md) carries integration messages for publication. Queue enqueue is not atomic with event append. Account for a crash between these operations.

See [work queues](../user/work-queues.md).
