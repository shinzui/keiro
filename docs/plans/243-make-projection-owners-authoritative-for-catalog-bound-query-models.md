---
id: 243
slug: make-projection-owners-authoritative-for-catalog-bound-query-models
title: "Make projection owners authoritative for catalog-bound query models"
kind: exec-plan
created_at: 2026-08-12T12:12:50Z
intention: "intention_01kzty1w82ey5vg2b86nkw83sk"
master_plan: "docs/masterplans/38-finalize-projection-ownership-and-query-freshness-before-stable-language-5.md"
---

# Make projection owners authoritative for catalog-bound query models

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

One catalogued projection owner can transactionally supply any number of separately typed
query models over the targets it owns. A Language 5 service no longer needs a legacy inner
aggregate `projection <readmodel>` clause merely to convince validation that each inline
read model has a writer. The same closed-world rule applies to catalogs assembled directly
in Haskell: every catalog-bound query resolves by identity to one supplying projection,
and ambiguity or missing ownership is rejected before registration, execution, or code
generation.

The motivating proof is the shape from
`docs/improvement-requests/let-one-inline-projection-owner-supply-multiple-query-models.md`:
one aggregate-sourced inline owner writes `catalog_state`, `catalog_layouts`, and
`catalog_keys`, while validation and administration query models observe different subsets.
After this plan, that source checks, its generated catalog contains the handler once, both
query bindings resolve to the same projection ID and group, and command execution still
applies the owner once in the append transaction. Reordering owners, query models, or
observed targets does not change the result.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-08-12T12:41:56Z — M1: added the normalized `ResolvedQuerySupply`/handler-capability view, validated empty/split supplier diagnostics, and positive/negative `keiro-test` coverage. `cabal test keiro-test --test-option=--match --test-option="Keiro.Projection.Catalog"` passed 15 examples with 0 failures.
- [x] 2026-08-12T13:04:36Z — M2: added the shared `Keiro.Dsl.ProjectionSupply` analysis, made Language 5 catalog-bound read models resolve exactly one owner/group from their complete observed-target set, preserved the legacy aggregate reference rule outside catalog-bound Language 5, and added deterministic split-owner/legacy-conflict diagnostics. The focused language-5 projection-catalog suite passed 13 examples with 0 failures.
- [ ] M3: update generated catalog selection, scaffold plans/ledgers, diff facts, harness facts, workspace composition, and compiled conformance for one owner supplying several queries.
- [ ] M4: update guides, API reference, changelogs, ADR 0026, and ADR 0032 identity notes; run repository-wide verification and update MasterPlan 38.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Planning audit (2026-08-12): the runtime inventory already contains both sides needed
  to derive the relationship: `InventoryTarget.owner` and
  `InventoryQueryModel.observedTargets`. The resolution itself need not add an independent
  fingerprint field; tests must prove it changes whenever either authoritative input
  changes.
- Planning audit (2026-08-12): a programmatic `ProjectionDefinition` may contain several
  ordered handlers, including combinations the Language 5 `projection-owner` surface
  cannot spell. The normalized relation therefore retains handler capabilities rather
  than pretending every runtime projection has one delivery mode. Plan 244 decides which
  capability can satisfy a freshness wait.
- Milestone 1 (2026-08-12): `InventoryProjection.ownedTargets` still preserves declaration
  order, so reversing an otherwise set-valued owner target list changes the current
  `catalog-v2` and `slice-v1` hashes. ADR 0032 requires a prefix change for any correction
  to that canonical identity contract. The new supply resolver is order-independent, but
  the fingerprint correction is deferred to Plan 244's already-planned format bump rather
  than silently changing v2/v1 identity in this plan.
- Milestone 2 (2026-08-12): the existing candidate fixture declared both a top-level
  `projection-owner order_summary_writer` and an aggregate-local `projection order_inline`
  for the same catalog-bound query. Removing the legacy clause also removed the duplicate
  mapped-consumer fact; the catalog owner remains the sole mapped projection consumer and
  supplies the generated inline handler independently.


## Decision Log

Record every decision made while working on the plan.

- Decision: Resolve a query's supplier from the owners of all its observed targets; do not
  add a query-to-projection name reference.
  Rationale: target ownership is already the catalog authority under ADR 0026. A second
  explicit edge could drift from it and would make multi-target queries ambiguous in two
  different ways.
  Date: 2026-08-12
