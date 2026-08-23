---
id: 177
slug: modernize-keiro-dsl-records-and-field-access
title: "Modernize keiro-dsl records and field access"
kind: exec-plan
created_at: 2026-08-01T20:05:19Z
intention: "intention_01kyzdr07ge299bk2axrgwssht"
master_plan: "docs/masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md"
---

# Modernize keiro-dsl records and field access

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Status: Revived on 2026-08-23 at the maintainer's direction after being cancelled before
implementation on 2026-08-01. The completed language-frontend work remains intact; this plan is now
an independently reviewable, post-frontend API modernization targeting the next PVP-breaking
release after the current `keiro-dsl` 0.14.0.0 baseline, provisionally 0.15.0.0.

After this change, every repository-authored component that imports either the `shared` or
`generated-output` stanza in `keiro-dsl/keiro-dsl.cabal` compiles with the record trio
`DuplicateRecordFields`, `NoFieldSelectors`, and `OverloadedRecordDot`. `DuplicateRecordFields` is
already a `shared` default, so the new compiler constraints and almost all migration cost come from
`NoFieldSelectors`; record-dot supplies the concise replacement for ordinary reads. Product records
owned by `keiro-dsl/src` and `keiro-dsl/app` use concise semantic field labels instead of datatype
prefixes. Product-record selector functions disappear from the public Haskell API. Callers use
record-dot for reads and continue to construct and pattern-match exported constructors with record
syntax. Intentionally public single-field newtype unwrappers such as `unLoc` remain ordinary
explicitly defined functions.

Scaffolded Haskell adopts the same record-access model through a new `idiomatic-v2` generated-
Haskell presentation edition. Its generated Cabal manifest supplies `DuplicateRecordFields`,
`NoFieldSelectors`, `OverloadedRecordDot`, and `OverloadedStrings`; overwriteable `Generated`
modules use concise repeated labels, record-dot reads, and constructor-directed patterns. Generated
newtype unwrappers remain explicit functions. Ordinary
scaffolding never silently upgrades an `idiomatic-v1` workspace: the edition change requires an
explicit, backup-backed adoption path, and create-once Hole bodies remain hand-owned.

A user can observe the result by importing two records that both contain labels such as `name`,
`span`, `source`, or `value`, constructing and matching both without selector ambiguity, while a
direct selector-function application is no longer part of the package or `idiomatic-v2` generated
API. The Keiro DSL source language, semantic values, parser and renderer function signatures, JSON
and wire keys, CLI text and JSON, fingerprints, diff/replay results, and runtime behavior remain
identical to their pre-migration oracles. Existing field strictness and deriving behavior are
preserved unless a separately justified row says otherwise, so this plan does not hide an
evaluation-strategy cleanup inside the selector break. Generated Haskell bytes and Haskell-facing
field names intentionally change only inside the reviewed `idiomatic-v1` to `idiomatic-v2` map;
their runtime and external identities do not. This is a PVP-breaking Haskell source migration and
a generated-Haskell presentation-edition migration, not a `.keiro` language, data, or wire-format
migration.


## Progress

- [x] Revived the plan, refreshed it from the completed frontend and the 0.14.0.0 package surface,
  and recorded a read-only compiler probe and preliminary record inventory (2026-08-23).
- [ ] Milestone 1: replace the preliminary scans with exhaustive package and generated-Haskell
  migration manifests and freeze every non-selector observation that a rename could affect.
- [ ] Milestone 2: modernize `Grammar`, the public frontend/language boundary, naming, and semantic
  contract records while keeping the package buildable at family boundaries.
- [ ] Milestone 3: modernize analysis, reports, generation planning, workspaces, CLI options, tests,
  and the remaining package-authored record families; then enable `NoFieldSelectors` in `shared`.
- [ ] Milestone 4: introduce `idiomatic-v2`, migrate the generator and complete tracked generated
  corpus, and enable the record trio in the generated manifest and `generated-output`.
- [ ] Milestone 5: implement explicit backup-backed edition adoption, prove old-edition consumer
  compatibility, and produce compiler-guided remediation for hand-owned Hole modules.
- [ ] Milestone 6: audit registered downstream projects, publish both migration guides, distill the
  durable policies into ADRs, and pass release-quality checks.


## Surprises & Discoveries

