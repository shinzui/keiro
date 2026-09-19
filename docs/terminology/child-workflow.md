---
type: Term
title: child workflow
description: "A separately identified durable workflow started by another workflow, which can wait for its completion."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-58
status: current
tags:
  - durable-workflows
anchors:
  - kind: doc
    resource: docs/user/durable-workflows.md
---

# child workflow

An order workflow might start a shipment workflow and wait for its result. The parent journals the child handle so resumption can recover that relationship.

Give the child its own workflow identity, distinct from the parent's. Parent and child retain separate execution histories; waiting for the child is itself durable.

See [durable workflows](../user/durable-workflows.md) for details.
