---
type: Improvement Request
title: Let one inline projection owner supply multiple query models
description: >-
  Make the Language 5 projection catalog authoritative for inline read-model ownership, so one
  catalogued inline projection owner can transactionally supply several separately typed query
  models without one legacy aggregate projection clause per model.
timestamp: 2026-08-12T02:15:20Z
requestId: IR-23
status: proposed
plan: docs/masterplans/38-finalize-projection-ownership-and-query-freshness-before-stable-language-5.md
origin: mori://tan/notification-render-service
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-12T02:15:20Z
    document_timestamp: 2026-08-12T02:15:20Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against the Language 5 grammar, read-model and projection-owner validation,
      generated projection catalog, typed runtime projection selection, and the active explicit
      backing-target release plan. The request keeps the runtime catalog model, separates the
      aggregate-clause ownership defect from multi-target backing and consistency vocabulary, and
      preserves released Languages 1–4.
---

# Improvement Request: Let One Inline Projection Owner Supply Multiple Query Models

## Status

Proposed and planned by
[MasterPlan 38](../masterplans/38-finalize-projection-ownership-and-query-freshness-before-stable-language-5.md),
principally
[Plan 243](../plans/243-make-projection-owners-authoritative-for-catalog-bound-query-models.md).
Raised by `mori://tan/notification-render-service` during its pre-implementation review against
the imminent Keiro 0.12 runtime and stable DSL Language 5. That service has one Catalog
aggregate whose inline projection owner atomically materializes three physical targets, with
several separately typed validation and administration queries over those targets. Existing fleet
services use an older Keiro release and are not evidence for the new surface.

This is a pre-0.12 language-release blocker for that consumer. The runtime projection catalog
already represents several query models and a typed inline owner over several targets; the missing
capability is in DSL ownership validation and the generated compatibility path.


## Context

Language 5 correctly separates these concepts:

- a `readmodel` is a typed logical query contract;
- a `target` is an application-owned physical table;
- a `rebuild-group` is the lifecycle and fence unit; and
- a top-level `projection-owner` is the event handler that owns one or more targets.

For example, one Catalog event handler should be able to maintain three tables while separate
queries retain separate input and result types:

```keiro
readmodel validate_layout {
  columns {}
  query input = LayoutValidationInput
  query result = Optional LayoutContract
  version = 1
  shape = "fnv1a:3c07a19c552c3547"
  consistency = Eventual
  feed = inline
  group = catalog_views
  targets = [ catalog_layouts ]
}

readmodel validate_schema_key {
  columns {}
  query input = CatalogKeyInput
  query result = CatalogKeyResult
  version = 1
  shape = "fnv1a:3c07a19c552c3547"
  consistency = Eventual
  feed = inline
  group = catalog_views
  targets = [ catalog_keys ]
}

projection-owner catalog_writer {
  source = aggregate Catalog
  feed = inline
  group = catalog_views
  targets = [ catalog_state catalog_layouts catalog_keys ]
  order = 10
  replay = explicit
}
```

The runtime catalog can represent this graph. `QueryModelBinding` values register both logical
query models, the `catalog_writer` `ProjectionSet CatalogEvent` owns the handler once, and
`runCommandWithCatalogProjections` applies its selected inline handlers while holding the rebuild
group fence in the append transaction.

The DSL checker nevertheless rejects both read models with `RmInlineFeedUnreferenced`. Its rule
recognizes an inline read model only when an aggregate's inner `projection <readmodel> ...` clause
names it. That older clause is stored as `aggProjection :: Maybe ProjectionSpec`; the aggregate
parser deliberately permits only one. It is therefore impossible for two inline read models to
satisfy the rule, even when one Language 5 `projection-owner` plainly owns their observed targets.

The confusing names hide the mismatch. The inner aggregate `projection` clause is a standalone,
single-read-model projection mechanism that predates the Language 5 catalog. The top-level
`projection-owner` is the catalogued writer of physical targets. They sound like two spellings for
the same declaration, but currently establish different and partially overlapping ownership
paths.

Changing the read models to `feed = subscription` is not an equivalent workaround. It makes the
materialization asynchronous, introduces checkpoint/dedup lifecycle, and opens a lag window. The
originating service needs catalog activation and all validation targets to commit atomically so
the first notification command after boot cannot validate against an older manifest.


## Requested Change

Make the Language 5 projection catalog the authority for determining whether catalog-managed read
models have a compatible writer.

1. For Language 5, treat a `feed = inline` read model as supplied when exactly one inline
   `projection-owner` in its rebuild group owns every target the read model observes. Do not
   require an aggregate's inner `projection` clause for that catalog-managed model.
2. Validate the relation explicitly. Report deterministic diagnostics when an inline read model
   has no compatible inline owner, when its observed target set spans several owners, or when its
   declared delivery mode conflicts with the owner that supplies its targets. Name the read model,
   owner candidates, group, and targets in the diagnostic.
3. Keep physical ownership singular. This change permits several query models to observe targets
   maintained by one projection owner; it does not permit several projection owners to write one
   target or generate one independent handler per query model.
