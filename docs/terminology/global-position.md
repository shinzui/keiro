---
type: Term
title: global position
description: "A store-wide event position used to order events across streams and track consumer progress."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-38
status: current
tags:
  - modeling
related:
  - TERM-37
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# global position

A projection consuming many streams uses global positions to track how far it has progressed. A caller can use a command's returned position to wait until the supplying projection has caught up before querying.

Positions come from `mori://shinzui/kiroku`. Treat them as store-issued cursors, not timestamps or gap-free counts. A [stream version](stream-version.md) instead describes one stream's history.

See [read models and projections](../user/read-models-and-projections.md) for details.
