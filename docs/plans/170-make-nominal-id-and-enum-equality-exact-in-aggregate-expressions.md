---
id: 170
slug: make-nominal-id-and-enum-equality-exact-in-aggregate-expressions
title: "Make nominal ID and enum equality exact in aggregate expressions"
kind: exec-plan
created_at: 2026-08-01T00:15:25Z
intention: "intention_01kyxarnbbet3ajn0995gt65w9"
master_plan: "docs/masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md"
---

# Make nominal ID and enum equality exact in aggregate expressions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a version-2 aggregate guard can compare two values of the same generated or
consumer-bound ID or enum declaration. `command.projectId == register.projectId` and
`register.phase == ProjectPhase.Active` are generated-owned, symbolically checked behavior; authors
no longer need `Text` shadow registers or transition Holes. Values from different declarations or
nominal-to-`Text` comparisons still fail at the expression site.

The implementation remains truthful for finite enums and validated IDs. Keiro retains a checked,
declaration-scoped equality witness, generates a projection through the one shared nominal owner,
and consumes the exact domain constraints and reconstructible counterexamples packaged for Keiki
`0.7.0.0`. A global `NominalEquality a` instance is not the schema authority.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: reverify and adopt released Keiki `0.7.0.0` with `>=0.7 && <0.8` bounds, then add
  focused exact-projection integration probes.
- [x] Milestone 2: add checked declaration-scoped nominal equality capabilities, fingerprints,
  diagnostics, and compatibility classification.
- [x] Milestone 3: generate declaration-scoped ID/enum projection witnesses, exact where the
  construction domain is enforced, and lower same-declaration equality through Keiki without
  exposing ordering or arithmetic.
- [x] Milestone 4: add positive, type-confusion, solver-domain, counterexample, replay, mutation,
  workspace, and fleet-adoption proof plus documentation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-01: `AggregateType.nominalSolverVisibility` explicitly returns `OpaqueOnly` for
  `IdRepresentation` and `EnumRepresentation`, and the capability matrix test expects it. The
  expression resolver already enforces exact operand types and qualified enum literals, so the
  missing surface is solver representation rather than basic nominal type safety.
- 2026-08-01: Keiki 0.6.0.0 `PEq` accepts any `Eq`/`Typeable` carrier, but exact symbolic dispatch
  is limited to a curated scalar registry. Its `FieldProjection` getter is one-way and
  `predicateTranslationExact` currently treats every supported result carrier as exact even when
  the getter image is finite. A `Text` projection alone would therefore make enum syntax compile
  while allowing impossible solver values.
- 2026-08-01: `Keiro.Codec.Nominal.NominalBinding` is already a versioned, fixture-backed total
  isomorphism between a consumer domain type and the complete Keiro-owned representation. Requiring
  a second consumer `NominalEquality` implementation would duplicate and potentially contradict
  that authority.
- 2026-08-01: Keiki public `master` now exposes `ProjectionDomain`, `ExactFieldProjection`,
  `exactFieldWitness`,
  `predicateTranslationReport`, `verifyPredicateDetailed`, and checked `ProjectionModel` values.
  These implement the producer capabilities tracked by
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-3` and
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4`. Hackage now publishes `0.7.0.0`,
  and `v0.7.0.0` resolves to release commit `7c5d433ef4455e9e626347f89cb3a416bad62e72`
  with the same exposed API.
- 2026-08-01: The existing Keiki bound was already `>=0.7 && <0.8` after EP-159. Hackage still
  publishes `0.7.0.0` as the current Keiki release and upstream tag `v0.7.0.0` still dereferences to
  `7c5d433ef4455e9e626347f89cb3a416bad62e72`, so EP-170 required no dependency edit.
- 2026-08-01: `mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid` resolves locally to an older
  checkout, while Hackage and upstream tags publish `0.7.1.1`. The released `parseText` grammar is
  exactly a fixed prefix, underscore, a leading Crockford character in `0..7`, and 25 more
  lower-case Crockford characters; it does not itself enforce UUID version/variant bits.
- 2026-08-01: Generated IDs are still public `newtype Id = Id Text` values under language 2. Their
  equality key is concrete and type-safe, but an exact textual domain would be dishonest because
  callers can construct arbitrary `Text`. Consumer-bound `KindID` IDs and all finite enums can use
  `exactFieldWitness`; generated legacy IDs must retain conservative `fieldWitness` until EP-171
  enforces construction domains.
- 2026-08-01: A fully generated version-2 aggregate needs no transition `Holes` module. Omitting
  that empty create-once surface exposed one stale unit expectation; the generated behavior
  contract and separate `BehaviorHoles` witness inventory remain present and compiled.
- 2026-08-01: Final acceptance passes 431 `keiro-dsl-test` examples, all three affected compiled
  conformance rings, `cabal build all`, strict ADR validation, and native `nix flake check`. The
  dishonest-exact-projection and transposed-enum mutation commands each fail at their named gate,
  proving the baseline does not silently accept either corruption.


## Decision Log

Record every decision made while working on the plan.

