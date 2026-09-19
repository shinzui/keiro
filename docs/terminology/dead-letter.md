---
type: Term
title: dead letter
description: A durable record of a delivery that keiro stopped retrying, kept so an operator can inspect it and replay it idempotently.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-20
status: current
anchors:
  - kind: module
    resource: Keiro.DeadLetter
  - kind: doc
    resource: docs/user/dead-letters.md
---

# dead letter

Keiro distinguishes two kinds. A dispatch dead letter records a process-manager or router
command that the target rejected, when the worker is configured with `RejectedDeadLetter`. A
subscription dead letter is Kiroku's terminal subscription failure, which `Keiro.DeadLetter`
can replay through a caller-supplied handler. Neither is an automatic retry queue.
