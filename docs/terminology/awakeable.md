---
type: Term
title: awakeable
description: A durable wait inside a durable workflow, identified by an opaque random id that an external system uses to signal a result or cancel the wait.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-15
status: current
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

The workflow journals the allocated id before awaiting, so hand that id to the external system
first; it cannot be recomputed from workflow coordinates.
