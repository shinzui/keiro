---
type: Term
title: idempotency
description: "Idempotency is the property that repetition of an operation does not repeat its intended effect."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-64
status: current
tags:
  - integration
aliases:
  - idempotence
related:
  - TERM-19
anchors:
  - kind: doc
    resource: docs/user/inbox.md
---

# idempotency

Idempotency is the property that repetition of an operation does not repeat its intended effect.

Duplicate payment notification must not credit an order twice. Stable identities and durable receipts can protect retries.

Keiro uses inbox receipts, command event identities, and projection deduplication at different boundaries. Workflow effects and queue handlers need appropriate protection. Each guarantee has a scope and retention window. No guarantee implies exactly-once execution of arbitrary external effects.

See [inbox](../user/inbox.md).
