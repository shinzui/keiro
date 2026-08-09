---
id: 34
slug: make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption
title: "Make Keiro DSL regeneration semantically local and source-stable before wide adoption"
kind: master-plan
created_at: 2026-08-09T19:29:22Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
---

# Make Keiro DSL regeneration semantically local and source-stable before wide adoption

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Before Keiro is adopted across roughly twenty services, a local DSL edit must have a local,
explainable generated impact. A mapped-type change rewrites only its generated shape, the
aggregates that semantically consume it, and one service-level structural-conformance module.
Inserting source text before an unchanged behavior rewrites at most one context-level source map;
the aggregate's behavior contract, witness keys, runtime behavior, wire bytes, fold identity, and
snapshot identity remain byte-stable. `check`, `diff`, and `scaffold` all explain impact from the
same checked semantic dependency model.

Correctness is the first constraint. Declaration-wide structural laws and fixture branch coverage
move to one generated service boundary and still execute exactly once. Aggregate harnesses retain
only evidence tied to their own command, event, register, snapshot, or generated projection uses.
Exact file, line, and column remain available to diagnostics by resolving a stable behavior key
through a checked source index. Missing, duplicate, or unexpected source anchors refuse before the
first scaffold write. No reduction in generated churn is accepted by deleting evidence or by
guessing at dependency reachability.

This initiative implements the corrected scope of
[IR-21](../improvement-requests/make-workspace-scaffolding-semantically-local-and-source-stable.md).
The current checked `TypeGraph` has mapped roots only for aggregate command fields, private-event
fields, and registers; snapshot impact is derived from register use. Queue payloads, public
contracts, read-model schemas, and aggregate-owned projections do not currently carry mapped
`TypeExpr` roots. The plans therefore do not pretend those consumers exist. They make the root
model exhaustive so a future typed surface must extend semantic impact, generation, and reporting
together. IR-21's acceptance wording is corrected before implementation: declaration-owned
binding and fixture evidence cannot be deleted “from either aggregate,” and shared declaration
laws must not be duplicated in both aggregate harnesses.

In scope are `keiro-dsl`'s checked mapped graph, aggregate and service harness generation, the
located frontend, workspace composition, behavior contracts, scaffold ledgers and reports, diff
reports, conformance fixtures, release guidance, and an empirical regression based on
`mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`.
Generated development artifacts intentionally receive one reviewed regeneration when this lands.
Subsequent semantic no-ops and unrelated source movement are the stability contract.

Out of scope are a new DSL grammar feature, a new released language version, a lossless syntax
tree, incremental compilation, changes to Keiki runtime semantics, event/public wire formats,
persisted streams, fold fingerprints, snapshot discriminators, behavior-key bytes, dependency
bounds, package publication, and fleet rewrite automation from IR-5. Mapped queue, read-model query,
and projection consumer types are owned by the adoption-blocking follow-up
[MasterPlan 35](35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md).
Wide adoption is blocked until both MasterPlans pass their final gates; neither plan itself
migrates a service.

The planning estimate is 16–24 engineer-days for one experienced Keiro maintainer: EP-1 2–3,
EP-2 4–6, EP-3 3–5, EP-4 3–4, EP-5 2–3, and EP-6 2–3. The semantic-impact and source-provenance
tracks can proceed in parallel, giving an expected elapsed duration of roughly 10–15 working days
before review and release coordination. The estimate includes corpus regeneration and restoring
mutation tests, not downstream service migrations.


## Decomposition Strategy

The initiative has two independent correctness foundations and four downstream consumers. EP-1
defines one checked semantic-impact model from `TypeGraph` roots and corrects IR-21's impossible or
contradictory acceptance language. EP-2 consumes that model to separate declaration-wide service
conformance from aggregate-local use evidence. EP-3 preserves exact semantic spans beside, never
inside, the normalized `Spec` while keeping workspace composition semantic. EP-4 joins behavior
requirements to that index and emits one stable source-map module. EP-5 makes diff, scaffold
history, and reports consume EP-1's model instead of reconstructing impact. EP-6 is an independent
qualification gate over all of those behaviors and owns the one deliberate corpus refresh.

