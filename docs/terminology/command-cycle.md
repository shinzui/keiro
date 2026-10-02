---
type: Term
title: command cycle
description: "A command cycle reconstructs aggregate state, evaluates a command, and appends resulting events with a concurrency check."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A command cycle reconstructs aggregate state, evaluates a command, and appends resulting events with a concurrency check.

For `ShipOrder`, Keiro reads the order history and evaluates whether shipment is permitted. It appends events only if the stream still has the expected version.

On a retryable concurrency conflict, Keiro reloads state and evaluates the command again. The configured retry limit bounds these attempts. A [snapshot](snapshot.md) can reduce replay work. [Inline projections](inline-projection.md) update within the append transaction.

See [Command Cycle](../user/command-cycle.md).