- Observation: `DuplicateRecordFields` is already listed in `keiro-dsl/keiro-dsl.cabal`'s
  `common shared` stanza.
  Evidence: The 0.14.0.0 manifest lists it before `ImportQualifiedPost`, `LambdaCase`,
  `OverloadedLabels`, and `OverloadedStrings`.
  Impact: The proposed default-set change is not two extension adoptions. It is one new extension,
  `NoFieldSelectors`, plus the source and public-API migration that makes it compile.

- Observation: A temporary `NoFieldSelectors` entry in `common shared` does not compile today.
  Evidence: On GHC 9.12.4, `cabal build keiro-dsl:lib:keiro-dsl --keep-going` stopped first in
  `Keiro.Dsl.Grammar` with six suppressed-selector errors (`rmSupply`, `erName`, and `erVersion`)
  and in `Keiro.Dsl.HaskellName` with six more (`siteLogicalName`, `lowerCamel`,
  `plannedOccurrenceKey`, and `plannedOccurrenceSite`). Removing the temporary entry restored the
  ordinary 77-module library build to green.
  Impact: The Cabal edit is trivial but cannot land independently. Those twelve diagnostics are
  only the first blockers in the dependency graph, not an estimate of the total edit count.

- Observation: The current surface is much larger than the cancelled 0.7-era draft assumed.
  Evidence: A preliminary lexical scan of `keiro-dsl/src` and `keiro-dsl/app` found 77 production
  Haskell files, 76 exposed modules, 53 files containing record declarations, approximately 294
  record-constructor blocks and 1,412 field declarations, of which approximately 1,374 are already
  strict. It also found 59 record-update candidates across 16 files. Four production modules and
  two test modules already declare `NoFieldSelectors` locally.
  Impact: This is a large mechanical/public-API migration, not a low-cost compiler-policy toggle.
  The counts are reconnaissance only; Milestone 1 must replace them with a reviewed exact manifest.

- Observation: The frontend modules already prove the desired construction and matching style,
  but they still consume selectors generated by older record modules.
  Evidence: `Keiro.Dsl.Source`, `Keiro.Dsl.SourceIndex`, `Keiro.Dsl.Syntax`, and
  `Keiro.Dsl.Frontend.Internal` compile with local `NoFieldSelectors` and use constructor-directed
  puns. `SourceIndex` still calls selectors such as `specNodes`, `aggName`, and `stName` from
  `Keiro.Dsl.Grammar`.
  Impact: Existing local examples reduce design risk but do not make the shared flip incremental;
  provider and consumer modules must be migrated together in dependency-aware families.

- Observation: `keiro-dsl` currently has no production import of `Data.Generics.Labels` and no
  `generic-lens` or `lens` dependency.
  Evidence: Source and Cabal searches on 2026-08-23 returned no matches.
  Impact: The migration can remain dependency-free and avoid introducing generic-lens's orphan
  `IsLabel` instance into Keiki-facing import closures. Any exception requires new registry and
  upstream release verification plus an explicit isolation proof.

- Observation: A public newtype unwrapper can keep the same spelling as its record label under
  `NoFieldSelectors`, but the implementation must not mention that label ambiguously.
  Evidence: A GHC 9.12.4 `-Wall -fno-code` probe compiled
  `newtype Loc = Loc {unLoc :: Int}` plus `unLoc (Loc value) = value` and the export list
  `Loc (..), unLoc`; a record-pun implementation was ambiguous.
  Impact: Package and generated emitters use positional matching for explicit newtype unwrappers
  and include their signatures in their respective compile probes.

- Observation: Generated Haskell is broad but centrally replaceable.
  Evidence: The tracked conformance corpus contains 487 generated Haskell modules, 42 generated
  files with record declarations, 34 generated newtype declarations, and 783 record-dot selection
  sites. Thirty-seven generated modules request `DuplicateRecordFields` locally and 117 request
  `OverloadedRecordDot`; 91 tracked Haskell files are create-once Hole or other consumer-owned
  sources rather than overwriteable `Generated` modules.
  Impact: The fixture diff will be large, but most edits belong in a small number of emitters and
  are reproduced by regeneration. The manual-risk inventory is the much smaller hand-owned set.

- Observation: Record-dot works with `NoFieldSelectors`, while current generated direct selector
  calls fail at compile time.
  Evidence: A GHC 9.12.4 `-Wall -fno-code` probe compiled `readFoo record = record.foo` for a record
  declared under both extensions. A temporary promotion in `common generated-output` then failed a
  representative 19-module behavior conformance target on direct calls such as
  `sourceFile location` and `ShapeStartPayload.label shape`; generated record-dot users and the
  hand-owned `Holes` module compiled before those failures. Restoring the current stanza returned
  the target to green.
  Impact: Generator changes are mechanical and compiler-enforced: use record-dot or patterns for
  product fields and positional definitions for explicit newtype accessors. There is no silent
  fallback to the wrong field.

