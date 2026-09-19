---
type: Term
title: dead letter
description: A saved record of a delivery that will no longer be retried automatically, kept for investigation and possible replay.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-20
status: current
tags:
  - integration
related:
  - TERM-10
  - TERM-11
anchors:
  - kind: module
    resource: Keiro.DeadLetter
  - kind: doc
    resource: docs/user/dead-letters.md
---

# dead letter

A dead letter makes a failed delivery visible for an operator to inspect, address, and
explicitly replay when appropriate. It is not an automatic retry queue, and replay must
be safe if some effects from an earlier attempt already occurred.

Keiro's dead-letter tooling distinguishes rejected commands dispatched by a
[process manager](process-manager.md) or [router](router.md), when configured to retain
them, from terminal subscription failures. See [Dead Letters](../user/dead-letters.md)
for inspection and replay procedures.
