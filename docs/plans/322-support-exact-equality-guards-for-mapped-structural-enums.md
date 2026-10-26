---
id: 322
slug: support-exact-equality-guards-for-mapped-structural-enums
title: "Support exact equality guards for mapped structural enums"
kind: exec-plan
created_at: 2026-10-26T19:08:15Z
intention: "intention_01m5wss06de1bsm2wspas8rs21"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-26T19:08:15Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T19:17:42Z
      verdict: "changes-requested"
      note: "Author self-review: require an explicit Language 6 capability gate and older-language negative coverage; shared-Haskell-owner test currently stops at MappedImportConflict, not expression identity."
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-26T22:49:17Z
      mode: "implement"
      note: "Implement checked structural enum equality and consumer qualification"
---

# Support exact equality guards for mapped structural enums

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Implement [IR-60](../improvement-requests/support-equality-guards-for-mapped-structural-enums.md): a consumer can use one `mapped structural enum RequiredScope` both inside a nested record and as direct aggregate command/register fields, then write `guard cmd.requiredScope == reg.requiredScope` or `!=`. Qualified constructors such as `RequiredScope.PipelineScope` work in these comparisons. Generated execution and symbolic analysis agree over exactly the declared alternatives, and solver models reconstruct the consumer's own type.

A structural mapping describes a wire shape in the DSL and connects it to a consumer-owned Haskell type through a total binding, meaning conversion accepts every declared shape without an extra rejection. Exact symbolic equality means the solver considers all and only possible enum keys; using an unconstrained string would incorrectly admit impossible alternatives. The implementation must retain declaration identity even when two enums share their wire strings or Haskell owner type.

The concrete adopter is `mori://shinzui/kotei/plans/103-reconstruct-recorded-failure-environments-for-inspection-and-debugging`. Its existing native-enum adapter remains usable. This plan delivers Keiro support and release-qualification guidance; publishing packages, editing Kotei, deploying it, and migrating its stored data are separate actions. General record/union equality, ordering, arithmetic, and new traversal through optional values or containers are outside scope.


## Progress


- [x] Milestone 1 (2026-10-26): the Language 6 scope fixture scaffolds and its compiled suite passes concrete equality/inequality, finite-domain exclusion, typed model reconstruction, and decoded replay. Verified with `nix develop -c cabal test keiro-dsl-conformance-mapped-structural-enum-equality --test-show-details=direct`.
- [x] Milestone 2 (2026-10-26): seven generated predicate forms pass all 28 concrete/symbolic input/register combinations, including literals on both sides, self comparisons, and owner-valued constructor writes. Seven restoring mutations detect collapsed bindings, omitted fixtures/domains, wrong inverses, bijective meaning swaps, missing symbols, and incorrect signatures; the restored compiled baseline passes. Focused source tests reject unsupported types/operators and preserve declaration identity, including a shared Haskell owner.
- [x] Milestone 3 (2026-10-26): single-file/workspace equality rows round-trip separately from nominal rows, binding explanations retain the declared contract, and supported revision pairs compare against their own graphs. Binding/domain/guard changes affect the scope aggregate; fixture/order changes remain replay-neutral; the unrelated control and data-only fold golden retain identity. Exact direct/nested JSON byte vectors and decoded replay pass. The compiled snapshot check preserves codec/layout discriminators, changes the fold discriminator, and agrees with full replay; the final repository gate also exercises the shared runtime snapshot-admission tests.
- [ ] Milestone 4: affected regression suites, repository verification, documentation, and ADR distillation establish an adoption-ready implementation.

Implementation has verified the first compiled consumer path; the remaining milestones are in progress. Creation evaluated the source and validation paths. The Nix shell reports Z3 4.16.0. The working tree already contained an unrelated edit to `docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md`; preserve it.


## Surprises & Discoveries