- Observation: GHC2024 does not provide `OverloadedRecordDot`, and keeping it local would preserve
  substantial generated pragma noise.
  Evidence: A GHC 9.12.4 probe using only `GHC2024` and `NoFieldSelectors` rejected `record.foo`;
  adding `OverloadedRecordDot` compiled. The tracked corpus already has 783 dot selections and 117
  generated modules with a local record-dot pragma.
  Impact: `OverloadedRecordDot` belongs in both record-default stanzas and the `idiomatic-v2`
  manifest. The v2 generator removes those 117 redundant local pragmas. This decision does not
  enable `OverloadedRecordUpdate`.

- Observation: Mori has no package-specific reverse dependency registered for
  `mori://shinzui/keiro/packages/keiro-dsl`, while several projects carry only coarse project-level
  references to `mori://shinzui/keiro`.
  Evidence: `mori registry dependents shinzui/keiro:keiro-dsl --packages --json` returned an empty
  array; the project-level query returned multiple registered projects.
  Impact: Absence of a package-specific registry edge is not proof that selectors are unused.
  Milestone 6 must inspect each coarse registered dependent and record whether it imports
  `keiro-dsl` or only another Keiro package.

- Observation: Only the original DSL had downstream users when this plan was first written;
  released language versions 2 and 3 had no adopters at that time.
  Evidence: Maintainer report on 2026-08-01.
  Impact: Preserve every released language and generated contract, but do not infer current
  downstream selector usage from that historical adoption statement; use the refreshed audit.


## Decision Log

- Decision: Revive EP-177 after EP-176 rather than inserting it back between the 0.7 oracle and the
  frontend plans.
  Rationale: EP-173 through EP-176 are complete and define the current package architecture. The
  record migration must include those landed modules and preserve their final frontend contracts.
  Date: 2026-08-23

- Decision: Supersede the initial revival boundary that changed only `common shared`. Apply
  `DuplicateRecordFields`, `NoFieldSelectors`, and `OverloadedRecordDot` to both package-authored
  and newly generated records under their independently tested Cabal contracts.
  Rationale: The generator already centralizes overwriteable source and record-dot works under
  `NoFieldSelectors`; postponing it would create more generated APIs and hand-owned consumers to
  migrate later. Keeping separate `shared` and `generated-output` stanzas still preserves ADR 19's
  ownership boundary without preserving different record models.
  Date: 2026-08-23

- Decision: Use record-dot as the ordinary product-field read syntax, while retaining patterns for
  destructuring and positional bridging; do not enable `OverloadedRecordUpdate`.
  Rationale: `value.field` preserves direct readable access without recreating top-level selector
  functions and lets GHC resolve repeated concise labels from the record type. Record update has a
  separate, more invasive contract and is unnecessary for this migration.
  Date: 2026-08-23

- Decision: Introduce `idiomatic-v2` as an explicit generated-Haskell presentation edition and
  require opt-in, backup-backed adoption from `idiomatic-v1`.
  Rationale: Generated product selectors and field names are Haskell source API. Ordinary
  regeneration may replace `Generated` modules but must not strand a project by silently changing
  imports used by hand-owned Hole modules. An edition row, preflighted write set, durable backups,
  and a remediation report make the break attributable and recoverable.
  Date: 2026-08-23

- Decision: Remove automatically generated product-record selector functions rather than retain
  deprecated aliases for the old or new field names.
  Rationale: Aliases would preserve the broad ambiguous API and make the shared
  `NoFieldSelectors` policy cosmetic. A complete migration table plus a PVP-breaking release gives
  callers a checked boundary.
  Date: 2026-08-23

- Decision: Preserve deliberately public newtype unwrappers as explicit functions with their
  existing descriptive `unTypeName` names.
  Rationale: `NoFieldSelectors` also suppresses a newtype's automatically generated selector, but
  unwrapping a nominal value is a small intentional API rather than accidental access to one field
  of a product. Defining the function explicitly preserves that distinction and lets its signature
  remain in the public compile probe.
  Date: 2026-08-23

