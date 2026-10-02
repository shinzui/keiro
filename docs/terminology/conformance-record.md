---
type: Term
title: conformance record
description: "Conformance record is a deprecated name for conformance ledger."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
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

Conformance record is a deprecated name for conformance ledger.

Use [conformance ledger](conformance-ledger.md) in new documentation. Existing records can use an older format.

Explicit sidecar-name migration converts the format and preserves the original contents. See [ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md) for the migration contract.
