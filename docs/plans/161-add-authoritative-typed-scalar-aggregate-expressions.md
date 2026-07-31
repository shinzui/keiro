---
id: 161
slug: add-authoritative-typed-scalar-aggregate-expressions
title: "Add authoritative typed scalar aggregate expressions"
kind: exec-plan
created_at: 2026-07-31T14:46:36Z
---

# Add authoritative typed scalar aggregate expressions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, an aggregate source using the successor language contract can express ordinary
typed scalar calculations directly in guards and register writes, and the generated transducer
must execute those checked expressions. Authors can use Text, Bool, `Int`, `Integer`, `Natural`,
Time, enum, and ID literals where the resolved scalar capability permits them. Exact `Integer`
arithmetic supports `+`, `-`, and `*`; `Natural` supports `+`, `*`, and total truncated
subtraction. Required structural paths may end at a supported scalar leaf.

A representative versioned source is:

```keiro
language keiro-dsl 2

guard cmd.requestedAt >= reg.windowStart
  && cmd.requestedAt < reg.windowEnd
  && cmd.requestedUnits + reg.reservedUnits <= reg.capacity
write reservedUnits := reg.reservedUnits + cmd.requestedUnits
```

The generated expression is authoritative: a hand-owned module cannot omit, replace, or weaken
the declared guard or write. Keiki evaluates the same generated structural term tree during
concrete forward execution and replay and translates it for symbolic analysis. The result is
observable in a compiled conformance aggregate whose direct command execution, encoded-event
replay, full replay after snapshot invalidation, and symbolic result agree.

Version 2 always retains an escape hatch for behavior that the scalar language does not express.
A transition is generated-owned by default, or its source may explicitly say `implementation
hole`. A Hole-owned transition delegates its predicate and register updates to hand-owned Keiki
terms while keeping the declared source, command, emitted event kinds, target, and replay mode as a
checked envelope. Generated-owned and Hole-owned semantics never silently override one another.
Hole behavior carries an explicit fold version, enters snapshot identity, and reports opaque terms
as unverified rather than successful. This is the fallback against which every future DSL feature
must justify itself, and adding a feature never removes the fallback.

This plan does not add list or map literals, membership, `keys`, `values`, `any`, `all`, collection
bounds, or collection-element variables. Those ideas moved to
[plan 166](166-evaluate-bounded-aggregate-collection-membership-and-quantification.md), which may
ratify NO-GO and finish without implementing them. Version 2 reserves their tokens as unsupported
so an accidental parse cannot become an unofficial contract.


## Progress

- [x] 2026-07-31: Audited the original expression proposal against the parser, resolver,
  generated ownership, fold/diff/replay logic, ADRs 3, 4, 12, and 16, and Mori-resolved Keiki
  source; removed unsound machine-`Int` arithmetic and dual-evaluator designs.
- [x] 2026-07-31: Split bounded collection membership and quantification into plan 166, retained
  the high-confidence scalar API here, and defined explicit per-transition Hole ownership so
  unsupported behavior always has an honest fallback.
- [x] 2026-07-31: Prerequisite plan 160 completed versioned CLI/workspace loading and froze
  language version 1; its full suite passed 394 examples, `cabal build all` and native
  `nix flake check` passed, and ADR 16 was accepted.
- [ ] Milestone 1: prove and release the exact scalar Keiki capabilities needed for `Integer` and
  total Natural arithmetic, then record the verified Hackage version and matching upstream tag.
- [ ] Milestone 2: add the version-2 located scalar grammar and one typed expression resolver with
  stable diagnostics while pinning version-1 rejection behavior.
- [ ] Milestone 3: make generated version-2 transducers own declared guards and writes, add the
  explicit Hole-owned transition escape hatch and output hooks, and preserve version-1 scaffolding.
- [ ] Milestone 4: add compiled, property, mutation, parser-version, replay, snapshot, and
  Hole-boundary regression tests.
- [ ] Milestone 5: update notation, user documentation, changelog, diff remedies, relevant ADRs,
  and complete full repository and ADR validation.


## Surprises & Discoveries

- 2026-07-31: The current parser admits names, Bool literals, comparisons, `&&`, and `||`; it
  deliberately emits a localized error for arithmetic operators. It has no Text/number/Time
  literal nodes, explicit roots, or dotted scalar paths.
