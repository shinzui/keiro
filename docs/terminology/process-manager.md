---
type: Term
title: process manager
description: An event-sourced coordinator that reacts to source events, advances its own state stream, emits commands to target streams, and schedules timers, computing its targets purely from its own state.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-10
status: current
related:
  - TERM-11
  - TERM-12
anchors:
  - kind: module
    resource: Keiro.ProcessManager
  - kind: module
    resource: Keiro.ProcessManager.Reaction
    note: The reaction runner, keyed by target stream and occurrence.
  - kind: doc
    resource: docs/user/process-managers-and-timers.md
---

# process manager

Keiro derives each emitted command's id deterministically, so repeated delivery of a source
event is idempotent. When targets must be found effectfully, for example by querying a read
model, use a [router](router.md) instead. A process manager gives time meaning through
[timers](timer.md).
