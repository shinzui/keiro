---
type: Term
title: read model
description: "A query-optimized view derived from the event log, declared as a `ReadModel q r` with a name, version, shape hash, table, subscription, default consistency mode, and a query transaction."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-6
status: current
related:
  - TERM-7
anchors:
  - kind: module
    resource: Keiro.ReadModel
  - kind: type
    resource: Keiro.ReadModel.ReadModel
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# read model

Keiro tracks read-model metadata and refuses reads from stale or non-live models. A
[projection](projection.md) is what keeps a read model up to date.
