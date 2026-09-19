---
type: Term
title: asynchronous projection
description: A projection driven by a subscription after the append commits, delivered at least once, so its write handlers must be idempotent.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-9
status: current
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

The usual idempotence technique is to store the source event id and write with
`INSERT ... ON CONFLICT DO NOTHING`. Each asynchronous subscription declares
`checkpointOnMissing`, the policy used when its durable checkpoint row does not exist.
