---
type: Term
title: projection generation
description: "A projection generation is a physical instance of a projection revision's data."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A projection generation is a physical instance of a projection revision's data.

During online rebuilding, the serving generation remains available while Keiro populates and checks the candidate. [Promotion](promotion.md) makes the candidate serve traffic.

A retained old generation stops receiving normal writes after promotion. Retention alone does not guarantee safe rollback.

See [read models and projections](../user/read-models-and-projections.md).
