---
id: 181
slug: replace-runtime-semantics-strings-with-capability-profiles-and-a-frozen-fingerprint-encoder
title: "Replace runtime-semantics strings with capability profiles and a frozen fingerprint encoder"
kind: exec-plan
created_at: 2026-08-02T04:56:03Z
intention: "intention_01kz0d7z8ceg4saffrbffpzd65"
---

# Replace runtime-semantics strings with capability profiles and a frozen fingerprint encoder

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today, registering a new Keiro language version is dangerous in two silent
ways.  First, runtime behavior is keyed on one opaque string per registry row
(`"keiro-dsl/runtime-semantics/N"`), and every consumer interrogates that
string through its own hand-maintained membership list: forgetting to extend
one list when version 5 arrives silently reverts ID-domain enforcement,
nominal-equality semantics, contract-ID admission, or strict validation to
legacy behavior with no diagnostic.
Second, the aggregate fold fingerprint — the token that decides whether a
persisted snapshot may seed replay
([ADR 0003](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md))
— receives a version segment whose default branch mints a fresh segment for
any unknown semantics string, so the *default* consequence of registering a
version is invalidating every snapshot in the fleet, even for a change with no
fold impact.  On top of both, the bytes being hashed come partly from the
human-facing pretty printer, so a future readability improvement to DSL
expression rendering would also silently move every fingerprint.

After this plan, runtime semantics is a profile carrying an explicit set of
named capabilities, mirroring the existing `SyntaxProfile`; every gate asks
"does this profile have capability X" instead of comparing strings; a new
capability contributes to fold fingerprints only if it explicitly declares a
fold segment; and the exact bytes fed to the fingerprint hash live in one
frozen, golden-pinned canonical encoder that the presentation pretty printer
can no longer disturb.  A hypothetical language version 5 that fixes a
contract-DTO codec then requires: one registry row, one capability, zero edits
to membership lists, and zero snapshot invalidation — and forgetting something
becomes a compile error or a failing registry test instead of silent legacy
fallback.  The wider digest is private to aggregate fold identity; read-model
shape hashes, mapped-wire fingerprints, behavior keys, and other already
published 64-bit identities do not change as collateral damage.

The change is observable: after every milestone except the final hash
widening, all existing fold fingerprints, fold surfaces, diff results, and
replay-impact classifications are byte-for-byte unchanged (proved by tests
pinned before the refactor), and a new negative registry test demonstrates
that an experimental fifth profile with a non-fold capability moves nothing.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-08-02 10:10 PDT: Milestone 0 pinned complete fold surfaces and
  fingerprints for six representative aggregates across five fixture families,
  all four gate/segment projections, representative diff/replay rendering, and
  the unrelated read-model, wire, and behavior-key 64-bit identities; all 486
  focused examples pass.
- [x] 2026-08-02 10:18 PDT: Milestone 1 introduced private runtime profiles
  with four explicit capabilities, migrated every semantic string gate
  including strict validation, improved JSON mismatch diagnostics, and added
  registry monotonicity/source-boundary tests.
- [x] 2026-08-02 10:18 PDT: Milestone 2 derives deduplicated fold segments from
  exhaustive per-capability metadata; all pre-hash surfaces, fingerprints, and
  generated/conformance behavior remain byte-identical for languages 1-4.
- [ ] Milestone 3: extract the frozen canonical fingerprint encoder, make fold
  surfaces total, and point replay-impact comparison at it.
- [x] 2026-08-02 10:25 PDT: Milestone 3 encoder extraction is complete:
  fingerprint and replay comparison now consume an independent frozen
  canonical module; explicit fold-surface errors and their propagation remain.
- [ ] Milestone 4: deterministic replay-impact transition pairing and removal
  of the `Spec`-only legacy entry points.
- [ ] Milestone 5: widen the fingerprint hash beyond 64 bits in one
  coordinated invalidation before the `0.9.0.0` release.
