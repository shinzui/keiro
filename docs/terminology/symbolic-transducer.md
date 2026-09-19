---
type: Term
title: symbolic transducer
description: "A state-machine model that describes command conditions, state updates, and emitted events in a form that can also support replay."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

Keiro uses one symbolic transducer as the behavior of an [event stream](event-stream.md). For an order, it might describe how a payment command moves the order from awaiting payment to paid and emits a payment event.

The model combines [lifecycle states](lifecycle-state.md), [registers](register.md), and [guarded transitions](transition.md). Its formal definition belongs to `mori://shinzui/keiki`; this entry explains its role in Keiro rather than defining another model.

See [core concepts](../user/core-concepts.md) for details.
