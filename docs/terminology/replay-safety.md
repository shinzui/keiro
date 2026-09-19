---
type: Term
title: replay safety
description: "The property that recorded events contain enough information to reconstruct the durable state produced by command handling."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-28
status: current
tags:
  - replay
aliases:
  - replayability
related:
  - TERM-4
  - TERM-56
anchors:
  - kind: doc
    resource: docs/user/replay-safety.md
---

# replay safety

If placing an order remembers a customer identifier, its events must preserve enough information to recover that identifier. Keiro validates the aggregate model before allowing it into the [command cycle](command-cycle.md).

Validation checks the current model in isolation. It does not establish that changed behavior still interprets old histories correctly; use a [replay audit](replay-audit.md) for evidence about actual stored streams.

See [replay safety](../user/replay-safety.md) for details.
