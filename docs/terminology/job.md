---
type: Term
title: job
description: "A declared kind of background work, combining its queue, payload format, ordering contract, and retry policy."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

A thumbnail job describes how thumbnail requests are queued and handled; an individual request supplies the image identifier and desired size. Its handler reports whether processing completed, should retry, or should be dead-lettered.

A job is processed through a [work queue](work-queue.md). Its payload requests work; it is not automatically an authoritative [domain event](domain-event.md).

See [work queues](../user/work-queues.md) for details.
