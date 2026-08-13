# Asynchronous Projections

An `AsyncProjection` applies a durable `RecordedEvent` after the source command
has committed. A Kiroku subscription owns delivery and its checkpoint; Keiro
coordinates transactional deduplication, application-owned target SQL, catalog
fencing, and rebuild integration.

This mode keeps command latency and availability independent from the read
side. The tradeoff is lag and at-least-once delivery. Keiro does not provide a
projection drain loop: the application starts and supervises the Kiroku
subscription and invokes Keiro once per delivered event.

Kiroku's subscription package is
`mori://shinzui/kiroku/packages/kiroku-store`. The Keiro-side runnable example
is `orderAuditAsyncProjection` in
[`Jitsurei.ReadModels`](../../jitsurei/src/Jitsurei/ReadModels.hs).

## Define The Projection

`AsyncProjection` receives the recorded envelope rather than a statically typed
domain event. Decode with the source codec, condemn the transaction on an
unsupported event (or deliberately ignore an irrelevant event from a broader
source), and use a stable event identity for deduplication:

```haskell
orderAuditAsyncProjection :: AsyncProjection
orderAuditAsyncProjection =
  AsyncProjection
    { name = "jitsurei-order-audit-async"
    , readModelName = "jitsurei-order-summary"
    , subscriptionName = "jitsurei-order-audit-subscription"
    , applyRecorded = \recorded ->
        case decodeRecorded orderCodec recorded of
          Left _ -> Tx.condemn
          Right event -> applyOrderAuditEvent event recorded
    , idempotencyKey = (^. #eventId)
    }
```

`name` is the physical dedup identity. Keep it stable for as long as retained
dedup rows must suppress redelivery. `readModelName` and `subscriptionName` are
also used by compatibility paths and telemetry. A catalog-managed projection
binds these fields to stable logical projection, subscription, dedup, source,
and rebuild-group identities and rejects mismatches during validation.

The normal idempotency key is the source event's `EventId`. A different key is
valid only when it remains stable across every redelivery and replay of the same
logical application.

## Declare Delivery In The Catalog

An async handler belongs to a projection owner and refers to separately declared
subscription and dedup identities:

```haskell
orderAuditDefinition =
  ProjectionDefinition
    { projectionId = orderAuditProjectionId
    , rebuildGroup = orderReportingGroupId
    , ownedTargets = orderAuditTargetId :| []
    , replayPolicy =
        Replayable
          (replayAdapterFromCodec orderCodec applyOrderAuditEvent)
    , handlers =
        AsyncHandler
          orderAuditAsyncProjection
          orderAuditSubscriptionId
          orderAuditDedupId
          (claim "jitsurei:order-audit-async")
          :| []
    , claimSite = claim "jitsurei:order-audit-owner"
    }
```

The matching `SubscriptionDeclaration` chooses the source and the behavior when
the exact durable checkpoint row does not exist:

- `FromBeginning` creates position zero and consumes retained history.
- `FromCurrentHead` starts with future events only.
- `FailIfMissing` refuses startup until an operator provisions the member.

An existing checkpoint always wins; changing this policy never moves durable
progress. A replayable owner of a `ClearBeforeReplay` target cannot use
`FromCurrentHead`, because clearing the target and skipping history cannot
reconstruct it.

Configure the actual Kiroku subscription with the same name, source, group
membership, and missing-checkpoint policy declared by the catalog. Kiroku can
deliver `AllStreams` or one `Category`, with optional static consumer-group
membership. The catalog remains the application authority; do not let worker
configuration drift into an independent second inventory.

## Apply And Acknowledge One Delivery

Inside the subscription handler, run one catalog-aware application transaction:

```haskell
Store.runTransaction
  ( applyAsyncProjectionFromCatalog
      jitsureiProjectionCatalog
      orderAuditProjectionId
      orderAuditAsyncProjection
      recorded
  )
```

Map the result to the worker lifecycle deliberately:

| Keiro outcome | Target or dedup write | Worker action |
|---|---|---|
| `CatalogAsyncApplied` | Dedup key and target commit together | Acknowledge success (`Continue`) |
| `CatalogAsyncDuplicate` | No target write | Acknowledge success (`Continue`) |
| `CatalogAsyncFenced group run` | Nothing written | Leave the checkpoint before this event and retry after promotion |
| `CatalogAsyncGroupUnregistered group` | Nothing written | Fail startup/delivery and repair registration |
| `CatalogAsyncProjectionUnknown projection` | Nothing written | Fail startup/delivery and repair catalog wiring |