- 2026-07-31: Current `Scaffold.hs` renders each aggregate guard and write only as a `-- HOLE`
  comment in a create-once hand-owned transducer. Adding a typed resolver or generated helper
  without changing ownership would not make the checked expression execute.
- 2026-07-31: Keiki already has one concrete evaluator for `Term`/`HsPred` and one symbolic
  translator for the same AST. A separate generated Haskell evaluator would duplicate semantics
  and could drift on arithmetic, literal, and projection behavior.
- 2026-07-31: Keiki `0.5.0.0` represents Haskell `Int` as an unbounded SMT integer and explicitly
  does not model machine-width wraparound. Arithmetic near `minBound` or `maxBound` can disagree
  between concrete Haskell and symbolic analysis.
- 2026-07-31: Keiki `0.5.0.0` constrains symbolic Natural values to be non-negative but omits
  Natural from its numeric capability registry. Haskell `Natural` subtraction throws
  `Underflow`; generic subtraction would be partial concretely and different from mathematical
  subtraction.
- 2026-07-31: Existing structural projection generation already has the right conservative
  boundary for this plan: it reaches required scalar leaves and stops at optional, union,
  collection, JSON, and opaque boundaries.
- 2026-07-31: Unqualified name resolution currently prefers a register over a same-named command
  field. The scalar conformance fixture deliberately contains both, so version 2 needs explicit
  `reg.`/`cmd.` roots and ambiguity errors while version 1 retains historical behavior.
- 2026-07-31: A conjunctive custom guard alone is not a universal escape hatch: an unsupported
  register computation could still strand a consumer. The sound general boundary is explicit
  transition ownership. Generated mode owns the checked guard/writes; `implementation hole` owns
  arbitrary predicate/updates within a checked transition envelope and reports lost evidence.
- 2026-07-31: Hackage preferred-version metadata listed Keiki `0.5.0.0`, and upstream tag
  `v0.5.0.0` resolved to commit `3250780cffa1397cb320ebae69a326ee7554685f` during the audit. That
  release lacks a total Natural arithmetic contract; the local Mori corpus agreed but was not
  used as release authority.


## Decision Log

- Decision: Make checked scalar expressions part of the executable generated transducer rather
  than advisory comments for hand-written code.
  Rationale: Type checking, symbolic analysis, diff classification, and replay fingerprints are
  valuable only when the runtime cannot silently execute different behavior.
  Date: 2026-07-31

- Decision: Build and type-check one located scalar expression AST, then generate one Keiki
  structural term/predicate/update tree that Keiki uses for both concrete execution and symbolic
  analysis.
  Rationale: Independent production evaluators would require permanent equivalence evidence and
  could drift on Natural subtraction, overflow, literals, or projections.
  Date: 2026-07-31

- Decision: Add exact `Integer` as an aggregate scalar and support `+`, `-`, and `*` for it.
  Preserve `Int` literals, writes, equality, and ordering, but reject `Int` arithmetic. Support
  Natural `+`, `*`, and monus, where `a - b = max 0 (a - b)`. Exclude division, remainder,
  implicit numeric coercions, and Time arithmetic.
  Rationale: `Integer` and Natural are arbitrary-precision domains with total chosen operations.
  Keiki's current `Int` symbolic representation does not model concrete overflow, and ordinary
  Haskell Natural subtraction is partial.
  Date: 2026-07-31

- Decision: Version 2 supports explicit `reg.name` and `cmd.name` roots. An unqualified name is
  accepted only when exactly one register or active command field matches. Enum values use their
  qualified `EnumName.Constructor` spelling. State and top-level rule names are not expression
  values.
  Rationale: Generated code cannot safely guess which same-named value an author intended, and
  rule invocation would require separately designed dependency, parameter, and recursion
  semantics.
  Date: 2026-07-31

- Decision: Permit dotted paths only through checked required structural record fields to a
  supported scalar leaf. Stop at optional, union, collection, JSON, and opaque boundaries.
  Rationale: ADR 12 supplies total structural projection evidence only along required paths. This
  plan should consume that authority without inventing missing/null or collection semantics.
  Date: 2026-07-31

- Decision: Allow qualified enum literals and constructor-style ID literals in whole-value writes
  but reject them in generated guards until a released Keiki nominal encoding provides structural
  symbolic equality or ordering.
  Rationale: Plan 158 and released Keiki keep nominal values opaque. A free Boolean or opaque
  application must not be presented as successful verification.
  Date: 2026-07-31

