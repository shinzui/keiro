---
type: Term
title: awakeable
description: "An awakeable is a durable workflow wait for an external result or cancellation."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

An awakeable is a durable workflow wait for an external result or cancellation.

An awakeable can wait for a payment callback or human approval. Keiro allocates an identifier for the participant that supplies the result. The wait survives application restarts.

Pass the allocated identifier to that participant before the workflow waits. Keiro saves the identifier in the [journal](journal.md). Use the returned identifier; do not calculate one independently.

See [Durable Workflows](../user/durable-workflows.md).
