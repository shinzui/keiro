---
id: 179
slug: generate-one-human-readable-authoritative-keiro-transducer
title: "Generate one human-readable authoritative Keiro transducer"
kind: exec-plan
created_at: 2026-08-02T03:36:01Z
intention: "intention_01kz08h277e8majwtw3v2pmmhw"
mori_publish: true
---

# Generate one human-readable authoritative Keiro transducer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A generated aggregate must have one obvious, human-readable behavioral artifact:
`Generated.<Context>.<Aggregate>.Transducer`.  After this change, the transition
body contains the checked guard and register expressions directly, written with
Keiki's infix expression operators and source-shaped field names.  The separate
generated `Expressions` module and its long, mechanically named forwarding
functions no longer exist.  A human can read the command decision, state changes,
emitted event, and next state in one continuous block without comments explaining
opaque constructor code.

This is a representation change, not a relaxation of authority.  The same checked
DSL scalar-expression tree is resolved once for generation and printed as the same
Keiki predicate and term tree.  Generated-versus-Hole ownership, compiler type checking, symbolic
verification, forward/replay equality, fold fingerprints, diff and replay-impact
classification, structural projection witnesses, and scaffold firewall behavior
must remain equal.  The plan cannot complete until an explicit before/after
guarantee ledger proves each of those claims.

Once the coordinated Keiki `0.8` renderer is released, the Jitsurei diagrams will
render the same guards, right-hand-side assignments, and literal values by default.
The code-readability milestone is intentionally independent of that release so the
module split can be fixed without waiting on diagram infrastructure.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 0: capture and automate the pre-change guarantee ledger for the
  canonical scalar-expression fixture.
- [ ] Milestone 1: replace raw Keiki-constructor emission with a precedence-aware,
  human-readable Haskell expression renderer.
- [ ] Milestone 2: inline checked guard and write terms into `Transducer`, remove
  generated `Expressions`, and provide a safe migration for existing scaffolds.
- [ ] Milestone 3: prove every authority, typing, replay, fingerprint, diff,
  symbolic, ownership, and scaffold guarantee against the baseline and amend ADRs.
- [ ] Milestone 4: adopt released Keiki `0.8`, make committed diagrams semantic,
  and refresh generated documentation.
- [ ] Milestone 5: prepare and, with explicit operator approval, publish the
  coordinated Keiro `0.9.0.0` breaking release and verify its tags and registry
  artifacts.
- [x] 2026-08-01: Revalidated the plan against the current Keiro and Mori-resolved
  Keiki sources, corrected the canonical fixture, made stale-file migration
  evidence honest, pinned exact operator-tree preservation, and verified the two
  focused pre-change suites are green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: the `Expressions`/`Transducer` split was introduced by checked-in
  ExecPlan 161 and commit `13d4df63d76a845eb1f6d5b6e6810d9dae86f5eb`
  (`feat(dsl): generate authoritative scalar transducers`, 2026-07-31).  MasterPlan
  28 coordinates the modular source-aware frontend but does not make a separate
  `Expressions` module a replay invariant.
  Evidence: `docs/plans/161-add-authoritative-typed-scalar-aggregate-expressions.md`,
  `docs/masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md`,
  and `git show -s 13d4df6`.
- Discovery: the only production consumer of a generated `Expressions` module in
  this repository is its sibling generated `Transducer`.  Other occurrences are
  generation tests, conformance fixtures, documentation, and Cabal module lists.
  The module boundary is therefore generated API surface rather than an
  independent runtime component.
  Evidence: repository-scoped `rg` over `keiro-dsl`, `jitsurei`, and `docs`.
- Discovery: replay safety does not depend on that module boundary.
  `Keiro.Dsl.FoldFingerprint.transitionSegment` hashes the canonical checked guard,
  writes, emits, target, and ownership independently of emitted Haskell modules;
  forward execution and replay consume the assembled `SymTransducer`.
  Evidence: `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`,
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, and ADR 0003.
- Discovery: Keiki `0.7` already exposes structural infix aliases `.+`, `.-`,
  `.*`, `.==`, `./=`, `.<`, `.<=`, `.>`, `.>=`, `.&&`, and `.||`.  They construct
  the same `TArith`, `PEq`, `PCmp`, `PAnd`, and `POr` nodes as the unreadable raw
  constructors.  Code readability does not need to wait for Keiki `0.8`.
  Evidence: `mori://shinzui/keiki/packages/keiki` and
  `src/Keiki/Core.hs` in the Mori-resolved source tree.
- Discovery: nested structural and nominal comparisons deliberately use typed
  projection witnesses.  Removing those witnesses would weaken path-exactness or
  canonical wire equality.  Readability must give the same witness application a
  business-shaped local name, not replace its semantics.
  Evidence: `renderNominalProjectionTerm` and
  `renderStructuralProjectionTerm` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, plus
  Keiki's `regProj` and `inpProj` contracts.
