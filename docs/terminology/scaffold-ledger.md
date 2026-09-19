---
type: Term
title: scaffold ledger
description: A tool-maintained history of generated service files that keiro-dsl uses to detect changes and track file ownership on later runs.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

Scaffolding generates the initial service code from a specification. The ledger preserves
what that generation produced, giving later runs a baseline for detecting changed files
and ownership. It is development-tool history, separate from application event history.

Commit it with the generated code; do not hand-edit or discard it. The file is named
`keiro-dsl-ledger.context.<context>.txt` for one context or
`keiro-dsl-ledger.workspace.<service>.txt` for a workspace. Older documentation calls it
a [scaffold record](scaffold-record.md). See
[Typed-Spec Toolchain](../user/typed-spec-toolchain.md#scaffold-sidecars) for details.
