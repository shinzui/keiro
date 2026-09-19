---
type: Term
title: Cabal fragment
description: Generated Haskell build configuration to copy into a package's Cabal file so it can build the generated modules.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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
    resource: docs/user/typed-spec-toolchain.md
    note: The Scaffold sidecars section.
---

# Cabal fragment

Cabal is Haskell's package and build system. After generating code, keiro-dsl writes a
fragment containing the build entries to add to your package. This is guidance for the
developer; subsequent scaffold runs do not read it as configuration.

The file is `keiro-dsl-cabal-fragment.context.<context>.txt` or
`keiro-dsl-cabal-fragment.workspace.<service>.txt`. Use "Cabal fragment" rather than the
old name "scaffold manifest", which can be confused with the authored
[workspace manifest](workspace-manifest.md). See
[Typed-Spec Toolchain](../user/typed-spec-toolchain.md#scaffold-sidecars) for usage.
