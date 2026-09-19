---
type: Term
title: inbox
description: A receiving-side mechanism that tracks processed messages so duplicate deliveries do not repeat their committed effects.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-19
status: current
tags:
  - integration
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

An [integration event](integration-event.md) may arrive more than once after a retry or
an [outbox](transactional-outbox.md) republish. The inbox recognizes previously processed
messages by a deduplication key.

In Keiro's transactional inbox, the receipt and the handler's database changes commit or
roll back together. A rolled-back attempt can run again; a committed receipt prevents
the same changes from being applied again while that receipt is retained. This guarantee
does not cover arbitrary external effects. See [Idempotent Inbox](../user/inbox.md) for
deduplication policies, retention, and delegated handling.
