---
id: 25
slug: structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl
title: "Structural consumer-type ergonomics and soundness-preserving adoption for keiro-dsl"
kind: master-plan
created_at: 2026-07-28T10:48:47Z
intention: "intention_01kym5dc4ve69sxsjtzd81pbbz"
---

# Structural consumer-type ergonomics and soundness-preserving adoption for keiro-dsl

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

After this initiative, a consumer with an existing Haskell domain model (nested records, tagged
unions, optional values, opaque JSON leaves) can adopt `keiro-dsl` for its aggregates without
choosing between two bad options: lossy `Text` surrogates on one side, or unchecked reuse of an
arbitrary `ToJSON`/`FromJSON` instance on the other. The DSL gains the two consumer-owned type
modes requested by
[IR-1](../improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md)
(`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`):
**structural mapped types**, where a Keiro-generated codec is the single wire-schema authority
and a typed binding connects it to the consumer's type, and **opaque external-codec types**,
where Keiro honestly declines to make nested compatibility claims. Around that core capability,
the initiative delivers the ergonomics identified by the research note
[14-structural-consumer-type-tradeoffs.md](../research/14-structural-consumer-type-tradeoffs.md)
(`docs/research/14-structural-consumer-type-tradeoffs.md`) so that satisfying the soundness
boundaries becomes cheap: generated binding skeletons and derived nominal adapters, a
shadow-codec comparison command that turns brownfield migration into checkable evidence, a
structural-versus-opaque coverage report that makes drift toward the escape hatch visible,
compatibility-vector diff output that replaces one universal additive/breaking label with
per-surface classifications, and a forward-versus-replay equality assertion in the generated
harness.

The initiative also closes a documentation gap the research surfaced: nowhere is it written down,
in one place aimed at adopters, exactly what the DSL layer buys and exactly what a hand-written
(spec-less) service gives up. Two guides fix that. The guarantee ledger documents the layered
gate model — replay soundness is enforced below the DSL by keiki validation and
`ValidatedEventStream`, while cross-version evolution safety exists only in the DSL diff — and
enumerates the concrete losses of bypassing the DSL, ranked by silence (stale-snapshot serving,
tolerant-codec field removal, the unrecoverable golden-capture window). The brownfield guide
teaches a developer migrating an existing event-sourced or CRUD service how to model transducers
well (decision scalars versus payload data, register design, lifecycle vertices) and how to walk
the migration path (goldens first, shadow comparison, versioned cutover) — because brownfield
projects are harder than greenfield ones and currently have the least guidance.

The binding non-negotiable, restated from the research note and confirmed by the initiative
owner: **no ergonomic improvement may compromise soundness.** Every child plan is gated by the
research note's ten-question Proposal Test ("A Proposal Test for Future Keiro Improvements") —
authority, replay, visibility, compatibility direction, ownership, completeness, migration,
recovery, performance, and negative proof. Ergonomics reduce the cost of satisfying the
boundaries; they never relax them. In particular: codec authority is never dual (a consumer
instance may delegate to the generated codec, never the reverse); no Haskell predicate is hidden
behind checked DSL syntax; opaque mode never silently upgrades to a structural claim; and
private and public contracts remain separately owned.

Explicitly excluded, per IR-1's Out of Scope section and the research note's research-grade
list: solver-visible bounded collections, membership, and element updates; recursive structural
mappings; symbolic field projections in Keiki (the research note's Experiment C — Keiki-side
work tracked separately); proof-carrying external codecs; atomic multi-stream aggregate
generations; external-decider or event-mirror modes; and implementing Mori's Project/
ProjectArtifact transducers (that is downstream Mori work, per IR-1, after the capability is
released and tagged).


## Decomposition Strategy

The decomposition follows the layering the codebase already enforces and
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) records:
evolution hazards are checked at the earliest boundary with enough evidence, and later
boundaries independently defend runtime assembly. Three phases group nine child plans.

**Phase 1 — independent hardening and documentation (EP-1 through EP-5).** Five plans need
nothing from IR-1 and can proceed in parallel today. Two are documentation (the guarantee
ledger, EP-1, and the brownfield migration/modeling guide, EP-2). Three are code improvements
the research note and the guarantee analysis identified as valuable regardless of consumer-owned
types: a library-level helper that gives hand-written services the same fold-fingerprint
snapshot invalidation the DSL wires automatically (EP-3, closing the single most consequential
silent loss of bypassing the DSL); forward-versus-replay equality assertions in the generated
harness (EP-4, a gate-3 strengthening IR-1's harness contract demands and which currently exists
only as DB-backed audit and advisory telemetry); and the compatibility-vector diff output with
remediation explanations (EP-5, the research note's section 7, generalizing the existing
three-way `Additive | Advisory | Breaking` classification without weakening it).

