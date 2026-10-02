---
type: Term
title: hydration
description: "Hydration is reconstruction of aggregate state from stored events, optionally using a compatible snapshot."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-62
status: current
tags:
  - replay
related:
  - TERM-5
  - TERM-43
anchors:
  - kind: doc
    resource: docs/user/command-cycle.md
---

# hydration

Hydration is reconstruction of aggregate state from stored events, optionally using a compatible snapshot.

Before a command decision, Keiro reads history, upcasts and decodes events, and replays them through the aggregate model. A snapshot can reduce required replay.

Hydration fails if required events cannot be decoded or interpreted. Skipping an event can produce an unsafe decision. A [projection rebuild](projection-rebuild.md) reconstructs query data.

See [command cycle](../user/command-cycle.md).
