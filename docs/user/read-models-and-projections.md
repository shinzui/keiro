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
  , schema :: Text
  , subscriptionName :: Text
  , version :: Int
  , shapeHash :: Text
  , defaultConsistency :: ConsistencyMode
  , strongScope :: StrongScope
  , query :: q -> Tx.Transaction r
  }
```

`q` is your query input type. `r` is your result type. `schema` is the
PostgreSQL schema your read-model *data* table lives in (see
[Choosing Your Projection Schema](#choosing-your-projection-schema)); it is
entirely separate from Keiro's own `keiro` schema, where the `keiro_read_models`
registry lives.

Keiro still does not create your application read-model tables — your migrations
(or an opt-in helper) own the table *definitions*, indexes, and row codecs. What
Keiro now gives you is a first-class way to say *which schema* those tables live
in, and helpers to target it, instead of implicitly inheriting the store
connection's `search_path`. See [Migration Ownership](migration-ownership.md)
for where those migrations live and how to compose them with the framework
ledger.

## Choosing Your Projection Schema

By default an unqualified `CREATE TABLE my_read_model (...)` lands in the store
connection's first `search_path` schema — which is kiroku's `kiroku` event-store
schema — co-mingling your application data with the event store. To place your
read-model and projection tables in a schema you choose, use the `schema` field
on `ReadModel` together with the helpers in the `Keiro.Connection` module:

```haskell
import Keiro.Connection
  ( qualifyTable          -- schema -> table -> "schema"."table"
  , qualifiedTableName    -- imported from Keiro.ReadModel: a ReadModel's "schema"."table"
  , withProjectionSchema  -- add a projection schema to a store connection's extraSearchPath
  , keiroConnectionSettings  -- kiroku defaults + a projection schema on extraSearchPath
  , ensureProjectionSchema   -- opt-in CREATE SCHEMA IF NOT EXISTS, for dev/tests/examples
  )
import Keiro.ReadModel (ReadModel (..), qualifiedTableName)

orderSummary :: ReadModel OrderId (Maybe OrderSummary)
orderSummary =
  ReadModel
    { name = "order-summary"
    , tableName = "order_summary"
    , schema = "app_reads"          -- your chosen schema, NOT kiroku
    , subscriptionName = "order-summary-inline"
    , version = 1
    , shapeHash = "order-summary-v1"
    , defaultConsistency = Eventual
    , strongScope = EntireLog
    , query = \oid -> Tx.statement (orderIdText oid) selectOrderSummaryStmt
    }
```

Qualify every DDL and DML statement for that table against the schema. The
canonical reference is `qualifiedTableName orderSummary` (equal to
`qualifyTable "app_reads" "order_summary"`, i.e. `"app_reads"."order_summary"`),
interpolated into your SQL, so reads and writes resolve correctly regardless of
`search_path`:

```haskell
selectOrderSummaryStmt =
  preparable
    ("SELECT ... FROM " <> qualifiedTableName orderSummary <> " WHERE order_id = $1")
    encoder
    decoder
```

Open the store so the schema also resolves on the pool, and create it (in
development, tests, or worked examples — production DDL belongs in your
migrations):

```haskell
-- kiroku defaults with your projection schema on extraSearchPath;
-- the store `schema` stays "kiroku" (it also drives the NOTIFY channel).
Store.withStore (keiroConnectionSettings connString "app_reads") $ \store ->
  Store.runStoreIO store $ do
    ensureProjectionSchema "app_reads"           -- opt-in CREATE SCHEMA
    Store.runTransaction createOrderSummaryTable  -- your qualified CREATE TABLE
```

Keiro's own framework metadata (`keiro_read_models`, `keiro_projection_dedup`)
stays in the `keiro` schema and is unaffected by your choice.

## Consistency Modes

```haskell
data ConsistencyMode
  = Strong
  | Eventual
  | PositionWait PositionWaitOptions

data StrongScope
  = EntireLog
  | CategoryHead Text
```

Use:

- `Strong` for an async model that should wait for its subscription cursor to
  reach the log head captured at query start. Set `strongScope = EntireLog` only
  when the subscription observes the whole log; category subscriptions should
  use `CategoryHead category` so unrelated categories cannot cause a timeout.
- `Eventual` for async models where stale reads are acceptable.
- `PositionWait` when a caller has a target `GlobalPosition` and wants to wait
  until the subscription has processed at least that position.

Inline projections commit with their command and should normally use
`Eventual`: there is no asynchronous cursor to wait for. A model fed from
multiple categories should use an explicit `PositionWait` target or an
all-stream subscription with `EntireLog`.

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

Register each model once when its projection starts:

```haskell
registerReadModel
  (orderSummary ^. #name)
  (orderSummary ^. #version)
  (orderSummary ^. #shapeHash)
```

Queries never create registry rows. Before running the query transaction, Keiro
loads the registered metadata and checks:

- stored version equals the read model's version;
- stored shape hash equals the read model's shape hash;
- status is `Live`.

Failures are returned as `ReadModelError`; an unknown name returns
`ReadModelUnregistered` without changing the registry.

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
  orderEventStream  -- ValidatedEventStream
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
  , readModelName :: Text
  , subscriptionName :: Text
  , applyRecorded :: RecordedEvent -> Tx.Transaction ()
  , idempotencyKey :: RecordedEvent -> EventId
  }
```

`applyAsyncProjection` runs the projection's transaction body for one recorded
event. Worker wiring is application-owned and typically comes from a Kiroku /
Shibuya subscription source. It returns `AsyncApplied`, `AsyncDuplicate`, or
`AsyncFenced`. The worker must not checkpoint an `AsyncFenced` event; park or
fail the delivery and retry after the model is promoted. The fence is checked
inside the same transaction as the dedup insert and model update.

Async projections are at-least-once in v1. Make every async handler idempotent.
The usual table shape includes a unique `source_event_id` column:

```sql
INSERT INTO order_audit (source_event_id, order_id, message)
VALUES ($1, $2, $3)
ON CONFLICT (source_event_id) DO NOTHING;
```

## Rebuild Lifecycle

The supported offline workflow in `Keiro.ReadModel.Rebuild` is:

1. Register the model at projection startup.
2. Call `startRebuild model projectionNames replayFrom`. One transaction marks
   the model `Rebuilding`, fences normal writers, truncates the model table,
   clears only those projections' dedup keys, and resets the subscription cursor.
3. Replay events through `applyAsyncProjectionUnfenced`. Do not use that entry
   point in normal workers.
4. After replay and application-specific verification, call
   `finishRebuild model projectionNames replayFrom`. It refuses to promote a
   rebuild that applied nothing even though the log contains replayable events.
5. On failure, call `abandonRebuild` and keep the partial model offline while it
   is repaired or restored.

The low-level `rebuild` and `promote` functions change status only and bypass
the reset and promotion safeguards; they are not the operator workflow.

## Errors

`ReadModelError` values:

- `ReadModelStaleSchema`: code and stored metadata disagree.
- `ReadModelWaitTimeout`: position wait timed out.
- `ReadModelNotLive`: metadata status is not `Live`.
- `ReadModelUnregistered`: startup did not register this model name.

Treat stale schema and non-live errors as deployment/rebuild coordination
signals, not transient query misses.
