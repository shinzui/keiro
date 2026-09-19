---
type: Term
title: router
description: "A stateless dispatcher that resolves its command targets effectfully, for example from a read model, and reuses the process manager's dispatch with exactly-once-per-target idempotency."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-11
status: current
related:
  - TERM-10
anchors:
  - kind: module
    resource: Keiro.Router
  - kind: doc
    resource: docs/guides/routers-and-effectful-fan-out.md
---

# router

Choose a router over a [process manager](process-manager.md) when target resolution needs
effects rather than the manager's own state.
