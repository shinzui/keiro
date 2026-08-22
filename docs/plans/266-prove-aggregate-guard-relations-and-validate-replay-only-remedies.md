---
id: 266
slug: prove-aggregate-guard-relations-and-validate-replay-only-remedies
title: "Prove aggregate guard relations and validate replay-only remedies"
kind: exec-plan
created_at: 2026-08-22T03:59:33Z
intention: "intention_01m0kst1x4ejdsnxmweqv8brne"
---

# Prove aggregate guard relations and validate replay-only remedies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, `keiro-dsl diff` reports a guard-history hazard only when it has sound evidence
that the old guard admits a concrete valuation excluded by the new guard. Harmless Boolean
reassociation, commutation, duplicate terms, and pure loosenings do not claim that history became
unreadable. A strict tightening receives the established `AggGuardTightened` code and a
replay-only transition only after the removed region is proved non-empty and the rendered remedy
round-trips and validates under the candidate Language-1-through-5 contract. An incomparable
replacement and an undecidable relationship receive distinct truthful diagnostics.

The plan preserves conservatism: every affirmative satisfiable or unsatisfiable answer is exact
for the supported proof fragment, while unsupported arithmetic, opaque behavior, incompatible
types, resource limits, or validation failures return `Unknown`. `Unknown` carries the same
private-history safety vector as a tightening and never prints a guessed remedy. Keiki and runtime
hydration remain unchanged; the existing replay-only and database replay-audit layers continue to
defend deployment independently.

This plan depends on
[ExecPlan 265](265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md),
which supplies order-independent exact sibling cancellation and the append-only
`AggGuardRelationUnknown` code. It completes the semantic and remedy-validation portions of
IR-33.


## Progress

- [ ] Confirm ExecPlan 265 is complete and re-establish Keiki dependency evidence through Mori
      before changing any proof boundary.
- [ ] Add a typed, pure, three-valued guard proof engine with sound Boolean-unsatisfiability and
      concrete finite-domain witness tests.
- [ ] Compare unions of guards by replay-equivalent transition body and share the resulting
      relation between ordinary diff and replay-impact analysis.
- [ ] Add truthful append-only diagnostics for incomparable replacements and unavailable remedies,
      and integrate compatibility vectors and machine-readable remediations.
- [ ] Prove existing replay-only coverage before suppression; construct, render, parse, and
      validate every newly suggested twin, including Language-5 domain outcomes.
- [ ] Cover equivalent, loosened, tightened, replaced, unknown, stale-twin, partial-twin, and
      Languages-1-through-5 compatibility cases in unit, CLI, and runtime safety tests.
- [ ] Update evolution guidance, CHANGELOG, IR-33, relevant ADRs, and run all package, OKF, and
      disposable Mori acceptance gates.


## Surprises & Discoveries

- Observation: `CheckedService` is a normalized spec paired with an effective language contract
  and lazy type/projection analyses; its constructor does not prove that `validateService` has no
  errors. A semantic guard result must therefore handle expression-resolution failure explicitly,
  and a remedy must be validated rather than trusting the type name.
  Evidence: `CheckedService`, `checkedServiceWithSpec`, and `checkedTypeGraph` in
  `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`; `validateService` in
  `keiro-dsl/src/Keiro/Dsl/Validate.hs`.

- Observation: the current replay-only suppression accepts any candidate replay-only transition
  with the same source and command. It does not compare guard coverage, writes, emits, target, or
  behavior ownership. An unrelated or stale retained edge can therefore hide a later real
  tightening.
  Evidence: local helper `hasReplayOnlyTwin` in
  `keiro-dsl/src/Keiro/Dsl/Diff.hs`.

