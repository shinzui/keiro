---
id: 266
slug: classify-guard-unions-by-replay-body-and-validate-replay-only-remedies
title: "Classify guard unions by replay body and validate replay-only remedies"
kind: exec-plan
created_at: 2026-08-22T03:59:33Z
intention: "intention_01m0kst1x4ejdsnxmweqv8brne"
---

# Classify guard unions by replay body and validate replay-only remedies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, `keiro-dsl diff` reasons about aggregate guard evolution per *replay body*
rather than per declared transition. Inside each live transition family left over by
[ExecPlan 265](265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md)'s
exact cancellation, transitions are grouped by the part of their behavior that matters to
hydration: behavior ownership, ordered writes, emitted events, and target. The union of live
guards for one body is compared across revisions. A body whose union changed produces one
`AggGuardTightened` with a mechanically exact replay-only twin; a body that emitted events and
no longer exists produces the same hazard with the old transition itself as the twin; a body
whose union is syntactically provably preserved produces nothing; a new-only body is additive.

Every printed twin is proved before it is advertised: it is inserted into a copy of the
candidate, rendered, parsed back through the candidate's language, and validated. A twin that
cannot survive that round trip is reported as `AggGuardRemedyUnavailable` rather than pasted
into the advisory. An existing replay-only sibling suppresses the hazard only when it has the
same replay body and its guard is, by construction, the twin this tool would print, the old
guard verbatim, or unguarded; a stale, unrelated, or differently behaving replay-only sibling
no longer hides a real change.

This plan is deliberately structural. It does not decide satisfiability, does not claim two
guards are semantically equivalent beyond the syntactic fragment replay impact already
trusts, and never withholds a twin because a region might be empty. Today's conservative rule
stands: any change to a body's guard union is reported with its exact remedy. The semantic
proof engine originally planned here was narrowed out by the IR-33 review recorded in
`docs/improvement-requests/make-aggregate-guard-diffs-idempotent-and-semantically-exact.md`;
that review records the conditions under which it may return.


## Progress

- [ ] Confirm ExecPlan 265 is complete and that its no-emit exclusion, outcome clearing, and
      `AggGuardRelationUnknown` contract are in place before changing any pairing boundary.
- [ ] Add a replay-body key and per-body guard-union grouping to
      `keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs`, on top of exact family remainders.
- [ ] Share the existing syntactic `guardImplies` fragment between diff and replay impact as
      the single loosening authority.
- [ ] Classify each body: preserved, changed, removed, or added; replace ExecPlan 265's
      one-to-one path and reserve `AggGuardRelationUnknown` for structurally undecidable bodies.
- [ ] Replace the source/command-only `hasReplayOnlyTwin` with same-body, by-construction
      coverage, and build every twin from the body's representative old transition.
- [ ] Gate every advertised twin behind insert, render, parse, and `validateService`; add
      `AggGuardRemedyUnavailable` for twins that fail.
- [ ] Thread the two `CheckedService`s into `DiffEnv` without changing finding emission order.
- [ ] Cover preserved, loosened, changed, removed-body, added-body, exact-twin, verbatim-twin,
      stale-twin, body-mismatch-twin, and Language-5 outcome cases in unit, CLI, and runtime
      safety tests.
- [ ] Update evolution guidance, CHANGELOG, ADRs 0002/0004/0018 where durable rules change,
      run all package, OKF, and disposable Mori gates, and close IR-33.


## Surprises & Discoveries

- Observation: `CheckedService` is a normalized spec paired with an effective language contract
  and lazy type/projection analyses; its constructor does not prove that `validateService` has no
  errors. A remedy must therefore be validated explicitly rather than trusted by type.
  Evidence: `CheckedService`, `checkedServiceWithSpec`, and `checkedTypeGraph` in
  `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`; `validateService` in
  `keiro-dsl/src/Keiro/Dsl/Validate.hs`.

- Observation: the current replay-only suppression accepts any candidate replay-only transition
  with the same source and command. It does not compare guard, writes, emits, target, or
  behavior ownership. An unrelated or stale retained edge can therefore hide a later real
  change.
  Evidence: local helper `hasReplayOnlyTwin` in `keiro-dsl/src/Keiro/Dsl/Diff.hs`.

