---
type: Improvement Request
title: Make projection ownership and rebuild catalogs one typed declaration
description: >-
  Give Keiro one validated typed catalog that binds projection handlers to physical read-model
  targets and rebuild groups, then derives registration, live application, replay, and operator
  inventory wiring while rejecting structural drift before startup.
timestamp: 2026-08-08T00:19:11Z
requestId: IR-20
status: accepted
origin: mori://shinzui/keiro
targetPlan: mori://shinzui/keiro/masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-08T00:19:11Z
    document_timestamp: 2026-08-08T00:19:11Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Approved after revision against Keiro 0.11's InlineProjection, AsyncProjection, ReadModel,
      rebuild, DSL, and pending ops surfaces; Kiroku's released ordered global/category reads; and
      Mori's twenty-four-table regression, reconcile-only policy, typed adapters, and grouped
      rebuild workaround. The revised contract separates query models, physical targets, rebuild
      groups, reset policy, and replay policy; scopes closed-world validation honestly; and requires
      captured-head replay completion rather than treating dedup presence as completeness proof.
      Kiroku IR-1 captures the useful dependency-side bounded-read primitive without gating Keiro.
---

# Improvement Request: Make Projection Ownership and Rebuild Catalogs One Typed Declaration

## Status

Validated and planned for implementation through
[MasterPlan 32](../masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md),
with Keiro runtime design and implementation first. `keiro-dsl` generation, evolution
classification, example adoption, and operator integration follow only after the runtime contract
is proven. Application schemas and migrations remain consumer-owned.