- Observation: current twin construction copies the entire old `Transition` and changes only
  guard and mode. In Language 5 that copies `tOutcome`, but the validator rejects a replay-only
  transition carrying a forward domain outcome as `DomainOutcomeReplayOnlyClause`.
  Evidence: `guardTighteningDiff` in `keiro-dsl/src/Keiro/Dsl/Diff.hs`, `docTransition` in
  `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, and `transitionOutcomeRules` in
  `keiro-dsl/src/Keiro/Dsl/Validate.hs`.

- Observation: the released Keiki 0.9.1.0 solver surface is conservative but not a drop-in API for
  this diff. `verifyPredicate` accepts a statically typed `HsPred rs ci` and performs solver work
  in `IO`; Keiro currently has dynamically resolved `TypedScalarExpr` values and a pure
  `diffServices` API.
  Evidence: Mori registration `mori://shinzui/keiki/packages/keiki` and
  `Keiki.Symbolic.verifyPredicate`. Hackage preferred versions and the upstream `v0.9.1.0` tag
  agreed at plan creation on 2026-08-21.

- Observation: full decision for every syntactically supported guard is impossible in general.
  The language includes multiplication over unbounded `Integer`, which reaches nonlinear integer
  satisfiability. A truthful `Unknown` result is therefore part of the product contract, not a
  temporary implementation gap.


## Decision Log

- Decision: A guard query has three proof outcomes: proved unsatisfiable, proved satisfiable with
  a concrete re-evaluable witness, or unknown with a reason.
  Rationale: suppressing a history warning requires an unsatisfiability proof; printing a remedy
  requires evidence that the removed region is real. Solver or abstraction uncertainty must not
  be coerced into either result.
  Date: 2026-08-21

- Decision: Implement the first proof engine inside Keiro without changing Keiki.
  Rationale: Boolean structural equivalence and finite Bool/generated-enum witnesses cover the
  requested harmless rewrites and the established genuine-tightening fixture. Keiki's current
  typed `HsPred`/`IO` surface would require a new cross-repository dynamic solver interface and
  release, while a conservative local engine can return `Unknown` for everything outside its
  exact fragment. Broader Keiki integration is a later optimization only if measured unknown
  rates justify it.
  Date: 2026-08-21

- Decision: Use a propositional over-approximation only to prove unsatisfiability; never treat its
  satisfying assignment as a concrete DSL witness.
  Rationale: treating comparisons as independent Boolean atoms can invent impossible assignments,
  such as one value simultaneously equalling two distinct enum constructors. If the
  over-approximation is unsatisfiable, the concrete expression is also unsatisfiable. If it is
  satisfiable, Keiro must construct and re-evaluate a concrete finite-domain valuation or return
  unknown.
  Date: 2026-08-21

- Decision: Classify both `old AND NOT new` and `new AND NOT old`.
  Rationale: the first region establishes the replay hazard; the second distinguishes a strict
  tightening from an incomparable replacement. Calling every change with a removed component a
  tightening is semantically inaccurate.
  Date: 2026-08-21

- Decision: Compare the union of live guards for one replay-equivalent body rather than pair
  individual siblings.
  Rationale: several declarations may split one behavior into alternative guards without changing
  its replay meaning. Union comparison is invariant under splitting, merging, duplication, and
  declaration order. Body changes remain independently owned by fold-surface and replay-impact
  findings and are not disguised as guard-only evolution.
  Date: 2026-08-21

- Decision: Suppress a finding for existing replay-only transitions only after their same-body
  guard union is proved equivalent to the removed region and the candidate service validates.
  Rationale: live-first replay makes an overlapping superset operationally tolerant, but IR-33's
  remedy contract is semantic exactness. Exact coverage prevents stale or unrelated twins from
  hiding a hazard and keeps the retained rule auditable.
  Date: 2026-08-21

- Decision: A generated twin clears all forward-only outcome fields and is advertised only after
  whole-spec render/parse and candidate-language validation succeed.
  Rationale: `renderTransition` alone proves presentation, not that the pasted transition is legal
  under the candidate language or domain-outcome rules. A failed proof becomes
  `AggGuardRemedyUnavailable`, not an invalid paste suggestion.
  Date: 2026-08-21

- Decision: Semantic normalization is analysis-only and never changes source ASTs, canonical
  encoding, pretty printing, or fold fingerprints.
  Rationale: ADR 0018 freezes canonical fold bytes. Semantically equivalent source may still
  produce the independent `AggFoldSurfaceChanged` advisory and snapshot invalidation; removing the
  guard-history warning must not erase that fact.
  Date: 2026-08-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan begins only after ExecPlan 265 lands. Its internal
