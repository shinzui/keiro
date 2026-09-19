---
type: Term
title: rebuild group
description: "A set of projection targets that must move through rebuilding and return to service together."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

An order summary and its totals may need one rebuild group so queries never see one rebuilt table paired with an incompatible old table. The group also declares target dependency order.

An offline rebuild makes the selected group unavailable while it is reconstructed and verified. Other independent groups can continue operating. See [projection rebuild](projection-rebuild.md).

See [read models and projections](../user/read-models-and-projections.md) for details.
