---
type: Term
title: sidecar
description: "A sidecar is a supporting file that keiro-dsl generates alongside Haskell code."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-21
status: current
tags:
  - keiro-dsl
scope: keiro-dsl
related:
  - TERM-22
  - TERM-24
  - TERM-26
  - TERM-27
anchors:
  - kind: module
    resource: Keiro.Dsl.SidecarNames
    note: The one naming authority for every sidecar.
  - kind: doc
    resource: docs/adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md
  - kind: doc
    resource: docs/user/keiro-dsl-workspaces-and-generated-code.md
    note: The Scaffold sidecars section.
---

# sidecar

A sidecar is a supporting file that keiro-dsl generates alongside Haskell code.

A sidecar contains generation history, build guidance, or a migration report. The [scaffold ledger](scaffold-ledger.md) and [conformance ledger](conformance-ledger.md) preserve generation history. The [Cabal fragment](cabal-fragment.md) supplies build entries.

The authored [workspace manifest](workspace-manifest.md) is generation input. In this catalog, sidecar means a companion file.

See [Keiro DSL Workspaces and Generated Code](../user/keiro-dsl-workspaces-and-generated-code.md#scaffold-sidecars).