`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` groups transitions by mode, source, and command,
cancels exact replay identities as a multiset, and returns canonical-order remainders. It also
establishes `AggGuardRelationUnknown`, a private-history advisory with a do-not-deploy/audit
remediation. Read that completed plan and its Progress, discoveries, and Decision Log before
implementation; do not recreate its cancellation algorithm.

The originating request is
`docs/improvement-requests/make-aggregate-guard-diffs-idempotent-and-semantically-exact.md`
(IR-33). The relevant package uses this canonical handle:

`mori://shinzui/keiro/packages/keiro-dsl`

The real adopter evidence uses these canonical plan handles:

- `mori://shinzui/mori/plans/223-move-the-mori-workspace-to-keiro-dsl-language-5`
- `mori://shinzui/mori/plans/236-model-project-releases-in-the-registry`

Use a disposable clone of `mori://shinzui/mori/repos/mori` for acceptance; never edit its
registered checkout.

A *guard* is the Boolean expression attached to a transition. Absence of a guard means logical
true. For old guard `O` and new guard `N`, the *removed region* is `O && !N`: command/register
valuations once accepted but now rejected. The *added region* is `N && !O`. The logical negation
is rendered without adding syntax by `complementExpr` in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`, which applies De Morgan's laws, flips comparisons, and
negates Boolean atoms.

The relation names used by this plan are exact:

- equivalent: both removed and added regions are proved unsatisfiable;
- loosening or old-domain preserving: the removed region is proved unsatisfiable and the added
  region is satisfiable or unknown;
- strict tightening: the removed region is proved satisfiable and the added region is proved
  unsatisfiable;
- incomparable replacement: both regions are proved satisfiable;
- unknown: the removed region cannot be decided, or it is satisfiable while the added region
  cannot be decided well enough to name strict tightening versus replacement.

Only the first region determines whether old history may lose an inverting edge. Therefore, a
proved-unsatisfiable removed region produces no guard-history diagnostic even if the added region
is unknown. Independent source/fold findings remain.

`keiro-dsl/src/Keiro/Dsl/Expression.hs` resolves syntax to `TypedScalarExpr`. Each node retains a
resolved scalar type and becomes a typed literal, root, structural projection, arithmetic term,
comparison, conjunction, or disjunction. Use `expressionEnvironmentFromGraphResult` with each
side's `CheckedService`, aggregate, and representative transition. Roots from the two services
may be treated as the same proof variable only when command/register provenance, complete path,
and canonical resolved type agree. A type, nominal binding, or projection-provenance mismatch is
unknown for guard relation purposes; the ordinary diff still reports its independent structural
or build consequences.

The initial exact satisfiability fragment is deliberately bounded. Boolean structure over
canonical atomic predicates is converted to a reduced, ordered decision representation with a
deterministic atom ordering and explicit complement pairs. This can soundly prove a Boolean
formula unsatisfiable even when the atom's scalar theory is opaque. A satisfiable answer requires
exhaustive concrete evaluation over finite exact domains: Bool and generated or otherwise
reconstructable nominal enums. Unsupported roots such as Text, Time, IDs, Int, Integer, Natural,
consumer-owned one-way projections, arithmetic terms, opaque Hole behavior, or a configured
decision-node/model-space limit return unknown unless Boolean simplification already proved
unsatisfiability. Do not approximate an infinite domain with samples.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` owns `AggGuardTightened` and its private-history vector.
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` owns audit targeting. Both must consume the same guard
relation. `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` owns remedies and JSON encoding.
`keiro-dsl/src/Keiro/Dsl/Validate.hs` owns append-only diagnostic codes and whole-service
validation. `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` supplies `renderSpec` and
`renderTransition`; `keiro-dsl/src/Keiro/Dsl/Parser.hs` and language-version entry points supply
the round trip.

The candidate replay-only body must preserve the old replay behavior: behavior ownership,
ordered writes, emitted event word, and target. The mode changes to replay-only, guard changes to
the removed region, and `tOutcome` plus duplicate outcome locations are cleared because outcomes
exist only for forward command decisions. Source locations are presentation evidence, not body
identity.

Relevant decisions are:

- [ADR 0002](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
  defines replay-only edges, live-first inversion, and the retained-edge lifecycle.
- [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  requires cross-spec hazards at diff while runtime validation and database replay audit remain
  independent defenses.
- [ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  defines `CheckedService`, effective language contracts, and symmetric semantic inputs.
- [ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  makes generated expressions authoritative and requires Hole behavior to remain honestly opaque.
- [ADR 0018](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
  freezes canonical fold encoding and requires sibling-order-independent replay comparison.

[ExecPlan 143](143-add-first-class-replay-only-transitions-for-guard-evolution.md) supplies the
runtime black-acuity proof: history fails without a twin, succeeds through the twin, and a new
command in the removed region remains rejected. This plan changes no Keiki runtime semantics.


## Plan of Work

### Milestone 1 — Build a sound three-valued proof engine

Create the internal module `keiro-dsl/src/Keiro/Dsl/GuardRelation.hs` and register it under
`other-modules` in `keiro-dsl/keiro-dsl.cabal`. Define types equivalent to the following
conceptual interface; choose repository-consistent field names but preserve these distinctions:

```haskell
data RegionProof
  = RegionUnsatisfiable
  | RegionSatisfiable GuardWitness
  | RegionUnknown GuardUnknownReason

