---
type: Term
title: projection generation
description: "A physical instance of a projection's data, such as the serving tables or a candidate being built alongside them."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-51
status: current
tags:
  - read-side
related:
  - TERM-52
  - TERM-50
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# projection generation

During an online rebuild, the serving generation stays available while the candidate is populated and checked. [Promotion](promotion.md) makes the candidate serve traffic.

A generation instantiates a [projection revision](projection-revision.md). A retained old generation stops receiving ordinary writes after promotion; retaining it does not make rollback automatically safe.

See [read models and projections](../user/read-models-and-projections.md) for details.
