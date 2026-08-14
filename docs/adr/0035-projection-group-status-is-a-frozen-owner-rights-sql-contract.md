---
type: Architecture Decision Record
title: Projection group status is a frozen owner-rights SQL contract
description: Keiro publishes serving availability and progress separately from candidate rebuild progress through a frozen versioned owner-rights view.
timestamp: 2026-08-14T02:59:54Z
docId: ADR-35
status: Accepted
date: 2026-08-13
originatingPlan: docs/plans/254-publish-a-documented-projection-status-relation-for-external-readers.md
---

# 35. Projection group status is a frozen owner-rights SQL contract

Date: 2026-08-13

Status: Accepted


## Context

Keiro's rebuild-group fence originally existed only at Haskell call boundaries. An
independent PostgreSQL reader could not tell whether an in-place rebuild had made its
target temporarily incomplete. The online generation protocol also makes lifecycle an
insufficient availability signal: a group can be `rebuilding-versioned` while its old
generation remains safe to read, and its candidate replay can lag far behind the data
still being served.

External clients need one supported status relation, but exposing Keiro's lifecycle
tables would freeze private storage and require broad schema grants. Serving progress
for asynchronous projections additionally comes from Kiroku. A Keiro-owned public view
must not depend on Kiroku's private checkpoint table, because that would make an
upstream internal migration part of Keiro's public compatibility graph.

SQL clients also do not share one notion of an additive change. Positional decoders and
clients using `SELECT *` can break when an ordinary unversioned view gains a column.
Column order, null semantics, and the value vocabulary must therefore be explicit parts
of the contract rather than implementation details.


## Decision

Keiro publishes `keiro_read.projection_group_status_v1` as a structurally read-only,
owner-rights PostgreSQL view. Deployments grant an external role only `USAGE` on
`keiro_read` and `SELECT` on that view. They do not grant access to the private `keiro`
or `kiroku` schemas. The view owner resolves its dependencies, including Kiroku's
supported `kiroku.subscription_checkpoints_v1` relation.

This relation is observability, not a two-statement authorization protocol for raw
projection tables. Projection data reads use ADR 0036's guarded functions so the
availability check and target access share one lifecycle lock and transaction.

The v1 relation is frozen in name, column order, PostgreSQL types, null semantics, and
value meanings. Compatible implementation changes may replace its body. Any
incompatible column or vocabulary change creates `projection_group_status_v2`; v1 is
not extended under an open-ended additive rule.

Lifecycle phase, read availability, and write availability are independent facts.
External readers use `reads_allowed`, not a closed list of lifecycle strings, to decide
whether serving data may be read. `writes_allowed` explains writer behavior but grants
no external write authority. Serving revision and monotonically increasing
`serving_epoch` identify the current generation; clients use the epoch rather than a
position regression to invalidate generation-scoped caches.

Serving progress and candidate progress are separate. `serving_position_basis` is
exactly `append`, `checkpoint`, or `unmanaged`. Inline groups use `append` and have no
numeric serving cursor. Catalog-bound async groups use `checkpoint`; their applied
position is the minimum checkpoint across every row for every bound subscription, but
is null until each bound subscription has at least one public checkpoint row.
Pre-existing or unreconciled groups use `unmanaged` and make no position promise. An
offline unavailable group reports no serving position even if its checkpoints exist.

Keiro persists one private cursor-authority row per group. Upgrade seeds existing
groups as `unmanaged`; catalog registration and reviewed adoption transactionally
replace that value with `append` or a sorted set of checkpoint subscription names.
This row shape distinguishes a catalog-proven inline group from metadata that has never
been reconciled. It is derived registration metadata, not a second catalog identity.

Candidate position is the conservative minimum of the source cursors persisted for the
active run, and candidate head is that run's captured head. The replay runner inserts
the complete declared source set in the same transaction that creates the run, so a
visible non-empty source set is complete. Candidate fields are null when no run is
active. Query-model names are sorted and empty rather than null.


## Consequences

- A narrow PostgreSQL role can poll one documented relation without access to private
  framework tables.
- A missing bound subscription checkpoint makes serving progress unknown instead of
  overstating it from a partial inventory.
- During online rebuild, serving availability and checkpoint progress can continue
  while candidate progress advances independently. Promotion changes the serving
  revision and epoch and clears active-candidate fields atomically.
- Legacy groups remain visible but explicitly `unmanaged` until catalog registration or
  reviewed adoption supplies cursor authority.
- The expected-schema gate records the public view's ordered column signature, while
  semantic and privilege tests cover meanings that PostgreSQL's ordinary-view catalog
  metadata cannot express.
- Kiroku checkpoint compatibility is owned by
  `mori://shinzui/kiroku/okf/adrs/concepts/ADR-6`; Keiro never queries its private
  subscription table through this contract.


## Alternatives considered

Grant external readers access to Keiro's private lifecycle tables. Rejected because it
freezes internal joins and widens privileges without providing stable null or value
semantics.

Publish one unversioned view and allow additive columns. Rejected because additions are
not universally compatible for SQL decoders or `SELECT *` clients.

Report the active replay cursor as the serving position. Rejected because an online
candidate starts behind the old generation that remains live; this would describe a
healthy serving projection as regressing.

Read Kiroku's private subscription table. Rejected because it creates an unsupported
cross-repository schema dependency. Keiro consumes only the owner-published v1
checkpoint relation.

Materialize a second status table. Rejected because lifecycle, revision, replay, query,
and checkpoint authorities already change transactionally; copying them creates a new
drift and crash-recovery problem.


## References

- [ADR 0026](0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
  defines the catalog and rebuild-group authority that derives cursor bindings.
- [ADR 0034](0034-online-projection-rebuilds-use-schema-versioned-target-generations.md)
  defines the orthogonal online serving and candidate lifecycle.
- [ADR 0036](0036-external-readers-use-versioned-guarded-sql-contracts.md)
  defines the sanctioned projection-data surface that consumes these availability facts.
- [ExecPlan 254](../plans/254-publish-a-documented-projection-status-relation-for-external-readers.md)
  records the frozen row contract, implementation, and PostgreSQL evidence.
- `mori://shinzui/kiroku/okf/adrs/concepts/ADR-6` owns the upstream versioned
  checkpoint relation contract.
