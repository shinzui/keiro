---
id: 35
slug: make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption
title: "Make mapped types first-class across queues, read models, and projections before fleet adoption"
kind: master-plan
created_at: 2026-08-09T20:45:21Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
---

# Make mapped types first-class across queues, read models, and projections before fleet adoption

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

After this initiative, a candidate-language-5 service can reuse the same checked mapped type in
three additional consumer families without hand-copying its Haskell type or JSON policy. A
workqueue payload field may carry a mapped type expression and its generated queue codec uses the
declared structural or opaque mapping authority. A read model may declare checked query input and
result expressions instead of receiving placeholder `()` aliases. Aggregate-owned projections and
projection-catalog owners derive mapped dependencies from their authoritative aggregate event
sources, so a mapped event change names every real projection consumer without requiring a second,
drift-prone type annotation.

The feature is complete only when `check`, generation, conformance, coverage, `diff`, scaffold
history, and impact reports all consume one extended `TypeGraph`/`SemanticImpact` model. Queue
payload changes are classified as persisted-job wire hazards; read-model query changes are
consumer-build/API hazards; projection changes follow the aggregate event history and catalog
rebuild surfaces they actually consume. A source that uses languages 1 through 4 retains its
released syntax and generated meaning byte-for-byte. Candidate language 5 gains the new syntax in
place because it remains explicitly unpublished.

Correctness remains stricter than convenience. The queue codec has one declared wire authority,
all mapped declarations keep the total binding and fixture laws from MP-34's service-level
structural conformance, and every new root kind is handled exhaustively. SQL columns, DDL,
migrations, row codecs, query bodies, and projection handler bodies remain application-owned.
Read-model SQL column types are not reinterpreted as mapped domain types. Category/all projection
sources remain heterogeneous and hand-decoded; the DSL does not claim a mapped dependency without
a typed aggregate source. Public contract DTO mapping, refined/partial bindings, automatic queue
upcasting, target-scoped SQL capabilities, package release, and downstream fleet rewrites are out
of scope.

This MasterPlan is the adoption-blocking follow-up to
[MasterPlan 34](34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md).
MP-34 must complete first because it defines the semantic-impact, source-stability, structural
conformance, and reporting extension points this initiative extends. Keiro is not ready for the
planned twenty-service adoption until both MP-34 and this MasterPlan pass their final qualification
plans.

The planning estimate is 20–29 engineer-days for one experienced Keiro maintainer: EP-1 3–4,
EP-2 4–6, EP-3 3–5, EP-4 3–4, EP-5 4–6, and EP-6 3–4. After MP-34, the queue, read-model, and
projection work streams can proceed in parallel, giving roughly 12–18 working days elapsed before
review and release coordination. The estimate includes one final candidate-language corpus
refresh, compiled conformance, and restoring mutation tests, but no service migration.


## Decomposition Strategy

EP-1 freezes the candidate-language source contract and the typed root algebra before any emitter
changes. EP-2, EP-3, and EP-4 then implement independently verifiable consumer families: persisted
queue payloads, typed read-model queries, and projection dependency derivation. EP-5 integrates all
new roots into the MP-34 semantic-impact, conformance, coverage, diff, scaffold, and ledger
authorities. EP-6 is the only plan that refreshes the complete committed corpus and decides whether
fleet adoption is permitted.

The boundaries follow ownership rather than file layout. Queue payloads own a versioned persisted
JSON envelope and therefore need their own compatibility and codec proof. Read-model `q`/`r` types
are compile-time query contracts while the SQL schema remains migration-owned. Projection inputs
are already owned by an aggregate event stream or by a heterogeneous decoder; they need dependency
derivation, not another free-form type spelling. Combining all three generators in one plan was
rejected because a queue wire regression, query API regression, and projection inventory regression
require different evidence and rollback guidance. Adding independent closure calculations to each
generator was rejected because MP-34 exists specifically to establish one semantic authority.

[ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) freezes
languages 1–4 and permits correction of unpublished candidate 5 in place. EP-1 adds one explicit
syntax capability to candidate 5; it does not allocate language 6 or add an aggregate-fold runtime
segment. [ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires one resolved mapping graph, total bindings, explicit opaque boundaries, and exhaustive
folds. [ADR 0013](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
requires each persisted surface to report its real evidence instead of contributing to a false
global percentage.

[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) separates
single-spec validity, cross-version compatibility, runtime assembly, and historical evidence.
[ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) keeps the
new queue/read-side conformance inventory behind one service facade.
[ADR 0026](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
keeps query models, targets, groups, and handlers distinct and says that SQL bodies remain
unchecked. Its motivating cross-repository ownership decision is
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`. Mori searches found no separate cross-repository ADR
for mapped queue payloads, query types, or projection source typing.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Register the mapped consumer-surface contract in candidate language 5 | [Plan 223](../plans/223-register-the-mapped-consumer-surface-contract-in-candidate-language-5.md) | None | None | Complete |
| 2 | Generate mapped workqueue payloads with honest persisted-wire compatibility | [Plan 224](../plans/224-generate-mapped-workqueue-payloads-with-honest-persisted-wire-compatibility.md) | EP-1 | None | Complete |
| 3 | Make read-model query inputs and results checked mapped types | [Plan 225](../plans/225-make-read-model-query-inputs-and-results-checked-mapped-types.md) | EP-1 | None | Complete |
| 4 | Derive projection mapped consumers from authoritative event sources | [Plan 226](../plans/226-derive-projection-mapped-consumers-from-authoritative-event-sources.md) | EP-1 | None | Not Started |
| 5 | Extend semantic impact conformance and evolution reporting to every mapped surface | [Plan 227](../plans/227-extend-semantic-impact-conformance-and-evolution-reporting-to-every-mapped-surface.md) | EP-2, EP-3, EP-4 | None | Not Started |
| 6 | Qualify the complete mapped consumer surface before fleet adoption | [Plan 228](../plans/228-qualify-the-complete-mapped-consumer-surface-before-fleet-adoption.md) | EP-5 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The completed MP-34 is a hard prerequisite for every implementation plan here. Its Plan 217
defines `SemanticImpact`, Plan 218 separates service-wide structural laws from consumer-specific
evidence, and Plan 221 defines semantic report/ledger projections. If those final types differ
from the planned interfaces, update this MasterPlan before beginning EP-1 rather than implementing
a compatibility shadow model.

EP-1 is the internal foundation. It registers the candidate-language syntax gate, introduces
surface-aware resolved root identities, and freezes which positions are explicit versus derived.
EP-2, EP-3, and EP-4 hard-depend on that vocabulary but not on one another. They can proceed in
parallel: EP-2 owns queue wire lowering, EP-3 owns read-model query signatures, and EP-4 owns
projection-source dependency derivation.

EP-5 hard-depends on all three consumer plans because it migrates global coverage, semantic impact,
diff, reports, and ledgers from the old three-root world to the complete new inventory. It may not
land temporary report fields for only one surface. EP-6 hard-depends on EP-5 and owns the
cross-surface mutation matrix, exact generated-tree baselines, documentation, and one complete
corpus regeneration. The critical path is MP-34 -> EP-1 -> max(EP-2, EP-3, EP-4) -> EP-5 -> EP-6.


## Integration Points

**Candidate language contract (EP-1 defines; every later plan consumes).** Candidate language 5
gains a named syntax capability for mapped consumer surfaces. Queue typed-field and read-model
query clauses are rejected under languages 1–4 at the frontend feature boundary. Projection
dependency derivation changes no source spelling. EP-1 must amend ADR 0016 or add a successor ADR
that records the final source contract and candidate-only rule.

**Explicit roots and derived consumers (EP-1 defines; EP-2 through EP-6 extend or consume).**
`Keiro.Dsl.TypeGraph.UseSite` becomes exhaustive across explicit aggregate fields/registers,
workqueue fields, and read-model query input/result positions. MP-34's `MappedRoot` and
`MappedConsumer` extend that vocabulary with aggregate-inline and catalog-aggregate projection
relations, without fabricating projection `UseSite` values. Explicit type-expression roots carry
`MappedKey`; derived projection consumers retain the exact event-root paths they inherit. There is
one transitive closure and one rendering vocabulary.

**Queue payload authority (EP-2 defines; EP-5 and EP-6 observe).** Existing lower-case
`text`/`int`/`bool` queue fields retain their grammar and bytes. Candidate language 5 adds a colon
form with a full checked `TypeExpr`. Structural mappings lower through the declared generated shape
and total binding; opaque mappings stay explicitly opaque. Queue diff classifies already-enqueued
jobs separately from event history and snapshots.

**Read-model query contract (EP-3 defines; EP-5 and EP-6 observe).** Optional language-5
`query input = <TypeExpr>` and `query result = <TypeExpr>` clauses replace create-once placeholder
aliases only when present. They type the generated `ReadModel q r` API and query hole. They do not
describe SQL columns, target storage, projection writes, or migration ownership.

**Projection consumers (EP-4 defines; EP-5 and EP-6 observe).** An aggregate inline projection
and a catalog owner with `source = aggregate A` consume A's generated event sum and inherit A's
mapped private-event roots. Category and all-history owners continue to use explicit hand-owned
decoders and have no fabricated mapped root. Read models become projection-impact observers through
catalog target/group relations, not through hidden SQL inspection.

**Evolution, conformance, and history (EP-5 defines; EP-6 verifies).** MP-34's service structural
module continues to own declaration laws exactly once. Queue codecs receive surface-specific
roundtrip/wire assertions; read-model query and projection consumers receive compile/inventory
assertions. Coverage JSON, semantic-impact snapshots, scaffold reports, and diff JSON add new
surface-tagged roots without changing existing event/snapshot compatibility meanings.

**Corpus and adoption gate (EP-6 owns).** EP-6 alone refreshes affected candidate-language
generated fixtures after all emitters settle. Published-language corpora remain byte-stable. No
package release or fleet rollout occurs, but adoption remains blocked until the new candidate
surface passes exact byte locality, restoring mutations, and full repository verification.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: register candidate-language syntax and one exhaustive external-consumer root algebra.
- [x] EP-1: freeze explicit queue/query positions and derived projection ownership with ADR/tests.
- [x] EP-2: parse, validate, and generate mapped workqueue payload expressions and codecs.
- [x] EP-2: classify queue wire evolution and prove structural/opaque payload conformance.
- [x] EP-3: generate checked read-model query input/result types without placeholder aliases.
- [x] EP-3: prove query API evolution, workspace composition, and SQL ownership boundaries.
- [ ] EP-4: derive aggregate-inline and catalog projection consumers from event-source authority.
- [ ] EP-4: prove category/all sources remain honestly heterogeneous and projection impact is local.
- [ ] EP-5: integrate every root into semantic impact, coverage, reports, ledgers, and conformance.
- [ ] EP-5: mutation-test independent queue, query, projection, event, and snapshot classifications.
- [ ] EP-6: pass cross-surface exact-tree, compatibility, and restoring-mutation qualification.
- [ ] EP-6: refresh the candidate corpus once, publish adoption guidance, and close both gates.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- At EP-1 start, `WqField.wqfType` was an unlocated `Name` restricted to lower-case `text`, `int`,
  or `bool`; queue mapping was a real persisted-codec feature, not an existing root waiting to be
  enumerated.
- `ReadModel q r` was already typed at runtime, but generated `ReadModelHoles` declared both types
  as `()` because the DSL carried no query type expressions. SQL columns are a separate closed
  storage vocabulary and must stay separate.
- Projection catalogs already retain typed aggregate sources. Aggregate sources can inherit mapped
  event dependencies exactly, while category/all sources intentionally cross a total hand-owned
  decoder and cannot honestly name one mapped event type.
- Candidate language 5 is registered but unpublished. ADR 0016 explicitly permits correcting its
  syntax profile in place while languages 1–4 remain immutable.
- EP-1 showed that the old queue parser was syntactically wider than strict language-4 semantics:
  preserving unknown legacy identifiers explicitly was necessary to keep predecessor parse/pretty
  behavior unchanged while adding the candidate colon form.
- Nested consumer roots need outer container segments in addition to their first mapped key.
  Keeping those segments beside `UseSite` preserves stable root identities and complete rendered
  paths without fabricating intermediate declarations.
- A subscription-only projection catalog exposed an unconditional generated inline-projection
  import. Conditioning both inline and async imports on the actual owner inventory kept warnings
  fatal in the candidate suite without changing mixed-catalog bytes.
- Query-contract adoption needs an explicit ledger baseline marker. An absent row in an older
  ledger cannot distinguish a genuine legacy `()` hole from lost current history, so both
  standalone and workspace reports now say that the baseline is unavailable instead of guessing.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Make this a separate follow-up to MP-34 and a second fleet-adoption prerequisite.
  Rationale: MP-34 is an architectural locality refactor over existing roots; adding queue and
  read-side type syntax changes the language, generated APIs, and compatibility surface. Keeping
  them separate preserves reviewability while completing both before downstream adoption.
  Date: 2026-08-09

- Decision: Amend unpublished candidate language 5 rather than allocate language 6.
  Rationale: ADR 0016 defines registration and publication separately. No external consumer is
  authorized to depend on language 5 yet, so correcting its candidate feature set is the stable
  pre-adoption action; languages 1–4 remain frozen.
  Date: 2026-08-09

- Decision: Add explicit mapped syntax only where the source owns a type expression; derive
  projection consumers from typed event-source ownership.
  Rationale: Queue payload fields and read-model query positions are actual type slots. Projection
  handlers already receive the event type selected by the aggregate/catalog source. Repeating an
  arbitrary projection type would create two authorities and permit an unsound mismatch.
  Date: 2026-08-09

- Decision: Keep SQL storage types and heterogeneous category/all decoding outside mapped roots.
  Rationale: The DSL cannot infer arbitrary SQL row codecs or prove one domain type covers a
  heterogeneous event category. Unsupported boundaries must remain visible instead of receiving
  false structural coverage.
  Date: 2026-08-09

- Decision: Perform one final candidate corpus regeneration in EP-6.
  Rationale: Queue, read-model, projection, conformance, and reporting emitters overlap. A single
  reviewed refresh after interfaces settle minimizes planning-induced golden churn before fleet
  adoption.
  Date: 2026-08-09

- Decision: Use unprefixed semantic field names in new records and retain prefixes only on existing
  record APIs.
  Rationale: `keiro-dsl` already enables `DuplicateRecordFields`, and focused modules can use
  type-directed record access. New fields such as `input`, `result`, `consumer`, and `authority`
  are clearer than type-name prefixes. Renaming existing `rm*`, `wq*`, or `po*` selectors would be
  unrelated source churn and remains out of scope. Record selector spelling is Haskell
  presentation only; it never enters DSL identity, wire keys, fingerprints, or serialized schemas.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-1 is complete. Candidate syntax ownership, located queue/query roots, the common consumer type
plan, derived projection relations, and fail-closed downstream gates are now landed and documented.
The existing generated corpus remained unchanged, so EP-2, EP-3, and EP-4 are dependency-ready.

EP-2 is complete. Candidate mapped workqueues share the aggregate mapped-codec lowering authority,
compile against closure-local consumer imports, preserve required-field and schema-v1 envelope
semantics, and report queued-job history separately from events and snapshots. A focused candidate
suite and restoring mutations cover structural, opaque, nested, and explicit-`Json` boundaries;
the released scalar queue and aggregate codec corpus remains byte-stable. EP-3 and EP-4 remain
independently dependency-ready.

EP-3 is complete. Candidate read models now generate one DSL-owned query-contract module and keep
only the transaction body application-owned. Standalone and workspace ledgers retain explicit,
baseline-aware input/result identities; legacy holes receive a reviewed migration obligation and
are never rewritten. Query API changes are consumer-build breaking but leave SQL shape, catalog
identity, persisted history, snapshots, and replay neutral. A compiled domain query plus four
restoring mutations proves direct, nested, shared, unused, and stale-alias behavior. EP-4 remains
dependency-ready.
