---
type: Term
title: upcaster
description: "A conversion that brings an older stored event payload forward to a format understood by the current application."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

When an order event gains a field, an upcaster can supply an appropriate value when reading the old version. Upcasting is part of the [codec](codec.md) read path and does not require rewriting the original stored event.

Payload compatibility is separate from behavioral compatibility. An event can decode successfully but still fail replay if the [transition](transition.md) that interprets it has been removed or changed.

See [codecs and event evolution](../user/codecs-and-event-evolution.md) for details.
