---
type: Term
title: work queue
description: "A durable queue of jobs for background processing by a service."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

Use a work queue for work such as rendering a thumbnail or sending a reminder. Keiro's queue support delivers [jobs](job.md) at least once, so handlers must tolerate retries.

A work queue carries work owed by this service; an [outbox](transactional-outbox.md) carries integration messages for publication. Keiro's queue enqueue is not atomic with an event append, so applications must account for a crash between those operations.

See [work queues](../user/work-queues.md) for details.
