---
type: Term
title: event stream
description: "An event stream is Keiro's aggregate contract for command handling, event production, and state reconstruction."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-2
status: current
tags:
  - modeling
aliases:
  - aggregate contract
discouraged:
  - decider
  - decider facade
related:
  - TERM-1
  - TERM-3
  - TERM-4
  - TERM-5
anchors:
  - kind: module
    resource: Keiro.EventStream
  - kind: type
    resource: Keiro.EventStream.EventStream
  - kind: doc
    resource: docs/user/core-concepts.md
    note: The EventStream section.
  - kind: doc
    resource: docs/why-keiro.md
    note: Why the contract is a SymTransducer rather than a Decider.
---

# event stream

An event stream is Keiro's aggregate contract for command handling, event production, and state reconstruction.

One order contract defines the commands and events for all order instances. Each order instance has its own stored [stream](stream.md).

The contract supplies the initial state, [codec](codec.md), stream names, and [snapshot](snapshot.md) policy. The [command cycle](command-cycle.md) uses these definitions.

Keiro uses a [symbolic transducer](symbolic-transducer.md) from `mori://shinzui/keiki` for command handling and replay. Use event stream or aggregate contract for this Keiro concept. Use stream for stored event history. The discouraged name decider suggests separate decision and event-application functions.

See [Core Concepts](../user/core-concepts.md#eventstream). See [Why Keiro](../why-keiro.md).