- Observation: ADR 0002 makes inversion two-phase and live-first, and keiki's static
  inversion-ambiguity check refuses two same-mode edges at one vertex that share a first output
  constructor regardless of guards. Two consequences drive this plan's design. First, within a
  live family every emitting body is already distinguishable by its emitted events, so the
  replay-body key is a faithful hydration identity. Second, an over-covering replay-only edge
  (for example the old guard verbatim) is operationally safe: a live edge always wins
  attribution, and the twin only serves history no live edge can invert.
  Evidence: `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`;
  the inversion paragraph in `docs/guides/evolution-and-replayability.md`.

- Observation: removing an emitting live transition strands its history exactly as a tightening
  does, and worse: the whole old guard region loses its inverting edge, not merely the removed
  region. Today neither `guardTighteningDiff` nor ExecPlan 265 reports this as a guard-history
  hazard; only `AggFoldSurfaceChanged` (which speaks of snapshot invalidation) and the
  replay-affected verdict (which says "audit") fire, and no remedy is offered although the
  sanctioned one applies directly. The same gap makes today's one-to-one twin too narrow when a
  guard and an emitted event change together.
  Evidence: `guardTighteningDiff` iterates candidate transitions only; `transitionSurfaceDiff`
  text; IR-33 review finding 7.

- Observation: the validator proves a no-emit transition is a pure no-op, so only emitting
  bodies can carry a guard-history hazard. ExecPlan 265 already excludes no-emit transitions;
  this plan must keep that exclusion ahead of the round-trip gate, otherwise an irrelevant
  guard change would be misreported as a hazard with an unavailable remedy.
  Evidence: the no-emit rule in `keiro-dsl/src/Keiro/Dsl/Validate.hs`; ExecPlan 265 Decision
  Log.

- Observation: `ReplayImpact`'s `guardImplies` already proves `old => new` for a small
  syntactic fragment (identity, true/false, conjunction elimination, disjunction introduction)
  and treats everything else as not provable. It is sound, solver-free, and currently the only
  reason a loosening is replay-neutral while the diff still reports it. Sharing it makes the two
  outputs agree on the fragment without any new proof machinery.
  Evidence: `guardOnlyLoosening` and `guardImplies` in
  `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`; the guide's "tightening detection is conservative"
  sentence.

- Observation: the originally planned finite-domain proof engine would have returned `Unknown`
  for every guard over Text, Int, Integer, Natural, Time, or ID roots, which is every guard in
  Mori's workspace, and would have withheld the twin in that case. That is a regression in
  actionable safety for the dominant guard class, and it is why the engine was removed from this
  plan.
  Evidence: IR-33 review findings 5 and 6; Mori `project.keiro` guard shapes.

- Observation: the released Keiki 0.9.1.0 solver surface (`Keiki.Symbolic.verifyPredicate`)
  accepts a statically typed `HsPred rs ci` and performs work in `IO`; Keiro's `diffServices` is
  pure over dynamically resolved `TypedScalarExpr`s. It remains background evidence only.
  Evidence: Mori registration `mori://shinzui/keiki/packages/keiki`; Keiro's `>=0.9 && <0.10`
  bound in `keiro-dsl/keiro-dsl.cabal`.


## Decision Log

- Decision: Narrow this plan to structural body classification and remedy validation; drop the
  three-valued proof engine, `AggGuardRegionReplaced`, satisfiability-gated twins, semantic
  equivalence detection, and exact-equivalence twin coverage.
  Rationale: the IR-33 review found two safety regressions in the original design. Witnesses
  restricted to finite Bool/enum domains turn every real tightening on Text/Int/Time/ID guards
  into `Unknown` with no remedy, which is worse than today's conservative advisory with an exact
  twin. Requiring an existing twin to be provably *equivalent* to the removed region turns the
  natural hand-written twin (old guard verbatim, explicitly safe under ADR 0002) into a perpetual
  finding. The structural parts of the plan remove the remaining known defects without either
  cost. The review in IR-33 records the conditions under which a semantic engine may be
  reconsidered.
  Date: 2026-08-22

