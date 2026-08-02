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
one list when version 5 arrives silently reverts ID-domain enforcement or
nominal-equality semantics to their legacy behavior with no diagnostic.
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
fallback.

The change is observable: after every milestone except the final hash
widening, all existing fold fingerprints, fold surfaces, diff results, and
replay-impact classifications are byte-for-byte unchanged (proved by tests
pinned before the refactor), and a new negative registry test demonstrates
that an experimental fifth profile with a non-fold capability moves nothing.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 0: pin the current fingerprint, surface, gate, and
  classification bytes as the no-drift baseline.
- [ ] Milestone 1: introduce `RuntimeCapability` and `RuntimeSemanticsProfile`,
  rewrite every string gate, and add registry monotonicity tests.
- [ ] Milestone 2: derive the fold-surface version segment from declared fold
  segments on capabilities, byte-identical for versions 1-4.
- [ ] Milestone 3: extract the frozen canonical fingerprint encoder, make fold
  surfaces total, and point replay-impact comparison at it.
- [ ] Milestone 4: deterministic replay-impact transition pairing and removal
  of the `Spec`-only legacy entry points.
- [ ] Milestone 5: widen the fingerprint hash beyond 64 bits in one
  coordinated invalidation before the `0.9.0.0` release.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (pre-plan audit, 2026-08-01): the string-membership gates are
  real and already three-deep.  `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` enables
  generated-ID enforcement via
  ``effectiveRuntimeSemantics ... `elem` ["keiro-dsl/runtime-semantics/2", "keiro-dsl/runtime-semantics/3"]``
  with `otherwise -> Nothing` (legacy unchecked), and contract-ID enforcement
  via equality with `".../3"`; `keiro-dsl/src/Keiro/Dsl/NominalType.hs`
  derives `"keiro-dsl/nominal-equality/2"` from the same gate.
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
- Decision: Capabilities are monotone across successors, and a registry test
  enforces it: every version's capability set must be a superset of its
  predecessor's.
  Rationale: all three shipped semantic changes (generated-ID enforcement,
  nominal-equality v2, contract-ID enforcement) are "enforced since
  generation N" facts; encoding monotonicity as a test converts the
  forget-one-list failure mode into a red test.
  Date: 2026-08-01
- Decision: A capability declares its own optional fold-surface segment token
  (`Maybe Text`), the profile's segment set is the deduplicated ascending
  union, and the default for a new capability is `Nothing`.
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
- Decision: Remove the `Spec`-only legacy entry points (`Spec`-typed
  fingerprint, surface, replay-impact, diff, and nominal functions that route
  through `legacyCheckedService`) rather than deprecate them, keeping
  `legacyCheckedService` itself as the single explicit opt-in bridge.
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

(To be filled during and after implementation.)


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
`NominalType.hs`.

ExecPlan 179 (`docs/plans/179-generate-one-human-readable-authoritative-keiro-transducer.md`)
depends on this machinery staying put: its guarantee ledger pins fingerprint
`d0897c163c958108` for the canonical scalar fixture, and its Context section
prohibits editing `renderExpr`/`renderTransition` precisely because this plan
has not yet frozen the encoding.  ExecPlan 178 established the current
version-4 gates this plan rewrites.

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

Milestone 0 pins the baseline.  Add tests that record, for every aggregate
fixture in the repository (at minimum the scalar-expressions, nominal-scalars,
id-domain-migration, workspace-nominals, and behavior-complete trees): the
complete fold-surface text, the fold fingerprint, the
`runtimeSemanticsFingerprintSegment` result for all four versions, the
`idDomainContractFor`/`contractIdDomainContractFor`/nominal-equality gate
results for all four versions, and the diff plus replay-impact classification
for a representative unchanged and changed pair.  Commit the surface texts as
golden files.  These tests are the no-drift proof reused by every later
milestone; they must pass against the unchanged code before any edit.

