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
scaffolded, consumer-compiled shadow-codec comparison runner that turns brownfield migration into checkable evidence, a
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

The binding non-negotiable, confirmed by the initiative owner and recorded locally in
[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md),
is: **no ergonomic improvement may compromise soundness.** Each child plan answers the ten
review questions first collected by the research note — authority, replay, visibility,
compatibility direction, ownership, completeness, migration, recovery, performance, and
negative proof — but those Mori-originated artifacts are inputs, not the API authority. The
Keiro ADRs, the public Keiki 0.4 API, generated conformance tests, and the behavior of this
repository are normative. Ergonomics reduce the cost of satisfying those boundaries; they
never relax them. In particular: codec authority is never dual; a structural binding is a
total bidirectional mapping rather than a hidden semantic decoder; no Haskell predicate is
hidden behind checked DSL syntax; opaque mode never silently upgrades to a structural claim;
and private and public contracts remain separately owned.

Keiki IR-1 is no longer a research prerequisite: Keiki 0.4.0.0 implements typed symbolic field
projections through `FieldProjection`, `FieldWitness`, `regProj`, and `inpProj`. This initiative
adopts that released API in a generated, schema-derived projection facade for hand-written
Holes. Keiki's actual validation boundary remains visible: projections are guard-only, start
from a direct register or matched input field, and return members of the curated symbolic
registry (with a smaller subset supporting ordering). Exact nested field-path syntax in
`.keiro` remains excluded because the current scaffolder renders guard/write intent as comments
in create-once Holes rather than lowering it to the running transducer. Such syntax may enter a
future plan only with an exact lowering and equivalence gate.

Other explicit exclusions remain: solver-visible bounded collections, membership, and element
updates; recursive or refined structural mappings; proof-carrying external codecs; atomic
multi-stream aggregate generations; external-decider or event-mirror modes; and implementing
any particular Mori transducer. Existing DSL ID/enum references are also excluded from the
first structural-shape grammar; admitting them later requires moving those leaves below aggregate
`Domain` modules so the per-declaration `Generated.*.Structural.Shape.*` stratum stays acyclic.


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
(EP-7: the total `StructuralBinding` runtime API, generated nested codecs that own the private
event wire schema, a Keiki 0.4 projection facade for eligible fields, scaffold integration,
manifest and mapping-drift records, fixture bindings, and the conformance harness including the
IR-1 conformance package). The seam is the same one the
existing toolchain uses: `Keiro.Dsl.Grammar`/`Validate`/`Diff` versus `Keiro.Dsl.Scaffold`/
`Harness`. EP-6 consumes EP-5's compatibility-vector and remediation registries rather than
creating a transitional second classifier; EP-6's artifacts (grammar constructors, the resolved
graph, diagnostic codes) are then compile-time prerequisites for EP-7.

**Phase 3 — adoption ergonomics on top of the core (EP-8, EP-9).** Two plans deliberately
separated by concern: authoring ergonomics (EP-8: create-once binding skeleton scaffolds with
typed holes, narrowly derived nominal adapters where constructor/field order, constructor and
selector names, and field types match exactly, and `check --explain-bindings`) versus migration evidence (EP-9:
an opt-in generated shadow-comparison runner invoked by hand-owned test code with an explicit
historical-codec value over finite golden corpora, and a
structural-versus-opaque report over the roots the resolved graph actually models). Both
hard-depend on EP-7 because they operate on the binding API
and generated codecs it defines. EP-9 soft-depends on EP-8 only for shared fixtures.

