---
type: Term
title: lifecycle state
description: "A lifecycle state is the named stage of an aggregate that determines which transitions are available."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-30
status: current
tags:
  - modeling
aliases:
  - control state
related:
  - TERM-31
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-aggregates.md
---

# lifecycle state

A lifecycle state is the named stage of an aggregate that determines which transitions are available.

Order stages can include awaiting payment, paid, and shipped. A payment total or customer identifier belongs in a [register](register.md).

The model from `mori://shinzui/keiki` separates lifecycle state from register values. Together they form the reconstructed aggregate state.

See [Keiro DSL Aggregates](../user/keiro-dsl-aggregates.md).