Kiroku companion request
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1` asks the event store to expose its
existing cheap global-head query and bounded `$all` / category pages. It is useful for centralizing
the fixed-head scan contract, but it is not an implementation blocker: Keiro can provide a
compatibility reader over Kiroku's released ordered vector APIs and adopt the bounded primitives
only after a verified release exists.

The runtime initiative supersedes the unimplemented repository-local
[inline-rebuild plan](../plans/162-rebuild-inline-projections-deterministically-from-event-history.md)
by carrying its fencing, fixed replay range, progress, resume, and decode-failure requirements into
the broader catalog contract. It also replaces only the application-supplied rebuild-map portion of
[the pending keiro-ops embedding plan](../plans/208-make-keiro-ops-embeddable-and-document-the-operational-surface.md);
that plan retains ownership of the command tree and other code-dependent operations.

## Context

Keiro currently exposes the right individual runtime pieces, but no closed declaration connects
all of them:

- `InlineProjection` carries a logical name and an unrestricted Hasql transaction handler.
- `AsyncProjection` adds one read-model name, subscription name, deduplication identity, and an
  unrestricted recorded-event handler.
- `ReadModel` combines a typed query contract with one logical registry identity, one physical
  PostgreSQL table, schema/version metadata, consistency policy, and one subscription name.
- `Keiro.ReadModel.Rebuild` takes a `ReadModel` plus a caller-supplied list of projection names,
  operates on one physical table, and always performs destructive truncate-and-replay preparation.

That separation is flexible, but an application must independently maintain the physical tables a
projection writes, its startup registrations, live selection, event decoder and replay adapter,
rebuild group and order, dedup reset set, and any targets that must reconcile rather than truncate.
Those lists can all compile while disagreeing. A normalized projection also exposes a modeling
fault in the current API: a typed query model, a physical table, and the lifecycle unit that must be
fenced and promoted atomically are related, but they are not the same identity.

Mori demonstrated the resulting failure at production scale. Its first-class Keiro migration
preserved the established Project projections, but the later functional Keiro DSL activation
removed their live assembly without replacing every writer. Registration continued to succeed
while twenty-four live read-model tables received no new rows. The same audit found a rebuild
cleanup that treated absence from incomplete functional history as deletion evidence and could
erase brownfield roots. The repair and evidence are recorded in
`mori://shinzui/mori/plans/215-restore-the-seven-registration-read-models-dropped-by-the-functional-rewrite`;
the durable ownership and reconcile-only constraint is
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`.

Mori now publishes physical-table inventories from live projection modules, maintains a separate
catalog of physical targets, fabricates query-less `ReadModel () ()` values for lifecycle state,
maintains an existential replay-adapter list, and implements its own grouped multi-table reset path
because Keiro's public operation handles one table at a time. Mutation-tested guards compare the
writer inventories with the catalog and protect brownfield targets. This closes the local defect,
but it is framework-shaped duplication that every non-trivial Keiro projection fleet would need to
repeat.

## Contract Boundaries

The catalog must distinguish four concepts instead of extending `ReadModel` into a larger record:

- A **query model** is the existing typed `ReadModel q r`: a logical query, schema/version identity,
  consistency contract, and binding to a lifecycle unit. A query may read one or several physical
  targets.
- A **physical target** is a stable target identity plus a qualified, application-owned PostgreSQL
  location. It is the unit for ownership diagnostics and reset policy, not necessarily a query or a
  registry row.
- A **rebuild group** is the atomic lifecycle and fencing unit. It owns the registry state used by
  live writers and queries, a non-empty target set, dependency metadata, and coordinated reset and
  promotion. Foreign-key-related targets can therefore transition and truncate in one transaction.
- A **projection definition** binds a stable projection identity to typed event sources, live apply
  behavior, replay behavior, execution mode, subscription/dedup identity where applicable, and the
  targets it owns. A projection that transactionally writes several targets places them in one
  compatible rebuild group.

One typed catalog means one validated runtime value composed from those declarations. It does not
mean collapsing query, physical-storage, and lifecycle identities or erasing the event type needed
by normal inline application.

Reset policy and replay policy are independent. A physical target is either cleared before replay
or preserved and reconciled in place. A projection is replayable through an explicit adapter or is
live-only/non-replayable. A live handler that also arms timers, emits externally visible work, or
performs another side effect may provide a replay-specific apply function that retains safe
read-model writes while suppressing the side effect. A live-only projection cannot be silently
included in a rebuild group whose targets require its historical writes.

The initial API retains unrestricted `Tx.Transaction` handlers. Keiro can validate catalog
structure and control the SQL it generates, but it cannot prove which tables arbitrary SQL touches
or whether consumer SQL obeys reconcile-only semantics. Stronger target-scoped write capabilities
may be explored later without overstating the first contract.

## Requested Change

Add a validated typed projection catalog to the Keiro runtime with the following behavior.

1. Represent typed event sources, projection identity, execution mode, live apply behavior,
   replay behavior, subscription/dedup identity where applicable, owned physical targets, and the
   rebuild group in one projection declaration. Prefer a source-owned codec such as the codec on a
   `ValidatedEventStream`; accept an explicit total relevance/decoder function where a projection
   consumes heterogeneous recorded events. Do not duplicate an authoritative codec merely to fill
   the catalog.
2. Represent query models, physical targets, and rebuild groups separately. Bind `ReadModel q r`
   values to a group for registration and liveness without requiring one fake query model per
   table. Give each target a stable identity and qualified application-owned location.
3. Give each target an explicit reset policy that distinguishes destructive clear-before-replay
   from preserve-and-reconcile. Give each projection a separate replay policy that distinguishes a
   safe replay adapter from live-only behavior. Preserve/reconcile replay may apply explicit
   recorded removals, but catalog-generated orchestration must never truncate the target or infer
   deletion merely from an absent stream.
4. Produce typed per-source views for normal application and existential fleet views for
   validation, registration, replay planning, and operator inventory. Inline command application
   must retain its event type; the existential wrapper must not force callers through `Dynamic` or
   an untyped handler merely to obtain `[InlineProjection event]` for one source.
5. Derive startup registration, live projection selection, replay adapters, dry-run inventory,
   group transitions, projection-name/dedup reset sets, and subscription resets from a successfully
   validated catalog. Pure structural validation must complete before any database registration or
   lifecycle effect occurs.
6. Validate the closed catalog structurally. Every declared physical target must have exactly one
   projection owner or one explicit composed owner; unknown identities, duplicate projection,
   target, group, registry, subscription, or dedup identities; ownerless declared targets;
   dependency cycles; cross-group transactional writers; and unsafe replay-policy combinations
   must produce deterministic diagnostics naming every claim site.
7. State the closed-world limit precisely. Runtime validation proves only the declarations present
   in the catalog and cannot discover an undeclared application table or SQL write. Removing the
   owner while retaining a target is a runtime validation error. Removing the target declaration
   itself requires comparison with a persisted catalog baseline or DSL diff to become an evolution
   finding; it cannot be detected from the new catalog alone.
8. Support atomic rebuild groups for normalized schemas. A group may legitimately mix targets that
   are cleared and targets that are preserved, provided its replay behavior is safe. Targets with
   foreign keys must be prepared in one multi-table operation or another validated group action,
   rather than relying on sequential `TRUNCATE` calls that PostgreSQL can reject. Live and replay
   handler order is explicit within composed ownership.
9. Define source ordering and completion. Capture an immutable target head for every replay source,
   scan each exclusive-start/inclusive-target range, and preserve global-position order when
   several categories feed an order-sensitive group. The catalog must either provide that merged
   order or reject a multi-source combination whose equivalence it cannot establish.
10. Promotion must prove that every source reached its captured target, every required replay
    adapter participated, and application verification succeeded. A source with no relevant event
    may validly produce zero applies. Dedup rows remain idempotency evidence, not a sufficient proof
    that every feeding projection ran. Persist a projection/source fingerprint and committed replay
    progress so a large failed rebuild can resume only against the same catalog contract.
11. Keep application schema and migration ownership with the consumer. Keiro may quote and operate
    on declared qualified PostgreSQL targets and may migrate its own lifecycle/progress tables, but
    it must not create, alter, or migrate application targets implicitly.
12. Once the runtime abstraction is proven, let `keiro-dsl` checked read-model/projection
    declarations generate catalog entries and include target ownership, reset policy, replay
    policy, grouping, source, and ordering changes in diff and replay-impact reports. Hand-written
    catalog entries remain supported for behavior outside the DSL.

## Acceptance

1. A multi-table inline projection and an asynchronous projection can each be declared once. Typed
   source views drive normal application, while the same validated catalog drives registration,
   rebuild planning/execution, and operator inventory without a second projection-name or table
   list.
2. `ReadModel q r` query contracts can read multiple targets and bind to one rebuild group; a
   normalized group does not require fabricated `ReadModel () ()` values for its physical tables.
3. Removing an owner while leaving its target declared, referring to an unknown target or group,
   or assigning two independent owners to one target produces a deterministic pre-effect failure
   naming the exact identities and claim sites. A baseline/diff test separately reports total
   removal of a previously catalogued target.
4. Explicitly composed multi-handler ownership remains possible, but the composition has one
   catalog identity, declared ordering, one group fence, and one replay contract.
5. Catalog-generated reset never truncates a preserve-and-reconcile target. A regression test
   preserves a brownfield root and child with no corresponding functional stream while replay
   repairs event-covered rows. A deliberately destructive consumer handler remains documented as
   outside the structural proof boundary.
6. Foreign-key-related targets transition atomically and use one compatible preparation action.
   Cycles, cross-group transactional writers, and a live-only handler required to reconstruct a
   cleared target fail validation. A mixed clear/preserve group with safe replay succeeds.
7. Inline writers and async writers consult the group fence in their write transaction. In-flight
   applications serialize before reset; later applications receive a typed fenced outcome and do
   not append events, insert dedup keys, or write targets until promotion.
8. A fixed-head replay preserves global event order across relevant sources, records bounded
   progress transactionally, resumes after a simulated crash, and refuses changed source,
   projection, group, target, version, shape, or replay fingerprints.
9. Promotion succeeds for an empty relevant history after proving every source reached its target,
   and fails when any required adapter was omitted, a source stopped early, decoding/application
   failed, or verification rejected the materialization. Merely inserting one named dedup row does
   not satisfy the completion proof.
10. Existing `InlineProjection`, `AsyncProjection`, `ReadModel`, and rebuild call sites retain a
    documented compatibility path during adoption. The new catalog APIs are additive until the
    examples, DSL, and migration guide prove the replacement path.
11. Mutation tests demonstrate that missing-owner, duplicate-owner, omitted-adapter, unsafe-policy,
    and early-promotion guards are live. End-to-end tests cover inline, async, multi-table,
    multi-source, reconcile, grouped, live-only/side-effecting, crash/resume, and failed rebuilds.
12. When DSL generation lands, checked specs emit the same runtime catalog values, generated
    source views compile, and diff classifies ownership, target, reset/replay policy, group,
    ordering, and source changes conservatively without transferring migration ownership.
13. When operator integration lands, catalog inventory and rebuild actions replace the manual
    application `Map Text ...` rebuild hook while preserving `keiro-ops` preview, `--force`, JSON,
    and embedding contracts.

## Requested Deliverables

- Typed runtime declarations for query-model bindings, physical targets, rebuild groups, typed
  projection/source views, existential fleet entries, and a `ValidatedProjectionCatalog` or
  equivalent that is the only input accepted by effectful catalog operations.
- Pure validation with deterministic multi-site diagnostics plus optional persisted-baseline or
  DSL-diff support for total target removal.
- Derived registration, normal application selection, grouped lifecycle, replay, dedup/checkpoint
  reset, completion proof, dry-run inventory, and operator-facing APIs.
- Separate clear/preserve target reset policies and replayable/live-only projection policies, with
  explicit live-versus-replay apply behavior where side effects require it.
- Durable rebuild-run metadata, captured source heads, fingerprints, progress, restart, abandon,
  verification, and atomic group promotion.
- Missing, duplicate, unknown-reference, dependency-cycle, cross-group writer, incompatible-policy,
  ordering, omitted-adapter, changed-fingerprint, and early-promotion negative tests.
- Migration guide from independent projection/read-model/rebuild lists, including the arbitrary-SQL
  proof boundary and continued consumer ownership of application schema and migrations.
- `keiro-dsl` catalog generation, compatibility classification, replay-impact reporting, and
  compiled conformance after the runtime API stabilizes.
- `keiro-ops`, `jitsurei`, API reference, runbook, and changelog adoption after the catalog and
  replay contracts are complete.
