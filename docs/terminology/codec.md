---
type: Term
title: codec
description: "A codec defines event type identifiers, payload encoding, payload decoding, and schema versions."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A codec defines event type identifiers, payload encoding, payload decoding, and schema versions.

An [upcaster](upcaster.md) converts an older payload to a format that the current application understands. For example, it can supply a newly required field.

Keiro stops command processing if an event type is unknown or its payload cannot be decoded. An incomplete history cannot provide a safe command decision.

See [Codecs and Event Evolution](../user/codecs-and-event-evolution.md).
