---
id: 166
slug: evaluate-bounded-aggregate-collection-membership-and-quantification
title: "Evaluate bounded aggregate collection membership and quantification"
kind: exec-plan
created_at: 2026-07-31T17:24:54Z
---

# Evaluate bounded aggregate collection membership and quantification

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This ExecPlan is a product and formal-semantics gate, not a commitment to ship collection syntax.
It determines whether bounded collection membership and quantification provide enough correctness,
reuse, and review value over an explicit Hole-owned transition to justify expanding Keiro's public
DSL and Keiki's symbolic term API. Because Keiro 0.12.0.0 is the first stable release and candidate
language 5 remains unpublished, complete the gate before release and, if the evidence says GO,
ship the accepted subset in language 5.

The plan has two equally valid successful outcomes. A GO names an exact, deliberately narrow
feature subset and implements it before 0.12.0.0. A NO-GO records why Hole ownership remains the
better boundary, leaves all collection syntax rejected, makes no production Keiki or Keiro
collection API, and completes the release gate. Missing evidence, an opaque or approximate
symbolic model, unenforceable bounds, unacceptable solver cost, or insufficient reusable demand
produce NO-GO after the planned survey and prototype have run.

If the result is GO, an aggregate can eventually express a bounded predicate such as:

```keiro
guard cmd.requestedSku in cmd.allowedSkus
  && all line in cmd.order.lines where (line.quantity > 0)
```

If the result is NO-GO, the same expression source remains rejected before scaffolding. The author
marks the transition `implementation hole`, removes DSL guard/write clauses from that transition,
and implements its predicate and updates with hand-owned Keiki terms under visible symbolic
opacity/manual fold-version obligations. The decision is observable through a checked-in gate
report, parser rejection fixture, and either the absence of production collection APIs or a
compiled verified conformance aggregate. The Hole escape hatch remains available after a GO too;
new syntax is an opt-in verified path, never the only way to express behavior.


## Progress

- [x] 2026-08-11: made the completed gate and any GO implementation prerequisites for 0.12.0.0
  while candidate language 5 remains unpublished.
- [x] 2026-08-12: verified the production dependency boundary against released Keiki 0.9.0.0.
  Its collection spike is a test-local mini-AST and its public `Term`, `Update`, `HsPred`, and
  symbolic translator still lack structural collection operations. A production GO therefore
  requires an upstream Keiki implementation and release.
- [ ] Milestone 1: collect real consumer cases and compare the proposed language with explicit
  Hole-owned transitions across correctness, maintenance, review, diff, replay, and migration
  costs, surveying the registered Keiro dependents rather than waiting for cases to arrive.
- [ ] Milestone 2: build a non-production Keiki/Keiro prototype, measure exactness and solver cost,
  and produce the gate report with a GO or NO-GO verdict.
- [ ] Gate: record the verdict in the Decision Log and Outcomes. On NO-GO, mark later milestones
  not applicable, document the evidence-backed alternative, and complete without a production
  collection implementation.
- [ ] GO only — Milestone 3: freeze the accepted syntax, bounds, symbolic encoding, diagnostics,
  compatibility behavior, and candidate-language-5 capability/profile changes before publication.
- [ ] GO only — Milestone 4: implement the released Keiki capability and authoritative generated
  Keiro lowering with compiled, property, mutation, replay, and performance evidence.
- [ ] Complete the appropriate outcome: document the Hole fallback after NO-GO, or document and
  release the accepted feature after GO; distill any durable decision into ADRs; and clear the
  0.12.0.0 release gate.


## Surprises & Discoveries

- Release-timing review on 2026-08-11 found Keiro 0.11.0.0 published, 0.12.0.0 planned as the first
  stable release, and language 5 still unpublished. A GO can therefore amend candidate language 5
  without widening a published parser; a later execution must recheck all three facts.
- Mori's reverse-dependency inventory on 2026-08-11 listed fourteen registered projects depending
  on Keiro and twelve depending on Keiki. Registry membership does not itself prove a qualifying
  collection predicate, but it supplies a concrete survey population and makes passive demand
  discovery inappropriate for a pre-release gate.
