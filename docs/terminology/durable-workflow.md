---
type: Term
title: durable workflow
description: A long-running process written as an ordinary imperative function whose named steps are journaled, so it can suspend and resume by re-running from the top while replaying completed steps.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-13
status: current
related:
  - TERM-14
  - TERM-15
  - TERM-12
anchors:
  - kind: module
    resource: Keiro.Workflow
  - kind: doc
    resource: docs/user/durable-workflows.md
  - kind: doc
    resource: docs/guides/durable-workflows.md
---

# durable workflow

A durable workflow survives crashes, redeployments, and idle waits. Its checkpoints live in a
[journal](journal.md); it can sleep on a [timer](timer.md), wait on an
[awakeable](awakeable.md), or spawn child workflows. Step effects are at-least-once, so they
must be idempotent.
