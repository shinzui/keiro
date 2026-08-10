---
id: 223
slug: register-the-mapped-consumer-surface-contract-in-candidate-language-5
title: "Register the mapped consumer-surface contract in candidate language 5"
kind: exec-plan
created_at: 2026-08-09T20:45:30Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md"
---

# Register the mapped consumer-surface contract in candidate language 5

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, Keiro has one source and semantic contract for mapped types outside aggregate
fields. Candidate-language-5 parsing recognizes an explicit typed workqueue field and an explicit
read-model query input/result pair, resolves every referenced mapped declaration, and records
surface-aware roots. Languages 1 through 4 reject the first new token with a version-gate
diagnostic, while every existing queue and read model retains its prior AST meaning.

This foundation also freezes projection typing: an aggregate inline projection and a projection
catalog owner with an aggregate source inherit the generated aggregate event type. They do not
accept a redundant free-form mapped type. Category/all sources remain heterogeneous decoder
boundaries. Until Plans 224 and 225 deliver generation, `check` reports a stable candidate-only
“lowering pending” error for the corresponding new positive form, so no accepted service can reach
an incomplete scaffold path.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: register the mapped-consumer syntax capability only in unpublished language 5
  and freeze predecessor rejection/registry behavior. (2026-08-10T04:43:41Z)
- [x] Milestone 2: add source/AST forms for typed queue fields and complete read-model query
  contracts with canonical pretty-print round trips. (2026-08-10T04:43:41Z)
- [x] Milestone 3: resolve explicit mapped roots and projection-source relations into one
  exhaustive surface vocabulary with stable diagnostics. (2026-08-10T04:43:41Z)
- [x] Milestone 4: add safe temporary lowering refusals, publish the contract in ADR/docs, and
  pass frontend/check tests without changing existing generated corpora. (2026-08-10T04:43:41Z)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The released queue parser accepted an arbitrary identifier into the AST even though strict
  language-4 validation closed the supported vocabulary to `text`, `int`, and `bool`. Preserving a
  `QueueOther Name` constructor keeps old parse/pretty behavior exact while allowing the new
  candidate colon form to be structurally distinct.
- A `UseSite` names the first mapped declaration but cannot itself retain outer containers such as
  `List (Optional T)`. `TypeGraph.tgRootSegments` records those segments beside the stable root key,
  and `usePaths` prepends them before declaration-internal paths.
- The plan named a nonexistent `just check-adr` recipe. The repository recipe is
  `just adr-validate`; its underlying strict OKF command passed with 28 concepts.


## Decision Log

Record every decision made while working on the plan.

- Decision: Amend candidate language 5 in place and leave languages 1–4 immutable.
  Rationale: Language 5 is registered but explicitly unpublished. ADR 0016 permits correcting an
  active candidate before external adoption and forbids widening a published predecessor.
  Date: 2026-08-09

- Decision: Spell a typed queue field as `name -> "wire" : TypeExpr`; retain the existing
  lower-case primitive form unchanged.
  Rationale: The colon creates an unambiguous candidate-only boundary and avoids reinterpreting
  legacy `text`, `int`, or `bool` tokens as mapped declaration names.
  Date: 2026-08-09

- Decision: Represent read-model query input and result as one optional pair.
  Rationale: `ReadModel q r` requires both types. A semantic AST with only one half would admit a
  state generation cannot lower honestly; the located surface parser may diagnose a missing half
  before constructing `ReadModelQueryTypes`.
  Date: 2026-08-09

- Decision: Projection typing is derived from aggregate source ownership, not declared again.
  Rationale: Generated aggregate projections already consume the aggregate event union, and
  catalog aggregate sources already select that type. A second annotation could disagree with the
  handler signature and create two semantic authorities.
  Date: 2026-08-09

- Decision: Add no aggregate-fold runtime capability or fingerprint segment.
  Rationale: The new syntax changes queue/query/projection consumer compilation and queue wire
  behavior, not aggregate decision or replay semantics. Those impacts have their own typed
  surfaces and must not invalidate unrelated aggregate snapshots.
  Date: 2026-08-09

