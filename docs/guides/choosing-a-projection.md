---
type: Guide
title: Choosing A Projection
description: Choose inline, asynchronous, or rebuilt projections for a read-model workload.
docId: DOC-4
tags: [keiro, projections, read-models, decision-guide]
generated:
  by: process:codex-cli
  at: 2026-10-11T21:11:39Z
timestamp: 2026-10-27T21:15:00Z
---

# Choosing A Projection

Default to asynchronous delivery for query models, including local aggregate
views. Return the command result directly when it contains everything the caller
needs; otherwise wait for its committed position after the command returns.
Reserve synchronous work for a stated invariant that requires an atomic write.

Keiro supports two projection delivery modes: inline application in the
command transaction and asynchronous application from a durable subscription.
It also lets a query either read immediately or wait for an asynchronous
projection to reach a known event-log boundary. These are separate decisions.

A projection is the write side of a derived view. It consumes events and writes
application-owned targets. A `ReadModel q r` is a query contract over those
targets. A projection may own several tables, supply several query models, or
write an operational target that has no public query model at all.

## Pick The Delivery Mode

| Need | Delivery | Query freshness | Start here |
|---|---|---|---|
| Default query model, reporting, search, or analytics | `AsyncProjection` over a Kiroku subscription | `Immediate` | [Asynchronous Projections](asynchronous-projections.md) |
| An explicit invariant requires the target write to commit with the event | `InlineProjection` | Usually `Immediate` | [Inline Projections](inline-projections.md) |
| A reactor-dispatched command has that same explicit atomic invariant | `targetProjections` with `InlineProjection` | `Immediate` | [Inline Projections](inline-projections.md#reactor-dispatch) |
| A query must include everything visible when the query begins | `AsyncProjection` | `WaitForHead` | [Asynchronous Projections](asynchronous-projections.md#choose-query-freshness-separately) |
| A caller must observe one command's returned global position | `AsyncProjection` | `WaitForPosition` | [Asynchronous Projections](asynchronous-projections.md#choose-query-freshness-separately) |
| Several targets must fence, rebuild, verify, and return to service together | Inline, async, or both in one catalog group | Chosen per query model | [Offline Projection Rebuilds](offline-projection-rebuilds.md) |

Choose inline delivery only when the target is local PostgreSQL state and the
writer can afford its latency, lock contention, and effect on event-store append
throughput. Inline handlers extend the append transaction and must always be
bounded and short-running. Choose asynchronous delivery when the view combines
many streams, does heavier work, has independent scaling needs, or may be
temporarily unavailable without rejecting commands.

## Separate Invariant State From Query Views

For an "ensure state note" operation, a small synchronous identity index can map
`(anchor type, anchor ID, property definition ID, state ID)` to the winning note
ID. Content, tags, display joins, search, and reporting belong in asynchronous
query targets. Preserve identity across archive when the business rule requires
reuse; record enough facts to reconstruct both targets deterministically.

The identity index is command authority even though events can rebuild it. It
must fail closed while unavailable; a lagging query view cannot replace it.
Declare separate owners and rebuild groups where dependencies allow independent
lifecycles. Avoid a foreign key from the identity index to an async row that may
not exist yet. Do not bypass genuine dependencies merely to split groups.

Use `runDomainCommandWithCatalogProjectionsGuarded` when that identity
precondition must participate in the command transaction. It resolves serving
bindings under the group fence, runs the precondition before projection apply,
and rolls back the append on `PreconditionRefused`.
[Guarded Catalog Commands](guarded-catalog-commands.md) gives the supported
recipe and callback boundaries.

Kiroku's append holds the global `$all` row lock until transaction end. Every
inline handler and post-append guard extends that interval and can delay unrelated
writers in the same store. Measure cumulative inline work and ordinary-writer
p95/p99 latency under mixed traffic before adopting it.

## Source Scope Is A Separate Choice

An inline handler sees the typed events emitted by the command path on which it
is installed. This limits its event scope; it does not make inline delivery the
default for aggregate-local query models.

A catalog source selects one Kiroku category or `AllStreams`. Use a
category when every relevant stream shares one category and unrelated traffic
should not determine the cursor. Use `AllStreams` for a genuinely global view.
Record that scope in the catalog's `SourceDeclaration`; it determines replay
selection and whether a query's `WaitForHead` request is reachable. Kiroku also
supports `CategoryNamespace` subscriptions for colon-separated category families;
that upstream target does not add a namespace source to Keiro's projection
catalog or DSL.

Source scope does not change delivery semantics. A category projection is still
at least once, and an all-stream query can still choose `Immediate` freshness.

## Delivery And Freshness Are Independent

`InlineProjection` and `AsyncProjection` answer *when an event is applied*.
`Immediate`, `WaitForHead`, and `WaitForPosition` answer *what a query waits for
before it executes*.

- An inline-only model normally uses `Immediate`. It has no subscription cursor
  that could advance while a query waits.
- An async model can also use `Immediate`; that explicitly accepts whatever lag
  exists when the SQL runs.
- `WaitForHead` captures a visible whole-store or category head and waits for
  the supplying subscription cursor to reach it.
- `WaitForPosition` waits for a caller-supplied `GlobalPosition`, usually the
  position returned by a command. It is the precise read-your-write option for
  an asynchronous model.

This separation prevents misleading combinations such as calling every async
query "eventually consistent" even when the caller explicitly waits, or giving
an inline-only model a fictional durable subscription.

## Prefer Catalog-Managed Projections

For new production code, declare targets, sources, rebuild groups, projection
owners, subscriptions, dedup identities, and query bindings in one
`ProjectionCatalog`. After validation, use its typed views:

```haskell
typedInlineProjections validatedCatalog orderProjectionSet
runCommandWithCatalogProjections
  options
  orderEventStream
  targetStream
  command
  validatedCatalog
  orderProjectionSet

applyAsyncProjectionFromCatalog
  validatedCatalog
  orderAuditProjectionId
  orderAuditAsyncProjection
  recorded
```

The managed runners acquire the rebuild-group fence in the same transaction as
the append or projection write. Catalog validation also checks ownership,
source, group, replay, subscription, dedup, and query-supplier relationships
before startup effects run.

`runCommandWithProjections`, `applyAsyncProjection`, and the
`unmanagedInlineProjections` / `unmanagedAsyncProjection` wrappers remain for
incremental migration. They do not provide the catalog's closed-world
validation. The compatibility runners also do not provide the group-wide fence
used by catalog rebuilds.

## Hand-Written And Generated Catalogs

The runtime model is the same whether the catalog is written in Haskell or
generated:

- Hand-written services construct `ProjectionCatalog`, `ProjectionSet event`,
  `InlineProjection`, and `AsyncProjection` values directly. The runnable
  Jitsurei example uses this path in
  [`Jitsurei.ReadModels`](../../jitsurei/src/Jitsurei/ReadModels.hs).
- Stable `keiro-dsl` Language 5 can generate a
  `Generated.<Context>.ProjectionCatalog` facade from `target`,
  `rebuild-group`, `projection-owner`, and catalog-bound `readmodel`
  declarations.

Generated code owns identities and wiring, but application code still owns
table migrations, SQL queries, live apply functions, replay adapters, and
verification transactions. Keiro cannot infer which tables arbitrary Hasql
transactions touch.

## A Useful Default

For a service starting from scratch:

1. Put every projection in one validated catalog, even if the first catalog has
   only one target.
2. Use async delivery for query models, including aggregate-local views.
3. Return command results directly, or use a bounded post-commit
   `WaitForPosition` when the response needs a projected view. Keep only the
   minimum state needed by a strict atomic invariant synchronous.
4. Give inline-only queries `Immediate` freshness. Give async queries
   `Immediate`, `WaitForHead`, or per-call `WaitForPosition` deliberately.
5. Supply an explicit replay adapter for reconstructible targets, keep
   live-only effects out of replay, and rebuild related targets as one group.

Continue with [Inline Projections](inline-projections.md),
[Asynchronous Projections](asynchronous-projections.md), or the complete
[Offline Projection Rebuilds](offline-projection-rebuilds.md) lifecycle. The
[Project Read Models](project-read-models.md) guide combines them in one example.
