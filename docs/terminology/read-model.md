---
type: Term
title: read model
description: "A read model is a view of event-sourced data organized for application queries."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-6
status: current
tags:
  - read-side
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

A read model is a view of event-sourced data organized for application queries.

An order summary can contain order status, payment total, and shipment date. Queries read this view without replay of aggregate history.

A [projection](projection.md) updates the view. Asynchronous updates can lag behind committed events. Keiro also tracks schema readiness and supports [query freshness](query-freshness.md) policies.

See [Read Models and Projections](../user/read-models-and-projections.md).
