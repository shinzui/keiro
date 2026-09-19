---
type: Term
title: hydration
description: "Reconstructing an aggregate's current state from its stored events, optionally starting from a compatible snapshot."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

Before deciding a command, Keiro reads history, upcasts and decodes events, and replays them through the aggregate model. A [snapshot](snapshot.md) can provide a starting point so only later events need replay.

Hydration fails if required history cannot be decoded or interpreted; skipping a bad event could produce an unsafe decision. It rebuilds command-side state, whereas a [projection rebuild](projection-rebuild.md) reconstructs derived query data.

See [command cycle](../user/command-cycle.md) for details.
