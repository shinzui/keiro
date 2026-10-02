---
type: Term
title: projection catalog
description: "A projection catalog declares projections, read models, event sources, target ownership, and rebuild boundaries."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A projection catalog declares projections, read models, event sources, target ownership, and rebuild boundaries.

The catalog connects each read model to the projection that maintains its [physical targets](physical-target.md). It groups targets for rebuilding.

Keiro validates declarations before registration or rebuild work. Validation detects conflicting ownership and unsafe combinations. It cannot discover undeclared table access in application SQL.

See [read models and projections](../user/read-models-and-projections.md).
