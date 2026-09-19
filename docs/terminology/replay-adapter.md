---
type: Term
title: replay adapter
description: "Projection logic specifically intended to process historical events safely during a rebuild."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-44
status: current
tags:
  - read-side
related:
  - TERM-43
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# replay adapter

A live handler might update a table and send a notification. Its replay adapter reconstructs the table without resending the notification for every historical event.

A projection can declare a replay adapter or declare itself live-only. That capability is independent of the target's clear-or-preserve policy. See [projection rebuild](projection-rebuild.md).

See [read models and projections](../user/read-models-and-projections.md) for details.
