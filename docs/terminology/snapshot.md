---
type: Term
title: snapshot
description: A saved copy of an aggregate's state at a known stream version, used to rebuild current state without replaying its entire history.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

A snapshot lets Keiro start with previously reconstructed state and replay only the events
that followed it. For example, a snapshot at event 1,000 means the next reconstruction can
start with event 1,001.

The event history remains authoritative. If a snapshot is unavailable, incompatible with
the current model, or cannot be read, Keiro falls back to replaying the full history.
See [Snapshots](../user/snapshots.md) for compatibility checks and configuration.
