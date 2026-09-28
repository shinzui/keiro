---
type: Research Document
title: "Recursion Schemes in keiro-dsl: Maintainability and Performance"
description: Evaluate shared expression folds and combined analyses in keiro-dsl, and define the evidence needed to justify adoption and any performance claim.
timestamp: "2026-09-28T00:18:52Z"
researchId: RES-19
status: active
scope: Source-based assessment of recursion schemes in the keiro-dsl toolchain, focused on typed scalar expressions, existing type folds, and the distinction between tooling and generated-service performance; no prototype or comparative benchmark has been run.
sources:
  - resource: ../../keiro-dsl/src/Keiro/Dsl/TypeGraph.hs
    title: Existing type-expression algebra, folds, and dependency-graph traversal
  - resource: ../../keiro-dsl/src/Keiro/Dsl/Expression.hs
    title: Typed scalar expression representation and contextual type resolution
  - resource: ../../keiro-dsl/src/Keiro/Dsl/Scaffold.hs
    title: Expression analysis, imports, operators, and Haskell generation
  - resource: ../../keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs
    title: Equality identity collection used by replay-fold fingerprints
  - resource: ../../keiro-dsl/src/Keiro/Dsl/SemanticContract.hs
    title: Existing shared service analyses
  - resource: ../../keiro-dsl/bench/parser-scaling/Main.hs
    title: Existing parser, workspace, service-check, and generation benchmarks
  - resource: https://hackage-content.haskell.org/package/recursion-schemes-5.2.2.5/docs/Data-Functor-Foldable.html
    title: Published recursion-schemes API reference
---

# Recursion Schemes in keiro-dsl: Maintainability and Performance

## Research question and current conclusion

Would using recursion schemes make `keiro-dsl` easier to maintain and faster to run?

Selective adoption is a promising maintainability improvement. The strongest candidate is
the family of analyses over `TypedScalarExpr`. A shared fold could centralize traversal,
and a combined analysis could collect several facts in one visit. Performance improvement
remains a hypothesis: replacing each recursive function with a separate fold preserves the
number of traversals, and abstraction can introduce allocation or change evaluation demand.

This is an active research note. The evidence is source inspection at Keiro commit
`2d7eb940be5b2c77a8ae1967420d887f439d9612` and the published library API reference. No
implementation comparison, timing result, allocation measurement, or accepted architecture
decision is claimed here.

## What a recursion scheme would provide

