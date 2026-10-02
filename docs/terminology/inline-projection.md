---
type: Term
title: inline projection
description: "An inline projection updates its read model within the transaction that appends a command's events."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-8
status: current
tags:
  - read-side
scope: read side
broader:
  - TERM-7
related:
  - TERM-4
anchors:
  - kind: type
    resource: Keiro.Projection.Types.InlineProjection
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# inline projection

An inline projection updates its read model within the transaction that appends a command's events.

The events and the update commit together. A projection failure rolls back the append. A payment command can expose `PaymentReceived` and the new balance at the same commit.

Projection work adds to command latency. Use an [asynchronous projection](asynchronous-projection.md) when the view can update after command completion.

See [Inline Projections](../guides/inline-projections.md).