- [x] 2026-08-02 09:57 PDT: reviewed the plan against the post-ExecPlan-180
  working tree, corrected the missing language-4 validation capability,
  order-dependent replay fallback, non-total API propagation, shared-hash
  blast radius, and stale legacy-wrapper claim; the untouched 482-example
  `keiro-dsl-test` baseline passes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (pre-plan audit, updated 2026-08-02): the string-membership gates
  are real and four-deep.  `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` enables
  generated-ID enforcement via
  ``effectiveRuntimeSemantics ... `elem` ["keiro-dsl/runtime-semantics/2", "keiro-dsl/runtime-semantics/3"]``
  with `otherwise -> Nothing` (legacy unchecked), and contract-ID enforcement
  via equality with `".../3"`; `keiro-dsl/src/Keiro/Dsl/NominalType.hs`
  derives `"keiro-dsl/nominal-equality/2"` from the generated-ID gate.
  `keiro-dsl/src/Keiro/Dsl/Validate.hs` separately compares with runtime
  semantics 3 in `enforcesSpecSurfaceClosures`, governing all strict
  language-4 validation added by ExecPlan 180.  The original plan inventory
  predates those last commits and would have left that gate stringly typed.
- Discovery: `runtimeSemanticsFingerprintSegment` in
  `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` hand-collapses semantics 2 and
  3 to the literal `"semantic-contract:keiro-dsl/runtime-semantics/2"` and
  mints a fresh segment for anything else in its `otherwise` branch; it is
  consumed as the first fold-surface line in
  `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`.
- Discovery: fold surfaces are not total.  `FoldFingerprint.hs` drops whole
  segment families on resolution failure (`Left _ -> []` at the type-graph and
  nominal-resolution call sites), falls back to raw source text for an
  unresolvable register initial, and renders one invalid-output case through a
  derived `Show` (`T.pack (show problem)`).  A fingerprint computed from a
  not-fully-resolved spec silently differs from the same spec resolved.
- Discovery: `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` compares transitions by
  pretty-printed text (`sameSurface left right = renderTransition left == renderTransition right`)
  and pairs old/new transitions greedily by (mode, source, command) with
  `find`/`delete`, so declaration order can decide which of two
  guard-disambiguated siblings pairs with which.
- Discovery (soundness review, 2026-08-02): the plan's proposed fallback of
  pairing leftovers positionally would preserve that order dependence.  Exact
  matches must be removed as a multiset, provable guard-only loosenings must be
  matched deterministically, and all remaining candidates must be sorted by
  canonical structural bytes before positional pairing.
- Discovery (soundness review, 2026-08-02): `fnv1a64` in
  `keiro-dsl/src/Keiro/Dsl/ReadModelShape.hs` is shared by aggregate fold
  fingerprints, read-model shape hashes, and behavior-obligation keys, while
  `TypeGraph.hs` carries another frozen FNV-1a-64 for mapped-wire identity.
  Replacing the shared helper would therefore invalidate unrelated public
  identities.  The widened digest must be a new fold-only function.
- Discovery (soundness review, 2026-08-02): `CheckedService` proves that a
  graph is paired with an effective language contract; it does not prove that
  `validateService` succeeded.  Therefore an `Either` result only on the leaf
  surface function is insufficient: fingerprint, diff, replay-impact, and
  scaffold planning paths must either propagate `FoldSurfaceError` or refuse
  before consuming a surface.
- Discovery (soundness review, 2026-08-02): `legacyCheckedService` is not the
  repository's only version-1 bridge.  Scaffold, harness, manifest, validation,
  and binding-explanation modules intentionally retain documented `Spec`-only
  compatibility wrappers.  This plan removes the identity/evolution wrappers
  it owns, but does not falsely claim to eliminate every compatibility wrapper.
- Discovery (dependency check, 2026-08-02): ExecPlan 179's Milestone 3
  guarantee ledger is closed and still pins `d0897c163c958108`; its release
  milestones remain pending.  Milestone 5 here may therefore update that pin
  before the coordinated `0.9.0.0` publication without crossing the ordering
  constraint.
- Discovery (Milestone 0, 2026-08-02): the pinned unrelated identities are
  read-model shape `fnv1a:3717f6d9e3c44bd6`, mapped-wire fingerprint
  `2bd99b3e57bcde9b`, and behavior key
  `behavior-v1-2e1fd6b9580e1a3d`.  The fold baselines include the six current
  fingerprints `d0897c163c958108`, `d452ae7d73a3bf7f`,
  `ce837676f16ed1a5`, `c5e44f6d33b3dd6f`, `f9264cc50ea1c28f`, and
  `6ee6400f21b05845`.
