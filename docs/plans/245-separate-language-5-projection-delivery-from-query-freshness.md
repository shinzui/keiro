---
id: 245
slug: separate-language-5-projection-delivery-from-query-freshness
title: "Separate Language 5 projection delivery from query freshness"
kind: exec-plan
created_at: 2026-08-12T12:12:50Z
intention: "intention_01kzty1w82ey5vg2b86nkw83sk"
master_plan: "docs/masterplans/38-finalize-projection-ownership-and-query-freshness-before-stable-language-5.md"
---

# Separate Language 5 projection delivery from query freshness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Stable Language 5 reads like the system it generates. A projection owner says when its
handlers apply events with `delivery = inline | subscription`. A query model says whether
the query runs now or waits for its supplying subscription with
`freshness = immediate | wait-for-head ...`. A catalog-managed read model no longer
repeats a `feed`, subscription name, or generic `Strong`/`Eventual` claim. Generated code
derives delivery and cursor identity from Plan 243's validated owner/query relation and
uses Plan 244's truthful runtime façade.

Users can see the separation in source, diagnostics, scaffold ledgers, diff output, and
compiled harness facts. An inline owner with an immediate query checks and performs no
cursor wait. A subscription owner with an immediate query explicitly accepts lag. A
subscription owner with a category head wait resolves exactly one durable cursor. An
inline owner with a head wait is rejected with a capability explanation. Released
Languages 1-4 continue to parse, validate, render, diff, and scaffold their historical
`feed`, `consistency`, and `scope` forms byte-for-byte.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: add version-gated semantic types and parse/pretty-print Language 5 `delivery` and `freshness`; focused parser/profile/round-trip checks passed (2026-08-12T21:51:03Z), and M4's final Languages 1-4 corpus gate later confirmed zero drift.
- [x] M2: replace keyword-pair validation with owner/cursor capability validation and generate Plan 244's honest runtime builders; the 17-example catalog group covers every positive and DSL-representable negative row (2026-08-12T21:51:03Z).
- [x] M3: diff, scaffold-ledger, harness, workspace, and fingerprint consumers expose separate delivery/freshness/cursor facts; all 39 corpus entries regenerated with drift confined to three candidate suites, and the four positive rows plus fact mutations compile and pass (2026-08-12T22:03:26Z).
- [x] M4: updated references, migration/diagnostics guides, examples, research annotations, changelogs, improvement requests, and ADRs; all documentation checks and `just verify` passed, closing MasterPlan 38 (2026-08-12T22:19:52Z).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Planning audit (2026-08-12): `ReadModelNode` currently stores `rmFeed`,
  `rmSubscription`, `rmConsistency`, and optional `rmScope`, while
  `ProjectionOwnerNode` separately stores `poFeed` and its subscription identity. Merely
  renaming tokens would retain two authorities. The semantic graph needs a legacy-supply
  variant for Languages 1-4 and an owner-derived variant for Language 5.
- Planning audit (2026-08-12): the inner aggregate `projection` clause is intrinsically
  inline and predates the catalog. For Language 5 it can act as an implicit standalone
  inline owner, but it cannot satisfy `wait-for-head`; subscription-maintained models must
  use a top-level catalog owner so cursor identity has one authority.
- Implementation (2026-08-12): the first category-head generation test exposed an
  application-precedence bug: `headWaitingReadModel CategoryVisibleHead "category"`
  parsed as three arguments. Parenthesizing the `CategoryVisibleHead` value fixed the
  emitted Haskell before corpus regeneration, while the entire-log constructor remained
  atomic.
- Implementation (2026-08-12): allocating the all-stream/entire-head row to a second
  owner in the existing mixed-source `reporting` group passed DSL validation but failed
  runtime catalog validation with `AmbiguousSourceOrdering`. The DSL now mirrors that
  closed-world rule as `CatalogAmbiguousSourceOrdering`, so generated catalogs cannot
  defer this invalid source combination until module initialization.


## Decision Log

Record every decision made while working on the plan.

- Decision: Freeze the Language 5 spellings as owner `delivery` and query `freshness`,
  with values `inline`, `subscription`, `immediate`, and `wait-for-head`.
  Rationale: they name scheduling/application and waiting directly, and candidate Language
  5 can still be corrected before publication under ADR 0016.
  Date: 2026-08-12
- Decision: Language 5 read models never declare `feed` or `subscription`; catalog-managed
  models derive both from the resolved owner, and a legacy inner aggregate projection is
  treated as an implicit inline-only owner.
  Rationale: retaining a read-model delivery field would preserve the duplicate authority
  IR-24 exists to remove. An async standalone model has no catalog cursor authority and
  must migrate to a projection owner.
  Date: 2026-08-12
