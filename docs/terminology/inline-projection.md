---
type: Term
title: inline projection
description: A projection that updates its read model in the same transaction that saves the command's events.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

The events and the read-model update commit together. If the projection fails, the event
append rolls back too. For example, a successful payment command can make both
`PaymentReceived` and the updated order balance visible at the same commit.

This provides immediate consistency for that update, but projection work adds to command
latency. Use an [asynchronous projection](asynchronous-projection.md) when the view can
catch up after the command completes. See [Inline Projections](../guides/inline-projections.md)
for setup.
