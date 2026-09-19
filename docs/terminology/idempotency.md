---
type: Term
title: idempotency
description: "The property that repeating an operation does not repeat its intended effect."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

For example, delivering the same payment notification twice must not credit the order twice. Stable identities and durable receipts can make retries safe.

Keiro uses different mechanisms at different boundaries: [inbox](inbox.md) receipts, command event identities, and projection deduplication. Workflow effects and queue handlers still need their own appropriate protection. Each guarantee has a scope and retention window; none implies that arbitrary external actions execute exactly once.

See [inbox](../user/inbox.md) for details.