- Decision: A valid catalog-bound query has a non-empty observed-target set whose targets
  all have the same projection owner and rebuild group.
  Rationale: one supplier is required for deterministic delivery/cursor derivation. A
  query spanning several owners would need an explicit multi-cursor/freshness policy,
  which IR-24 deliberately does not invent for 0.12.
  Date: 2026-08-12
- Decision: Keep the runtime relation delivery-neutral by retaining a sorted list of
  handler capabilities.
  Rationale: programmatic catalogs can compose ordered handlers. Collapsing that into a
  single inline/async label would discard information or select by list order; Plan 244
  can accept immediate reads broadly and require one unambiguous async cursor for waits.
  Date: 2026-08-12
- Decision: In Language 5, reject a catalog-managed read model that is also named by a
  legacy aggregate `projection` clause.
  Rationale: accepting both would leave two declarations claiming to supply one logical
  model and make generated handler selection unclear. Languages 1-4 retain their frozen
  standalone behavior.
  Date: 2026-08-12
- Decision: Keep EP-1's derived supply relation invariant under owned-target order, but
  move canonical owned-target sorting into Plan 244's format-prefix revision.
  Rationale: the original plan assumed the current canonical inventory already normalized
  owner target order. It does not. Correcting that preimage without a prefix would violate
  ADR 0032; Plan 244 already owns the next catalog/slice/contract/replay formats and can
  include the correction with explicit adoption evidence.
  Date: 2026-08-12
- Decision: Publish the pure DSL supply analysis as `Keiro.Dsl.ProjectionSupply` and map
  only relation-owned failures to new query diagnostics.
  Rationale: validation, scaffold planning, workspace planning, diff, and harness code all
  need the same normalized owner/query record. Existing target/group validators remain the
  primary source for missing/multiple owner and malformed group claims, which avoids
  redundant query-level noise while split valid owners and legacy double ownership receive
  precise query diagnostics with related owner/clause locations.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Repository root is the `keiro` multi-package repository. A *query model* is a logical,
typed `ReadModel q r`; a *target* is an application-owned PostgreSQL table; a *rebuild
group* is the lifecycle/fence unit; and a *projection owner* is the single catalog
projection identity that owns one or more targets and contains ordered live handlers.
The *supplying relationship* is the normalized fact that one query model observes targets
owned by one projection in the same group. It does not imply that the query's generated
SQL reads every observed target; Plan 234's backing target remains the one physical table
used to construct `ReadModel`.

The runtime types and validation live in `keiro/src/Keiro/Projection/Catalog.hs`.
`QueryModelBinding` carries a `ReadModel`, a rebuild group, and observed targets.
`ProjectionDefinition` carries one projection ID, group, owned targets, replay policy,
and a non-empty ordered handler list. `collectProjectionFacts` and `collectQueryFacts`
normalize these values. `validateProjectionCatalog` currently verifies missing/multiple
target owners and query membership in a group, then `buildInventory` records each target's
owner and each query's observed targets. It does not expose or validate the stronger
single-supplier relation.

The DSL graph is in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`.
`ReadModelNode` carries `rmGroup`, `rmObservedTargets`, and `rmBackingTarget` alongside the
legacy `rmFeed`; `ProjectionOwnerNode` carries `poGroup`, `poTargets`, and `poFeed`.
`validateReadModel` in `keiro-dsl/src/Keiro/Dsl/Validate.hs` currently emits
`RmInlineFeedUnreferenced` unless an aggregate's singular `aggProjection` names the read
model. That test ignores top-level projection owners and creates IR-23. Owner validation,
catalog lowering, scaffold generation, and conformance facts are spread across
`Parser/ProjectionCatalog.hs`, `Scaffold.hs`, `ScaffoldRun.hs`,
`WorkspaceScaffold.hs`, `ScaffoldRecord.hs`, `Harness.hs`, and `Diff.hs`.

Completed Plan 234,
`docs/plans/234-bind-catalog-read-models-to-one-explicit-physical-target.md`, made backing
target resolution explicit and order-independent. This plan must reuse that resolver's
checked target identities and must not confuse backing (one generated table) with supply
(the owner of every observed target). Completed Plan 237,
`docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md`,
made target owner and query observed-target facts canonical and slice-scoped. This plan
does not change its format.

Relevant ADRs are
`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
(candidate-only semantic changes),
`docs/adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md`
(compiled generated facts),
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(identity and ownership authority), and
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
(the existing canonical facts and adoption boundary). The originating consumer is
`mori://tan/notification-render-service`; no cross-repository ADR is required.


