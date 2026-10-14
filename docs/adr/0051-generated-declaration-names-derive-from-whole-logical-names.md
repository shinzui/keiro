---
type: Architecture Decision Record
title: Generated declaration names derive from whole logical names
description: Keiro DSL derives each declaration stem from its complete logical name and checks provably missing imports between generated modules before scaffold writes.
timestamp: 2026-10-14T02:16:17Z
docId: ADR-51
status: Accepted
date: 2026-10-14
originatingPlan: docs/plans/310-derive-generated-declaration-stems-from-whole-logical-names-to-fix-bug-11.md
---

# Generated declaration names derive from whole logical names

## Context

`keiro-dsl check` accepts `validate_custom_type`: the complete lowerCamel
occurrence is `validateCustomType`, which is not reserved. The scaffold renderer
formerly cased each underscore segment separately for read models and
workqueues. The segment `type` failed the term-level keyword check and fell
back to raw lowercase text, producing `validateCustomtypeReadModel` and
`jobtypeJobCodec`. The read-model harness used the complete name and imported
`validateCustomTypeReadModel`, so the generated tree failed to compile.

The [generated Haskell contract](0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
defines ASCII segmentation, casing, and the 23 term-level reserved words.
The [sidecar contract](0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
distinguishes generated files from create-once consumer holes. New positive DSL
coverage uses Language 6 under [ADR-49](0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md).

## Decision

Derive each generated declaration stem once from its whole logical name, then
share that stem across definitions, contracts, imports, and harnesses. Do not
case underscore-separated segments independently. Keep the existing
`lowerFirst . pascal` stem formula, which preserves names without reserved
segments, including single-letter segments such as `a_b_test`.

The reserved term-level set applies to a complete lowerCamel occurrence.
UpperCamel-only positions derive without consulting that set: a segment `type`
becomes `Type` when embedded in a compound name, while a whole declaration
named `type` still fails validation. Structural projection names assembled
from wire-path pieces follow the same upper-only rule; wire keys and pointers
retain their original bytes.

Before any scaffold write, compare supported plain value imports between
planned generated modules with their sibling's complete explicit export list.
Refuse a value that the known list proves absent. Treat implicit exports,
wildcard children, module re-exports, unsupported syntax, external modules,
and hand-owned hole targets as unknown; GHC remains responsible for them.
The audit is deliberately bounded and must not infer a complete export set
from a partial inventory.

Rejecting every logical name containing a keyword segment was considered and
rejected: `validate_custom_type` is a valid, already accepted declaration,
and only its renderer was inconsistent. This repair stays within the existing
`idiomatic-v2` naming edition; it changes generated source spellings for
affected names without changing persisted or wire identities.

## Consequences

Consumers re-scaffold and recompile. References to affected workqueue codec
values, outcome types, and structural projection witnesses/getters need source
renames. Create-once read-model holes are never overwritten: consumers rename
their query binding, local type aliases, exports, and contract imports by hand
while preserving application code. A compiled Language 6 keyword-segment
conformance suite protects the read-model import and workqueue names.