- Hackage and the matching upstream tag show Keiki 0.9.0.0, not the plan's stale 0.5.0.0 snapshot.
  Its production API still lowers `TApp1`/`TApp2` to fresh symbolic values. The included
  `test/Keiki/CollectionSpike.hs` is a local mini-AST whose `SkippedCollectionGuard` result fails
  this plan's exact, zero-skipped GO gate.


## Decision Log

- Decision: Treat this ExecPlan as a reversible design gate. NO-GO with no production feature is a
  complete and successful outcome, not a blocked or partially completed implementation.
  Rationale: Collection syntax creates a permanent language, schema, runtime-bound, and symbolic
  maintenance obligation. Executed evidence may preserve the smaller API, but an unrun gate is
  incomplete work rather than an evidence-backed NO-GO.
  Date: 2026-07-31; clarified 2026-08-11 for the pre-release gate.

- Decision: Require at least two independently useful collection predicates from at least two
  independently designed real or committed aggregates before GO. No named consumer qualifies in
  advance or receives a custom acceptance path. A synthetic conformance aggregate or hypothetical
  example does not count.
  Rationale: One aggregate can expose several variants of the same modeling choice. A public core
  operator needs evidence of reuse beyond one consumer topology.
  Date: 2026-07-31; strengthened 2026-08-12 to prevent consumer-specific overfitting.

- Decision: Compare the feature against plan 161's explicit per-transition ownership boundary.
  Generated mode owns checked scalar behavior; `implementation hole` owns arbitrary predicates and
  updates within a checked structural envelope, records a manual fold version, and reports opacity.
  Rationale: A collection API must improve materially on the real, honest escape hatch rather than
  on a deliberately unsafe or artificially weak alternative.
  Date: 2026-07-31

- Decision: Keep `implementation hole` permanently available whether the gate returns NO-GO, GO
  for a subset, or a later language version adds more expressions.
  Rationale: No closed DSL can anticipate every domain invariant. Built-in syntax should improve
  verification and ergonomics without trapping users when the next requirement falls outside it.
  Date: 2026-07-31

- Decision: Allocate no language version, parser entry, schema annotation, diagnostic namespace,
  dependency bound, or production module until the gate records GO. If GO is recorded before
  0.12.0.0 publishes candidate language 5, amend language 5 and its exact syntax/runtime profiles
  in place. If an external compatibility boundary has already published language 5, do not widen
  it; use the next available successor and record that the pre-release gate was missed.
  Rationale: Reserving public surface before ratification turns a research idea into accidental
  compatibility debt. Conversely, allocating language 6 while language 5 is still an amendable
  candidate would freeze a known pain point into the first stable contract unnecessarily.
  Date: 2026-08-11 (revises the 2026-07-31 next-version rule for the unpublished candidate).

- Decision: GO requires an exact structural Keiki encoding used by both concrete evaluation and
  symbolic translation. Opaque applications, free Booleans, truncation, skipped verification,
  solver `Unknown`, or timeout cannot implement the accepted fragment.
  Rationale: Syntax sugar that still behaves like opaque Hole behavior does not repay the API and
  maintenance cost.
  Date: 2026-07-31

- Decision: A production GO requires a new released Keiki capability with structural bounded
  collection terms and predicates sharing concrete and exact finite symbolic semantics. A
  Keiro-only lowering through `TApp1`/`TApp2` does not satisfy the gate.
  Rationale: Keiki 0.9.0.0 has only a test-local collection mini-AST; its production term,
  predicate, evaluator, symbolic translator, and structural walkers have no collection vocabulary.
  Date: 2026-08-12

- Decision: The widest candidate scope is read-only membership and single-level quantification
  over required structural outer `List a` and `Map Text a` fields with executable positive
  `max-items` bounds. Optional or nested collections, unions, JSON, opaque values, direct
  collection registers, lookups into aggregate collection state, and collection writes are
  outside this plan. The gate may approve a smaller named subset or reject all of it.
  Rationale: This is the smallest shape with total structural access and finite symbolic
  expansion. Stateful collections introduce a separate aggregate-modeling, replay, inversion,
  update-order, and concurrency problem that requires its own evidence and plan.
  Date: 2026-07-31; restored and clarified 2026-08-12.