A recursion scheme separates visiting recursive children from interpreting a constructor.
For a bottom-up fold, each constructor receives the results of folding its children. The
constructor-specific function is called an algebra; the general fold is a catamorphism.
The published [`cata` documentation](https://hackage-content.haskell.org/package/recursion-schemes-5.2.2.5/docs/Data-Functor-Foldable.html#v:cata)
describes this interface. Its `Recursive` abstraction can operate on an existing recursive
datatype through a representation of one layer, so adopting the library does not itself
require replacing a public datatype with `Fix`.

The technique can also be implemented as a small domain-specific fold, without adding a
package dependency. A fold centralizes recursive descent; each consumer remains responsible
for the meaning of each constructor. Catch-all algebra cases can still conceal missing
semantic handling when the language grows.

## Evidence in the current implementation

### Resolved types already have a shared fold

[`TypeGraph.hs`](../../keiro-dsl/src/Keiro/Dsl/TypeGraph.hs) defines
`TypeExprAlgebra a` and `foldTypeExpr :: TypeExprAlgebra a -> ResolvedTypeExpr -> a`.
The fold handles recursive container forms and delegates primitives, nominal leaves, and
named references to the supplied algebra. This is already a custom catamorphism.

Callers include validation, coverage, binding explanations, manifests, mapped compatibility
analysis, and scaffold generation. For example,
[`planMappedCodec`](../../keiro-dsl/src/Keiro/Dsl/MappedCodecPlan.hs) uses the fold to
collect schema authorities. This gives a local precedent for extending the technique.
Merely replacing this working fold with a library call has no demonstrated benefit.

### Typed scalar expressions repeat useful analyses

[`Expression.hs`](../../keiro-dsl/src/Keiro/Dsl/Expression.hs) represents a typed
expression as a `TypedScalarExpr` carrying a resolved type, location, and `TypedScalarNode`.
Binary nodes contain recursive expressions; literals, roots, and projections are leaves.

[`Scaffold.hs`](../../keiro-dsl/src/Keiro/Dsl/Scaffold.hs) already centralizes immediate
children in `typedExpressionChildren`, but several consumers still own their recursive
walks: `typedExpressionLiterals`, `typedExpressionLiteralTypes`,
`typedExpressionImportTypes`, `typedConsumerLiteralNominals`, `typedGeneratedNominals`,
and `anyTypedExpression`. Operator collection also traverses expressions while distinguishing
predicate and term contexts. The transducer import logic invokes several of these analyses
over the same resolved expressions.

[`equalityIdentities`](../../keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs) separately
enumerates the typed constructors and recursively collects nominal equality identities.
Its inspection of a comparison operand's type means a shared fold must preserve access to
child metadata, or synthesize the required metadata alongside each child result.

These are concrete duplication and repeated-work candidates. Their contribution to total
tooling time has not been measured.

### Some useful sharing already exists

`resolvedGeneratedTransitions` in `Scaffold.hs` creates an inventory intended for reuse by
import analysis, projection planning, and emission.
[`CheckedService`](../../keiro-dsl/src/Keiro/Dsl/SemanticContract.hs) also stores shared,
lazily evaluated type-graph resolution and projection-supply analysis. An experiment should
build on these owners and verify reuse at call sites. Reconstructing a combined analysis
independently in every consumer would surrender much of the intended benefit.

## Candidate scope and alternatives

| Area | Potential benefit | Constraint |
|---|---|---|
| Existing `ResolvedTypeExpr` fold | Established model for centralized recursion | A library substitution needs a separate justification |
| Typed-expression fact collection | Less traversal code and fewer repeated visits | Preserve metadata, ordering, context, and evaluation demand |
| Expression rendering | Shared descent may reduce duplicated constructor handling | Precedence, associativity, and term/predicate contexts remain explicit |
| Expression type resolution | A richer fold could express inherited expected types | Bidirectional and sibling-dependent resolution makes the first experiment harder |
| Named type dependency analysis | Reuse of summaries may reduce repeated graph work | Tree folds do not automatically preserve graph sharing or memoize references |

The alternatives worth comparing are:

1. **Existing implementation.** Keep the current recursive functions as the behavioral
   and performance baseline.
2. **Shared typed-expression fold.** Introduce a small internal fold while retaining
   separate analyses. This isolates the maintainability benefit and abstraction cost.
3. **Shared fold with combined facts.** Produce and reuse an `ExpressionFacts` value for
   consumers that need several analyses together. Candidate facts are literal and root
   types, nominal requirements, operator requirements, and literal flags.
4. **Library-backed folds.** Use a base functor and `Recursive` instances when several
   traversals demonstrate enough benefit to justify the dependency and extra representation.
   Compare this against the custom fold using the same analyses.

Prefer alternatives 2 and 3 for the initial experiment. Keep locations and resolved types
available at every node. Preserve the existing distinction between guard imports and write
imports: naming an unnecessary type can produce an unused import in generated code, which
is checked with warnings treated as errors. Operator summaries must likewise preserve the
term/predicate distinction, including operators introduced when a Boolean term is rendered
as a predicate.

The referenced library documentation establishes available concepts and APIs. No dependency
version or bound is selected by this note. If alternative 4 is pursued, locate dependency
sources through Mori and verify the current Hackage release and upstream release tags
before choosing bounds.

## Where the model needs more care

`resolveScalarExpr` passes expected types into arithmetic and literals, and `resolvePair`
can use one operand's inferred type to resolve the other. A fold returning only a completed
typed child is insufficient for those dependencies. A function-valued algebra can carry
expected-type context, but must preserve retries, error accumulation, diagnostic order,
and locations. Its readability should be assessed separately after the simpler analyses.

Named references in `TypeGraph` are graph edges. Resolution rejects cycles and computes
reachability using explicit maps, sets, and visited-state tracking. Recursively expanding
each reference into a tree could duplicate shared declarations. Any optimization here
needs an explicit graph algorithm and an account of the size of its required outputs;
ordinary tree folding supplies neither automatically.

Pretty printing and Haskell emission also carry context. A fold can synthesize a document
with precedence information or return a function of rendering context. That is feasible,
but preserving exact output and keeping the renderer easy to read are the criteria for
adoption.

## Performance hypotheses and limits

For a tree with `n` nodes and constant work at each node, both direct recursion and a
catamorphism take `O(n)` time. Running `k` complete analyses separately visits roughly
`k * n` nodes; a combined traversal can reduce that overhead while still performing the
semantic work of all requested analyses. For fixed `k`, both remain linear under those
assumptions. List concatenation, set operations, and rendering costs must be accounted for
separately; changing the recursion mechanism does not eliminate them.

Three hypotheses are testable:

- **H1 — maintenance:** a shared fold reduces duplicated recursive descent and makes
  omissions easier to detect when a constructor is added.
- **H2 — tooling performance:** computing and reusing several facts together reduces
  generation time or allocation on services with substantial expression analysis.
- **H3 — abstraction cost:** the shared fold itself has acceptable time, allocation, and
  build costs compared with the current direct recursion.

Combining facts can force more work than a short-circuiting `anyTypedExpression` caller
needs. Retaining a facts record can increase residency. Strict result records, temporary
base-functor layers, and closures can affect allocation and compiler optimization. Preserve
specialized searches when they serve callers that need only an early Boolean answer.

`keiro-dsl` parses, checks, and emits Haskell. An internal refactor that produces identical
Haskell provides no expected speedup in the generated service's request processing, event
replay, or workflow execution. Runtime improvements would require a separate change to
emitted code or runtime algorithms and their own measurements.

## Proposed experiment and acceptance evidence

Compare the baseline, shared-fold variant, and combined-facts variant independently. Add
the library variant only if its maintenance value warrants evaluation. Keep the experiment
focused on typed-expression analysis so differences have an identifiable cause.

Use existing conformance inputs plus fixtures that vary expression depth, balanced versus
skewed shape, and the number of expressions at a fixed aggregate count. Include arithmetic,
Boolean nesting, nominal comparisons, projections, and literal-heavy expressions. Include
both full fact consumption and an early-match predicate to expose demand changes.

Measure two levels:

1. **Focused analysis:** fully consume the required facts for prebuilt, forced expression
   inputs, with fresh analysis work on each sample. Measure time and allocation; merely
   forcing the outer result constructor does not establish the cost of the analysis.
2. **Toolchain workload:** measure service checking and generation with complete generated
   text consumed. The existing
   [`keiro-dsl-parser-bench`](../../keiro-dsl/bench/parser-scaling/Main.hs) includes
   service-check and scaffold-planning groups, and
   [`process-scaling`](../../keiro-dsl/bench/process-scaling/Main.hs) consumes generated
   text lengths. They provide surrounding workloads, but dedicated expression fixtures
   are needed to isolate this hypothesis.

Record the source revision, compiler, optimization settings, machine, fixture dimensions,
sampling method, and uncertainty for each variant. Keep setup outside focused measurements,
avoid accidentally timing reuse of an already evaluated result, and run repeated comparisons
under the same conditions. Measure residency when facts are retained, and report build-time
cost if introducing generated base functors or a dependency. Investigate profiles or compiler
output when a measured regression needs explanation.

Before accepting the refactor, demonstrate:

- Identical analysis results, including ordered lists, deduplication behavior, and
  context-dependent requirements; every current expression constructor is covered.
- Identical generated Haskell, import lists, fingerprint inputs and outputs, and
  relevant diagnostics and source locations.
- Passing relevant existing DSL and generated conformance checks.
- A maintenance comparison showing which recursive cases disappear and what a new
  constructor requires in each variant, including catch-all cases that could hide work.
- Performance results that distinguish a focused improvement from its end-to-end effect.
  A neutral result can support a maintainability change; it cannot support a speed claim.

Do not select an arbitrary speedup target before establishing measurement noise and the
analysis share of total runtime. A significant regression in realistic workloads should
prompt a smaller scope, different evaluation strategy, or retention of the existing walk.

## Open questions and recommendation

The remaining questions are how much time expression analyses consume, which facts are
usually needed together, where a shared result should live, and whether a custom algebra
remains clearer than base-functor machinery as expression forms grow. The right evaluation
strategy also depends on how often callers benefit from short-circuiting.

Start with a domain-specific fold over `TypedScalarExpr`, then evaluate a reusable facts
analysis at the generation-planning boundary. Assess maintainability and measured costs
separately. Broader adoption in contextual resolution, rendering, or graph analysis should
follow evidence from those individual areas.

This note is governed by the repository's [research profile](profile.dhall), derived from
`mori://shinzui/okf-profiles/profiles/research-documents`. It extends the discussion of
consistent graph traversal in [RES-15](14-structural-consumer-type-tradeoffs.md). Existing
parser measurements and their limited scope are recorded in
[Plan 229](../plans/229-eliminate-repeated-suffix-scans-from-keiro-dsl-source-span-capture.md);
those measurements do not establish the outcome of this proposed experiment.
