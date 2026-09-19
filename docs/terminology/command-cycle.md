---
type: Term
title: command cycle
description: "The sequence keiro runs for one command: resolve the stream, hydrate and replay its events through the transducer, step the transducer with the command, encode and append the produced events with optimistic concurrency, and optionally write a snapshot."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-4
status: current
related:
  - TERM-2
  - TERM-1
  - TERM-5
anchors:
  - kind: module
    resource: Keiro.Command
  - kind: doc
    resource: docs/user/command-cycle.md
---

# command cycle

A retryable concurrency conflict on append rehydrates and runs the cycle again, up to the
configured retry limit. [Inline projections](inline-projection.md) run inside the same append
transaction.
