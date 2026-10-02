---
type: Term
title: upcaster
description: "An upcaster converts an older stored event payload to a format that the current application can decode."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-63
status: current
tags:
  - replay
related:
  - TERM-3
  - TERM-32
anchors:
  - kind: doc
    resource: docs/user/codecs-and-event-evolution.md
---

# upcaster

An upcaster converts an older stored event payload to a format that the current application can decode.

If an event gains a field, an upcaster can supply a value for older payloads. Upcasting is part of the [codec](codec.md) read path. It does not require changes to stored events.

Payload compatibility differs from behavioral compatibility. An event can decode but fail replay if its interpreting transition changed or was removed.

See [codecs and event evolution](../user/codecs-and-event-evolution.md).
