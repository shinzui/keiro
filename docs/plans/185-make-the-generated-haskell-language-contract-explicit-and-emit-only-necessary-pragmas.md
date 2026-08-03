---
id: 185
slug: make-the-generated-haskell-language-contract-explicit-and-emit-only-necessary-pragmas
title: "Make the generated Haskell language contract explicit and emit only necessary pragmas"
kind: exec-plan
created_at: 2026-08-03T13:50:54Z
intention: intention_01kz45h8xtedy8qnsarqhznvbp
---

# Make the generated Haskell language contract explicit and emit only necessary pragmas

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a consumer of `keiro-dsl` output can copy the generated build
manifest into a Cabal component and know the exact Haskell compilation contract:
`default-language: GHC2024` with `OverloadedStrings` as the one shared default
extension. Overwriteable generated modules will no longer repeat extensions already
provided by that contract. They will carry local pragmas only for specialized syntax
that is not part of GHC2024 and is not in the shared default.

This is observable in two ways. A scaffolded `keiro-dsl-manifest.<context>.txt` will
start with the language and default-extension declarations, and the checked-in
conformance corpus will compile under the same narrow Cabal profile instead of the
broader profile used to build `keiro-dsl` itself. Running the extension-policy check
will also reject a redundant or unapproved pragma in any overwriteable `Generated`
module. Create-once, hand-owned modules such as `Holes`, `BehaviorHoles`,
`ReadModelHoles`, and consumer binding skeletons are deliberately outside this cleanup
and retain their own pragmas.


## Progress

- [x] (2026-08-03) Audited every LANGUAGE pragma emitted for overwriteable
  `ScaffoldModule` values of kind `Generated`, distinguished GHC2024 members from
  specialized extensions, and excluded create-once `HoleStub` output.
- [x] (2026-08-03) Milestone 1: centralized and published the generated-Haskell compilation contract in
  the manifest and Cabal conformance profile.
- [x] (2026-08-03) Milestone 2: routed generated emitters through the restricted pragma renderer and
  remove or condition every redundant pragma identified in the audit.
- [ ] Milestone 3: add policy and conditional-emission regressions, regenerate only
  overwriteable conformance files, and compile all conformance components under the
  narrow generated-output profile.
- [ ] Milestone 4: document the consumer contract, record the durable decision in the
  ADR bundle, run the full validation matrix, and complete the retrospective.


## Surprises & Discoveries

- Observation: generated modules already depend on an ambient compilation contract,
  even though the generated manifest currently emits only `other-modules` and
  `build-depends`. Text literals throughout the output require `OverloadedStrings`, and
  many modules use syntax included by GHC2024. The repository's `common shared` Cabal
  stanza supplies both, so existing conformance targets conceal the omission from the
  consumer manifest.

- Observation: the checked-in conformance corpus contains 517 pragma lines in 194
  overwriteable generated modules at plan creation. The most common redundant entries
  are `DataKinds` (107), `TypeApplications` (64), `GADTs` (42), and `DeriveGeneric`
  (29). This makes regeneration and an automated policy gate safer than hand-editing
  selected fixtures.

- Observation: `DuplicateRecordFields` in an aggregate `Domain` module can be required
  by code that is not visible until Template Haskell runs. Keiki's
  `deriveWireCtorsAll` creates one `<Event>TermFields` record with the same selectors as
  each event payload record. The registered dependency is
  `mori://shinzui/keiki/packages/keiki`; within that package the evidence is in
  `src/Keiki/Generics/TH.hs` (an artifact-level URI for this source file is not yet
  defined).

- Observation: `scripts/check-extension-policy.sh` intentionally skips every path under
  `Generated`, so the existing global-extension policy cannot catch this class of
  drift. A generated-output allowlist is needed in addition to the existing hand-owned
  source policy.

- Observation: the live corpus had grown to 203 generated modules with 543 pragma
  lines before implementation began, compared with the plan-creation counts of 194 and
  517. The extension vocabulary was unchanged and the current emitter already included
  the intervening import-planning work, so implementation proceeded from the live tree
  and will regenerate from that merged emitter.

- Observation: the Milestone 1 pilot component
  `keiro-dsl-conformance-aggregate-scalar-expressions` immediately exposed the expected
  hand-owned reliance on `OverloadedLabels`. Adding only that local pragma to
  `keiro-dsl/test/conformance-scalar-expressions/Main.hs` let the component compile under
  `common generated-output`; no broad default was added to the consumer contract.

- Observation: refreshing the repository's generated pre-commit configuration caused
  the existing extension-policy hook to reject that planned local `OverloadedLabels`
  declaration, because the old policy assumed every hand-owned Haskell file inherited
  `common shared`. The policy now exempts exactly the four named narrow-profile drivers
  from the `OverloadedLabels` redundancy check while continuing to reject
  `ImportQualifiedPost` there and both global defaults everywhere else.

- Observation: the merged import-planning emitter renders mapped structural selectors
  as qualified ordinary functions such as `Shape.field shape`, not record-dot syntax.
  Consequently mapped structural codecs do not by themselves require
  `OverloadedRecordDot`; aggregate event encoders still require it whenever an event has
  fields. This is the current-tree result of preserving the work from ExecPlan 184.


## Decision Log

