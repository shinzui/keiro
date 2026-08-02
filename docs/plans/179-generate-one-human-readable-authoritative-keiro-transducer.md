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
DSL scalar-expression tree is lowered once into the same Keiki predicate and term
constructors.  Generated-versus-Hole ownership, compiler type checking, symbolic
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
  an explicit, banner-checked migration; silently leaving the old file and Cabal
  entry would create a misleading second artifact.
  Evidence: `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and scaffold tests in
  `keiro-dsl/test/Main.hs`.
- Discovery: Hackage and upstream tags show the coordinated Keiro packages already
  released at `0.8.0.0`; tag `keiro-dsl-0.8.0.0` peels to commit
  `80cd51516da513d530e4631d92a5f1350a0d38d9`.  Removing a generated public module
  and raising the Keiki major bound belongs in a coordinated `0.9.0.0` release.


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
  Rationale: operator aliases build the same typed AST while making arithmetic,
  comparison, and Boolean structure readable.  Blind textual replacement would
  mis-parenthesize subtraction and mixed Boolean expressions.
  Date: 2026-08-01
- Decision: Preserve structural and nominal projection witnesses, but expose their
  use through deterministic business-path names in the same `Transducer` module.
  Rationale: witness semantics are a guarantee.  Local source-shaped names isolate
  type plumbing without hiding business behavior in another module.
  Date: 2026-08-01
- Decision: Do not use prose comments as the readability mechanism.
  Rationale: comments can drift from executable code.  Acceptance is based on the
  guard and assignments remaining understandable when non-contractual comments are
  removed from the generated module.
  Date: 2026-08-01
- Decision: Keep expression authority in the existing checked semantic graph and
  retain one lowering path.
  Rationale: a display AST or separately maintained Haskell template would create
  a second truth.  The readable emitter is only a printer for `TypedScalarExpr`.
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

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` turns a validated aggregate into generated
Haskell modules.  For a language-version-2 generated-owned transition it currently
emits one typed function per guard and register write into
`Generated.<Context>.<Aggregate>.Expressions`, then emits a `Transducer` whose
transition body calls names such as `transition1OpenAdjustWriteBalance`.  The
functions use raw forms such as `K.PAnd`, `K.PCmp`, `K.tadd`, and `K.tmul`.  This is
type-safe but obscures the business expression and separates it from the command,
emit, and target state.

`TypedScalarExpr` is the checked expression tree.  `resolvedGeneratedExpressions`
derives all generated-owned guards and writes from that tree.  The new renderer
must consume this same value.  `renderKeikiPredicate`, `renderComparisonTerm`,
`renderNominalProjectionTerm`, `renderKeikiTerm`, and
`renderStructuralProjectionTerm` are the current raw Haskell emitters.
`emitExpressions` owns expression-specific pragmas and imports;
`emitGeneratedTransducer` assembles the runtime machine.  The work moves required
imports and typed projection plumbing into the latter and deletes the former path.

The canonical proof fixture is
`keiro-dsl/test/fixtures/aggregate-scalars-arithmetic.keiro`, whose checked tree is
materialized under
`keiro-dsl/test/conformance-scalar-expressions/Generated/AggregateScalarExpressions/`.
Its guard exercises nested Boolean expressions, arithmetic, ordering, ordinary and
nominal equality, time, IDs, enums, structural projections, and every supported
scalar write.  `keiro-dsl/test/aggregate-scalar-expression-mutation-test.sh`
mutates generated behavior and the source fixture to prove regeneration and
firewall behavior.  `keiro-dsl/test/Main.hs` contains generation, fingerprint,
ownership, and stale-module assertions.

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
  is removed only after checking its generated banner.

Relevant durable decisions are:

- `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md`
  makes the aggregate fold fingerprint part of snapshot compatibility.  This plan
  must prove the fingerprint byte-for-byte unchanged for the same checked spec.
- `docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md`
  makes checked structural paths and projection witnesses authoritative.  Readable
  naming may not bypass or duplicate those witnesses.
- `docs/adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md`
  owns generated-versus-Hole behavior.  Its invariant remains valid, but its
  description of separate `Expressions` and `Transducer` modules must be amended
  to describe one readable generated transducer.

Checked-in Plan 161 is the predecessor that added the split.  This plan supersedes
its output-layout decision, not its typed-expression authority.  The diagram and
literal-rendering dependency has this canonical URI:

    mori://shinzui/keiki/plans/84-preserve-readable-business-semantics-in-keiki-transducers-and-diagrams


## Plan of Work

