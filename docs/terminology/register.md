---
type: Term
title: register
description: "A register is a named, typed value that an aggregate retains alongside its lifecycle state."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-31
status: current
tags:
  - modeling
related:
  - TERM-30
  - TERM-5
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-aggregates.md
---

# register

A register is a named, typed value that an aggregate retains alongside its lifecycle state.

An order in the paid state can retain its customer identifier and total in registers. Events must contain enough information to recover register changes.

Register operations belong to `mori://shinzui/keiki`. Keiro stores their evidence in events and can cache their values in [snapshots](snapshot.md).

See [Keiro DSL Aggregates](../user/keiro-dsl-aggregates.md).
