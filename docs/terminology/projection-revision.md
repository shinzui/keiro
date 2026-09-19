---
type: Term
title: projection revision
description: "A declared version of a projection's schema and behavior that can be deployed and rebuilt as one coherent implementation."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

A revision connects target provisioning, live handlers, replay adapters, and verification. An online rebuild deploys both serving and candidate revisions so Keiro can keep serving one while constructing the other.

A revision describes what to run; a [projection generation](projection-generation.md) is a physical instance of its data. Changing a public query shape may also require a new [external read contract](external-read-contract.md).

See [read models and projections](../user/read-models-and-projections.md) for details.
