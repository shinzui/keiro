---
type: Term
title: sidecar
description: A supporting file generated alongside Haskell code by keiro-dsl, containing generation history or build guidance.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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
    resource: docs/user/typed-spec-toolchain.md
    note: The Scaffold sidecars section.
---

# sidecar

Here, "sidecar" means a companion file in the generated project, not a separate running
service. It helps the tool or developer use and maintain the generated code.

The [scaffold ledger](scaffold-ledger.md) and [conformance ledger](conformance-ledger.md)
preserve generation history. The [Cabal fragment](cabal-fragment.md) supplies build
configuration to copy into a package. A workspace migration can also produce a report.

The [workspace manifest](workspace-manifest.md) is an input you author, rather than a
generated sidecar. See [Typed-Spec Toolchain](../user/typed-spec-toolchain.md#scaffold-sidecars)
for file names and handling rules.
