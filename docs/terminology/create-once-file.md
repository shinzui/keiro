---
type: Term
title: create-once file
description: "A create-once file is a file that scaffolding creates initially and preserves on subsequent runs."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

A create-once file is a file that scaffolding creates initially and preserves on subsequent runs.

Implementation holes and bindings use this policy. Developers can complete their business logic without regeneration overwriting it.

Regeneration can replace generated modules. After specification changes, retained application code can need manual updates for new interfaces.

See [Keiro DSL Workspaces and Generated Code](../user/keiro-dsl-workspaces-and-generated-code.md).
