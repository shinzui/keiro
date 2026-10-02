---
type: Term
title: implementation hole
description: "An implementation hole is an explicit boundary where application code supplies behavior outside the keiro-dsl specification."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-48
status: current
tags:
  - keiro-dsl
related:
  - TERM-49
  - TERM-55
anchors:
  - kind: doc
    resource: docs/user/keiro-dsl-workspaces-and-generated-code.md
---

# implementation hole

An implementation hole is an explicit boundary where application code supplies behavior outside the keiro-dsl specification.

A transition can declare a hole for complex predicates or updates. Scaffolding creates an implementation interface. Generated code retains the declared transition structure.

The implementation resides in a [create-once file](create-once-file.md). Maintain the [fold version](fold-version.md) when handwritten aggregate folding behavior changes. A hole can contain complete application logic.

See [Keiro DSL Workspaces and Generated Code](../user/keiro-dsl-workspaces-and-generated-code.md).
