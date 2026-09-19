---
type: Term
title: snapshot
description: "An advisory persisted `(state, registers)` seed for one stream at a known version, from which hydration replays only the tail of the stream."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-5
status: current
related:
  - TERM-4
  - TERM-2
anchors:
  - kind: module
    resource: Keiro.Snapshot
  - kind: doc
    resource: docs/user/snapshots.md
---

# snapshot

Snapshots are acceleration, never correctness: a snapshot is loaded only when its version and
shape hashes match the current state codec, and any snapshot failure falls back to full replay.