- Decision: Compare the union of live guards per replay body, not per declared transition, and
  represent an absent guard as true.
  Rationale: several declarations may split one behavior into alternative guards without
  changing its replay meaning. Union comparison is invariant under splitting, merging,
  duplication, and declaration order, and it resolves most families ExecPlan 265 must call
  `AggGuardRelationUnknown`. Body changes remain independently owned by fold-surface and
  replay-impact findings.
  Date: 2026-08-22

- Decision: Never withhold a twin for a changed or removed emitting body. The twin's guard is
  exactly `oldUnion AND complement(newUnion)` for a changed body and the old guard union for a
  removed body; it is printed whenever it validates.
  Rationale: the twin is sound whether or not the removed region is empty: an empty region makes
  it a dead replay-only edge, which is harmless under live-first inversion, while a non-empty
  region makes it the only thing keeping history replayable. Withholding it pushes users to
  hand-write complements, the error class `complementExpr` exists to eliminate.
  Date: 2026-08-22

- Decision: A removed emitting body inside a surviving live family is a guard-history hazard with
  the same code and vector as a tightening, and its twin is the old transition re-moded
  replay-only with its guard unchanged and its outcome cleared.
  Rationale: every event that body emitted loses its inverting edge. Reporting only
  `AggFoldSurfaceChanged` understates the failure mode and offers no remedy. A removed
  aggregate, or a family whose every live transition is gone, stays with the existing
  `EvtRemovedNotDeprecated` and `ReplayOnlyCommandStillLive` paths.
  Date: 2026-08-22

- Decision: Suppress a finding for an existing replay-only sibling only when it has the same
  replay body and its guard is by construction one of: the twin this tool would print for the
  current change (canonical text equality), one of the body's old live guards verbatim, or
  absent. Containment suffices; extra replay-only siblings are not a defect.
  Rationale: each accepted shape provably covers the removed region without any solver: the
  computed twin is the region itself, the old guard verbatim is a superset, and an unguarded
  replay-only edge covers everything. ADR 0002 makes supersets safe. Anything else is not
  demonstrably coverage and stays a finding. Containment rather than equality keeps a second
  tightening's twin from invalidating the first.
  Date: 2026-08-22

- Decision: Share the syntactic `guardImplies` fragment between diff and replay impact; a body
  whose every old live guard syntactically implies the new union produces no guard finding.
  Rationale: the fragment is sound and already trusted by replay impact. Sharing it removes the
  one case where the diff reports a hazard that replay impact calls neutral, without adding
  proof machinery. Extending the fragment is not in scope.
  Date: 2026-08-22

- Decision: A generated twin is advertised only after whole-spec insert, render, parse, and
  candidate-language validation succeed; failure becomes `AggGuardRemedyUnavailable`.
  Rationale: `renderTransition` alone proves presentation, not that the pasted transition is
  legal under the candidate language. A failed proof must be a truthful code with the reason,
  not an unpasteable suggestion.
  Date: 2026-08-22

- Decision: Thread both `CheckedService`s into `DiffEnv` rather than relocating the guard pass
  to a service-level step.
  Rationale: the round-trip gate needs the candidate's language contract, but moving the pass
  after `diffCheckedSpecs` would reorder the emission-ordered rendering golden and change text
  output order for every adopter. Carrying the services in the environment keeps the pass at
  its current position.
  Date: 2026-08-22

- Decision: Semantic normalization of any kind stays out of this plan; canonical encoding,
  pretty printing, and fold fingerprints are untouched.
  Rationale: ADR 0018 freezes canonical fold bytes. Nothing here needs to rewrite an
  expression; the body key is derived from canonical text of the body clauses only.
  Date: 2026-08-22


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan begins only after ExecPlan 265 lands. Its internal
`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` groups transitions by mode, source, and command,
cancels exact replay identities as a multiset, and returns canonical-order remainders. Its guard
pass already excludes no-emit transitions, clears outcome fields from twins, and reports
`AggGuardRelationUnknown` for families it cannot pair. Read that completed plan's Progress,
discoveries, and Decision Log before implementation; do not recreate its cancellation algorithm.

The originating request is
`docs/improvement-requests/make-aggregate-guard-diffs-idempotent-and-semantically-exact.md`
(IR-33). Its review section records which acceptance items this plan delivers and which are
deferred. The relevant package uses this canonical handle:

`mori://shinzui/keiro/packages/keiro-dsl`

The real adopter evidence uses these canonical plan handles:

- `mori://shinzui/mori/plans/223-move-the-mori-workspace-to-keiro-dsl-language-5`
- `mori://shinzui/mori/plans/236-model-project-releases-in-the-registry`

Use a disposable clone of `mori://shinzui/mori/repos/mori` for acceptance; never edit its
registered checkout.

A *guard* is the Boolean expression attached to a transition; absence means true. A *replay
body* is everything hydration needs from a transition other than its guard: behavior ownership
(`tImplementation`), ordered `tWrites`, ordered `tEmits`, and `tGoto`. Mode, source location,
and the forward-only `tOutcome` are excluded. Two transitions with the same body are alternative
guards over one behavior. For a body with old union `O` and new union `N`, the *removed region*
is `O && !N`, rendered inside the grammar by `complementExpr` in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`.

Body classification within one live family, after exact cancellation and no-emit exclusion:

- preserved: the body exists on both sides and every old live guard syntactically implies the
  new union (`guardImplies`), or the canonical guard unions are identical;
- changed: the body exists on both sides and is not preserved;
- removed: the body has old live transitions and no new live transition;
- added: the body has new live transitions only.

Only changed and removed bodies carry a guard-history hazard. Because keiki refuses two live
edges at one vertex sharing a first output constructor, emitting bodies in one family are
distinguished by their emits in practice; the key still includes ownership, writes, and target
so a write or target change is a different body rather than a guard change.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` owns `AggGuardTightened` and its private-history vector;
`DiffEnv` currently carries only the two `Spec`s. `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` owns
audit targeting and the syntactic `guardImplies`. `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` owns
remedies and JSON encoding; its `remediationFor` has an `otherwise` fallthrough, so every new
code needs an explicit case. `keiro-dsl/src/Keiro/Dsl/Validate.hs` owns append-only diagnostic
codes and `validateService`. `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` supplies `renderSpec`,
`renderSource`, and `renderTransition`; `keiro-dsl/src/Keiro/Dsl/Parser.hs` supplies
`parseSource`. Workspaces merge into one `Spec` (`wsMergedSpec` in
`keiro-dsl/src/Keiro/Dsl/Workspace.hs`), and the validator already runs on that merged spec, so
the round trip operates on a single-document rendering of it.

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

### Milestone 1 — Key families by replay body and share the loosening fragment

Extend `keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` with a `ReplayBodyKey` built from the
canonical text of ownership marker, writes, emits, and target only (reuse the clause renderers
behind `canonicalTransition`; do not add a new encoding of expressions), and a function that
groups one family's exact old and new remainders by that key, drops no-emit transitions, and
returns for each body the old live guards, the new live guards, the old and new replay-only
guards, and one representative old live transition in canonical order. Represent an absent guard
as `Nothing` and build unions as right-nested `EOr` chains in canonical order so the printed
twin is deterministic.

Move `guardImplies` from `ReplayImpact.hs` into the shared module unchanged, extend it to treat
`ELiteral _ (LiteralBool True)` and `ELiteral _ (LiteralBool False)` exactly like the atom forms,
and define `unionPreserved oldGuards newUnion` as "every old guard implies the new union". Make
`ReplayImpact.hs` import the shared function; its behavior must not change, and its existing
permutation test must remain green.

Add focused tests: bodies that differ only in guard group together; a write, emit, target, or
ownership difference yields a distinct body; no-emit transitions never appear in a body; the
union is identical under every permutation of three siblings; `unionPreserved` holds for
identity, disjunction introduction, conjunction elimination, and literal true, and fails for an
unguarded old transition against a guarded new union.

### Milestone 2 — Classify bodies and build exact twins

Rewrite ExecPlan 265's guard pass in `Diff.hs` to iterate bodies. A preserved or added body
produces nothing. A changed body produces one `AggGuardTightened` whose subject is the source
and command, whose detail names the body's emitted events and old/new sibling counts, and whose
twin is the representative old transition with guard `oldUnion AND complementExpr newUnion`
(just `complementExpr newUnion` when the old union is absent), mode `TmReplayOnly`,
`tOutcome = Nothing`, `tOutcomeDuplicateLocs = []`, and `noLoc`. A removed body produces one
`AggGuardTightened` whose detail states that the body was removed and whose twin is the
representative old transition with its guard unchanged, re-moded the same way. Keep
`AggGuardRelationUnknown` only for a family whose remainders contain a Hole-owned transition on
one side and generated ownership on the other for the same emits, where the body key cannot
decide whether behavior was preserved; everything else now classifies.

