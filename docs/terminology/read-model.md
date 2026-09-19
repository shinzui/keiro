---
type: Term
title: read model
description: A view of event-sourced data organized for queries, such as an order summary or a list of overdue invoices.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

A read model stores the information a query needs without requiring the query to replay
aggregate histories. An order summary might combine an order's status, payment total,
and shipping date into one row.

A [projection](projection.md) keeps the view up to date. The read model is the data you
query; the projection is the logic that updates it. With asynchronous updates, the view
can lag behind committed events.

Keiro also tracks whether a model's schema is current and ready to query. See
[Read Models and Projections](../user/read-models-and-projections.md) for query contracts
and [query freshness](query-freshness.md) options.