4. Preserve the existing inner aggregate `projection` clause and its current semantics for
   released Languages 1–4. In Language 5, retain it as a standalone aggregate-projection
   compatibility surface for sources that do not use the catalog owner path, or deprecate it if
   every supported use has a lossless catalog spelling. Do not silently reinterpret old source.
5. Use unambiguous terminology in Language 5 diagnostics and documentation: call the inner clause
   a **standalone aggregate projection** and the top-level declaration a **catalog projection
   owner**. Avoid a source-syntax rename immediately before release unless an automated rewrite and
   compatibility policy make it demonstrably safer than documentation and diagnostics.
6. Derive mapped-consumer impact and generated conformance from the catalog projection owner and
   its authoritative aggregate event source. Removing the obsolete inner clause must not erase
   projection mapped-impact facts, replay review, or source fingerprints.
7. Scaffold one handler for the catalog projection owner and one typed query contract/hole per
   read model. Generated registration must associate every query model with its group and observed
   targets without inventing extra projection handlers.
8. Make the ownership resolution workspace-wide, so a read model, projection owner, aggregate,
   and targets may live in separate members of one checked Language 5 service workspace.
9. Update the authoring guide, API reference, fixtures, corpus, diff behavior, and changelog before
   Language 5 is marked stable. Include the multi-inline use case as a positive example rather
   than teaching authors to multiplex unrelated queries through one tagged union.


## Acceptance

1. A Language 5 workspace with one aggregate-sourced inline `projection-owner`, three owned
   targets, and at least two `feed = inline` read models over different subsets checks cleanly
   without any inner aggregate `projection` clause.
2. Scaffolding that workspace emits one typed inline projection set/handler for the owner and a
   distinct generated `QueryContract`, `ReadModel`, table binding, harness, and create-once query
   hole for every read model.
3. Running a command through `runCommandWithCatalogProjections` applies the owner once, updates all
   owned targets in the append transaction, and leaves all separately typed queries registered and
   available through the one validated catalog.
4. An inline read model whose targets have no inline owner fails with a stable diagnostic replacing
   the misleading aggregate-clause-only `RmInlineFeedUnreferenced` rule for Language 5.
5. An inline read model observing targets split across two owners, or supplied only by a
   subscription owner, fails with a deterministic multi-site diagnostic. A subscription read
   model is not accepted merely because an unrelated inline owner touches the same group.
6. Two query models observing the same target are legal, while two independent projection owners
   claiming that target remain illegal.
7. Languages 1–4 retain byte-compatible parse/check/scaffold behavior for the existing standalone
   aggregate `projection` clause and its single-read-model constraint.
8. Mapped-consumer reports, projection fingerprints, replay-impact classification, generated
   harnesses, and service conformance remain complete after the Language 5 aggregate clause is
   omitted.
9. Single-file and multi-member workspace fixtures both pass repeated byte-stable scaffolding, and
   a restoring mutation proves that weakening or deleting the owner/read-model relation fails the
   test suite.
10. The originating notification service can replace its temporary tagged `CatalogQuery` union
    with separate `validate_layout`, `validate_schema_key`, `validate_recipient_type`,
    `validate_custom_type`, and catalog-list query models while retaining one inline
    `catalog_writer` owner.


## Compatibility and Scope

This request completes the candidate Language 5 catalog model before it becomes stable. It does
not change event wire formats, persisted aggregate state, application table migrations, Kiroku
checkpoint semantics, or the runtime rule that every physical target has exactly one writer.

The adjacent vocabulary problem—`feed = inline` combined with `consistency = Eventual`, while
`Strong` specifically means a subscription cursor wait—is real but broader. Redesigning delivery
and query-read policy would affect runtime query semantics and migration for released source. It
should be handled by a separate improvement request rather than delaying this ownership fix. This
request changes the projection terminology in diagnostics and documentation only where necessary
to explain the two existing constructs accurately.

The multi-target generated-table binding defect is also separate and is already tracked by
`mori://shinzui/keiro/plans/234-bind-catalog-read-models-to-one-explicit-physical-target`. That
plan selects one explicit physical `backing` for a query that observes several targets. This
request instead allows several logical inline queries to be supplied by one writer. Both fixes are
needed before the originating service should adopt stable Language 5, but neither substitutes for
the other.


## Requested Deliverables

- Language-5-aware read-model/owner resolution shared by validation, scaffolding, semantic impact,
  diff, and workspace composition.
- Stable missing-owner, split-owner, and delivery-mismatch diagnostics with multi-site evidence.
- Positive and negative single-file/workspace fixtures for several inline query models supplied by
  one aggregate-sourced catalog owner.
- Generated conformance proving one handler, several typed queries, atomic application, complete
  mapped-consumer impact, and byte-stable regeneration.
- Updated Language 5 guides, API reference, ADR terminology, corpus index, and changelog.


## References

- Originating consumer: `mori://tan/notification-render-service`.
- Affected toolchain: `mori://shinzui/keiro/packages/keiro-dsl`.
- Runtime catalog request: `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-20`.
- Projection identity ADR: `mori://shinzui/keiro/okf/adrs/concepts/ADR-26`.
- Adjacent backing-target plan:
  `mori://shinzui/keiro/plans/234-bind-catalog-read-models-to-one-explicit-physical-target`.
