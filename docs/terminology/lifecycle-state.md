---
type: Term
title: lifecycle state
description: "The named stage an aggregate currently occupies, used to determine which transitions are available."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-30
status: current
tags:
  - modeling
aliases:
  - control state
related:
  - TERM-31
anchors:
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
---

# lifecycle state

An order might be awaiting payment, paid, or shipped. These stages form its lifecycle; a payment total or customer identifier belongs in a [register](register.md).

Keiro's underlying model, owned by `mori://shinzui/keiki`, separates the lifecycle state from those remembered values. Together they form the state reconstructed from events.

See [typed spec toolchain](../user/typed-spec-toolchain.md) for details.
