---
type: Term
title: transactional outbox
description: A durable handoff that records each outgoing integration event in the same transaction as its source checkpoint, then publishes it at least once from a separate worker.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-18
status: current
aliases:
  - outbox
related:
  - TERM-17
  - TERM-19
anchors:
  - kind: module
    resource: Keiro.Outbox
  - kind: doc
    resource: docs/user/outbox.md
---

# transactional outbox

The outbox closes both failure windows of inline publishing: committing a domain event and
crashing before the publish, and publishing before the domain event commits. Because
publication is at-least-once, the receiving [inbox](inbox.md) deduplicates.
