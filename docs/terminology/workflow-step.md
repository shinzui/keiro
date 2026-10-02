---
type: Term
title: workflow step
description: "A workflow step is a named action whose saved result is reused when workflow execution resumes."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A workflow step is a named action whose saved result is reused when workflow execution resumes.

A stock-reservation step can save its reservation identifier in the [journal](journal.md). The workflow reuses the result after durable completion.

If the action succeeds before result storage, the step can run again. Make the action [idempotent](idempotency.md). Treat step names and saved result formats as durable contracts.

See [durable workflows](../user/durable-workflows.md).