- Decision: Use record-dot for ordinary reads and constructor-directed pattern matching, field
  puns, record construction, and small explicit semantic helper functions for destructuring and
  transformations. Do not add generic-lens or lens dependencies by default, and remove
  package-owned record-update syntax where the checked manifest identifies it.
  Rationale: These mechanisms work with the record trio without an orphan `IsLabel` instance.
  Reconstructing a value explicitly is verbose in some modules but keeps Keiki label resolution
  and module import closures predictable.
  Date: 2026-08-23

- Decision: Never import `Data.Generics.Labels` from a prelude, record-definition module,
  generated module, or module visible to a Keiki-facing consumer. An isolated exception must be
  justified in the migration manifest and must receive verified current dependency bounds.
  Rationale: The registered record convention
  `mori://shinzui/haskell-jitsurei/docs/core-record-patterns` documents that generic-lens supplies
  an orphan `IsLabel` instance whose visibility is transitive and can change Keiki's bare-label
  resolution.
  Date: 2026-08-01; reaffirmed 2026-08-23

- Decision: Preserve every external serialization key and rendered artifact explicitly instead of
  deriving those schemas from renamed Haskell labels. Generated Haskell bytes may change only in
  the reviewed `idiomatic-v1` to `idiomatic-v2` presentation map.
  Rationale: The intended Haskell cleanup must not silently become a wire-format, `.keiro`
  language, fingerprint, CLI, or runtime change. ADR 21 independently separates DSL identity,
  generated selector identity, and wire identity for scaffold output.
  Date: 2026-08-01; revised 2026-08-23

- Decision: Preserve existing strictness and deriving behavior during this migration; do not use
  the selector break for a package-wide evaluation-strategy cleanup.
  Rationale: A bang pattern changes when a bottom or expensive thunk is evaluated even when all
  serialized and total-value observations are equal. Isolating field naming and access makes both
  package and generated-project compatibility easier to prove. Any strictness modernization can
  be proposed separately with its own semantic evidence.
  Date: 2026-08-23

- Decision: The 2026-08-01 cancellation is superseded. The plan remains independent of the
  language frontend even though it stays registered under MasterPlan 28.
  Rationale: The original cancellation correctly protected the frontend critical path. Reviving
  the cleanup after that path completed gains the intended record API without reopening parser
  architecture work.
  Date: 2026-08-23


## Outcomes & Retrospective

The plan was cancelled before production changes on 2026-08-01, then revived on 2026-08-23. The
completed frontend delivered concise `NoFieldSelectors` records in four production modules, but
the package-wide API remains on its historical prefixed selector surface and the shared Cabal
stanza still lacks `NoFieldSelectors`.

The revival reconnaissance establishes the cost shape: the package manifest edit is one line
because `DuplicateRecordFields` is already present, while the implementation spans dozens of
record-owning modules, public selector removal, a large internal consumer rewrite, a generated-
Haskell edition change, JSON/render/wire proofs, and a downstream audit. The generated corpus is
large at 487 tracked modules but overwriteable; the safety-sensitive surface is direct
`keiro-dsl` callers plus 91 hand-owned conformance/consumer modules. No production source or Cabal
change remains from either compiler probe, and both the ordinary library and the restored
representative generated conformance target are green. Implementation outcomes, exact field and
selector counts, downstream migrations, test totals, and ADR distillation remain pending.


## Context and Orientation

`keiro-dsl/keiro-dsl.cabal` is currently version 0.14.0.0 and targets GHC 9.12. Its `common shared`
stanza supplies GHC2024 plus `DuplicateRecordFields`, `ImportQualifiedPost`, `LambdaCase`,
`OverloadedLabels`, and `OverloadedStrings`. The library, executable, primary Hspec suite, three
focused source-sharing suites, and two benchmarks import this stanza. Generated conformance suites
instead import `common generated-output`, which currently supplies only GHC2024 and
`OverloadedStrings`; EP-177 deliberately changes that independent contract in sync with the
generated manifest and presentation edition.

`DuplicateRecordFields` permits the same field label in different datatypes. `NoFieldSelectors`
changes what a record declaration produces: record labels remain available for construction,
patterns, and updates, but GHC does not generate ordinary selector functions for records declared
in that module. It does not suppress selector functions imported from a dependency or another
module that was compiled with `FieldSelectors`. Therefore the migration must remove uses of each
package-owned selector after changing its defining module; imported dependency APIs are not
automatically affected.

