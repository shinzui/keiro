---
type: Term
title: asynchronous projection
description: "An asynchronous projection processes committed events independently of command handling."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-9
status: current
tags:
  - read-side
scope: read side
aliases:
  - async projection
broader:
  - TERM-7
anchors:
  - kind: type
    resource: Keiro.Projection.Types.AsyncProjection
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# asynchronous projection

An asynchronous projection processes committed events independently of command handling.

A [subscription](subscription.md) supplies events. Its [checkpoint](checkpoint.md) records progress. A reporting dashboard can update after an order command completes.

The read model can lag behind the event log. Delivery is at least once. Handlers must be [idempotent](idempotency.md) so duplicate delivery does not repeat an effect.

See [Asynchronous Projections](../guides/asynchronous-projections.md).