## Plan of Work

### Milestone 1 — Runtime catalog resolution

In `keiro/src/Keiro/Projection/Catalog.hs`, add an exported normalized relation named
`ResolvedQuerySupply` and an exported accessor over a validated catalog. It contains the
query model ID, supplying projection ID, rebuild group ID, sorted observed targets, source
ID, and a deterministic ordered representation of the owner's handler capabilities. An
inline capability carries its handler name. An async capability carries handler name,
subscription ID/name, source, checkpoint-on-missing policy, and dedup identity. Do not
store closures or copy the query's backing target into this relation.

Build the relation from `ProjectionFacts`, query facts, and validated declarations by
identity maps. Extend `CatalogDiagnosticCode` with stable codes for an empty query target
set, a query whose target set resolves to no supplier, and a query spanning several
suppliers. Existing unknown-target, missing-owner, multiple-owner, and outside-group
diagnostics continue to fire at their existing claim sites; suppress redundant derived
diagnostics when a prerequisite identity is invalid. Sort diagnostics by the existing
stable rule and sort public resolution results by query model ID.

Add tests in `keiro/test/CatalogSpec.hs` for one owner/three targets/two queries, target
and declaration reordering, a subset-observing query, empty targets, split owners, mixed
groups, and a composed handler owner. Test both `validateProjectionCatalog` and the
resolved accessor. Show that changing a target owner or observed set changes the existing
catalog and group-slice fingerprints; adding only the derived accessor changes neither.

### Milestone 2 — DSL ownership authority

Create one checked owner/query resolver in the DSL validation layer (a small internal
module is preferred if `Validate.hs`, scaffold planning, and workspace planning otherwise
duplicate maps). For a Language 5 read model with `rmGroup`, resolve every named observed
target, require one top-level projection owner to own all of them in the same group, and
retain the resolved owner name in checked service/catalog planning. Do not select
`head`, `find` on source order, or the backing target as a proxy for the whole set.

Replace the catalog-managed branch of `RmInlineFeedUnreferenced` with this rule. Preserve
the old aggregate-clause rule for Languages 1-4 and for a genuinely standalone read model.
For candidate Language 5, add a stable diagnostic when a catalog-bound read model is also
named by an aggregate's inner `projection` clause, with both source locations and a remedy
that removes the legacy clause. Keep the standalone mechanism singular; this plan does
not generalize `aggProjection` into a list.

Add parser/check fixtures under `keiro-dsl/test/fixtures/` and focused assertions in
`keiro-dsl/test/Main.hs`. Positive evidence includes the exact multi-query inline owner
shape and a query observing a target subset. Negative evidence covers zero observed
targets, unknown targets, two owners, group mismatch, missing owner, and double ownership,
with deterministic diagnostics under declaration reordering.

### Milestone 3 — One relation in every generated consumer

Thread the checked relationship through `ScaffoldRun.hs`, `WorkspaceScaffold.hs`, and
`Scaffold.hs`. The generated `ProjectionCatalog` contains one projection definition and
several `SomeQueryModelBinding` values. Inline selection for command execution is by the
resolved projection ID/source, so multiple queries never duplicate the handler. Preserve
Plan 234's explicit backing-target selection for each generated `ReadModel`.

Update `ScaffoldRecord.hs` ledgers and `Harness.hs` facts to report query model → supplying
owner → group → observed targets separately from backing target. Update `Diff.hs` so a
supplier change is a projection/query binding change derived from target-owner facts, not
a read-model-feed spelling change. Add a mutation test that intentionally selects the
first owner or emits a handler per query and is caught by compiled conformance.

Regenerate affected candidate fixtures with `just corpus-regen`, update the corpus index,
and compile the service conformance packages. Languages 1-4 must have zero corpus drift.

### Milestone 4 — Durable documentation and closeout

