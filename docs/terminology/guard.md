---
type: Term
title: guard
description: "A guard is a condition that must hold before a transition can handle a command."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-33
status: current
tags:
  - modeling
related:
  - TERM-31
  - TERM-28
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-aggregates.md
---

# guard

A guard is a condition that must hold before a transition can handle a command.

A payment guard can require the command amount to equal the outstanding balance. Guards use the command and reconstructed state to select behavior.

Guards belong to `mori://shinzui/keiki`. Guard changes can affect historical replay and new decisions. Include them in replay-safety and evolution reviews.

See [Keiro DSL Aggregates](../user/keiro-dsl-aggregates.md).