- Discovery: the presentation pretty printer is load-bearing replay identity.
  `FoldFingerprint.hs` imports `renderExpr` from
  `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` for guard, write, and case
  rendering; ExecPlan 179 records the matching prohibition on editing
  `renderExpr`/`renderTransition` until this plan freezes the encoding.


## Decision Log

Record every decision made while working on the plan.

- Decision: Model runtime semantics as `RuntimeSemanticsProfile` with a
  private constructor and an explicit `Set RuntimeCapability`, exactly
  mirroring the released `SyntaxProfile` pattern in
  `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, and keep the existing
  `"keiro-dsl/runtime-semantics/N"` strings as the profiles' stable
  identifiers for serialization and record compatibility.
  Rationale: the syntax side already proves the pattern works and stays
  append-only; keeping the identifier strings means no persisted record,
  JSON document, or fingerprint byte changes shape.
  Date: 2026-08-01
- Decision: Represent all four shipped gates, including ExecPlan 180's
  language-4 validation policy.  The initial capability set is
  `GeneratedIdDomainTypeIdV7`, `NominalEqualityV2`,
  `ContractIdDomainTypeIdV7`, and `StrictSpecSurfaceValidation` (exact
  constructor spelling may be tightened while implementing, but each behavior
  remains independently queryable).  Runtime profile 1 is empty; runtime
  profile 2 owns the generated-ID and nominal-equality capabilities; runtime
  profile 3 adds contract-ID admission and strict validation.
  Rationale: the 2026-08-02 audit found a fourth raw string gate in
  `Validate.hs`, added after the original plan inventory.  Leaving it behind
  would violate the stated goal and let a successor silently skip most
  language-4 validation.
  Date: 2026-08-02
- Decision: Capabilities are monotone across successors, and a registry test
  enforces it: every version's capability set must be a superset of its
  predecessor's.
  Rationale: all four shipped semantic changes (generated-ID enforcement,
  nominal-equality v2, contract-ID enforcement, and strict validation) are
  "enforced since generation N" facts; encoding monotonicity as a test converts the
  forget-one-list failure mode into a red test.
  Date: 2026-08-01
- Decision: A capability declares its own optional fold-surface segment token
  (`Maybe Text`), and the profile's segment set is the deduplicated ascending
  union.  `capabilityFoldSegment` is an exhaustive pattern match: adding a
  capability is a compile error until its author deliberately chooses `Just`
  or `Nothing`; there is no wildcard/default branch.
  Rationale: this inverts today's dangerous default.  Currently an unknown
  semantics string mints a fresh segment (fleet-wide snapshot invalidation);
  after this change a new capability moves fingerprints only when its author
  explicitly writes the token, and a test forces that decision to be
  conscious.  Byte-compatibility constraint: the capabilities carried by
  semantics 2 and 3 must together contribute exactly the frozen token
  `semantic-contract:keiro-dsl/runtime-semantics/2` and nothing else, so
  versions 1-4 fingerprints do not move.
  Date: 2026-08-01
- Decision: Extract the fingerprint byte surface into a dedicated frozen
  module (working name `Keiro.Dsl.CanonicalEncoding`) whose functions are
  copies of today's `renderExpr`/`renderTransition` behavior, pinned by
  goldens of complete pre-hash fold-surface text; `FoldFingerprint` and
  `ReplayImpact` consume only this module afterward.
  Rationale: the pretty printer serves humans and must be free to improve;
  replay identity must never move as a side effect.  Freezing by copy plus
  goldens is the only mechanism that makes "representation-only change" a
  checkable property instead of a per-plan manual proof (ExecPlan 179 had to
  prove it by hand).
  Date: 2026-08-01
- Decision: Remove the `Spec`-only identity/evolution entry points (`Spec`-typed
  fingerprint, surface, replay-impact, diff, and nominal functions that route
  through version-1 semantics) rather than deprecate them.  Keep
  `legacyCheckedService` as the explicit bridge for callers that knowingly
  need a legacy contract.  Other documented `Spec`-only compatibility APIs in
  scaffold, harness, manifest, validation, and binding explanation are not
  removed incidentally by this plan; their eventual retirement is separate
  API-cleanup work and this plan must not claim otherwise.
  Rationale: a caller holding a `Spec` from a version-4 workspace silently
  gets version-1 answers today — wrong fingerprints with no error.  The
  operator has confirmed nothing serious consumes Keiro yet and `0.9.0.0` is
  already a breaking release, so this is the cheapest moment to delete the
  trap instead of renaming it.
  Date: 2026-08-01
- Decision: Widen the fold-fingerprint hash from FNV-1a-64 in the same plan,
  but as the explicitly last milestone, sequenced after ExecPlan 179's
  guarantee ledger closes and before the `0.9.0.0` release is cut.
  Rationale: ADR 0003 accepts the 64-bit collision risk explicitly, but a
  64-bit non-cryptographic hash over highly similar structured text is the
  wrong foundation for fleet-scale adoption, and the frozen-encoder milestone
  creates the one natural moment to change hash width with a single
  coordinated invalidation while no production snapshots exist.  Doing it
  after 179's ledger keeps that plan's pinned fingerprint
  (`d0897c163c958108`) valid throughout its proofs; this plan then updates
  179's pinned values and records that update in 179's living sections.
  Date: 2026-08-01
- Decision: Implement the widened digest as a new aggregate-fold-only
  FNV-1a-128 function over the frozen UTF-8 encoding.  Do not replace the
  exported `ReadModelShape.fnv1a64` helper or `TypeGraph`'s independent
  FNV-1a-64 implementation.
  Rationale: the shared 64-bit helper also creates read-model shape identities
  and behavior-obligation keys, and the type-graph implementation creates
  mapped-wire fingerprints.  Those are separate persisted/public contracts;
  widening them would turn a targeted snapshot invalidation into several
  undocumented migrations.  Standard FNV-1a-128 is dependency-free,
  platform-stable when reduced modulo 2^128, and satisfies this plan's width
  requirement without broadening the compatibility break.
  Date: 2026-08-02
- Decision: Make fold-surface failure explicit throughout every path that
  consumes it.  `aggregateFoldSurfaceForService` and
  `aggregateFoldFingerprintForService` return `Either FoldSurfaceError Text`;
  diff and replay-impact service APIs return the same error channel; scaffold
  planning turns it into a refusal before emitting modules.  Low-level module
  rendering may consume only a surface/fingerprint successfully resolved by
  its planner.
  Rationale: `CheckedService` retains language provenance but is constructible
  before semantic validation.  Leaf-only `Either` with downstream partial
  extraction would merely move the silent/partial behavior rather than remove
  it.
  Date: 2026-08-02
- Decision: Pair replay transitions per structural identity group by removing
  exact canonical matches as a multiset, deterministically matching provable
  guard-only loosenings, sorting remaining old and new transitions by
  `(canonical guard, canonical transition)`, and only then zipping leftovers.
  Rationale: sorting makes the result invariant under declaration permutation;
  preserving exact and proven-loosening matches first retains the narrowest
  sound replay classification available from the current syntax.
  Date: 2026-08-02
- Decision: Out of scope: durable scaffold/workspace record hardening
  (unknown-row round-tripping, unrecognized-row counts, a `requires-reader`
  header) and the coarse `nonTransitionFoldChanged` audit scoping in
  `ReplayImpact.hs`.
  Rationale: both are real adoption-scale findings from the same audit, but
  neither touches the capability/fingerprint machinery this plan freezes;
  bundling them would couple unrelated review surfaces.  They should become
  their own plan once this one lands.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestone 0 completed with the production code untouched.  Two committed
goldens now pin the full pre-hash fold bytes plus representative diff/replay
rendering, while focused assertions pin every released runtime gate and the
three unrelated 64-bit identity families that Milestone 5 must preserve.  The
focused suite grew from 482 to 486 examples and passes in full.

Milestones 1 and 2 completed together because the profile and its fold metadata
form one registry invariant.  Runtime profile identifiers remain the exact
serialized strings, but all behavior now queries capabilities.  The focused
suite has 488 passing examples after the monotonicity, source-boundary, and JSON
mismatch checks; both scalar-expression and ID-domain compiled conformance
suites pass without regenerating a fixture.


## Context and Orientation

Definitions used throughout: the "fold surface" is the canonical text
description of an aggregate's replay-relevant behavior computed by
`aggregateFoldSurfaceForService` in
`keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`; the "fold fingerprint" is its
FNV-1a-64 hash (`fnv1a64` in `keiro-dsl/src/Keiro/Dsl/ReadModelShape.hs`),
embedded in generated transducers and in the snapshot-compatibility
discriminator of ADR 0003.  "Replay impact" is the classification in
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` that tells an operator which event
streams a spec change forces them to re-audit.  A "gate" is any code path that
enables or disables semantic behavior based on the effective language
contract.