- Decision: Every version-2 transition has explicit behavior ownership. Generated ownership is the
  default and necessarily executes its declared guard and writes. A transition marked
  `implementation hole` forbids DSL guard/write clauses and delegates its predicate and ordered
  updates to a stable, create-once Hole while retaining the declared source, command, emitted event
  kinds, target, and replay mode as a generated checked envelope.
  Rationale: Users always need an escape hatch for behavior the DSL cannot express. Mutually
  exclusive ownership avoids the unsound state where checked expressions exist but hand-written
  code silently replaces them.
  Date: 2026-07-31

- Decision: Every Hole-owned transition carries an explicit manual `FoldVersion`, is composed into
  the snapshot fold fingerprint, and is reported as verified only to the degree Keiki can validate
  and symbolically translate the supplied structural terms. Opaque applications remain allowed but
  visibly unverified. The escape hatch remains available after future language features land.
  Rationale: ADR 3 already makes hand-written fold behavior a manual versioning obligation. An
  escape hatch must prevent users from being stuck without pretending hand-written behavior has
  source-level proof or automatic diff visibility.
  Date: 2026-07-31

- Decision: Exclude list/map literals, membership, collection functions, quantification,
  collection bounds, and lexical element variables from plan 161. Version 2 rejects their
  reserved spellings; plan 166 owns the independent GO/NO-GO decision.
  Rationale: Scalar expressions have broad immediate value and fit Keiki's existing term model.
  Collections add a new bounded symbolic domain, runtime invariant, solver budget, and language
  complexity whose value must be proven against an explicit Hole-owned transition.
  Date: 2026-07-31

- Decision: Register this syntax only under successor language version 2 after plan 160 freezes
  version 1. If plan 158 deliberately shares the same unreleased successor, review both parser
  deltas and rejection fixtures together; otherwise it uses a later version.
  Rationale: Released parsers are append-only contracts under ADR 16 and cannot acquire new scalar
  syntax retroactively.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  structural-consumer-type MasterPlan.
  Rationale: Scalar expression execution and generated ownership form an independently
  schedulable change with their own acceptance evidence.
  Date: 2026-07-31


## Outcomes & Retrospective

The 2026-07-31 validation and split changed planning, not production code. Plan 161 now contains
only the high-confidence scalar language and the generated execution boundary. It no longer makes
that work wait for a bounded collection formalism. Machine-`Int` arithmetic, partial Natural
subtraction, two production evaluators, and ignorable generated helpers remain excluded.

The split also retained an explicit Hole-owned transition so a plan-166 NO-GO does not force Keiro
to pretend every business predicate or update belongs in the DSL. That fallback deliberately
loses source-level proof and automatic diff visibility and therefore carries conformance, opacity,
and manual fold-version obligations. It remains available even if collection syntax later ships.

Implementation and runtime outcomes remain pending. At each milestone, record the released Keiki
dependency, concrete/symbolic agreement evidence, generated ownership migration experience, and
remaining unverified surfaces. Before completion, distill durable decisions into the relevant
ADRs.


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines the untyped `Expr` used by guards, rules, and writes.
`keiro-dsl/src/Keiro/Dsl/Parser.hs:pExpr` builds that tree with `makeExprParser`; atoms currently
are parentheses, Bool literals, and names. `keiro-dsl/src/Keiro/Dsl/Validate.hs` performs scope
checks and comparison capability checks but does not type-check every Boolean operand or write
right-hand side. `keiro-dsl/src/Keiro/Dsl/AggregateType.hs` owns the aggregate scalar and
capability resolver introduced by plan 157. It has no `Integer` constructor.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` generates Domain, Codec, EventStream, Harness, Projection,
and create-once Holes modules. `onCmdBlock` currently emits guard/write comments into Holes rather
than executable terms. Version 2 must add generated expression/transducer modules, typed output
hooks, and stable per-transition Hole implementations for sources that explicitly select them. Do
not overwrite an existing version-1 Holes module or pretend its behavior was automatically
migrated.

`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` represents mapped structural record shapes.
`projectionSpecs` in `Scaffold.hs` emits Keiki `FieldProjection` witnesses for eligible required
scalar leaves and stops at unsupported boundaries. `MappedDiff.hs`, `FoldFingerprint.hs`,
`ReplayImpact.hs`, `Diff.hs`, pretty printing, source-language dispatch, scaffold records, and
workspace relocation inspect syntax or fold metadata and require exhaustive updates.

The symbolic dependency is `mori://shinzui/keiki/packages/keiki`. In released `0.5.0.0`, the
`Term` AST and concrete evaluator live under canonical project `mori://shinzui/keiki` at
project-relative `src/Keiki/Core.hs`, while the symbolic registry and translator live at
`src/Keiki/Symbolic.hs`; source-file artifact URIs are not yet defined. The implementer must use
Mori to locate the current source and then verify any chosen dependency release independently
against Hackage metadata and the matching upstream tag.

