---
type: Term
title: implementation hole
description: "An explicit place where application code supplies behavior that the keiro-dsl specification leaves hand-written."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-48
status: current
tags:
  - keiro-dsl
related:
  - TERM-49
  - TERM-55
anchors:
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
---

# implementation hole

A transition with complex predicate or update logic can declare an implementation hole. Scaffolding creates a place to implement that logic while generated code retains the declared transition structure.

The implementation lives in a [create-once file](create-once-file.md). Changing hand-written aggregate folding behavior also requires maintaining its [fold version](fold-version.md). A hole is an ownership boundary, not necessarily unfinished code.

See [typed spec toolchain](../user/typed-spec-toolchain.md) for details.
