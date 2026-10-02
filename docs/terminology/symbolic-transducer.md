---
type: Term
title: symbolic transducer
description: "A symbolic transducer is a state-machine model for command conditions, state updates, emitted events, and replay."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-29
status: current
tags:
  - modeling
aliases:
  - transducer
related:
  - TERM-2
  - TERM-30
  - TERM-31
  - TERM-32
anchors:
  - kind: doc
    resource: docs/user/core-concepts.md
---

# symbolic transducer

A symbolic transducer is a state-machine model for command conditions, state updates, emitted events, and replay.

An order model can describe a payment command that changes order state and emits a payment event. The model combines [lifecycle states](lifecycle-state.md), [registers](register.md), and guarded [transitions](transition.md).

Keiro uses this model as the behavior of an [event stream](event-stream.md). The formal definition belongs to `mori://shinzui/keiki`.

See [core concepts](../user/core-concepts.md).