The language registry (`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`) holds
four released versions.  Syntax capabilities are already per-feature: each
registry row carries a `SyntaxProfile` with a `Set LanguageFeature` and a
private constructor, so parser dispatch asks `syntaxProfileSupportsFeature`.
Runtime semantics has no such structure: each row carries
`definitionRuntimeSemantics :: Text`, and the consumers are:

- `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` — `idDomainContractFor` (generated and
  consumer-bound IDs, enabled for semantics 2 and 3 via `elem`) and
  `contractIdDomainContractFor` (contract DTO fields, enabled for semantics 3
  via string equality; added by ExecPlan 178).
- `keiro-dsl/src/Keiro/Dsl/NominalType.hs` — selects
  `"keiro-dsl/nominal-equality/2"` versus `".../1"` off the same gate.
- `keiro-dsl/src/Keiro/Dsl/Validate.hs` —
  `enforcesSpecSurfaceClosures` enables the language-4 numeric floors,
  duplicate/shadowing checks, stable external identity checks, contract/intake
  coupling, and aggregate wire policy only when the raw string is semantics 3.
- `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` —
  `runtimeSemanticsFingerprintSegment` maps semantics 1 to no segment,
  semantics 2 and 3 to the shared literal
  `"semantic-contract:keiro-dsl/runtime-semantics/2"`, and anything else to a
  fresh segment.  Its `FromJSON` instance also rejects a mismatched semantics
  string with a bare `guard` and no error message.

