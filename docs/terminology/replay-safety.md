---
type: Term
title: replay safety
description: "Replay safety is the property that recorded events can reconstruct the durable state produced by command handling."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

Replay safety is the property that recorded events can reconstruct the durable state produced by command handling.

If a command stores a customer identifier, its events must preserve enough information to recover that identifier. Keiro validates the aggregate model before command execution.

Validation checks the current model in isolation. Use a [replay audit](replay-audit.md) to check changed behavior against actual stored histories.

See [replay safety](../user/replay-safety.md).
