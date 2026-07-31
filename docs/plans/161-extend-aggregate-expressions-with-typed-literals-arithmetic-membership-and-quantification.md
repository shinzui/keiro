---
id: 161
slug: extend-aggregate-expressions-with-typed-literals-arithmetic-membership-and-quantification
title: "Extend aggregate expressions with typed literals arithmetic membership and quantification"
kind: exec-plan
created_at: 2026-07-31T14:46:36Z
---

# Extend aggregate expressions with typed literals arithmetic membership and quantification

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, aggregate guards and register writes can express ordinary typed domain logic
without hiding it in opaque Haskell. Authors can use Text, integer, Natural, Time, Bool, enum, and
ID literals; `+`, `-`, and `*` with defined numeric semantics; membership over finite collections;
and bounded `any`/`all` quantification. The checker type-checks each expression, rejects partial or
unbounded forms, and lowers the same typed tree to generated Haskell and Keiki conformance terms.

A representative accepted guard is:

```keiro
guard requestedAt >= windowStart
  && requestedAt < windowEnd
  && requestedUnits + reservedUnits <= capacity
  && requestedSku in allowedSkus
  && all line in lines where line.quantity > 0
```

The feature is complete only when a compiled generated aggregate executes and replays these
expressions and Keiki checks their bounded symbolic behavior. Parsing a larger expression language
without sound lowering is not acceptance.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: freeze typed syntax and total semantics, including collection bounds and Natural
  subtraction, and satisfy any required Keiki release prerequisite.
- [ ] Milestone 2: add a typed expression resolver with literals, arithmetic, collection access,
  membership, and bounded quantification plus stable diagnostics.
- [ ] Milestone 3: lower the typed tree to generated Haskell and Keiki from one capability model.
- [ ] Milestone 4: add compiled conformance, property and mutation tests, compatibility/diff rules,
  documentation, ADR updates, and full validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31: The current parser admits names, Bool literals, comparisons, `&&`, and `||`; it
  deliberately emits a localized error for arithmetic operators. There are no Text/number/Time
  literal nodes, membership operators, variables, or quantified expressions.
- 2026-07-31: Plans 149 and 150 explicitly excluded collection membership, element updates, and
  quantified guards. Plan 157 keeps Natural arithmetic outside its scope because released Keiki
  exposes Natural equality and ordering but deliberately omits it from the numeric registry.
- 2026-07-31: Haskell `Natural` subtraction throws `Underflow`; using Haskell's `(-)` directly
  would make a syntactically valid DSL expression partial at runtime.


## Decision Log

Record every decision made while working on the plan.

- Decision: Build and type-check one expression AST before either Haskell or Keiki lowering.
  Rationale: Independent parser, runtime, and solver interpretations would recreate the capability
  drift that plan 157 removes for aggregate types.
  Date: 2026-07-31

- Decision: Support `+`, `-`, and `*` for `Int`; support `+`, `*`, and total monus for `Natural`,
  where `a - b = max 0 (a - b)`. Division, remainder, coercions, and overflow-prone fixed-width
  integer types remain outside this plan.
  Rationale: Every accepted DSL expression must be total. Monus is the standard total subtraction
  operation on naturals and must be explicit in generated and symbolic semantics rather than
  inheriting Haskell's partial instance.
  Date: 2026-07-31

- Decision: Quantification is permitted only over literal collections, enums, or collection fields
  with a declared finite `max-items` bound. Unbounded `List`/`Map` values remain codec-capable but
  are rejected in membership or quantified solver-visible guards.
  Rationale: Keiki must construct a finite symbolic problem. Treating an arbitrary JSON list as a
  finite compile-time domain would make validation incomplete or non-terminating.
  Date: 2026-07-31

- Decision: Membership covers list elements and map keys; `values(map)` may be quantified but plain
  value membership must be written explicitly against `values(map)`. Quantifiers use lexical
  variables and cannot mutate registers.
  Rationale: These forms have clear types and deterministic finite lowering. Implicitly choosing
  keys versus values for a map would be ambiguous.
  Date: 2026-07-31

- Decision: ID and enum literals are checked nominally. IDs must parse against the declaration's
  prefix; enum literals use constructor names in source and existing wire spellings only in codecs.
  Rationale: Quoted text must not silently enter a nominal domain, and source expressions should
  not depend on serialized enum spellings.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  structural-consumer-type MasterPlan.
  Rationale: Expression-language expansion has its own dependency on language versioning and can
  be scheduled without changing the historical status of the earlier initiative.
  Date: 2026-07-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines the untyped `Expr` used by guards, rules, and writes.
