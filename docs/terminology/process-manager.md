---
type: Term
title: process manager
description: "A process manager is an event-sourced coordinator that reacts to events with commands or timers."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A process manager is an event-sourced coordinator that reacts to events with commands or timers.

An order process can remember payment, request shipment, and set a shipping deadline. Its incoming event and recorded state determine the next actions.

Keiro gives emitted commands stable identities for duplicate handling. Use a [router](router.md) for recipient lookup through queries. Use a [durable workflow](durable-workflow.md) for sequential steps and waits.

See [Process Managers and Timers](../user/process-managers-and-timers.md).
