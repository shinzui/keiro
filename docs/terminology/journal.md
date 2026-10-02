---
type: Term
title: journal
description: "A journal is the durable execution history that recovers workflow progress and supplies saved step results."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A journal is the durable execution history that recovers workflow progress and supplies saved step results.

The journal records completed steps, their results, and workflow completion. A saved stock-reservation result lets a resumed workflow reuse the reservation.

The journal uses a stored [stream](stream.md). It records execution progress. Aggregate history records domain facts.

See [Durable Workflows](../user/durable-workflows.md).
