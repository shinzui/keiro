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
DSL and Keiki's symbolic term API.

The plan has two equally valid successful outcomes. A GO names an exact, deliberately narrow
feature subset and then implements it under a new successor language version. A NO-GO records why
Hole ownership remains the better boundary, leaves all collection syntax rejected, makes no
production Keiki or Keiro collection API, and completes the plan. Missing evidence, an opaque or
approximate symbolic model, unenforceable bounds, unacceptable solver cost, or insufficient real
consumer demand all produce NO-GO by default.

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

- [ ] Milestone 1: collect real consumer cases and compare the proposed language with explicit
  Hole-owned transitions across correctness, maintenance, review, diff, replay, and migration costs.
- [ ] Milestone 2: build a non-production Keiki/Keiro prototype, measure exactness and solver cost,
  and produce the gate report with a GO or NO-GO verdict.
- [ ] Gate: record the verdict in the Decision Log and Outcomes. On NO-GO, mark later milestones
  not applicable and complete without a production collection implementation.
- [ ] GO only — Milestone 3: freeze the accepted syntax, bounds, symbolic encoding, diagnostics,
  compatibility behavior, and next available language version.
- [ ] GO only — Milestone 4: implement the released Keiki capability and authoritative generated
  Keiro lowering with compiled, property, mutation, replay, and performance evidence.
- [ ] Complete the appropriate outcome: document the Hole fallback after NO-GO, or document and
  release the accepted feature after GO; distill any durable decision into ADRs.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Treat this ExecPlan as a reversible design gate. NO-GO with no production feature is a
  complete and successful outcome, not a blocked or partially completed implementation.
  Rationale: Collection syntax creates a permanent language, schema, runtime-bound, and symbolic
  maintenance obligation. The absence of sufficient evidence should preserve the smaller API.
  Date: 2026-07-31

- Decision: Require at least two independently useful collection predicates from real or committed
  aggregates before GO. A synthetic conformance aggregate or a hypothetical example does not count.
  Rationale: The prior upstream collection proposal lacked a real consumer. One-off behavior is the
  use case for an explicit Hole, not sufficient reason to enlarge the core language.
  Date: 2026-07-31

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
  dependency bound, or production module until the gate records GO. A GO uses the next version
  available at that time rather than assuming version 3.
  Rationale: Reserving public surface before ratification turns a research idea into accidental
  compatibility debt and can collide with other successor syntax plans.
  Date: 2026-07-31

- Decision: GO requires an exact structural Keiki encoding used by both concrete evaluation and
  symbolic translation. Opaque applications, free Booleans, truncation, skipped verification,
  solver `Unknown`, or timeout cannot implement the accepted fragment.
  Rationale: Syntax sugar that still behaves like opaque Hole behavior does not repay the API and
  maintenance cost.
  Date: 2026-07-31

- Decision: The widest candidate scope is read-only expressions over required structural outer
  `List a` and `Map Text a` fields with executable positive `max-items` bounds. Optional or nested
  collections, unions, JSON, opaque values, direct collection registers, and collection writes are
  outside the candidate. The gate may approve a smaller named subset or reject all of it.
  Rationale: This is the smallest shape with total structural access and finite symbolic expansion.
  It avoids inventing null, recursive-bound, mutation, or collection-register semantics.
  Date: 2026-07-31

- Decision: A bound is sound only when generated JSON decoding, fixtures, direct Haskell command
  construction, events, and every other introduction path reject over-bound values before user
  predicate evaluation. Values are never truncated for the solver.
  Rationale: Concrete membership or quantification could observe any discarded element, making a
  clipped symbolic model unsound.
  Date: 2026-07-31

- Decision: Require the upstream Keiki design gate to revisit, not silently override, the NO-GO in
  `mori://shinzui/keiki/plans/60-first-class-collection-registers-design-gated`.
  Rationale: A narrower downstream consumer justifies a fresh evaluation but does not erase a
  deliberate upstream formalism decision.
  Date: 2026-07-31