Milestone 0 creates executable baseline evidence before editing the generator.
Extend focused tests around the canonical scalar-expression fixture to pin the
accepted/rejected expression matrix, generated-versus-Hole ownership, detailed
forward result, emitted event payload, replayed state/registers, symbolic
verification classification, aggregate fold surface and fingerprint bytes, diff
and replay-impact classification, generated-firewall decisions, and stale-module
reporting.  Record the current canonical fingerprint (`d0897c163c958108` at plan
creation) as fixture evidence, but compute semantic expectations from the checked
spec rather than blessing arbitrary generated text.  Run this baseline on the
unchanged generator.  No later milestone starts until it passes.

Milestone 1 introduces a precedence-aware Haskell renderer in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (or a small internal module if extraction
materially improves testing).  Give each expression form a precedence matching
Keiki's declared fixities: atoms; multiplication; addition/subtraction;
equality/ordering; conjunction; disjunction.  Track associativity so `a - (b - c)`
and mixed Boolean trees preserve their checked AST.  Emit Keiki's infix structural
operators, `K.pnot` where needed, `K.lit` for typed literals, direct `d.field` and
`B.reg @"field"` roots, and the existing typed projection operations.  Add golden
unit cases for every operator, same- and mixed-precedence nesting, negative
literals, nominal comparisons, and nested paths.  Parse and compile representative
rendered expressions; string resemblance alone is not acceptance.

A normal generated transition should have this shape, adjusted to the actual
fixture types and established formatter:

```haskell
B.onCmd inCtorAdjust $ \d -> B.do
  B.requireGuard $
    d.balance .+ B.reg @"balance" .>= K.lit (-100 :: Integer)
      .&& B.reg @"reserved" .+ d.requested .<= B.reg @"capacity"
      .&& d.active .== K.lit False
  B.slot @"balance" =:
    B.reg @"balance" .+ d.balance .* K.lit (2 :: Integer)
  B.slot @"active" =: K.lit True
  B.emit wireAdjusted (AdjustedTermFields { balance = d.balance })
  B.goto ScalarAccountReviewed
```

The exact fixture has more guard clauses, writes, and output fields; the point is
that they remain adjacent.  No helper named after a transition guard or write may
replace the inline expression.

Milestone 2 changes scaffold structure.  Fold the import and pragma analysis from
`emitExpressions` into `emitGeneratedTransducer`, including `Text`, `Natural`,
time constructors, consumer modules, generated nominals, nominal projections, and
structural projections only when used.  Merge imports deterministically and retain
warning-free output.  For projection terms whose required witness name is an
opaque hash or representation detail, emit a deterministic, collision-checked
local binding named from the DSL root and JSON-pointer path, and define it in the
same `Transducer` module using exactly the old `K.regProj`/`K.inpProj` expression.
The transition body must expose the business path; the local binding contains only
projection plumbing, never a guard or write expression.

Remove `expressionFunctionNames`, `emitExpressions`, transition guard/write
definition emission, the `Expressions` module from `scaffoldAggregateForService`,
its import from `Transducer`, and the `/Expressions.hs` generated-firewall
exception.  Leave `/Transducer.hs` generated and replaceable.  Regenerate all
checked conformance trees, delete only generated-banner-bearing `Expressions.hs`
fixtures, and remove their Cabal module-list entries.  Update
`keiro-dsl/test/Main.hs`, the mutation script, user API/reference guides, typed
toolchain guide, and guarantee guide.

Existing consumer scaffolds need a safe migration because reconciliation does not
delete stale files.  The scaffold report must identify the obsolete module and its
Cabal entry.  Documentation instructs the operator to delete an old
`Expressions.hs` only if it contains the exact keiro-dsl generated banner; any
unbannered or modified file is preserved and reported for manual resolution.  Do
not add broad automatic deletion or overwrite permissions as part of this plan.

Milestone 3 reruns the full guarantee ledger.  Every item from Milestone 0 must
either match byte-for-byte or, for expected Haskell/diagram presentation changes,
have an explicit new golden plus an unchanged semantic proof.  Add a test that
changing only the emitter/module layout leaves `aggregateFoldSurface` and
`aggregateFoldFingerprint` unchanged, while changing a checked guard or write
still changes them.  The mutation script must mutate inline `Transducer` behavior,
prove scaffold regeneration repairs it, prove a source mutation changes runtime
and fingerprint as before, and prove Hole ownership/firewall behavior remains
unchanged.  Amend ADR 0017 and the two local guides that describe `Expressions`.
Run strict OKF validation so ADR metadata and log entries remain canonical.

