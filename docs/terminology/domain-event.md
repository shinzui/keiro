---
type: Term
title: domain event
description: "A domain event is a recorded business fact owned by a bounded context's internal model."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A domain event is a recorded business fact owned by a bounded context's internal model.

Replay of domain events reconstructs aggregate state. The owning context can change the event format if its [codec](codec.md) can still read stored history.

Other contexts consume published [integration events](integration-event.md). This boundary lets the internal format change without a direct consumer dependency.