- Decision: A bound is sound only when generated JSON decoding, fixtures, direct Haskell command
  construction, events, and every other introduction path reject over-bound values before user
  predicate evaluation. Values are never truncated for the solver.
  Rationale: Concrete membership or quantification could observe any discarded element, making a
  clipped symbolic model unsound.
  Date: 2026-07-31

- Decision: Require the upstream Keiki design gate to revisit, not silently override, the NO-GO in
  `mori://shinzui/keiki/plans/60-first-class-collection-registers-design-gated`.
  Rationale: New downstream demand justifies a fresh evaluation but does not erase a
  deliberate upstream formalism decision.
  Date: 2026-07-31

- Decision: If the gate is NO-GO, retain plan 161's `CollectionExpressionUnsupported` rejection,
  document `implementation hole`, remove any production-facing prototype surface, and avoid a
  Keiki release or Keiro dependency update for collections.
  Rationale: A rejected experiment must not leave a shadow API or force downstream compatibility
  work.
  Date: 2026-07-31

- Decision: Complete this gate before publishing Keiro 0.12.0.0. If it records GO, complete and
  release the accepted Keiki and Keiro implementation in 0.12.0.0; if it records NO-GO, the
  evidence-backed rejection and documented fallback clear the release gate.
  Rationale: The unpublished language-5 window avoids a later source and fold-identity migration.
  Date: 2026-08-11

- Decision: Proactively survey Mori-registered Keiro dependents during Milestone 1. Lack of two
  qualifying cases is a NO-GO only after the report records which reachable consumers were
  inspected, which were unavailable, and why near-miss cases did not qualify.
  Rationale: Missing execution must not masquerade as missing demand.
  Date: 2026-08-11

- Decision: Supersede, for this plan, MasterPlan 36's scheduling assumption that collection syntax
  necessarily rides language 6, but amend the MasterPlan and language registry only after GO.
  Rationale: Candidate language 5 remains amendable under ADR 16.
  Date: 2026-08-11

- Decision: Consumer cases are evidence for the generic feature matrix, not requirements that the
  public DSL reproduce a particular consumer's aggregate topology. Stateful collection-register
  work, if later justified, must use a separate ExecPlan and revisit the Keiki plan-60 gate.
  Rationale: Stateful aggregate design is a separate formalism and evidence problem.
  Date: 2026-08-12


## Outcomes & Retrospective

(To be filled at the gate and again after any GO implementation. For NO-GO, record which required
evidence failed, the survey and prototype results, why Hole ownership remains preferable, and
confirm that no public collection API was allocated. For GO, record the accepted subset, released
dependency/tag, measured budget, migration evidence, and candidate-language-5 profile. In either
branch, record the evidence that cleared the release gate.)


## Context and Orientation

The repository targets Keiro 0.12.0.0 from published 0.11.0.0. Candidate language 5 remains
unpublished. The pre-release language-surface review in
[MasterPlan 36](../masterplans/36-fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5.md)
scheduled collection syntax for language 6. This plan reopens only that schedule: finish the gate
before 0.12.0.0, amend language 5 only after GO, and leave languages 1–4 unchanged.

[Plan 161](161-add-authoritative-typed-scalar-aggregate-expressions.md) establishes the baseline.
Its version-2 transitions select exactly one behavior owner. Generated ownership necessarily
executes checked scalar guards and writes. `implementation hole` delegates arbitrary predicates
and updates to a hand-owned value while retaining a checked source/command/event/target/mode
envelope. The Hole supplies a manual fold version, and opaque Keiki terms are reported as
unverified. This plan asks whether specific collection predicates are common and important enough
to gain a verified built-in path. It never removes Hole ownership.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` and `Parser.hs` own expression syntax.
`keiro-dsl/src/Keiro/Dsl/Validate.hs` and `AggregateType.hs` own checked aggregate capabilities.
`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` represents mapped `List` and `Map` shapes, while
`projectionSpecs` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` currently stops at collection
boundaries. `FoldFingerprint.hs`, `Diff.hs`, `MappedDiff.hs`, `ReplayImpact.hs`, pretty printing,
workspace relocation, generated records, codecs, harnesses, and transducers all consume syntax or
schema facts that a GO would change.