Milestone 4 starts only after
`mori://shinzui/keiki/plans/84-preserve-readable-business-semantics-in-keiki-transducers-and-diagrams`
has published Keiki `0.8.0.0` to Hackage and an upstream tag.  Verify both sources,
then raise every `keiro-dsl` Keiki bound from `>=0.7 && <0.8` to
`>=0.8 && <0.9`.  Update `jitsurei/src/Jitsurei/Diagrams.hs` to use the new readable
primary renderer (without reassembling opt-in flags locally), add a scalar
aggregate diagram whose guard, assignments, literal values, event, and target are
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

    mori registry show shinzui/keiro --full
    mori registry show shinzui/keiki --full
    mori registry docs shinzui/keiki
    curl -fsSL https://hackage.haskell.org/package/keiro-dsl/preferred.json
    curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
    git ls-remote --tags https://github.com/shinzui/keiro.git
    git ls-remote --tags https://github.com/shinzui/keiki.git

At plan creation, the expected Keiro evidence is `0.8.0.0` and
`keiro-dsl-0.8.0.0`; Keiki is `0.7.0.0` until the companion plan publishes
`0.8.0.0`.  Do not raise the Cabal bound based only on a local checkout.

Establish and repeatedly run the focused guarantee gates:

    cabal test keiro-dsl-test --test-show-details=direct
    cabal test keiro-dsl-conformance-aggregate-scalar-expressions --test-show-details=direct
    bash keiro-dsl/test/aggregate-scalar-expression-mutation-test.sh

Inspect the generated readability and forbidden split with repository-scoped
searches:

    sed -n '1,260p' keiro-dsl/test/conformance-scalar-expressions/Generated/AggregateScalarExpressions/ScalarAccount/Transducer.hs
    rg -n 'K\.(PAnd|POr|PCmp|PEq|tadd|tsub|tmul)|Expressions\.' keiro-dsl/test/conformance-scalar-expressions/Generated
    rg -n 'Expressions\.hs|\.Expressions\b|emitExpressions|expressionFunctionNames' keiro-dsl/src keiro-dsl/test keiro-dsl/keiro-dsl.cabal docs jitsurei

The first `rg` must return no raw expression constructors or `Expressions.` calls
inside the canonical generated transducer.  The second may find historical plans
and the ADR amendment's historical explanation, but no current generator, fixture,
Cabal, or user-reference contract.

After the Keiki dependency milestone, regenerate and check diagrams:

    cabal run jitsurei:exe:jitsurei-diagrams -- --write
    git diff -- docs jitsurei
    cabal run jitsurei:exe:jitsurei-diagrams -- --check

Run full repository validation:

    cabal build all
    cabal test all --test-show-details=direct
    just adr-validate
    nix flake check
    cabal sdist all
    git diff --check

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
business-shaped projection names.  Removing non-contractual comments from a copy
must not make that transition unintelligible.  No generated `Expressions.hs` or
`Expressions` import remains in a clean scaffold.

The guarantee ledger is accepted only when all of these proofs pass:

- Parse/check/lower tests accept every previously admitted canonical scalar form
  and reject every previous negative fixture with the same diagnostic code.
- Every generated guard and write comes from `resolvedGeneratedExpressions`; no
  untyped textual expression or second display AST can enter code generation.
- The canonical fixture compiles with all scalar, nominal, time, and structural
  projection types.  Operator sugar builds the same Keiki constructors and adds no
  opaque `TApp` fallback.
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
- Generated firewall, create-once Hole preservation, stale reporting, and modified
  generated-file diagnostics retain their pre-change behavior.  Only the exact
  `Expressions` generated target is removed.
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
Review generated diffs before accepting them; never update a golden solely because
a test failed.

Fixture cleanup may delete only files that are both at an exact expected
`Expressions.hs` path and contain the keiro-dsl generated banner.  For a consumer
workspace, preserve any missing-banner or modified file, report it, and require
manual resolution.  Remove the matching Cabal module entry only after resolving
the exact module name.  Do not glob-delete generated directories.

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
must have one precedence-aware renderer over the checked AST.  Exact helper names
may follow module conventions, but their responsibilities must correspond to:

```haskell
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

The implementation must also track left/right context or an equivalent document
algebra so equal-precedence non-associative cases are parenthesized correctly.
These functions print existing `TypedScalarExpr`; they do not parse strings or
define semantics.

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

Keiki has this canonical package URI:

    mori://shinzui/keiki/packages/keiki

Milestones 0 through 3 remain within the released `>=0.7 && <0.8` API.
Milestones 4 and 5 depend on
`mori://shinzui/keiki/plans/84-preserve-readable-business-semantics-in-keiki-transducers-and-diagrams`
and set the released bound to `>=0.8 && <0.9` only after authoritative registry and
tag verification.

The Keiro package has this canonical URI:

    mori://shinzui/keiro/packages/keiro-dsl

Removal of its generated `Expressions` surface and adoption of Keiki `0.8` are
declared breaking changes in the coordinated Keiro `0.9.0.0` changelog and
migration guide.