The mapping from the research note is explicit. Its low-risk list lands in EP-5 (compatibility
vectors, remediation explanations), EP-8 (binding skeletons, explain-bindings, derived nominal
adapters — narrowed from the note's medium-risk tier to exact representation correspondence:
wire policy stays in the spec, while both binding laws and finite conformance cases exercise the
adapter), and EP-9 (historical comparison and supported-root reporting). Its Experiment A
(binding skeleton plus direct codec generation) is an acceptance scenario of EP-7/EP-8;
Experiment B (historical shadow comparison) informs EP-9; its Mori type is not the acceptance
API. EP-5 proves usage-aware classification with existing private and public change fixtures
rather than adding a nominal `CEnum -> Text` shortcut. Experiment C's Keiki prerequisite is now
implemented and lands in EP-7 as the narrow generated projection facade; checked nested DSL
paths remain deferred. Explicit fixture and branch-coverage ideas land in EP-7, with the
important limitation that finite examples are evidence, not universal proof. The Proposal Test
remains a useful review checklist, while local interfaces and tests define acceptance.

Alternatives considered. A single "implement IR-1" plan was rejected for scope balance (it would
dwarf the other plans and hide the spec-layer/generation-layer seam that allows meaningful
intermediate validation). Folding the documentation into the code plans was rejected because the
guides have independent value now — the initiative owner needs the modeling guidance before the
IR-1 code exists — and because doc-only plans can complete in parallel without build risk.
Deferring EP-3/EP-4/EP-5 until after IR-1 was rejected because they are independent, and EP-4/
EP-5 de-risk EP-6/EP-7 by landing the harness and diff extension points first.

