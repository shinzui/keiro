---
type: Term
title: workspace manifest
description: "A workspace manifest is authored configuration that groups keiro-dsl specifications into one service and declares generation settings."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-27
status: current
tags:
  - keiro-dsl
scope: keiro-dsl
related:
  - TERM-26
anchors:
  - kind: module
    resource: Keiro.Dsl.Workspace
  - kind: doc
    resource: docs/user/keiro-dsl-workspaces-and-generated-code.md
    note: The Service workspaces section.
---

# workspace manifest

A workspace manifest is authored configuration that groups keiro-dsl specifications into one service and declares generation settings.

A `.keiro-workspace` file lists member `.keiro` specifications, service identity, and output configuration. Use it for a service with several specification files.

The manifest is generation input. Generated supporting files are [sidecars](sidecar.md). Generated build guidance is a [Cabal fragment](cabal-fragment.md).

See [Service Workspaces](../user/keiro-dsl-workspaces-and-generated-code.md#service-workspaces).
