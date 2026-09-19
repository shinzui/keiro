---
type: Term
title: awakeable
description: A durable wait for an external result, allowing a workflow to pause until another part of the system signals or cancels it.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-15
status: current
tags:
  - durable-workflows
scope: durable workflows
related:
  - TERM-13
  - TERM-14
anchors:
  - kind: module
    resource: Keiro.Workflow.Awakeable
  - kind: doc
    resource: docs/user/durable-workflows.md
---

# awakeable

An awakeable connects a [durable workflow](durable-workflow.md) to a callback, such as a
payment notification or a human approval. Keiro gives the wait an identifier that the
external participant uses to supply the result. The wait survives application restarts.

Pass the allocated identifier to that participant before the workflow starts waiting.
Keiro saves it in the journal; callers must use the returned identifier rather than try
to derive one themselves. See [Durable Workflows](../user/durable-workflows.md) for the API.