- Decision: New record types use unprefixed semantic selectors; existing AST selectors retain
  their current names.
  Rationale: The package already enables `DuplicateRecordFields`. Focused records read more clearly
  as `input`/`result` or `consumer`/`authority`, while renaming existing `rm*`, `wq*`, and `po*`
  selectors would create unrelated source/API churn.
  Date: 2026-08-09

- Decision: Preserve unknown legacy queue scalar identifiers explicitly instead of narrowing the
  parser while adding the candidate form.
  Rationale: Languages before strict surface closure accepted those identifiers syntactically.
  `QueueOther` retains their AST and canonical rendering, while language-4 validation continues to
  reject them exactly as before.
  Date: 2026-08-10

- Decision: Keep existing untagged aggregate consumer identities and tag only new consumer
  families in semantic-impact JSON.
  Rationale: Existing scaffold/workspace ledgers must remain byte-compatible. Prefixes for
  workqueues, read models, and the two projection forms are unambiguous without rewriting any
  aggregate snapshot row.
  Date: 2026-08-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Candidate language 5 now owns the queue colon and atomic read-model query-pair syntax. The parser,
AST, pretty-printer, resolved graph, nested path expansion, common `ConsumerTypePlan`, and
event-authority-derived projection relations are implemented. Category/all projection sources are
visible unsupported boundaries rather than fabricated consumers. Queue and query use remains
fail-closed through the two planned pending-lowering diagnostics.

Languages 1 through 4 retain their feature sets and legacy queue/read-model behavior. The full DSL
suite passed, the 35-invocation corpus check reported every generated artifact unchanged, strict
OKF validation passed, and `git diff --check` is clean. ADR 0012 and ADR 0016 now carry the durable
authority and language-version decisions. Plans 224–226 may consume this foundation without
inventing parallel type rendering or projection ownership.


## Context and Orientation

This plan must begin only after
[MasterPlan 34](../masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md)
is complete. In particular,
[Plan 217](217-define-one-checked-semantic-impact-model-for-keiro-dsl-consumers.md) will define the
final `SemanticImpact` extension point. Reconcile this plan's interface examples with that landed
type before editing; do not create a parallel impact model.

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` currently declares languages 1–4 as published and
language 5 as the sole candidate. Candidate 5 selects the syntax profile containing
`ProjectionCatalogSyntax`. A `LanguageFeature` is a named parser capability; source selection
rejects a feature that its exact profile does not contain.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` represents a workqueue payload field as `WqField` with
`wqfType :: Name`. `keiro-dsl/src/Keiro/Dsl/Parser/Queue.hs` parses only lower-case `text`, `int`,
or `bool` in practice, and `Validate.validateWorkqueue` rejects anything else under strict
semantics. A read model stores SQL columns, version/shape, consistency, feed, and catalog binding,
but no query types. `Scaffold.emitReadModelHoles` therefore creates both `QueryInput` and
`QueryResult` as `()`.

`keiro-dsl/src/Keiro/Dsl/Parser/Mapped.hs` already owns recursive `pMappedTypeExpr`, and
`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` resolves those expressions into `ResolvedTypeExpr`. Its
`UseSite` currently records aggregate command fields, private-event fields, and registers only.
In this plan an **explicit root** is a source position that directly contains a mapped
`TypeExpr`; a **derived consumer relation** says that another generated component consumes an
already-typed root, such as a projection handler receiving an aggregate event.

`Grammar.ProjectionSpec` names an aggregate inline projection table, key, and status map. It has no
independent event type because its generated handler consumes `<Aggregate>Event`.
`ProjectionOwnerNode` similarly selects `CatalogAggregate`, `CatalogCategory`, or `CatalogAll`.
Only `CatalogAggregate` has a statically known generated event union. This distinction follows
[ADR 0026](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md).

[ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) governs
candidate mutation and predecessor immutability. [ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires one checked graph and exhaustive folds. [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires a clean `check` to imply complete lowering, which is why this plan includes a temporary
fail-closed diagnostic. [ADR 0013](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
forbids pretending unsupported sources have mapped evidence. Mori searches found no external ADR
for these source spellings or root types.


## Plan of Work

Milestone 1 adds `MappedConsumerSurfaceSyntax` (or an equally explicit final name) to
`LanguageFeature` and to candidate 5's exact syntax profile only. Do not allocate a language 6,
change `currentStableLanguageVersion`, or add a runtime/fold capability. Add registry and parser
tests proving versions 1–4 still reject the new colon/query clauses, candidate 5 accepts their
owned tokens, and syntax/runtime profile identifiers remain stable except for the intentional
candidate syntax-profile content.

Milestone 2 changes the semantic grammar without erasing legacy queue syntax. Introduce a sum
equivalent to `LegacyQueueScalar QueueScalar | TypedQueueExpression TypeExpr`; give `WqField` an
exact `Loc`. In `Parser.Queue`, parse the existing no-colon lower-case form exactly as before and
gate `: pMappedTypeExpr` through the candidate feature at the colon span. Update `PrettyPrint` so
legacy fields retain lower-case output and typed fields print a canonical colon plus `TypeExpr`.

Add `ReadModelQueryTypes {input, result}` and an optional `queryTypes` field on `ReadModelNode`.
Candidate syntax inside the read-model block is exactly:

```text
query input = AccountLookup
query result = Optional AccountSummary
```

Both clauses are required together, in that order in canonical output. The located frontend emits
a stable missing-half diagnostic rather than lowering a partial pair. Existing read models with no
query clauses remain valid and retain hand-owned placeholder aliases until Plan 225.

Milestone 3 extends `TypeGraph` with explicit workqueue-field, read-model-query-input, and
read-model-query-result roots. Resolve the complete expression, not just a direct `TRef`, so a
root such as `List (Optional AccountSummary)` produces paths through its containers. Put exhaustive
rendering/key/surface functions in one module with incomplete-pattern warnings as errors.

At the same boundary, add one pure `ConsumerTypePlan` that lowers a `ResolvedTypeExpr` to its
consumer-facing Haskell type occurrence, deterministic imports, and transitive mapped
dependencies. It handles primitives, containers, structural references, and opaque references,
but deliberately carries no JSON, SQL, or runtime codec. Plan 224 composes it with JSON
encode/parse authority; Plan 225 consumes it directly. This prevents the queue and read-model
emitters from inventing separate type/import renderers.

Define projection relations in the semantic-impact vocabulary rather than fabricating
`TypeExpr`s: an aggregate inline projection inherits that aggregate's private-event roots, and
each `ProjectionOwnerNode` with `CatalogAggregate A` inherits A's private-event roots. Do not
inherit command-only or register-only roots. A category/all source records an unsupported typed
source boundary for reporting but has no mapped path.

Milestone 4 adds temporary `MappedQueueLoweringPending` and `MappedReadModelLoweringPending`
semantic errors for candidate sources using the new explicit forms. Plans 224 and 225 remove their
respective error only when their complete check/generation/diff paths land. Existing sources and
derived projection relations do not trigger the errors. Amend ADR 0016 and ADR 0012 (or create one
focused successor) with the source and root ownership decisions, and update the language reference.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori registry show shinzui/keiro --full
rg -n 'LanguageFeature|profileV4|WqField|pWqField|ReadModelNode|UseSite|collectUseSites' \
  keiro-dsl/src keiro-dsl/test
```

Run focused frontend and graph tests:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='mapped consumer surface'
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='language registry'
```

Before closure, run:

```bash
cabal build keiro-dsl
cabal test keiro-dsl:keiro-dsl-test
cabal run -v0 keiro-dsl-corpus-regen -- check
just adr-validate
git diff --check
git status --short
```

The candidate positive `check` fixtures must fail only with the intended pending-lowering code;
predecessor fixtures fail at the feature gate, and the existing corpus check reports no drift.


## Validation and Acceptance

A language-5 queue field `payload -> "payload" : JobPayload` parses, pretty-prints, reparses, and
resolves a workqueue root with the field location and mapped key. A nested expression retains all
container segments. The same colon form under language 4 fails with `LanguageFeatureRequiresVersion`
at the colon rather than becoming an unknown legacy type.

A language-5 read model with both query clauses constructs one `ReadModelQueryTypes` value and two
explicit roots. Missing either clause produces a stable located frontend/check error. A read model
without the pair is semantically equal to its pre-change form and keeps the legacy generated path.

An aggregate inline projection inherits only the mapped event roots of its aggregate. A catalog
aggregate owner inherits the same roots and records its projection identity. Neither inherits a
mapped command that is never persisted, nor a mapped register that is absent from the event sum.
Category/all sources produce no mapped declaration consumer and remain visibly unsupported.

Until downstream generation lands, a source using an explicit queue/query form cannot pass
`check` and therefore cannot scaffold. Existing language-1–5 sources, generated fixtures, fold
fingerprints, queue bytes, and read-model modules are unchanged. Focused tests, full DSL tests,
corpus policy, ADR validation, and diff hygiene pass.


## Idempotence and Recovery

Parser, resolver, and relation derivation are pure. Repeated parse/pretty/parse and root derivation
must be byte/determinism stable. The temporary lowering diagnostics are explicit tracked gates;
do not bypass them in scaffold code. If a later plan changes the agreed syntax before publication,
update this plan, candidate fixtures, and ADR text together rather than accepting aliases.

No corpus regeneration is authorized. If a test changes generated files, inspect the corpus
driver and restore only recognized generated outputs after confirming no consumer-owned file was
touched. Never alter published language profiles to make a candidate test pass.


## Interfaces and Dependencies

No external dependency or bound change. Reuse the existing parser, `containers`, and resolved
mapped graph. The semantic interfaces must be equivalent to:

```haskell
data QueuePayloadType
  = LegacyQueueScalar QueueScalar
  | TypedQueueExpression TypeExpr

data ReadModelQueryTypes = ReadModelQueryTypes
  { input :: !TypeExpr
  , result :: !TypeExpr
  }

data UseSite
  = RootCommandField Name Name Name MappedKey
  | RootEventField Name Name Name MappedKey
  | RootRegister Name Name MappedKey
  | RootWorkqueueField Name Name MappedKey
  | RootReadModelQueryInput Name MappedKey
  | RootReadModelQueryResult Name MappedKey

data DerivedMappedConsumer
  = AggregateInlineProjectionConsumer Name Name
  | CatalogProjectionConsumer Name Name

data ConsumerTypePlan = ConsumerTypePlan
  { haskellType :: !HaskellTypeOccurrence
  , imports :: ![ImportRequirement]
  , dependencies :: !(Set MappedKey)
  }

planConsumerType
  :: TypeGraph
  -> ResolvedTypeExpr
  -> Either ConsumerTypePlanError ConsumerTypePlan
```

The exact constructors may be refined after reconciling MP-34's landed `SemanticImpact`, but the
information and exclusions are fixed: legacy versus typed queue syntax, an atomic query pair,
complete nested root paths, event-only projection inheritance, and no fabricated category/all or
SQL-column mapping. New focused records use semantic fields such as `input`, `result`, `imports`,
and `dependencies`. Existing prefixed selectors are not renamed. Keep these records in focused
modules and use typed patterns or record-dot access where duplicate labels would make a selector
function ambiguous; selector spelling must not enter any serialized or generated identity.


## Revision Notes

- 2026-08-10: Recorded the landed AST/root refinements, corrected the ADR validation recipe, and
  closed all milestones with full-suite, corpus, and strict-OKF evidence.
