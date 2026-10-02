---
type: Term
title: structural binding
description: "A structural binding is a total conversion in both directions between an application-owned type and a DSL-declared structural shape."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-61
status: current
tags:
  - keiro-dsl
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-types-and-mappings.md
---

# structural binding

A structural binding is a total conversion in both directions between an application-owned type and a DSL-declared structural shape.

The conversion must preserve values in both directions. Conformance fixtures provide finite evidence for these obligations.

The binding connects representations. The structural declaration owns wire-format policy. Application JSON instances cannot override the generated format.

See [Keiro DSL Types and Mappings](../user/keiro-dsl-types-and-mappings.md).