data GuardRelation
  = GuardEquivalent
  | GuardOldDomainPreserved
  | GuardStrictlyTightened Expr GuardWitness
  | GuardRegionReplaced Expr GuardWitness GuardWitness
  | GuardRelationUnknown GuardUnknownReason
```

`GuardWitness` is internal evidence mapping canonical roots to concrete `ScalarValue`s. It must be
re-evaluated through an exact evaluator for the resolved typed expression before
`RegionSatisfiable` is returned. `GuardUnknownReason` must distinguish at least resolution/type
mismatch, opaque ownership or projection, unsupported/infinite theory, proof-resource limit, and
concrete-model reconstruction failure so human diagnostics and tests can tell why no claim was
made.

Resolve both sides with their own checked type graph and transition environment, then translate
them into one comparison representation. Canonicalize equality operand order, flatten and sort
conjunctions/disjunctions, remove duplicate children, apply true/false identities, and recognize
the exact complement pairs already expressible by `complementExpr`. Keep this representation
private; never feed it to `CanonicalEncoding` or write it back into `Spec`.

Use a deterministic reduced ordered Boolean decision structure, or an equivalently exact
truth-table algorithm with a documented hard limit, over canonical atomic predicates. An
unsatisfiable result from this propositional over-approximation is a valid concrete
unsatisfiability proof. When it is satisfiable, enumerate the complete Cartesian product only when
every referenced root has a finite exact domain and the configured product limit is not exceeded.
Evaluate every candidate against the typed expression; return the first canonical satisfying
witness. If exhaustive finite enumeration yields none, return unsatisfiable. Otherwise return
unknown. No timeout, exception, unsupported node, or exhausted limit may become satisfiable or
unsatisfiable.

Add focused and property tests in `keiro-dsl/test/Main.hs`. For bounded generated Boolean/enum
expressions, compare every proof answer against exhaustive concrete truth tables. Pin association,
commutation, idempotence, absorption, complementary comparison, pure loosening, strict tightening,
replacement, repeated-root consistency, contradictory enum equalities, and proof-limit cases.
Add nonlinear `Integer` multiplication and opaque/Hole examples that return unknown rather than a
false proof.

Milestone acceptance is that every returned proof agrees with exhaustive semantics in the finite
test universe, and all unsupported cases remain explicitly unknown.

### Milestone 2 — Classify guard unions once for diff and replay impact

Extend `keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` with a replay-body key that excludes guard,
mode, source location, and forward-only outcome while retaining behavior ownership, ordered
writes, emitted events, and target. Work only inside an exact-cancellation family from ExecPlan
265. Group remaining live transitions by this body key and represent absent guard as true and
multiple sibling guards as their disjunction. An old body with no corresponding new body is a
body/fold change owned by existing analyses; a new-only body is additive. Only a body present on
both sides enters guard-relation classification.

Replace the one-to-one raw guard path in `keiro-dsl/src/Keiro/Dsl/Diff.hs` with the shared
`GuardRelation`. The result rules are:

- equivalent or old-domain-preserved: no guard-history diagnostic;
- strict tightening: `AggGuardTightened`, subject to remedy verification in Milestone 3;
- incomparable replacement: append-only `AggGuardRegionReplaced`, subject to the same removed-
  region remedy verification;
- unknown: `AggGuardRelationUnknown`, same private-history vector, reason in detail, no twin.

Append `AggGuardRegionReplaced` to `DiagnosticCode` and its origin registries. Give it the same
private-history vector as `AggGuardTightened`, because its removed component can make old events
unreadable. Its text must explicitly state that the new guard both adds and removes valuations.
Map it to the replay-only remedy only after Milestone 3 proves a valid remedy exists.

Replace `ReplayImpact`'s private syntactic `guardImplies`/`cancelLoosenings` authority with the same
relation. Equivalent and old-domain-preserving groups contribute no affected event type. Strict
tightenings and replacements contribute only the same-body emitted events and snapshot inclusion
required by the established replay contract. Unknown remains conservatively affected. Body
changes continue through existing replay-impact logic. Keep the released replay-impact JSON shape
unchanged.

Milestone acceptance is agreement across text, JSON, and replay impact: semantic equivalence and
loosening have no guard-history finding and no guard-derived audit target; tightening and
replacement identify only their affected aggregate/event types; unknown stays audit-targeted.
Independent `AggFoldSurfaceChanged`, catalog, ownership, and source findings remain present.

### Milestone 3 — Prove existing coverage and validate every suggested remedy

Delete the source/command-only `hasReplayOnlyTwin` rule. For each proved removed region, collect
candidate replay-only transitions with the same source, command, and replay-body key. Disjoin their
guards and use the same relation engine to prove both `removed => candidateUnion` and
`candidateUnion => removed`. Suppress the hazard only when both removed differences are proved
unsatisfiable and `validateService` reports no errors for the candidate. A stale, unrelated,
partial, excessive, differently emitting, differently writing, differently targeted, or
Hole-owned replay-only sibling must not suppress the finding. Coverage uncertainty must remain a
guard finding or become `AggGuardRelationUnknown`; never silently accept it.

When no exact existing coverage is present, construct a twin from a representative old transition
in the same replay-body group. Set its guard to the exact syntax expression
`oldGuardUnion AND complement(newGuardUnion)`, using `complementExpr`; set mode to
`TmReplayOnly`; set `tOutcome = Nothing`; clear `tOutcomeDuplicateLocs`; and use neutral source
locations. Preserve ownership, ordered writes, emits, and target. Do not simplify the source AST
with the analysis normalizer.

Insert the proposed twin into a copy of the candidate spec using `checkedServiceWithSpec`. Render
the full candidate with its effective language-version preamble, parse it back through the normal
language entry point, reconstruct a checked service, and run `validateService`. Compare the
round-tripped semantic transition with the proposed transition modulo locations. Only after all
steps succeed may `Diff.hs` call `renderTransition` and map the finding to
`RemedyReplayOnlyEdge`.

Append `AggGuardRemedyUnavailable` for a relation whose removed region is proved real but whose
twin cannot round-trip or validate. Give it the private-history advisory vector and
`RemedyDoNotDeploy` containing the parse/validation reason; do not print the failed transition.
This distinguishes a known hazard with an unavailable mechanical remedy from an undecidable guard
relationship.

Extend the existing reservation tightening fixtures and tests. Add exact, partial, stale, and
unrelated twin cases. Add a Language-5 `domain-outcomes` tightening whose old live transition has
an accepted outcome; assert the printed replay-only twin contains no `outcome` clause, the pasted
source parses and validates, and re-diffing suppresses the hazard. Add a body-mismatch case proving
that matching source/command alone is insufficient.

Milestone acceptance is that every printed twin is parse-valid, candidate-valid, exact in guard
coverage, and replay-body equivalent; every inadequate existing twin leaves a truthful hazard.

### Milestone 4 — Close the end-to-end contract

Expand `keiro-dsl/test/diff-test.sh` so Git-backed text and JSON cover equivalent ACI rewrites,
loosening, tightening, replacement, unknown, exact existing twin, and invalid/partial twin. Assert
the codes, vectors, and remedies rather than scraping only prose. Re-run the existing Keiro
black-acuity and replay-audit examples from ExecPlan 143: without the twin hydration/audit fails;
with it history replays; a new removed-region command remains rejected. No runtime implementation
change is expected.

Run the local `keiro-dsl` binary against a disposable clone identified by this canonical handle:

`mori://shinzui/mori/repos/mori`

