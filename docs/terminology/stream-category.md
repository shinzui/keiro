---
type: Term
title: stream category
description: "A stream category is a named family of streams for event consumption."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-36
status: current
tags:
  - modeling
related:
  - TERM-34
anchors:
  - kind: doc
    resource: docs/user/api-reference.md
---

# stream category

A stream category is a named family of streams for event consumption.

The streams `order-123` and `order-456` belong to the order category. A reporting subscription can follow this category without listing each order.

Category naming belongs to `mori://shinzui/kiroku`. The category precedes the first hyphen in a stream name. Keiro's category-aware constructors validate this boundary.

See [api reference](../user/api-reference.md).
