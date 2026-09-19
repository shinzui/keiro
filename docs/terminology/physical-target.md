---
type: Term
title: physical target
description: "An application-owned database table maintained by a projection and declared as a unit of read-side ownership."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

An order summary table and an order totals table can be two targets owned by one [projection](projection.md). Several query models may read different subsets of that owner's targets.

Each target declares how rebuilding prepares its data: clear it for reconstruction or preserve it for reconciliation. This reset policy is separate from whether a handler has a safe [replay adapter](replay-adapter.md).

See [read models and projections](../user/read-models-and-projections.md) for details.