- Decision: The Language 5 syntax has no static `wait-for-position` form.
  Rationale: position waiting is a caller-specific read-your-write override using the
  append result. A source-level default without a target is immediate under the old API
  and would reintroduce an invalid state.
  Date: 2026-08-12
- Decision: Normalize legacy and new source into separate semantic axes while retaining a
  legacy-supply constructor for rendering Languages 1-4.
  Rationale: downstream validation/generation needs truthful concepts, but byte-compatible
  released rendering requires retaining which frozen surface produced them.
  Date: 2026-08-12
- Decision: Pin the four positive capability rows across the existing compiled candidate
  fixtures: projection-catalog owns inline/immediate and subscription/immediate,
  mapped-readmodel owns subscription/entire-head, and declarative-router owns
  subscription/category-head.
  Rationale: these are already primary candidate conformance packages, so the matrix is
  compiled without creating a synthetic grammar-only lane.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

M1 and M2 are complete. Language 5 now has one delivery authority on each projection
owner and one freshness policy on each query model. Released syntax lowers through an
explicit legacy supply value, allowing old parsing/rendering/generation to remain on its
historical path. Checked generation uses only `ReadModelBlueprint`,
`immediateReadModel`, or `headWaitingReadModel`, with cursor identity derived from the
resolved supplier. Focused validation proves compatible whole-store/category waits and
rejects inline, implicit, missing-cursor, and unreachable-category waits before
generation.

M3 is complete. Separate `ProjectionDeliveryChanged` and `QueryFreshnessChanged` diff
codes, ledger rows, harness facts, workspace facts, and canonical catalog/slice inputs now
track the two policies independently. A 39-entry regeneration changed only
`conformance-declarative-router`, `conformance-mapped-readmodel`, and
`conformance-projection-catalog`; their compiled tests cover inline/immediate,
subscription/immediate, subscription/category-head, and subscription/entire-head.
Hand-owned conformance mutations prove freshness, resolved cursor authority, and delivery
facts each fail independently, while the 17-example focused suite proves whitespace and
declaration order do not alter normalized identity.

M4 and this ExecPlan are complete. ADRs 0016 and 0026 now freeze the candidate syntax and
single-owner semantics, while ADR 0032 records how checked Language 5 populates the
already-revised canonical freshness/cursor identity. The API, typed-spec, read-model,
capability, authoring, migration, research-history, improvement-request, and changelog
surfaces distinguish delivery from freshness and label every retained old term as released
compatibility or history. `just verify` passed 508 runtime examples, 58 PGMQ examples (two
pre-existing pending), 38 operations examples, all 43 DSL suites including 701 core DSL
examples, 23 Jitsurei examples, 28 migration examples, strict documentation/policy gates,
and the 39-entry zero-drift conformance corpus. The plan leaves no remaining implementation
or release-documentation gap.


## Context and Orientation

Repository root is the `keiro` multi-package repository. Language versions are selected in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`; ADR 0016 records Languages 1-4 as published
and Language 5 as the amendable candidate. Parser entry points receive a
`FrontendContext`/`EffectiveLanguageContract`, so the new grammar must be selected by
capability rather than by the installed package version.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` currently defines shared `Consistency = Strong |
Eventual`, `RmFeed = RmInline | RmSubscription`, `RmScope`, `ReadModelNode`, and
`ProjectionOwnerNode`. `Parser/ReadModel.hs` requires, in order, `consistency`, optional
`scope`, `feed`, optional `subscription`, then optional Language 5 group/targets/backing.
`Parser/ProjectionCatalog.hs` requires owner `feed`. `Parser/Aggregate.hs` optionally
parses `consistency` on the older inner projection clause.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` currently memorizes keyword pairs: `Strong` plus
inline fails; scope without `Strong` fails; inline subscription warns; and an inline read
model must be named by an aggregate projection. Plan 243 replaces the last rule with the
authoritative owner/query relationship. This plan replaces the remaining pair rules with
capability checks. `Scaffold.hs` currently emits runtime `defaultConsistency`,
`strongScope`, and `subscriptionName`; Plan 244 provides truthful builders so new generated
code does not mention those fields.

Every semantic consumer must move together: `PrettyPrint.hs`, `Diff.hs`,
`ScaffoldRecord.hs`, `Harness.hs`, `ScaffoldRun.hs`, `WorkspaceScaffold.hs`, type-graph and
impact/explanation modules, test fixtures, and the compiled conformance corpus. The
canonical runtime inventory and slice format bump is owned by Plan 244; this plan populates
those fields but does not create another fingerprint encoder.

Relevant ADRs are
`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
(versioned parsing and immutable released behavior),
`docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md`
(normalized behavior/fingerprint discipline),
`docs/adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md`
(compiled generated facts),
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(owner/query/target separation),
`docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
(cursor policy), and
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
(canonical freshness identity from Plan 244). The originating consumer is
`mori://tan/notification-render-service`; no external ADR applies.


