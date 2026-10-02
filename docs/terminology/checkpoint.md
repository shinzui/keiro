---
type: Term
title: checkpoint
description: "A checkpoint is a durable record of subscription progress through an event source."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-35
status: current
tags:
  - read-side
aliases:
  - subscription checkpoint
related:
  - TERM-14
  - TERM-5
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# checkpoint

A checkpoint is a durable record of subscription progress through an event source.

After restart, the subscription resumes from its checkpoint. A missing-checkpoint policy can start at the beginning, start at the current head, or report an error. It does not move an existing checkpoint.

Subscription checkpoints belong to `mori://shinzui/kiroku`. Workflow step results belong to a [journal](journal.md). Aggregate cached state belongs to a [snapshot](snapshot.md).

See [read models and projections](../user/read-models-and-projections.md).