- Decision: If the gate is NO-GO, retain plan 161's `CollectionExpressionUnsupported` rejection,
  document `implementation hole`, remove any production-facing prototype surface, and avoid a
  Keiki release or Keiro dependency update for collections.
  Rationale: A rejected experiment must not leave a shadow API or force downstream compatibility
  work.
  Date: 2026-07-31


## Outcomes & Retrospective

(To be filled at the gate and again after any GO implementation. For NO-GO, record which required
evidence failed, what prototype or benchmark was run, why Hole ownership remains preferable, and confirm
that no language version or production collection API was allocated. For GO, record the accepted
subset, real consumers, released dependency/tag, measured budget, migration experience, and
concrete/symbolic agreement evidence.)


## Context and Orientation

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

The symbolic dependency is `mori://shinzui/keiki/packages/keiki`. Released Keiki `0.5.0.0` has one
structural `Term` AST, one concrete evaluator, and a symbolic translator, but no public bounded
collection term contract. The prior first-class collection experiment was ratified NO-GO in
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
released parsers and requires any accepted syntax to use a successor language version.
[ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
keeps explicit Hole ownership available before and after any GO implementation.

A “bounded collection” is a concrete list or map whose declared maximum item count is enforced
before evaluation and participates in schema, fingerprint, diff, and symbolic identity. A “gate
report” is the checked-in research result that maps evidence to every GO criterion and records the
verdict. “GO” means the report justifies a specific public subset. “NO-GO” means Keiro deliberately
keeps the feature out of production and directs the use case to `implementation hole`.


## Plan of Work

Milestone 1 gathers demand evidence before building a formalism. Identify at least two independent
collection predicates from real or committed aggregates. For each, record the aggregate and
command, concrete input shape and realistic maximum size, present or proposed Hole-owned implementation,
why scalar plan 161 cannot express it, frequency of change, replay and diff consequences, and the
specific symbolic question a built-in operator would answer. A generated-only conformance fixture
does not count. Write this comparison as a research document under `docs/research/` using that
bundle's profile and stable ID workflow.

The research must compare three choices: retain Hole ownership; add only membership over bounded
lists/map keys; or add membership plus single-level `any`/`all`. Nested quantification is a
separate optional row and cannot be smuggled into the base scope. Compare authoring size, generated
code, manual fold-version burden, symbolic status, diff/replay visibility, migration cost, and
long-term parser/Keiki maintenance. If fewer than two qualifying predicates exist, or the verified
status would not change an operational decision, record NO-GO immediately and skip all production
work.

Milestone 2 is a disposable, non-production prototype. In the Mori-resolved Keiki checkout, open a
focused successor to
`mori://shinzui/keiki/plans/60-first-class-collection-registers-design-gated`. Prototype a
required list of scalar values, a required list of records with one scalar projection, and a
`Map Text value`. Include empty collections, list duplicates, map key distinctness, repeated reads
of one path, an over-bound input, membership, and single-level `any`/`all`. Prototype nested
quantification separately so it cannot determine the base result.

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
exact feature matrix. GO requires all of the following: two qualifying real predicates; a total
runtime bound at every introduction path; one exact concrete/symbolic term model; mutation evidence
for each known unsound shortcut; acceptable measured cost for the real bounds; a material reduction
in opacity/manual versioning over Hole ownership; and an explicit upstream Keiki GO. Any missing item is
NO-GO. A smaller GO may approve membership while rejecting quantification, but every rejected form
remains explicitly listed and unsupported.

On NO-GO, update Progress, Decision Log, Outcomes, and the research record. Promote the durable
exclusion to an ADR if it is intended to survive beyond this experiment. Confirm plan 161's
version-2 rejection fixture still fails before scaffolding. Remove production-facing prototype
modules, parser entries, schema fields, and dependency changes; research-only benchmark fixtures
may remain when the research profile and upstream repository convention permit them. Mark GO-only
milestones not applicable and complete the plan. Do not ask for permission to implement a fallback
subset that failed the written gate.

Milestone 3 runs only after GO. Allocate the next available successor language version through the
registry established by plan 160. Freeze only the accepted syntax. The widest candidate spelling is:

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
JSON, opaque values, and direct aggregate collection registers remain rejected. If the gate did
not approve quantification, omit its syntax and binder types entirely rather than parsing them
behind a disabled capability.

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
Build a compiled consumer based on the real gate cases plus a test-only reference interpreter.
Property tests compare reference, Keiki concrete execution, symbolic formulas, encoded-event
replay, and snapshot-invalidated replay. Mutation and performance tests preserve the gate's
exactness and budget claims.

Complete either branch by documenting the result. For NO-GO, document how to select, implement,
version, and test a Hole-owned transition and what verification is lost. For GO, document syntax,
bounds, empty/duplicate/map semantics, cost limits, optional Hole-to-generated migration,
compatibility vectors, unsupported forms, and the continuing Hole escape hatch. Update ADRs
3, 4, 12, 13, and 16 only where the evidence changes their durable contracts.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Re-establish project and dependency ownership:

```bash
mori show --full
mori registry list
mori registry search keiki
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
mori registry dependents shinzui/keiki --packages
mori path mori://shinzui/keiki/packages/keiki
```

Inspect the current Hole baseline and the version-2 rejection surface:

```bash
cabal test keiro-dsl-test \
  --test-option=--match \
  --test-option='scalar expressions' \
  --test-show-details=direct
cabal run -v0 keiro-dsl -- check \
  keiro-dsl/test/fixtures/aggregate-collection-expressions-v2-rejects.keiro
```

The second command exits non-zero with `CollectionExpressionUnsupported`. Record the two real
consumer cases and prototype results in the profile-governed research document. Allocate its
stable handle and validate the bundle with:

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

1. NO-GO: fewer than two qualifying predicates exist, bounds cannot be enforced everywhere, the
   symbolic model is approximate/opaque, known unsound mutations survive, useful bounds exceed the
   cost criterion, the API does not materially improve on Hole ownership, or upstream Keiki rejects it.
   The plan records the failing evidence and finishes without production collection syntax,
   schema fields, Keiki API, release, or dependency update.
2. NO-GO keeps the plan-161 collection fixture failing with `CollectionExpressionUnsupported`,
   documents `implementation hole` and its manual fold version, and confirms generated-owned
   scalar transitions remain authoritative.
3. GO: at least two real predicates pass an exact shared concrete/symbolic prototype at realistic
   bounds with zero unknown/timeout/opaque results, every bound-entry path rejects over-bound data,
   all unsound mutations fail, performance has the required timeout headroom, the Hole comparison
   shows material correctness or maintenance benefit, and upstream Keiki records GO.
4. A GO report names the exact approved operator/scope matrix. Unapproved membership,
   quantification, nesting, map/value, or element-projection forms stay rejected and are not
   parsed into dormant nodes.
5. GO implementation allocates the then-next language version; every earlier released parser
   rejects the new syntax and retains byte-identical generated behavior.
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

On GO, keep schema, language registration, dependency release, and generated lowering in separate
checkpoints. If concrete and symbolic results disagree or a required bound fails, disable the
candidate and return the gate to NO-GO before release. Mutation scripts must install traps that
restore exact files and run `git diff --check`; never use destructive Git reset or checkout for
recovery.


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

The only potential external production dependency is a future released version of
`mori://shinzui/keiki/packages/keiki` exposing exactly the approved bounded term model, coherent
collection projections, finite predicates, bound validation, and verified-versus-unknown status.
A NO-GO adds no dependency. A GO cannot name PVP bounds until the exact Hackage release and matching
tag are inspected.

Plan 161 and plan 160 are prerequisites for a GO implementation but not for running the research
gate. Plan 161's unsupported diagnostic and explicit Hole ownership are the NO-GO terminal
behavior and remain an escape hatch after GO. No language version is reserved by this plan until
the verdict is GO.
