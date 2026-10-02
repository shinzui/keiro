---
type: Term
title: external read contract
description: "An external read contract is a versioned query interface for consumers outside a projection's process."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-53
status: current
tags:
  - read-side
related:
  - TERM-50
anchors:
  - kind: doc
    resource: docs/user/read-models-and-projections.md
---

# external read contract

An external read contract is a versioned query interface for consumers outside a projection's process.

Keiro publishes the contract as a guarded PostgreSQL function. It defines input and result shapes and supported [projection revisions](projection-revision.md).

A compatible contract can follow a promoted generation. A breaking shape change requires a new contract version and consumer migration. The application owns access grants and query SQL semantics.

See [read models and projections](../user/read-models-and-projections.md).
