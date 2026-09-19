---
type: Term
title: event stream
description: "Keiro's aggregate contract, defining how one kind of aggregate handles commands, produces events, and reconstructs state from its history."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

In general event-sourcing usage, "event stream" often means a sequence of stored events.
In this catalog, that is a [stream](stream.md). Keiro's `EventStream` instead describes
the behavior and persistence rules shared by instances of an aggregate type.

For example, one order event-stream contract defines which commands an order accepts and
which events it produces; each individual order has its own stored stream. The contract
also supplies the initial state, [codec](codec.md), stream naming, and
[snapshot](snapshot.md) policy used by the [command cycle](command-cycle.md).

Keiro expresses command handling and replay in one state-machine model, called a
[symbolic transducer](symbolic-transducer.md), provided by `mori://shinzui/keiki`. Use "event stream" or "aggregate contract"
for the Keiro contract; "decider" suggests a different API with separate decision and
event-application functions. See [Core Concepts](../user/core-concepts.md#eventstream)
for the types and validation, and [Why Keiro](../why-keiro.md) for the design rationale.
