---
type: Term
title: replay adapter
description: "A replay adapter is projection logic that safely processes historical events during a rebuild."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A replay adapter is projection logic that safely processes historical events during a rebuild.

A live handler can update a table and send a notification. Its replay adapter reconstructs the table without sending historical notifications again.

A projection can declare a replay adapter or remain live-only. This capability is separate from the target's clear-or-preserve policy.

See [read models and projections](../user/read-models-and-projections.md).
