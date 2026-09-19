---
type: Term
title: domain event
description: "A private fact recorded in one stream of one bounded context, free to change shape as that context's model evolves."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-16
status: current
related:
  - TERM-17
  - TERM-1
anchors:
  - kind: doc
    resource: docs/user/integration-events.md
---

# domain event

A domain event is internal. What another context may depend on is an
[integration event](integration-event.md), which is mapped from domain events and kept stable.
