---
type: Term
title: conformance record
description: A deprecated name for the conformance ledger, the tool-maintained history of a generated conformance test package.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-25
status: deprecated
tags:
  - keiro-dsl
replacedBy: TERM-24
scope: keiro-dsl
related:
  - TERM-24
anchors:
  - kind: module
    resource: Keiro.Dsl.SidecarMigration
  - kind: doc
    resource: docs/adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md
---

# conformance record

Use [conformance ledger](conformance-ledger.md) in new code and documentation. Older
projects may still contain a conformance record, which serves the same role but uses an
older file format.

The explicit sidecar-name migration converts that format while preserving the original
file contents. See
[ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
for migration behavior.
