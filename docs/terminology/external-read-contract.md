---
type: Term
title: external read contract
description: "A versioned query interface that lets another process read a projection without depending on its private tables."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-53
status: current
tags:
  - read-side
related:
  - TERM-50
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# external read contract

Keiro publishes these contracts as guarded PostgreSQL functions. The contract defines input and result shapes and which [projection revisions](projection-revision.md) it supports.

A compatible contract can follow a promoted generation. A breaking input or result change requires a new contract version and consumer migration. The application still owns access grants and the meaning of its query SQL.

See [read models and projections](../user/read-models-and-projections.md) for details.
