---
type: Term
title: continue-as-new
description: "Continue-as-new is a workflow operation that starts a new journal generation with explicitly selected state."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-59
status: current
tags:
  - durable-workflows
aliases:
  - workflow rotation
related:
  - TERM-14
  - TERM-15
anchors:
  - kind: doc
    resource: docs/user/durable-workflows.md
---

# continue-as-new

Continue-as-new is a workflow operation that starts a new journal generation with explicitly selected state.

A recurring workflow can otherwise accumulate an unbounded [journal](journal.md). The operation closes the current generation and passes a seed to the next. Each generation has bounded history.

The new generation restores the seed without replay of prior steps. Its awakeables receive new identifiers. Pass these identifiers to external participants.

See [durable workflows](../user/durable-workflows.md).
