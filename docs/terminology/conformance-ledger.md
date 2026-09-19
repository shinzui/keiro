---
type: Term
title: conformance ledger
description: A tool-maintained history of the generated test package used to check a service against its keiro-dsl specification.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

When enabled, a conformance package provides runnable checks of the service against its
specification. Its ledger records the package's identity and files so later generation
can check the existing package. It records generation history, not test results.

The file is `keiro-dsl-conformance-ledger.txt`; keep it with the package and let the tool
maintain it. It replaces the [conformance record](conformance-record.md). See
[Typed-Spec Toolchain](../user/typed-spec-toolchain.md#one-runnable-conformance-package-per-service)
for the generated test package.