Replace `hasReplayOnlyTwin`. A changed or removed body is covered when the candidate contains at
least one replay-only transition with the same `ReplayBodyKey` whose guard's `canonicalExpr` is
equal to the guard the twin would carry, equal to one of the body's old live guards, or absent.
Coverage suppresses the finding for that body only.

Keep the existing Plan-143 fixtures green: the one-to-one tightening still yields exactly one
`AggGuardTightened` with the same twin text as today, and the twin fixture still suppresses it.
Add fixtures for: a sibling split (`g` into `g && a` plus `g && !a`) that is preserved; a
loosening by disjunction introduction that is preserved; a removed emitting sibling with a
surviving same-body sibling (a changed body); a removed emitting body with no survivor; a guard
and emit changed together (removed body plus added body, twin guard equals the whole old guard);
a stale twin from a previous tightening that does not cover a new change; a replay-only sibling
with the right guard but a different write that does not cover; and the old guard verbatim as a
replay-only sibling that does cover.

### Milestone 3 — Prove every printed twin

Extend `DiffEnv` with the old and new `CheckedService`s, threaded from `diffServices`, so the
guard pass can reach the candidate's language contract without moving. Before any twin is
rendered into a detail, insert it into a copy of the candidate spec's aggregate, wrap that spec
with `checkedServiceWithSpec`, render the whole document with `renderSource` under the
candidate's declared language, parse it back with `parseSource`, reconstruct the checked
service, and run `validateService`. Require no `Error` diagnostics and require that the
round-tripped aggregate contains a transition equal to the proposed twin (`Loc` equality is
already constant-true). Only then may the finding carry `renderTransition twin` and map to
`RemedyReplayOnlyEdge`.

Append `AggGuardRemedyUnavailable` to `DiagnosticCode` after ExecPlan 265's code, classify it as
`DiffDiagnostic`, add it to the private code registry and `classifyCompatibility` with the same
private-history advisory vector, and add an explicit `remediationFor` case mapping it to
`RemedyDoNotDeploy` carrying the parse or validation reason. Its detail must say the hazard is
real and the mechanical remedy could not be validated; it must not print the failed twin.

Prove the gate on a Language-5 `domain-outcomes` fixture whose old live transition declares an
accepted outcome and whose guard tightens: the printed twin contains no `outcome` clause, the
pasted source parses and validates, and re-diffing suppresses the finding. Prove the negative by
a test-only hook or fixture in which the rendered twin is made invalid (for example an emit the
candidate no longer declares after an event removal) and assert `AggGuardRemedyUnavailable`
with the reason and no `replay-only` text. Add a spike test first that renders and re-parses the
unmodified merged Mori-shaped workspace fixture and asserts semantic equality, so a round-trip
infidelity is found before it can masquerade as an unavailable remedy.

### Milestone 4 — Close the end-to-end contract

Expand `keiro-dsl/test/diff-test.sh` so Git-backed text and JSON cover preserved, changed,
removed-body, exact-twin, verbatim-twin, stale-twin, and unavailable-remedy cases, asserting
codes, vectors, and remedies rather than prose. Re-run the Keiro black-acuity and replay-audit
examples from ExecPlan 143 unchanged.

Run the local `keiro-dsl` binary against a disposable clone identified by
`mori://shinzui/mori/repos/mori`: the identical `HEAD` diff remains empty and replay-neutral.
Then, in the disposable clone only, tighten one `ObserveProjectDescription` emitting branch and
confirm exactly one `AggGuardTightened` naming `ProjectDescriptionChanged`, a twin that pastes
and validates, and suppression on re-diff; record the evidence in this plan and discard the
clone.

Update `docs/guides/evolution-and-replayability.md` with the replay-body vocabulary, the
removed-body hazard, the three accepted coverage shapes, and the unavailable-remedy code. Add a
`keiro-dsl/CHANGELOG.md` entry. Update ADR 0002's computed-remedy wording (removed bodies,
coverage shapes), ADR 0004's diff-gate inventory (the two new codes), and ADR 0018's replay
comparison statement (body-keyed union comparison) if the final implementation establishes
these durable rules; log every timestamp change. After every gate passes, close IR-33 per its
review section and append the `Implemented` log entry.


