---
type: Term
title: codec
description: The rules for converting application events to stored data and reading stored events back, including support for older event formats.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-3
status: current
tags:
  - replay
related:
  - TERM-2
anchors:
  - kind: module
    resource: Keiro.Codec
  - kind: type
    resource: Keiro.Codec.Codec
  - kind: doc
    resource: docs/user/codecs-and-event-evolution.md
---

# codec

A codec connects the events your application uses to their persisted representation. It
identifies each event type, encodes and decodes its payload, and tracks its schema version.
An [upcaster](upcaster.md) converts an older payload into the format the current application understands.

For example, when `OrderPlaced` gains a field, an upcaster can supply a value for events
written before that field existed. Keiro stops command processing if an event type is
unknown or its payload cannot be decoded: deciding from an incomplete history is unsafe.

See [Codecs and Event Evolution](../user/codecs-and-event-evolution.md) for the API.