`FoldFingerprint.hs` builds the fold surface from that segment plus state,
register, nominal, transition, and rule segments.  Three properties matter
here.  It renders expressions with the presentation pretty printer
(`renderExpr` from `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`).  It is not
total: type-graph or nominal resolution failure silently drops whole segment
families (`Left _ -> []`), an unresolvable register initial falls back to raw
source text, and one invalid-mapping case is rendered via derived `Show`.
And it exposes `Spec`-only wrappers that assume version-1 semantics through
`legacyCheckedService` — as do `ReplayImpact.hs`, `Diff.hs`, and
`NominalType.hs`.  Other packages intentionally expose similarly documented
compatibility wrappers; this plan removes the identity/evolution subset, not
the whole 0.8 compatibility surface.

`CheckedService` is a provenance-preserving pair, not a proof of successful
semantic validation: `checkedSource` constructs it immediately after parsing.
The single-file diff CLI also currently parses and computes diff/replay output
without calling `validateService`.  Consequently, making only the leaf fold
surface return `Either` would be incomplete; each consumer must propagate the
error or refuse before rendering output.

The current aggregate fold digest imports `fnv1a64` from
`keiro-dsl/src/Keiro/Dsl/ReadModelShape.hs`.  That exported helper is also used
for behavior-obligation keys, and `deriveShapeHash` uses it for read-model
shape identities.  `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` has a separate copy
for mapped-wire identities.  None of those identities is the aggregate fold
fingerprint governed by ADR 0003, so Milestone 5 introduces a dedicated
fold-only FNV-1a-128 encoder instead of altering either 64-bit helper.

ExecPlan 179 (`docs/plans/179-generate-one-human-readable-authoritative-keiro-transducer.md`)
depends on this machinery staying put: its guarantee ledger pins fingerprint
`d0897c163c958108` for the canonical scalar fixture, and its Context section
prohibits editing `renderExpr`/`renderTransition` precisely because this plan
has not yet frozen the encoding.  ExecPlan 178 established the contract-ID
gate, and ExecPlan 180
(`docs/plans/180-close-accepted-but-unenforced-spec-surfaces-before-language-4-ships.md`)
established the strict-validation gate that landed after this plan's original
inventory.  Both are current version-4 behavior this plan rewrites.

