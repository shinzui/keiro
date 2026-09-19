---
type: Term
title: Cabal fragment
description: The human-facing sidecar holding the Cabal stanza text a person pastes into the consuming package to build generated modules.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-26
status: current
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

The file is `keiro-dsl-cabal-fragment.context.<context>.txt` or
`keiro-dsl-cabal-fragment.workspace.<service>.txt`. No scaffold run reads it back.

Do not call it a "scaffold manifest". Its old filename, `keiro-dsl-manifest.*`, was retired by
ADR-22 because "manifest" also named the authored [workspace manifest](workspace-manifest.md).
