---
type: Term
title: projection
description: "A handler that folds events into one or more read-model tables, owned by exactly one projection definition in the application's projection catalog."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-7
status: current
related:
  - TERM-6
anchors:
  - kind: module
    resource: Keiro.Projection
  - kind: module
    resource: Keiro.Projection.Catalog
    note: Declares the whole read-side inventory once.
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# projection

A projection only reflects what the write side already recorded; it never decides. Keiro has
two delivery modes, the [inline projection](inline-projection.md) and the
[asynchronous projection](asynchronous-projection.md). Each handler also declares whether it
has a safe replay path, which is separate from what a rebuild does to its tables.