Relevant ADRs: ADR 0003 (the fingerprint is a snapshot-compatibility
component and explicitly accepts the 64-bit risk — Milestone 5 amends it),
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
(the registry tests added here are earliest-boundary gates for
version-registration mistakes), and
[ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
(the released-language registry this plan restructures internally without
changing any released meaning).  No ADR yet documents the capability-profile
or frozen-encoder decisions; the distillation pass must create one.


## Plan of Work

Milestone 0 pins the baseline.  Add tests that record the representative
aggregate coverage set consisting of scalar-expressions, nominal-scalars,
id-domain-migration, workspace-nominals, and behavior-complete: the complete
fold-surface text, the fold fingerprint, the runtime-semantics fingerprint
segments for all four versions, the
`idDomainContractFor`/`contractIdDomainContractFor`/nominal-equality/strict-
validation gate results for all four versions, and the diff plus replay-impact
classification for a representative unchanged and changed pair.  Commit the
surface texts as golden files.  Also pin the current read-model shape hash,
mapped-wire fingerprint, and behavior key that Milestone 5 must not move.
These tests are the no-drift proof reused by every later milestone; they must
pass against the unchanged code before any production edit.

Milestone 1 introduces the capability model in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` (or a sibling module if size
demands): a `RuntimeCapability` sum naming today's shipped behaviors —
`GeneratedIdDomainTypeIdV7`, `NominalEqualityV2`,
`ContractIdDomainTypeIdV7`, and `StrictSpecSurfaceValidation`, with exact names
chosen from the gate semantics during implementation — and a
`RuntimeSemanticsProfile` with a private constructor, the existing identifier
string, and the capability set.  Registry rows: semantics 1 = empty set;
semantics 2 = generated-ID and nominal-equality capabilities; semantics 3 =
those plus the contract-ID and strict-validation capabilities.  Rewrite the
gates in `IdDomain.hs`, `NominalType.hs`, and `Validate.hs` to
`runtimeProfileHasCapability`, delete the string comparisons, and give the
`SemanticContract.hs` `FromJSON` mismatch a real error message.  Add registry
tests for successor monotonicity and a focused source-boundary assertion that
no consumer compares runtime-semantics identifier strings.  Milestone 0's gate
baselines must pass unchanged.

Milestone 2 replaces `runtimeSemanticsFingerprintSegment`'s hand-maintained
table.  Each capability carries `capabilityFoldSegment :: Maybe Text`; the
generated-ID and nominal-equality capabilities both carry
`Just "semantic-contract:keiro-dsl/runtime-semantics/2"` (the frozen legacy
spelling), the contract-ID and strict-validation capabilities carry `Nothing`,
and the profile-level segment list is the deduplicated ascending union.  Make
an incomplete `capabilityFoldSegment` match a build failure with a module-local
`-Werror=incomplete-patterns`, so a future constructor cannot inherit an
implicit default.  Tests over the released profiles prove that language 2 to
3 (the first `Just` contributors) moves fingerprints and language 3 to 4 (only
`Nothing` contributors) leaves every pinned fixture unchanged.  Milestone 0's
segment and fingerprint baselines must pass byte-identical for versions 1-4.

Milestone 3 freezes the encoder and makes surfaces total.  Create
`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs` containing the canonical
expression and transition renderers as they exist today (initially by moving
or duplicating the relevant `PrettyPrint` logic; byte-identical output is the
acceptance bar, enforced by the Milestone 0 goldens), with a module comment
declaring the freeze contract: this module's output feeds persisted identity
and may change only with an explicit, ADR-recorded migration.  Point every
`FoldFingerprint.hs` and `ReplayImpact.hs` rendering call at it and remove
their `PrettyPrint` imports.  Then make the fold surface total: computing a
surface for a service whose type graph, nominals, registers, guards, or output
mappings do not resolve becomes an explicit error (`Either FoldSurfaceError`)
instead of silently dropping segments; the raw-source register fallback and
the derived-`Show` rendering are removed.  Audit all call sites — CLI,
workspace, diff, replay, scaffold, tests — and propagate the error through
fingerprint, diff, replay-impact, and scaffold planning rather than assuming
that a `CheckedService` is already valid.  CLI commands render the error and
exit non-zero before emitting a partial report or module set.  After this
milestone, `PrettyPrint.hs` is free presentation surface again; record that in
179's prohibition note if 179 is still in flight.

Milestone 4 hardens replay pairing and deletes the legacy traps.  In
`ReplayImpact.hs`, replace text-equality `sameSurface` with comparison of
canonical-encoder output (identical bytes today, per Milestone 3) and replace
the greedy `find`-plus-`delete` pairing with a deterministic structural
pairing per (mode, source state, command) group: cancel exact canonical
surfaces as a multiset, then deterministically cancel provable guard-only
loosenings, then sort both remaining sides by canonical guard and transition
bytes before positional pairing.  Add tests that independently permute old and
new guard-disambiguated siblings while preserving the classification.  Remove
the `Spec`-only wrappers from `FoldFingerprint.hs`, `ReplayImpact.hs`,
`Diff.hs`, and `NominalType.hs`, update every caller to pass a
`CheckedService`, and note these identity/evolution API removals in the
changelog as `0.9.0.0` breaking changes.  Do not remove unrelated compatibility
wrappers incidentally.

Milestone 5 widens the hash.  Add a dedicated deterministic FNV-1a-128
aggregate-fold digest over the same UTF-8 byte fold, reducing multiplication
modulo 2^128 and rendering exactly 32 lowercase hexadecimal characters.  Keep
`ReadModelShape.fnv1a64`, read-model shape hashes, behavior keys,
`TypeGraph`'s 64-bit wire fingerprints, and generated identifiers unchanged.
This changes every fold fingerprint, every generated transducer's embedded
fingerprint, ADR 0003's discriminator, and ExecPlan 179's pinned
`d0897c163c958108` — which is why this milestone runs only after 179's
Milestone 3 guarantee ledger has closed and before the coordinated `0.9.0.0`
release is cut, while no production snapshots exist.  Regenerate the
fingerprint-bearing conformance trees, update every pinned fold fingerprint
including 179's (recording the update in 179's living sections), amend ADR
0003 with the new width and the canonical-encoder contract, and update both
package changelogs.  Tests must pin one non-ASCII vector and prove all
unrelated 64-bit identities retain their Milestone 0 bytes.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Confirm the current gate and segment behavior before editing (expected values
shown; record actual output here):

```bash
rg -n "runtime-semantics" keiro-dsl/src/Keiro/Dsl/IdDomain.hs keiro-dsl/src/Keiro/Dsl/NominalType.hs keiro-dsl/src/Keiro/Dsl/SemanticContract.hs keiro-dsl/src/Keiro/Dsl/Validate.hs
```

Expected before editing: the four string-gated consumers described in Context.
After Milestone 1, identifier strings remain only in registry definitions,
serialization compatibility, stable diagnostic prose, and pinned test values;
no semantic consumer branches on them.

After each milestone, run the focused and full suites:

```bash
cabal test keiro-dsl-test --test-show-details=direct
cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
cabal test keiro-dsl-conformance-id-domain-migration --test-show-details=direct
cabal test all --test-show-details=direct
```

Expected through Milestone 4: every suite passes with zero regenerated
fixtures — fingerprint bytes are the acceptance criterion, so any conformance
fixture that "needs" regeneration before Milestone 5 is a defect in the
change, not in the fixture.  Expected at Milestone 5: exactly the fingerprint
bearing fixtures regenerate, and nothing else about generated output changes.

Close with repository gates and ADR validation:

```bash
cabal build all
nix flake check
okf log add docs/adr --kind Update -m "Record runtime capability profiles, the frozen canonical fingerprint encoder, and the widened snapshot hash (plan 181)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```


## Validation and Acceptance

Acceptance is behavioral and byte-precise:

- Through Milestone 4, every fold surface, fold fingerprint, gate result,
  diff, and replay-impact classification recorded in Milestone 0 is
  byte-for-byte unchanged, proved by the pinned tests — including
  `d0897c163c958108` for the canonical scalar fixture.
- The registry monotonicity test fails if a hypothetical successor drops a
  capability; exhaustive matching forces every new capability to choose a fold
  segment explicitly; language 2 to 3 proves a `Just` contributor moves the
  fingerprints while language 3 to 4 proves the two new `Nothing` contributors
  do not.
- No code outside the registry module compares runtime-semantics strings
  (enforced by test); enforcement can no longer silently revert to legacy for
  an unlisted version because there is no list to forget.
- Computing a fold surface for an unresolvable spec returns an explicit error;
  diff, replay-impact, and scaffold planning propagate/refuse that error; tests
  prove the old silent-truncation path is gone with deliberately broken type
  graph, nominal, register, guard, and output-mapping inputs.
- Independently reordering the old or new guard-disambiguated sibling
  transitions does not change any replay-impact classification (permutation
  tests).
- The identity/evolution `Spec`-only wrappers named in Milestone 4 no longer
  exist; `cabal build all` proves every internal caller migrated.
- After Milestone 5, fold fingerprints are exactly 32-hex-character tokens, all
  conformance suites pass against regenerated fixtures, ADR 0003 documents
  the width and the frozen-encoder contract, and ExecPlan 179's pinned values
  are updated with a note in its living sections.  Read-model shape hashes,
  mapped-wire fingerprints, and behavior keys retain their pinned 64-bit bytes.

The work is accepted only when `cabal test all`, `cabal build all`,
`nix flake check`, and strict ADR validation all pass at the final state.


## Idempotence and Recovery

Milestones 0 through 4 are byte-preserving by construction and can each be
reverted independently; the Milestone 0 pins are the recovery oracle — if any
of them fails unexpectedly at any point, stop, record the discrepancy in
Surprises & Discoveries, and restore the last passing state rather than
updating a golden.  Never update a Milestone 0 golden before Milestone 5.
Milestone 5 is the single deliberate identity break: land it as one commit
that changes the hash, regenerates fixtures, and updates pins together, so a
revert is also a single commit.  If ExecPlan 179 is still before its
Milestone 3 when this plan reaches Milestone 5, pause and finish 179's ledger
first; the ordering is a hard dependency, not a preference.


## Interfaces and Dependencies

All work is inside `keiro-dsl` (canonical URI
`mori://shinzui/keiro/packages/keiro-dsl`), with fingerprint-width fallout in
generated output consumed by `keiro-core` conformance fixtures.  The
effective interfaces at the end:

```haskell
data RuntimeCapability
  = GeneratedIdDomainTypeIdV7
  | NominalEqualityV2
  | ContractIdDomainTypeIdV7
  | StrictSpecSurfaceValidation
  deriving stock (Eq, Ord, Show)

data RuntimeSemanticsProfile   -- constructor private to the registry module
runtimeProfileIdentifier :: RuntimeSemanticsProfile -> Text
runtimeProfileHasCapability :: RuntimeSemanticsProfile -> RuntimeCapability -> Bool
capabilityFoldSegment :: RuntimeCapability -> Maybe Text
runtimeProfileFoldSegments :: RuntimeSemanticsProfile -> [Text]

effectiveRuntimeProfile :: EffectiveLanguageContract -> RuntimeSemanticsProfile
effectiveRuntimeSemantics :: EffectiveLanguageContract -> Text

-- Keiro.Dsl.CanonicalEncoding (frozen; goldens pin its bytes)
canonicalExpr :: Expr -> Text
canonicalTransition :: Transition -> Text
foldFingerprint128 :: Text -> Text

aggregateFoldSurfaceForService
  :: CheckedService -> Aggregate -> Either FoldSurfaceError Text
aggregateFoldFingerprintForService
  :: CheckedService -> Aggregate -> Either FoldSurfaceError Text

diffServices
  :: CheckedService -> CheckedService -> Either FoldSurfaceError [Change]
replayImpactServices
  :: CheckedService -> CheckedService -> Either FoldSurfaceError ReplayImpact
```

`LanguageDefinition` carries the profile in place of the raw semantics
string while continuing to expose the identifier text for records and JSON.
The `Spec`-only fingerprint, replay-impact, diff, and nominal wrappers are
removed; callers that deliberately need legacy/version-1 behavior can construct
a `CheckedService` with `legacyCheckedService`.  Other pre-existing documented
compatibility wrappers remain outside this plan's API cleanup.  No new external
dependency is required: the fold-only FNV-1a-128 implementation is local, and
its constants, modulo arithmetic, UTF-8 behavior, and golden vectors are pinned
in tests and documented in ADR 0003.


## Revision Note

2026-08-02: Before implementation, re-audited the plan against the current
working tree and its relevant ADRs.  The revision adds the post-plan
language-4 strict-validation capability from ExecPlan 180, replaces the still
order-dependent replay fallback with canonical sorted multiset pairing,
propagates total fold-surface errors beyond the leaf API, narrows hash widening
to aggregate fold identity so unrelated persisted 64-bit identities do not
move, and corrects the claim about the repository's remaining documented
legacy wrappers.  The untouched 482-example focused suite passed before these
changes, and ExecPlan 179's guarantee ledger is closed far enough for the final
coordinated fingerprint invalidation.