- Decision: Store nominal equality as checked declaration metadata and derive consumer equality
  from the existing total `NominalBinding` plus Keiro's canonical representation key.
  Rationale: `check`, diff, fingerprints, and workspace planning run without loading consumer
  Haskell instances. The named/versioned binding already proves a stronger bijection than equality
  needs and is declaration-specific.
  Date: 2026-08-01

- Decision: Do not introduce `class NominalEquality a` as the primary public contract. If a class
  is useful for generated Keiki integration, index it by a declaration/projection tag and return a
  value witness containing domain and reconstruction evidence.
  Rationale: an owner-type instance is global, cannot distinguish two DSL declarations sharing a
  Haskell type, cannot be inspected by the DSL checker, and cannot by itself constrain finite
  solver domains or make instance evolution visible.
  Date: 2026-08-01

- Decision: IDs use their canonical textual representation; enums use their unique declared wire
  text plus a finite domain. Equality is the only capability added.
  Rationale: stable wire keys are already validated and fingerprinted. Ordinal keys would drift
  when constructors are inserted or reordered, and enabling ordering/arithmetic exceeds IR-12.
  Date: 2026-08-01

- Decision: Adopt released Keiki `0.7.0.0` with the normal Keiro range `>=0.7 && <0.8` when this
  plan begins after Plan 168.
  Rationale: Hackage and `v0.7.0.0` expose conservative classification, exact domains, and
  reconstructible models with matching versioned source. The external technical and release
  blockers are gone; Plan 168's shared-owner dependency still determines local execution order.
  Date: 2026-08-01

- Decision: Split ID proof strength at the checked ownership boundary. Consumer-bound `KindID`
  declarations receive exact textual projection domains and reconstruction; generated language-2
  IDs receive the same declaration-scoped textual equality key through a conservative one-way
  witness. Generated and consumer-bound enums remain exact finite domains.
  Rationale: concrete equality stays correct for every admitted Haskell value, while symbolic
  claims remain truthful. EP-171 is the already-planned place to close construction and then
  upgrade generated ID witnesses to exactness under the successor contract.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

All four milestones are complete. Checked declaration metadata now drives capability policy,
fold/scaffold/workspace identities, binding explanations, shared-owner witnesses, and Keiki
lowering. Generated and consumer enum equality is finite and exact; consumer `KindID` equality is
exact over the released decoder grammar; legacy generated ID equality is concrete but
symbolically conservative. The scalar, consumer-bound, and two-member workspace fixtures exercise
both equality branches, replay, exact-domain verification, and shared witness ownership without a
`Text` shadow register or transition Hole. Type-confusion tests reject cross-declaration,
nominal-to-`Text`, and unqualified enum comparisons at source checking. Mutation gates reject a
transposed enum binding and an under-declared exact projection. ADRs 12, 14, and 17 now preserve
the authority, ownership, proof-strength, and empty-Holes decisions; IR-12 and adopter guidance are
updated. EP-171 remains responsible for restricting generated-ID construction and upgrading that
one intentionally conservative witness.


## Context and Orientation

The owning request is
[IR-12](../improvement-requests/make-nominal-id-and-enum-equality-first-class-in-aggregate-expressions.md).
`keiro-dsl/src/Keiro/Dsl/AggregateType.hs` resolves aggregate types and exposes
`AggregateCapability`; IDs and enums currently resolve but are `OpaqueOnly` for equality.
`keiro-dsl/src/Keiro/Dsl/Expression.hs` validates typed roots, qualified enum literals, ID literals,
operand identity, and comparison capabilities. Keep those checks as the source of cross-type
diagnostics.

`keiro-dsl/src/Keiro/Dsl/NominalType.hs` owns `ResolvedNominalType`, generated versus consumer
ownership, representation, binding value, binding version, canonical identity, and fixtures.
`keiro-core/src/Keiro/Codec/Nominal.hs` owns the published total `NominalBinding` law. Scaffold
generation in `Keiro.Dsl.Scaffold` currently emits projection tags only for consumer-bound nominal
scalars; `renderComparisonTerm` excludes IDs and enums.

Plan 168 moves generated IDs/enums to one context-level owner. This plan adds equality witnesses
and projection tags to that owner and must not recreate per-aggregate declarations. Plan 171 later
changes the ID key domain under a successor language contract; this plan must model the domain
explicitly so that change is an evolution record rather than a rewrite.

