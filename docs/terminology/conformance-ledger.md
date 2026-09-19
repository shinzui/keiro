---
type: Term
title: conformance ledger
description: "The machine-owned sidecar inside an enabled conformance package that records the package's history as typed rows that tolerate unknown row kinds and keys."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-24
status: current
scope: keiro-dsl
broader:
  - TERM-21
related:
  - TERM-22
replaces:
  - TERM-25
anchors:
  - kind: module
    resource: Keiro.Dsl.ConformancePackage
  - kind: doc
    resource: docs/adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md
---

# conformance ledger

The file is `keiro-dsl-conformance-ledger.txt`. Known rows still reject corruption, unsafe
paths, duplicate paths, and a mismatched service key. It replaces the
[conformance record](conformance-record.md).
