---
type: Term
title: workflow step
description: "A named action in a durable workflow whose result is saved and reused when execution resumes."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-57
status: current
tags:
  - durable-workflows
aliases:
  - named step
related:
  - TERM-14
  - TERM-64
anchors:
  - kind: doc
    resource: docs/user/durable-workflows.md
---

# workflow step

A reserve-stock step might save the reservation identifier in the [journal](journal.md). On resumption, the workflow reuses that result once its completion is durable.

If the external action succeeds but saving its result fails, the step may run again. Make the action [idempotent](idempotency.md), and treat step names and saved result formats as durable contracts.

See [durable workflows](../user/durable-workflows.md) for details.
