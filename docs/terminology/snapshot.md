---
type: Term
title: snapshot
description: "A snapshot is aggregate state saved at a known stream version to reduce the events needed for reconstruction."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-5
status: current
tags:
  - replay
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

A snapshot is aggregate state saved at a known stream version to reduce the events needed for reconstruction.

A snapshot at event 1,000 lets reconstruction start with event 1,001. Event history remains authoritative.

Keiro replays the full history if the snapshot is unavailable, incompatible, or unreadable.

See [Snapshots](../user/snapshots.md).
