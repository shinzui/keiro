---
type: Term
title: inline projection
description: A projection applied in the same transaction as the command append whose events it reads, so a reader that sees the events also sees their effect.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-8
status: current
scope: read side
broader:
  - TERM-7
related:
  - TERM-4
anchors:
  - kind: type
    resource: Keiro.Projection.Types.InlineProjection
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# inline projection

An inline projection runs through `runCommandWithProjections` or `runCommandWithSqlEvents`.
A failure rolls back the append with it.
