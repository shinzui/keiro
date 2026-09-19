---
type: Term
title: inbox
description: "The receiving side of integration delivery, which runs a local handler at most once per integration event by recording a deduplication key in the handler's own transaction."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-19
status: current
aliases:
  - idempotent inbox
related:
  - TERM-17
  - TERM-18
anchors:
  - kind: module
    resource: Keiro.Inbox
  - kind: doc
    resource: docs/user/inbox.md
---

# inbox

Redelivery is normal, from consumer crashes, rebalances, retries, or an
[outbox](transactional-outbox.md) republish. The inbox row and the handler's effects commit or
roll back together, so there is no window between accepting a message and applying it.