Its identical `HEAD` diff remains empty and replay-neutral after semantic classification is
enabled. Record any non-identical experimental guard cases separately; do not rewrite Mori as part
of this plan.

Update `docs/guides/evolution-and-replayability.md` with the exact relation vocabulary, unknown
deployment rule, incomparable replacement, and existing-twin coverage requirements. Add an entry
to `keiro-dsl/CHANGELOG.md`. Update ADR 0002's computed-remedy wording, ADR 0004's diff-gate
inventory, and ADR 0018's replay comparison statement if the final implementation establishes the
durable rules described here. Preserve profile metadata and log every timestamp change.

After every validation gate passes, update IR-33's status and body to link both ExecPlans and
record the exact supported proof fragment and `Unknown` contract. Append the implemented entry to
`docs/improvement-requests/log.md` with `okf log add`; do not mark the request implemented before
the real Mori, CLI, and full-suite evidence exists.

Milestone acceptance is the complete IR-33 behavior, all Languages 1–5 compatibility evidence,
the unchanged runtime safety proof, and strict OKF validation.


## Concrete Steps

At the start of implementation, verify the prerequisite and dependency rather than relying on the
version observed while this plan was written:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro

rg -n '^-[[:space:]]+\[ \]' docs/plans/265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md
mori registry search keiki
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
```

The first command must print no unchecked Progress item. Mori should resolve this canonical
dependency handle:

`mori://shinzui/keiki/packages/keiki`

