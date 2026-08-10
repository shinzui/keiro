---
type: Improvement Request
title: Make read models safely readable by out-of-process consumers
description: >-
  Give a non-Haskell consumer reading a Keiro read model over SQL a way to observe the group
  fence, and give rebuilds a zero-downtime path, so an external reader can never mistake a
  truncated or partially replayed target for current truth.
timestamp: 2026-08-10T20:40:00Z
requestId: IR-22
status: proposed
origin: mori://shinzui/keiro
---

# Improvement Request: Make Read Models Safely Readable by Out-of-Process Consumers

## Status

Proposed. Raised by `mori://tan/notification-render-service`, which is splitting into an
event-sourced Keiro service and a stateless TypeScript render process that reads live published
content from the Keiro read model over SQL. That design is documented in that repository at
`docs/SPLIT-PULL-ALTERNATIVE.md` and decomposed by
`docs/masterplans/1-notification-platform-split-mvp-event-sourced-domain-service-and-typescript-render-kernel.md`;
an artifact-level Mori URI for that repository's plans is not yet defined, so the canonical
project URI and repository-relative paths are given together.

The consuming service is shipping a local mitigation now — a versioned SQL read function that
checks group liveness transactionally and raises — and does not need this request to proceed.
It files the request because the mitigation reimplements, in one application's SQL, a guarantee
that belongs to the runtime, and because every future non-Haskell consumer of a Keiro read model
will otherwise have to rediscover the hazard and reimplement it too.


## Context

Keiro's catalog rebuild is deliberate and well specified. `beginGroupRebuild` holds the exclusive
group lock while it moves the group and its bound query models out of live service, truncates
every `ClearBeforeReplay` target through one quoted multi-table `TRUNCATE`, leaves every
`PreserveAndReconcile` target untouched, and resets the replayable async dedup and subscription
identities derived from that group. Replay proceeds against one captured immutable Kiroku head.
Promotion requires the opaque completion proof produced by the replay runner, and no individual
target or query binding can be promoted independently. A failed or abandoned run stays fenced.

The fence is enforced at every in-process boundary. `runQuery` checks registration and liveness
before applying a model's consistency mode. `runCommandWithCatalogProjections` and
`applyAsyncProjectionFromCatalog` acquire shared locks for the catalog-derived groups in stable
identity order inside the same transaction as the append or dedup work; when a group is
rebuilding or failed, the inline runner rolls back the event append and target SQL and the async
runner performs no dedup insert or target write. Both surface a typed fenced outcome that callers
are told to treat as retryable unavailability.

Every one of those enforcement points is a Haskell function call. A consumer holding its own
PostgreSQL connection and issuing `SELECT` participates in none of them.

The standard is explicit that this is an offline rebuild:
`keiro-runtime-patterns/runtime-patterns/keiro/read-models-and-projections.md` states "This is an
offline rebuild, not a zero-downtime shadow-table swap." For an in-process reader, "offline"
means `runQuery` returns a fenced outcome — unavailability, correctly reported. For an
out-of-process reader, "offline" means something entirely different and much worse: the tables
are readable throughout.

Concretely, during a rebuild of a group containing a `ClearBeforeReplay` target, an external SQL
reader observes, in sequence: a table that is empty because it was just truncated; then a table
progressively filling with rows reconstructed from the beginning of history; then, at promotion,
the correct current state. In the middle of that window the table contains a coherent, queryable,
*historical* picture of the world.

For the requesting service that picture is: templates at revisions they no longer sit at, and
market-specific template variants that do not exist yet — so variant selection silently falls
through to the default. Both produce a successful render of the wrong content, which is then
delivered as email. Nothing errors, no retry occurs, and no alert fires, because from the
system's point of view nothing failed. The failure is invisible precisely because the rebuilt
state is internally consistent.

`PreserveAndReconcile` targets narrow but do not remove the hazard: an external reader still
observes a target mid-reconciliation with no way to know reconciliation is in progress.

The asymmetry worth naming is that the runtime already *knows* the answer. Group liveness is a
durable catalog fact that preparation and promotion both write. The information an external
reader needs exists; there is simply no sanctioned way for that reader to see it, and no
documented statement that it must.


## Requested Change

Four capabilities, in descending order of value to the requesting service. The first two close
the correctness gap; the third removes the availability cost of closing it; the fourth reduces
how often the question arises.

**1. A fence that a database-level reader observes.** Make it possible for a non-Haskell consumer
to fail loudly rather than read garbage. Two shapes both work, and either is sufficient:

- A generated SQL read API. Keiro emits, per query-model binding, a SQL function that checks its
  group's liveness transactionally and raises a documented `SQLSTATE` when the group is not in
  live service, then returns the declared rows. External consumers call the function and never
  touch the target tables, which stay private. This is the shape the requesting service is
  hand-rolling and would delete in favor of a generated one.
- Privilege-based fencing. Preparation revokes `SELECT` on the group's targets from a declared
  consumer role and promotion restores it, so an external reader receives a permission error
  during the window. Blunter, requires no generated code, and fails safe by construction.

The requirement is only that the failure be *loud and attributable*. A reader that cannot
distinguish "the model is rebuilding" from "no row matched" is the whole problem.

