---
type: Term
title: scaffold record
description: "Scaffold record is a deprecated name for scaffold ledger."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-02T16:43:06Z"
termId: TERM-23
status: deprecated
tags:
  - keiro-dsl
replacedBy: TERM-22
scope: keiro-dsl
related:
  - TERM-22
anchors:
  - kind: doc
    resource: docs/adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md
---

# scaffold record

Scaffold record is a deprecated name for scaffold ledger.

Use [scaffold ledger](scaffold-ledger.md) in new documentation. The deprecated term identifies the same generation-history role.

Existing files need explicit migration with `scaffold --apply-name-migrations`. See [ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md) for the migration contract.