[ADR 3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md) requires every
generated guard/write semantic change to enter the replay-fold fingerprint and requires a manual
version for invisible hand-written fold behavior. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires ill-typed, partial, or unsupported expressions to fail during checking.
[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires checked nested paths to use the structural graph and to execute the semantics the checker
validates. [ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
freezes released parser versions.
[ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
records the proposed permanent exclusive generated/Hole ownership boundary introduced by this
plan. Plan 160 completed the language-version prerequisite. Plan 158 owns direct nominal Haskell
bindings. [Plan 159](159-generate-complete-reachable-state-holes-and-spec-behavioral-conformance.md)
owns consumer witnesses; its witnesses must invoke the generated version-2 transducer rather than
an alternative behavior implementation.

A “typed expression” is a source expression annotated with one resolved result type, source row,
root provenance, and operator capability evidence. “Monus” is total Natural subtraction,
`max 0 (a - b)`. An “authoritative expression” is one the generated runtime necessarily executes.
A “Hole-owned transition” is an explicitly selected behavior implementation whose arbitrary Keiki
predicate and updates live in consumer code while its structural transition envelope remains
generated and checked.


## Plan of Work

Milestone 1 establishes the dependency contract before Keiro accepts arithmetic syntax. Use Mori
to inspect the current Keiki source. Add or coordinate a Keiki change that gives exact `Integer`
and Natural operations one structural concrete/symbolic meaning. Natural monus must translate as
`ite (a >= b) (a - b) 0`; it must not use Haskell's partial `Natural (-)` or generic subtraction.
An opaque application, free Boolean, skipped result, solver `Unknown`, or timeout cannot count as
verification of a generated scalar guard. Release Keiki first, verify Hackage preferred-version
metadata and the matching upstream tag/commit, inspect that exact source, and only then select the
Cabal bounds. No collection API is part of this dependency milestone.

Milestone 2 registers language version 2 and implements a located scalar grammar. Add an optional
`implementation hole` transition clause whose absence means generated ownership. A Hole-owned
transition rejects `guard` and `write` clauses because two simultaneous semantic authorities are
not permitted; it retains `emit`, `goto`, live/replay-only mode, source, and command declarations.
Extend `TypeExpr` and `ResolvedAggregateType` with `Integer`. Add Text, signed/unsigned integral, Time,
qualified enum, and constructor-style ID literals. A leading negative sign is part of an `Int` or
`Integer` literal only; Natural rejects it. Integral literals are resolved from their expected
type and never implicitly coerce among `Int`, `Integer`, and `Natural`.

The canonical escape-hatch spelling is:

```keiro
Active -- Reprice -->
  implementation hole
  emit PriceChanged
  goto Active
```

The Hole supplies the predicate, updates, and emitted-event field values for that structural
envelope. Conditional outcomes use separate declared Hole-owned transition alternatives; Hole code
cannot invent an undeclared event kind or target state.

The grammar supports explicit `reg.` and `cmd.` roots and dotted required paths. Multiplication
binds above addition/subtraction; arithmetic binds above non-associative comparison; comparison
binds above `&&`; `&&` binds above `||`. Chained comparisons fail. Guards and Boolean operands
must resolve to Bool, and a write right-hand side must exactly equal its register type. Enum and ID
literals must satisfy their checked declaration but work only in whole-value writes until nominal
symbolic capability exists. `in`, `not in`, `keys`, `values`, `any`, `all`, list/map literals, and
element binders fail with a version-2 `CollectionExpressionUnsupported` diagnostic that points to
plan-166 documentation. Version 1 rejects the first new token through its frozen parser.

The resolver accumulates append-only, deterministically ordered diagnostics for unknown or
ambiguous roots, invalid paths, wrong operand/write types, unsupported capability, invalid
Time/ID/enum literals, non-Bool guards, and reserved collection syntax. Semantic errors retain the
repository's exact-row `Loc`; parser failures retain exact line and column.

Milestone 3 changes generated ownership for version 2. Add a generated module such as
`Generated.<Context>.<Aggregate>.Expressions` with stable names for checked guard and write terms,
and a generated transducer module that owns transition mode, command constructor, the declared
guard, ordered register writes, static emits, and goto for generated-owned transitions. The
create-once Holes module exports typed event/output functions plus one implementation value per
stable Hole-owned transition identity. Generated assembly validates that each Hole implementation
matches its declared source/command/event/target/mode envelope and offers no aggregate-wide
transducer replacement.

A Hole-owned value supplies its Keiki predicate and ordered register updates and requires a
hand-owned `FoldVersion`. The generated fold identity composes that version with the structural
envelope. Runtime validation and conformance inspect the supplied Keiki terms; opaque applications
are reported unverified and never upgraded to verified. Migration tooling preserves existing
version-1 Holes and creates explicit version-2 ownership skeletons for manual review. Future DSL
features may migrate individual Hole transitions to generated ownership but may never delete Hole
ownership from the language.

Lower every scalar name, literal, arithmetic, comparison, Boolean operation, and path into Keiki
terms through one exhaustive renderer. Do not generate a pure-Haskell expression evaluator.
Update `complementExpr` so comparison/Boolean complement remains total while arithmetic operands
stay unchanged. Update expression traversal, pretty printing, source rendering, parser registry,
workspace relocation, scaffold records, generated module firewalls, imports/packages,
`FoldFingerprint`, `Diff`, `MappedDiff`, and `ReplayImpact`. Version-1 parsing, validation,
rendering, module lists, and generated bytes remain pinned by regression fixtures.

Milestone 4 creates a compiled `keiro-dsl-conformance-aggregate-scalar-expressions` service using
every literal family, exact Integer and Natural arithmetic, required scalar projections,
same-named registers/command fields, generated writes, and both ownership modes. A small
test-only reference interpreter evaluates the typed scalar AST; production does not import it.
Property tests compare the oracle with Keiki concrete evaluation and the symbolic formula across
finite generated inputs. Mutation tests replace monus with partial subtraction, bypass a generated
guard, change one write operand, let a Hole implementation coexist with DSL guard/write clauses,
violate its declared event/target envelope, omit its fold version, and report an opaque Hole as
verified. Each mutation must turn its owning test red and restore the file on exit. Boundary tests
prove Int arithmetic near `minBound`/`maxBound` is rejected.

Milestone 5 documents version-2 scalar syntax, version-1 and collection-syntax rejection, manual
Holes migration, exact arithmetic domains, Hole-ownership opacity, and operational diff remedies.
Every generated guard/write change is replay-affecting and invalidates snapshots through ADR 3's
fold fingerprint. A Hole behavior change without a fold-version bump is a documented contract
violation. Update ADRs 3, 4, 12, and 16 if the implementation confirms durable changes, and create
a new ADR for the generated-expression/Hole-ownership seam only if existing records cannot
hold it clearly.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Re-establish the dependency source through Mori:

```bash
mori registry list
mori registry search keiki
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
mori registry dependents shinzui/keiki --packages
mori path mori://shinzui/keiki/packages/keiki
```

Verify the release authority independently before changing Cabal bounds:

```bash
curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
git ls-remote --tags https://github.com/shinzui/keiki.git
```

Replace the recorded `0.5.0.0` baseline with the first released version whose exact tag contains
the required total scalar contract. Run the focused suites as they are added:

```bash
cabal test keiro-dsl-test \
  --test-option=--match \
  --test-option='scalar expressions' \
  --test-show-details=direct
cabal test keiro-dsl-conformance-aggregate-scalar-expressions \
  --test-show-details=direct
bash keiro-dsl/test/aggregate-scalar-expression-mutation-test.sh
```

Exercise both parser contracts explicitly:

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/aggregate-scalar-expressions-v2.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/aggregate-scalar-expressions-v1-rejects.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/aggregate-collection-expressions-v2-rejects.keiro
```

The first fixture prints `OK`. The version-1 fixture exits non-zero at the first version-2 scalar
token. The collection fixture exits non-zero with `CollectionExpressionUnsupported` and never
generates code.

Before completion, run:

```bash
cabal build all
cabal test all --test-show-details=direct
nix flake check
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
git diff --check
```

All commands must exit zero. Record actual example/property counts, released dependency/tag, and
any environment-qualified Nix result in Progress and Surprises & Discoveries.


## Validation and Acceptance

1. Version 2 parses and round-trips every documented scalar literal, root, required scalar path,
   arithmetic operator, comparison, Boolean expression, and scalar write. Released version 1 and
   legacy syntax reject the new forms and retain byte-identical generated output.
2. Every expression node has one resolved scalar type and capability. Boolean operators require
   Bool, writes exactly match their register, literals resolve without coercion, ambiguous names
   fail, and unsupported structural boundaries fail before scaffolding.
3. Exact Integer `+`, `-`, and `*` and Natural `+`, `*`, and monus agree in the reference oracle,
   Keiki concrete evaluation, replay, and symbolic formulas. Natural `2 - 5` is `0`. Int
   arithmetic, division, remainder, mixed numeric types, and Time arithmetic fail during checking.
4. Every transition has exactly one behavior owner. Generated-owned transitions necessarily
   execute declared guards and ordered writes. Hole-owned transitions reject DSL guard/write
   clauses and cannot change their declared structural envelope.
5. `implementation hole` remains available regardless of which later expression features ship.
   Its predicate and updates may be arbitrary Keiki terms, carry a manual fold version, and change
   snapshot/fold identity when that version changes. Opaque Hole terms are unverified, never
   verified, and conformance mutations detect envelope or replay divergence.
6. Qualified enum and ID literals are checked and work in whole-value writes. Until a released
   nominal encoding exists, their guard/comparison use fails with a documented capability code.
7. Repeated scalar path reads share symbolic identity. Direct execution, encoded event replay,
   replay after snapshot invalidation, and the test oracle agree for all conformance cases.
8. `complementExpr` remains an involution and evaluates to logical negation for finite generated
   scalar cases. Guard tightening still prints a valid replay-only twin.
9. List/map literals, membership, collection functions, quantifiers, bounds, and element variables
   all fail under version 2 with stable rejection evidence owned by plan 166.
10. The dependency floor names the first adequate published Keiki release and records matching
    Hackage metadata and upstream tag/commit. An unreleased sibling checkout is not acceptance.


## Idempotence and Recovery

Mori lookup, release checks, parsing, checking, disposable scaffolding, builds, and tests are safe
to repeat. Generate comparison trees under `mktemp -d`; never target an existing hand-owned Holes
module while testing version-2 ownership migration. Generated modules are reproducible from the
source, while hook modules remain hand-owned and are created only when absent.

Keep language registration, scalar resolution, dependency lowering, and generated ownership in
separate checkpoints. Until the released Keiki scalar gate passes, version-2 arithmetic must stay
absent rather than accept syntax behind a runtime flag. If concrete and symbolic scalar results
disagree, disable the affected capability at `check`, preserve the minimized fixture, and update
this plan before proceeding.

Mutation scripts must install traps that restore exact files and must run `git diff --check` after
restoration. Do not use destructive Git reset or checkout for recovery. Existing version-1 Holes
remain untouched; version-2 migration creates and reviews the new hook interface alongside the old
file until the compiled conformance path uses the generated transducer.


## Interfaces and Dependencies

The source AST must retain a row for each node and distinguish roots, paths, literals, and scalar
operators. The checked representation may use GADTs or an existential first-order tree. An
equivalent shape is:

```haskell
data ScalarType a where
  SText :: ScalarType Text
  SInt :: ScalarType Int
  SInteger :: ScalarType Integer
  SBool :: ScalarType Bool
  STime :: ScalarType UTCTime
  SNatural :: ScalarType Natural
  SId :: ResolvedNominalId a -> ScalarType a
  SEnum :: ResolvedNominalEnum a -> ScalarType a

data TypedScalarExpr a where
  Literal :: ScalarType a -> AggregateValue a -> TypedScalarExpr a
  Root :: ResolvedScalarRoot a -> TypedScalarExpr a
  Project
    :: ResolvedScalarProjection owner a
    -> ResolvedRoot owner
    -> TypedScalarExpr a
  Add
    :: TotalArithmetic a
    -> TypedScalarExpr a
    -> TypedScalarExpr a
    -> TypedScalarExpr a
  Subtract
    :: TotalSubtraction a
    -> TypedScalarExpr a
    -> TypedScalarExpr a
    -> TypedScalarExpr a
  Multiply
    :: TotalArithmetic a
    -> TypedScalarExpr a
    -> TypedScalarExpr a
    -> TypedScalarExpr a
  Equal
    :: SolverEquality a
    -> TypedScalarExpr a
    -> TypedScalarExpr a
    -> TypedScalarExpr Bool
  Compare
    :: SolverOrdering a
    -> OrderingOp
    -> TypedScalarExpr a
    -> TypedScalarExpr a
    -> TypedScalarExpr Bool
  And :: TypedScalarExpr Bool -> TypedScalarExpr Bool -> TypedScalarExpr Bool
  Or :: TypedScalarExpr Bool -> TypedScalarExpr Bool -> TypedScalarExpr Bool

resolveScalarExpr
  :: ExpressionEnvironment
  -> ExpectedScalarType
  -> Expr
  -> Either (NonEmpty ExpressionDiagnostic) SomeTypedScalarExpr
```

The exact indices may differ. The invariants may not: result type, source row, root/path
provenance, and explicit operator evidence are retained; total arithmetic has no `Int` instance
and distinguishes Natural monus from ordinary subtraction.

Generated lowering exposes one path equivalent to:

```haskell
renderKeikiTerm :: TypedScalarExpr a -> GeneratedHaskell
renderKeikiPredicate :: TypedScalarExpr Bool -> GeneratedHaskell
renderKeikiUpdate
  :: ResolvedRegister a
  -> TypedScalarExpr a
  -> GeneratedHaskell
```

These functions render Haskell that constructs Keiki AST nodes; they do not evaluate expressions.
The generated transducer consumes those nodes and a typed `AggregateHooks` value. The hook API
contains output/event constructors and stable-transition-keyed Hole behavior values equivalent to:

```haskell
data TransitionImplementation
  = GeneratedImplementation
  | HoleImplementation

data HoleTransition registers input = HoleTransition
  { foldVersion :: FoldVersion
  , predicate :: HsPred registers input
  , updates :: [SomeUpdate registers input]
  }
```

The source `Transition` records the implementation owner. Generated ownership forbids a Hole
behavior value; Hole ownership forbids source guard/write clauses and requires exactly one value.
Generated assembly retains the declared event/target/mode envelope and validates forward/replay
conformance. There is no aggregate-wide replacement transducer. Keiki's released concrete
evaluator and symbolic translator remain the only production interpreters.

The only anticipated new external capability is a released version of
`mori://shinzui/keiki/packages/keiki` exposing exact `Integer` evidence, total Natural
add/multiply/monus terms, and a queryable verified-versus-unknown symbolic result. Do not name the
version or PVP bounds until Milestone 1 verifies Hackage and the matching upstream tag. No
collection term dependency belongs in this plan.

Plan 160's language-version registry is a hard prerequisite. This plan reserves successor version
2. Plan 158 must either be deliberately co-released and tested under the same version-2 parser or
move its nominal-binding syntax to a later version. Plan 166 allocates no language version unless
its design gate returns GO.


Revision note: Detached this plan from the completed structural-consumer-type MasterPlan so it is
an independent implementation unit, 2026-07-31.

Revision note (2026-07-31): Validated the original proposal against Keiro, relevant ADRs, and the
released Keiki API. Replaced machine-Int arithmetic with exact Integer arithmetic, made Natural
subtraction total, changed dual lowerers to one Keiki AST, and made generated guards/writes
authoritative with regression gates.

Revision note (2026-07-31): Renamed and narrowed plan 161 to authoritative typed scalar
expressions. Moved all bounded collection, membership, and quantification work into plan 166, which
may conclude NO-GO without implementation. Retained explicit per-transition Hole ownership with
conformance, opacity, and fold-version obligations so unsupported behavior always has an honest
escape hatch.

Revision note (2026-07-31): Strengthened the escape hatch from a guard-only extension to explicit
`implementation hole` transition ownership. This keeps arbitrary predicates and register updates
possible without allowing hand-written code to silently override generated DSL semantics, and the
escape hatch remains available after future expression features ship.

Revision note (2026-07-31): Marked the plan-160 language-version prerequisite complete after its
recorded full-suite, build, Nix, and ADR validation passed.