The generated forward/replay harness samples the first mapped fixture. That can falsify an inequality guard when the first fixture equals the register initial. Structural enum command sampling now uses the initial for explicit equality and selects a different supplied fixture for explicit inequality. This preserves executable replay assertions without weakening an assertion or depending on solver-selected whole environments.

An extra strict check of the improvement-request bundle reports six pre-existing missing recommended `reviews` fields (including IR-60). The prescribed strict ADR check passes; no review metadata was invented or unrelated requests changed. Final repository acceptance uses the required verification gate.

The full unit regression also maintains an explicit list of Language 6 fixture exceptions; the new fixture and six revision vectors must be listed there in addition to registering the compiled suite in `test/conformance-baseline.json`. The first broad run exposed that inventory obligation.

The general mapped-value operations share a bidirectional `AggregateMapped` pattern over ordinary mappings and the new checked enum variant. Capability admission inspects the enum evidence first, while codecs, samples, initials, and writes keep their established structural paths. Declaration-specific equality uses a separate versioned canonical segment; no global capability fold segment is added.


## Decision Log


- Decision: derive equality from the checked structural enum declaration and its existing total binding, using declared wire strings as finite keys and declaration-specific projection tags. Do not require another consumer equality adapter or use arbitrary consumer `Eq` as the wire authority. Rationale: this preserves the single schema authority and supports exact reconstruction without duplicating the enum. Date: 2026-10-26.
- Decision: qualify a compiled producer/consumer example before expanding test variants. Rationale: capability admission alone does not provide qualified literals, generated imports, finite domains, or inverse bindings. Date: 2026-10-26.
- Decision: add support to the current Language 6 surface with usage-scoped identity; do not add a global fold-version change or revive retired compatibility suites. Rationale: previously rejected syntax can gain support without changing unrelated folds; current supported histories still require explicit qualification. Date: 2026-10-26.


## Outcomes & Retrospective



## Context and Orientation


The request is about `mapped structural enum`, distinct from native or consumer-bound nominal `enum`. [Plan 170](170-make-nominal-id-and-enum-equality-exact-in-aggregate-expressions.md) delivered nominal equality. [Plan 288](288-complete-nominal-id-support-across-contracts-expressions-nested-enums-and-direct-optional-fields.md) extended nominal leaves inside structures. Reuse their existing machinery, but neither makes a structural enum an `AggregateNominal`.

`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` represents a valid mapping as `ResolvedStructural StructuralDecl (REnum entries)`. `StructuralDecl` retains Haskell ownership, binding symbol/version, canonical type identity, fixtures, and optional initial value. `keiro-core/src/Keiro/Codec/Structural.hs` defines the two total binding directions, `bindingToShape` and `bindingFromShape`, and their round-trip checks. A canonical identity is the stable declared type identifier used by generated contracts, not the source filename.

`keiro-dsl/src/Keiro/Dsl/AggregateType.hs` currently represents every mapped aggregate type as `AggregateMapped MappedKey`, without its shape. `aggregateCapability EqualityGuardUse` rejects every such value. Therefore a sound change needs checked enum evidence at this boundary, rather than returning `SolverVisible` for all mappings. `AggregateSymbols.mapped` already holds resolved declarations.

