---
type: Term
title: projection
description: "A projection is logic that updates a read model from recorded events."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A projection is logic that updates a read model from recorded events.

For `PaymentReceived`, a projection can update the paid amount in an order summary. Aggregate command handling owns business decisions.

An [inline projection](inline-projection.md) updates within the event append transaction. An [asynchronous projection](asynchronous-projection.md) processes events after commit. The [projection catalog](projection-catalog.md) declares target ownership and replay capability.

See [Choosing a Projection](../guides/choosing-a-projection.md).
