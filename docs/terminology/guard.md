---
type: Term
title: guard
description: "A condition that must hold for an aggregate transition to handle a command."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-33
status: current
tags:
  - modeling
related:
  - TERM-31
  - TERM-28
anchors:
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
---

# guard

For example, a payment transition might require the amount in the command to equal the outstanding balance in a [register](register.md). Guards select applicable behavior using the command and reconstructed state.

Keiro uses guards from `mori://shinzui/keiki`. Changing a guard can affect historical replay as well as new decisions, so it belongs in the [replay-safety](replay-safety.md) and evolution review.

See [typed spec toolchain](../user/typed-spec-toolchain.md) for details.