- Discovery: scaffold reconciliation reports stale generated files but does not
  delete them.  Removing `Expressions` from the desired module set therefore needs
  an explicit evidence-checked migration; silently leaving the old file and its
  hand-maintained Cabal entry would create a misleading second artifact.
  Evidence: `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and scaffold tests in
  `keiro-dsl/test/Main.hs`.
- Discovery: a scaffold record remembers only the old module kind and path.  It
  stores neither generated bytes nor a content hash, so the presence of the
  generated banner proves provenance but cannot prove that a stale file was never
  edited.  The current report's phrase `safe to delete` is therefore too strong.
  Evidence: `ScaffoldRecord.recFiles`, `staleAgainst`, and `renderScaffoldReport`
  in `keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` and
  `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`.
- Discovery: the scaffold-owned build manifest is Cabal-pasteable text; the tool
  does not read or edit a consumer's `.cabal` file.  The new manifest can omit the
  obsolete module, but the migration must tell the operator to reconcile their
  Cabal stanza rather than claim the scaffold report found or removed that entry.
  The semantic CLI and workspace paths currently call `renderManifestForService`.
  Evidence: `keiro-dsl/src/Keiro/Dsl/Manifest.hs`,
  `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, and
  `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`.
- Discovery: the canonical compiled proof fixture is
  `keiro-dsl/test/fixtures/aggregate-scalar-expressions-v2.keiro`.
  `keiro-dsl/test/fixtures/aggregate-scalars-arithmetic.keiro` is intentionally a
  language-version-1 parser rejection and cannot materialize the generated proof
  tree named by the earlier draft.
  Evidence: the fixtures and the `scalar expressions` tests in
  `keiro-dsl/test/Main.hs`.
- Discovery: the current focused baseline is green: the `scalar expressions`
  selection passes 12 examples, and
  `keiro-dsl-conformance-aggregate-scalar-expressions` passes its complete runtime,
  replay, projection, symbolic, behavior, and snapshot assertions.
  Evidence: commands recorded in Concrete Steps, run on 2026-08-01 before this
  revision.
- Discovery: Hackage and upstream tags show the coordinated Keiro packages already
  released at `0.8.0.0`; tag `keiro-dsl-0.8.0.0` peels to commit
  `80cd51516da513d530e4631d92a5f1350a0d38d9`.  Removing a generated public module
  and raising the Keiki major bound belongs in a coordinated `0.9.0.0` release.
- Discovery: the authoritative current Keiki release is `0.7.0.0` in Hackage's
  preferred-version document and upstream tag `v0.7.0.0`, which peels to
  `7c5d433ef4455e9e626347f89cb3a416bad62e72`.  No `0.8` tag or Hackage version
  existed at this review, so Milestone 4 remains correctly gated.


## Decision Log

Record every decision made while working on the plan.

- Decision: Make the guarantee ledger a blocking milestone before changing the
  generator.
  Rationale: readability is the goal, but it cannot trade away checked-source
  authority, replayability, symbolic conservatism, or scaffold safety.  A named
  before/after proof prevents those guarantees from becoming implicit assumptions.
  Date: 2026-08-01
- Decision: Generate no aggregate `Expressions` module; inline every generated-owned
  guard and write exactly at its use site in `Transducer`.
  Rationale: a separate function with a transition-index name makes the state
  machine harder to follow and provides no independent semantic or replay boundary.
  Direct placement restores narrative locality.
  Date: 2026-08-01
- Decision: Render checked scalar expressions with Keiki's infix structural
  operators and a precedence/associativity-aware pretty-printer.
  Rationale: operator aliases build the same typed tree while making arithmetic,
  comparison, and Boolean structure readable.  Parenthesization follows Keiki's
  declared fixities and preserves the exact checked tree, including right children
  of left-associative arithmetic and left children of right-associative Boolean
  operators; algebraic equivalence is not permission to reassociate the tree.
  Date: 2026-08-01
- Decision: Import only the readable Keiki operators unqualified and keep
  constructors, literals, projections, and inspection APIs behind `K`.
  Rationale: generated expressions read naturally as infix Haskell without a broad
  unqualified import or the visually awkward syntax of qualified symbolic
  operators.
  Date: 2026-08-01
- Decision: Preserve structural and nominal projection witnesses, but expose their
  use through deterministic business-path `let` bindings immediately inside the
  owning transition.
  Rationale: witness semantics are a guarantee.  Transition-local aliases such as
  `commandLimitsMinimum` and `registerLimitsMinimum` keep exact `K.inpProj` and
  `K.regProj` plumbing adjacent, avoid exported or polymorphic helper APIs, and
  expose the source path in the guard and writes.
  Date: 2026-08-01
