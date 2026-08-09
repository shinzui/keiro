---
id: 225
slug: make-read-model-query-inputs-and-results-checked-mapped-types
title: "Make read-model query inputs and results checked mapped types"
kind: exec-plan
created_at: 2026-08-09T20:45:30Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md"
---

# Make read-model query inputs and results checked mapped types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a candidate-language-5 read model can declare the real Haskell types of its
query input and result with checked mapped type expressions. Generated `ReadModel q r` values and
create-once query holes compile against those exact types instead of placeholder `()` aliases. A
fixture can query by a consumer-owned `AccountLookup` and return `Optional AccountSummary`, proving
the generated API, imports, and application-owned query function agree.

The feature does not claim to model SQL storage. Read-model columns retain their closed PostgreSQL
shape vocabulary and continue to drive version/shape identity. DDL, row codecs, query bodies, and
the correspondence between SQL rows and the declared result remain consumer responsibilities.
Mapped query types are compile-time API consumers; changing them never becomes event history,
queue history, snapshot, projection-replay, or table-migration impact.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: generate one deterministic read-model query-contract module from the checked
  input/result expression pair and MP-35's shared Haskell type plan.
- [ ] Milestone 2: wire generated `ReadModel q r` and new create-once query holes to the contract,
  including an explicit legacy-hole migration path.
- [ ] Milestone 3: classify query input/result evolution and semantic impact without contaminating
  SQL shape or projection catalog fingerprints.
- [ ] Milestone 4: compile query fixtures and mutations, document the ownership boundary, remove
  the read-model pending diagnostic, and pass full validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Generate query type aliases in a generated contract module, not in the create-once
  holes module.
  Rationale: Type expressions are DSL-owned and must regenerate when declarations change. Query
  function bodies are application-owned and must never be overwritten. Putting both in one file
  would force one owner to violate the other.
  Date: 2026-08-09

- Decision: Lower query expressions to consumer domain Haskell types without generating a JSON or
  SQL codec.
  Rationale: `ReadModel q r` passes Haskell values to an application transaction. Structural JSON
  authority and SQL row decoding are different boundaries; generating either conversion here
  would invent behavior absent from the source.
  Date: 2026-08-09

- Decision: Exclude query type identity from read-model table shape and projection-catalog runtime
  fingerprints.
  Rationale: The existing shape describes persisted columns and the catalog fingerprint describes
  operational projection inventory. Query API changes require recompilation but do not alter
  stored rows, target preparation, or replay semantics by themselves.
  Date: 2026-08-09

- Decision: Preserve an absent query contract as the legacy create-once alias path.
  Rationale: Existing sources and hole modules must remain byte-compatible. Adoption is explicit
  candidate syntax followed by a reviewed one-time hole edit, not an implicit rewrite.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on
[Plan 223](223-register-the-mapped-consumer-surface-contract-in-candidate-language-5.md), which
defines the atomic `ReadModelQueryTypes` grammar/AST and query roots. It also depends on the
completed MP-34 semantic impact and service structural conformance. Consume Plan 223's shared
resolved Haskell type/import plan; do not create another renderer in `Scaffold.hs`.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` currently emits three relevant artifacts. A generated table
module exposes the qualified SQL table name. A generated read-model module imports query aliases
and a query function from a create-once `ReadModelHoles` module and constructs
`ReadModel QueryInput QueryResult`. The holes module contains:

```haskell
type ExampleQueryInput = ()
type ExampleQueryResult = ()