The symbolic dependency is `mori://shinzui/keiki/packages/keiki`. Released Keiki `0.9.0.0` has one
structural `Term` AST, one concrete evaluator, and a symbolic translator, but no public bounded
collection term contract. Its `TApp1` and `TApp2` remain raw-function escape hatches whose symbolic
translation produces fresh opaque values. The prior first-class collection experiment was
ratified NO-GO in
`mori://shinzui/keiki/plans/60-first-class-collection-registers-design-gated`; the follow-up
`mori://shinzui/keiki/plans/67-collection-slot-opaque-mutation-signpost-validatetransducer-warning-and-guidance`
reports opaque guards rather than proving them. Mori currently locates the project source but does
not provide curated Keiki docs. Any dependency choice must be verified against Hackage and the
matching upstream tag rather than the local corpus alone.

[ADR 3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md) requires generated
guard semantics and manual Hole fold versions to enter snapshot identity.
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires invalid
bounds or unsupported capabilities to fail at the first boundary with enough evidence.
[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
permits total scalar projection only through required structural paths and states that future DSL
path syntax must execute what the checker validates.
[ADR 13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
requires opacity to remain honestly visible rather than forcing a dishonest structural claim.
[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) freezes
published parsers, permits an unpublished candidate to be corrected in place, and requires a
successor only after publication.
[ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
keeps explicit Hole ownership available before and after any GO implementation.
[ADR 18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md) requires
any accepted collection behavior to be an explicit language capability whose fold contribution is
decided and covered by the frozen canonical encoder.

A “bounded collection” is a concrete list or map whose declared maximum item count is enforced
before evaluation and participates in schema, fingerprint, diff, and symbolic identity. A “gate
report” is the checked-in research result that maps evidence to every GO criterion and records the
verdict. “GO” means the report justifies a specific public subset. “NO-GO” means Keiro deliberately
keeps the rejected feature out of production and directs each use case to `implementation hole`.

## Plan of Work

Milestone 1 gathers demand evidence before building a formalism. Start with
`mori registry dependents shinzui/keiro --packages`, resolve every reachable registered project
through `mori registry show <qualified-name> --full`, and inspect its committed aggregate sources
and open improvement requests for collection predicates currently expressed outside the DSL or
through Hole ownership. Record projects that cannot be inspected separately from projects that
contain no qualifying case. Add cases supplied directly by maintainers or committed for the
0.12.0.0 adoption cohort.

Identify at least two independent collection predicates from at least two independently designed
real or committed aggregates. For each, record the canonical owning-project URI, aggregate and
command, concrete input shape and realistic maximum size, present or proposed Hole-owned
implementation, why scalar plan 161 cannot express it, frequency of change, replay and diff
consequences, and the specific symbolic question a built-in operator would answer. A generated-only
conformance fixture or hypothetical example does not count. Write this comparison as a research
document under `docs/research/` using that bundle's profile and stable ID workflow.

The research must compare three choices: retain Hole ownership; add only membership over bounded
lists/map keys; or add membership plus single-level `any`/`all`. Nested quantification is a
separate optional row and cannot be smuggled into the base scope. Compare authoring size, generated
code, manual fold-version burden, symbolic status, diff/replay visibility, migration cost, and
long-term parser/Keiki maintenance. If the completed survey finds fewer than two qualifying
predicates from independent aggregates, or the verified status would not change an operational
decision, record NO-GO and skip all production work. Uninspected reachable consumers, a missing
report, or time pressure before release are incomplete evidence and cannot be converted into
NO-GO.

Milestone 2 is a disposable, non-production prototype. In the Mori-resolved Keiki checkout, open a
focused successor to
`mori://shinzui/keiki/plans/60-first-class-collection-registers-design-gated`. Prototype a
required list of scalar values, a required list of records with one scalar projection, and a
`Map Text value`. Include empty collections, list duplicates, map key distinctness, repeated reads
of one path, an over-bound input, membership, and single-level `any`/`all`. Prototype nested
quantification separately so it cannot determine the base result. Reuse the released
`test/Keiki/CollectionSpike.hs` as design evidence, but do not count its local constructors or
`SkippedCollectionGuard` result as production capability or as satisfaction of this plan's exact
symbolic gate.

The candidate symbolic list representation has a length in `[0,N]` plus `N` element slots; slot
`i` is present exactly when `i < length`. A map has at most `N` present key/value slots and requires
present keys to be distinct. Membership and quantification are finite presence-guarded folds.
Repeated reads of the same collection/path/slot share symbolic variables. Concrete evaluation and
symbolic translation consume the same first-order term tree. Test an intentionally unsound
truncation mutation, missing map-key-distinctness mutation, empty-`all` mutation, and split symbolic
identity mutation; every one must fail.

Benchmark each real consumer bound plus powers of two up to the smallest bound covering those
consumers. Run at least 30 samples for each predicate and report term size, solver result,
median/p95 duration, peak memory when available, and timeout/unknown count. A GO requires zero
`Unknown`, timeout, skipped, or opaque results and p95 headroom of at least two times beneath the
existing Keiki validation timeout for every advertised bound on the recorded reference machine.
The supported bound and static expansion budget must be derived from the passing matrix and frozen
with the eventual language version. If no useful bound satisfies this criterion, record NO-GO.

At the end of Milestone 2, write one gate report whose conclusion is either NO-GO or GO for an
exact feature matrix. GO requires all of the following: two qualifying real predicates from
independent aggregates; a total runtime bound at every introduction path; one exact concrete/
symbolic term model; mutation evidence for each known unsound shortcut; acceptable measured cost
for the real bounds; a material reduction in opacity/manual versioning over Hole ownership; and an
explicit upstream Keiki GO. Any missing item is NO-GO. A smaller GO may approve membership while
rejecting quantification, but every rejected form remains explicitly listed and unsupported.

The gate report is required before the 0.12.0.0 release decision. GO blocks the release until
Milestones 3 and 4 are complete. NO-GO clears this plan's release condition only after the report,
Hole guidance, rejection fixture, prototype cleanup, living-plan updates, and any durable ADR
distillation are complete. “Defer until after release” is not a third verdict.

On NO-GO, update Progress, Decision Log, Outcomes, and the research record. Promote the durable
exclusion to an ADR if it is intended to survive beyond this experiment. Confirm plan 161's
version-2 rejection fixture still fails before scaffolding. Remove production-facing prototype
modules, parser entries, schema fields, and dependency changes; research-only benchmark fixtures
may remain when the research profile and upstream repository convention permit them. Mark GO-only
milestones not applicable, synchronize MasterPlan 36, and complete the plan. Do not implement a
fallback subset that failed the written gate.

Milestone 3 runs only after GO. Synchronize MasterPlan 36 and the 0.12.0.0 release checklist. If
language 5 is still unpublished, amend its syntax and runtime profiles through the registry from
plan 160; otherwise leave it immutable and allocate the next successor. Freeze only the accepted
syntax. The widest candidate spelling is:

```keiro
lines as "lines" : List Line max-items=16 required
bySku as "by_sku" : Map SkuAvailability max-items=32 required

guard cmd.requestedSku in cmd.allowedSkus
  && all line in cmd.order.lines where (line.quantity > 0)
  && any sku in keys(cmd.catalog.bySku) where (sku == cmd.requestedSku)
```

`max-items` is valid only on an outer required structural List/Map field and must be positive and
at or below the frozen per-collection limit. List membership uses element equality and ignores
duplicate multiplicity. Map membership is explicitly key membership through `keys(map)`; value
iteration uses `values(map)`. `any` over empty is false and `all` is true. The parentheses after
`where` are mandatory. Map literals, collection writes, optional/nested collection paths, unions,
JSON, opaque values, direct aggregate collection registers, and aggregate collection lookup remain
rejected. If the gate did not approve quantification, omit its syntax and binder types entirely
rather than parsing them behind a disabled capability.

The checked schema bound is enforced by generated JSON decoding, fixtures, direct Haskell command
execution, event decoding, and every value-introduction path before user predicates execute.
Never truncate. A bound decrease is a historical-read and replay hazard; a bound increase can make
new values unreadable to an old binary and therefore rolls out producer-last. Bounds enter schema
identity, diff, fold/snapshot fingerprint, and static symbolic cost. Expression changes remain
replay-affecting.

Milestone 4 also runs only after GO. Land and release the exact Keiki API first, verify Hackage and
the matching upstream tag, and set dependency bounds from that release. Extend plan 161's one typed
expression tree and one generated Keiki renderer; do not add a second production evaluator or use
opaque `TApp1`/`TApp2`. Generated collection guards become authoritative and may replace a
previously Hole-owned transition only through an explicit ownership migration that removes its
manual fold version and changes the fold fingerprint. Hole ownership stays available for other
transitions and future unsupported behavior.

Update collection/path traversal, pretty printing, complement, workspace relocation, generated
records/codecs/transducers, diff, replay impact, and fingerprints exhaustively. Classical
complement exchanges `in`/`not in` and exchanges `all`/`any` while complementing the predicate.
Build compiled consumers based on the real gate cases plus a test-only reference interpreter.
Property tests compare reference, Keiki concrete execution, symbolic formulas, encoded-event
replay, and snapshot-invalidated replay. Mutation and performance tests preserve the gate's
exactness and budget claims.

Complete either branch by documenting the result. For NO-GO, document how to select, implement,
version, and test a Hole-owned transition and what verification is lost. For GO, document syntax,
bounds, empty/duplicate/map semantics, cost limits, optional Hole-to-generated migration,
compatibility vectors, unsupported forms, and the continuing Hole escape hatch. Update ADRs 3, 4,
12, 13, 16, 17, and 18 only where the evidence changes their durable contracts.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Re-establish project and dependency ownership:

```bash
mori show --full
mori registry list
mori registry search keiki
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
mori registry dependents shinzui/keiro --packages
mori registry dependents shinzui/keiki --packages
mori path mori://shinzui/keiki/packages/keiki
```

For each reachable Keiro dependent returned by Mori, run
`mori registry show <qualified-project-name> --full`, inspect the resolved checkout rather than a
guessed path, and record the canonical project URI and survey result. Before using release timing
or dependency versions as evidence, verify the authoritative registries and upstream tags:

```bash
curl -fsSL https://hackage.haskell.org/package/keiro/preferred.json
curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
git ls-remote --tags https://github.com/shinzui/keiro.git
git ls-remote --tags https://github.com/shinzui/keiki.git
rg -n 'version5|CandidateLanguage|currentStableLanguageVersion|currentAuthoringLanguageVersion' \
  keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs
```

At plan revision time these checks showed Keiro 0.11.0.0, Keiki 0.9.0.0, published stable
language 4, and unpublished candidate language 5. Re-run them at execution time; do not copy those
values into dependency bounds or mutate candidate language 5 if the evidence has changed.

Inspect the current Hole baseline and the version-2 rejection surface:

```bash
cabal test keiro-dsl-test \
  --test-option=--match \
  --test-option='scalar expressions' \
  --test-show-details=direct
cabal run -v0 keiro-dsl -- check \
  keiro-dsl/test/fixtures/aggregate-collection-expressions-v2-rejects.keiro
```

The second command exits non-zero with `CollectionExpressionUnsupported`. Record the qualifying
cases from at least two independent aggregates, the full registered-dependent survey disposition,
and prototype results in the profile-governed research document. Use canonical `mori://` project
or artifact URIs for every cross-repository case. Allocate its stable handle and validate the
bundle with:

```bash
okf id list docs/research --profile docs/research/profile.dhall
okf id next docs/research --profile docs/research/profile.dhall RES
okf validate docs/research \
  --strict \
  --profile docs/research/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Add the allocated `RES-N` document to `docs/research/index.md` and record its creation or later
timestamp changes in `docs/research/log.md` through the repository's OKF log workflow. Run the
Keiki prototype and benchmark commands specified by its new upstream plan; copy concise result
summaries, not raw logs, into the gate report.

For a NO-GO, prove absence of accidental production surface:

```bash
rg -n 'max-items|BoundedCollection|CollectionBound|BoundedList|BoundedMap' \
  keiro-dsl/src keiro-dsl/app keiro-dsl/keiro-dsl.cabal
cabal run -v0 keiro-dsl -- check \
  keiro-dsl/test/fixtures/aggregate-collection-expressions-v2-rejects.keiro
git diff --check
```

The `rg` command has no collection-feature production matches other than deliberate unsupported
diagnostic names documented by the gate; the parser command still fails before scaffolding.

For a GO, first verify the released dependency independently:

```bash
curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
git ls-remote --tags https://github.com/shinzui/keiki.git
```

Then run the focused implementation suites whose final names are recorded after the gate:

```bash
cabal test keiro-dsl-test \
  --test-option=--match \
  --test-option='bounded collection expressions' \
  --test-show-details=direct
cabal test keiro-dsl-conformance-bounded-collection-expressions \
  --test-show-details=direct
bash keiro-dsl/test/bounded-collection-expression-mutation-test.sh
```

Both outcomes finish with the repository checks appropriate to files actually changed:

```bash
cabal build all
cabal test all --test-show-details=direct
nix flake check
okf validate docs/research \
  --strict \
  --profile docs/research/profile.dhall \
  --profile-enforce \
  --log-enforce
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
git diff --check
```

Record actual test counts, gate verdict, benchmark matrix summary, prototype disposition, and any
environment-qualified Nix result in Progress and Outcomes.


## Validation and Acceptance

The gate itself is accepted only when the research document maps concrete evidence to every
criterion and records one unambiguous verdict. It may not say “promising,” “defer,” or “implement
and see.” The two valid terminal branches are:

1. NO-GO: fewer than two qualifying predicates from independent aggregates exist, bounds cannot be
   enforced everywhere, the symbolic model is approximate/opaque, known unsound mutations survive,
   useful bounds exceed the cost criterion, the API does not materially improve on Hole ownership,
   or upstream Keiki rejects it.
   The plan records the failing evidence and finishes without production collection syntax,
   schema fields, Keiki API, release, or dependency update.
2. NO-GO keeps the plan-161 collection fixture failing with `CollectionExpressionUnsupported`,
   documents `implementation hole` and its manual fold version, and confirms generated-owned scalar
   transitions remain authoritative.
3. GO: at least two real predicates from independent aggregates pass an exact shared concrete/
   symbolic prototype at realistic bounds with zero unknown/timeout/opaque results, every
   bound-entry path rejects over-bound data, all unsound mutations fail, performance has the
   required timeout headroom, the Hole comparison shows material correctness or maintenance
   benefit, and upstream Keiki records GO.
4. A GO report names the exact approved operator/scope matrix. Unapproved membership,
   quantification, nesting, map/value, element-projection, register, or update forms stay rejected
   and are not parsed into dormant nodes.
5. If language 5 is still unpublished, GO implementation amends its exact syntax/runtime profiles
   in place; languages 1–4 reject the new syntax and retain byte-identical generated behavior. If
   language 5 was already published, it remains immutable and the plan records the missed gate
   before allocating a successor.
6. A declared bound enters checked schema identity and is enforced by decoding, fixtures, direct
   commands, events, fingerprinting, and diff. No path truncates an over-bound value.
7. Accepted list membership, map key/value operations, empty quantifiers, duplicate handling, and
   record projections agree across the test oracle, Keiki concrete evaluation, symbolic formula,
   direct execution, event replay, and snapshot-invalidated replay.
8. Repeated collection/path reads share symbolic identity. Map keys are distinct. Solver
   `Unknown`, timeout, skipped, free, or opaque status is failure for the accepted fragment.
9. Generated collection predicates cannot be bypassed by Hole code. Migrating a Hole-owned
   transition changes the manual/generated ownership and fold identity deliberately, mutation
   coverage detects a bypass, and `implementation hole` remains available for other behavior.
10. The final dependency floor, if any, names a published Keiki release with matching Hackage
    metadata and upstream tag/commit. A NO-GO has no collection-driven dependency-floor change.
11. Keiro 0.12.0.0 is not published while the gate is missing a verdict. GO clears the release
    after accepted implementation and conformance complete; NO-GO clears it after evidence,
    cleanup, rejection-fixture, fallback-guidance, and plan/ADR distillation complete.


## Idempotence and Recovery

Consumer inventory, Mori discovery, release checks, the parser rejection fixture, disposable
prototypes, benchmarks, and reports are safe to repeat. Put generated benchmark output under a
temporary directory and keep only concise reproducible summaries in the research document. Record
the reference machine, Keiki commit, solver version, command, sample count, and timeout so later
runs are comparable.

Do not add production parser/schema/API changes before GO. If a prototype starts in production
modules, move or remove that surface before recording NO-GO; preserve only research/test artifacts
that cannot be imported by released packages. Do not publish a Keiki collection release or change
Keiro dependency bounds merely to make the gate easier to run.

On NO-GO, keep the plan and research report as the evidence and mark GO-only Progress items “not
applicable after NO-GO” with a date. This is completion, not blocked status. A later materially new
consumer or dependency capability may reopen the decision through a new plan or an explicit plan
revision; it does not retroactively change this verdict.

On GO, keep schema, language-profile amendment, dependency release, and generated lowering in
separate checkpoints. If concrete and symbolic results disagree or a required bound fails, disable
the candidate and return the gate to NO-GO before release. Mutation scripts must install
traps that restore exact files and run `git diff --check`; never use destructive Git reset or
checkout for recovery.


## Interfaces and Dependencies

Milestones 1 and 2 add no production interface. Their durable artifact is a profile-valid research
record containing equivalents of:

```haskell
data GateVerdict
  = NoGo
  | Go AcceptedCollectionFeatureMatrix

data GateCriterion = GateCriterion
  { name :: Text
  , requiredEvidence :: Text
  , observedEvidence :: Text
  , passed :: Bool
  }

data CollectionGateReport = CollectionGateReport
  { consumers :: NonEmpty RealConsumerCase
  , criteria :: NonEmpty GateCriterion
  , benchmarkSummary :: BenchmarkSummary
  , upstreamDecision :: UpstreamDecision
  , verdict :: GateVerdict
  }
```

The actual research format may be Markdown/OKF rather than Haskell. It must contain the same
facts, and `Go` is valid only when every mandatory criterion passed.

Only after GO may production checked types equivalent to the following exist:

```haskell
newtype CollectionBound = CollectionBound PositiveInt

data BoundedCollectionExpr a where
  BoundedList
    :: CollectionBound
    -> TypedExpr [a]
    -> BoundedCollectionExpr a
  BoundedMapKeys
    :: CollectionBound
    -> TypedExpr (Map Text value)
    -> BoundedCollectionExpr Text
  BoundedMapValues
    :: CollectionBound
    -> TypedExpr (Map Text a)
    -> BoundedCollectionExpr a

data TypedCollectionPredicate where
  Member
    :: SolverEquality a
    -> TypedExpr a
    -> BoundedCollectionExpr a
    -> TypedCollectionPredicate
  Any
    :: VariableId
    -> BoundedCollectionExpr a
    -> TypedExpr Bool
    -> TypedCollectionPredicate
  All
    :: VariableId
    -> BoundedCollectionExpr a
    -> TypedExpr Bool
    -> TypedCollectionPredicate
```

The exact indices follow the approved feature matrix. Rejected constructors must be absent, not
present behind runtime failure. Quantifier bodies stay first-order trees with explicit variable
identity, never opaque Haskell closures.

A production GO depends on a future released version of
`mori://shinzui/keiki/packages/keiki` exposing exactly the approved bounded term model, coherent
collection projections, finite predicates, bound validation, and verified-versus-unknown status.
Keiro owns grammar, checking, schema-bound enforcement, lowering, generated bindings/codecs, diff,
and fingerprints; Keiki owns the structural executable and analyzable core. A NO-GO adds no
dependency. A GO cannot name PVP bounds until the exact Hackage release and matching tag are
inspected.

Plan 161 and plan 160 are prerequisites for a GO implementation but not for running the research
gate. Plan 161's unsupported diagnostic and explicit Hole ownership are the NO-GO terminal
behavior and remain an escape hatch after GO. Candidate language 5 is amended only after GO and
only while it remains unpublished; no collection capability is reserved by this plan before the
verdict.

Revision note (2026-08-11): Made the completed gate and any GO implementation prerequisites for
Keiro 0.12.0.0, updated the released Keiki baseline to 0.9.0.0, made the registered-dependent survey
proactive, and recorded candidate language 5 as the pre-publication implementation target.

Revision note (2026-08-12): Restored the original generic, read-only scope after review found that
a stateful tier overfit one consumer's unratified aggregate topology. Collection registers,
lookups, and writes now require a separate future ExecPlan. This revision also requires reusable
evidence from independent aggregates and retains the verified Keiki dependency boundary without
consumer-specific acceptance criteria.
