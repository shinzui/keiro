---
type: Term
title: timer
description: "A durable scheduled wakeup stored in `keiro_timers`, claimed by a timer worker when due and fired at least once into application code."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-12
status: current
related:
  - TERM-10
  - TERM-13
anchors:
  - kind: module
    resource: Keiro.Timer
  - kind: doc
    resource: docs/user/process-managers-and-timers.md
---

# timer

Timers are a low-level scheduling primitive: the [process manager](process-manager.md) or
[durable workflow](durable-workflow.md) that arms a timer decides what firing means. A worker
claims one due timer with `FOR UPDATE SKIP LOCKED`, so several workers can run safely.
