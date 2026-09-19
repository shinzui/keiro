---
type: Term
title: query freshness
description: "The waiting policy applied before a read-model query runs, determining which projection progress it requires."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-39
status: current
tags:
  - read-side
related:
  - TERM-38
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# query freshness

Keiro offers three choices: query immediately without waiting, wait for a captured event-log head, or wait for a caller-supplied [global position](global-position.md).

Immediate does not mean up to date: an asynchronous projection may still lag. Waiting requires a durable cursor for the projection supplying the query. Delivery mode controls when updates run; freshness controls what the query waits for.

See [read models and projections](../user/read-models-and-projections.md) for details.