exampleQuery :: ExampleQueryInput -> Tx.Transaction ExampleQueryResult
```

Because the whole holes module is create-once, scaffolding cannot safely replace those aliases
when a source adopts checked query types. The scaffold record/sidecar machinery from
`ScaffoldRecord`, `WorkspaceRecord`, `SidecarNames`, and ADR 0022 already records additive
obligations and generated roles; use it to report the one-time application edit.

`Grammar.RmColumn` stores PostgreSQL-facing name, type token, and requiredness.
`ReadModelShape.canonicalShape` hashes those columns. `Keiro.ReadModel.ReadModel q r` is typed at
runtime, but neither the registry nor projection catalog serializes `q` or `r` identity.
`ProjectionOwnerNode` and `ReadModelNode.rmGroup/rmObservedTargets` relate query models to catalog
targets independently of query value types.

[ADR 0026](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
separates query contracts, physical targets, groups, and projection handlers and leaves SQL
unchecked. [ADR 0022](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
governs generated versus create-once ownership and additive history.
[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
governs mapped domain identity and imports; its JSON binding laws remain service conformance, not a
claim about SQL. [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires complete lowering before the pending error is removed. No cross-repository ADR specifies
Keiro's query type syntax.


## Plan of Work

Milestone 1 adds a generated module role such as
`Generated.<Context>.<ReadModel>.QueryContract`. From the checked input and result
`ResolvedTypeExpr`s, render deterministic aliases named `<Stem>QueryInput` and
`<Stem>QueryResult`. Use the shared type occurrence/import plan, including nested optional/list/map
types and mapped consumer modules. Do not import bindings, fixtures, generated structural shape
types, Aeson, or Hasql codecs merely because the domain type has a structural declaration.

Generate the module before planning dependents and include it in the Cabal fragment, module
provenance, scaffold report, and workspace ledger. A legacy read model with no explicit contract
must not receive this module and must retain exact current bytes.

Milestone 2 changes the generated read-model module to import aliases from `QueryContract` and only
the query function from `ReadModelHoles`. For a newly scaffolded typed read model, create a holes
module that imports both aliases and declares only the function implementation. For an existing
create-once legacy holes module, refuse to overwrite it and render a typed migration obligation
showing the old alias declarations that must be removed and the generated contract import that
must be added. Never parse or rewrite application Haskell automatically.

The generated contract is the single source of type identity used by `ReadModel q r`, the query
function signature, the service facade, and conformance. Preflight all module path/import
collisions before writing. Remove `MappedReadModelLoweringPending` only when standalone and
workspace scaffolds both use this path.

Milestone 3 extends semantic compatibility. A query-root mapped wire/binding/canonical change
names the read model and whether it is input or result. The compatibility vector requests consumer
and caller builds; changing the result is an API result change and changing the input is a caller
input change. It sets no persisted event/job/snapshot flags and does not change `rmShape`,
`ReadModelShape.deriveShapeHash`, catalog fingerprint, target reset/replay policy, or replay impact.

Store query contract identities and mapped consumer closure additively in single/workspace scaffold
records so removing the whole clause remains visible. MP-34's semantic impact report must call the
read model a consumer even when no aggregate consumes the same declaration. A legacy record with
no query-contract row reports baseline unavailable rather than inferring `()`.

Milestone 4 adds candidate-language single/workspace fixtures with direct, nested, shared, and
unused mapped declarations. Compile a hand-owned query returning a fixture domain value. Mutate an
imported type, delete one query clause, alter a nested mapping, and leave a stale legacy alias;
each must fail at its correct frontend, check, or GHC/conformance boundary. Update read-model and
typed-toolchain guidance without claiming SQL proof.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori registry show shinzui/keiro --full
rg -n 'emitReadModelGen|emitReadModelHoles|ReadModelShape|QueryInput|QueryResult|rmColumns' \
  keiro-dsl/src keiro-dsl/test docs/user
```

Run focused generation, diff, workspace, and compiled tests:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='mapped read model query'
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='query contract migration'
cabal test keiro-dsl:keiro-dsl-conformance-readmodel-runtime
bash keiro-dsl/test/diff-test.sh
```

Before closure, run:

```bash
cabal build all
cabal test keiro-dsl:tests
cabal run -v0 keiro-dsl-corpus-regen -- check
scripts/check-conformance-corpus.sh
just check-adr
git diff --check
git status --short
```

Expected evidence includes a compiled non-`()` query API, a safe migration report for a retained
legacy holes file, and no generated changes for read models without the new clauses.


## Validation and Acceptance

A complete query contract generates one role-bearing contract module with the exact consumer
domain types and deterministic imports. `ReadModel`, its query hole, service build inventory, and
conformance agree on those aliases. Nested containers and shared mapped declarations compile
without duplicate/conflicting imports.

Deleting either source clause fails before lowering; changing a mapped declaration names exactly
the affected read models and query positions. It does not change SQL column shape/hash/version,
projection catalog fingerprint, target/group inventory, replay impact, event/queue bytes, fold
fingerprints, or snapshots. Two read models sharing a result type are both named; an unrelated
read model is absent.

Adopting an explicit contract over an existing create-once holes file never overwrites it. The
report gives an actionable migration obligation, and compilation remains red until the application
imports the generated aliases and removes its placeholder declarations. The next scaffold is
idempotent once the hand edit is complete.

Legacy read models remain byte-identical. Focused/full DSL and workspace tests, compiled read-model
conformance, diff tests, corpus policy, ADR validation, and diff hygiene pass.
`MappedReadModelLoweringPending` is gone.


## Idempotence and Recovery

Query-contract generation is pure and safe to repeat. All collision and create-once ownership
checks occur before writes. A failed migration preflight leaves the generated tree, holes module,
and ledger unchanged. Re-running after the application-owned import edit produces the same
generated bytes and no repeated migration obligation.

Never recover by overwriting `ReadModelHoles`, parsing arbitrary Haskell, or folding query types
into the SQL shape hash. An author can remove the candidate query clauses to return to the legacy
path before release, but must review any generated contract module reported stale; the scaffolder
does not delete it automatically.


## Interfaces and Dependencies

No new dependency. Use Plan 223's resolved Haskell type/import interface and the existing sidecar
role/ledger machinery. Generated output must be equivalent to:

```haskell
module Generated.Example.AccountSummary.QueryContract
  ( AccountSummaryQueryInput
  , AccountSummaryQueryResult
  ) where

import Domain.Account (AccountLookup, AccountSummary)

type AccountSummaryQueryInput = AccountLookup
type AccountSummaryQueryResult = Maybe AccountSummary
```

The application-owned module imports these aliases and implements:

```haskell
accountSummaryQuery
  :: AccountSummaryQueryInput
  -> Tx.Transaction AccountSummaryQueryResult
```

Ledger/report types need a stable query-position discriminator rather than a rendered string,
conceptually `QueryInputConsumer Name | QueryResultConsumer Name`. They must reuse MP-34's
`MappedConsumer` and `SemanticImpactSnapshot` extension points.
