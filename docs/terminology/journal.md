---
type: Term
title: journal
description: The durable execution history of one workflow instance, used to recover its progress and reuse recorded step results.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-14
status: current
tags:
  - durable-workflows
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

A journal records [durable workflow](durable-workflow.md) progress, including completed
steps, their results, and how the workflow ended. If a stock reservation step has a
recorded result, a resumed workflow can reuse that result instead of reserving stock again.

The journal is stored as an event stream, but its purpose is execution recovery. An
aggregate's domain history records business facts; the journal records how far the
workflow ran. See [Durable Workflows](../user/durable-workflows.md) for storage details.
