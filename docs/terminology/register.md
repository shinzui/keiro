---
type: Term
title: register
description: "A named, typed value remembered by an aggregate alongside its lifecycle state."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-31
status: current
tags:
  - modeling
related:
  - TERM-30
  - TERM-5
anchors:
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
---

# register

An order can be in the paid [lifecycle state](lifecycle-state.md) while registers hold its customer identifier and total. Here, register means part of the aggregate's in-memory model, not a database registration record.

Register changes must be recoverable from events. Registers and their formal operations belong to `mori://shinzui/keiki`; Keiro persists their evidence through events and can cache their values in [snapshots](snapshot.md).

See [typed spec toolchain](../user/typed-spec-toolchain.md) for details.