Update `docs/user/read-models-and-projections.md`, `docs/user/api-reference.md`, the DSL
language reference, diagnostics reference, and the `keiro`/`keiro-dsl` changelogs. Amend
ADR 0026 to state that a catalog-bound query derives one supplier from target ownership.
Amend ADR 0032 only to note that the relation is derived from already canonical target
owner and observed-target facts; do not change its format prefixes in this plan. Run the
focused suites, ADR validation, corpus policy, and `just verify`, then update Plan 243 and
MasterPlan 38 progress with actual evidence.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-test --test-option=--match --test-option="projection catalog"
cabal test keiro-dsl-test --test-option=--match --test-option="projection owner"
cabal test keiro-dsl-test --test-option=--match --test-option="readmodel"
just corpus-regen
just conformance-corpus-policy
just adr-validate
just verify
```

The focused runs must report zero failures. `just corpus-regen` may change only candidate
Language 5 entries attributable to this plan, and the policy check must report zero drift
after regenerated artifacts are checked in. Record exact example counts and the final
`just verify` result in Progress/Surprises when implementing; do not copy stale counts
from earlier plans.


## Validation and Acceptance

Acceptance requires all of the following observable behavior:

1. A runtime catalog with one inline owner of three targets and two query bindings over
   different subsets validates. Both `ResolvedQuerySupply` values name the same projection
   and group, while command projection selection contains the handler once.
2. Reversing sources, targets, groups, projection sets, query bindings, owned targets, or
   observed targets yields the same resolution and canonical fingerprints.
3. Empty observed targets, missing owners, multiple owners, and cross-group supply fail
   with stable codes and identity-sorted claim sites before registration.
4. The equivalent Language 5 source checks and compiles without any inner aggregate
   `projection` clause. Adding that clause produces the double-ownership diagnostic.
5. A multi-target query's backing target remains explicit and may be only one member;
   supplier resolution still evaluates the full observed set.
6. A composed programmatic owner retains all handler capabilities; no accessor silently
   picks the first handler.
7. Compiled harness facts prove each query's supplier and prove there is only one generated
   live handler. Mutating owner selection or duplicating the handler makes the suite fail.
8. Published Languages 1-4 keep byte-identical parse, check, pretty-print, scaffold, diff,
   and corpus outputs.
9. Catalog and slice fingerprints change when authoritative owner/observed facts change,
   but no canonical prefix or migration changes merely because the derived accessor exists.


## Idempotence and Recovery

All source generation and test commands are repeatable. The plan adds no database
migration and performs no catalog adoption. If an intermediate runtime/DSL API change
breaks generation, keep the old fields as internal adapters until every consumer has
moved; do not weaken validation or regenerate golden files from a partially checked graph.
Corpus regeneration is accepted only after focused semantic tests pass, and unrelated
dirty files must remain untouched.


## Interfaces and Dependencies

`Keiro.Projection.Catalog` must export an equivalent of:

```haskell
data ProjectionHandlerCapability
  = InlineCapability Text
  | SubscriptionCapability
      { handlerName :: Text
      , subscriptionId :: SubscriptionId
      , subscriptionName :: Text
      , sourceId :: SourceId
      , checkpointOnMissing :: MissingCheckpointPolicy
      , dedupKeyId :: DedupKeyId
      , dedupName :: Text
      }

data ResolvedQuerySupply = ResolvedQuerySupply
  { queryModelId :: QueryModelId
  , projectionId :: ProjectionId
  , rebuildGroupId :: RebuildGroupId
  , observedTargets :: NonEmpty TargetId
  , sourceId :: SourceId
  , handlerCapabilities :: NonEmpty ProjectionHandlerCapability
  }

resolvedQuerySupplies :: ValidatedProjectionCatalog -> [ResolvedQuerySupply]
```

Exact field labels may change to avoid `OverloadedRecordDot` collisions, but the information,
non-emptiness, ordering, and absence of closures are normative. Resolution is produced only
by `validateProjectionCatalog`; callers cannot construct a falsely validated value.

The DSL needs one internal resolved record keyed by `rmName`, containing the `poName`,
`poGroup`, and sorted observed target names plus claim locations. Validation, scaffold,
workspace scaffold, diff, and harness consume that same record. No new external library
dependency is required. Runtime dependency APIs are already in the repository; if an
external API question arises during implementation, locate it with Mori before coding.