The central public record graph is `keiro-dsl/src/Keiro/Dsl/Grammar.hs`. It exports most datatypes
with constructors and fields through `Type (..)`, and validation, generation, pretty printing,
diffing, replay, workspaces, and the modular parser consume those fields. Other large record
surfaces include `LanguageVersion.hs`, `TypeGraph.hs`, `Coverage.hs`, `CodecCompare.hs`,
`Scaffold.hs`, `ScaffoldRun.hs`, `Workspace.hs`, `WorkspaceRecord.hs`, and `app/Main.hs`.
`keiro-dsl/test/Keiro/Dsl/FrontendPublicApiProbe.hs` deliberately pins representative public
selector signatures from the 0.7 release in addition to stable parser and renderer functions.
This plan must preserve the function probes, move removed product selectors into the exhaustive
migration manifest, and keep explicit newtype accessor probes compiling.

Four landed frontend modules already show the target semantics. `Keiro.Dsl.Source` defines
`SourcePoint {offset, line, column}`, `SourceSpan {source, start, end}`, and
`Located {span, value}` with `NoFieldSelectors`; it exposes semantic functions such as `startLine`
and manipulates records by patterns and construction. `SourceIndex`, `Syntax`, and
`Frontend.Internal` follow the same style. The rest of the package still generates selectors and
often uses datatype-prefixed labels such as `idName`, `aggName`, `wfKey`, `rmName`, and
`siteLogicalName`.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) keeps
`Grammar.Spec` as the normalized semantic graph, with source evidence beside rather than inside it.
The record migration may rename Haskell labels but must not change this graph's semantic meaning,
location-insensitive equality, or source-index join. [ADR 19](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
owns scaffolded Haskell's extension and presentation edition; Milestones 1 and 4 must amend it for
`idiomatic-v2`. [ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
owns backup-backed generated-source migration and must be extended without weakening the create-
once boundary. [ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
keeps Hole behavior hand-owned. [ADR 21](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)
keeps generated Haskell selectors independent from DSL and wire identities. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires those identities and their external compatibility observations to remain at their current
validation and diff boundaries.

The cross-repository record convention is
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`. Its source is registered under
`shinzui/haskell-jitsurei`; it prefers concise shared labels, strict fields, explicit deriving
strategies, and `Generic`, while warning that generic-lens labels can conflict with Keiki. This
plan adopts its naming/access model but preserves current strictness and deriving behavior to keep
the break single-purpose. No local ADR currently defines the package-authored `keiro-dsl` record
API. Milestone 6 records that policy and amends ADRs 15 and 19 with the proven generated-edition
and adoption contract.


## Plan of Work

Milestone 1 produces two auditable migration contracts before renaming anything. Create
`keiro-dsl/record-field-migration-0.15.md` for every product record and record-style newtype in
`keiro-dsl/src`, `keiro-dsl/app`, and package-owned test support that imports `shared`. Create a
second `idiomatic-v1` to `idiomatic-v2` table for every generated declaration, direct selector use,
newtype accessor, local record extension, manifest default, and hand-owned module that consumes a
generated field. Each table records current and target spellings, API exposure, current strictness
and deriving behavior, selection replacement, and every JSON, text, canonical, fingerprint,
scaffold-ledger, CLI, wire, or runtime observation that must remain stable. Include unchanged rows
so omissions are visible.

Turn the current frontend compatibility probe into package and generated-project authorities
without weakening it. Stable functions such as `parseSource`, `parseSourceDocument`, `parseSpec`,
`renderSource`, and `lookupSourceSpan` remain compile-time assignments. Removed product selectors
move into the migration documents with replacement patterns. Add decoded-shape and exact-byte
goldens for the production Aeson modules and existing CLI/report/workspace fixtures. Freeze one
complete `idiomatic-v1` consumer project that must still compile against the new package release,
plus an `idiomatic-v2` counterpart whose generated files, Hole modules, manifest, and ledger prove
the complete adoption path. Generated-byte changes are accepted only when a migration-table row
explains them.

Milestone 2 migrates the semantic foundation in compiling families. Begin with
`HaskellName.hs`, `Grammar.hs`, `LanguageVersion.hs`, `SemanticContract.hs`, `Source.hs`,
`SourceIndex.hs`, `Syntax.hs`, `Frontend/Internal.hs`, and the modular parser consumers. Rename
redundant product fields to the checked semantic labels while preserving constructor names,
constructor order, field order, strictness, deriving behavior, every custom instance, `Loc`
equality, and every semantic helper. Migrate call sites to constructor-directed patterns and
construction before enabling `NoFieldSelectors` for a provider. At each family boundary, build the
library and run the focused frontend, public API, parse/pretty, and generated-byte checks.

Milestone 3 applies the same manifest-driven conversion to type resolution, validation,
expression planning, coverage, reports, diff/replay analysis, generation planning, scaffold
records, workspace modules, `app/Main.hs`, primary tests, focused tests, and benchmarks. Keep
explicit Aeson key strings and schema identifiers byte-stable. Remove package-owned record-update
sites by reconstructing through named helpers or constructor patterns where that improves clarity;
do not introduce generic-lens merely to shorten a mechanical reconstruction. Then add
`NoFieldSelectors` and `OverloadedRecordDot` to `common shared` beside the existing
`DuplicateRecordFields`, remove redundant local pragmas, and enforce the policy. Define explicit
functions for public newtype unwrappers.
`NoFieldSelectors` permits the explicit function to retain the field label's spelling, while a
positional constructor match avoids an ambiguous field occurrence in the function body:

```haskell
newtype Loc = Loc {unLoc :: Int}
  deriving stock (Show)

unLoc :: Loc -> Int
unLoc (Loc value) = value
```

Update `scripts/check-extension-policy.sh` with a `keiro-dsl`-specific assertion that `shared`
contains the record trio and that package-owned source importing that stanza has no local
`FieldSelectors` escape hatch or redundant record-default pragma. Run a clean compiler pass and
treat every GHC-88464 suppressed-selector diagnostic as a missed migration row rather than adding
an escape hatch.

Milestone 4 implements `idiomatic-v2` in the generator. Promote `DuplicateRecordFields`,
`NoFieldSelectors`, and `OverloadedRecordDot` into the typed generated manifest and
`common generated-output`. Rewrite generated product access to record-dot or constructor-directed
patterns; replace composition and higher-order selector uses with explicit typed lambdas where
that is clearer. Emit explicit positional newtype accessors and remove redundant local
`DuplicateRecordFields` and `OverloadedRecordDot` pragmas. Regenerate the complete tracked corpus
and review every changed byte against the edition table. Update the closed extension policy,
manifest fixtures, standalone conformance packages, and ADR 19 together.

Milestone 5 makes edition adoption recoverable for existing projects. Ordinary scaffold runs on an
`idiomatic-v1` ledger refuse before writes and print the exact generated, manifest, and hand-owned
source impact. An explicit `--apply-generated-haskell-edition` path completes all preflights,
prepares the full deterministic write set, and moves the old generated tree and sidecars under a
durable `idiomatic-v1-to-idiomatic-v2` backup before installing new bytes. It never rewrites Hole
bodies. Instead it emits a stable remediation report mapping every detected old product-selector
use to a positional pattern/construction bridge for renamed labels, record-dot for unchanged labels,
or an explicit preserved newtype accessor. Constructor names, arity, and field order remain stable
across the edition so attributed Hole code can be made dual-compatible before apply. Unresolved
hand-owned uses remain ordinary compiler errors. Reruns resume or refuse from recorded digests, and
the migration guide includes a tested rollback. Amend ADR 15 without weakening its create-once
ownership rule.

Milestone 6 turns both source refactors into a releasable API change. Update
`keiro-dsl/CHANGELOG.md` and user/contributor documentation with the complete package-selector and
generated-edition mappings, explicit newtype accessor lists, and the statement that construction
and matching remain supported. Use Mori's project and package reverse-dependency views, then
inspect each coarse project-level dependent at its registered path and record actual `keiro-dsl`
or generated-API use with canonical `mori://` project or package references. Do not modify another
repository under this plan. Finish the ADR distillation pass and the complete build, test, format,
sdist, and flake checks.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Refresh the inventory before implementation:

```bash
mori registry show shinzui/keiro --full
mori registry dependents shinzui/keiro:keiro-dsl --packages --json
rg -n '^data |^newtype ' keiro-dsl/src keiro-dsl/app keiro-dsl/test
rg -n '^\s*[,{]?\s*[a-z][A-Za-z0-9_]*\s*::' keiro-dsl/src keiro-dsl/app
rg -n 'ToJSON|FromJSON|toJSON|parseJSON|\.=' keiro-dsl/src keiro-dsl/app
rg -n 'Data\.Generics\.Labels|^import .*Keiki|#[_A-Za-z]' keiro-dsl/src keiro-dsl/app keiro-dsl/test
rg -n '\b[a-z][A-Za-z0-9_]*\s*\{\s*[a-z][A-Za-z0-9_]*\s*=' keiro-dsl/src keiro-dsl/app
rg -n '^data |^newtype |\{[^}]+::' keiro-dsl/test --glob 'Generated/**/*.hs'
rg -n 'LANGUAGE (DuplicateRecordFields|OverloadedRecordDot)|\.[a-z][A-Za-z0-9_]*' keiro-dsl/test --glob 'Generated/**/*.hs'
rg -n '(Holes|BehaviorHoles|Bindings)' keiro-dsl/test --glob '*.hs'
```

The `rg` output is a seed, not the manifest authority. Review it against every record declaration,
module export list, explicit public function, and call site. Record exact final counts in the
living sections. During each module-family conversion run:

```bash
cabal build keiro-dsl:lib:keiro-dsl keiro-dsl:exe:keiro-dsl
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='frontend 0.7 compatibility'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='record API migration'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='JSON contracts'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='generated Haskell language'
```

If a named focused group does not yet exist, Milestone 1 creates it before production renames. At
the shared-default cutover run the ordinary build without a global command-line extension override;
the Cabal stanza itself must provide the proof:

```bash
cabal build keiro-dsl:lib:keiro-dsl keiro-dsl:exe:keiro-dsl
cabal test keiro-dsl-test keiro-dsl-import-planning-test keiro-dsl-haskell-name-test keiro-dsl-runtime-vocabulary-test --test-show-details=direct
bash scripts/check-extension-policy.sh
```

At the generated-edition cutover, regenerate every conformance history and compile both frozen
edition fixtures through their advertised manifest defaults. Do not pass the record extensions on
the command line; the manifests and Cabal stanzas are the objects under test:

```bash
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='generated Haskell edition'
cabal build keiro-dsl:keiro-dsl-conformance-behavior-complete
cabal build keiro-dsl:keiro-dsl-conformance-aggregate-scalars
bash scripts/check-extension-policy.sh
```

Finish with the repository's release-quality matrix:

```bash
cabal test all --test-show-details=direct
cabal build all
cabal sdist keiro-dsl
nix fmt -- --ci
nix flake check
git diff --check
```

The expected result is zero compiler warnings promoted by existing policy, zero missing migration
rows, no changed JSON/rendered/wire bytes outside the explicitly approved Haskell presentation
map, and successful compilation of downstream-style pattern construction, record-dot selection,
preserved manual newtype accessors, frozen `idiomatic-v1`, and migrated `idiomatic-v2` projects.


## Validation and Acceptance

Acceptance requires `keiro-dsl/keiro-dsl.cabal` to list `DuplicateRecordFields`,
`NoFieldSelectors`, and `OverloadedRecordDot` under `common shared` and `common generated-output`,
and the generated manifest to advertise the same record trio. Neither package-authored nor
`idiomatic-v2` generated code has a `FieldSelectors` escape hatch or a redundant local record-
default pragma. Every package and generated field is accounted for in the migration manifests; no
field retains an owner prefix solely to avoid a selector collision.
Existing strictness, deriving clauses, constructor order, and field order remain unchanged unless
an individually justified migration row proves otherwise.

An external-style compile fixture must construct and pattern-match representative records from
`Grammar`, `LanguageVersion`, `Source`, reports, workspaces, and the CLI-facing library surface
without using generated selector functions. Every intentionally public newtype unwrapper keeps its
documented signature as an explicit function. The old selector portion of
`FrontendPublicApiProbe` is replaced only after the exhaustive manifest names each removal;
parser, renderer, source-index, and other deliberate function signatures remain pinned.

All source-language versions keep their acceptance, rejection, semantic graph, canonical pretty
output, diagnostics, and exact source-index behavior. JSON schemas and bytes, CLI output, semantic
workspace/scaffold ledger content, fold and canonical fingerprints, diff/replay results, and
runtime behavior remain unchanged. Generated Haskell bytes, presentation-edition rows, manifest
defaults, and Haskell field APIs change only as enumerated by the `idiomatic-v2` migration table.
ADR 21's DSL/selector/wire identity separation remains true. A frozen `idiomatic-v1` project builds
against the new release without adoption; an explicit adoption produces the reviewed v2 tree,
leaves Hole bytes untouched, reports every required hand edit, and can be rolled back from durable
backups.

The downstream audit accounts for every Mori-registered package-specific or coarse project-level
dependent and uses canonical `mori://` references in durable documentation. The plan is not
complete if the audit treats an empty package-specific query as proof of no users, if a JSON golden
is refreshed without explaining the invariant, if `Data.Generics.Labels` enters a Keiki-facing
closure, or if a temporary selector alias or `FieldSelectors` pragma remains.


## Idempotence and Recovery

This is a source/API and generated-presentation refactor with no data migration. Apply package code
one record family at a time and keep both migration manifests synchronized with compiling
boundaries. Re-running inventory and tests is safe. Do not add `NoFieldSelectors` to either common
stanza until its provider and consumer families have been migrated far enough for compiler output
to be a finite final checklist.

If a rename changes a JSON golden, parser result, rendered diagnostic, fingerprint, wire identity,
or CLI byte, restore the explicit external key or renderer at its owning boundary rather than
accepting a new baseline. A generated-file change is accepted only with an exact presentation-map
row. If either default flip exposes a missed selector, add the occurrence and its replacement to
the manifest, repair the caller, and retry; do not recover by adding `FieldSelectors`. If a
generic-lens experiment makes Keiki labels ambiguous, remove the orphan import and convert that
module to patterns, construction, or record-dot before proceeding.

A partially migrated package family should be returned to a compiling family boundary before
committing. A generated-edition migration completes its whole preflight before moving files,
retains digest-addressed v1 backups, never rewrites Hole bodies, and has a resumable or refusing
recovery state. The work is intentionally PVP-breaking, so recovery does not mean supporting old
and new product selector APIs indefinitely. Package callers can roll back to the previous release;
generated projects can additionally restore the recorded v1 tree and sidecars.


## Interfaces and Dependencies

The target product-record model is:

```haskell
data IdDecl = IdDecl
  { name :: !Name,
    prefix :: !Text,
    binding :: !(Maybe NominalBindingDecl),
    loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data SourcePoint = SourcePoint
  { offset :: !Int,
    line :: !Int,
    column :: !Int
  }
  deriving stock (Eq, Ord, Show, Generic)
```

Explicit semantic helpers such as the existing `externalReadNodeIdentity` remain appropriate when
an operation deserves a stable name independent of storage layout. A one-field read under a new
name is still a selector alias and is not added. Ordinary reads use record-dot:

```haskell
renderId :: IdDecl -> Text
renderId declaration = declaration.name <> ":" <> declaration.prefix
```

Constructor patterns remain appropriate when several fields are destructured or when a generated
consumer needs a positional bridge across an edition rename. Record construction and matching
remain public when a constructor is exported. Automatic product selectors do not. Record update
syntax is not the target package style; reconstruct values or use a small semantic helper, without
enabling `OverloadedRecordUpdate`. Generated Haskell retains its independently advertised ADR-19
contract, but `idiomatic-v2` shares the same ambient record trio. The generator's field labels are
Haskell presentation and may become concise; their DSL and wire identities remain separate under
ADR 21.

No new package dependency is required. The governing cross-repository guide is
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`. If an isolated generic-lens exception
is ever proposed, locate its source and docs with Mori, then verify released versions through the
authoritative registry and upstream tags before choosing bounds. That exception must be limited to
the importing component and must not enter a Keiki-facing transitive import closure.


## Revision Note

2026-08-01: Cancelled the original 0.7-era plan before implementation so MasterPlan 28 could focus
on the source-aware frontend. No production record change landed from the cancelled draft.

2026-08-23: Revived the plan at the maintainer's direction as a post-EP-176, next-breaking-release
work stream. Refreshed all sections for `keiro-dsl` 0.14.0.0, made the already-present
`DuplicateRecordFields` versus new `NoFieldSelectors` cost explicit, incorporated the landed
frontend record examples and ADRs 19/21, added compiler and inventory evidence, protected generated
output, and expanded validation to public API, downstream, release, and ADR-distillation gates.

2026-08-23: Superseded the initial generated-output exclusion after maintainer review. Added the
`idiomatic-v2` generated-Haskell presentation edition, the record trio in its manifest,
generator-driven corpus regeneration, explicit backup-backed adoption, unchanged create-once Hole
bodies, frozen-v1/new-v2 consumer proofs, and rollback guidance. Narrowed the migration by
preserving existing strictness and deriving behavior instead of combining an evaluation change
with the selector break.

2026-08-23: Promoted `OverloadedRecordDot` into both target defaults and the `idiomatic-v2`
manifest after a GHC 9.12.4 probe confirmed GHC2024 alone does not provide dot selection under
`NoFieldSelectors`. Made record-dot the ordinary read syntax, removed v2 local record-dot pragmas,
and explicitly left `OverloadedRecordUpdate` out of scope.
