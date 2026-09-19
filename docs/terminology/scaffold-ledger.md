---
type: Term
title: scaffold ledger
description: "The machine-owned sidecar that records a service's scaffold history, including its generated paths, mapped provenance, and ownership, and that every later scaffold run reads."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-22
status: current
scope: keiro-dsl
aliases:
  - ledger
broader:
  - TERM-21
related:
  - TERM-24
replaces:
  - TERM-23
anchors:
  - kind: module
    resource: Keiro.Dsl.ScaffoldRecord
    note: Reads and writes the standalone ledger.
  - kind: module
    resource: Keiro.Dsl.WorkspaceRecord
    note: Reads and writes the workspace ledger.
  - kind: doc
    resource: docs/adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md
---

# scaffold ledger

A scaffold ledger is named `keiro-dsl-ledger.context.<context>.txt` for a standalone context or
`keiro-dsl-ledger.workspace.<service>.txt` for a workspace. Commit it; do not edit or discard
it. It replaces the [scaffold record](scaffold-record.md). The parsing module still carries
the old name, `Keiro.Dsl.ScaffoldRecord`.
