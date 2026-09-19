---
type: Term
title: domain event
description: A recorded business fact that belongs to a bounded context's internal model, such as an order being placed or a payment being received.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-16
status: current
tags:
  - modeling
related:
  - TERM-17
  - TERM-1
anchors:
  - kind: doc
    resource: docs/user/integration-events.md
---

# domain event

A domain event records something that happened, and replaying these facts reconstructs
an aggregate's state. Its representation belongs to the context that owns the model.

That context can evolve the event format, provided it can still read its stored history
through its [codec](codec.md). Other contexts consume an explicitly published
[integration event](integration-event.md), so they do not depend on the internal format.