- Decision: Do not use prose comments as the readability mechanism.
  Rationale: comments can drift from executable code.  Acceptance is based on the
  guard and assignments remaining understandable when non-contractual comments are
  removed from the generated module.
  Date: 2026-08-01
- Decision: Keep expression authority in the existing checked semantic graph and
  resolve each aggregate's generated behavior once before import analysis and
  Haskell emission.
  Rationale: a display tree or separately maintained Haskell template would create
  a second truth, while the current generator redundantly resolves expressions for
  import discovery and again for definitions.  The readable emitter and its import
  analysis must consume one shared resolved-behavior value containing
  `TypedScalarExpr` nodes.
  Date: 2026-08-01
- Decision: Never call a stale generated file safe to delete from record and banner
  evidence alone.
  Rationale: the v1 scaffold record has no content hash.  A missing exact banner is
  an immediate preserve-and-review signal; a present banner proves only generated
  provenance.  Deletion additionally requires a clean version-control diff or a
  byte comparison with Keiro `0.8` output regenerated from the same source in a
  disposable directory.  Uncertain files remain untouched.
  Date: 2026-08-01
- Decision: Let the regenerated scaffold manifest, not Cabal-file inspection,
  describe the post-migration module set.
  Rationale: keiro-dsl owns the manifest but not arbitrary consumer `.cabal`
  files.  The migration can prove the manifest omits `Expressions` and instruct a
  manual stanza reconciliation without widening filesystem authority.
  Date: 2026-08-01
- Decision: Treat removal of `Expressions` as an intentional breaking generated-API
  change and ship it on Keiro `0.9.0.0` with migration guidance.
  Rationale: repository search finds no production import beyond generated code,
  but external consumers may import a generated public module.  The release must
  state the break rather than pretend it is source-compatible.
  Date: 2026-08-01
- Decision: Make the Keiki `0.8` dependency a final diagram milestone, not a
  prerequisite for readable generated Haskell.
  Rationale: the operator surface exists in `0.7`; separating the milestones keeps
  the root code fix independently deliverable while still completing the human
  diagram outcome.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The 2026-08-01 soundness review found the core design feasible on released Keiki
`0.7` and left implementation at Milestone 0.  It corrected one wrong fixture and
two unsafe migration assumptions before code work began.  No product behavior or
generated output has changed yet; later milestone outcomes belong below this
planning-review note.


## Context and Orientation

A `.keiro` file is a service specification written in Keiro's domain-specific
language (DSL).  Language version 2 can declare a generated-owned aggregate
transition, whose guard and register writes must be emitted from the checked DSL,
or a Hole-owned transition, whose behavior is a deliberate hand-written escape
hatch in a create-once Haskell module.  Cabal is the Haskell build tool and its
package file carries the module list a consumer compiles.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` turns a validated aggregate into generated
Haskell modules.  For a language-version-2 generated-owned transition it currently
emits one typed function per guard and register write into
`Generated.<Context>.<Aggregate>.Expressions`, then emits a `Transducer` whose
transition body calls names such as `transition1OpenAdjustWriteBalance`.  The
functions use raw forms such as `K.PAnd`, `K.PCmp`, `K.tadd`, and `K.tmul`.  This is
type-safe but obscures the business expression and separates it from the command,
emit, and target state.

`TypedScalarExpr` is the checked expression tree.  Today
`resolvedGeneratedExpressions` derives a flat list for import analysis, while
`emitTransitionExpressions` separately calls `resolveGuardExpr` and
`resolveWriteExpr` again for definitions.  The new resolved-behavior inventory
replaces that duplication and is the sole value consumed by imports and rendering.
`renderKeikiPredicate`, `renderComparisonTerm`, `renderNominalProjectionTerm`,
`renderKeikiTerm`, and `renderStructuralProjectionTerm` are the current raw Haskell
emitters.  `emitExpressions` owns expression-specific pragmas and imports;
`emitGeneratedTransducer` assembles the runtime machine.  The work moves required
imports and typed projection plumbing into the latter and deletes the former path.

A projection witness is a typed Keiki value that ties a source-visible nested
field path to its concrete getter and symbolic identity.  `K.regProj` reads that
path from an aggregate register and `K.inpProj` reads it from the matched command.
The renderer may rename their local use but may not replace the witness or getter.

The canonical proof fixture is
`keiro-dsl/test/fixtures/aggregate-scalar-expressions-v2.keiro`, whose checked
tree is materialized under
`keiro-dsl/test/conformance-scalar-expressions/Generated/AggregateScalarExpressions/`.
Its guard exercises nested Boolean expressions, arithmetic, ordering, ordinary and
nominal equality, time, IDs, enums, structural projections, and every supported
scalar write.  `keiro-dsl/test/aggregate-scalar-expression-mutation-test.sh`
mutates generated behavior and the source fixture to prove regeneration and
firewall behavior.  `keiro-dsl/test/Main.hs` contains generation, fingerprint,
ownership, and stale-module assertions.

The aggregate fold surface is the canonical checked description of transition
behavior used by diff and replay-impact analysis.  Its fold fingerprint is the
short deterministic token included in snapshot compatibility so changed behavior
does not reuse state cached under an older fold.

The guarantee ledger in this plan uses these meanings:

- Source authority: parsing, validation, capability admission, and
  `TypedScalarExpr` resolution remain the only way generated-owned behavior enters
  the transducer.
- Type authority: generated Haskell still compiles for every admitted scalar,
  nominal, structural projection, and operator combination; rejected expressions
  remain rejected with the same diagnostic.
- Ownership authority: generated transitions necessarily execute checked guards
  and writes; Hole-owned transitions and fold-version obligations remain exactly
  where they were.
- Runtime/replay equality: detailed forward results, emitted wire events, decoded
  replay, terminal state, and register file are unchanged.
- Proof conservatism: Keiki sees the same structural nodes, so verified,
  counterexample, and unverified outcomes do not become more optimistic.
- Evolution identity: aggregate fold surface and fingerprint bytes, diff,
  compatibility vector, and replay-impact classification are unchanged by module
  layout and formatting alone.
- Scaffold safety: generated files remain replaceable only through the generated
  firewall; create-once Hole files are not overwritten; obsolete generated output
  is never deleted by the scaffolder and is removed by an operator only after
  provenance plus unchanged-byte evidence is established.

The generated firewall is `firewallBreaches` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`.  It scans generated modules and rejects
hand-written Keiki symbolic operators everywhere except the generated module that
is explicitly responsible for executable aggregate behavior.