If implementation proposes any Keiki bound, pin, or API work despite this plan's boundary, stop
and create a separately reviewed dependency plan after checking Hackage and upstream tags; do not
expand this plan silently.

Run focused proof and diff tests while implementing:

```bash
cabal test keiro-dsl-test --test-options='--match "guard relation"'
cabal test keiro-dsl-test --test-options='--match "guard tightening"'
cabal test keiro-dsl-test --test-options='--match "replay impact"'
cabal test keiro-dsl-conformance-domain-outcomes
bash keiro-dsl/test/diff-test.sh
```

Expected focused behavior is comparable to:

```text
equivalent: no guard-history finding
old-domain-preserved: no guard-history finding
strict-tightening: AggGuardTightened with validated replay-only remedy
replacement: AggGuardRegionReplaced with validated replay-only remedy
unknown: AggGuardRelationUnknown without replay-only remedy
```

Run the runtime safety proof. Hspec match strings may need quoting adjustment, but do not broaden
the test by changing its assertions:

```bash
cabal test keiro-test --test-options='--match "guard tightening"'
cabal test keiro-test --test-options='--match "black-acuity"'
cabal test keiro-test --test-options='--match "replay-only twin"'
```

Run the disposable Mori proof exactly as in ExecPlan 265, using the newly built executable:

