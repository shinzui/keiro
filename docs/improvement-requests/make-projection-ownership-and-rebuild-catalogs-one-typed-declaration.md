---
type: Improvement Request
title: Make projection ownership and rebuild catalogs one typed declaration
description: >-
  Give Keiro one typed catalog that binds projection handlers to their physical read-model
  targets and derives registration and rebuild wiring while rejecting missing or duplicate
  ownership before an application starts.
timestamp: 2026-08-07T23:11:15Z
requestId: IR-20
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-07T23:11:15Z
    document_timestamp: 2026-08-07T23:11:15Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against Keiro's current InlineProjection, AsyncProjection, ReadModel, and rebuild
      APIs and against Mori's twenty-four-table functional projection regression, reconcile-only
      brownfield constraints, and structural ownership guard.
---

# Improvement Request: Make Projection Ownership and Rebuild Catalogs One Typed Declaration

## Status

Proposed for Keiro runtime design first, with optional `keiro-dsl` generation after the runtime
contract stabilizes. Application schemas and migrations remain consumer-owned.

## Context

Keiro currently exposes the right individual runtime pieces, but no closed declaration connects
all of them:

- `InlineProjection` carries a logical name and an unrestricted Hasql transaction handler.
- `AsyncProjection` adds one read-model name, subscription name, deduplication identity, and an
  unrestricted recorded-event handler.
- `ReadModel` carries one logical identity, one physical PostgreSQL table, schema/version metadata,
  consistency policy, subscription name, and query transaction.
- `Keiro.ReadModel.Rebuild` takes a `ReadModel` plus a caller-supplied list of projection names and
  always implements the destructive truncate-and-replay lifecycle.

That separation is flexible, but an application must independently maintain the list of physical
tables a projection writes, its startup registration set, its event codec and replay adapter, its
rebuild grouping/order, and any tables that must reconcile rather than truncate. Those lists can
all compile while disagreeing.

Mori demonstrated the resulting failure at production scale. Its first-class Keiro migration
preserved the established Project projections, but the later functional Keiro DSL activation
removed their live assembly without replacing every writer. Registration continued to succeed
while twenty-four live read-model tables received no new rows. The same audit found a rebuild
cleanup that treated absence from incomplete functional history as deletion evidence and could
erase brownfield roots. The repair and evidence are recorded in
`mori://shinzui/mori/plans/215-restore-the-seven-registration-read-models-dropped-by-the-functional-rewrite`;
the durable ownership and reconcile-only constraint is
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`.

Mori now publishes physical table inventories from its live projection modules, constructs its
rebuild catalog from those inventories, and pins the complete expected set in mutation-tested
guards. That closes the local defect, but it is framework-shaped duplication: every Keiro
application with more than a trivial projection fleet needs the same connection between writers,
read models, and rebuilds.

## Requested Change

Add a typed projection catalog to the Keiro runtime that makes a projection's ownership and
rebuild wiring one declaration.

1. Represent a stable projection identity, its event source category or categories, codec/decoder,
   apply handler, subscription/dedup identity where applicable, and every physical read-model
   target it owns in one typed definition. It must support inline and asynchronous projections and
   one handler that transactionally maintains multiple normalized tables.
2. Give each physical target a stable identity and qualified application-owned location plus an
   explicit rebuild policy. At minimum the policy model must distinguish destructive rebuild,
   reconcile-only replay, and side-effecting/non-rebuildable behavior. Reconcile-only replay may
   upsert facts positively established by events but must never truncate or infer deletion from a
   missing stream.
3. Derive startup read-model registration, live projection selection, rebuild adapters, rebuild
   dry-run inventory, projection-name/dedup reset sets, and safe grouping/order from the catalog.
   Applications must not need a second manually synchronized projection or table list for these
   operations.
4. Validate the closed catalog structurally. Every expected physical target must have an owner;
   accidental duplicate ownership must be rejected with both claim sites; and a projection,
   read-model registration, or rebuild adapter that refers to an unknown identity must fail before
   startup. Legitimate composition or co-ownership must use one explicit combined declaration,
   not two silently competing writers.
5. Support dependency/group metadata for normalized schemas whose foreign keys require coordinated
   rebuild lifecycle transitions or deterministic application order. Reject dependency cycles and
   incompatible policies within an atomic group.
6. Keep physical schema and migration ownership with the consumer. Keiro may model qualified
   PostgreSQL targets because its existing projection/read-model API is Hasql-based, but it must not
   create or migrate application tables implicitly.
7. Preserve an explicit unchecked boundary for arbitrary SQL. Keiro cannot truthfully infer the
   tables touched by an unrestricted `Tx.Transaction`; catalog validation proves that declarations
   are complete and internally coherent, not that opaque SQL obeys them. A stronger future mode may
   narrow handlers to target-scoped capabilities, but the initial API must state this limitation
   rather than claiming SQL-level write confinement.
8. Once the runtime abstraction is proven, let `keiro-dsl` checked read-model/projection
   declarations generate catalog entries and include ownership or rebuild-policy changes in diff
   and replay-impact reports. Hand-written catalog entries remain supported for behavior outside
   the DSL.

## Acceptance

1. A multi-table inline projection and an asynchronous projection can each be declared once, and
   the same catalog value drives startup registration, normal application, rebuild planning, and
   operator inventory output.
2. Removing a target owner, adding an unregistered target reference, or assigning two independent
   owners to one target produces a deterministic structural validation failure naming the exact
   identities involved.
3. Explicitly composed multi-handler ownership remains possible, but the composition has one
   catalog identity, one ordering policy, and one rebuild contract.
4. Destructive rebuild is impossible for a reconcile-only target. A regression test preserves a
   brownfield root and child that have no corresponding functional stream, while replay repairs
   event-covered rows.
5. Foreign-key-related targets can be grouped and ordered without application code reimplementing
   Keiro's lifecycle transitions; cyclic or policy-incompatible groups fail validation.
6. The catalog derives the exact projection-name set used for dedup reset and promotion checks, so
   forgetting a feeding projection cannot silently produce an incomplete rebuild.
7. Existing `InlineProjection`, `AsyncProjection`, `ReadModel`, and rebuild call sites have a
   documented compatibility/migration path; adopting the catalog does not transfer application
   schema or migration ownership to Keiro.
8. Mutation tests demonstrate that the missing-owner and duplicate-owner guards are live rather
   than vacuous, and end-to-end tests cover inline, async, multi-table, reconcile-only, grouped,
   side-effecting, and failed-rebuild cases.
9. If DSL generation is included, checked specs emit the same runtime catalog entries, and diff
   classifies target ownership, rebuild-policy, grouping, and source-category changes
   conservatively.

## Requested Deliverables

- Typed runtime catalog definitions, validation diagnostics, and an existential wrapper where
  heterogeneous query/event types require one fleet-level collection.
- Derived registration, application, rebuild-adapter, grouping, dedup-reset, and dry-run inventory
  APIs.
- Explicit destructive, reconcile-only, and side-effecting policies with brownfield-safe tests.
- Missing, duplicate, unknown-reference, dependency-cycle, and incompatible-policy negative tests.
- Migration guide from independent projection/read-model/rebuild lists.
- Runtime documentation describing the arbitrary-SQL proof boundary and consumer schema ownership.
- Optional `keiro-dsl` catalog generation, compatibility classification, and conformance coverage
  after the runtime API stabilizes.
