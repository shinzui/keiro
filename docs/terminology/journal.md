---
type: Term
title: journal
description: "The event stream of one durable workflow instance, recording each completed named step and the workflow's terminal or rotation marker so a resumed run can replay them."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-14
status: current
scope: durable workflows
related:
  - TERM-13
anchors:
  - kind: module
    resource: Keiro.Workflow.Journal
  - kind: doc
    resource: docs/user/durable-workflows.md
    note: The Journal stream and tables section.
---

# journal

Each instance journals to `wf:<name>-<id>`, and a rotated generation `g` to
`wf:<name>-<id>#<g>`. Suspension primitives record their completions as ordinary step records
under reserved prefixes (`sleep:`, `awkid:`, `awk:`, `child:`) rather than as new event types.