**Phase 2 — the IR-1 core capability, split at its natural seam (EP-6, EP-7).** IR-1 is too
large for one balanced plan. It splits cleanly between the spec layer (EP-6: the resolved
type-expression graph, structural and opaque declaration grammar, parser/pretty-printer round
trips, `check` rejections, recursive `diff` classification with complete use-site paths, and
golden emission — everything that operates on `.keiro` text alone) and the generation layer
(EP-7: the `StructuralBinding` runtime API, generated nested codecs that own the wire schema,
scaffold integration, manifest and binding-drift records, fixture-generator bindings, and the
conformance harness including the IR-1 conformance package). The seam is the same one the
existing toolchain uses: `Keiro.Dsl.Grammar`/`Validate`/`Diff` versus `Keiro.Dsl.Scaffold`/
`Harness`. EP-6's artifacts (grammar constructors, the resolved graph, diagnostic codes) are
compile-time prerequisites for EP-7, hence the one hard dependency inside the phase.

**Phase 3 — adoption ergonomics on top of the core (EP-8, EP-9).** Two plans deliberately
separated by concern: authoring ergonomics (EP-8: create-once binding skeleton scaffolds with
typed holes, `GHC.Generics`-derived nominal adapters where field correspondence is unambiguous,
and `check --explain-bindings`) versus migration evidence (EP-9: `keiro-dsl codec compare` shadow
comparison over golden corpora, and the structural-versus-opaque coverage report that makes
opaque creep measurable in CI). Both hard-depend on EP-7 because they operate on the binding API
and generated codecs it defines. EP-9 soft-depends on EP-8 only for shared fixtures.

The mapping from the research note is explicit. Its low-risk list lands in EP-5 (compatibility
vectors, remediation explanations), EP-8 (binding skeletons, explain-bindings, derived nominal
adapters — promoted from the note's medium-risk tier because the binding is nominal-only: wire
policy stays in the spec and a wrong derived binding fails the conformance harness rather than
corrupting the wire contract), and EP-9 (shadow comparison, coverage reporting). Its Experiment A
(binding skeleton plus direct codec generation) is an acceptance scenario of EP-7/EP-8;
Experiment B (historical shadow comparison) is the acceptance scenario of EP-9; Experiment D
(usage-aware union-arm diff producing three distinct per-surface results) is the acceptance
scenario of EP-5 and is re-verified against nested paths in EP-6. Experiment C (a solver-visible
Keiki field projection) is excluded as Keiki-side research, per the deliberate-exclusion list in
Vision & Scope. Its section 6 (explicit fixtures, generator bindings, branch-coverage reporting)
lands in EP-7. Its Proposal Test is the cross-cutting soundness gate every child plan carries in
its Validation and Acceptance section.

Alternatives considered. A single "implement IR-1" plan was rejected for scope balance (it would
dwarf the other plans and hide the spec-layer/generation-layer seam that allows meaningful
intermediate validation). Folding the documentation into the code plans was rejected because the
guides have independent value now — the initiative owner needs the modeling guidance before the
IR-1 code exists — and because doc-only plans can complete in parallel without build risk.
Deferring EP-3/EP-4/EP-5 until after IR-1 was rejected because they are independent, and EP-4/
EP-5 de-risk EP-6/EP-7 by landing the harness and diff extension points first.