Relevant ADRs, read during creation and this revision:
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) (the
gate-inventory table this initiative extends; its amendment protocol binds EP-5, EP-6, and
EP-9), [ADR 0003](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md)
(the three-component snapshot discriminator EP-3 exposes to hand-written services), and
[ADR 0002](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
(guard-evolution remedies the brownfield guide EP-2 must teach), and
[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
(single event-schema authority, total bindings, separate snapshot-cache boundary, and generated
Keiki projection provenance). Cross-repository context:
the originating Mori request is plan
`mori://shinzui/mori/plans/171-extend-keiro-dsl-for-structural-mori-domain-contracts` and
Mori's ADR `mori://shinzui/mori/okf/adrs/concepts/ADR-6`, cited by IR-1. They explain the
request's origin but do not constrain the reusable Keiro API beyond the local decisions above.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Document the guarantee ledger: what the DSL buys and what hand-written services lose | docs/plans/144-document-the-guarantee-ledger-what-the-dsl-buys-and-what-hand-written-services-lose.md | None | None | Complete |
| 2 | Write the brownfield migration and transducer modeling guide | docs/plans/145-write-the-brownfield-migration-and-transducer-modeling-guide.md | None | EP-1 | Complete |
| 3 | Give hand-written services first-class fold-fingerprint snapshot invalidation | docs/plans/146-give-hand-written-services-first-class-fold-fingerprint-snapshot-invalidation.md | None | None | Complete |
| 4 | Generate forward-versus-replay equality assertions in the DSL harness | docs/plans/147-generate-forward-versus-replay-equality-assertions-in-the-dsl-harness.md | None | None | Complete |
| 5 | Report evolution as a compatibility vector with remediation explanations | docs/plans/148-report-evolution-as-a-compatibility-vector-with-remediation-explanations.md | None | None | Complete |
| 6 | Implement the IR-1 spec layer: resolved type graph, structural and opaque declarations, check and diff | docs/plans/149-implement-the-ir-1-spec-layer-resolved-type-graph-structural-and-opaque-declarations-check-and-diff.md | EP-5 | None | Complete |
| 7 | Implement the IR-1 generation layer: total bindings, codecs, Keiki projection facade, scaffold, and conformance harness | docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md | EP-6, Keiki 0.4 | EP-4 | Complete |
| 8 | Reduce binding boilerplate: skeleton scaffolds, exact nominal derivation, and explain-bindings | docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md | EP-7 | None | Complete |
| 9 | Gather migration evidence with historical codec comparison and supported-root coverage reporting | docs/plans/152-prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting.md | EP-7 | EP-8 | In Progress |


## Dependency Graph

Phase 1 (EP-1 through EP-5) has no hard dependencies anywhere; all five plans can proceed in
parallel immediately. EP-2 soft-depends on EP-1 because the brownfield guide links into the
guarantee ledger's layered-gate exposition rather than restating it; if EP-2 lands first it
carries a temporary summary that EP-1 later replaces with a link.

EP-6 (spec layer) hard-depends on EP-5: its recursive nested classification emits EP-5's
`ChangeContext`, `CompatibilityVector`, rollout constraints, and remediation values directly.
This avoids a temporary three-way classifier, duplicate change constructors, and a later
conversion that could classify the same mapped change differently at two boundaries.

EP-7 (generation layer) hard-depends on EP-6 and on the coordinated Keiki 0.4 API migration:
generated codecs, projection witnesses, scaffolds, manifests, and the harness all traverse the
resolved type-expression graph and grammar constructors EP-6 defines, while the facade uses
Keiki's released `FieldProjection`/`FieldWitness` API. All current `>=0.3.1 && <0.4` bounds and
exhaustive term/warning matches in this repository must move together; EP-7 cannot compile
without both prerequisites. EP-7 soft-depends on EP-4 because the
forward-versus-replay equality assertion EP-4 adds to the harness must also run over aggregates
carrying mapped values; landing EP-4 first means EP-7 extends an existing assertion rather than
inventing one.

EP-8 and EP-9 both hard-depend on EP-7: binding skeletons and derivation target the
`StructuralBinding` API and generated-module layout EP-7 defines, and shadow comparison compares
against EP-7's generated codecs. EP-9 soft-depends on EP-8 only because the comparison runner's
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

**`StructuralBinding` API and generated-module layout.** Defined by ADR 0012 and implemented by
EP-7 (a total two-way nominal mapping, both round-trip laws, the generated private-event codec's
ownership of wire keys/tags, one context-level shape module per mapped declaration so constructor
names neither collide nor require mangling, import discipline below the generated ring, manifest fields,
mapping-drift records in scaffold records). Consumed by EP-8 (skeletons
and derivation emit and target this API) and EP-9 (shadow comparison drives the generated codec
through it). EP-7 must publish the API in a dedicated module with a stability note before EP-8/
EP-9 begin.

**Keiki projection facade.** EP-7 generates nominal field tags, `FieldProjection` instances,
and `FieldWitness` values from the same resolved graph and binding used by the codec. The facade
supports hand-written Holes through `regProj`/`inpProj`; it does not add nested `.keiro` syntax.
It preserves Keiki 0.4's guards-only/direct-base/curated-result restrictions and establishes
witness provenance by generation and conformance checks at Keiro's boundary, which Keiki
intentionally cannot infer from consumer code itself. Diagnostic field paths use escaped JSON
Pointers; nominal tag identity, not the diagnostic string, controls symbolic sharing.

**Snapshot discriminator and fold fingerprint** (`keiro/src/Keiro/Snapshot/Codec.hs`
`withFoldFingerprint`, `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`, ADR 0003). Touched by
EP-3 (hand-written-service helper and jitsurei adoption) and EP-7 (mapped wire fingerprint,
binding and register-initial provenance, and projection schema contribute to invalidation). The current snapshot
codec still uses consumer `ToJSON`/`FromJSON` instances for register cache storage; no plan may
report the generated event codec as structural snapshot execution. EP-6 (plan 149) classifies
mapped snapshot impact as invalidate/rebuild, and EP-9 (plan 152) reports it as a boundary rather than codec
coverage.

**Guides corpus** (`docs/guides/`). EP-1 creates the guarantee ledger; EP-2 creates the
brownfield guide and cross-links `adopting-keiro-from-tan-event-source.md`,
`evolution-and-replayability.md`, and `migrating-to-validated-event-stream.md`. EP-8 and EP-9
each append the sections documenting their new commands to EP-2's guide (and the
evolution guide where relevant) as part of their own acceptance, so the guides never describe
tooling that does not exist.

**ADR 0004's gate-inventory table.** Its amendment protocol ("the inventory is amended when a
later child plan changes a gate's ownership") binds EP-4 (new conformance-CI gate row), EP-5
(classification output change), EP-6 (new structural/opaque change classes), and EP-9 (an
explicit optional policy gate, if retained). ADR 0012 already owns codec authority, total
binding, snapshot-boundary, and projection-provenance decisions; EP-6/EP-7 amend and accept it
when the implementation proves them. EP-9 creates a separate coverage-policy ADR only if its
reporting policy remains a durable project-wide decision after implementation.

**Contract-field grammar** (`ContractType` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`). This
initiative does not add a `CEnum Name` lowered to `Text`: that shortcut would erase nominal
ownership and couple a general compatibility API to a single research scenario. EP-5 exercises
public-consumer classification through existing contract changes. EP-6's mapped grammar remains
private-event/register-only; public DTO evolution stays independently owned.

**Local authority and origin references.** ADRs 0002, 0003, 0004, and 0012, released Keiki
0.4 interfaces, generated code, and conformance observations define the implementation. IR-1
and the research note remain useful requirements and review history, but child plans translate
them into consumer-neutral interfaces rather than copying acceptance text or Mori examples
verbatim. IR-1 status advances only when the Keiro capability, including the Keiki 0.4 adoption,
is implemented and released.


## Progress

- [x] 2026-07-28: Revalidated the initiative against released Keiki 0.4.0.0 and current Keiro DSL/runtime code; revised all affected child plans and proposed ADR 0012
- [x] 2026-07-28: Reconciled master/child dependencies and interfaces; strict ADR validation, ADR-12 inspection, offline link checking, and diff hygiene passed
- [x] 2026-07-28: EP-1 guarantee ledger guide drafted (layered gates, DSL benefits, hand-written losses ranked by silence)
- [x] 2026-07-28: EP-1 IR-1 justification reframed and cross-linked; evolution guide cross-links landed
- [x] 2026-07-28: EP-2 transducer modeling chapters drafted (decision scalars, registers, lifecycle vertices)
- [x] 2026-07-28: EP-2 brownfield migration path drafted (goldens first, versioned cutover, upcasters, audit)
- [x] 2026-07-28: EP-3 fold-fingerprint helper API landed in keiro with discriminator and full-replay tests
- [x] 2026-07-28: EP-3 jitsurei adoption, guides, ADR 0003 amendment, and full verification completed
- [x] 2026-07-28: EP-4 forward-versus-replay equality assertion generated for aggregate harnesses
- [x] 2026-07-28: EP-4 mutation test proves a divergent fold fails the assertion; ADR 0004 inventory amended
- [x] 2026-07-28: EP-5 compatibility-vector output and per-surface classification landed behind stable codes
- [x] 2026-07-28: EP-5 `diff --explain` remediation output landed; consumer-neutral private/public scenarios pass
- [x] 2026-07-28: EP-6 resolved type-expression graph, grammar, parser/pretty round trips, and total traversal algebras landed
- [x] 2026-07-28: EP-6 `check` negative fixtures, recursive root-aware `diff`, replay impact, exhaustive mutation proof, and nested weak-golden synthesis landed
- [x] 2026-07-28: EP-7 total `StructuralBinding` API, generated codecs, Keiki 0.4 projection facade, and scaffold integration landed
- [x] 2026-07-28: EP-7 conformance package passes both binding laws, structural-codec, fixture-coverage, projection, and forward/replay tests; all three mutations go red and the 2x benchmark budget passes
- [x] 2026-07-28: EP-7 shared `0.4.0.0` release preparation approved and completed; all mandatory release gates pass, while annotated tags, pushes, and publication remain assigned to the initiative release train
- [x] 2026-07-28: EP-8 create-once binding skeletons, granular scaffold-record obligations, and exact newly-required-hole reporting landed
- [x] 2026-07-28: EP-8 exact nominal bindings and `check --explain-bindings` landed; the conformance ring, four mutations, strict ADR validation, and `just verify` pass
- [ ] EP-9: Explicit historical-codec comparison over a finite corpus landed
- [ ] EP-9: Supported-root structural/opaque and snapshot-boundary report landed; guides updated; ADR distillation complete


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
- Keiki 0.3.1's `solveOutput` rebuilds an observed event with the active `wcBuild` before
  accepting inversion. A simple dishonest field swap therefore fails replay before state
  comparison. EP-4's negative proof uses an idempotent dishonest build (copy the second
  same-typed field into both wire fields), which survives that rebuild check while causing a
  register-only forward/replay divergence. EP-7 should reuse the idempotent pattern when
  mutation-testing consumer-owned structural bindings.
- Keiki 0.4.0.0 is the current Hackage release and upstream `v0.4.0.0` tag. It implements
  typed field projections, but deliberately limits validated uses to guards with direct
  register/matched-input bases and curated scalar results; computed bases cross a
  `NonStructuralProjectionBoundary`. Current Keiro package bounds (`>=0.3.1 && <0.4`) exclude
  this API and require a coordinated dependency and exhaustive-match migration.
- The coordinated migration includes `keiki-codec-json >=0.4 && <0.5`, not only `keiki`:
  `keiki-codec-json` 0.3.1 pins `keiki ^>=0.3`, while the 0.4.0.0 companion release pins the
  projection-bearing core. EP-7 verified both against Hackage and upstream tag `v0.4.0.0`.
- The current scaffolder does not execute `.keiro` guard/write syntax: it writes intent as
  comments in create-once Holes, and the generated-module firewall rejects general Keiki
  symbolic operators. A generated projection facade is sound for those hand-written Holes;
  claiming checked nested DSL syntax is not yet sound.
- `bindingFromShape :: shape -> Either Text domain` would make consumer-only rejection
  invisible to structural diff. ADR 0012 therefore requires a total isomorphism and both
  round-trip laws. Separately, `defaultStateCodec` serializes register snapshots through
  consumer JSON instances, so generated structural event codecs must invalidate snapshots
  rather than claim to execute their historical encoding.
- Contract fields today are only `CTypeId | CText | CInt`. Adding `CEnum Name` and lowering it
  to `Text` solely to reproduce a Mori research scenario would weaken nominal ownership; EP-5
  now tests its general vector API using existing private and public change classes.
- A registry of traversals is not compile-time evidence that every `TypeExpr` consumer is
  complete. EP-6 now owns an exported algebra and fold, so adding a constructor forces every
  subsystem algebra to be updated by the compiler.
- JSON null makes some apparently ordinary shapes non-injective: `Optional Json`, nested
  `Optional`, and `Optional` around an unconstrained opaque codec cannot distinguish `Nothing`
  from an inner null. EP-6 now rejects these shapes, identical union tag/contents keys, and
  duplicate Haskell field names before generation.
- Keiro cannot reliably hash arbitrary consumer Haskell to detect binding-semantic changes. EP-6
  therefore makes `binding-version` mandatory and diff-visible; EP-7 records it, runs conformance,
  and includes it in mapped-register invalidation.
- The `Justfile` has no keiro-dsl test recipes — `just haskell-test` does not cover
  `keiro-dsl-test` or the conformance suites — so the child plans state `cabal test`
  commands directly rather than relying on `just` recipes.
- EP-5 found that the current aggregate-event grammar has no explicit unknown-field decode
  policy. Its compatibility registry therefore records old-binary risk only where the present
  spec provides evidence. EP-6 must make that policy an explicit structural-declaration fact and
  feed it into EP-5's `ChangeContext`; inheriting an implicit reject/ignore default would make
  nested classifications unsound.
- EP-7's conformance fixture intentionally shares one hand-owned binding module across four
  structural declarations. EP-8 therefore groups create-once skeletons by the qualified symbol's
  owning module while retaining field/arm-granular obligations in the scaffold record.
- Exact generic representations cannot reveal the module containing the binding value. EP-8 keeps
  the successful API free of a forgeable promoted-path argument and uses GHC's exact invocation
  source span, plus a stable custom error directing the author to that scaffolded module.


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

- Decision: Use the research note's ten-question Proposal Test as a mandatory review checklist
  in every child plan, and record the non-negotiable that ergonomics never relax soundness
  boundaries (single codec authority, no hidden opaque semantics, no silent structural upgrade
  of opaque mode, separate private/public ownership).
  Rationale: Explicit instruction from the initiative owner; the questions expose useful failure
  modes. Local ADRs, released dependency APIs, generated interfaces, and observed tests remain
  normative so the initiative does not overfit the originating Mori proposal.
  Date: 2026-07-28

- Decision: Keep only exact-match nominal derivation in EP-8: constructor names, selector names,
  and nested bound field types must match without prefix stripping, coercion, or guessing.
  Rationale: Wire policy remains in the spec, but fixtures cannot prove a heuristic mapping
  correct for all values. Exact representation correspondence plus both binding laws is a
  maintainable convenience; renamed or refined domains use the generated skeleton.
  Date: 2026-07-28

- Decision: Adopt Keiki 0.4 projections through a generated facade, but exclude checked nested
  `.keiro` field-path syntax, bounded collections, and recursive structural mappings.
  Rationale: Keiki now supplies the term, evaluator, symbolic translation, validator, and
  nominal witness API. Keiro can generate witness provenance from its schema authority for
  hand-written Holes. The DSL still lacks an exact lowering from checked guard text to running
  code, so syntax would overclaim what is executed.
  Date: 2026-07-28

- Decision: Allocate ADR 0012 in this MasterPlan revision; EP-6 and EP-7 amend it and move it
  to Accepted only after the total binding, generated codec, snapshot invalidation, and Keiki
  projection facade are implemented and observed.
  Rationale: These are cross-plan architectural constraints needed before either child begins,
  so allocating them to a later implementation plan would let the two plans drift.
  Date: 2026-07-28

- Decision: Land EP-4 and EP-5 in Phase 1 rather than folding them into the IR-1 plans.
  Rationale: Both are valuable for existing specs today, both de-risk Phase 2 by establishing
  the harness-assertion and diff-output extension points first, and both are independently
  verifiable without consumer-owned types.
  Date: 2026-07-28

- Decision: Make EP-5 a hard prerequisite of EP-6.
  Rationale: EP-6 now emits EP-5's `ChangeContext`, six-surface `CompatibilityVector`, rollout
  constraints, and non-empty remediation values directly. A soft dependency would require a
  temporary second classifier and a later conversion where the same mapped change could acquire
  two answers.
  Date: 2026-07-28

- Decision: EP-6 will supply explicit unknown-field policy evidence when it extends EP-5's
  `ChangeContext`; EP-5 does not infer that policy for the current aggregate-event grammar.
  Rationale: A compatibility vector must describe observable decoder behavior. Treating absent
  grammar evidence as reject or ignore would overstate one deployment direction and give EP-6 a
  misleading default at recursive use sites.
  Date: 2026-07-28

- Decision: Treat Keiki 0.4.0.0's public API and tests, not Keiki IR-1 prose, as the dependency
  contract. Generate `FieldProjection`/`FieldWitness` declarations only for eligible fields and
  consume them through `regProj`/`inpProj`; never reconstruct an owner value from a projected
  scalar.
  Rationale: Upstream implemented the request with one-way symbolic agreement by design.
  Preserving that over-approximation, guard-only restriction, structured sharing key, and
  composition warning is necessary for soundness and for other Keiki consumers.
  Date: 2026-07-28

- Decision: Structural bindings are total in both directions, `canonical-type` is checked
  against the consumer's `CanonicalTypeName`, every structural mapping carries an explicit
  diff-visible `binding-version`, and mapped schema/binding/projection changes feed
  the snapshot fingerprint rather than replacing the snapshot codec.
  Rationale: A partial inverse hides domain semantics from diff, an unchecked nominal name can
  bind the wrong consumer type, and the current snapshot path demonstrably uses consumer JSON
  instances. These boundaries are recorded in ADR 0012.
  Date: 2026-07-28

- Decision: Structural declarations require one non-empty `fixtures = Module.symbol` value,
  explicit `on-missing` for optional fields, and an explicit `unknown-fields = reject|ignore`
  decode policy. The v1 grammar uses existing `Time`/`UTCTime` spelling and supports only mapped
  declaration references. Its raw parser AST can represent missing facts for diagnostics, while
  the resolved graph exposes only checked, mandatory-field declarations and typed graph errors.
  Rationale: These choices make construction and old/new decode direction explicit, avoid two
  competing fixture APIs, and prevent generated-module cycles through existing domain IDs/enums.
  Date: 2026-07-28


## Outcomes & Retrospective

EP-6 completed the IR-1 spec layer. Structural and opaque consumer mappings now have one checked
graph that drives validation, compatibility classification, replay impact, and weak-golden
synthesis, with total traversal algebras and an exhaustive mutation proof guarding nested
coverage. At that intermediate boundary EP-7 became ready and took ownership of bindings, codecs,
shape modules, projection facades, scaffold integration, and executable conformance.

EP-7's generation boundary is implemented and verified: the published total binding API, acyclic
shape stratum, declared-wire codecs, projection facade, scaffold preflight/manifest/record, mapped
snapshot invalidation, fixture-driven harness, compiled structural/opaque acceptance ring, payload
golden, mutation suite, and benchmark budget all pass. ADR 0012 is Accepted and ADR 0004 owns the
new conformance gates. The user approved the shared `0.4.0.0` preparation, all five publishable
packages and their changelogs/bounds are aligned, and `nix fmt`, `just verify`, and
`nix flake check` pass. EP-7 is therefore Complete. Tags, pushes, the final Hackage dependency
audit, and publication remain deferred to the initiative release train.

EP-8 completed the soundness-preserving authoring layer. Scaffolding emits compiling create-once
binding skeletons grouped by owner, persists granular obligations, skips hand-owned files, and
reports exactly what a later shape change adds. Exact `GHC.Generics` derivation removes nominal
boilerplate only when constructor names/order, selector names/order, arity, and field types match;
four compile-fail fixtures prove the refusal cases. `check --explain-bindings` now reports every
binding, fixture, and register-initial obligation with use paths and binding-version provenance.
The landed conformance bindings fell from 56 to 30 semantic lines, goldens stayed unchanged, all
four structural mutations turn red, and `just verify` passes. ADR 0012 records these as downstream
conveniences under its existing single-authority and total-binding rules; EP-8 is Complete.


---

Revision note: Revalidated the initiative against Keiki 0.4.0.0 and current Keiro DSL/runtime
boundaries; adopted the released projection API, generalized consumer-facing contracts, and
tightened binding, snapshot, compatibility, and derivation soundness, 2026-07-28.

Revision note: Completed the consumer-maintainability pass by splitting shape definitions per
mapped declaration, making projection paths unambiguous JSON Pointers, restricting generic
derivation to what its public signature can express, and replacing an unexecutable comparison CLI
with a consumer-compiled runner, 2026-07-28.

Revision note: Tightened unrelated DSL contracts as part of the same review: EP-5 is now a hard
dependency of the mapped differ, compatibility JSON covers all six surfaces with rollout arrays,
resolved AST constructors are distinct from parser constructors, scaffold mapping rows are
unambiguous JSON, and comparison reports carry structured differences and explicit provenance,
2026-07-28.

Revision note: Closed EP-7 after the approved shared `0.4.0.0` release preparation and passing
release gates; EP-8 and EP-9 are now hard-dependency-ready while publication remains deferred,
2026-07-28.

Revision note: Closed EP-8 after landing owner-grouped create-once binding skeletons, granular
new-hole reporting, exact nominal derivation, binding explanations, and passing full verification;
EP-9 may now consume its fixture conveniences, 2026-07-28.
