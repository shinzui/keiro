---
type: Term
title: projection revision
description: "A projection revision is a declared schema and behavior version that can be deployed and rebuilt as one implementation."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-50
status: current
tags:
  - read-side
related:
  - TERM-51
  - TERM-53
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# projection revision

A projection revision is a declared schema and behavior version that can be deployed and rebuilt as one implementation.

A revision connects provisioning, live handlers, replay adapters, and verification. Online rebuilding deploys serving and candidate revisions together.

A [projection generation](projection-generation.md) is a physical instance of revision data. A public query-shape change can also require a new [external read contract](external-read-contract.md).

See [read models and projections](../user/read-models-and-projections.md).
