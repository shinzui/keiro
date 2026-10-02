---
type: Term
title: projection rebuild
description: "A projection rebuild reconstructs or reconciles derived data from retained event history and verifies it before service."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A projection rebuild reconstructs or reconciles derived data from retained event history and verifies it before service.

An offline rebuild prepares serving tables while the selected group is unavailable. An online rebuild prepares a candidate generation while the current generation continues service. It then promotes the candidate.

Use a safe [replay adapter](replay-adapter.md). Clear a target only if retained history can reconstruct it. Data preservation and reconciliation require a separate target policy.

See [read models and projections](../user/read-models-and-projections.md).