## Plan of Work

### Milestone 1 — Versioned grammar and normalized semantics

Add a candidate-only language capability for the separated projection/query policy in
`LanguageVersion.hs`. Do not key code directly on numeric version 5. In `Grammar.hs`, add
semantic types equivalent to:

```haskell
data ProjectionDelivery = DeliveryInline | DeliverySubscription
data QueryFreshnessNode
  = FreshnessImmediate
  | FreshnessWaitForHead RmScope
data ReadModelSupply
  = LegacyReadModelSupply RmFeed (Maybe Text)
  | OwnerDerivedSupply
```

Replace `ReadModelNode`'s independent consistency/scope/feed/subscription fields with
`rmFreshness` and `rmSupply`. Replace `ProjectionOwnerNode.poFeed` with `poDelivery`.
Retain the legacy constructor and source locations so published sources can render exactly
as before. Parser code for Languages 1-4 consumes the historical token order and lowers
`Eventual` to immediate, `Strong` plus scope to head wait, and feed/subscription to
`LegacyReadModelSupply`.

Candidate Language 5 parses:

```keiro
freshness = immediate
freshness = wait-for-head entire-log
freshness = wait-for-head category "notificationType"
delivery = inline
delivery = subscription
```

A Language 5 read model rejects `consistency`, `scope`, `feed`, and `subscription` with a
source-located migration diagnostic. A Language 5 projection owner rejects `feed` and
requires `delivery`. A Language 5 inner aggregate projection rejects its optional
`consistency`; the referenced read model owns freshness, and that implicit owner supports
only immediate inline reads. Add parser/pretty-print round trips for all new forms and
negative ownership cases. Run a frozen golden snapshot over Languages 1-4 before and after
the AST migration.

### Milestone 2 — Capability validation and runtime lowering

Extend Plan 243's resolved supplier facts with Plan 244's cursor capability. In
`Validate.hs`, implement the matrix:

| Supply capability | `immediate` | `wait-for-head` |
|---|---:|---:|
| inline-only owner | valid | invalid: no durable cursor |
| one compatible subscription cursor | valid, explicit possible lag | valid |
| zero or several cursor authorities | valid only if supply itself is unambiguous | invalid with candidates |
| legacy inner aggregate projection | valid | invalid |

For category head waits, require the resolved subscription source to cover the same
category. Entire-log waits require an all-stream-capable source; do not claim an aggregate
or unrelated category cursor can reach it. Diagnostics name the read model, projection
owner, delivery capabilities, requested scope, candidate subscriptions, and remedy. Sort
candidate identities; never select the first declaration.

In `Scaffold.hs`, emit Plan 244's `immediateReadModel` or `headWaitingReadModel` builder
with the cursor derived from the checked owner. Per-call position waiting remains available
through the runtime API and is not emitted as a static default. Update imports and generated
facade exports. Add compile/run fixtures for inline/immediate, subscription/immediate,
subscription/entire-head, subscription/category-head, per-call position wait, and all
negative matrix rows.

### Milestone 3 — All semantic consumers and identity evidence

Update `Diff.hs` with separate classifications such as `ProjectionDeliveryChanged` and
`QueryFreshnessChanged`. A delivery change is a projection lifecycle/wiring change; a
freshness or head-scope change is a query policy change. Legacy Language 1-4 diff wording
and severity remain frozen. Update scaffold ledgers, impact reports, explanations, and
`Harness.hs` to expose owner delivery, query freshness, and resolved cursor in distinct
facts. Add mutation tests that swap those facts or choose a cursor by order.

Populate Plan 244's `QueryModelBinding`/inventory freshness fields from the normalized
Language 5 graph. Prove a freshness-only edit changes query/catalog/slice identity but not
aggregate fold, event wire, or table-shape identity; prove a delivery edit changes owner
handler/lifecycle identity; prove whitespace and declaration reordering change neither.

Update single-file and workspace fixtures, the corpus index, scaffold snapshots, and every
compiled conformance package. Regenerate only candidate Language 5 artifacts. Run the
published-language baseline and policy gates to demonstrate zero Languages 1-4 drift.

### Milestone 4 — Documentation and release gate

Update the Language 5 reference, read-model/projection guide, API reference, diagnostics,
authoring examples, research-history annotations, and both package changelogs. Include a
mechanical candidate-source migration table:

```text
projection-owner feed = X       -> delivery = X
readmodel Eventual + any feed   -> freshness = immediate; remove feed/subscription
readmodel Strong + scope        -> freshness = wait-for-head <scope>; derive cursor
standalone async readmodel      -> declare target/group/projection-owner subscription
inner projection consistency   -> freshness on its readmodel (immediate only)
```

Amend ADR 0026 with the single-owner concepts and ADR 0016 with the finalized candidate
surface. Coordinate ADR 0032 wording/prefixes with Plan 244 and the reachable-head ADR with
Plan 238. Search documentation and generated candidate artifacts for misleading new uses
of “inline eventual consistency” or generic “strong consistency”; historical/deprecation
sections may retain old terms only when labeled. Run all focused checks and `just verify`,
then update this plan and MasterPlan 38 with actual results.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-dsl-test --test-option=--match --test-option="freshness"
cabal test keiro-dsl-test --test-option=--match --test-option="projection owner"
cabal test keiro-dsl-test --test-option=--match --test-option="language compatibility"
just corpus-regen
just conformance-corpus-policy
rg -n "inline.*[Ee]ventual|[Ss]trong consistency" docs keiro-dsl/test keiro-dsl/src
just adr-validate
just verify
```

The focused runs must report zero failures. Review each search hit: compatibility and
history may explain deprecated words, but current Language 5 examples and generated code
must use delivery/freshness terminology. Corpus regeneration may alter candidate entries
only; the policy gate must finish with zero drift. Record actual suite counts and final
verification output during implementation.


## Validation and Acceptance

Acceptance requires:

1. A Language 5 inline owner plus immediate query checks without read-model feed or
   subscription declarations. Generated `runQuery` performs no cursor wait.
2. A subscription owner plus immediate query checks and documentation explicitly says it
   may read stale data without waiting.
3. A subscription owner plus matching category/entire-log head wait resolves exactly one
   cursor, captures the requested visible head, and retains typed timeout behavior.
4. An inline-only or implicit aggregate owner plus head wait fails before generation. A
   mismatched category, zero cursors, or multiple cursors produces deterministic candidates
   and no positional choice.
5. Caller-supplied `WaitForPosition` provides read-your-write for an async owner without a
   static Language 5 position target.
6. Reordering owners, queries, targets, or observed targets changes neither generated
   cursor selection nor normalized identity.
7. Delivery and freshness edits produce separate diff/ledger/harness facts and correct
   impact classification. A freshness-only edit does not change fold, event-wire, or
   table-shape identity.
8. New generated Haskell imports and invokes only Plan 244's truthful façade; no candidate
   snapshot contains the legacy constructor/field names.
9. Languages 1-4 retain byte-identical parse/check/pretty/scaffold/diff/corpus behavior,
   including old invalid diagnostics and accepted record shapes.
10. At least one compiled catalog fixture covers each positive matrix row, and mutations
    of delivery, freshness, or cursor facts make conformance fail.


## Idempotence and Recovery

Parser, generation, and validation changes are repeatable and have no database side
effects. Keep both legacy and separated semantic constructors until all consumers compile;
do not regenerate corpus snapshots while some consumer still projects old fields. If a
candidate fixture cannot migrate cleanly, add an explicit negative/migration test rather
than weakening owner/cursor validation. Runtime catalog prefix adoption and active-run
recovery belong to Plan 244 and must use its supported preview/adopt path.


## Interfaces and Dependencies

The normalized DSL surface must expose equivalents of:

```haskell
data ProjectionDelivery
  = DeliveryInline
  | DeliverySubscription

data QueryFreshnessNode
  = FreshnessImmediate
  | FreshnessWaitForHead RmScope

data ReadModelSupply
  = LegacyReadModelSupply RmFeed (Maybe Text)
  | OwnerDerivedSupply

data ReadModelNode = ReadModelNode
  { ...
  , rmFreshness :: QueryFreshnessNode
  , rmSupply :: ReadModelSupply
  , rmGroup :: Maybe Name
  , rmObservedTargets :: [Name]
  , rmBackingTarget :: Maybe Name
  }

data ProjectionOwnerNode = ProjectionOwnerNode
  { ...
  , poDelivery :: ProjectionDelivery
  , poSubscription :: Maybe Text
  }
```

Exact constructor names may be refined, but semantic ownership is fixed: only the legacy
constructor retains read-model delivery/subscription data; new Language 5 uses
`OwnerDerivedSupply`. Language-aware pretty-printing must distinguish them without
reconstructing source syntax from freshness alone.

Plan 243 supplies the deterministic query-to-owner relation. Plan 244 supplies
`QueryFreshness`, cursor authority, builders, execution functions, and canonical inventory
fields without changing the `QueryModelBinding` record. Plan 238 supplies the visible-head
implementation. This plan consumes all three and owns no alternative resolution, wait loop,
or fingerprint serializer.
