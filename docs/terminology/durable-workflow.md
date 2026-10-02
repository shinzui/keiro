---
type: Term
title: durable workflow
description: "A durable workflow is sequential code whose saved progress lets steps and waits resume after interruptions."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-13
status: current
tags:
  - durable-workflows
related:
  - TERM-14
  - TERM-15
  - TERM-12
anchors:
  - kind: module
    resource: Keiro.Workflow
  - kind: doc
    resource: docs/user/durable-workflows.md
  - kind: doc
    resource: docs/guides/durable-workflows.md
---

# durable workflow

A durable workflow is sequential code whose saved progress lets steps and waits resume after interruptions.

A workflow can reserve stock, wait for payment, and arrange shipment across application restarts. It saves named step results in a [journal](journal.md). It can wait for a [timer](timer.md), an [awakeable](awakeable.md), or a [child workflow](child-workflow.md).

On resumption, Keiro starts the function again and returns saved results for completed steps. An effect can succeed before its result is saved. The step can then run again, so effects must be [idempotent](idempotency.md).

See [Durable Workflows](../guides/durable-workflows.md).
