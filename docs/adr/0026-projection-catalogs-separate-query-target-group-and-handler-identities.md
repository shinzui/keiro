---
type: Architecture Decision Record
title: Projection catalogs separate query, target, group, and handler identities
description: A validated projection catalog separates query models, physical targets, atomic rebuild groups, and projection handlers while leaving application SQL and schema ownership explicit.
timestamp: 2026-08-08T13:31:09Z
docId: ADR-26
status: Accepted
date: 2026-08-08
originatingPlan: docs/plans/209-define-and-validate-the-typed-projection-catalog-runtime-contract.md
---

# 26. Projection catalogs separate query, target, group, and handler identities

Date: 2026-08-08

Status: Accepted


## Context

Keiro's original read-side API has useful typed pieces but no single projection
authority. `ReadModel q r` combines a logical query contract with one table and
one subscription name. `InlineProjection event` and `AsyncProjection` contain
live SQL handlers, while rebuild callers supply another list of projection
names. An application can therefore register one inventory, execute another,
and rebuild a third without any boundary that compares them.

Those values also conflate identities with different cardinalities. One query
can observe several tables. One projection transaction can update several
tables. Several foreign-key-related tables may need to leave service, reset,
replay, verify, and return to service atomically. A table can be preserved
during a rebuild even when its handler has a replay-safe reconciliation path,
and a clearable table can be owned by a live handler whose unrelated external
effects must not be replayed.

The motivating cross-repository decision
`mori://shinzui/mori/okf/adrs/concepts/ADR-20` requires one owner per live
read-model table and preserve-in-place replay for brownfield history that cannot
reconstruct the whole table. Keiro must express that decision without importing
Mori's application-specific records or claiming to inspect arbitrary SQL.


## Decision

Keiro has one typed projection catalog with four independent stable identities.
A query-model binding retains `ReadModel q r` and names the targets it observes.
A physical target names one application-owned qualified PostgreSQL table and
its reset policy. A rebuild group owns the deterministic order of targets that
must move through one lifecycle. A projection definition is the single owner of
one or more targets and contains an explicitly ordered non-empty list of live
handlers.

Target reset policy and handler replay policy are independent. A target is
either cleared before replay or preserved and reconciled. A projection is
either replayable through an explicit replay adapter or live-only with a
reason. A mixed clear/preserve group is valid only when every clear target can
be reconstructed and every preserved target in that group has an explicit
reconciliation adapter. The replay adapter's decoder is total over a recorded
event: irrelevant, relevant and decoded, or a structured decode failure. The
authoritative event codec constructs the ordinary adapter path rather than
being copied into the catalog.

The same validated catalog produces two views. A typed `ProjectionSet event`
keeps the event type for ordinary inline application. An existential fleet view
supports heterogeneous validation, inventory, registration, replay planning,
and operator rendering. An application does not maintain parallel target,
subscription, deduplication, projection-name, or replay-adapter lists.

Catalog validation is a pure closed-world gate. It accumulates diagnostics,
sorts them by stable code and identity, and reports all conflicting claim sites.
It rejects duplicate logical and physical identities, unknown references,
missing or multiple target owners, cross-group writes, dependency cycles,
unsafe replay policy combinations, and source combinations whose global order
cannot be established. The canonical inventory and SHA-256 fingerprint include
identities, versions, policies, sources, targets, and declared order, but never
function closures. Comparing an optional previous inventory is a separate gate
for detecting total removal; absence from the supplied closed world is not
something single-catalog validation can discover.

The SQL boundary stays deliberately unchecked. A declaration states intent but
does not prove that an unrestricted `Hasql.Transaction.Transaction` writes only
declared targets. Applications continue to own table DDL, migrations, row
codecs, and SQL handler bodies. Keiro may own only its registry, fence, and
rebuild-progress schema. A future target-scoped SQL capability can strengthen
this boundary without retroactively pretending the current catalog provides
that proof.

A rebuild group is also the durable database lifecycle and live-writer fence.
It moves through `live -> rebuilding -> live` after verified promotion, or
`live -> rebuilding -> failed` after abandonment. Both rebuilding and failed
states keep ordinary writers fenced. The group row stores the active run and
catalog fingerprint; query-model rows observe that group and transition with it.
No target or query model can return to service independently.

Live inline and async paths acquire `FOR SHARE` locks on distinct group rows in
sorted `RebuildGroupId` order inside the same transaction as the event append,
dedup insert, and target SQL. Preparation takes `FOR UPDATE` on the group row.
Consequently a writer that already owns the shared lock commits before
preparation continues, while any writer arriving after preparation sees the
non-live state and returns a typed fenced outcome without committing work.

Preparation is one transaction. It issues one quoted multi-table `TRUNCATE` for
all declared clear-before-replay targets, in dependency order and without
`CASCADE`; preserves reconcile targets; and resets only replayable async dedup
and subscription identities derived from the catalog. An undeclared foreign
key therefore rolls back registry, target, and framework-state changes together.
Abandonment records structured failure evidence and preserves the fence because
cleared or partially replayed application data cannot be restored automatically.


## Consequences

- Database lifecycle and history replay code accept only a
  `ValidatedProjectionCatalog`, so invalid inventories cause no registration or
  rebuild effects.
- Group registration is idempotent only for the same fingerprint. Existing
  single-read-model rows migrate to deterministic singleton legacy groups so
  compatibility calls keep their old behavior without inventing fake catalog
  targets.
- A failed rebuild is an offline state, not an automatic rollback. Operators
  repair or resume it through the rebuild runner; they cannot bypass completion
  evidence by promoting one binding.
- Existing `InlineProjection`, `AsyncProjection`, and `ReadModel` values remain
  source-compatible. Explicit unmanaged wrappers label callers that have not
  adopted catalog validation; they do not make a legacy list safe by naming it.
- One physical table has one projection owner. Several ordered handlers can be
  composed under that one owner, but two independent projection identities
  cannot both claim the table.
- `$all` and category sources cannot feed the same rebuild group because that
  would replay overlapping events. Several distinct categories are allowed and
  later orchestration must merge them by `RecordedEvent.globalPosition`.
- Generated DSL values and operational commands consume the runtime catalog;
  neither defines a second inventory.
- Online shadow-table cutover, dynamic plugin discovery, automatic
  application-table creation, replay of external side effects, and static proof
  of arbitrary SQL writes remain outside this decision.


## Related decisions

- [ADR 0004](0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  keeps single-catalog validation, previous-inventory comparison, and runtime
  assembly as independent evidence boundaries.
- [ADR 0009](0009-keiro-owns-live-schema-verification-under-pg-migrate.md)
  separates Keiro-owned metadata migrations from consumer-owned application
  schema.
- [ADR 0020](0020-service-conformance-packages-import-one-runtime-owned-facade.md)
  requires generated conformance code to import one runtime-owned facade rather
  than restating service inventories.
