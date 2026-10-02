---
type: Term
title: scaffold ledger
description: "A scaffold ledger is tool-maintained generation history that tracks service files and their ownership."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-22
status: current
tags:
  - keiro-dsl
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

A scaffold ledger is tool-maintained generation history that tracks service files and their ownership.

The ledger supplies a baseline for later scaffold runs. It records development-tool history.

Commit the ledger with generated code. Do not edit or discard it manually. Its filename is `keiro-dsl-ledger.context.<context>.txt` or `keiro-dsl-ledger.workspace.<service>.txt`. [Scaffold record](scaffold-record.md) is a deprecated name.

See [Keiro DSL Workspaces and Generated Code](../user/keiro-dsl-workspaces-and-generated-code.md#scaffold-sidecars).
