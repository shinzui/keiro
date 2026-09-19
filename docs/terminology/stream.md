---
type: Term
title: stream
description: "An ordered, append-only sequence of events that records the history of one entity, addressed in Haskell by a typed `Stream a` handle over a Kiroku stream name."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-1
status: current
related:
  - TERM-2
  - TERM-4
anchors:
  - kind: module
    resource: Keiro.Stream
  - kind: type
    resource: Keiro.Stream.Stream
  - kind: doc
    resource: docs/user/core-concepts.md
    note: The Stream section.
---

# stream

A stream is where one entity's history lives. Kiroku owns the storage, versions, and global
positions; keiro adds the `Stream a` handle, whose phantom `a` lets code tell an order stream
from an invoice stream even though the stored name is plain text.

Every command appends to exactly one stream, and the [event stream](event-stream.md) contract
decides which stream a command targets.
