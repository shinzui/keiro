---
type: Term
title: checkpoint
description: "A durable record of how far a subscription has progressed through its event source."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

After a restart, a subscription uses its checkpoint to resume processing. In Keiro's projection catalog, the missing-checkpoint policy chooses whether an absent checkpoint starts at the beginning, starts at the current head, or causes an error. It does not reposition an existing checkpoint.

Subscription checkpoints belong to `mori://shinzui/kiroku`. They track consumer progress; a workflow's saved step results belong to its [journal](journal.md), and an aggregate's cached state is a [snapshot](snapshot.md).

See [read models and projections](../user/read-models-and-projections.md) for details.
