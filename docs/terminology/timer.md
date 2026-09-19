---
type: Term
title: timer
description: A scheduled wakeup that survives application restarts and lets a process react when a deadline is due.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-12
status: current
tags:
  - coordination
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

A timer can wake a [process manager](process-manager.md) to check an unpaid order or
resume a sleeping [durable workflow](durable-workflow.md). The application decides what
the wakeup means; the timer supplies durable scheduling.

A worker processes timers when they are due, so a deadline does not promise execution at
an exact instant. Delivery is at least once; the action taken on wakeup must tolerate
duplicates. See [Process Managers and Timers](../user/process-managers-and-timers.md).