- Decision: define the generated-output compilation contract as GHC2024 plus the Cabal
  default extension `OverloadedStrings`.
  Rationale: `keiro-dsl` is tested only with GHC 9.12 through 9.12.x, GHC2024 already
  describes the syntax the output assumes, and string literals are pervasive enough
  that repeating `OverloadedStrings` in nearly every module would add noise without
  useful locality. `DuplicateRecordFields`, `OverloadedRecordDot`, and
  `OverloadedLabels` are common in the corpus but each corresponds to identifiable
  syntax in only some module families; keeping them local preserves useful evidence and
  lets the contract compilation test catch an emitter that forgets its requirement.
  Date: 2026-08-03.

- Decision: keep a module-local pragma only when an emitted module actually uses a
  non-contract extension. The approved local set is `BlockArguments`,
  `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
  `OverloadedRecordDot`, `QualifiedDo`, `TemplateHaskell`, and `TypeFamilies`.
  Rationale: these extensions are not supplied by GHC2024 plus `OverloadedStrings`.
  Conditional emission keeps each module honest while allowing consumers to understand
  exceptional syntax at the point of use.
  Date: 2026-08-03.

- Decision: do not anticipate a future GHC language edition by moving
  `DuplicateRecordFields` into today's GHC2024-based default-extension contract. If a
  later adopted edition includes it and Keiro raises `default-language` to that edition,
  remove the then-redundant local pragmas as part of the edition migration.
  Rationale: future inclusion is plausible but not part of GHC2024, and no generated
  file is maintained by hand. Local declarations preserve current-version correctness
  without imposing authoring cost or committing the consumer contract to an unfinalized
  edition.
  Date: 2026-08-03.

- Decision: keep promotion of a local extension into the shared contract mechanical and
  test-driven. If a future language edition includes the extension, raise
  `generatedHaskellDefaultLanguage` and the matching Cabal `default-language`, then
  remove the local constructor, emitter requests, predicates, policy entry, and generated
  fixture pragmas; do not also list an edition-provided extension under
  `default-extensions`. If Keiro promotes an extension without changing editions, add it
  to `generatedHaskellDefaultExtensions` and `common generated-output` before performing
  the same local cleanup.
  Rationale: the closed local-extension type, generated-output policy, fixture freshness
  tests, and independent conformance compile turn either form of promotion into a small
  synchronized edit whose omissions fail validation. The explicit distinction avoids
  carrying a redundant Cabal default after an edition upgrade.
  Date: 2026-08-03.

- Decision: apply this plan only to overwriteable modules represented by
  `ModuleKind Generated`. Do not remove or normalize pragmas in `HoleStub` modules,
  existing hand-owned conformance code, or create-once skeleton templates.
  Rationale: the user asked specifically about generated `keiro-dsl` code, and the
  ownership boundary promises that human-edited files are never rewritten by a later
  scaffold run.
  Date: 2026-08-03.

- Decision: compile every `keiro-dsl-conformance*` component under a narrow Cabal common
  stanza matching the emitted manifest, while leaving the generator library and its
  ordinary tests on the existing broader `common shared` stanza.
  Rationale: policy assertions catch text drift, but only an independent compile profile
  proves that the advertised defaults plus module-local exceptions are sufficient.
  Date: 2026-08-03.

- Decision: centralize the allowed module-local extensions in a private Haskell module
  and reject any other pragma in committed generated output.
  Rationale: removing today's redundant strings is not enough; a restricted renderer and
  an allowlist make future accidental reintroduction fail at review time.
  Date: 2026-08-03.

- Decision: permit a local `OverloadedLabels` pragma only in the four named hand-owned
  conformance drivers that compile under `common generated-output`; preserve the global
  redundancy rule for every other hand-owned file.
  Rationale: those drivers no longer inherit the generator's broad Cabal defaults, so
  the local declaration is necessary rather than redundant. A four-path exception keeps
  the existing source policy strict without falsely broadening the generated-output
  contract.
  Date: 2026-08-03.

- Decision: make `codecUsesRecordDot` follow the concrete syntax emitted by the merged
  import planner: it is true for field-bearing aggregate event encoders and false for a
  codec that only invokes module-qualified mapped-shape selectors.
  Rationale: `Shape.field shape` is ordinary module qualification and compiles without
  `OverloadedRecordDot`. Retaining the pragma for that case would contradict the plan's
  necessary-only contract and discard a useful consequence of ExecPlan 184.
  Date: 2026-08-03.

- Decision: preserve and integrate the in-progress import-planning work described by
  [ExecPlan 184](184-generate-idiomatic-haskell-imports-for-consumer-owned-types.md).
  Rationale: both plans touch `Keiro.Dsl.Scaffold` and generated fixtures. This plan may
  begin only from the then-current tree and must regenerate through the merged emitter,
  never restore or overwrite Plan 184's changes.
  Date: 2026-08-03.

- Decision: create a new ADR during implementation rather than forcing this contract
  into an ADR about source-language provenance or workspace identity.
  Rationale: no current ADR owns the compiler-edition/default-extension boundary for
  generated Haskell. The contract is durable consumer-facing architecture, not merely a
  task-local cleanup.
  Date: 2026-08-03.


## Outcomes & Retrospective

Milestone 1 is complete. `Keiro.Dsl.GeneratedHaskellLanguage` now owns the GHC2024 plus
`OverloadedStrings` baseline and the closed local-extension vocabulary. Both single-file
and workspace manifests emit that contract before their module and dependency blocks,
and `common generated-output` mirrors it for conformance compilation. The exact manifest
prefix is covered for ordinary aggregate, typed-contract, consumer-mapping, and workspace
paths.

Validation completed on 2026-08-03 with `cabal build keiro-dsl`, the 514-example
`cabal test keiro-dsl-test --test-show-details=direct` suite, and
`cabal test keiro-dsl-conformance-aggregate-scalar-expressions
--test-show-details=direct`; all passed. A CLI scaffold of `reservation.keiro` visibly
emitted `default-language: GHC2024` followed by the single `OverloadedStrings` default.
The scalar-expression driver was the first hand-owned file to need its planned additive
`OverloadedLabels` pragma after leaving `common shared`.

Milestone 2 is complete. Every raw LANGUAGE string left in
`Keiro.Dsl.Scaffold` belongs to a `HoleStub` create-once emitter; overwriteable modules
request extensions through `renderGeneratedLanguagePragmas`. The renderer deduplicates
and orders the closed extension set, and modules with no exceptions begin directly with
their generated banner. Source-local predicates now follow duplicate selectors,
record-dot reads, register comparisons, snapshot derivation, projection labels, and
read-model feed mode.

The focused command `cabal test keiro-dsl-test --test-option=--match
--test-option='generated Haskell language contract' --test-show-details=direct` passed
three examples covering the eight representative fixtures and positive/negative
conditional cases. `cabal build keiro-dsl` also passed. Committed generated fixtures have
not yet been changed; their freshness assertions will be restored by the controlled
Milestone 3 regeneration.

Before marking the plan complete, compare a freshly scaffolded manifest and generated
tree with the purpose above. Then distill the final language contract, local-exception
rule, and generated-versus-hand-owned boundary into a new ADR under `docs/adr/`, update
`docs/adr/log.md`, and record the resulting ADR link here.


## Context and Orientation

`keiro-dsl` turns checked `.keiro` specifications into Haskell source. In
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and
`keiro-dsl/src/Keiro/Dsl/Harness.hs`, a `ScaffoldModule` carries a path, emitted text,
and a `ModuleKind`. `Generated` means the tool owns and overwrites the file on later
scaffold runs. `HoleStub` means the tool creates the file only when it is absent and a
human owns it afterward. In this plan, “generated module” always means the former,
overwriteable kind, not every file that happened to be initially created by the CLI.

A Haskell compilation contract is the Cabal language edition and default extensions
that apply before a module's own `{-# LANGUAGE ... #-}` declarations. The current
`common shared` stanza in `keiro-dsl/keiro-dsl.cabal` sets `default-language: GHC2024`
and defaults `DuplicateRecordFields`, `ImportQualifiedPost`, `LambdaCase`,
`OverloadedLabels`, and `OverloadedStrings`. All current conformance components import
that broad stanza. By contrast, `renderManifestForService` in
`keiro-dsl/src/Keiro/Dsl/Manifest.hs` emits only `other-modules` and `build-depends`, so
a consumer following `docs/user/typed-spec-toolchain.md` is not told the language
assumptions needed to compile the output.

For the extensions that current emitters use, GHC2024 already includes `DataKinds`,
`DeriveGeneric`, `EmptyDataDecls`, `GADTs`, `ImportQualifiedPost`, `LambdaCase`, and
`TypeApplications`. It does not include `BlockArguments`, `DeriveAnyClass`,
`DuplicateRecordFields`, `OverloadedLabels`, `OverloadedRecordDot`,
`OverloadedStrings`, `QualifiedDo`, `TemplateHaskell`, or `TypeFamilies`. The plan puts
`OverloadedStrings` in the shared generated-output profile and leaves the other eight
available as local, usage-driven exceptions.

The audit below names emitter families because the context, aggregate, contract, queue,
or read-model name changes the concrete module name. “Conditional” means the emitter
must inspect the semantic input or the text it is about to emit; it must not preserve a
pragma merely because another instance of the same module family needs it.

| Generated module family | Current emitted pragmas | Required result under the contract |
| --- | --- | --- |
| Context `Nominals` | `DataKinds`, `DeriveAnyClass`, `DeriveGeneric`, `LambdaCase`, plus conditional `TypeApplications` and `TypeFamilies` | Conditional `DeriveAnyClass` only when a declaration has `deriving anyclass`; conditional `TypeFamilies` when equality witnesses emit associated type instances. |
| `Nominals.Internal` | `DeriveGeneric` | None. |
| `Nominal.Shape.<Name>` | `DeriveGeneric`, `LambdaCase` | None. |
| `NominalProjections` | `DataKinds`, `TypeApplications`, `TypeFamilies` | `TypeFamilies`. |
| `Structural.Shape.<Name>` | `DeriveGeneric`, conditional `DuplicateRecordFields` | None; each shape module declares one record type, so its selectors cannot collide locally. |
| `StructuralProjections` | `DataKinds`, `TypeApplications`, `TypeFamilies` | `TypeFamilies`. |
| Aggregate `BehaviorContract` | `DataKinds`, `OverloadedLabels` | Conditional `OverloadedLabels` when register comparisons emit `#field`. |
| Context `ReplayAudit` | `GADTs` | None. |
| Public integration `Contract` | unconditional `DuplicateRecordFields` and `OverloadedRecordDot`, plus conditional `DataKinds` and `TypeApplications` | Conditional `DuplicateRecordFields` only when payload record selectors collide; conditional `OverloadedRecordDot` when encoding reads one or more payload fields. |
| `Inbox` | `OverloadedStrings` | None; the manifest contract supplies it. |
| Workqueue `Queue` | `OverloadedRecordDot` | Conditional `OverloadedRecordDot` when payload or group-key code performs record-dot selection. |
| `ReadModel` | `OverloadedRecordDot` | Conditional `OverloadedRecordDot` only for subscription-fed models, whose idempotency key reads `recorded.eventId`. |
| Aggregate `Domain` | `DataKinds`, conditional `DeriveAnyClass`, conditional `EmptyDataDecls`, unconditional `DuplicateRecordFields`, `TemplateHaskell`, `TypeApplications` | `TemplateHaskell`; conditional `DeriveAnyClass` for snapshot derivations; conditional `DuplicateRecordFields` when source records or Keiki-generated event term records duplicate a selector. |
| Aggregate `Codec` | conditional `DataKinds`, `LambdaCase`, and `TypeApplications`, plus unconditional `OverloadedRecordDot` | Conditional `OverloadedRecordDot` when an emitted encoder or mapped codec reads a record field. |
| Aggregate `Transducer` | `BlockArguments`, `DataKinds`, `GADTs`, unconditional `OverloadedRecordDot`, conditional `OverloadedLabels`, `QualifiedDo`, `TypeApplications` | `BlockArguments` and `QualifiedDo`; conditional `OverloadedRecordDot` for emitted `d.field` reads; conditional `OverloadedLabels` for projection aliases. |
| Aggregate `Projection` | `OverloadedRecordDot` | None; it pattern matches events and constructs `InlineProjection` but does not select a field with record-dot syntax. |
| Aggregate `Harness` | `DataKinds`, `OverloadedLabels`, plus conditional `TypeApplications` | Conditional `OverloadedLabels` when assertions index one or more registers. |

Generated `CodecComparison`, `EventStream`, `Publisher`, `QueueCodec`, `QueuePolicy`,
`ReadModelTable`, `Router`, `Process`, `WorkflowFacts`, `WorkflowRuntime`, and the
non-aggregate harness families currently emit no LANGUAGE pragmas. They should continue
to emit none under the shared contract.

The excluded create-once emitters are easy to confuse with this list.
`emitBindingSkeleton`, `emitLegacyHoles`, `emitVersion2Holes`, behavior-hole emitters,
router/process/read-model holes, and all existing hand-filled modules are not cleanup
targets. Their current local pragmas remain untouched even when GHC2024 would make some
redundant. Four hand-owned conformance drivers currently use overloaded labels without a
local declaration:
`keiro-dsl/test/conformance-aggregate-scalars/Main.hs`,
`keiro-dsl/test/conformance-nominal-scalars/Main.hs`,
`keiro-dsl/test/conformance-scalar-expressions/Main.hs`, and
`keiro-dsl/test/conformance-structural/Main.hs`. They may receive only an additive
`OverloadedLabels` pragma so the narrowed test component continues to compile; do not
otherwise audit or clean them.

`keiro-dsl/test/Main.hs` contains emitter-level assertions and freshness checks that
compare fresh `ScaffoldModule` text with committed files.
`keiro-dsl/test/Keiro/Dsl/ConformanceBaseline.hs` and
`keiro-dsl/test/conformance-baseline.json` inventory all 33 compiled conformance
components, including source, workspace, skeleton, and compatibility cases. The
committed `keiro-dsl/test/conformance*/Generated/**/*.hs` trees are the actual output
compiled by those components. `scripts/check-extension-policy.sh` is invoked by the
`extension-policy` recipe in `Justfile`. `nix/treefmt.nix` intentionally excludes the
conformance generated trees from Fourmolu because they must stay byte-identical to raw
scaffolder output.

[ExecPlan 161](161-add-authoritative-typed-scalar-aggregate-expressions.md) established
the repository precedent that Cabal's GHC2024/default-extension profile is authoritative
and removed redundant `ImportQualifiedPost` and `OverloadedStrings` pragmas from
hand-written project modules. [ExecPlan 179](179-generate-one-human-readable-authoritative-keiro-transducer.md)
made the generated build manifest Cabal-pasteable and routed both single-file and
workspace scaffolding through `renderManifestForService`. [ExecPlan 183](183-make-language-4-the-stable-dsl-conformance-baseline.md)
created the current conformance inventory and generation modes. The number 4 in the DSL
source line `language keiro-dsl 4` is unrelated to GHC2024: one selects Keiro source
semantics, while the other selects a Haskell language edition. This plan applies the
Haskell contract to output from every supported Keiro source-language version.

The relevant durable decisions are [ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md),
which requires a single resolved authority for generated structural lowering;
[ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md),
which requires whole-workspace generation to be deterministic and ownership-aware; and
[ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md),
which makes overwriteable generated output distinct from create-once hand-owned files.
None of the current ADRs defines a GHC language/default-extension contract for generated
Haskell, so implementation must add a focused ADR rather than silently treating this
plan as the durable authority.


## Plan of Work

### Milestone 1: Establish one generated-Haskell contract

Add a private module at
`keiro-dsl/src/Keiro/Dsl/GeneratedHaskellLanguage.hs` and list it under the library's
`other-modules` in `keiro-dsl/keiro-dsl.cabal`. It will own the constants
`generatedHaskellDefaultLanguage = "GHC2024"` and
`generatedHaskellDefaultExtensions = ["OverloadedStrings"]`. It will also define the
closed `GeneratedHaskellExtension` type and the canonical pragma renderer described in
Interfaces and Dependencies. The closed type intentionally has constructors only for
the eight approved local exceptions, so an emitter cannot request `DataKinds` or another
contract-covered extension through the normal path.

Change `renderManifestForService` in `keiro-dsl/src/Keiro/Dsl/Manifest.hs` to emit
`default-language` and `default-extensions` before `other-modules`. Change its introductory
comment from “two blocks” to language that tells the user to paste the complete fragment.
Both single-file scaffolding in `Keiro.Dsl.ScaffoldRun` and workspace scaffolding in
`Keiro.Dsl.WorkspaceScaffold` already call this renderer, so no second implementation is
needed. Extend the manifest tests in `keiro-dsl/test/Main.hs` to assert exact ordering,
indentation, and values for ordinary, typed-contract, consumer-mapping, and workspace
manifests.

Add a `common generated-output` stanza to `keiro-dsl/keiro-dsl.cabal` with exactly
`default-language: GHC2024` and `default-extensions: OverloadedStrings`. Do not import
`common shared` from it and do not add the specialized extension allowlist as Cabal
defaults. Initially use the new stanza in one representative conformance component and
run that component to prove the profile is syntactically valid. Milestone 1 is complete
when a fresh manifest advertises the contract, manifest unit tests pass, and the pilot
component compiles under the narrow profile.

### Milestone 2: Make every generated pragma usage-driven

Import `Keiro.Dsl.GeneratedHaskellLanguage` into
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and
`keiro-dsl/src/Keiro/Dsl/Harness.hs`. Replace raw LANGUAGE strings in every
`ModuleKind Generated` emitter with `renderGeneratedLanguagePragmas`. Apply the audit
matrix in Context and Orientation exactly. Leave raw pragma text in create-once emitters
alone; the separation is intentional and should remain visible in the diff.

Introduce small semantic predicates beside the emitter that owns them rather than one
large path-based classifier. Examples are `domainNeedsDuplicateRecordFields`,
`contractNeedsDuplicateRecordFields`, `contractUsesRecordDot`, `codecUsesRecordDot`, and
`transducerUsesRecordDot`. A predicate must mirror emitted syntax. In particular,
`domainNeedsDuplicateRecordFields` must count selectors from command payload records,
event payload records, the register record, and the extra event term records created by
`deriveWireCtorsAll`; any event with fields therefore duplicates those event selectors.
For contract records, duplicated field names across two payload record types require
`DuplicateRecordFields`, while any encoded payload field requires
`OverloadedRecordDot`. `ReadModel` uses record dot only in subscription mode.

Keep pragma output deterministic: deduplicate requested extensions and render them in
lexicographic extension-name order before the generated banner. An emitter with no local
extensions starts directly with its generated banner, with no leading blank line. Add
focused Hspec examples before changing all fixtures. The examples must prove both sides
of each conditional extension: a fixture that needs the extension contains it, and a
fixture that does not need it omits it. Milestone 2 is complete when all fresh generated
modules use only the closed local set, the negative/positive assertions pass, and no
hand-owned emitter text has changed.

### Milestone 3: Prove the contract against the complete generated corpus

Extend `scripts/check-extension-policy.sh` with a second policy for tracked Haskell paths
containing `/Generated/`. Extract every leading LANGUAGE extension and fail unless it is
one of the eight approved local exceptions. This allowlist is intentionally stricter than
a list of today's redundant pragmas: it rejects `OverloadedStrings`, every GHC2024 member,
and any newly introduced specialized default until the architecture and the closed
Haskell type are deliberately updated. Preserve the current policy for non-generated
files.

Add a `generated Haskell language contract` group to `keiro-dsl/test/Main.hs`. Scaffold
representative aggregate, nominal, structural, contract, inbox, queue, and read-model
fixtures through `scaffoldFixture`; filter on `kind == Generated`; parse only the leading
pragma lines; and assert the allowed set plus the module-specific matrix. At minimum use
`aggregate-scalar-expressions-v2.keiro`, `nominal-scalars.keiro`,
`structural-conformance.keiro`, `reservation.keiro`, `contract-v4.keiro`,
`intake.keiro`, `reservation-work.keiro`, and `readmodel-runtime.keiro`. Include explicit
assertions that `Projection`, `ReplayAudit`, `Nominals.Internal`, and structural shape
modules now have no local pragmas, and that `TypeFamilies`, `TemplateHaskell`,
`QualifiedDo`, and other retained exceptions appear in fixtures that exercise them.

Regenerate through the CLI into fresh temporary directories. Copy back only files that
are already tracked below a conformance component's `/Generated/` directory. Never
scaffold directly into a committed component because several components intentionally
compile only a subset of one source's full output. Refresh the union of built-in skeleton
outputs separately. The exact repeatable procedure is in Concrete Steps. After copying,
the diff outside `/Generated/` must contain only the intended Cabal, test, policy, plan,
documentation, and four additive hand-owned driver pragmas.

Change every `test-suite keiro-dsl-conformance*` stanza in
`keiro-dsl/keiro-dsl.cabal` from `warnings, shared` to `warnings, generated-output`.
Add `{-# LANGUAGE OverloadedLabels #-}` to only the four hand-owned drivers identified in
Context and Orientation. If compilation exposes another hand-owned reliance on the broad
profile, add the narrowest local pragma, record the path and reason in Surprises &
Discoveries, and do not remove any existing hand-owned pragma. Run all 33 components.
This independent compile is the proof that the emitted manifest is sufficient and that
each specialized generated pragma remains where it is needed. Milestone 3 is complete
when freshness, policy, and all conformance targets pass under the narrow profile.

### Milestone 4: Publish and preserve the contract

Update `docs/user/typed-spec-toolchain.md` so its scaffold instructions say to copy the
language, default-extension, module, and dependency blocks from the manifest. Explain
that generated files assume GHC2024 plus `OverloadedStrings`, while specialized local
pragmas are emitted only when used. Add the same compatibility note to the planned
`0.9.0.0` section of `keiro-dsl/CHANGELOG.md`; this plan does not change package versions
or dependency bounds.

Create a focused ADR under `docs/adr/`. At implementation time, run `okf id list` and
`okf id next` rather than guessing the handle. The ADR must record four durable facts:
the generated manifest owns the Haskell edition/default-extension contract; the baseline
is GHC2024 plus `OverloadedStrings`; non-baseline syntax is declared locally and
conditionally; and create-once hand-owned files are outside automated pragma cleanup.
Add the ADR update to `docs/adr/log.md` with `okf log add` and run strict profile and log
enforcement.

Finish with the mutation checks and complete repository validation in Concrete Steps.
Update the living sections of this plan with results and any deviations. Every
implementation commit must end with this trailer:

```text
ExecPlan: docs/plans/185-make-the-generated-haskell-language-contract-explicit-and-emit-only-necessary-pragmas.md
```

Milestone 4 is complete when a user can scaffold a fixture, paste the emitted contract
into Cabal, compile the output, and see only locally necessary pragmas; the ADR and user
documentation explain why that remains the supported contract.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro` unless a command says
otherwise. Start by checking the live tree. Plan 184 may still have uncommitted work in
the same emitter, so preserve every pre-existing path and base edits on current contents.

```bash
git status --short
git diff -- keiro-dsl/src/Keiro/Dsl/Scaffold.hs
```

Reproduce the initial corpus audit without traversing dependency stores:

```bash
rg -l '^\{-# LANGUAGE [A-Za-z0-9_]+ #-\}$' \
  keiro-dsl/test/conformance*/Generated --glob '*.hs' | wc -l
rg -n '^\{-# LANGUAGE [A-Za-z0-9_]+ #-\}$' \
  keiro-dsl/test/conformance*/Generated --glob '*.hs' | wc -l
rg -n '^\{-# LANGUAGE [A-Za-z0-9_]+ #-\}$' \
  keiro-dsl/test/conformance*/Generated --glob '*.hs' \
  | sed -E 's/.*LANGUAGE ([A-Za-z0-9_]+).*/\1/' | sort | uniq -c
```

At plan creation the first two commands print `194` and `517`. Counts may change if the
preceding import-planning work regenerates fixtures, but the extension names and audit
matrix remain the target.

After adding the contract module, manifest output, pilot Cabal profile, and tests, run:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test --test-show-details=direct
cabal test keiro-dsl-conformance-aggregate-scalar-expressions \
  --test-show-details=direct
```

Scaffold a visible example and inspect its manifest:

```bash
contract_probe=$(mktemp -d)
cabal run -v0 keiro-dsl -- scaffold \
  keiro-dsl/test/fixtures/reservation.keiro --out "$contract_probe"
sed -n '1,16p' "$contract_probe/keiro-dsl-manifest.hospital-capacity.txt"
```

The beginning must have this shape before the sorted modules and dependencies continue:

```text
-- keiro-dsl build manifest for keiro-dsl/test/fixtures/reservation.keiro
-- Paste the complete fragment below into the consuming Cabal stanza.
-- The generated layer is overwritten on every scaffold; hole modules are
-- create-if-absent (filled by hand).

default-language: GHC2024
default-extensions:
    OverloadedStrings

other-modules:
```

After Milestone 2, run the focused tests before touching committed generated files:

```bash
cabal test keiro-dsl-test --test-show-details=direct
just extension-policy
```

The unit suite must pass against fresh emitter text. The policy check is expected to fail
at this point on old committed fixtures and name the first disallowed generated pragma;
that failure proves the new gate is active.

Refresh source- and workspace-backed conformance files through temporary output. This
loop uses `conformance-baseline.json` as the mapping authority and copies only already
tracked overwriteable files. `jq` is used only to read the checked-in JSON inventory.

```bash
refresh_root=$(mktemp -d)
jq -r '.compiledSuites[] | select(.source != null) | [.directory, .source] | @tsv' \
  keiro-dsl/test/conformance-baseline.json \
| while IFS=$'\t' read -r component_dir source_path; do
    output_dir="$refresh_root/$(printf '%s' "$component_dir" | tr '/' '_')"
    mkdir -p "$output_dir"
    cabal run -v0 keiro-dsl -- scaffold "keiro-dsl/$source_path" --out "$output_dir"
    git ls-files "keiro-dsl/$component_dir" \
    | rg '/Generated/.*\.hs$' \
    | while IFS= read -r tracked_path; do
        relative_path=${tracked_path#"keiro-dsl/$component_dir/"}
        generated_path="$output_dir/$relative_path"
        if test ! -f "$generated_path"; then
          printf 'missing regenerated module: %s\n' "$generated_path" >&2
          exit 1
        fi
        cp "$generated_path" "$tracked_path"
      done
  done
```

Refresh the built-in skeleton union in another temporary directory, then copy only its
tracked generated files. The kind/root pairs must stay synchronized with
`skeletonModuleRoots` in `keiro-dsl/test/Keiro/Dsl/ConformanceBaseline.hs`.

```bash
skeleton_refresh=$(mktemp -d)
while IFS=$'\t' read -r skeleton_kind module_root; do
  skeleton_source="$skeleton_refresh/$skeleton_kind.keiro"
  cabal run -v0 keiro-dsl -- new "$skeleton_kind" > "$skeleton_source"
  cabal run -v0 keiro-dsl -- scaffold "$skeleton_source" \
    --out "$skeleton_refresh/output" --module-root "$module_root"
done <<'SKELETONS'
aggregate	SkelAggregate
process	SkelProcess
router	SkelRouter
contract	SkelContract
intake	SkelIntake
emit	SkelEmit
workqueue	SkelQueue
workflow	SkelWorkflow
SKELETONS
git ls-files keiro-dsl/test/conformance-skeletons \
| rg '/Generated/.*\.hs$' \
| while IFS= read -r tracked_path; do
    relative_path=${tracked_path#keiro-dsl/test/conformance-skeletons/}
    cp "$skeleton_refresh/output/$relative_path" "$tracked_path"
  done
```

Do not delete either temporary directory until freshness tests pass; it is useful for
diagnosing a missing path. If a compatibility component has no source and still contains
an obsolete generated pragma, regenerate it from its documented fixture where possible
or make the minimal pragma-only edit. Record that exception in Surprises & Discoveries.
Never modify its behavior or a hand-owned neighbor as part of this cleanup.

Check the ownership boundary immediately after regeneration. Besides the four named
`Main.hs` additions, no conformance change outside `/Generated/` is expected.

```bash
git diff --name-only -- 'keiro-dsl/test/conformance*'
git diff --stat -- 'keiro-dsl/test/conformance*'
```

Run the focused policy and complete compiled corpus:

```bash
just extension-policy
cabal test keiro-dsl-test --test-show-details=direct
cabal test all --test-show-details=direct
```

The first command ends with `extension policy: OK`. Every
`keiro-dsl-conformance*` component listed in `conformance-baseline.json` must report
`PASS` or an equivalent successful test result while importing `common generated-output`.

Perform four short mutation checks, restoring each small edit immediately with an inverse
patch rather than a broad `git restore` in the dirty working tree. Record the observed
failure in Surprises & Discoveries.

1. Add `DataKinds` to one generated emitter's requested extension list. `just
   extension-policy` or the generated-language Hspec group must fail and name the
   disallowed extension.
2. Remove `TypeFamilies` from a generated nominal or structural projections module. Its
   conformance component must fail at the associated type instances.
3. Remove `QualifiedDo` or `BlockArguments` from a generated transducer. Its conformance
   component must fail to parse the builder `do` syntax.
4. Temporarily remove `OverloadedStrings` from `common generated-output`. Multiple
   generated modules must fail with `String` versus `Text` type errors, demonstrating why
   this one extension belongs in the contract.

Create and validate the ADR using the repository's profiled bundle:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add docs/adr --kind Add \
  -m "Record the generated Haskell language and local-extension contract (plan 185)."
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Use the handle returned by `okf id next`; do not infer it from filenames. Finish with the
repository gates and whitespace checks:

```bash
nix fmt
cabal build all
just verify
nix flake check
git diff --check
```

Generated conformance trees are excluded from Fourmolu by design, so do not format them
after regeneration. Inspect the final pragma vocabulary and manifest diff:

```bash
rg -n '^\{-# LANGUAGE [A-Za-z0-9_]+ #-\}$' \
  keiro-dsl/test/conformance*/Generated --glob '*.hs' \
  | sed -E 's/.*LANGUAGE ([A-Za-z0-9_]+).*/\1/' | sort | uniq -c
git diff -- keiro-dsl/src/Keiro/Dsl/Manifest.hs \
  docs/user/typed-spec-toolchain.md keiro-dsl/CHANGELOG.md
```

Only the eight approved names may appear in the first command's output; a particular
name may be absent if no checked-in fixture needs it.


## Validation and Acceptance

Acceptance is based on user-visible scaffold output and an independent compiler proof,
not only on source inspection.

A fresh scaffold of `keiro-dsl/test/fixtures/reservation.keiro` must create
`keiro-dsl-manifest.hospital-capacity.txt` containing `default-language: GHC2024` and a
single default extension, `OverloadedStrings`, before the module and dependency blocks.
The workspace scaffolder must emit the identical contract. Manifest tests must show that
consumer package/module blocks still follow the Cabal blocks and that no dependency or
module inventory changed because of this presentation cleanup.

Every fresh overwriteable `Generated` module must have a leading pragma set drawn only
from `BlockArguments`, `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedRecordDot`, `QualifiedDo`, `TemplateHaskell`, and `TypeFamilies`. The focused
unit tests must demonstrate absence as well as presence: a plain projection and replay
audit have no pragmas, a projection-witness module retains `TypeFamilies`, an aggregate
domain retains `TemplateHaskell`, and a generated transducer retains builder-specific
extensions. A contract with disjoint or empty payload records must omit
`DuplicateRecordFields`; a contract with repeated selectors must retain it. Inline read
models omit `OverloadedRecordDot`; subscription read models retain it.

`just extension-policy` must fail if a tracked generated module contains any pragma
outside the closed set, including `DataKinds` and `OverloadedStrings`, and pass on the
committed corpus. Existing non-generated policy behavior must remain unchanged.

Every `keiro-dsl-conformance*` component must compile and run after its Cabal stanza is
switched from `common shared` to `common generated-output`. This is the decisive proof:
the broader generator defaults can no longer mask a missing specialized pragma. The four
hand-owned driver additions are acceptable only because they isolate test code from that
broader profile; no existing hand-owned pragma may be removed.

The committed generated fixture freshness assertions in `keiro-dsl-test` must pass,
showing that checked-in output came from the current merged emitter. The final diff must
contain no semantic Haskell changes other than pragma rendering and the Cabal/test
infrastructure needed to prove it. Full `just verify`, `nix flake check`, strict ADR
validation, and `git diff --check` must be green.


## Idempotence and Recovery

All emitter and manifest edits are deterministic. Re-running a scaffold in a new
temporary directory and copying the same tracked `/Generated/` paths produces the same
bytes. The refresh loops intentionally never target hand-owned paths and can be repeated
after a partial failure. Keep their temporary roots until tests pass; if one mapping is
wrong, inspect the fresh tree, correct only that mapping, and copy again.

Do not scaffold directly into `keiro-dsl/test/conformance*`: some components are curated
subsets, so direct output can create unrelated generated files even though it preserves
holes. Do not use a broad checkout, reset, restore, or clean command to recover from a
mistake. The working tree may contain active Plan 184 edits. Use `git diff -- <path>` to
identify this plan's changes and an explicit inverse `apply_patch` for a mutation or
mistake.

If the complete conformance switch exposes a hand-owned file that relied on
`common shared`, add only its missing local extension and record it. Do not solve the
failure by broadening `common generated-output`; doing so would silently expand the
consumer contract. If generated compilation exposes an extension not in the approved
set, stop and update the plan's Decision Log and ADR rationale before extending the
closed type, manifest, policy, or Cabal profile.

Promoting an existing local extension later is the inverse operation and should not
require another generated-code audit. First decide whether the extension arrived through
a new `default-language` edition or is being added explicitly under
`default-extensions`. Update the corresponding manifest constant and
`common generated-output`, delete the extension's closed-type constructor and every
emitter request or usage predicate, remove it from the generated-output policy allowlist,
regenerate the tracked `/Generated/` corpus, and update the contract tests, documentation,
and ADR. The compiler profile catches a promotion applied too early, while the policy and
freshness checks catch a leftover local pragma. For `DuplicateRecordFields`, this is
expected to be a modest policy-and-regeneration change rather than a redesign; the exact
diff size depends on how many conformance fixtures contain duplicate selectors at the
time of migration.

The manifest addition is backward-compatible as a pasteable fragment: rerunning the CLI
over an output directory overwrites the generated manifest and generated modules while
preserving create-once files. No database, network service, release, or irreversible data
migration is involved.


## Interfaces and Dependencies

Create the private module `Keiro.Dsl.GeneratedHaskellLanguage` at
`keiro-dsl/src/Keiro/Dsl/GeneratedHaskellLanguage.hs` with this conceptual interface:

```haskell
data GeneratedHaskellExtension
  = ExtBlockArguments
  | ExtDeriveAnyClass
  | ExtDuplicateRecordFields
  | ExtOverloadedLabels
  | ExtOverloadedRecordDot
  | ExtQualifiedDo
  | ExtTemplateHaskell
  | ExtTypeFamilies
  deriving stock (Eq, Ord, Show)

generatedHaskellDefaultLanguage :: Text
generatedHaskellDefaultExtensions :: [Text]
renderGeneratedLanguagePragmas :: [GeneratedHaskellExtension] -> [Text]
```

`renderGeneratedLanguagePragmas` deduplicates inputs, sorts by rendered extension name,
and returns complete `{-# LANGUAGE ... #-}` lines. The module stays in the library's
`other-modules`; it is implementation policy, not a new public `keiro-dsl` API.
`Keiro.Dsl.Manifest`, `Keiro.Dsl.Scaffold`, and `Keiro.Dsl.Harness` import it internally.

`renderManifestForService :: Text -> [ScaffoldModule] -> CheckedService -> Text` retains
its public signature. Its output contract gains these Cabal fields:

```cabal
default-language: GHC2024
default-extensions:
    OverloadedStrings
```

The new `common generated-output` stanza in `keiro-dsl/keiro-dsl.cabal` mirrors those
values exactly. It is used by conformance components only. `common shared` continues to
own the broader defaults for the generator library, executable, ordinary unit tests, and
unrelated package code.

The source-level condition helpers remain private to `Keiro.Dsl.Scaffold`. They consume
existing checked semantic types such as `Agg`, `ContractNode`, `WorkqueueNode`, and
`ReadModelNode`; this plan adds no DSL syntax or AST fields. Tests observe the resulting
`moduleText` and `kind` fields rather than exporting those helpers.

Keiki remains at the existing `keiki >=0.8 && <0.9` bound. No dependency update is
needed. Its registered package `mori://shinzui/keiki/packages/keiki` explains the hidden
event term-record selector duplication that informs the Domain predicate. The plan does
not change Keiki source.

The implementation uses existing `aeson`, `containers`, `text`, Hspec, Cabal, `jq`, OKF,
Nix, and repository scripts. It adds no runtime library dependency and makes no external
service calls.


## Revision Note (2026-08-03)

Reaffirmed after contract-scope discussion that `OverloadedStrings` is the only Cabal
default extension. Expanded the Decision Log to distinguish its pervasive literal-typing
role from record, label, derivation, type-family, Template Haskell, and builder syntax
that remains locally attributable to particular generated modules. A follow-up clarified
that likely inclusion of `DuplicateRecordFields` in a future edition should trigger
cleanup when Keiro adopts that edition, not preemptively broaden the GHC2024 contract.
Documented the inverse promotion procedure and clarified that an extension supplied by a
new language edition is removed from local pragmas without also being repeated in Cabal's
`default-extensions`.
