---
type: Term
title: transition
description: "A transition is an aggregate rule that defines conditions, updates, emitted events, and the next lifecycle state for a command."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-32
status: current
tags:
  - modeling
related:
  - TERM-33
  - TERM-54
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-aggregates.md
---

# transition

A transition is an aggregate rule that defines conditions, updates, emitted events, and the next lifecycle state for a command.

A payment transition can update the paid amount, emit `PaymentReceived`, and move the order to paid. A [guard](guard.md) determines whether the transition applies.

Keiro uses the transition model from `mori://shinzui/keiki` for commands and replay. A [replay-only transition](replay-only-transition.md) retains historical behavior without accepting new commands.

See [Keiro DSL Aggregates](../user/keiro-dsl-aggregates.md).
