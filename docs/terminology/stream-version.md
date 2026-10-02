---
type: Term
title: stream version
description: "A stream version is an event position within one stream that identifies the history seen by a command."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-37
status: current
tags:
  - modeling
related:
  - TERM-1
  - TERM-38
anchors:
  - kind: doc
    resource: docs/user/command-cycle.md
---

# stream version

A stream version is an event position within one stream that identifies the history seen by a command.

A command appends against the version it read. If another writer changes the stream, optimistic concurrency detects a conflict. Keiro can retry with reconstructed state.

Stream versions belong to `mori://shinzui/kiroku`. A [global position](global-position.md) identifies progress across streams.

See [command cycle](../user/command-cycle.md).
