---
type: Term
title: asynchronous projection
description: A projection that processes committed events in the background, allowing its read model to catch up independently of command handling.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

An asynchronous projection follows the event log through a [subscription](subscription.md). Its [checkpoint](checkpoint.md)
records how far it has processed. A reporting dashboard, for example, can update shortly
after an order command succeeds instead of delaying the command for reporting work.

The read model is eventually consistent: it may temporarily lag behind the event log.
Delivery is at least once, so handlers must be idempotent: processing the same event again
must not apply its effect twice. See
[Asynchronous Projections](../guides/asynchronous-projections.md) for checkpoint policies
and safe update patterns.
