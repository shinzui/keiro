---
type: Term
title: stream category
description: "A named family of streams that can be selected together for event consumption."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
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

For example, `order-123` and `order-456` belong to the order category. A reporting [subscription](subscription.md) can follow that family without listing every order.

Category naming follows `mori://shinzui/kiroku`: the category precedes the first hyphen in a stream name. Keiro's category-aware stream constructors validate that boundary so naming and subscription selection agree.

See [api reference](../user/api-reference.md) for details.
