---
type: Review
title: keiro-dsl 0.15 record API modernization
description: The package-authored record migration is complete, inventoried, and externally invisible, but its drift test overclaims three checks it does not perform and cannot run outside the repository.
generated:
  by: process:claude-code
  at: "2026-08-26T23:38:11Z"
reviewId: REV-13
subject: mori://shinzui/keiro
subjectKind: component
component: keiro-dsl
reviewedSha: acb9ee6cca88dd2ab6db5f6a3ff80b788e8e5d21
coverage: incremental
baseSha: 0bdd4b7d9c3e766c394ea487333822ddf9a554a8
previousReview: REV-12
reviewedAt: "2026-08-26T23:38:11Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: approved
dimensions:
  - correctness
  - design
  - test-coverage
  - documentation
context: >-
  Read the record modernization plan, ADR 38, both migration guides, the
  checked package and generated-edition inventories, the shared and
  generated-output Cabal stanzas, the extension-policy and formatter changes,
  the downstream audit, and the record-migration test and its generator;
  verified the twelve preserved unwrappers against source, diffed every
  non-Haskell conformance artifact since the base, and ran the build,
  inventory check, and repository gates. The generated-edition adoption path
  that this migration also introduced is reviewed separately in REV-14.
---

# keiro-dsl 0.15 record API modernization

## Release verdict

Approved. The package now compiles with `DuplicateRecordFields`,
`NoFieldSelectors`, and `OverloadedRecordDot` from the `shared` stanza, product
selector functions are gone from the public Haskell API, and the migration
stayed inside the boundary ADR 38 draws for it: the checked inventory covers 288
record-owning declarations and 1,412 fields with a current-to-target row for
each, the twelve deliberately preserved newtype unwrappers are explicit
positional functions exported from exposed modules, and no `generic-lens`,
`FieldSelectors`, or `OverloadedRecordUpdate` escape entered the tree. The
external contract held: the only non-Haskell conformance artifacts that changed
since 0.14.0.0 are 38 ledger `naming-edition` rows and the three new
`default-extensions` lines in 38 Cabal fragments, so JSON keys, goldens,
`.keiro` fixtures, and fingerprints are byte-identical. The extension-policy
gate now rejects local record-default pragmas and `FieldSelectors`, and Fourmolu
receives the same parser options, so the compiler, formatter, and policy agree
on one record model.

This is a PVP-major source change for the single registered package consumer
(`mori://shinzui/rei`) and is documented as such; the guide's migration table
is the checked inventory itself rather than prose that can drift from it.

## Follow-ups that do not block the release

- `keiro-dsl/test/Keiro/Dsl/RecordMigration.hs` runs one `manifestCheck`
  under three `it` descriptions that each claim a distinct property:
  "accounts for every package-authored record field", "keeps every serialized
  record boundary named in the migration inventory", and "accounts for
  generated declarations, consumers, and local record defaults". The generator's
  `--check` performs one operation per manifest, a regeneration and byte
  comparison; the "JSON/wire bytes" column is regex-derived documentation, not
  an assertion, and there is no serialized-boundary check. Collapse the three
  into the one claim the code makes, or add the two checks the descriptions
  promise.
- The same test is the third repository-only dependency in `keiro-dsl-test`:
  the generator lives at the repository root, resolves `ROOT` from its own
  path, and shells out to `git ls-files`, so a Hackage tarball (which cannot
  include `scripts/`) fails the suite with "record migration inventory
  generator is not available", and `python3` is undeclared. The suite already
  reached across to `../keiro-core` at 0.14.0.0, so this is not a regression in
  kind, but it is worth a `pendingWith` when the generator is absent given that
  `keiro-test-support` was published precisely so the suites build from
  tarballs.

## Evidence

- `python3 scripts/generate-record-migration-manifests.py --check` exited 0
  at the reviewed commit; the package inventory header reports 288
  declarations, 1,412 fields, 1,374 strict fields, and 1,293 publicly
  exported fields.
- `unBehaviorKey`, `unJsonPointer`, `unHaskellTypeOccurrence`,
  `unOutputObligationKey`, `unLoc`, `unRuntimePackageName`,
  `unQualifiedValueName`, `unCanonicalTypeId`, `unBindingVersion`,
  `unCodecIdentity`, `unCodecVersion`, and `unMappedKey` are each defined by a
  positional constructor match and exported from an `exposed-modules` entry
  (`BehaviorCoverage`, `CodecCompare`, `ConsumerTypePlan`, `EventOutput`,
  `Grammar`, `RuntimePackage`, `TypeGraph`).
- `git diff keiro-0.14.0.0..HEAD -- 'keiro-dsl/test/**' ':!*.hs' ':!*.cabal'`
  touches 76 `.txt` files whose unique hunk lines are exactly the
  `idiomatic-v1` to `idiomatic-v2` ledger row and the three added
  extension lines; no golden, `.json`, or `.keiro` fixture changed.
- `scripts/check-extension-policy.sh` exited 0 and now checks both
  `keiro-dsl` stanzas for the record trio, the Fourmolu mirror in
  `nix/treefmt.nix`, and the absence of local record-default pragmas in
  package source and non-skeleton `Generated` modules.
- `cabal build all` exited 0 at the reviewed commit with no warnings in
  `keiro-dsl` source.
- `cabal sdist keiro-dsl` includes `record-field-migration-0.15.md` and
  `generated-haskell-edition-idiomatic-v2.md` as `extra-doc-files` but no
  `scripts/` entry.
- `just verify` exited 0 at the reviewed commit (started 2026-08-26T23:26:22Z, finished 23:40:13Z): 49 of 49 test suites passed with zero failures, including 712 `keiro-dsl-test` and 620 `keiro-test` examples, the jitsurei walkthrough and diagram check, the conformance-corpus replay check (39 of 39, frozen skeleton corpus verified only), the extension and generated-name policies, and `keiro-migrations-test`.