```bash
keiro_dsl_bin="$(cabal list-bin exe:keiro-dsl)"
mori_source="$(mori path mori://shinzui/mori/repos/mori)"
guard_proof_scratch="$(mktemp -d "${TMPDIR:-/tmp}/keiro-guard-proof.XXXXXX")"
git clone --local --no-hardlinks "$mori_source" "$guard_proof_scratch/mori"

cd "$guard_proof_scratch/mori"
"$keiro_dsl_bin" diff domain/mori.keiro-workspace --since HEAD \
  --report-out "$guard_proof_scratch/mori-diff.json" \
  --replay-impact-out "$guard_proof_scratch/mori-replay.json"
jq '{breaking, findings: [.findings[] | {code, vector, remedies}]}' \
  "$guard_proof_scratch/mori-diff.json"
jq . "$guard_proof_scratch/mori-replay.json"
```

The identical-source result must contain no findings and must be replay-neutral. Delete only the
validated `guard_proof_scratch` temporary directory, never the Mori source.

Run the complete repository validation from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal build all
cabal test keiro-dsl:tests
cabal test keiro-test
nix fmt -- --check
git diff --check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
mori improvement-requests validate --path /Users/shinzui/Keikaku/bokuno/keiro
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce --log-enforce
```

Only after these pass, close IR-33 and add its bundle log entry:

```bash
okf log add docs/improvement-requests IR-33 \
  --kind Implemented \
  --message "Close IR-33 after Plans 265 and 266 make transition-family diffs idempotent, prove guard relations conservatively, and validate exact replay-only remedies."
mori improvement-requests validate --path /Users/shinzui/Keikaku/bokuno/keiro
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce --log-enforce
git diff --check
git status --short
```

Record actual test counts, the disposable Mori commit, proof limits, and any remaining unknown
cases in Progress and Outcomes rather than copying anticipated values.


## Validation and Acceptance

The plan is complete only when affirmative proof results are sound and all non-proofs stay
conservative. Property tests over the complete finite Bool/generated-enum universe must show that
every `RegionUnsatisfiable` has no concrete model and every `RegionSatisfiable` witness evaluates
to true in the original typed expression. Deliberately unsupported nonlinear integer, infinite-
domain, opaque, type-mismatched, and resource-limit cases return `RegionUnknown` with stable
reasons.

Identical and ACI-equivalent guards produce no `AggGuardTightened`,
`AggGuardRegionReplaced`, `AggGuardRelationUnknown`, or `AggGuardRemedyUnavailable`. A pure
loosening produces no guard-history finding. These changes may still produce independent
`AggFoldSurfaceChanged` or source findings because analysis normalization does not rewrite the
frozen fold surface.

A strict tightening produces exactly one `AggGuardTightened`. Its removed region is proved
satisfiable, its added region is proved unsatisfiable, its compatibility vector retains
`private-history-read=advisory`, and its JSON remediation contains the replay-only edge. An
incomparable change produces `AggGuardRegionReplaced`, clearly states that both regions are
non-empty, carries the same history vector, and offers an exact validated removed-region twin.

An undecidable relationship produces `AggGuardRelationUnknown`, remains classified on the
private-history surface in the default report, includes a truthful reason, and contains neither a
replay-only transition nor `RemedyReplayOnlyEdge`. A proved hazard whose remedy cannot parse or validate produces
`AggGuardRemedyUnavailable` with the same safety vector and a do-not-deploy remediation.

An existing replay-only edge suppresses a finding only when the union of same-body replay-only
guards is proved equivalent to the removed region and the candidate validates. Tests prove that
unrelated, stale, partial, excessive, differently emitting, differently writing, differently
targeted, and opaque twins do not suppress it.

Every printed twin preserves old behavior ownership, ordered writes, emits, and target; denotes
exactly `old AND NOT new`; has replay-only mode; contains no forward-only outcome; parses under the
candidate's effective language; and passes `validateService` after insertion. The Language-5
domain-outcome regression pastes, validates, and silences the finding.

Text and JSON findings and replay-impact output agree on equivalent, loosened, tightened,
replaced, and unknown cases. The identical Mori `HEAD` diff is empty and replay-neutral. A real
tightening targets only its aggregate and emitted historical events. Catalog, declaration,
ownership, fold, and other compatibility findings remain independent.

The existing black-acuity tests continue to prove the safety envelope end to end: history written
under the old guard fails hydration and targeted audit without a twin, succeeds with the validated
twin, and a new command in the removed region remains rejected. All `keiro-dsl:tests`,
`keiro-test`, formatting, ADR, and improvement-request gates pass without changing Keiki, package
bounds, canonical fold goldens, or released Languages 1–5 parsing/scaffolding semantics.


## Idempotence and Recovery

The proof engine and both consumers are pure. Re-running a diff, proof test, or report generation
does not alter source or stored data, and twins remain suggestions rather than automatic edits.
Finite enumeration and decision-structure limits are deterministic configuration constants, so a
given checked pair cannot oscillate between proof and unknown.

Develop additively. Land the proof engine with focused tests before routing production findings
through it. Then switch diff and replay impact together in one working commit so there is never a
released state with two authorities. Keep the old syntactic loosening helper only until shared
relation tests cover its cases; remove it before completion. If the new engine fails, restore both
consumers to the prior shared transition-family result rather than weakening proof checks.

Candidate validation occurs on an in-memory copy. A parse or validation failure leaves the user's
source untouched and produces `AggGuardRemedyUnavailable`. Retrying after correcting the
candidate is safe. Never bypass validation to keep a paste-ready assertion green.

The diagnostic registry is append-only. Once committed, keep `AggGuardRegionReplaced`,
`AggGuardRelationUnknown`, and `AggGuardRemedyUnavailable` parseable even if later proof coverage
reduces their use. JSON remains schema `keiro-dsl/diff-report/1`; additions use existing
ignore-unknown conventions.

Mori validation always uses a fresh temporary clone. If interrupted, discard that specific clone
and create another. Preserve unrelated user work in Keiro, and do not reset, clean, or rewrite the
registered Mori or Keiki checkout.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/GuardRelation.hs` is internal and owns `RegionProof`, `GuardWitness`,
`GuardUnknownReason`, `GuardRelation`, and the pure relation entry point. Its exact signature may
bundle contexts, but it must accept each side's `CheckedService`, aggregate, transition/body
context, and optional union guard; it must not use `unsafePerformIO` or expose solver exceptions.

