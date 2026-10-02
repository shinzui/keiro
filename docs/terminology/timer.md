---
type: Term
title: timer
description: "A timer is a durable scheduled wakeup for a process or workflow."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A timer is a durable scheduled wakeup for a process or workflow.

A timer can wake a [process manager](process-manager.md) to check an unpaid order. It can also resume a sleeping [durable workflow](durable-workflow.md). The application defines the wakeup action.

A worker processes due timers. A deadline does not guarantee execution at an exact instant. Delivery is at least once, so the wakeup action must tolerate duplicates.

See [Process Managers and Timers](../user/process-managers-and-timers.md).
