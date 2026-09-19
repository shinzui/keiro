---
type: Term
title: projection rebuild
description: "The process of reconstructing or reconciling derived data from retained event history and verifying it before serving it."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-43
status: current
tags:
  - read-side
related:
  - TERM-42
  - TERM-51
  - TERM-44
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# projection rebuild

An offline rebuild prepares the selected [rebuild group's](rebuild-group.md) serving tables in place while that group is unavailable. An online rebuild prepares a candidate [generation](projection-generation.md) while the current one continues serving, then promotes the candidate.

Rebuilding needs a safe [replay adapter](replay-adapter.md). Clearing a table is appropriate only when retained history can reconstruct it; preserving and reconciling data is a separate policy.

See [read models and projections](../user/read-models-and-projections.md) for details.
