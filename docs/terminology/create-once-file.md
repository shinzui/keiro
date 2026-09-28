---
type: Term
title: create-once file
description: "A file scaffolding creates initially and then preserves on later runs so developers can maintain its contents."
generated:
  by: openai/codex
  at: "2026-09-19T03:27:20Z"
termId: TERM-49
status: current
tags:
  - keiro-dsl
aliases:
  - hand-owned file
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-workspaces-and-generated-code.md
---

# create-once file

Implementation holes, bindings, and other application-owned modules use this policy. Once created, they can hold completed business logic without regeneration overwriting it.

Generated modules have a different policy: regeneration may replace them. When a specification evolves, retained create-once code may need manual updates to match new interfaces.

See [Keiro DSL Workspaces and Generated Code](../user/keiro-dsl-workspaces-and-generated-code.md) for details.