`keiro-dsl/src/Keiro/Dsl/Parser.hs:pExpr` builds that tree with `makeExprParser`; its atoms are
parentheses, Bool literals, and names, and its operators are comparisons and Boolean conjunction/
disjunction. `Validate.hs` resolves names and checks current guard capabilities.
`AggregateType.hs` owns the aggregate type/capability resolver introduced by plan 157.
`Scaffold.hs` renders expressions into generated Haskell and Keiki declarations. `MappedDiff.hs`,
`FoldFingerprint.hs`, `ReplayImpact.hs`, pretty printing, and workspace relocation all inspect the
current expression tree.

Consumer-owned structural shapes in `Grammar.hs` already represent `List` and `Map`, but without a
solver bound. Direct aggregate containers remain unsupported by plan 157. This plan adds bounded
collection expression capabilities without implying that every opaque or unbounded mapped value
becomes solver-visible.

The symbolic dependency is `mori://shinzui/keiki/packages/keiki`. Its current released registry
supports symbolic Bool, Int, Integer, Natural, Text, UTCTime, and fixed integers, but Natural is not
in the numeric discovery registry and there is no public bounded-list quantifier contract. Before
Keiro changes dependency bounds, implementation must verify the authoritative package registry and
matching upstream tag as required by repository policy.

