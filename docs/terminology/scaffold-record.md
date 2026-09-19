---
type: Term
title: scaffold record
description: A deprecated name for the scaffold ledger, the tool-maintained history of generated service files.
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
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

Use [scaffold ledger](scaffold-ledger.md) in new code and documentation. You may encounter
"scaffold record" in older projects and documentation; it refers to the same role.

Existing files require an explicit migration using `scaffold --apply-name-migrations`.
See [ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
for migration behavior.
