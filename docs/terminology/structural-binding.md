---
type: Term
title: structural binding
description: "A total conversion in both directions between an application-owned type and the structural shape declared by keiro-dsl."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-61
status: current
tags:
  - keiro-dsl
anchors:
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
---

# structural binding

A binding connects an existing address value to the generated address shape and back. It must preserve values in both directions; conformance fixtures provide finite evidence for those obligations.

The binding connects representations, while the structural declaration owns wire-format policy. It does not grant the application's JSON instance authority to override the generated format.

See [typed spec toolchain](../user/typed-spec-toolchain.md) for details.
