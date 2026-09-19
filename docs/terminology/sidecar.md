---
type: Term
title: sidecar
description: A file that keiro-dsl scaffolding writes beside generated Haskell, whose name states whether it is machine-owned history or text for a person.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-21
status: current
scope: keiro-dsl
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

Sidecar is the umbrella word, and it is current. ADR-22 did not retire it: it renamed the
individual sidecars so each filename states its role. The sidecars are the
[scaffold ledger](scaffold-ledger.md), the [conformance ledger](conformance-ledger.md), the
[Cabal fragment](cabal-fragment.md), and the one-time workspace migration report.

The authored `.keiro-workspace` input is not a sidecar; it is the
[workspace manifest](workspace-manifest.md).