## Concrete Steps

At the start of implementation, verify the prerequisite:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro

rg -n '^-[[:space:]]+\[ \]' docs/plans/265-make-aggregate-transition-family-diffs-idempotent-and-order-independent.md
rg -n 'AggGuardRelationUnknown|null \(tEmits' keiro-dsl/src/Keiro/Dsl/Diff.hs
```

The first command must print no unchecked Progress item; the second must show ExecPlan 265's
code and no-emit exclusion in place.

Run focused tests while implementing:

```bash
cabal test keiro-dsl-test --test-options='--match "transition family"'
cabal test keiro-dsl-test --test-options='--match "replay body"'
cabal test keiro-dsl-test --test-options='--match "guard tightening"'
cabal test keiro-dsl-test --test-options='--match "replay impact"'
cabal test keiro-dsl-conformance-domain-outcomes
bash keiro-dsl/test/diff-test.sh
```

Expected focused behavior is comparable to:

```text
preserved body: no guard-history finding
changed body: AggGuardTightened with validated replay-only twin
removed body: AggGuardTightened with the old transition as replay-only twin
covered body: no finding (computed twin / old guard verbatim / unguarded)
invalid twin: AggGuardRemedyUnavailable without replay-only text
```

Run the runtime safety proof without broadening its assertions:

```bash
cabal test keiro-test --test-options='--match "guard tightening"'
cabal test keiro-test --test-options='--match "black-acuity"'
cabal test keiro-test --test-options='--match "replay-only twin"'
```

Run the disposable Mori proof:

```bash
keiro_dsl_bin="$(cabal list-bin exe:keiro-dsl)"
mori_source="$(mori path mori://shinzui/mori/repos/mori)"
guard_proof_scratch="$(mktemp -d "${TMPDIR:-/tmp}/keiro-guard-body.XXXXXX")"
git clone --local --no-hardlinks "$mori_source" "$guard_proof_scratch/mori"

cd "$guard_proof_scratch/mori"
"$keiro_dsl_bin" diff domain/mori.keiro-workspace --since HEAD \
  --report-out "$guard_proof_scratch/mori-diff.json" \
  --replay-impact-out "$guard_proof_scratch/mori-replay.json"
jq '{breaking, findings: [.findings[] | {code, vector, remedies}]}' \
  "$guard_proof_scratch/mori-diff.json"
jq . "$guard_proof_scratch/mori-replay.json"
```

The identical-source result must contain no findings and must be replay-neutral. For the
experimental tightening, edit only the clone, re-run the same command, and capture the single
finding and its twin before discarding the clone. Delete only `guard_proof_scratch`, never the
Mori source.

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
  --message "Close IR-33's accepted scope after Plans 265 and 266 make transition-family diffs idempotent, classify guard unions by replay body, and validate every replay-only remedy; the deferred semantic engine remains recorded in the IR-33 review."
mori improvement-requests validate --path /Users/shinzui/Keikaku/bokuno/keiro
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce --log-enforce
git diff --check
git status --short
```

Record actual test counts and the disposable Mori commit in Progress and Outcomes rather than
copying anticipated values.


## Validation and Acceptance

The plan is complete only when all of the following observable behaviors hold.

Identical sources and every declaration permutation produce no `AggGuardTightened`,
`AggGuardRelationUnknown`, or `AggGuardRemedyUnavailable`, and the replay verdict is neutral. A
sibling split or merge that preserves the canonical guard union, and a loosening provable by the
shared syntactic fragment, produce no guard-history finding and no guard-derived audit target;
they may still produce the independent `AggFoldSurfaceChanged`.

A changed emitting body produces exactly one `AggGuardTightened` carrying the private-history
advisory vector, a detail naming its emitted events, and a twin whose guard is exactly
`oldUnion AND complement(newUnion)` over the body's old representative, with replay-only mode and
no outcome. A removed emitting body produces the same code with the old transition as twin. The
existing Plan-143 fixture's twin text is byte-identical to today's.

