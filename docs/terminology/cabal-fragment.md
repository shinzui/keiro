---
type: Term
title: Cabal fragment
description: "A Cabal fragment is generated Haskell build configuration for inclusion in a package's Cabal file."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-26
status: current
tags:
  - keiro-dsl
scope: keiro-dsl
discouraged:
  - scaffold manifest
broader:
  - TERM-21
anchors:
  - kind: module
    resource: Keiro.Dsl.SidecarNames
  - kind: doc
    resource: docs/user/keiro-dsl-workspaces-and-generated-code.md
    note: The Scaffold sidecars section.
---

# Cabal fragment

A Cabal fragment is generated Haskell build configuration for inclusion in a package's Cabal file.

After code generation, keiro-dsl writes build entries for the developer to copy. Later scaffold runs do not read the fragment as configuration.

Its filename is `keiro-dsl-cabal-fragment.context.<context>.txt` or `keiro-dsl-cabal-fragment.workspace.<service>.txt`. Use Cabal fragment for this output. Reserve manifest for the authored [workspace manifest](workspace-manifest.md).

See [Keiro DSL Workspaces and Generated Code](../user/keiro-dsl-workspaces-and-generated-code.md#scaffold-sidecars).