**2. Documented projection status metadata for external readers.** A stable, supported relation
exposing per rebuild group: the group identity, the applied global position, and the live-service
state, with a documented contract that external consumers may read it and what each value means.
This makes position-regression detection possible for a consumer that wants it, and makes
`PositionWait`-equivalent behavior implementable outside Haskell. Today an external reader
inferring any of this is reading private bookkeeping and will be broken by an internal change,
with no warning that it was never a contract.

**3. Zero-downtime versioned rebuild with atomic cutover.** Replay into a new target version
alongside the live one, which keeps serving — stale but monotonic and internally consistent —
then swap in one transaction and drop the old version after drain. Registration identity already
carries `version` and `shapeHash`; the ask is promoting that to the first-class rebuild protocol
rather than the current documented offline, in-place one.

This one asks to revisit a stated stance rather than to fill a gap, and is filed as the weakest
of the four for that reason. `keiro-runtime-patterns/runtime-patterns/keiro/projection-catalogs.md`
says plainly: "Keiro never creates, migrates, or swaps application-owned tables; an online cutover
remains application-owned." That boundary is coherent — targets are application-owned, their DDL
is application-owned, and a framework that swapped them would be reaching across the ownership
line the catalog exists to draw.

So the request is deliberately conditional. If the boundary stands, say so and close this
capability, and the remaining ask becomes documentation: state in the read-model standard that an
online cutover is application-owned *and* what an application must do to achieve one against a
catalog-managed group, since today a reader is told the rebuild is offline without being told
that an alternative is theirs to build. If instead the framework is willing to own a versioned
target lifecycle — which registration identity's existing `version` and `shapeHash` suggest was
anticipated — this is where it belongs, because every application solving it separately will
solve it differently and most will solve it wrong.

Capabilities 1 and 2 do not depend on this one and should not be blocked behind deciding it.

This is what turns the fence from a correctness fix into a non-event. With capability 1 alone, a
rebuild takes every external consumer of that group out of service for its duration — correct,
and for the requesting service a deliberate, scheduled maintenance window, but a real cost that
grows with the number of external consumers. With cutover, external readers never lose service
and the fence becomes a backstop rather than an operational constraint.

**4. Targeted per-stream reprojection.** "Reproject aggregate X into model M." For a
row-per-aggregate model, this shrinks a bugfix rebuild's blast radius from the whole table to one
row, and correspondingly shrinks the window in which any of the above matters. Not a substitute
for the others — a shape change still needs a full rebuild — but it removes the most common
reason for one.


## Acceptance

A non-Haskell consumer reading a Keiro read model can be shown to fail rather than read
historical state. Concretely: begin a rebuild of a group containing a `ClearBeforeReplay` target;
from a separate process holding its own connection, issue the sanctioned read; observe a
documented, distinguishable error rather than zero rows or partial rows. Complete the rebuild and
observe the same read return correct current state.

The same consumer can read a supported status relation and obtain the group's applied position
and live-service state, and that relation is documented as a contract external readers may depend
on.

With capability 3 delivered, the same test shows the external read continuing to succeed
throughout the rebuild, returning the pre-rebuild state until promotion and the new state
afterwards, with no window in which it returns partially replayed rows.

Capability 4 is demonstrated by reprojecting one aggregate into a row-per-aggregate model and
observing that only that aggregate's row changes and no group-wide fence is taken.


## Requested Deliverables

Runtime support for whichever fencing shape is chosen — generated read functions with a
documented `SQLSTATE`, or preparation-time and promotion-time privilege changes against a
declared consumer role — including the catalog declaration by which an application names its
external consumers.

A supported, documented projection status relation with a stated compatibility promise for
external readers.

The versioned rebuild protocol with atomic cutover, and the operator surface to drive it.

Targeted per-stream reprojection in `ProjectionCatalogOperations`.

Documentation changes in `docs/user/read-models-and-projections.md` and in
`keiro-runtime-patterns/runtime-patterns/keiro/read-models-and-projections.md` stating explicitly
that the in-process fence does not protect out-of-process readers, and naming the sanctioned way
for such a reader to participate. Until the runtime capabilities land, that documentation change
alone has standalone value: the hazard is currently discoverable only by reading the rebuild
implementation and reasoning about what an external `SELECT` would see, and the requesting service
found it during design review rather than in production by luck.


## Related Decisions

`mori://shinzui/keiro/okf/adrs/concepts/ADR-26` establishes that a projection catalog separates
query, target, group, and handler identities. This request depends on that separation: the fence
is a property of the rebuild *group*, the sanctioned read is a property of the *query-model
binding*, and the privacy being protected belongs to the *target*. Without those four identities
already distinct, capability 1 would have nowhere coherent to attach.

`mori://shinzui/mori/okf/adrs/concepts/ADR-20` requires exactly one catalogued projection owner
per live read-model table. That requirement is what makes an external read API well defined —
there is one writer whose liveness determines whether the table may be read — and this request
extends the same reasoning outward to readers the catalog does not currently know about.

`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-20` delivered the typed projection
catalog and its group-fenced offline rebuild. This request is not a correction to it. IR-20
scoped rebuild honestly as offline and in-place, and every guarantee it delivered holds for
in-process readers. What has changed is the arrival of an out-of-process reader, which is a case
that design did not have to consider and does not cover.
