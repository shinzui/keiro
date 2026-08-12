---
id: 36
slug: fix-the-keiro-dsl-language-surface-defects-before-publishing-stable-language-5
title: "Fix the keiro-dsl language-surface defects before publishing stable language 5"
kind: master-plan
created_at: 2026-08-11T23:37:12Z
intention: "intention_01kzsjznhgeyvbcpfk1znzmbnr"
---

# Fix the keiro-dsl language-surface defects before publishing stable language 5

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The next keiro release (0.12.0.0) publishes keiro-dsl language 5 — currently the amendable
`Candidate` entry in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` — as the first stable,
immutable language contract. The 2026-08-11 pre-release review (a multi-agent, adversarially
verified review of every change since the `keiro-*-0.11.0.0` tags at `e796227c`) confirmed four
defects on the language surface itself. Each one either breaks a compatibility promise already
made (published languages 1–4 must keep parsing), or would freeze a dishonest or wasteful
contract into language 5 the moment it is published — after which the fix itself would be a
breaking language change.

After this MasterPlan completes: specs written under published languages 1–4 that legally use
`outcome` as an ordinary identifier parse again; a catalog-bound read model's physical binding
(schema and table) is explicit, diagnosed, and insensitive to declaration order instead of
silently taken from the first listed target; the generated read-model harness for catalog-bound
read models asserts a real async-registration identity instead of comparing a constant to
itself; the still-exported legacy `Spec`-only scaffold entry points either work again or are
deliberately removed in this major release; and `check`/`scaffold` resolve the spec type graph
once instead of roughly ten times. All four child plans must be complete before the language-5
registry entry is flipped to `Stable`/`PublishedLanguage`.

Excluded from this MasterPlan: the registry flip itself and all release mechanics (version
bumps, changelogs, tags); every runtime and operational defect from the same review (those are
`docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md`);
and the two consciously deferred language additions — the `idempotence` clause of
`docs/plans/83-add-delegated-idempotence-inbox-intake.md` and the collection syntax of
`docs/plans/166-evaluate-bounded-aggregate-collection-membership.md` — which ride a future
language 6 and must not be amended into language 5.


## Decomposition Strategy

The initiative decomposes along the four independently verifiable defects the review
confirmed, because each has its own grammar-or-generation surface, its own acceptance
evidence, and no shared code artifact that would force a merge. EP-1 fixes parser keyword
gating (`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`). EP-2 fixes the declaration semantics and
generated identity of catalog-bound read models; it deliberately merges two review findings
(the silent table/schema override in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and the vacuous
harness fact in `keiro-dsl/src/Keiro/Dsl/Harness.hs`) because both restore truthful generated
identity for the same declaration form and land in the same validation/scaffold pipeline —
splitting them would create two plans editing the same functions. EP-3 resolves the fate of
the legacy `Spec`-only entry points, a public-API concern independent of any grammar work.
EP-4 is a pure performance refactor (single type-graph resolution) whose acceptance is
byte-identical outputs, so mixing it into the semantics-changing EP-2 was rejected: a
behavior-preserving refactor and a behavior change should not share a review boundary.

Relevant ADRs, read during planning: `docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
(language contracts wrap the spec; published entries are immutable — the reason these fixes
must precede publication), `docs/adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md`
and `docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md`
(what counts as frozen replay identity — EP-2 and EP-4 must not disturb fold fingerprints),
`docs/adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md` (how harness
facts are compiled and checked — EP-2), `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(the identity separation EP-2's binding rule must respect), and
`docs/adr/0029-typed-domain-decisions-are-successful-additive-command-outcomes.md` (the
feature whose syntax introduced the `outcome` reservation EP-1 gates). No cross-repository
ADR applies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Gate the outcome reserved words on the language-5 syntax profile | docs/plans/233-gate-the-outcome-reserved-words-on-the-language-5-syntax-profile.md | None | None | Complete |
| 2 | Bind catalog read models to one explicit physical target | docs/plans/234-bind-catalog-read-models-to-one-explicit-physical-target.md | None | None | Complete |
| 3 | Retire or repair the legacy Spec-only scaffold entry points | docs/plans/235-retire-or-repair-the-legacy-spec-only-scaffold-entry-points.md | None | None | Complete |
| 4 | Resolve the spec type graph once per check and scaffold run | docs/plans/236-resolve-the-spec-type-graph-once-per-check-and-scaffold-run.md | None | EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are no hard dependencies: each plan compiles and verifies on its own. EP-1, EP-2, and
EP-3 can proceed fully in parallel — they touch disjoint grammar, validation, and API
surfaces. EP-4 carries a soft dependency on EP-2: both edit `keiro-dsl/src/Keiro/Dsl/Validate.hs`
and `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, and EP-4 refactors exactly the
`resolveTypeGraph` call sites that EP-2 may add to or move, so implementing EP-4 after EP-2
avoids rebasing a wide mechanical refactor over a semantic change. If EP-4 must start first,
coordinate on the call-site list in its Context and Orientation section.

