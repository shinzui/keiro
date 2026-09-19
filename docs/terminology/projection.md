---
type: Term
title: projection
description: Logic that turns recorded events into a read model by updating it as events are processed.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-7
status: current
tags:
  - read-side
related:
  - TERM-6
anchors:
  - kind: module
    resource: Keiro.Projection
  - kind: module
    resource: Keiro.Projection.Catalog
    note: Declares the whole read-side inventory once.
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# projection

A projection might handle `PaymentReceived` by updating the paid amount in an order
summary. It derives a [read model](read-model.md) from facts already recorded by the
write side; aggregate command handling owns business decisions.

An [inline projection](inline-projection.md) updates in the event append transaction.
An [asynchronous projection](asynchronous-projection.md) processes events after they commit.
Keiro records projection definitions in a [projection catalog](projection-catalog.md), including the tables each owns and
whether its handlers support safe replay. See
[Choosing a Projection](../guides/choosing-a-projection.md) for the tradeoffs.
