---
type: Term
title: stream version
description: "The position of an event within one stream, used to identify the history seen by a command."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

A command reads a stream at a known version and appends against that expected version. If another writer changes the stream first, optimistic concurrency detects the conflict and Keiro may retry with fresh state.

Stream versions are store concepts owned by `mori://shinzui/kiroku`. They are local to a [stream](stream.md); a [global position](global-position.md) identifies progress across the store.

See [command cycle](../user/command-cycle.md) for details.
