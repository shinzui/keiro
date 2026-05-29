# Read Models And Projections

Read models are query-optimized views derived from the event log. Keiro provides
metadata, consistency helpers, inline projection support, and at-least-once async
projection helpers.

## Initialize Metadata

The `keiro_read_models` table — which stores each model's version, shape hash,
status, and build timestamp — is created by `keiro-migrate`; see
[Database Migrations](migrations.md). Tests get it from the migrated template
database (the `keiro-test-support` `withMigratedSuite` fixture).

## Define A ReadModel

```haskell
data ReadModel q r = ReadModel
  { name :: Text
  , tableName :: Text
  , subscriptionName :: Text
  , version :: Int
  , shapeHash :: Text
  , defaultConsistency :: ConsistencyMode
  , query :: q -> Tx.Transaction r
  }
```

`q` is your query input type. `r` is your result type.

Keiro does not create your application read-model tables. Your migrations own
those tables, indexes, and row codecs.

## Consistency Modes

```haskell
data ConsistencyMode
  = Strong
  | Eventual
  | PositionWait PositionWaitOptions
```

Use:

- `Strong` for read models updated inline in the same transaction as the
  command append.
- `Eventual` for async models where stale reads are acceptable.
- `PositionWait` when a caller has a target `GlobalPosition` and wants to wait
  until the subscription has processed at least that position.

`PositionWaitOptions`:

```haskell
data PositionWaitOptions = PositionWaitOptions
  { target :: Maybe GlobalPosition
  , timeoutMicros :: Int
  , pollMicros :: Int
  }
```

If `target = Nothing`, `PositionWait` does not wait.

## Querying

```haskell
runQuery readModel input
runQueryWith consistency readModel input
```

Before running the query transaction, Keiro registers or loads metadata and
checks:

- stored version equals the read model's version;
- stored shape hash equals the read model's shape hash;
- status is `Live`.

Failures are returned as `ReadModelError`.

## Inline Projections

Inline projections run inside the command append transaction.

```haskell
data InlineProjection co = InlineProjection
  { name :: Text
  , apply :: co -> RecordedEvent -> Tx.Transaction ()
  }
```

`apply` receives the decoded event together with its per-event `RecordedEvent`,
so a projection can read event metadata (actor, source event id, stream version,
global position) when writing the read-model row.

Use `runCommandWithProjections`:

```haskell
runCommandWithProjections
  defaultRunCommandOptions
  orderEventStream
  orderStream
  command
  [orderSummaryProjection]
```

If projection SQL fails or condemns the transaction, the append rolls back.
This is the path for strongly consistent read-after-write behavior.

See [Project Read Models](../guides/project-read-models.md) for the
`jitsurei_order_summary` table, inline projection, and `ReadModel` query backed
by `jitsurei-test`.

## Async Projections

```haskell
data AsyncProjection = AsyncProjection
  { name :: Text
  , subscriptionName :: Text
  , applyRecorded :: RecordedEvent -> Tx.Transaction ()
  , idempotencyKey :: RecordedEvent -> EventId
  }
```

`applyAsyncProjection` runs the projection's transaction body for one recorded
event. Worker wiring is application-owned and typically comes from a Kiroku /
Shibuya subscription source.

Async projections are at-least-once in v1. Make every async handler idempotent.
The usual table shape includes a unique `source_event_id` column:

```sql
INSERT INTO order_audit (source_event_id, order_id, message)
VALUES ($1, $2, $3)
ON CONFLICT (source_event_id) DO NOTHING;
```

## Rebuild Lifecycle

`Keiro.ReadModel.Rebuild` exposes:

- `rebuild` to mark a model `Rebuilding`;
- `promote` to mark it `Live`;
- `abandonRebuild` to mark it `Abandoned`.

Use version and shape-hash changes to force stale readers to fail closed while a
new model is being rebuilt.

## Errors

`ReadModelError` values:

- `ReadModelStaleSchema`: code and stored metadata disagree.
- `ReadModelWaitTimeout`: position wait timed out.
- `ReadModelNotLive`: metadata status is not `Live`.

Treat stale schema and non-live errors as deployment/rebuild coordination
signals, not transient query misses.
