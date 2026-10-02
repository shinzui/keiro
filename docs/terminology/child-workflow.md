---
type: Term
title: child workflow
description: "A child workflow is a separately identified durable workflow started by another workflow."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-58
status: current
tags:
  - durable-workflows
anchors:
  - kind: doc
    resource: docs/user/durable-workflows.md
---

# child workflow

A child workflow is a separately identified durable workflow started by another workflow.

An order workflow can start a shipment workflow and wait for its result. The parent journals the child handle for recovery.

Give the child its own workflow identity. Parent and child retain separate execution histories. The parent can durably wait for child completion.

See [durable workflows](../user/durable-workflows.md).