Do not map a fenced or misconfigured outcome to `Continue`, `Stop`, or
`DeadLetter`: each can advance the durable checkpoint past work that did not
happen. Surface an error or park the delivery through supervision so the same
event is attempted again. Kiroku's `Retry` result is bounded and dead-letters on
exhaustion, so use it for a projection fence only when that terminal behavior is
explicitly acceptable; an open-ended rebuild normally calls for failing the
handler and restarting the worker later without acknowledging the event.

Kiroku saves checkpoints per batch. A crash after target application but before
the checkpoint save causes redelivery. This is expected.

## Understand The Dedup Guarantee

`applyAsyncProjectionFromCatalog` inserts
`(projection_name, idempotency_key)` into Keiro's dedup table in the same
transaction as `applyRecorded`. Therefore:

- a failed target transaction does not retain a false dedup key;
- a committed target application retains its dedup key; and
- a later delivery with the same key returns `CatalogAsyncDuplicate` without
  running target SQL.

Delivery remains at least once. Application is exactly once while the matching
dedup key is retained. Keep target SQL naturally idempotent when practical as
defense in depth for operator mistakes and for events replayed after their dedup
rows were intentionally pruned.

Prune with `pruneAsyncProjectionDedupForBefore` only beyond the subscription
system's possible redelivery window. Pruning re-opens those events for
application. Preview the named projection and cutoff with
`countAsyncProjectionDedupForBefore` before mutation; do not use global pruning
when different projections have different retention needs.

## Choose Query Freshness Separately

An async projection's query can choose among three truthful behaviors:

- `Immediate` executes SQL now and accepts current lag. Build it with
  `immediateReadModel`; it may still retain `DurableQueryCursor subscription`
  for per-call waits.
- `WaitForHead scope` captures one reachable visible head, waits for the
  supplying durable cursor, then executes. Use `EntireVisibleLog` only for an
  all-stream subscription, or `CategoryVisibleHead category` for a compatible
  category source.
- `WaitForPosition options` waits for one concrete `GlobalPosition`. Use the
  append position returned to the caller for precise async read-your-write.

```haskell
blueprint =
  ReadModelBlueprint
    { cursorAuthority =
        DurableQueryCursor "jitsurei-order-audit-subscription"
    , ...
    }

eventualView = immediateReadModel blueprint
currentView = headWaitingReadModel (CategoryVisibleHead "order") blueprint

readYourWrite position =
  runQueryWithFreshness
    metrics
    (WaitForPosition (defaultHeadWaitOptions { target = Just position }))
    readModel
    queryInput
```

The catalog validates that a waiting query resolves through target ownership to
exactly one compatible durable cursor. An immediate query does not require a
cursor.

## Rebuild And Operate

During a catalog rebuild, live async applications return
`CatalogAsyncFenced` before inserting a dedup key or touching a target. The
rebuild runner uses the declared replay adapter, reset policy, source, target
order, and verification hooks. Promotion atomically restores the dedup state
needed for the captured redelivery window, advances declared checkpoint
members, records completion, and returns the group to `live`.

After each drain pass, `recordProjectionGlobalPositionDistance` can report the
non-negative distance from the newest visible event to the slowest durable
subscription member. A global position is an opaque cursor, so this is a
position distance, not an exact count of relevant category events.

Use [Project Read Models](project-read-models.md) for the mixed inline/async
catalog and its repair-and-resume rebuild, and
[Offline Projection Rebuilds](offline-projection-rebuilds.md) for the complete
fence, replay, verification, and promotion lifecycle. See
[Run And Operate Jitsurei](run-and-operate-jitsurei.md) for the inventory,
preview, and rebuild commands plus dedup-retention guidance.

## Async Checklist

- The command can commit before the target changes.
- The worker configuration matches the validated catalog declaration.
- The handler calls `applyAsyncProjectionFromCatalog` inside one store
  transaction per delivered event.
- Applied and duplicate outcomes acknowledge; fenced and invalid outcomes do
  not advance the checkpoint.
- The dedup name and key are stable across redelivery.
- Dedup retention exceeds the possible redelivery window.
- Query freshness is chosen independently from delivery mode.
- Replay adapters omit external or live-only effects.
