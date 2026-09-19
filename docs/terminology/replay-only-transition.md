---
type: Term
title: replay-only transition
description: "An aggregate transition retained to reconstruct historical events without allowing new commands to select that behavior."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-54
status: current
tags:
  - replay
related:
  - TERM-63
anchors:
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
---

# replay-only transition

Suppose an older rule emitted an event that new orders must no longer produce. Removing that rule entirely can make old streams unreadable. A replay-only transition preserves the historical interpretation while retiring the live behavior.

It must still emit the historical evidence needed for replay. Decoding an old payload through an [upcaster](upcaster.md) is a different responsibility from retaining the behavior that interprets it.

See [typed spec toolchain](../user/typed-spec-toolchain.md) for details.