Relevant durable decisions are:

- [ADR 0003](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md)
  makes the aggregate fold fingerprint part of snapshot compatibility.  This plan
  must prove the fingerprint byte-for-byte unchanged for the same checked spec.
- [ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
  makes checked structural paths and projection witnesses authoritative.  Readable
  naming may not bypass or duplicate those witnesses.  Its description of lowering
  through a separate generated `Expressions` module must be amended.
- [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  requires attributable, non-destructive scaffold migration.  This plan retains
  that rule and corrects stale-generated reporting so record or banner evidence is
  not overstated as proof of unchanged bytes.
- [ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  keeps generated output downstream of the checked, location-independent semantic
  graph.  The renderer consumes that graph and never uses surface text or spans as
  a second semantic input.
- [ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  owns generated-versus-Hole behavior.  Its invariant remains valid, but its
  description of separate `Expressions` and `Transducer` modules must be amended
  to describe one readable generated transducer.

Checked-in Plan 161 is the predecessor that added the split.  This plan supersedes
its output-layout decision, not its typed-expression authority.  The diagram and
literal-rendering dependency is
`mori://shinzui/keiki/plans/84-preserve-readable-business-semantics-in-keiki-transducers-and-diagrams`.


## Plan of Work

Milestone 0 creates executable baseline evidence before editing the generator.
Extend focused tests around the canonical scalar-expression fixture to pin the
accepted/rejected expression matrix, generated-versus-Hole ownership, detailed
forward result, emitted event payload, replayed state/registers, symbolic
verification classification, aggregate fold surface and fingerprint bytes, diff
and replay-impact classification, generated-firewall decisions, and stale-module
reporting.  Manifest assertions use `renderManifestForService`, matching the
semantic CLI and workspace paths.  While Keiki remains at `0.7`, also pin
`Keiki.Render.Pretty.prettyPred` and `prettyUpdate` for the canonical generated
edge; those traversals expose constructor nesting and therefore catch accidental
reassociation even though ordinary literal values still appear as `<lit>`.  Put
pure generator, rejection, fingerprint, diff, replay-impact, manifest, and
stale-report assertions in `keiro-dsl/test/Main.hs`; keep compiled
forward/replay and symbolic assertions in
`keiro-dsl/test/conformance-scalar-expressions/Main.hs`; and keep mutation
sentinels in `keiro-dsl/test/aggregate-scalar-expression-mutation-test.sh`.
Record the current canonical fingerprint (`d0897c163c958108` at plan creation) as
fixture evidence, but compute semantic expectations from the checked spec rather
than blessing arbitrary generated text.  Run this baseline on the unchanged
generator.  No later milestone starts until it passes.

Milestone 1 first replaces repeated generator resolution with one internal
resolved-behavior inventory per aggregate.  It contains each generated-owned
transition's already checked guard and ordered writes as `TypedScalarExpr` values;
import analysis and Haskell emission consume that same inventory.  Fingerprinting,
diff, and replay-impact continue to consume the checked semantic graph
independently, which is how this plan proves presentation changes do not alter
evolution identity.

Then introduce a precedence-aware Haskell renderer in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (or a small internal module if extraction
materially improves testing).  Match Keiki `0.7` exactly: atoms and function
application bind tightest; `.*` is `infixl 7`; `.+` and `.-` are `infixl 6`;
`.==`, `./=`, `.<`, `.<=`, `.>`, and `.>=` are non-associative `infix 4`; `.&&`
is `infixr 3`; and `.||` is `infixr 2`.  Parenthesize a child whenever omitting
parentheses would make Haskell parse a different tree.  In particular, preserve a
same-precedence right child of left-associative arithmetic and a same-precedence
left child of right-associative Boolean operators even when the operator is
mathematically associative.  Render negation as `K.pnot (...)`.

Import the infix operators through an explicit unqualified `Keiki.Core` import and
continue to render literals and projection plumbing as `K.lit`, `K.regProj`, and
`K.inpProj`.  Roots remain direct `d.field` and `B.reg @"field"` terms.  Add
byte-pinned expected-output cases for every operator, both child positions at equal precedence,
mixed precedence, negative literals, nominal comparisons, and nested paths.  The
committed conformance modules are the compile test for representative output; do
not add a second Haskell parser dependency merely to reparse strings.

A normal generated transition should have this shape, adjusted to the actual
fixture types and established formatter:

```haskell
B.onCmd inCtorAdjust $ \d -> B.do
  B.requireGuard $
    ( d.balance .+ B.reg @"balance" .>= K.lit (-100 :: Integer)
        .&& B.reg @"reserved" .+ d.requested .<= B.reg @"capacity"
    )
      .&& d.active .== K.lit False
  B.slot @"balance" =:
    B.reg @"balance" .+ d.balance .* K.lit (2 :: Integer)
  B.slot @"active" =: K.lit True
  B.emit wireAdjusted (AdjustedTermFields { balance = d.balance })
  B.goto ScalarAccountReviewed
```

The exact fixture has more guard clauses, writes, and output fields; the point is
that they remain adjacent.  The parentheses above preserve a left-nested checked
conjunction even though `.&&` is right-associative Haskell.  When the fixture uses
`cmd.limits.minimum` or `reg.limits.minimum`, a transition-local `let` binds the
corresponding witness applications under those business-shaped names immediately
before the guard.  No helper named after a transition guard or write may replace
the inline expression.

Milestone 2 changes scaffold structure.  Fold the import and pragma analysis from
`emitExpressions` into `emitGeneratedTransducer`, including `Text`, `Natural`,
time constructors, `Data.KindID`, consumer modules, generated nominals, nominal
projections, and structural projections only when used.  Move the
`OverloadedLabels` pragma and `Keiki.Generics (RegFieldsOf)` import whenever a
projection index requires them.  Merge imports deterministically and retain
warning-free output.  Immediately inside each generated-owned `B.onCmd` lambda,
emit one `let` group for projection terms used by that transition.  Derive names
from provenance plus the JSON-pointer path: for example,
`commandLimitsMinimum` and `registerLimitsMinimum`.  Scope makes command names from
other transitions irrelevant; within one transition, reject or deterministically
suffix any collision produced by Haskell-name normalization.  Each binding is
exactly the old `K.regProj` or `K.inpProj` expression, and repeated uses share the
binding.  It must never contain a whole guard or register write.

Remove `expressionFunctionNames`, `emitExpressions`, transition guard/write
definition emission, the `Expressions` module from `scaffoldAggregateForService`,
its import from `Transducer`, and the `/Expressions.hs` generated-firewall
exception.  Leave `/Transducer.hs` generated and replaceable.  Regenerate all
checked conformance trees, delete the repository-owned committed `Expressions.hs`
fixtures after confirming their expected banner and clean Git provenance, and
remove their Cabal module-list entries.  Update `keiro-dsl/test/Main.hs`, the
mutation script, `docs/user/api-reference.md`,
`docs/user/typed-spec-toolchain.md`, and
`docs/guides/dsl-guarantees-and-hand-written-services.md`.

Existing consumer scaffolds need a safe migration because reconciliation does not
delete stale files.  Keep reporting the obsolete `Expressions.hs`, but change the
general stale-generated messages in `renderScaffoldReport` and
`renderWorkspaceScaffoldReport` so neither says record evidence alone makes
deletion safe.  Extend `StaleModule` with exact-banner evidence populated by the
shared IO function `staleAgainst`, and pin both report paths in
`keiro-dsl/test/Main.hs`.  A missing exact keiro-dsl banner is an explicit
preserve-and-review result.  A present banner proves generated
provenance, not unchanged bytes: documentation permits deletion only after a clean
version-control comparison or a byte comparison against Keiro `0.8` output
regenerated from the same source in a disposable directory.  When neither is
available, preserve the file.  The regenerated `keiro-dsl-manifest.<context>.txt`
or workspace manifest must omit the module; documentation tells the operator to
reconcile that authoritative list with the consuming Cabal stanza manually.  Do
not add automatic deletion, Cabal editing, or broader overwrite permissions.

Milestone 3 reruns the full guarantee ledger.  Every item from Milestone 0 must
either match byte-for-byte or, for expected Haskell/diagram presentation changes,
have an explicit new expected output plus an unchanged semantic proof.  Add a test that
changing only the emitter/module layout leaves `aggregateFoldSurface` and
`aggregateFoldFingerprint` unchanged, while changing a checked guard or write
still changes them.  The Keiki `0.7` `prettyPred` and `prettyUpdate` baselines must
also remain byte-identical through this milestone, proving the compiled aliases
reconstruct the old constructor nesting.  The mutation script must mutate inline
`Transducer` behavior, prove scaffold regeneration repairs it, prove a source
mutation changes runtime and fingerprint as before, and prove Hole
ownership/firewall behavior remains unchanged.  Amend ADRs 0012, 0015, and 0017,
plus all three current module-layout documents
named in Milestone 2.  ADR 0016 remains valid without textual change because the
semantic graph still owns generation.  Run strict OKF validation so ADR metadata
and log entries remain canonical.

Milestone 4 starts only after
`mori://shinzui/keiki/plans/84-preserve-readable-business-semantics-in-keiki-transducers-and-diagrams`
has published Keiki `0.8.0.0` to Hackage and an upstream tag.  Verify both sources,
then raise every `keiro-dsl` Keiki bound from `>=0.7 && <0.8` to
`>=0.8 && <0.9`.  Search the whole repository for direct `TLit` construction,
exhaustive `Term` matches, and Mermaid option assembly.  Existing literals must
retain readable `K.lit` when their type has the already required `Show` evidence;
use `K.opaqueLit` only for an intentional redaction or a genuinely non-`Show`
value, and handle `TOpaqueLit` in any exhaustive match.  Update
`jitsurei/src/Jitsurei/Diagrams.hs` to use the new readable primary renderer
(without reassembling opt-in flags locally), add a scalar aggregate diagram whose
guard, assignments, literal values, event, and target are
visible, and regenerate the marked blocks through `jitsurei-diagrams -- --write`.
Review the rendered Mermaid text as a behavioral artifact, then require
`-- --check` in the normal gate.  `docs/why-keiro.md` and diagram guidance must no
longer claim comprehensibility while showing topology-only output.

Milestone 5 prepares the coordinated breaking release.  Re-verify Hackage and tags
for both Keiki and Keiro, set the repository's shared coordinated version to
`0.9.0.0`, update internal bounds and changelogs, build source distributions, and
follow `agents/skills/release/SKILL.md`.  Publishing requires separate explicit
operator approval.  After publication, verify every Keiro package's Hackage entry
and upstream tag and record the peeled commit in this living plan.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro` unless stated otherwise.

Refresh local dependency metadata and authoritative release evidence before
selecting bounds:

```bash
mori registry list
mori registry search keiki
mori registry show shinzui/keiro --full
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
mori registry dependents shinzui/keiki --packages
mori path mori://shinzui/keiki/plans/84-preserve-readable-business-semantics-in-keiki-transducers-and-diagrams
curl -fsSL https://hackage.haskell.org/package/keiro-dsl/preferred.json
curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
git ls-remote --tags https://github.com/shinzui/keiro.git
git ls-remote --tags https://github.com/shinzui/keiki.git
```

At plan creation, the expected Keiro evidence is `0.8.0.0` and
`keiro-dsl-0.8.0.0`; Keiki is `0.7.0.0` until the companion plan publishes
`0.8.0.0`.  Do not raise the Cabal bound based only on a local checkout.

Establish and repeatedly run the focused guarantee gates:

```bash
cabal test keiro-dsl-test --test-show-details=direct \
  --test-option=--match --test-option='scalar expressions'
cabal test keiro-dsl-conformance-aggregate-scalar-expressions \
  --test-show-details=direct
bash keiro-dsl/test/aggregate-scalar-expression-mutation-test.sh
```

Inspect the generated readability and forbidden split with repository-scoped
searches:

```bash
sed -n '1,260p' \
  keiro-dsl/test/conformance-scalar-expressions/Generated/AggregateScalarExpressions/ScalarAccount/Transducer.hs
rg -n 'K\.(PAnd|POr|PNot|PCmp|PEq|tadd|tsub|tmul)|Expressions\.' \
  keiro-dsl/test --glob '**/Generated/**/Transducer.hs'
rg -n 'Expressions\.hs|\.Expressions\b|emitExpressions|expressionFunctionNames' \
  keiro-dsl/src keiro-dsl/test keiro-dsl/keiro-dsl.cabal
rg -n 'Generated\.<Context>\.<Aggregate>\.Expressions|generated `Expressions`' \
  docs/user docs/guides docs/why-keiro.md
```

The transducer search must return no raw expression constructors or
`Expressions.` calls.  The broader split search may retain explicitly labelled
migration assertions in `keiro-dsl/test/Main.hs`, but it must find no current
generator function, committed generated fixture, or Cabal module entry.  The
documentation search may retain an explicitly labelled `0.8` migration note, but
it must find no statement that `Expressions` is part of the current layout.

After the Keiki dependency milestone, regenerate and check diagrams:

```bash
rg -n '\bTLit\b|\bTOpaqueLit\b|opaqueLit|toMermaid|defaultMermaidOptions' \
  . --glob '*.hs' --glob '!dist-newstyle/**'
cabal run jitsurei:exe:jitsurei-diagrams -- --write
git diff -- docs jitsurei
cabal run jitsurei:exe:jitsurei-diagrams -- --check
```

Run full repository validation:

```bash
cabal build all
cabal test all --test-show-details=direct
just adr-validate
nix flake check
cabal sdist all
git diff --check
```

The expected final transcript has all Cabal test suites passing, diagram check
reporting no stale blocks, strict ADR validation succeeding, no failed Nix checks,
and source distributions for the coordinated packages.  Before publishing, read
and follow `agents/skills/release/SKILL.md`; this ExecPlan does not itself grant
release authority.


## Validation and Acceptance

The human outcome is accepted when the canonical `Transducer.hs`, read from the
`B.onCmd` line through `B.goto`, communicates the guard, every register assignment,
emitted payload, and target state without opening another behavior module.  Its
expressions use normal precedence, minimal semantics-preserving parentheses, and
business-shaped projection names.  "Minimal" here means no parentheses beyond
those required to make Haskell reconstruct the exact checked tree; the renderer
does not reassociate expressions under algebraic laws.  Removing non-contractual
comments from a copy must not make that transition unintelligible.  No generated
`Expressions.hs` or `Expressions` import remains in a clean scaffold.

The guarantee ledger is accepted only when all of these proofs pass:

- Parse/check/lower tests accept every previously admitted canonical scalar form
  and reject every previous negative fixture with the same diagnostic code.
- Every generated guard and write, and all import analysis for it, comes from one
  shared resolved-behavior inventory of `TypedScalarExpr`; no repeated resolution,
  untyped textual expression, or second display tree can enter code generation.
- The canonical fixture compiles with all scalar, nominal, time, and structural
  projection types.  Operator sugar reconstructs the same Keiki constructor tree,
  including associativity, adds no opaque `TApp` fallback, and retains the pinned
  Keiki `0.7` `prettyPred`/`prettyUpdate` tree renderings through Milestone 3.
- Generated-owned transitions necessarily execute their checked guard and writes.
  Hole-owned transitions, Hole fold-version requirements, and
  `BehaviorOwnership`/verification labels are unchanged.
- Detailed forward execution returns the same accept/reject result, state,
  register values, and emitted event payload.  Encoding and replaying those events
  returns the same final state and registers.
- Symbolic verification returns the same verified/counterexample/unverified class
  for every canonical transition; readability must not make a proof gate more
  optimistic.
- The unchanged fixture retains aggregate fingerprint `d0897c163c958108` and the
  same fold-surface segments.  Guard/write mutations still alter the fingerprint,
  snapshot compatibility discriminator, diff vector, and replay-impact result.
- Generated firewall and create-once Hole preservation retain their pre-change
  behavior.  Stale reporting still deletes nothing, no longer calls a
  record-attributed generated file safe to delete, and explicitly distinguishes a
  missing banner from generated provenance whose unchanged bytes remain unknown.
- A regenerated manifest omits every `Expressions` module.  Tests state plainly
  that keiro-dsl does not inspect or edit a consuming Cabal stanza.
- Scaffold output is idempotent: a second run produces no diff and does not
  recreate the obsolete module.

The diagram outcome is accepted when a committed scalar aggregate Mermaid block
shows the same readable guard and complete assignments, including ordinary literal
values, plus its event constructor and target state; it passes Keiki validation and
`jitsurei-diagrams -- --check`.  Keiki's explicit topology renderer must still
reproduce legacy compact output for consumers that request it.

Finally, `cabal test all --test-show-details=direct`, `just adr-validate`,
`nix flake check`, and `cabal sdist all` must pass, and Hackage plus upstream tags
must independently confirm the intended `0.9.0.0` release before completion is
claimed.


## Idempotence and Recovery

Renderer and scaffold generation must be deterministic.  Regenerating checked
fixtures, writing diagram blocks, and running all test commands are safe to repeat.
Review generated diffs before accepting them; never update an expected-output
fixture solely because a test failed.

Repository fixture cleanup may delete only tracked files at exact expected
`Expressions.hs` paths after confirming both the keiro-dsl generated banner and a
clean pre-edit Git diff.  For a consumer workspace, the banner is necessary but
not sufficient: also compare against version control or Keiro `0.8` output
regenerated from the same source.  Preserve anything missing that evidence.  Use
the new manifest to reconcile the exact Cabal module name by hand.  Do not
glob-delete generated directories.

Milestones 1 through 3 can be rolled back as source changes without changing
persisted events or snapshots because the guarantee ledger requires identical
runtime and fingerprint behavior.  If any ledger item differs unexpectedly, stop,
record the discrepancy in Surprises & Discoveries, and restore the last passing
milestone before proceeding; do not waive it as a formatting consequence.

Package publication is irreversible.  Build and inspect source distributions,
obtain release approval, and publish only after the dependency tag/Hackage checks
and full gates pass.  If publication partially succeeds, do not reuse a released
version; update this plan with the external state and follow the release skill's
recovery instructions.


## Interfaces and Dependencies

`Keiro.Dsl.Scaffold` retains the existing public scaffold interface.  Internally it
must have one resolved generated-behavior inventory and one precedence-aware
renderer over its checked expression tree.  Exact helper names may follow module
conventions, but their responsibilities must correspond to:

```haskell
data ResolvedGeneratedTransition = ResolvedGeneratedTransition
  { resolvedTransitionIndex :: Int
  , resolvedTransition :: Transition
  , resolvedGuard :: Maybe TypedScalarExpr
  , resolvedWrites :: [(Name, TypedScalarExpr)]
  }

resolvedGeneratedBehavior :: Agg -> [ResolvedGeneratedTransition]

data HaskellPrecedence
  = PrecOr
  | PrecAnd
  | PrecCompare
  | PrecAdd
  | PrecMultiply
  | PrecAtom

renderKeikiPredicateReadable
  :: Agg -> Transition -> TypedScalarExpr -> Text

renderKeikiTermReadable
  :: Agg -> Transition -> TypedScalarExpr -> Text
```

Import analysis and transition emission receive `resolvedGeneratedBehavior`; they
must not call `resolveGuardExpr` or `resolveWriteExpr` again.  The renderer also
tracks parent precedence, child side, and parent associativity, or uses an
equivalent document algebra, so every equal-precedence tree is parenthesized
correctly.  These functions print existing `TypedScalarExpr`; they do not parse
strings or define semantics.

`Keiro.Dsl.ScaffoldRun` keeps `staleAgainst` as the one filesystem inspection path
used by single-file and workspace scaffolds, but makes its limited evidence
explicit:

```haskell
data StaleGeneratedEvidence
  = ExactGeneratedBannerPresent
  | ExactGeneratedBannerMissing

data StaleModule = StaleModule
  { staleKind :: ModuleKind
  , stalePath :: FilePath
  , staleGeneratedEvidence :: Maybe StaleGeneratedEvidence
  }
```

`HoleStub` rows carry `Nothing`.  Generated rows compare a complete line with
`generatedBanner`; `ExactGeneratedBannerPresent` must be rendered as provenance
only, never as unchanged-byte or safe-deletion evidence.

For every generated-owned aggregate, the final module interface is:

```haskell
module Generated.Context.Aggregate.Transducer
  ( aggregateTransducer
  , aggregateFoldFingerprint
  , BehaviorOwnership (..)
  , aggregatePredicateVerifications
  ) where
```

There is no `Generated.Context.Aggregate.Expressions` module or corresponding
export list.  Required structural/nominal projection bindings are private to
`Transducer` and build the same `K.regProj`/`K.inpProj` terms as before.

Keiki has the canonical package URI `mori://shinzui/keiki/packages/keiki`.

Milestones 0 through 3 remain within the released `>=0.7 && <0.8` API.
Milestones 4 and 5 depend on
`mori://shinzui/keiki/plans/84-preserve-readable-business-semantics-in-keiki-transducers-and-diagrams`
and set the released bound to `>=0.8 && <0.9` only after authoritative registry and
tag verification.

The Keiro package has the canonical URI
`mori://shinzui/keiro/packages/keiro-dsl`.

Removal of its generated `Expressions` surface, the additive evidence field on the
exported `StaleModule` record, and adoption of Keiki `0.8` are declared breaking
changes in the coordinated Keiro `0.9.0.0` changelog and migration guide.


## Revision Note

2026-08-01: Revalidated the plan against current Keiro sources, relevant ADRs,
Mori-resolved Keiki `0.7` sources and companion plan 84, Hackage preferred
versions, and upstream release tags.  Corrected the canonical fixture, required a
single resolved generator inventory and exact fixity-aware tree preservation,
made projection aliases transition-local, added the missing pragma/import and
Keiki `0.8` migration audits, corrected ADR and documentation scope, replaced
unsafe stale-file and Cabal-ownership assumptions with evidence the current
scaffold format can actually provide, converted every command block to a tagged
fence, and recorded the passing focused baseline.  These changes make the plan
self-contained and executable without weakening its authority guarantees.
