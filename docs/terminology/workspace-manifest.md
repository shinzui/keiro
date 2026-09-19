---
type: Term
title: workspace manifest
description: An authored configuration file that groups several keiro-dsl specifications into one service and declares how to generate that service.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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
    resource: docs/user/typed-spec-toolchain.md
    note: The Service workspaces section.
---

# workspace manifest

A `.keiro-workspace` file lists the `.keiro` specifications that make up a service,
along with its identity and output configuration. Use it when one service is described
across several specification files.

You author this file as input to generation. The generated supporting files are
[sidecars](sidecar.md); build guidance is a [Cabal fragment](cabal-fragment.md).
In keiro-dsl, "manifest" refers only to the workspace manifest. See
[Service Workspaces](../user/typed-spec-toolchain.md#service-workspaces) for the format.
