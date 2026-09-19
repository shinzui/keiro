---
type: Term
title: event stream
description: "The aggregate contract an application declares once per aggregate type: a Keiki symbolic transducer with its initial state and registers, an event codec, a stream-name resolver, and a snapshot policy."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-2
status: current
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

An event stream (`EventStream phi rs s ci co`) is what keiro runs a command against. Its
decision logic is a Keiki `SymTransducer`, not a decide/evolve pair; applications validate the
record with `mkEventStream` and hand the resulting `ValidatedEventStream` to the command runner.

Do not call it a "decider". Keiro deliberately chose Keiki's native transducer over a Decider
facade, and `Keiki.Decider` is a legacy facade keiro must not rely on (see `docs/why-keiro.md`,
"The single-formalism claim"). The transducer itself is a Keiki concept, defined by
`mori://shinzui/keiki`, not by this catalog.

Its events live in a [stream](stream.md), cross the storage boundary through a
[codec](codec.md), and are processed by the [command cycle](command-cycle.md).