`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` gains a replay-body key and guard-union grouping on
top of ExecPlan 265's exact family delta. It must not change
`Keiro.Dsl.CanonicalEncoding.canonicalTransition` or reuse analysis normalization for persisted
identity.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` and
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` consume the same `GuardRelation`. Their public signatures
remain:

```haskell
diffServices :: CheckedService -> CheckedService -> Either FoldSurfaceError [Change]

replayImpactServices
  :: CheckedService
  -> CheckedService
  -> Either FoldSurfaceError ReplayImpact
```

`keiro-dsl/src/Keiro/Dsl/Validate.hs` retains ExecPlan 265's
`AggGuardRelationUnknown` and appends `AggGuardRegionReplaced` and
`AggGuardRemedyUnavailable`. All three are `DiffDiagnostic`s and carry the private-history
advisory vector through `classifyCompatibility`. `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` maps only
a proved and validated tightening/replacement to `RemedyReplayOnlyEdge`; unknown and unavailable
cases map to `RemedyDoNotDeploy`.

`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` supplies `checkedTypeGraph`, `checkedSpec`,
`checkedLanguageContract`, and `checkedServiceWithSpec`. `keiro-dsl/src/Keiro/Dsl/Expression.hs`
supplies typed guard resolution. `keiro-dsl/src/Keiro/Dsl/Grammar.hs` supplies `complementExpr`.
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, parser/language entry points, and
`validateService` form the remedy round-trip gate.

There is no new package dependency and no Keiki modification. Keiki remains referenced by this
canonical handle:

`mori://shinzui/keiki/packages/keiki`

Its released solver surface is background evidence, not an implementation dependency beyond
Keiro's existing `>=0.9 && <0.10` bound. Any future dynamic solver API belongs in a separate
cross-repository plan with authoritative Hackage and upstream-tag verification.

Every implementation commit must use a Conventional Commit subject and include both trailers:

```text
ExecPlan: docs/plans/266-prove-aggregate-guard-relations-and-validate-replay-only-remedies.md
Intention: intention_01m0kst1x4ejdsnxmweqv8brne
```
