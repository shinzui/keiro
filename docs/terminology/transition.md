---
type: Term
title: transition
description: "A rule describing how an aggregate handles a command from a particular lifecycle state, including conditions, updates, events, and the next state."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-32
status: current
tags:
  - modeling
related:
  - TERM-33
  - TERM-54
anchors:
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
---

# transition

A transition might accept a payment when an order is awaiting payment, update its paid amount, emit `PaymentReceived`, and move to paid. A [guard](guard.md) determines whether that transition applies.

Keiro uses the transition model from `mori://shinzui/keiki` for both command handling and replay. A [replay-only transition](replay-only-transition.md) preserves historical behavior without accepting new commands.

See [typed spec toolchain](../user/typed-spec-toolchain.md) for details.
