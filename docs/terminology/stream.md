---
type: Term
title: stream
description: An ordered, append-only sequence of events recording the history of one aggregate instance or other entity.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-1
status: current
tags:
  - modeling
related:
  - TERM-2
  - TERM-4
anchors:
  - kind: module
    resource: Keiro.Stream
  - kind: type
    resource: Keiro.Stream.Stream
  - kind: doc
    resource: docs/user/core-concepts.md
    note: The Stream section.
---

# stream

A stream holds one entity's history. For example, an order's stream might contain
`OrderPlaced`, `PaymentReceived`, and `OrderShipped`. Replaying those events reconstructs
the order's current state.

Each command targets one stream. Keiro uses typed stream handles so application code can
distinguish an order stream from an invoice stream. A stream is the stored
history; an [event stream](event-stream.md) is Keiro's contract for handling commands and
replaying history for that kind of aggregate.

See [Core Concepts](../user/core-concepts.md#stream) for the Haskell representation.
