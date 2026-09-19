---
type: Term
title: durable workflow
description: A long-running process written as a sequence of steps and waits whose progress is saved so it can resume after interruptions.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

A durable workflow can reserve stock, wait for payment confirmation, then arrange shipment,
even if those steps span restarts or long idle periods. It saves named step results in a
[journal](journal.md), and can wait on a [timer](timer.md), an
[awakeable](awakeable.md), or a child workflow.

On resumption, Keiro runs the function from the beginning and returns recorded results for
completed steps. A step can run again if its external effect succeeded before its result
was saved, so step effects must be idempotent. A [process manager](process-manager.md)
expresses coordination as reactions to events; a workflow expresses it as sequential code.
See [Durable Workflows](../guides/durable-workflows.md) for an example.
