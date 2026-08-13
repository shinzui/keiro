# Inline Projections

An `InlineProjection event` applies a decoded domain event in the same
PostgreSQL transaction as the append that produced it. Either the event and all
projection SQL commit, or neither does. Use it when updating the view is part of
the command's success contract.

The Jitsurei order summary is the complete example in
[`Jitsurei.ReadModels`](../../jitsurei/src/Jitsurei/ReadModels.hs).

## Define The Live Handler

An inline projection has a stable operational name and one Hasql transaction
for each event:

```haskell
orderSummaryInlineProjection :: InlineProjection OrderEvent
orderSummaryInlineProjection =
  InlineProjection
    { name = "jitsurei-order-summary-inline"
    , apply = applyOrderEventLive
    }
```

The handler also receives the durable `RecordedEvent` envelope. Use its event
ID, global position, stream identity, or metadata when the target needs source
provenance:

```haskell
applyOrderEventLive :: OrderEvent -> RecordedEvent -> Tx.Transaction ()
applyOrderEventLive event recorded =
  case event of
    OrderPlaced placed ->
      Tx.statement
        ( orderIdText placed.orderId
        , globalPositionToInt recorded.globalPosition
        )
        upsertOrderSummaryStmt
    -- Handle every remaining OrderEvent constructor.
```

Keep this transaction small and deterministic. PostgreSQL constraints and an
event-position guard on the target row are useful defenses when more than one
path can touch the same table.

## Protect Event-Store Throughput

An inline projection is part of the event-store append transaction, not work
performed after the append. The transaction stays open while every inline
handler runs and retains the locks acquired by the append and catalog group
until commit. A slow handler therefore increases command latency and lock
contention and can reduce the throughput of otherwise unrelated event-store
work that needs conflicting locks.

Budget the cumulative cost and number of inline projections against the
store's required append throughput, not only against one command's latency.
Keep their SQL local, indexed, bounded, and predictably fast. An inline handler
must never deliberately hold a long-running PostgreSQL transaction: do not make
network calls, wait or sleep, perform unbounded scans, or run maintenance work
inside it. Move work to an asynchronous projection whenever it is not required
for command success or cannot reliably finish within the append transaction's
short latency budget.

## Give Replay Its Own Adapter

The live handler is not automatically a safe rebuild handler. Catalog ownership
records replay behavior separately:

```haskell
orderSummaryDefinition :: ProjectionDefinition OrderEvent
orderSummaryDefinition =
  ProjectionDefinition
    { projectionId = orderSummaryProjectionId
    , rebuildGroup = orderReportingGroupId
    , ownedTargets = orderSummaryTargetId :| [orderLineTargetId]
    , replayPolicy =
        Replayable
          (replayAdapterFromCodec orderCodec applyOrderEventForReplay)
    , handlers =
        InlineHandler
          orderSummaryInlineProjection
          (claim "jitsurei:order-summary-inline")
          :| []
    , claimSite = claim "jitsurei:order-summary-owner"
    }
```

Jitsurei's live function writes both the reconstructible order rows and a
test-observable live-side-effect row. Its replay adapter calls only
`applyOrderEventForReplay`, so rebuilding does not repeat the live-only action.
Use `LiveOnly reason` instead of `Replayable adapter` when there is no truthful
historical application path.

Target reset policy is another independent choice. `ClearBeforeReplay` says the
target can be emptied before replay. `PreserveAndReconcile` keeps brownfield or
partially historical rows in place and requires the replay and verification
logic to reconcile them safely.

## Run Commands Through The Catalog

Select inline handlers through the same typed `ProjectionSet event` that was
validated as part of the catalog:

```haskell
result <-
  runCommandWithCatalogProjections
    defaultRunCommandOptions
    orderEventStream
    (orderStream orderId)
    command
    jitsureiProjectionCatalog
    orderProjectionSet
```

The runner:

1. decides and appends the command's events;
2. locks every catalog rebuild group reached by the projection set;
3. applies each inline handler to the emitted events in order; and
4. commits the append and target writes together.

Handle every `ProjectionCommandOutcome` explicitly. `ProjectionCommandApplied`
means the transaction committed. `ProjectionCommandFenced` means a rebuild or
failed group rejected the write and the append was rolled back.
`ProjectionCommandGroupUnregistered` and `ProjectionCommandCatalogMismatch`
are deployment or wiring errors, not successful commands.

For typed rejections and no-ops, use
`runDomainCommandWithCatalogProjections`. It runs projection SQL only for an
accepted event batch. A domain rejection or no-op returns its
`DomainCommandOutcome` without acquiring a projection fence or invoking a
handler.

The older `runCommandWithProjections` and
`runDomainCommandWithProjections` functions still run supplied projections in
the append transaction, but they do not validate ownership or consult catalog
rebuild-group fences. Keep them as an explicit compatibility boundary while
migrating existing code.

## Reactor Dispatch

Routers and process managers can attach inline handlers to each command they
dispatch:

```haskell
targetProjections = const orderLiveProjections
```

Use a non-empty `targetProjections` only when the router, the next process
manager decision, or an immediate reader needs the target aggregate's local
view to reflect that dispatched command. Use `const []` for ordinary fan-out,
reporting, analytics, integration publishing, and any view that can be updated
asynchronously.

These hooks run the projection in each target command's append transaction, but
the current router and process-manager paths use the compatibility inline
runner. They do not acquire catalog rebuild-group fences. Do not point them at a
catalog-managed target that may be rebuilt unless the deployment supplies
equivalent exclusion; prefer async delivery when that coordination is not
available.

See [Routers And Effectful Fan-Out](routers-and-effectful-fan-out.md) and
[Process Managers And Timers](process-managers-and-timers.md) for their complete
dispatch lifecycles.

## Query The Inline View

An inline-only read model has no durable subscription cursor. Construct it with
`NoQueryCursor` and normally choose immediate freshness:

```haskell
orderSummaryReadModel =
  immediateReadModel
    ReadModelBlueprint
      { name = "jitsurei-order-summary"
      , tableName = "jitsurei_order_summary"
      , schema = "jitsurei"
      , version = 1
      , shapeHash = "jitsurei-order-summary-v1"
      , cursorAuthority = NoQueryCursor
      , query = queryOrderSummary
      }
```

`WaitForHead` is not useful for an inline-only model: no subscription cursor can
advance while the query waits. If the same catalog owner also has a compatible
async handler for the query's targets, model that durable cursor truthfully and
choose freshness from the
[asynchronous guide](asynchronous-projections.md#choose-query-freshness-separately).

## Inline Checklist

- The target write is required for command success.
- The cumulative inline work is balanced against the event store's required
  append throughput and lock-contention budget.
- The SQL is local, indexed, bounded, and predictably fast; the handler never
  holds a long-running PostgreSQL transaction.
- The catalog is registered before commands are accepted.
- The command path uses `runCommandWithCatalogProjections` when catalog rebuilds
  can occur.
- Live-only behavior is absent from the replay adapter.
- The query uses `Immediate` unless a real async cursor supplies it.
- A projection failure and every fenced outcome are surfaced as command
  failures, never reported as a committed append.

See [Offline Projection Rebuilds](offline-projection-rebuilds.md) for replaying
the catalog adapter while live inline writers are fenced.
