---
type: Term
title: inbox
description: "An inbox tracks received messages so duplicate delivery does not repeat committed handler effects."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

An inbox tracks received messages so duplicate delivery does not repeat committed handler effects.

An integration event can arrive again after a retry or outbox publication. The inbox uses a deduplication key to recognize a previously processed message.

In the transactional inbox, the receipt and handler database changes commit or roll back together. A rolled-back attempt can run again. A retained committed receipt prevents repetition of those changes. This guarantee does not cover arbitrary external effects.

See [Idempotent Inbox](../user/inbox.md).
