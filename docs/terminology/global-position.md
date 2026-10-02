---
type: Term
title: global position
description: "A global position is a store-wide event cursor for ordering events across streams and tracking consumer progress."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A global position is a store-wide event cursor for ordering events across streams and tracking consumer progress.

A projection uses global positions to track progress across streams. A caller can wait for the command's returned position before a query.

Positions belong to `mori://shinzui/kiroku`. Treat them as store-issued cursors. They are not timestamps or counts that guarantee no gaps. A [stream version](stream-version.md) describes one stream's history.

See [read models and projections](../user/read-models-and-projections.md).