Every advertised twin has been inserted, rendered, parsed, and validated under the candidate's
language; a twin that fails produces `AggGuardRemedyUnavailable` with the reason, the same
vector, `RemedyDoNotDeploy`, and no `replay-only` text. Both new codes parse by name, are
`DiffDiagnostic`s, and have explicit remedy cases.

A replay-only sibling suppresses a finding only with the same replay body and a guard that is the
computed twin, an old guard verbatim, or absent. Tests prove that stale, unrelated, differently
writing, differently emitting, differently targeted, and Hole-owned siblings do not suppress it,
and that extra replay-only siblings beyond a covering one do not reintroduce it.

Text and JSON findings and replay-impact agree: every body reported as a hazard has its emitted
events in the audit target set, and every body the diff calls preserved is replay-neutral with
respect to guards. Finding emission order and the rendering golden are unchanged except for the
deliberate additions this plan makes to fixtures.

The disposable Mori `HEAD` self-diff is empty and replay-neutral, and a single experimental
tightening in the clone yields one finding with a pasteable, validating twin. The black-acuity
tests pass unchanged. All `keiro-dsl:tests`, `keiro-test`, formatting, ADR, and
improvement-request gates pass without changing Keiki, package bounds, canonical fold goldens, or
released Languages 1–5 parsing/scaffolding semantics.


## Idempotence and Recovery

Everything here is pure comparison and rendering. Re-running a diff, test, or report generation
does not alter source or stored data, and twins remain suggestions rather than automatic edits.
Candidate validation runs on an in-memory copy; a failing twin leaves the user's source untouched.

Develop additively. Land the replay-body grouping and the shared `guardImplies` with focused
tests before routing production findings through them, then switch the diff pass in one working
commit so there is never a released state with two authorities. If body classification fails,
restore ExecPlan 265's one-to-one path rather than weakening the round-trip gate. Never bypass
validation to keep a paste-ready assertion green.

The diagnostic registry is append-only. Once committed, keep `AggGuardRemedyUnavailable`
parseable. JSON remains schema `keiro-dsl/diff-report/1`; additions use existing ignore-unknown
conventions.

Mori validation always uses a fresh temporary clone; if interrupted, discard that clone and create
another. Preserve unrelated user work in Keiro, and do not reset, clean, or rewrite the registered
Mori or Keiki checkout.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` gains `ReplayBodyKey`, per-body guard grouping, and
the shared `guardImplies`/`unionPreserved` on top of ExecPlan 265's exact family delta. It must
not change `Keiro.Dsl.CanonicalEncoding.canonicalTransition`.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` keeps its guard pass at the current emission position;
`DiffEnv` gains the old and new `CheckedService`s. `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`
imports the shared implication fragment. Their public signatures remain:

```haskell
diffServices :: CheckedService -> CheckedService -> Either FoldSurfaceError [Change]

replayImpactServices
  :: CheckedService
  -> CheckedService
  -> Either FoldSurfaceError ReplayImpact
```

`keiro-dsl/src/Keiro/Dsl/Validate.hs` retains ExecPlan 265's `AggGuardRelationUnknown` and
appends `AggGuardRemedyUnavailable`. Both are `DiffDiagnostic`s with the private-history advisory
vector. `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` maps only a validated twin to
`RemedyReplayOnlyEdge`; unknown and unavailable cases map explicitly to `RemedyDoNotDeploy`.

`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` supplies `checkedServiceWithSpec`,
`checkedLanguageContract`, and `checkedSpec`. `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`,
`keiro-dsl/src/Keiro/Dsl/Parser.hs`, and `validateService` form the remedy round-trip gate.
`keiro-dsl/src/Keiro/Dsl/Grammar.hs` supplies `complementExpr` and `noLoc`.

There is no new package dependency and no Keiki modification. Keiki remains referenced by
`mori://shinzui/keiki/packages/keiki` under Keiro's existing `>=0.9 && <0.10` bound. Any future
semantic guard engine belongs in a separate plan opened from IR-33's review, not in this one.

Every implementation commit must use a Conventional Commit subject and include both trailers:

```text
ExecPlan: docs/plans/266-classify-guard-unions-by-replay-body-and-validate-replay-only-remedies.md
Intention: intention_01m0kst1x4ejdsnxmweqv8brne
```