This separation prevents two tempting architectural mistakes. Filtering the current global
harness list inside `Harness.hs` was rejected because report generation and future consumer roots
could drift from it. Putting spans on every `Grammar` value was rejected because equality,
fingerprints, diff, replay, and workspace merging are intentionally source-location independent.
Leaving declaration laws in a deterministically selected “owner aggregate” was rejected because
that aggregate would still churn for an unrelated shared declaration. Removing locations from
diagnostics was rejected because it trades review churn for worse correctness evidence.

The prior [MasterPlan 29](29-stabilize-keiro-dsl-for-wide-adoption.md) is complete and remains the
first adoption baseline. This initiative addresses residual churn that its conformance polish and
workspace parity evidence exposed; it does not reopen its language, wire, fold, or sidecar
contracts. [MasterPlan 25](25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md)
established the structural mapping model, [MasterPlan 26](26-composable-multi-file-service-workspaces-for-keiro-dsl.md)
established semantic workspace composition, and
[MasterPlan 28](28-build-a-modular-source-aware-keiro-dsl-language-frontend.md) established the
surface/lowering seam. All three are implemented prerequisites, not child plans.

Relevant local ADR constraints are:

- [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  requires stable diagnostics and detection before writes. The new source-index coherence errors
  and any impact-ledger corruption therefore fail at `check` or scaffold preflight.
- [ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
  defines the checked `TypeGraph`, total binding laws, fixture evidence, and one schema authority.
  EP-1 and EP-2 preserve those laws while assigning declaration and consumer scopes explicitly.
- [ADR 0013](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
  forbids presenting unsupported surfaces as mapped coverage. It is why current queue and
  read-model surfaces are named as unsupported rather than guessed into the closure.
- [ADR 0014](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  keeps `wsMergedSpec` semantic and uses relocated lines only for compatibility diagnostics. EP-3
  retains that graph while adding an exact per-member source index beside it.
- [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  and [ADR 0022](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
  require additive, extension-tolerant history and detection-before-write. EP-5 stores semantic
  impact snapshots as additive ledger rows and treats an absent historical row as unknown, never
  as empty impact.
- [ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  explicitly keeps spans out of `Spec`; EP-3 extends its wrapper model rather than reversing it.
- [ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  fixes behavior-key identity and currently requires source-line annotations. EP-4 amends the
  presentation part only: the key remains frozen while positions move to the source map.
- [ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
  defines one runtime-owned service facade. EP-2 adds one structural check source to that facade
  without creating per-member packages or exposing every aggregate harness.

No relevant cross-repository ADR was found in the Mori registry search. The Mori reproducer plan
is acceptance evidence, not API authority. During implementation, EP-1/EP-2 must record the
declaration-versus-consumer conformance ownership rule durably, and EP-3/EP-4 must record the
semantic-index/source-map boundary by amending the ADRs above or creating a focused successor ADR.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Define one checked semantic-impact model for Keiro DSL consumers | [Plan 217](../plans/217-define-one-checked-semantic-impact-model-for-keiro-dsl-consumers.md) | None | None | In Progress |
| 2 | Centralize structural conformance at the service boundary and localize aggregate harnesses | [Plan 218](../plans/218-centralize-structural-conformance-at-the-service-boundary-and-localize-aggregate-harnesses.md) | EP-1 | None | Not Started |
| 3 | Preserve exact semantic source provenance through parsing and workspace composition | [Plan 219](../plans/219-preserve-exact-semantic-source-provenance-through-parsing-and-workspace-composition.md) | None | None | Not Started |
| 4 | Generate one stable behavior source map from semantic anchors | [Plan 220](../plans/220-generate-one-stable-behavior-source-map-from-semantic-anchors.md) | EP-3 | EP-1 | Not Started |
| 5 | Report scaffold and diff impact from semantic dependencies | [Plan 221](../plans/221-report-scaffold-and-diff-impact-from-semantic-dependencies.md) | EP-1 | EP-2, EP-4 | Not Started |
| 6 | Certify source-stable semantic locality before fleet adoption | [Plan 222](../plans/222-certify-source-stable-semantic-locality-before-fleet-adoption.md) | EP-2, EP-4, EP-5 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 and EP-3 can start in parallel. EP-1 owns `SemanticImpact` and the exhaustive mapping from
`UseSite` to consumer identity. EP-3 owns `SemanticSourceIndex` and the source-aware parsed/workspace
wrappers. Neither type imports the other, and neither changes generated bytes.

EP-2 hard-depends on EP-1 because aggregate harness selection and context structural-conformance
generation must consume one checked closure. EP-4 hard-depends on EP-3 because it needs exact
transition/state spans after workspace composition; it soft-depends on EP-1 only to align stable
ordering and service-level module conventions. EP-2 and EP-4 can proceed in parallel after their
respective foundation.

EP-5 hard-depends on EP-1 because diff and scaffold reporting serialize the same semantic-impact
model. It soft-depends on EP-2 and EP-4: its core report types can land earlier, but final module
classification must know the service structural module and source-map module names so reports do
not call either an aggregate impact. EP-5 also records additive snapshots in both standalone and
workspace ledgers; it must not infer a removed consumer from missing historical data.

EP-6 hard-depends on EP-2, EP-4, and EP-5. It owns the two-aggregate minimized fixture, restoring
mutations, single/workspace byte comparisons, the Mori Plan 181 replay, corpus regeneration,
documentation, and the adoption gate. The critical paths are EP-1 -> EP-2 -> EP-6 and EP-3 -> EP-4
-> EP-6, with EP-5 joining before qualification. EP-6 closes MP-34's locality gate; MP-35 remains
the hard follow-up that extends the landed authority to mapped queue, query, and projection
consumers before fleet adoption.


## Integration Points

**Checked semantic impact (EP-1 defines; EP-2, EP-5, EP-6 consume).** A new exposed
`Keiro.Dsl.SemanticImpact` module derives aggregate closures and the service-wide declaration
inventory from a resolved `TypeGraph`. It accepts only checked graph values, preserves
`MappedKey`, `UseSite`, and transitive reachability, and sorts every public projection. Harnesses,
diffs, scaffold reports, and ledgers may not recalculate closure from raw `Spec` fields.

**Structural conformance ownership (EP-2 defines; EP-5 and EP-6 observe).** One generated
`<context generated prefix>.StructuralConformance` module owns declaration-wide binding,
canonical-identity, fixture-label, branch-coverage, opaque-boundary, and projection-witness laws.
Aggregate harnesses keep only use-specific codec, wire-policy, forward/replay, snapshot, and
expression evidence for their EP-1 closure. The context `Conformance` facade imports the structural
module once. New mapped root kinds must update the checked model before either generator compiles.

**Exact source index (EP-3 defines; EP-4 and EP-6 consume).** `SemanticSourceIndex` is stored beside
`ParsedSource`/`WorkspaceSpec`, never in `Spec`, `CheckedService`, fold input, or diff identity.
Parser aggregate transitions and rejection-cell source states need exact spans. Workspace
composition unions file-qualified indices without relocating their points; the existing relocated
`Loc` and `LineMap` remain compatibility projections.

**Behavior source map (EP-4 defines; EP-5 and EP-6 observe).** One generated
`<context generated prefix>.BehaviorSourceMap` maps the frozen behavior-key text to a
`BehaviorSourceLocation` containing file, line, and column. Aggregate `BehaviorContract` modules
remove `requirementLine` and source-line comments and resolve current positions by key. Generation
preflights exact key-set equality and duplicate/collision freedom before writes.

**Scaffold history and reports (EP-5 defines; EP-6 verifies).** One sorted
`SemanticImpactSnapshot` representation is written as additive ignore-unknown rows in standalone
and workspace ledgers. `ScaffoldReport`, `WorkspaceScaffoldReport`, text rendering, and the
append-only `keiro-dsl/diff-report/1` JSON expose semantic consumers separately from
service-conformance and source-map impact. Missing legacy snapshots render “baseline unavailable”;
they never imply no impact.

**Generated corpus and adoption gate (EP-6 owns).** EP-6 alone runs the full 41-invocation corpus
regeneration after all templates settle, preventing repeated high-churn fixture updates. It pins
wire/fold/snapshot/behavior-key neutrality, exact evidence counts, mutation failures, and the Mori
reproducer's allowed file set. No service rollout or release publication is part of this plan. The
MasterPlan cannot complete until this gate is green, and fleet adoption additionally requires
MasterPlan 35's complete mapped-consumer qualification.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: correct IR-21's scope and define exhaustive semantic consumer/root identities.
- [x] EP-1: derive deterministic per-aggregate closures and service inventory with focused tests.
- [ ] EP-2: emit declaration-wide structural conformance once at the context boundary.
- [ ] EP-2: localize aggregate harnesses without losing use-specific codec/replay evidence.
- [ ] EP-3: retain exact transition and state spans through a source-aware parsed wrapper.
- [ ] EP-3: compose workspace source indices without contaminating the merged semantic graph.
- [ ] EP-4: generate and preflight one behavior-key source map for single and workspace inputs.
- [ ] EP-4: remove volatile positions from aggregate behavior contracts and diagnostics.
- [ ] EP-5: persist semantic-impact snapshots and render scaffold/diff consumers honestly.
- [ ] EP-5: prove source-only movement never becomes aggregate semantic impact.
- [ ] EP-6: pass minimized locality, evidence mutation, and single/workspace stability fixtures.
- [ ] EP-6: replay the Mori Plan 181 regression, regenerate the corpus once, and publish the gate.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- The current `TypeGraph.UseSite` inventory contains only command fields, event fields, and
  registers. IR-21's queue/read-model/projection wording describes future language work, not a
  reachable current consumer surface.
- `Harness.mappedHarnessDeclarationsResolved` returns every declaration in `tgDeclarations`, and
  `mappedProjectionSpecs` returns every projection spec. This is the concrete global-amplification
  source; event codec selection is already local through `codecMappedDeclarations`.
- Exact `SourceSpan` values already exist in the surface frontend, but `lowerSurfaceSource`
  deliberately discards them and `Workspace` rebases line-only `Loc` values into an artificial
  merged line space. The source-map work is preservation and plumbing, not a new parser library.
- The Mori Plan 181 regeneration changed 1,869 generated Haskell lines across 22 files. Unrelated
  behavior keys were stable; their contracts moved only because of line metadata, while unrelated
  harnesses repeated the same three optional-field coverage assertions.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Treat correctness, maintainable semantic authority, and reduced churn as ordered
  constraints; locality may not remove or weaken conformance evidence.
  Rationale: The initiative is a pre-adoption architecture gate, not a cosmetic diff cleanup.
  Date: 2026-08-09

- Decision: Narrow implementation to mapped roots the released grammar and checked graph actually
  represent, while making the root algebra exhaustive for future consumers.
  Rationale: Claiming queue or read-model reachability today would require guessing semantics and
  would violate ADR 0013's evidence boundary.
  Date: 2026-08-09

- Decision: Own declaration-wide structural laws once at the service boundary and own semantic-use
  evidence in aggregate harnesses.
  Rationale: Binding and fixture evidence belongs to a declaration, not an aggregate. Choosing an
  arbitrary aggregate owner would retain unrelated churn; duplicating it would retain the defect.
  Date: 2026-08-09

- Decision: Preserve exact positions in an index beside the semantic graph and isolate generated
  positions in one behavior source-map module keyed by the existing `BehaviorKey` text.
  Rationale: Putting spans in `Spec` would contaminate semantic identity, while keeping line values
  in every behavior contract turns harmless source movement into generated churn.
  Date: 2026-08-09

- Decision: Use one reviewed corpus regeneration in EP-6 and block fleet adoption until it passes.
  Rationale: The project can afford one controlled change before twenty services adopt the DSL;
  it should not spend the same fixture churn after every intermediate template change.
  Date: 2026-08-09

- Decision: Keep typed queue, read-model query, and projection consumers in a separate hard
  follow-up MasterPlan while requiring both gates before adoption.
  Rationale: This plan stabilizes the existing semantic graph. The follow-up changes candidate
  syntax, generated query APIs, and persisted queue compatibility, which need independent design
  and evidence without weakening the shared locality prerequisite.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)


## Revision Notes

- 2026-08-09: Linked MasterPlan 35 as the separate mapped-consumer language follow-up and clarified
  that MP-34 completion is necessary but not sufficient for fleet adoption.
