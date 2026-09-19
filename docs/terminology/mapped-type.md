---
type: Term
title: mapped type
description: "A keiro-dsl declaration that connects a specification type to an existing application-owned Haskell type."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-60
status: current
tags:
  - keiro-dsl
related:
  - TERM-61
anchors:
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
---

# mapped type

A service can reuse its existing address type instead of introducing a second public domain type. A structural mapping declares the representation and uses a [structural binding](structural-binding.md) to connect the two shapes.

An opaque mapping delegates encoding to application code and leaves the internal representation outside the DSL's compatibility checks. The choice determines who owns the serialized format.

See [typed spec toolchain](../user/typed-spec-toolchain.md) for details.
