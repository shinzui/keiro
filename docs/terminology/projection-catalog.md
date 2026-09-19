---
type: Term
title: projection catalog
description: "The application's declaration of its projections, query models, event sources, target ownership, and rebuild boundaries."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-40
status: current
tags:
  - read-side
related:
  - TERM-6
  - TERM-7
  - TERM-41
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# projection catalog

A catalog connects a queryable [read model](read-model.md) to the [projection](projection.md) that maintains its [physical targets](physical-target.md), and groups those targets for rebuilding.

Keiro validates these declarations before registration or rebuild work. This detects conflicting ownership and unsafe combinations, but cannot discover tables touched by undeclared application SQL.

See [read models and projections](../user/read-models-and-projections.md) for details.