[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires mapped structure and binding behavior to have one authority. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires ill-typed, unbounded, partial, or unsupported expressions to fail during checking.
[Plan 157](157-unify-aggregate-type-capabilities-and-lower-time-and-natural.md) establishes the
aggregate capability resolver this plan must extend. Completed
[plan 150](150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md)
provides field paths but explicitly does not provide these collection operations.

“Typed expression” means an expression annotated with its resolved aggregate type, lexical scope,
and required capabilities. “Bounded collection” means a collection whose maximum length is part of
the checked schema, fingerprints, diffs, and solver encoding. “Monus” means truncated Natural
subtraction, `max 0 (a - b)`.


## Plan of Work

Milestone 1 writes executable syntax/semantics tests before broad parser edits. Add canonical forms
for quoted Text, signed Int, context-inferred non-negative Natural, `time "...Z"`, qualified enum
constructors, prefix-checked ID literals, list literals, `+ - *`, `in`/`not in`, `keys`, `values`,
and `any`/`all ... where ...`. Extend mapped collection field syntax with `max-items=<positive
integer>` and make this bound part of checked type identity. Prototype the required symbolic
encoding against `mori://shinzui/keiki/packages/keiki`. If Keiki needs public total monus or bounded
sequence terms, land and release those upstream first, verify the registry/tag, then record the
minimum compatible bound here. Do not ship a Keiro parser path that falls back to concrete-only
checking.

Milestone 2 adds source `Expr` nodes in `Grammar.hs` and a separate typed tree in a new
`Keiro.Dsl.Expression` module. The resolver receives `AggregateType` environments for registers,
command/event fields, mapped field paths, rules, and lexical variables. It returns a typed tree or
located append-only diagnostics for ambiguity, type mismatch, unsupported operation, invalid Time
or ID literal, unbounded collection use, non-Bool predicate, and variable escape/shadowing. Update
Parser/PrettyPrint/workspace traversal and add parse-precedence properties. Literals are parsed
losslessly and Time is validated once, using the same total constructor rendering as plan 157.

Milestone 3 gives the typed tree exactly two lowerers: generated concrete Haskell and Keiki symbolic
terms. Both use shared operator/capability tables. Natural subtraction lowers to an explicit monus
helper in both. A bounded collection lowers to a length plus at most `max-items` slots; membership
and `any`/`all` are finite folds guarded by slot presence. Literal collections lower directly.
Reject mapped opaque values and unbounded collections before code generation. Update rule, guard,
write, sample, manifest, and import generation. Update fingerprints, diffs, and replay impact so a
bound decrease, operator change, or expression semantic change is classified honestly.

Milestone 4 adds a compiled conformance service exercising each literal family, mixed precedence,
Int arithmetic, Natural monus, list/map membership, empty collection identities (`any = false`,
`all = true`), and nested bounded quantification. Add property tests comparing concrete evaluation
with Keiki evaluation over generated bounded inputs, plus mutations for off-by-one bounds, wrong
monus, incorrect empty identities, and Haskell/Keiki drift. Update notation, typed toolchain,
compatibility docs, changelog, ADR 4, and ADR 12; add a new ADR if the finite symbolic collection
encoding becomes a public cross-plan invariant.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. At Milestone 1, discover and inspect the dependency
through Mori before selecting a bound:

```bash
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
```

After the dependency precondition is satisfied:

```bash
cabal test keiro-dsl-test --test-options='--match=aggregate.*expression'
cabal test keiro-dsl-conformance-aggregate-expressions
bash keiro-dsl/test/aggregate-expression-mutation-test.sh
cabal test keiro-dsl-test
cabal build all
nix flake check
```

The focused suite must print zero failures for parser precedence, type errors, boundedness, literal
validation, and diff/fingerprint behavior. The compiled suite must report concrete/Keiki agreement
for every generated bounded case. If an upstream release is required, add the exact Hackage
preferred-version response and upstream tag/commit to Surprises & Discoveries before changing the
Cabal bound.


## Validation and Acceptance

1. All documented literals parse and resolve only where their types are known. Invalid Time and ID
   literals fail at their source location; enum constructors cannot cross enum domains.
2. Operator precedence is canonical and round-trips: multiplication binds above addition/
   subtraction, arithmetic above comparisons/membership, comparisons above `&&`, and `&&` above
   `||`. Chained comparisons are rejected unless parenthesized into valid Bool expressions.
3. Int arithmetic and Natural `+`, `*`, and monus are total and produce identical concrete and
   symbolic results. A mutation to Haskell's partial Natural `(-)` fails.
4. Membership and quantifiers work for literal and schema-bounded collections. Unbounded list/map,
   mapped opaque, excessive or zero bounds, and predicates that do not return Bool fail at check,
   never scaffold.
5. `any` over an empty collection is false and `all` is true. Map membership is explicitly over
   keys; value membership/quantification uses `values(map)`. Iteration order cannot affect truth.
6. Generated code compiles and exercises guards and writes, and replay reaches the same state and
   registers as forward execution for all conformance cases.
7. Bounds and typed expression identities participate in scaffold records, fingerprints, diffs,
   and replay-impact reports. Pretty/scaffold output is deterministic for one-file and workspace
   inputs.
8. No new dependency bound is selected from memory or the local corpus alone; the released package
   registry and matching upstream tag are recorded and verified.


## Idempotence and Recovery

Parser, resolver, lowerers, scaffolding, and property generation are deterministic. Land syntax,
typed resolution, and lowerers in separate checkpoints so a blocked Keiki release does not leave
accepted syntax without sound execution. Until the symbolic prerequisite is released, keep the
feature behind failing capability validation rather than a runtime flag.

Bound changes are schema/evolution changes and must not be auto-rewritten. If a bound is too small,
the author raises it and reviews the diff/replay report. Mutations must restore files on exit. If
concrete and symbolic semantics disagree, disable the affected operator at validation and update
this living plan; do not retain a concrete-only escape hatch for aggregate guards.


## Interfaces and Dependencies

`Keiro.Dsl.Grammar.Expr` gains lossless source nodes; `Keiro.Dsl.Expression` must expose checked
equivalents of:

```haskell
data TypedExpr a where
  Literal :: AggregateValue a -> TypedExpr a
  Add :: NumericCapability a -> TypedExpr a -> TypedExpr a -> TypedExpr a
  Subtract :: SubtractionSemantics a -> TypedExpr a -> TypedExpr a -> TypedExpr a
  Multiply :: NumericCapability a -> TypedExpr a -> TypedExpr a -> TypedExpr a
  Member :: EqualityCapability a -> TypedExpr a -> BoundedCollectionExpr a -> TypedExpr Bool
  Any :: BoundedCollectionExpr a -> (Variable a -> TypedExpr Bool) -> TypedExpr Bool
  All :: BoundedCollectionExpr a -> (Variable a -> TypedExpr Bool) -> TypedExpr Bool

resolveExpr :: ExpressionEnvironment -> Expr -> Either (NonEmpty ExpressionDiagnostic) SomeTypedExpr
renderConcreteExpr :: SomeTypedExpr -> Text
renderSymbolicExpr :: SomeTypedExpr -> Text
```

The real representation may avoid a public GADT, but it must make result types, operator evidence,
collection bounds, and lexical variables explicit. `AggregateType` capabilities remain the source
of truth. The only anticipated external dependency is a released version of
`mori://shinzui/keiki/packages/keiki` exposing the total numeric and finite-sequence primitives
proven necessary in Milestone 1. Plan 160's language-version registry is also a hard prerequisite:
this syntax must be assigned a new version (or a deliberately shared unreleased version with plan
158), and must not widen a released parser contract in place.


Revision note: Detached this plan from the completed structural-consumer-type MasterPlan so it is
an independent implementation unit, 2026-07-31.
