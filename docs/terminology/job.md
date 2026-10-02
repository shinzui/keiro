---
type: Term
title: job
description: "A job is a declared kind of background work with a queue, payload format, ordering contract, and retry policy."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-46
status: current
tags:
  - work-queues
related:
  - TERM-45
  - TERM-16
anchors:
  - kind: doc
    resource: docs/user/work-queues.md
---

# job

A job is a declared kind of background work with a queue, payload format, ordering contract, and retry policy.

A thumbnail job defines how requests are queued and handled. Each request supplies an image identifier and desired size. The handler reports completion, retry, or dead-letter disposition.

The [work queue](work-queue.md) processes the job. A job payload requests work; it is not automatically an authoritative domain event.

See [work queues](../user/work-queues.md).