The dependency is `mori://shinzui/keiki/packages/keiki`. Upstream
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-3` corrects false projection exactness,
and `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4` adds exact domain constraints and
reconstructible projection models. Both implementations are present in the Keiki `0.7.0.0`
release. Hackage and the matching tag were verified on 2026-08-01; repeat that check immediately
before setting Keiro bounds.

[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires one checked binding authority. [ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
requires generated guards to be authoritative. ADR 4 requires mismatched nominal comparisons to
fail in source checking and equality-contract changes to enter evolution gates.


## Plan of Work

Milestone 1 uses Mori to locate released Keiki `0.7.0.0` and inspects its exact projection witness,
domain forms, translation constraints, exactness result, and counterexample reconstruction. After
Plan 168 provides the shared nominal owner, independently reverify that Hackage and upstream
`v0.7.0.0` expose the same API, adopt `>=0.7 && <0.8`, and add focused compile probes. Stop if the
authoritative artifact differs from the inspected source or exposes only an unconstrained one-way
getter.

Milestone 2 extends the checked nominal model with an equality contract derived from declaration
representation and ownership. Generated and bound IDs/enums receive equality capability; scalar
nominals retain their current scalar capabilities. Keep exact declaration identity in typed
operands. Include representation key, domain kind/values, binding qualified name and version, and
contract version in fold fingerprints, scaffold records, diff, compatibility vector, replay
impact, and `--explain-bindings` output. A changed equality contract is guard/fold-affecting where
used.

Milestone 3 generates one declaration-tagged witness per used nominal in the Plan 168 shared owner.
Generated values project directly. Consumer values compose `nominalToRepresentation` with the
Keiro-owned canonical ID/enum key mapping. The witness supplies an unrestricted or validated ID
domain as appropriate and a finite enum domain plus reconstruction. `renderComparisonTerm` lowers
both roots through their canonical witness and emits `PEq` over the key only after the checked DSL
types match. Do not change `PEq` globally or accept arbitrary `Eq` instances.

Milestone 4 expands the aggregate scalar conformance ring and a workspace/fleet fixture. Cover
register-to-command IDs, enum-to-qualified-literal and enum-to-enum comparisons, generated and
consumer ownership, equal and unequal execution, finite-enum exhaustiveness, concrete
counterexample attribution, codec-crossing replay, and all type-confusion failures. Remove a real
`Text` shadow register without adding a Hole. Add mutations for dishonest projection, finite-domain
omission, binding-version drift, and wrong projection tag. Update notation, migration guidance,
guarantee ledger, changelog, and relevant ADR consequences.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
git ls-remote --tags https://github.com/shinzui/keiki.git
cabal test keiro-dsl-test --test-option=--match --test-option='aggregate expression'
cabal test keiro-dsl-conformance-aggregate-scalar-expressions
cabal test keiro-dsl-conformance-nominal-scalars
cabal test keiro-dsl-conformance-workspace-nominals
keiro-dsl/test/conformance-nominal-scalars/mutations/dishonest-exact.sh
keiro-dsl/test/conformance-nominal-scalars/mutations/enum-transpose.sh
cabal test keiro-dsl-test
cabal build all
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix flake check
```

Record the exact Keiki `0.7.0.0` tag/metadata evidence in Progress before changing bounds. Focused
conformance must exercise both branches of every nominal equality guard. Baseline and validation
commands exit zero; each restoring mutation is accepted only when its named conformance gate exits
non-zero.


## Validation and Acceptance

Acceptance requires same-declaration generated IDs and enums and consumer-bound IDs and enums to
compare in generated guards. Qualified enum literals resolve only against the expected enum.
Cross-ID, cross-enum, ID/enum-to-`Text`, and unqualified enum comparisons fail at the expression
location. A finite enum cannot produce an out-of-domain solver model. Counterexamples identify the
guard and projection path. Fingerprints and diffs change when an equality representation or binding
version changes. A fleet-style aggregate removes its shadow `Text` without introducing a Hole.


## Idempotence and Recovery

Dependency adoption is additive until the capability gate flips. Keep IDs/enums `OpaqueOnly` while
compile probes or exact-domain tests fail. Adopt only the released `>=0.7 && <0.8` range; do not pin
the sibling checkout. Generate projections deterministically from the checked graph and use
temporary scaffold output for mutations. If a later authority check differs from the inspected
`0.7.0.0` source, update this plan before selecting bounds.


## Interfaces and Dependencies

The checked Keiro-side model should be equivalent to:

```haskell
data CheckedNominalEquality = CheckedNominalEquality
  { equalityKeyRepresentation :: NominalEqualityKey
  , equalityDomain :: NominalEqualityDomain
  , equalityContractVersion :: Text
  }
```

If an implementation class is exposed, it must be projection-tagged and return a value witness:

```haskell
class NominalEquality projection where
  type EqualityOwner projection
  type EqualityKey projection
  nominalEqualityWitness
    :: proxy projection
    -> NominalEqualityWitness (EqualityOwner projection) (EqualityKey projection)
```

The schema-owned checked value remains authoritative. Existing `NominalBinding domain
representation` supplies consumer conversion; the user does not implement a second equality
function. Keiki 0.7's released domain/reconstruction types are consumed rather than copied into
`keiro-core`.


Revision note: Rebased the upstream integration contract on released Keiki `0.7.0.0`, verified
through Hackage and the matching `v0.7.0.0` tag. Plan 170 can adopt `>=0.7 && <0.8` once Plan 168
satisfies its repository-local hard dependency; no external Keiki blocker remains, 2026-08-01.

Revision note: Completed all milestones with declaration-scoped equality metadata, shared-owner
and consumer projection witnesses, exact finite-enum and consumer-`KindID` domains, conservative
legacy generated-ID verification, compatibility/scaffold identities, three compiled conformance
rings, restoring mutations, adopter documentation, and ADR 12/14/17 amendments. The final 431-
example suite, all-package build, strict ADR validation, and native Nix checks pass, 2026-08-01.
