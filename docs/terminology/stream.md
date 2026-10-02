---
type: Term
title: stream
description: "A stream is an ordered, append-only history of events for one aggregate instance or other entity."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-1
status: current
tags:
  - modeling
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

A stream is an ordered, append-only history of events for one aggregate instance or other entity.

An order stream can contain `OrderPlaced`, `PaymentReceived`, and `OrderShipped`. Replay of these events reconstructs the order state.

Each command targets one stream. Typed handles distinguish order streams from invoice streams. An [event stream](event-stream.md) defines the aggregate contract that handles commands and replays this history.

See [Core Concepts](../user/core-concepts.md#stream).
