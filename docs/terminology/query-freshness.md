---
type: Term
title: query freshness
description: "Query freshness is the policy that determines required projection progress before a read-model query runs."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

Query freshness is the policy that determines required projection progress before a read-model query runs.

A query can run immediately, wait for a captured event-log head, or wait for a caller-supplied [global position](global-position.md). Immediate execution can return data that lags behind committed events.

Waiting requires a durable cursor for the supplying projection. Delivery mode controls update execution. Freshness controls query waiting.

See [read models and projections](../user/read-models-and-projections.md).
