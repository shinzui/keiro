---
type: Term
title: process manager
description: An event-sourced coordinator that remembers the progress of a business process and reacts to events by sending commands or scheduling timers.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-10
status: current
tags:
  - coordination
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

A process manager coordinates work across aggregates while keeping its own event-sourced
state. For example, an order-fulfillment process can remember that payment arrived, request
shipment, and use a [timer](timer.md) to handle a shipping deadline.

Its next actions follow from the incoming event and its recorded state. Keiro gives emitted
commands stable identities so redelivery can be handled idempotently. Use a
[router](router.md) when finding command recipients requires a query; consider a
[durable workflow](durable-workflow.md) when the process is easier to express as a sequence
of steps and waits. See [Process Managers and Timers](../user/process-managers-and-timers.md).