The external gate runs the other way: the language-5 registry flip (release mechanics,
outside this MasterPlan) must not happen until all four plans here are Complete, because each
fix amends candidate language 5 or its generated output in place — legal only while the
registry entry remains `Candidate`/`CandidateLanguage`.


## Integration Points

The `DiagnosticCode` enumeration in `keiro-dsl/src/Keiro/Dsl/Validate.hs` is shared by EP-2
(which defines any new diagnostic codes for catalog read-model binding) and EP-4 (which
refactors validation plumbing but must not add, remove, or renumber codes). EP-2 owns all
code additions; EP-4 consumes the enumeration as it stands when EP-4 begins.

The compiled conformance corpus and its policy gate (`scripts/check-conformance-corpus.sh`,
`just corpus-regen`, `just conformance-corpus-policy`) are touched by EP-1 and EP-2: both
change what language 5 accepts or generates, so both must regenerate the corpus. Land and
regenerate sequentially — whichever plan merges second regenerates on top of the first —
to keep corpus churn attributable to one change at a time.

The scaffold planning pipeline in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` is touched by
EP-2 (catalog read-model binding resolution), EP-3 (the legacy `Spec`-only entry points at
its top), and EP-4 (type-graph call sites). EP-2 is authoritative for binding semantics;
EP-3 only deletes or repairs entry points and must not alter the indexed
(`ParsedSourceDocument`) path's behavior; EP-4 must leave all observable outputs
byte-identical.

Cross-plan decisions that should reach `docs/adr/`: the catalog read-model physical-binding
rule (EP-2) extends the identity separation recorded in
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
and should be added there; if EP-1 lands a general principle for how reserved words are
introduced (profile-gated reservation versus contextual keywords), record it in
`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`; if EP-3
retires the legacy entry points, the deliberate exclusion belongs in the changelog and, if
it establishes a durable API policy (indexed-only planning), a short ADR update alongside
`docs/adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md`.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (233) M1: red regression fixtures covering `outcome` as an identifier in every affected position across legacy + declared languages 1–4, plus the language-5 clause-boundary coexistence fixture
- [x] EP-1 (233) M2: contextual-keyword fix (drop the two reserved words, `try`/lookahead-guard the clause marker) turns the fixtures green with the v4 feature-gating test untouched
- [x] EP-1 (233) M3: corpus zero-drift proof, full gates, changelog, ADR-0016 distillation
- [x] EP-2 (234) M1: `CatalogReadModelPhysicalOverride` diagnostic forbids explicit table/schema on catalog-bound read models
- [x] EP-2 (234) M2: explicit order-insensitive `backing = <target>` binding; name-based resolution deduplicated across ScaffoldRun and WorkspaceScaffold; reorder diffs as nothing
- [x] EP-2 (234) M3: real grouped-harness facts against the generated ProjectionCatalog exports, with mutation-test proof
- [x] EP-2 (234) M4: corpus regeneration, gates, documentation, ADR-0026 update
- [x] EP-3 (235) M1: seven legacy Spec-only exports deleted, Haddocks relocated, library compiles
- [x] EP-3 (235) M2: test suite migrated off the retired exports while preserving the anti-fabrication proof
- [x] EP-3 (235) M3: changelog Breaking Changes entry with both migration recipes; ADR-16 amendment
- [ ] EP-4 (236) M1: baseline evidence and the `type-graph` benchmark group
- [ ] EP-4 (236) M2: inert lazy `checkedTypeGraph` field on `CheckedService` (Eq/Show-invisible)
- [ ] EP-4 (236) M3: check-pass threading (Validate/RouterSelection/ExplainBindings)
- [ ] EP-4 (236) M4: scaffold-run threading plus the workspace double-construction hoist
- [ ] EP-4 (236) M5: equivalence proof (tests, corpus zero drift) and recorded before/after timings


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Plan-creation research (2026-08-11): the review's "~10 redundant type-graph resolutions"
  was an undercount. EP-4's site inventory verified roughly twenty additional call sites,
  including a per-aggregate amplifier (`aggregateSymbols` at
  `keiro-dsl/src/Keiro/Dsl/AggregateType.hs:97`, re-resolving per dispatched command field
  inside router-selection checking) and a planning pipeline that constructs its module plan
  twice. Details and the full inventory live in
  `docs/plans/236-resolve-the-spec-type-graph-once-per-check-and-scaffold-run.md`.
- Plan-creation research (2026-08-11): contextual parsing of the outcome keywords is not
  novel — plan 232 already made the three selector words (`accepted`/`rejected`/`no-op`)
  contextual after the same defect class, and `outcome` was already a contextual keyword in
  the 0.11.0.0 workflow grammar (`keiro-dsl/src/Keiro/Dsl/Parser/Workflow.hs:125`). EP-1
  therefore removes the reservation entirely instead of feature-gating it, so `outcome`
  stays a legal identifier in language 5 as well.
- Plan-creation research (2026-08-11): `resolveCatalogReadModel` has a second, silently
  duplicated copy in `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`; EP-2 deduplicates the
  resolution into one name-based implementation, or the workspace path would retain the
  targets[0] bug after the single-source path is fixed.
- EP-1 completion (2026-08-12): the all-suites gate enforces two explicit fixture inventories
  beyond the focused parser tests. A legacy compatibility fixture must be registered in
  `keiro-dsl/test/conformance-baseline.json`, and any legacy or candidate-language fixture must
  appear in the non-stable fixture list in `keiro-dsl/test/Main.hs`. EP-2 should account for
  both policies when it adds or changes candidate-language-5 conformance evidence.
- EP-2 completion (2026-08-12): grouped read-model harness output exists in three compiled
  corpora, not the two originally identified: declarative-router's `hospitalLoad` model is
  also catalog-bound. Regenerating and running all three suites kept the change attributable,
  and the repository-wide corpus gate finished at zero drift.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Split the pre-release fixes into two MasterPlans — language-surface defects here,
  runtime/operational defects in `docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md`.
  Rationale: User direction. The two sets have different gates: this plan blocks the
  language-5 publication flip specifically; the runtime set blocks shipping 0.12 with known
  bugs but has no language-contract coupling.
  Date: 2026-08-11
- Decision: Merge the table/schema-override finding and the vacuous-harness-fact finding into
  one child plan (EP-2) instead of two.
  Rationale: Both concern the truthfulness of a catalog-bound read model's generated identity
  and edit the same validation/scaffold/harness pipeline; two plans would modify the same
  functions, violating the decomposition principle that such plans should be one.
  Date: 2026-08-11
- Decision: All four child plans gate the release; none is deferrable.
  Rationale: User directive — no known bugs ship. Independently, EP-1, EP-2, and EP-3 would
  freeze wrong behavior into the published contract, and EP-4's refactor becomes riskier once
  fingerprint-bearing outputs are frozen.
  Date: 2026-08-11
- Decision: EP-3 retires all seven Spec-only planning and planning-backed check wrappers instead
  of weakening exact-provenance requirements to repair them.
  Rationale: No repository or registered dependent caller uses the wrappers; the indexed APIs are
  already the production path; and accepting `CompatibilityLineOnly` anchors would contradict the
  behavior-source ownership contract. The 0.12 major release is the safe removal boundary.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-1 is complete. It restored `outcome` as an identifier in published languages and retained
typed domain outcomes through contextual clause parsing in candidate language 5. Regression,
compiled conformance, corpus-policy, and full repository gates pass, and ADR-16 now records the
general rule.

EP-2 is complete. Catalog-bound read models now bind to one target by name, reject competing
physical coordinates, and treat observation order as semantically inert. Their generated
harnesses assert real catalog registrations and detect perturbed async identity. Corpus and
full repository gates pass, and ADR-26 records the durable identity rule. At that checkpoint,
EP-3 and EP-4 remained before the language-5 publication gate could move.

EP-3 is complete. The seven unusable Spec-only planning and planning-backed check wrappers are
removed, the anti-fabrication proof now exercises the behavior source-map join directly, and the
changelog gives both parsed-source and programmatic-spec migration recipes. ADR-16 records
indexed-only planning as durable API policy. Strict ADR validation and the complete repository
gate pass with a byte-identical conformance corpus. EP-4 is the sole remaining child before the
language-5 publication gate can move.
