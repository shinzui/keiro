# Choosing A Projection

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
| The command must not succeed unless the derived row is updated | `InlineProjection` | Usually `Immediate` | [Inline Projections](inline-projections.md) |
| A router or process manager must update the target aggregate's local view with its dispatched command | `targetProjections` with `InlineProjection` | `Immediate` | [Inline Projections](inline-projections.md#reactor-dispatch) |
| Reporting, search, or analytics can lag behind writes | `AsyncProjection` over a Kiroku subscription | `Immediate` | [Asynchronous Projections](asynchronous-projections.md) |
| A query must include everything visible when the query begins | `AsyncProjection` | `WaitForHead` | [Asynchronous Projections](asynchronous-projections.md#choose-query-freshness-separately) |
| A caller must observe one command's returned global position | `AsyncProjection` | `WaitForPosition` | [Asynchronous Projections](asynchronous-projections.md#choose-query-freshness-separately) |
| Several targets must fence, rebuild, verify, and return to service together | Inline, async, or both in one catalog group | Chosen per query model | [Offline Projection Rebuilds](offline-projection-rebuilds.md) |

Choose inline delivery only when the target is local PostgreSQL state and the
writer can afford its latency, lock contention, and effect on event-store append
throughput. Inline handlers extend the append transaction and must always be
bounded and short-running. Choose asynchronous delivery when the view combines
many streams, does heavier work, has independent scaling needs, or may be
temporarily unavailable without rejecting commands.

## Source Scope Is A Separate Choice

An inline handler sees the typed events emitted by the command path on which it
is installed. It is therefore the natural fit for a view local to that
aggregate's writes.

An asynchronous worker can consume one Kiroku category or `AllStreams`. Use a
category when every relevant stream shares one category and unrelated traffic
should not determine the cursor. Use `AllStreams` for a genuinely global view.
Record that scope in the catalog's `SourceDeclaration`; it determines replay
selection and whether a query's `WaitForHead` request is reachable.

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
- Candidate `keiro-dsl` language 5 can generate a
  `Generated.<Context>.ProjectionCatalog` facade from `target`,
  `rebuild-group`, `projection-owner`, and catalog-bound `readmodel`
  declarations. Language 5 is unreleased; adopting it is an explicit candidate
  language upgrade, not a silent change to language 1–4 programs.

Generated code owns identities and wiring, but application code still owns
table migrations, SQL queries, live apply functions, replay adapters, and
verification transactions. Keiro cannot infer which tables arbitrary Hasql
transactions touch.

## A Useful Default

For a service starting from scratch:

1. Put every projection in one validated catalog, even if the first catalog has
   only one target.
2. Use inline delivery for a small local view that is part of command success.
3. Use async delivery for cross-stream or independently operated views.
4. Give inline-only queries `Immediate` freshness. Give async queries
   `Immediate`, `WaitForHead`, or per-call `WaitForPosition` deliberately.
5. Supply an explicit replay adapter for reconstructible targets, keep
   live-only effects out of replay, and rebuild related targets as one group.

Continue with [Inline Projections](inline-projections.md),
[Asynchronous Projections](asynchronous-projections.md), or the complete
[Offline Projection Rebuilds](offline-projection-rebuilds.md) lifecycle. The
[Project Read Models](project-read-models.md) guide combines them in one example.
