---
type: Term
title: command cycle
description: The process of rebuilding an aggregate's state, evaluating a command, and saving any resulting events while checking for concurrent changes.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-4
status: current
tags:
  - modeling
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

For a command such as `ShipOrder`, Keiro reads the target order's history, reconstructs
its state, and evaluates whether shipping is allowed. It then appends any resulting events
only if the stream has not changed since it was read. This is optimistic concurrency.

On a retryable concurrency conflict, Keiro reloads the state and evaluates the command
again, up to the configured retry limit. A [snapshot](snapshot.md) can reduce replay work;
[inline projections](inline-projection.md) update in the same transaction as the append.

See [Command Cycle](../user/command-cycle.md) for the execution sequence and options.
