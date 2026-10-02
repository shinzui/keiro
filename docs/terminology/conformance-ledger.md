---
type: Term
title: conformance ledger
description: "A conformance ledger is tool-maintained generation history for a service's conformance test package."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-24
status: current
tags:
  - keiro-dsl
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

A conformance ledger is tool-maintained generation history for a service's conformance test package.

The ledger records package identity and generated files. Later generation uses it to check the existing package. It records generation history rather than test results.

Keep `keiro-dsl-conformance-ledger.txt` with the package. Let the tool maintain it. [Conformance record](conformance-record.md) is a deprecated name.

See [Keiro DSL Workspaces and Generated Code](../user/keiro-dsl-workspaces-and-generated-code.md#one-runnable-conformance-package-per-service).
