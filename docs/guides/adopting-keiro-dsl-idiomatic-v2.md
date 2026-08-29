---
type: Guide
title: Adopting keiro-dsl generated Haskell idiomatic-v2
description: Adopt the idiomatic-v2 generated Haskell surface and its compatibility gates.
docId: DOC-24
tags: [keiro, dsl, generated-code, migration]
generated:
  by: human:nadeem
  at: 2026-08-23T19:54:01Z
---

# Adopting keiro-dsl generated Haskell idiomatic-v2

`idiomatic-v2` is a Haskell presentation edition for scaffold output. It gives
generated records concise repeated labels, suppresses product selector functions,
and moves `DuplicateRecordFields`, `NoFieldSelectors`, and `OverloadedRecordDot` into
the generated Cabal fragment. Constructor names, constructor arity, field order,
wire keys, SQL names, runtime identities, and `.keiro` meaning do not change.

Ordinary scaffolding never upgrades a recorded pre-v2 ledger silently. A ledger with
no `naming-edition` row is `legacy-v1`, not an untracked new tree.


## 1. Run the ordinary scaffold command

Use the same source or workspace, output directory, runtime package, module root,
layout, and golden arguments as the project's normal command:

```console
keiro-dsl scaffold path/to/service.keiro-workspace --out path/to/src
```

An `idiomatic-v1` or `legacy-v1` ledger exits non-zero before writes. The refusal lists every
recorded Generated path, the Cabal fragment and ledger, and attributable old selector
uses in create-once files.


## Legacy-v1 trees

A historical tree may use old ledger/Cabal-fragment names, old generated module names,
and a ledger with no edition row. Review the combined refusal, then run one command with
both flags:

```console
keiro-dsl scaffold path/to/service.keiro-workspace \
  --out path/to/src \
  --apply-name-migrations \
  --apply-generated-haskell-edition
```

The sidecars move first, the ledger is read again under its current name, the edition
backup captures every recorded file at its pre-move path, and the generated-name move
runs afterward under its separate backup. Passing either flag alone cannot complete a
legacy migration; the refusal names both remaining operations.


## 2. Migrate hand-owned code first

Review every reported Hole or binding occurrence. Use one of these dual-edition
bridges before applying the edition:

- For a renamed label, use a positional constructor pattern or positional
  construction. Constructor order is stable across the edition.
- For an unchanged concise label, enable `OverloadedRecordDot` locally while the v1
  manifest is still active and use `value.label`.
- Keep using an explicitly preserved newtype unwrapper.

The scanner is intentionally attributable rather than a claim to understand the
whole application. Compile errors after adoption remain the authority for sources
outside the scaffold inventory. Do not add `FieldSelectors`, generic-lens aliases, or
replacement product selectors.


## 3. Apply explicitly

After the ordinary refusal is understood, rerun the exact command with:

```console
keiro-dsl scaffold path/to/service.keiro-workspace \
  --out path/to/src \
  --apply-generated-haskell-edition
```

The command reruns collision, banner, package, workspace, and overwrite preflights.
Before overwriting, it copies every existing Generated file and both sidecars to:

```text
path/to/src/.keiro-dsl-generated-haskell-migrations/<from>-to-idiomatic-v2/
```

The backed-up set is every existing ledger-recorded Generated file plus the current
ledger and Cabal fragment. A conformance package's own files are written after the
ledger and are not part of this backup set. The same directory contains
`remediation-report.txt`, which is regenerated on every apply and may be left in place
during rollback and retry. Create-once Hole files are not
copied, moved, rewritten, or claimed. A pre-existing backup with different bytes is a
hard refusal. Repeating a successful run is an ordinary idempotent v2 scaffold.


## 4. Reconcile the build

Paste or otherwise reconcile the regenerated Cabal fragment. Its defaults are:

```cabal
default-language: GHC2024
default-extensions:
  DuplicateRecordFields
  NoFieldSelectors
  OverloadedRecordDot
  OverloadedStrings
```

Compile the entire consuming component, including Hole modules and generated
conformance packages. Then run behavior, structural, codec, replay, and application
tests. Generated Haskell bytes and Haskell field APIs are expected to change; wire,
JSON, SQL, fingerprint, and runtime observations are not.


## Roll back

Stop scaffolding and restore each backed-up relative path from
`.keiro-dsl-generated-haskell-migrations/<from>-to-idiomatic-v2/` to the output
root, including the Cabal fragment and ledger. Restore as a complete set; do not mix a
v1 ledger or manifest with v2 Generated modules. The restored ledger again records
`naming-edition idiomatic-v1`, so the current tool will refuse ordinary regeneration
until a later explicit adoption. Version-control restoration is equally valid when it
restores the same complete set.

For a `legacy-v1` migration, also remove every source-move destination listed in
`remediation-report.txt` and restore the moved originals from
`.keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/`. The remediation report itself
does not need to be restored or removed.

If an apply was interrupted, rerun only after inspecting the backup. The tool either
continues from byte-identical backup evidence or refuses a source/backup conflict;
rollback the complete set before retrying when it refuses. This conflict check runs only
while the ledger records the older edition; once the ledger says `idiomatic-v2`, an
ordinary rerun does not reinterpret later application edits as migration conflicts.


## References

- The exhaustive generated field and consumer map is
  [`generated-haskell-edition-idiomatic-v2.md`](../../keiro-dsl/generated-haskell-edition-idiomatic-v2.md).
- [ADR 0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
  defines the edition.
- [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  defines backup and hand-owned-source authority.