Relevant ADRs, read during creation:
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) (the
gate-inventory table this initiative extends; its amendment protocol binds EP-5, EP-6, and
EP-9), [ADR 0003](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md)
(the three-component snapshot discriminator EP-3 exposes to hand-written services), and
[ADR 0002](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
(guard-evolution remedies the brownfield guide EP-2 must teach). Cross-repository context:
the originating Mori request is plan
`mori://shinzui/mori/plans/171-extend-keiro-dsl-for-structural-mori-domain-contracts` and
Mori's ADR `mori://shinzui/mori/okf/adrs/concepts/ADR-6`, cited by IR-1; no keiro-local ADR
covers consumer-owned type binding yet — EP-6/EP-7 are expected to create one.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Document the guarantee ledger: what the DSL buys and what hand-written services lose | docs/plans/144-document-the-guarantee-ledger-what-the-dsl-buys-and-what-hand-written-services-lose.md | None | None | Not Started |
| 2 | Write the brownfield migration and transducer modeling guide | docs/plans/145-write-the-brownfield-migration-and-transducer-modeling-guide.md | None | EP-1 | Not Started |
| 3 | Give hand-written services first-class fold-fingerprint snapshot invalidation | docs/plans/146-give-hand-written-services-first-class-fold-fingerprint-snapshot-invalidation.md | None | None | Not Started |
| 4 | Generate forward-versus-replay equality assertions in the DSL harness | docs/plans/147-generate-forward-versus-replay-equality-assertions-in-the-dsl-harness.md | None | None | Not Started |
| 5 | Report evolution as a compatibility vector with remediation explanations | docs/plans/148-report-evolution-as-a-compatibility-vector-with-remediation-explanations.md | None | None | Not Started |
| 6 | Implement the IR-1 spec layer: resolved type graph, structural and opaque declarations, check and diff | docs/plans/149-implement-the-ir-1-spec-layer-resolved-type-graph-structural-and-opaque-declarations-check-and-diff.md | None | EP-5 | Not Started |
| 7 | Implement the IR-1 generation layer: bindings API, generated codecs, scaffold, and conformance harness | docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md | EP-6 | EP-4 | Not Started |
| 8 | Reduce binding boilerplate: skeleton scaffolds, derived nominal bindings, and explain-bindings | docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md | EP-7 | None | Not Started |
| 9 | Prove migrations with shadow codec comparison and structural coverage reporting | docs/plans/152-prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting.md | EP-7 | EP-8 | Not Started |


## Dependency Graph

Phase 1 (EP-1 through EP-5) has no hard dependencies anywhere; all five plans can proceed in
parallel immediately. EP-2 soft-depends on EP-1 because the brownfield guide links into the
guarantee ledger's layered-gate exposition rather than restating it; if EP-2 lands first it
carries a temporary summary that EP-1 later replaces with a link.

EP-6 (spec layer) has no hard dependency but soft-depends on EP-5: the compatibility-vector
shape EP-5 introduces is the output format EP-6's recursive nested classification should emit.
If EP-6 starts first it emits the existing three-way classification and adopts the vector when
EP-5 lands; the diagnostic-code registry makes that a mechanical extension.

EP-7 (generation layer) hard-depends on EP-6: generated codecs, scaffolds, manifests, and the
harness all traverse the resolved type-expression graph and grammar constructors EP-6 defines;
EP-7 code cannot compile without them. EP-7 soft-depends on EP-4 because the
forward-versus-replay equality assertion EP-4 adds to the harness must also run over aggregates
carrying mapped values; landing EP-4 first means EP-7 extends an existing assertion rather than
inventing one.

EP-8 and EP-9 both hard-depend on EP-7: binding skeletons and derivation target the
`StructuralBinding` API and generated-module layout EP-7 defines, and shadow comparison compares
against EP-7's generated codecs. EP-9 soft-depends on EP-8 only because the comparison command's
test fixtures are cheapest to author with the skeleton scaffolder available; the dependency is
convenience, not compilation.


## Integration Points

**Diagnostic-code registry** (`keiro-dsl/src/Keiro/Dsl/Validate.hs`, the shared
`DiagnosticCode` list correlating `check` and `diff` per ADR 0004). Touched by EP-5 (new
vector/remediation codes), EP-6 (structural/opaque rejection and classification codes), EP-9
(coverage-report codes). EP-5 defines the vector-output conventions first; EP-6 and EP-9 extend
the registry following those conventions. Codes are append-only; no plan renames or reuses an
existing code.

**Harness generator** (`keiro-dsl/src/Keiro/Dsl/Harness.hs`, `harnessAssertions`). Touched by
EP-4 (forward-versus-replay equality assertion) and EP-7 (structural binding round trips, codec
goldens, branch coverage, and extending EP-4's assertion to mapped registers). EP-4 defines the
assertion's shape and labeling convention; EP-7 extends it without changing its meaning for
existing specs.

**Diff and replay-impact modules** (`keiro-dsl/src/Keiro/Dsl/Diff.hs`,
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`, and the closed `familyRegistry`). Touched by EP-5
(classification output becomes a per-surface vector) and EP-6 (recursive descent into mapped
type expressions with complete root-to-leaf use-site paths). EP-5 owns the output shape; EP-6
owns the nested traversal. Both preserve the invariant that `diff` exits non-zero only on a
breaking classification for the surfaces the operator selected.

**`StructuralBinding` API and generated-module layout.** Defined by EP-7 (runtime binding
types, the generated codec's ownership of wire keys/tags, import discipline below the generated
ring, manifest fields, binding-drift records in scaffold records). Consumed by EP-8 (skeletons
and derivation emit and target this API) and EP-9 (shadow comparison drives the generated codec
through it). EP-7 must publish the API in a dedicated module with a stability note before EP-8/
EP-9 begin.

**Snapshot discriminator and fold fingerprint** (`keiro/src/Keiro/Snapshot/Codec.hs`
`withFoldFingerprint`, `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`, ADR 0003). Touched by
EP-3 (hand-written-service helper and jitsurei adoption) and referenced by EP-1's ledger and
EP-2's guide. EP-3 owns the helper; the guides link to it.

**Guides corpus** (`docs/guides/`). EP-1 creates the guarantee ledger; EP-2 creates the
brownfield guide and cross-links `adopting-keiro-from-tan-event-source.md`,
`evolution-and-replayability.md`, and `migrating-to-validated-event-stream.md`. EP-8 and EP-9
each append the sections documenting their new commands to EP-2's guide (and the
evolution guide where relevant) as part of their own acceptance, so the guides never describe
tooling that does not exist.

**ADR 0004's gate-inventory table.** Its amendment protocol ("the inventory is amended when a
later child plan changes a gate's ownership") binds EP-4 (new conformance-CI gate row), EP-5
(classification output change), EP-6 (new structural/opaque change classes), and EP-9 (coverage
gate). Cross-plan decisions expected to become new ADRs: codec authority for consumer-owned
types (single generated authority, delegation direction — allocated and created by EP-6 with
status Proposed; extended and moved to Accepted by EP-7), and the structural-versus-opaque
coverage policy (EP-9).

**Contract-field grammar** (`ContractType` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`). EP-5
owns the minimal `CEnum` contract-field extension (an enum-typed contract field, lowered to
`Text`) needed to make Experiment D's public-contract leg expressible. EP-6's mapped-type
grammar is a separate surface: mapped declarations never appear in contract nodes, and EP-6
does not redefine `ContractType`; it builds beside EP-5's extension without touching it.

**IR-1 and the research note as normative references.** Every child plan cites
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` (IR-1) and
`docs/research/14-structural-consumer-type-tradeoffs.md` and states which of its sections it
implements; EP-6/EP-7 additionally carry IR-1's acceptance list and negative-fixture/mutation
requirements verbatim. IR-1's status field moves from `proposed` toward accepted/implemented as
EP-6/EP-7 complete; EP-1 records the reframed justification (layered soundness,
no-false-confidence) in IR-1 itself.


## Progress

- [ ] EP-1: Guarantee ledger guide drafted (layered gates, DSL benefits, hand-written losses ranked by silence)
- [ ] EP-1: IR-1 justification reframed and cross-linked; evolution guide cross-links landed
- [ ] EP-2: Transducer modeling chapters drafted (decision scalars, registers, lifecycle vertices)
- [ ] EP-2: Brownfield migration path drafted (goldens first, versioned cutover, upcasters, audit)
- [ ] EP-3: Fold-fingerprint helper API landed in keiro with tests
- [ ] EP-3: jitsurei adopts the helper; guides and ADR 0003 references updated
- [ ] EP-4: Forward-versus-replay equality assertion generated for aggregate harnesses
- [ ] EP-4: Mutation test proves a divergent fold fails the assertion; ADR 0004 inventory amended
- [ ] EP-5: Compatibility-vector output and per-surface classification landed behind stable codes
- [ ] EP-5: `diff --explain` remediation output landed; Experiment D scenario passes
- [ ] EP-6: Resolved type-expression graph, grammar, and parser/pretty round trips landed
- [ ] EP-6: `check` negative fixtures and recursive `diff` classification with use-site paths landed
- [ ] EP-7: `StructuralBinding` API, generated codecs, and scaffold integration landed
- [ ] EP-7: Conformance package passes structural-codec, fixture-coverage, and forward/replay tests
- [ ] EP-8: Binding skeleton scaffolds with typed holes and re-scaffold hole reporting landed
- [ ] EP-8: Derived nominal bindings and `check --explain-bindings` landed; Experiment A scenario passes
- [ ] EP-9: `codec compare` shadow comparison landed; Experiment B scenario passes
- [ ] EP-9: Structural-versus-opaque coverage report landed; guides updated; ADR distillation complete


## Surprises & Discoveries

Recorded during child-plan drafting (2026-07-28):

- `keiro-dsl` deliberately does not depend on the `keiro` package, so EP-9 (plan 152)
  cannot reuse `Keiro.ReplayDigest.canonicalJsonBytes` for semantic JSON equality; it uses
  the same underlying primitive directly — aeson's `Data.Aeson.RFC8785.encodeCanonical`
  (aeson >= 2.2.1) — keeping the algorithm identical to the replay audit without inverting
  the package layering.
- The harness's uniform `"sample"` `Text` sample values would make a same-typed field swap
  byte-invisible, giving the forward/replay equality assertion zero discriminating power;
  EP-4 (plan 147) makes `Text` samples per-field distinct (`"sample-<fieldName>"`). Also,
  keiki's `RegFile` has no `Eq` instance, so register comparison uses per-register indexed
  lookups (`regs ! #name`) rather than whole-file equality.
- Contract fields today are only `CTypeId | CText | CInt`, so the research note's
  Experiment D public-contract leg is inexpressible; EP-5 (plan 148) adds a minimal
  `CEnum` contract-field grammar extension to make it expressible (see Integration Points).
- The `Justfile` has no keiro-dsl test recipes — `just haskell-test` does not cover
  `keiro-dsl-test` or the conformance suites — so the child plans state `cabal test`
  commands directly rather than relying on `just` recipes.


## Decision Log

- Decision: Include the IR-1 core implementation in this MasterPlan rather than treating it as
  external work the ergonomics depend on.
  Rationale: Confirmed with the initiative owner. The ergonomics plans (EP-8, EP-9) are
  meaningless without the core, and sequencing both under one plan keeps the soundness gates in
  one governance structure.
  Date: 2026-07-28

- Decision: Split IR-1 into a spec-layer plan (EP-6) and a generation-layer plan (EP-7) at the
  Grammar/Validate/Diff versus Scaffold/Harness seam.
  Rationale: One plan would dwarf the rest of the initiative and hide the intermediate
  validation point (a spec that parses, checks, and diffs correctly before any code generation
  exists). The seam matches the existing module structure of `keiro-dsl`.
  Date: 2026-07-28

- Decision: Adopt the research note's ten-question Proposal Test as a mandatory acceptance gate
  in every child plan, and record the non-negotiable that ergonomics never relax soundness
  boundaries (single codec authority, no hidden opaque semantics, no silent structural upgrade
  of opaque mode, separate private/public ownership).
  Rationale: Explicit instruction from the initiative owner; the research note's central
  conclusion is that the constraints are well placed and only their cost should fall.
  Date: 2026-07-28

- Decision: Promote derived nominal bindings (EP-8) from the research note's medium-risk tier
  into this initiative's scope.
  Rationale: The binding is nominal-only; wire keys, tags, presence, and defaults stay in the
  `.keiro` spec, and the generated codec plus pinned goldens remain the check. A wrong derived
  binding fails the conformance harness; it cannot silently alter the wire contract. Binding
  boilerplate is the strongest force pushing consumers into opaque mode, which is the outcome
  the design most needs to avoid.
  Date: 2026-07-28

- Decision: Exclude Keiki-side symbolic projections (research note Experiment C), bounded
  collections, and recursive structural mappings.
  Rationale: These are research-grade per the note's own risk tiers and require new Keiki terms,
  evaluators, and validator support before any DSL syntax may claim them (guarantee G4). They
  must not enter through this initiative's scope as unproven promises.
  Date: 2026-07-28

- Decision: The codec-authority ADR for consumer-owned types is allocated and created by
  EP-6 (plan 149) — handle via `okf id next`, status Proposed — and EP-7 (plan 150) extends
  it (stratified generated ring, `Shapes` leaf) and moves it to Accepted once the generated
  codec exists. Exactly one plan allocates; the other amends.
  Rationale: Both IR-1 plans initially mentioned creating the ADR; a single allocator
  avoids duplicate handles and log entries. EP-6 lands first and EP-7 hard-depends on it,
  so allocation belongs to EP-6.
  Date: 2026-07-28

- Decision: Land EP-4 and EP-5 in Phase 1 rather than folding them into the IR-1 plans.
  Rationale: Both are valuable for existing specs today, both de-risk Phase 2 by establishing
  the harness-assertion and diff-output extension points first, and both are independently
  verifiable without consumer-owned types.
  Date: 2026-07-28


## Outcomes & Retrospective

(To be filled during and after implementation.)