`keiro-dsl/src/Keiro/Dsl/Expression.hs` checks operand identity and capabilities. `resolveEnumLiteral` currently searches only `Spec.enums`; it never resolves mapped structural constructors. `ScalarEnumValue` and typed roots must carry enough resolved information for structural enums to lower without looking up a nominal declaration. Keep ordinary operand mismatch diagnostics at the expression location.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` contains `renderComparisonTerm`, nominal projection aliases, and shared structural projection generation (`projectionSpecs`, `emitStructuralProjections`). Nominal equality already compares canonical textual keys with exact domains. The structural projection code handles scalar record paths and nominal leaves, but has no root structural-enum equality witness. Generated owner types, bindings, literals, witness imports, and aliases must all derive from the same checked evidence, including workspace generation.

`keiro-dsl/src/Keiro/Dsl/StructuralConformance.hs` emits binding assertions and enum branch coverage. Current binding assertions exercise consumer fixtures; `coverageExpression` verifies all enum branches are represented. Extend this to explicitly enumerate every generated enum shape, validate both conversion directions, and check exact projection laws. Static checking cannot execute or prove arbitrary Haskell functions: declaration validity belongs to `check`, missing symbols/types fail consumer compilation, and binding-law/fixture failures belong to executable conformance. Exactness is conditional on those binding laws, never a claim that fixture tests prove all arbitrary Haskell values.

`keiro-dsl/src/Keiro/Dsl/NominalType.hs` provides a precedent for versioned equality identities. `keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs`, `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`, `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`, `keiro-dsl/src/Keiro/Dsl/Diff.hs`, `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`, and `keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` own persisted identity and compatibility reporting. `keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs` supplies mapped use-site inventory. Follow those authorities rather than introducing a separate string-based compatibility classifier.

The unit entry point is `keiro-dsl/test/Main.hs`. Existing compiled examples are `keiro-dsl/test/conformance-structural/Main.hs`, `keiro-dsl/test/conformance-nominal-scalars/Main.hs`, and `keiro-dsl/test/conformance-structural-nominals/Main.hs`. `keiro-dsl/keiro-dsl.cabal` registers each suite. `keiro-dsl/tools/corpus-regen/src/Main.hs` regenerates tracked generated output; `keiro-dsl/test/conformance-corpus-manifest.txt` supplies corpus metadata. Some current fixture files still declare Language 4 despite the retirement decision below; do not copy that preamble into the new Language 6 fixture or expand this work into a corpus-wide migration.

Relevant ADRs consulted are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which requires one wire authority and total bindings; [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md), which distinguishes nominal leaves and restricts traversal; [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which requires frozen canonical encoding and explicit fold effects; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which gates snapshots on codec version, register layout, and fold identity together; and [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md), which scopes historical support while retaining current replay obligations. No new global compatibility reset is justified by this feature.


## Plan of Work


### Milestone 1: Establish the checked contract and one complete consumer path


Add a dedicated resolved aggregate variant for structural enums, carrying declaration identity and a compact checked equality contract derived only from `ResolvedStructural _ (REnum _)`. Define that contract beside the aggregate type authority, including the nonempty constructor/wire mapping, Haskell owner, binding provenance, canonical identity, and a stable policy token such as `keiro-dsl/structural-enum-equality/1`. Keep other mapped shapes on their existing path. Audit every `ResolvedAggregateType` match so type rendering, initial values, codecs, samples, writes, and structural paths continue using the structural binding rather than nominal conversion. Preserve existing serialization for mapped types that do not use equality.

Create `keiro-dsl/test/fixtures/mapped-structural-enum-equality.keiro` with `language keiro-dsl 6`, context `mapped-structural-enum-equality`, and the request's two scope alternatives (`pipeline` and `diagnostic`). Add a required nested record field using the same enum, a direct register initialized with `initial`, and commands/events using that same owner type. Start with an equality guard comparing command to register and an observable emitted event or register update. Add hand-owned `Conformance.MappedStructuralEnumEquality.Domain` and `Bindings` modules beneath `keiro-dsl/test/conformance-mapped-structural-enum-equality/`, and a `Main.hs` that runs generated assertions and the behavior proof. Register `keiro-dsl-conformance-mapped-structural-enum-equality` in the Cabal file using the neighboring conformance components' dependencies and source layout.

Generate one declaration-tagged root equality witness in the context's `StructuralProjections` module. Its owner is the consumer enum and its result is `Text`. Project through `bindingToShape` then the declared constructor-to-wire mapping. Use `finiteProjectionDomain` over every wire string. Reconstruction recognizes only declared strings, constructs the generated shape, and applies `bindingFromShape`; unknown strings return `Nothing`. Route command/register comparison operands through this witness and exact Keiki equality. Do not use ordinal keys or unconstrained textual witnesses. Include shared imports and workspace planning in the same path so consumers do not need a second native enum.

Acceptance is a clean source check and a compiled test that passes for equal scopes, rejects a different scope, reports an exact finite predicate, and reconstructs a consumer owner from a satisfiable model. This is the early integration proof. Keep the capability disabled or the milestone incomplete until all layers work together.


### Milestone 2: Complete operators, literals, and binding evidence


Extend qualified literal resolution to the checked structural enum namespace, preserving its declaration identity. Lower literals to declared wire keys only in comparison terms; any accepted owner-valued literal must cross `bindingFromShape` rather than accidentally constructing a nominal representation. Keep constructor errors and cross-type errors source-local. Cover literal on either side, root/root, and self comparisons for both `==` and `!=`. The enum's presence in a nested record must still compile and serialize; arbitrary new nested-expression traversal is not required.

Enumerate the two-by-two scope matrix: equality accepts exactly the diagonal and inequality accepts exactly the off-diagonal. Check generated execution and symbolic results, including exhaustive disjunction over both alternatives and contradiction outside that domain. Use `verifyPredicateDetailed` and typed model accessors to check every returned projection key and reconstructed owner round-trips to that key. Models are path-local projection owners, not complete reconstructed command/register environments; do not overstate the upstream API.

Generate exhaustive shape round-trip checks for root enum shapes, domain round trips for supplied fixtures, branch coverage, expected wire values, and `checkFieldProjectionOwner`/`checkFieldProjectionKey` evidence. Add `keiro-dsl/test/mapped-structural-enum-equality-mutation-test.sh` with restoring mutation tests for a collapsed/non-bijective binding, omitted fixture branch, omitted finite-domain alternative, and a rejecting or wrong inverse. A bijective swap alone can satisfy binding laws, so expected-wire fixtures must detect an unintended meaning swap. Do not silently downgrade a failed binding to opaque equality. Missing binding metadata fails checking; missing symbols or wrong signatures fail compilation; executable violations fail conformance or report a projection contract violation explicitly.

Negative source tests reject a second enum with identical strings, nominal-enum/structural-enum comparison, enum/Text, unknown constructors, unqualified constructors, record/union/opaque equality, ordering, and arithmetic. Also use two declarations sharing one Haskell owner to verify declaration separation. Existing nominal enum tests remain green. Milestone acceptance is the focused unit matrix and compiled suite, with each mutation failing its named assertion and restoring the baseline.


### Milestone 3: Qualify identity and supported history


Thread the checked equality contract through capability/binding explanations and generated scaffold provenance. If an additive scaffold row is necessary, use a distinct structural-enum equality row with parse/render round-trip tests; do not relabel it as nominal. Decide identity from semantic facts, not Haskell source text or fixture labels. Keep wire identity independent of equality capability: unchanged `pipeline`/`diagnostic` strings must remain byte-identical in direct and nested events.

Extend fold identity only for aggregates whose expressions use the new equality contract. Include the versioned policy and binding/domain facts not already represented by the aggregate's mapped dependencies. Preserve existing no-use pre-hash bytes and digests, with explicit golden controls for unrelated aggregates and mapped enums used only as data. Stable key-domain ordering must not depend on source constructor order. Binding symbol/version, canonical identity, wire-domain changes, and guard changes must flow through the relevant build, fold, diff, replay-impact, and snapshot consequences. Fixture-only changes and declaration reordering must not invent wire/fold changes.

Add old/new fixture pairs covering addition of a guard, changed binding version, changed wire spelling/domain, and unchanged semantics. Exercise both ordinary diff and replay-impact selection against each revision's own checked graph. Run current supported event bytes through the generated codecs and replay fold; compare full replay with an admitted compatible snapshot, and prove a changed fold rejects a stale snapshot. Preserve established enum spellings. A native bridge's removal is not automatically replay-neutral simply because its strings match: document separate event-codec, register-layout, fold, and snapshot qualification obligations for the adopter.

Acceptance requires expected findings for affected aggregates, unchanged identities for unrelated controls, exact JSON goldens, and current-contract replay/snapshot checks. If historical bridge bytes cannot be proven equivalent, retain explicit migration/rebuild requirements instead of claiming transparent adoption.


### Milestone 4: Finish regressions and adoption documentation


Run the unit suite, the new compiled suite, and existing nominal, structural, nested nominal, and snapshot suites. Regenerate only affected corpus outputs and verify the corpus inventory. Complete the repository's Nix-shell verification gate. Record test evidence and any environmental failures accurately; a failure is not permission to weaken solver or binding assertions.

Update `docs/user/keiro-dsl-types-and-mappings.md`, `docs/user/mapped-consumer-adoption.md`, `docs/guides/checked-mapping-adoption.md`, `keiro-dsl/CHANGELOG.md`, and IR-60 with the supported syntax, finite-domain guarantees, exclusions, and implementation/release distinction. Provide the scope example and release qualification steps needed to remove Kotei's adapter while retaining its owner type and wire strings. Do not mark the downstream adoption complete without its evidence.

Distill the final authority and compatibility decisions into ADR-12 and ADR-18, updating ADR-46 only if its traversal boundary changes. Before editing ADRs, run `mori show --full`, inspect the `docs/adr` bundle profile and descriptor, preserve existing `docId` values, update timestamps and the bundle log using the existing OKF workflow, and run strict validation. A new ADR is needed only for a distinct durable decision; allocate any new handle using `okf id next`, never from filename counting. Finish Outcomes & Retrospective after every milestone's acceptance passes.


## Concrete Steps


Run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. All builds, tests, and verification run in the Nix development shell. Check the solver first:

```bash
nix develop -c z3 --version
```

Creation observed `Z3 version 4.16.0 - 64 bit`. Create the new fixture and consumer modules described above, then exercise the CLI and focused suite:

```bash
nix develop -c cabal run keiro-dsl -- check keiro-dsl/test/fixtures/mapped-structural-enum-equality.keiro --explain-bindings
nix develop -c cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/mapped-structural-enum-equality.keiro --out keiro-dsl/test/conformance-mapped-structural-enum-equality
nix develop -c cabal test keiro-dsl-conformance-mapped-structural-enum-equality --test-show-details=direct
nix develop -c cabal test keiro-dsl-test --test-show-details=direct
```

Before implementation, the complete fixture's first direct guard should fail with `AggregateExpressionOperatorUnsupported` naming `RequiredScope`. After implementation, checking and scaffolding exit zero and the compiled suite prints passing binding, concrete truth-table, finite-domain, and reconstruction assertions. Add the suite and generated modules to corpus tracking before final corpus validation. For subsequent regeneration use:

```bash
nix develop -c cabal run keiro-dsl-corpus-regen -- regenerate --only keiro-dsl/test/conformance-mapped-structural-enum-equality
```

The corpus tool refuses dirty generated output. Review and checkpoint owned generated changes before rerunning; use `--allow-dirty` only for known, reproducible edits in this fixture. Do not reset someone else's work. Register the new root as required by the corpus manifest and tracked scaffold record.

At coherent milestones, run the relevant regressions:

```bash
nix develop -c cabal test keiro-dsl-conformance-nominal-scalars keiro-dsl-conformance-aggregate-scalar-expressions keiro-dsl-conformance-structural keiro-dsl-conformance-structural-nominals keiro-dsl-conformance-workspace-nominals keiro-dsl-conformance-snapshot --test-show-details=direct
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c just conformance-corpus-policy
nix develop -c just adr-validate
nix develop -c just verify
nix develop -c bash keiro-dsl/test/mapped-structural-enum-equality-mutation-test.sh
nix develop -c git diff --check
```

All baseline commands must exit zero. The restoring mutation runner added in milestone 2 must require its specific negative assertion, then rerun a clean baseline; an arbitrary compiler or solver startup failure is not mutation acceptance. The runner itself exits zero only when all expected failures are detected and the clean baseline passes. Commit meaningful working boundaries on the current branch using Conventional Commits and both trailers:

```text
ExecPlan: docs/plans/322-support-exact-equality-guards-for-mapped-structural-enums.md
Intention: intention_01m5wss06de1bsm2wspas8rs21
```


## Validation and Acceptance


The new fixture uses one consumer-owned scope type inside a record, in a direct command, and in a direct register. It compiles without a duplicate native enum or behavior hole. Both operators agree with the complete two-alternative truth table. Qualified constructors resolve against their own declaration; unrelated declarations and Text fail even when their wire strings coincide. Every returned projection model has a declared key and a reconstructible owner that projects back to it. Exhaustive finite-domain contradictions are exact, and omitted-domain/bad-binding mutations cannot pass qualification.

Declaration errors fail static checking, malformed binding code fails compilation, and incomplete fixtures or law-breaking bindings fail executable qualification. Reports must distinguish declared solver capability from evidence actually executed; `check` alone does not certify a Haskell binding. Generated wire strings stay `pipeline` and `diagnostic`. Relevant binding/domain/guard changes produce appropriate evolution findings and snapshot invalidation; fixture-only and unrelated changes retain existing identity. Current supported event decoding and replay remain correct. Nominal enum behavior remains covered.

Completion means the four milestones and required checks pass and adoption guidance identifies the release and consumer qualification still required. It does not imply a package has been published or Kotei's adapter removed.


## Idempotence and Recovery


Keep changes additive until the compiled example proves exact equality. Generate into the dedicated conformance directory and use temporary copies for destructive mutation probes, with automatic restoration on failure. Never patch generated Haskell as the permanent solution; edit the generator and regenerate. Repeat checks after changes that invalidate their evidence, rather than repeatedly rerunning unrelated suites.

Do not change dependency bounds to work around a missing solver. Diagnose the Nix shell and Z3 first. If an exact inverse cannot be generated or validated, fail qualification explicitly and leave the consumer bridge usable. There is no database migration or production data write in this plan. Preserve unrelated dirty files and do not create a branch unless requested.


## Interfaces and Dependencies


The consumer interface remains `StructuralBinding domain shape` from `keiro-core/src/Keiro/Codec/Structural.hs`; no additional user equality function is introduced. The new checked aggregate enum evidence is internal and declaration-specific. It supplies the canonical textual key mapping, nonempty finite domain, structural binding provenance, and policy version to all consumers. Generated `StructuralProjections` owns the witness and private projection tag. Root reconstruction uses the declared shape and binding, never a fixture-selected fallback owner.

The solver dependency is `mori://shinzui/keiki/packages/keiki`, discovered using Mori registry commands. Its `src/Keiki/Core.hs` defines `FieldProjection`, `ExactFieldProjection`, `exactFieldWitness`, `checkFieldProjectionOwner`, and `checkFieldProjectionKey`; `src/Keiki/ProjectionDomain.hs` exports `finiteProjectionDomain`; `src/Keiki/Symbolic.hs` exposes `verifyPredicateDetailed` and typed projection-model accessors. These paths are relative to that canonical project; artifact-level source URIs are pending. The exact contract requires every owner key to lie in the declared domain and every domain key to reconstruct an owner that projects back to it. A missing key can cause false unsatisfiability, which is why owner-side conformance is mandatory.

On 2026-10-26, Hackage's preferred-version endpoint reported Keiki 0.9.1.0 as latest, and upstream tag `v0.9.1.0` resolved to commit `15bc83b1eb38d78488862f24bb1d873aa32a919a`. The repository already uses `>=0.9 && <0.10`; no dependency change is planned. Existing generated nominal witnesses already consume the needed API. Recheck registry and upstream tags before any later bounds or compatibility decision, and inspect dependency source through Mori rather than the Nix store. This plan is standalone and has no parent MasterPlan prerequisite.
