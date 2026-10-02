---
type: Term
title: rebuild group
description: "A rebuild group is a set of projection targets that must be rebuilt and returned to service together."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-42
status: current
tags:
  - read-side
related:
  - TERM-43
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# rebuild group

A rebuild group is a set of projection targets that must be rebuilt and returned to service together.

An order summary and its totals can need one group to prevent incompatible table combinations. The group declares target dependency order.

An offline rebuild makes the selected group unavailable during reconstruction and verification. Independent groups can continue operating.

See [read models and projections](../user/read-models-and-projections.md).
