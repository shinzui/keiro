---
type: Term
title: physical target
description: "A physical target is an application-owned database table that a projection maintains."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-41
status: current
tags:
  - read-side
aliases:
  - projection target
related:
  - TERM-7
  - TERM-44
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# physical target

A physical target is an application-owned database table that a projection maintains.

An order summary and order totals can be two targets with one projection owner. Several read models can query subsets of those targets.

Each target declares a rebuild preparation policy. Reconstruction can clear the target; reconciliation can preserve its data. This policy is separate from replay-adapter capability.

See [read models and projections](../user/read-models-and-projections.md).
