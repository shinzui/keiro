---
type: Term
title: mapped type
description: "A mapped type is a keiro-dsl declaration that connects a specification type to an existing application-owned Haskell type."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-60
status: current
tags:
  - keiro-dsl
related:
  - TERM-61
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-types-and-mappings.md
---

# mapped type

A mapped type is a keiro-dsl declaration that connects a specification type to an existing application-owned Haskell type.

A service can reuse its existing address type. A structural mapping declares its representation. A [structural binding](structural-binding.md) connects the application and generated shapes.

An opaque mapping delegates encoding to application code. Its internal representation is outside DSL compatibility checks. The mapping mode determines serialized-format ownership.

See [Keiro DSL Types and Mappings](../user/keiro-dsl-types-and-mappings.md).