Milestone 1 introduces the capability model in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` (or a sibling module if size
demands): a `RuntimeCapability` sum naming today's shipped behaviors —
indicatively `GeneratedIdDomainTypeIdV7`, `NominalEqualityV2`, and
`ContractIdDomainTypeIdV7`, with exact names chosen from the gate semantics
during implementation — and a `RuntimeSemanticsProfile` with a private
constructor, the existing identifier string, and the capability set.
Registry rows: semantics 1 = empty set; semantics 2 = generated-ID and
nominal-equality capabilities; semantics 3 = those plus the contract-ID
capability.  Rewrite the gates in `IdDomain.hs` and `NominalType.hs` to
`profileHasCapability`, delete the string comparisons, and give the
`SemanticContract.hs` `FromJSON` mismatch a real error message.  Add registry
tests: monotonicity across successors, and a test that every capability is
queried through the profile API (no remaining
`effectiveRuntimeSemantics ... ==`/`elem` comparison outside the registry
module, enforced by a source grep in the test or by removing
`effectiveRuntimeSemantics` from the public API in favor of the profile).
Milestone 0's gate baselines must pass unchanged.

Milestone 2 replaces `runtimeSemanticsFingerprintSegment`'s hand-maintained
table.  Each capability carries `capabilityFoldSegment :: Maybe Text`; the
generated-ID and nominal-equality capabilities both carry
`Just "semantic-contract:keiro-dsl/runtime-semantics/2"` (the frozen legacy
spelling), the contract-ID capability carries `Nothing` (it changes contract
DTO decoding, not folds — exactly the carve-out 178 hand-coded), and the
profile-level segment list is the deduplicated ascending union.  Add a test
registering a synthetic experimental profile with one new `Nothing`-segment
capability and asserting every fixture fingerprint is unchanged, plus a test
that a `Just`-segment capability moves them.  Milestone 0's segment and
fingerprint baselines must pass byte-identical for versions 1-4.

Milestone 3 freezes the encoder and makes surfaces total.  Create
`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs` containing the canonical
expression and transition renderers as they exist today (initially by moving
or duplicating the relevant `PrettyPrint` logic; byte-identical output is the
acceptance bar, enforced by the Milestone 0 goldens), with a module comment
declaring the freeze contract: this module's output feeds persisted identity
and may change only with an explicit, ADR-recorded migration.  Point every
`FoldFingerprint.hs` and `ReplayImpact.hs` rendering call at it and remove
their `PrettyPrint` imports.  Then make the fold surface total: computing a
surface for a service whose type graph, nominals, guards, or output mappings
do not resolve becomes an explicit error (`Either FoldSurfaceError`) instead
of silently dropping segments; the raw-source register fallback and the
derived-`Show` rendering are removed.  Audit all call sites — CLI, workspace,
diff, replay, scaffold, tests — so surfaces are computed only for validated
`CheckedService` values, and thread the error where a caller could previously
receive a truncated surface.  After this milestone, `PrettyPrint.hs` is free
presentation surface again; record that in 179's prohibition note if 179 is
still in flight.

Milestone 4 hardens replay pairing and deletes the legacy traps.  In
`ReplayImpact.hs`, replace text-equality `sameSurface` with comparison of
canonical-encoder output (identical bytes today, per Milestone 3) and replace
the greedy `find`-plus-`delete` pairing with a deterministic structural
pairing: pair transitions on (mode, source state, command, canonical guard
text), then pair any leftovers within the same (mode, source, command) group
positionally, so declaration-order permutations of guard-disambiguated
siblings cannot change classifications; add a permutation test proving it.
Remove the `Spec`-only wrappers from `FoldFingerprint.hs`, `ReplayImpact.hs`,
`Diff.hs`, and `NominalType.hs`, update every caller to pass a
`CheckedService`, and note the removals in the changelog as `0.9.0.0`
breaking changes.

Milestone 5 widens the hash.  Replace `fnv1a64` as the fold-fingerprint and
shape-hash algorithm with a deterministic hash of at least 128 bits, chosen
during implementation under these constraints: pure and
dependency-light (a handwritten FNV-1a-128 over the same UTF-8 byte fold is
acceptable; a well-reviewed existing dependency already in the build plan is
also acceptable), byte-stable across platforms and GHC versions, and encoded
in lowercase hex.  This changes every fold fingerprint, every generated
transducer's embedded fingerprint, ADR 0003's discriminator, and ExecPlan
179's pinned `d0897c163c958108` — which is why this milestone runs only after
179's Milestone 3 guarantee ledger has closed and before the coordinated
`0.9.0.0` release is cut, while no production snapshots exist.  Regenerate all
conformance trees, update every pinned fingerprint including 179's (recording
the update in 179's living sections), amend ADR 0003 with the new width and
the canonical-encoder contract, and update both package changelogs.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Confirm the current gate and segment behavior before editing (expected values
shown; record actual output here):

```bash
rg -n "runtime-semantics" keiro-dsl/src/Keiro/Dsl/IdDomain.hs keiro-dsl/src/Keiro/Dsl/NominalType.hs keiro-dsl/src/Keiro/Dsl/SemanticContract.hs
```

Expected: the three string-membership gates described in Context; after
Milestone 1 this search must return only the registry module's identifier
definitions.

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
  capability; the synthetic-profile tests prove a `Nothing`-segment capability
  moves no fingerprint and a `Just`-segment capability moves them.
- No code outside the registry module compares runtime-semantics strings
  (enforced by test); enforcement can no longer silently revert to legacy for
  an unlisted version because there is no list to forget.
- Computing a fold surface for an unresolvable spec returns an explicit error;
  a test proves the old silent-truncation path is gone by asserting the error
  on a deliberately broken spec that previously produced a shorter surface.
- Reordering guard-disambiguated sibling transitions in a source spec does not
  change any replay-impact classification (permutation test).
- The `Spec`-only wrappers no longer exist; `cabal build all` proves every
  internal caller migrated.
- After Milestone 5, fingerprints are 32-hex-character (or wider) tokens, all
  conformance suites pass against regenerated fixtures, ADR 0003 documents
  the width and the frozen-encoder contract, and ExecPlan 179's pinned values
  are updated with a note in its living sections.

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
  deriving stock (Eq, Ord, Show)

data RuntimeSemanticsProfile   -- constructor private to the registry module
runtimeProfileIdentifier :: RuntimeSemanticsProfile -> Text
profileHasCapability :: RuntimeSemanticsProfile -> RuntimeCapability -> Bool
capabilityFoldSegment :: RuntimeCapability -> Maybe Text

-- Keiro.Dsl.CanonicalEncoding (frozen; goldens pin its bytes)
canonicalExpr :: Expr -> Text
canonicalTransition :: Transition -> Text

aggregateFoldSurfaceForService
  :: CheckedService -> Agg -> Either FoldSurfaceError [Text]
```

`LanguageDefinition` carries the profile in place of the raw semantics
string while continuing to expose the identifier text for records and JSON.
The `Spec`-only fingerprint, replay-impact, diff, and nominal wrappers are
removed; `legacyCheckedService` in
`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` remains the single explicit
version-1 bridge.  No new external dependency is required unless the
Milestone 5 hash decision selects one already in the build plan; the decision
and its rationale go in this plan's Decision Log and ADR 0003.
