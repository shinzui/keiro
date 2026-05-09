# Kiroku Event Store — Current State Survey

Survey author: research subagent (Explore), 2026-05-04. Source tree: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

## Overview

`kiroku-store` is a high-performance PostgreSQL event store written in Haskell using `effectful`, `hasql`, and `hasql-pool`. It implements **Strategy E** (atomic row-level counter on the `$all` stream) for gap-free global ordering and read-your-own-writes semantics. The codebase is production-grade: ~30K events/second throughput, comprehensive error handling with specific exception constructors, atomic multi-stream transactions with deadlock avoidance, and live subscriptions with at-least-once delivery.

Kiroku separates **stream identity** (human-readable names with category prefixes like `order-1`) from **database identity** (surrogate `StreamId`), and uses a junction table (`stream_events`) to track membership across source streams, the global `$all` stream, and linked streams. The effect layer (`Effectful`) allows both interpretation against a real PostgreSQL pool and mocking for tests.

## Type Model

Core types live in `Kiroku.Store.Types:1–255`:

- **StreamName** — human-readable identifier (e.g., `"orders-1"`); unique per store. Category (prefix before first `-`) is used for category subscriptions.
- **StreamId** — database surrogate (Int64), stable for the stream row's lifetime; reused only after hard deletion.
- **EventId** — UUIDv7 by default, or caller-supplied for idempotent retries. `Ord` instance matches UUID byte order (rough time order, but not causally precise; use `globalPosition` for time ordering).
- **EventType** — free-form `Text` discriminator (e.g., `"OrderCreated"`); indexed for filtering.
- **StreamVersion** — monotonic per-stream counter (0-indexed: after N events, version is N). Event *i* has `streamVersion = i` (1-indexed within the stream).
- **GlobalPosition** — monotonic global counter across all streams, gap-free, strictly increasing per append. Starts at 0 (reserved seed row); first real event has position 1.
- **ExpectedVersion** — four variants enforce optimistic concurrency:
  - `NoStream` — stream must not exist; fails with `StreamAlreadyExists` if it does (for aggregate creation).
  - `StreamExists` — stream must exist and not be soft-deleted; fails with `StreamNotFound` if missing.
  - `ExactVersion v` — stream version must match exactly; fails with `WrongExpectedVersion` on mismatch.
  - `AnyVersion` — create if missing, append otherwise; maps to `INSERT ... ON CONFLICT DO UPDATE`.

`RecordedEvent` (the read shape) carries both source position (`originalStreamId`, `originalVersion`) and target position (`streamVersion` for links):

    eventId, eventType, payload (Value), metadata (Maybe Value),
    causationId, correlationId (Maybe UUID),
    streamVersion, globalPosition,
    createdAt (UTCTime)

`AppendResult` and `LinkResult` return stream ID, final stream version (last event), and (for appends) global position of last event.

`CategoryName` is extracted from `StreamName` prefix (substring before first `-`); used by `readCategory` and category subscriptions to fan-in events from multiple streams sharing a prefix.

## Append API

Signatures (`Kiroku.Store.Append:53–89`):

    appendToStream ::
        (HasCallStack, Store :> es) =>
        StreamName -> ExpectedVersion -> [EventData] -> Eff es AppendResult

    appendMultiStream ::
        (HasCallStack, Store :> es) =>
        [(StreamName, ExpectedVersion, [EventData])] -> Eff es [AppendResult]

Semantics:

1. **All-or-nothing per call**: if the precondition fails, the entire batch is rejected; no partial commits.
2. **Read-your-own-writes**: events are visible to subsequent reads on *this* store handle immediately. Other handles see events after their connection's transaction-visibility horizon advances (typically milliseconds).
3. **Return value**: `AppendResult` carries `streamId`, `streamVersion` (of the last event in batch), and `globalPosition` (of last event).

Expected-version handling:

- `NoStream` with existing stream → `StreamAlreadyExists` (includes soft-deleted streams).
- `StreamExists` with nonexistent/soft-deleted stream → `StreamNotFound`.
- `ExactVersion` mismatch → `WrongExpectedVersion (name, expected, actual)`; actual is current version or 0 if concurrent soft-delete occurred.
- `AnyVersion` always succeeds (barring duplicate event ID).

Idempotent retries (`Append:26–33`): supply `EventData.eventId` yourself and retry on transient failures. A retry whose previous attempt committed surfaces as `DuplicateEvent` (when `events_pkey` detail is parseable). A retry observing `WrongExpectedVersion` on `ExactVersion` is ambiguous (concurrent writer or own prior success); recovery is re-read and re-decide.

Error cases (`Error.hs:39–87`):

- `WrongExpectedVersion StreamName ExpectedVersion StreamVersion`
- `StreamNotFound StreamName`
- `StreamAlreadyExists StreamName`
- `DuplicateEvent (Maybe EventId)`
- `PoolAcquisitionTimeout`
- `ConnectionLost Text`
- `UnexpectedServerError Text Text`
- `ConnectionError Text`

Multi-stream appends (`Effect.hs:121–173`): atomic in one transaction. Caller pre-locks streams in deterministic `stream_id` order to avoid deadlocks. Per-stream errors are attributed to the responsible stream via `attributeMultiStreamError`. Either every per-stream append succeeds or all roll back.

Implementation (`Effect.hs:75–94`): single-stream uses `Pool.use`; multi-stream uses `TxSessions.transaction ReadCommitted Write`. UUIDv7 generation is deferred until the interpreter (`Effect.hs:253–273`): unused event IDs are generated in bulk, then assigned in order during event preparation.

## Read APIs

### Single-Stream Hydration

Forward read (`Read.hs:27–33`):

    readStreamForward ::
        StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)

Cursor is exclusive: events with `streamVersion > startVer` returned. Read from the beginning by passing `StreamVersion 0`. Empty `Vector` for nonexistent/soft-deleted streams. Limit caps batch size (pass a large value for "read everything").

Backward read (`Read.hs:44–50`): cursor exclusive (events with `streamVersion < startVer`). Pass `StreamVersion 0` to read latest backward; treated as "newer than any."

### Global Stream (`$all`)

Forward (`Read.hs:62–67`): GlobalPosition-ascending order, cursor exclusive. Seed row at position 0 is internal, never returned. `$all` contains every appended event including soft-deleted streams' events; hard-deleted events do not appear.

Backward (`Read.hs:69–80`): cursor exclusive, descending. Pass `GlobalPosition 0` to read from most recent backward.

### Category Fan-In

`readCategory` (`Read.hs:90–96`): events from all streams whose category (prefix before first `-`) matches, ordered by `GlobalPosition`. Linked events appear at their source position; category is the source's category.

### Stream Metadata

`getStream` (`Read.hs:104–108`): `Maybe StreamInfo` (Just for live and soft-deleted streams, Nothing for hard-deleted or never-created). `StreamInfo` carries `id`, `name`, `version` (event count), `createdAt`, `deletedAt`.

### Implementation Details

- All reads return `Vector RecordedEvent` (immutable vector, zero-copy slicing).
- Cursors are **exclusive in both directions** (start at 0 → events at 1, start at N → events at N+1). Enables simple pagination: `readStreamForward name lastVersion limit`.
- **No streaming**: reads are materialized in-memory as Vectors. For large streams, caller batches via the limit parameter and cursor.
- SQL (`SQL.hs:355–399`): shared `recordedEventRow` decoder (11 columns). Stream reads use `ix_stream_events_stream_version (stream_id, stream_version)`.
- **Soft-delete visibility**: soft-deleted streams' events remain visible in `$all` and category reads. Single-stream reads return empty.

## Subscriptions Hook

Kiroku provides live subscription infrastructure (`Subscription.hs`, `Subscription/Types.hs`); shibuya integrates this; kiroku provides the primitives.

Subscribe (`Subscription.hs:90–114`):

    subscribe :: (MonadIO m) =>
        KirokuStore -> SubscriptionConfig -> m SubscriptionHandle

Returns a handle with `cancel` and `wait`. Worker thread spawns; handles checkpoint persistence, catch-up from database, and live broadcast via an `EventPublisher`.

Delivery semantics (`Subscription.hs:43–67`): at-least-once. Checkpoint saved per batch. If handler returns Continue for batch tail and the worker crashes before `saveCheckpoint`, batch replays on next subscription start. Handlers must tolerate replay.

Targets (`Subscription/Types.hs:27–32`): `AllStreams` (global position order, bounded queue per subscriber) and `Category CategoryName` (category filter, re-queries database as publisher advances).

Overflow policy (`Subscription/Types.hs:42–64`): `DropSubscription` (default, slow subscriber shut down → `SubscriptionOverflowed` exception); `DropOldest` (drop oldest batch, continue).

Config (`Subscription/Types.hs:85–135`):

    data SubscriptionConfig = SubscriptionConfig
      { name :: SubscriptionName
      , target :: SubscriptionTarget
      , handler :: EventHandler  -- RecordedEvent -> IO SubscriptionResult
      , batchSize :: Int32
      , queueCapacity :: Natural
      , overflowPolicy :: OverflowPolicy
      }

Publisher (`Subscription.hs:24–36`): internal `EventPublisher` broadcasts appended events. AllStreams subscribers read from a bounded per-subscriber queue; Category subscribers re-query on publisher advance. Checkpoint saved per batch in `subscriptions` table (`subscription_name`, `last_seen` position).

## Snapshots

**No snapshot support yet.** Events are always replayed from version 0.

Where snapshots could live:

1. Separate snapshot stream (e.g., `order-1-snapshot`) — snapshots as events. Couples snapshot lifecycle to the event stream.
2. Sidecar table — `aggregate_snapshots (stream_id, version, state_jsonb)`. Decoupled from events; hydration: read snapshot, then catch-up from `snapshot_version+1`.
3. In-event metadata — mark certain events as "good-enough snapshots"; hydration picks the latest and replays thereafter.

For keiro the **sidecar table** is the natural fit — opt-in per aggregate type, decoupled lifecycle, simple GC.

## Storage & Migrations

Schema (`schema.sql:1–160`):

- **streams**: `stream_id BIGSERIAL`, `stream_name TEXT UNIQUE`, `category` (generated as substring before first `-`), `stream_version BIGINT default 0`, `created_at`, `deleted_at`. Seed row (`stream_id=0`, name `$all`) reserved for global counter. Sequence reset to MAX(`stream_id`) after seed insertion.
- **events**: `event_id UUID PK default uuidv7()`, `event_type TEXT`, `causation_id`, `correlation_id`, `data JSONB`, `metadata` (Maybe JSONB), `created_at TIMESTAMPTZ`.
- **stream_events** (junction): `(event_id, stream_id)` PK, `original_stream_id`, `original_stream_version`. Immutable (INSERT only; DELETE forbidden without `kiroku.enable_hard_deletes`).
- **subscriptions**: `subscription_name UNIQUE`, `stream_name DEFAULT '$all'`, `last_seen BIGINT`, `created_at`, `updated_at`.

Indexes:

- `ix_stream_events_stream_version (stream_id, stream_version)`
- `ix_events_event_type`, `ix_events_correlation_id`, `ix_events_causation_id`
- `ix_streams_category`
- `ix_stream_events_all_by_origin (original_stream_id, stream_version) WHERE stream_id=0`

Triggers:

- `notify_events()` AFTER INSERT/UPDATE on streams — `pg_notify` fires once per append (not per event) with `stream_name`, `stream_id`, `stream_version`.
- `prevent_mutation()` BEFORE UPDATE on events, stream_events.
- `protect_deletion()` BEFORE DELETE/TRUNCATE — gated by `SET LOCAL kiroku.enable_hard_deletes = 'on'`.

Initialization (`Schema.hs:58–70`): `initializeSchema pool _schema` runs embedded `schema.sql` as idempotent DDL via hasql scripting.

Transactional guarantees:

- Single-stream appends execute within one CTE (all-or-nothing at SQL level).
- Multi-stream appends use `TxSessions.transaction ReadCommitted Write` with pre-locking.
- Hard-deletes run in one transaction.

**No migration tooling in kiroku itself** — schema.sql is embedded and run once at app startup. Future schema evolution should use `codd` or `hasql-migration` (per `docs/plans/partition-ready-schema.md`).

## Effectful Surface

Effect declaration (`Effect.hs:48–61`):

    data Store :: Effect where
        AppendToStream :: StreamName -> ExpectedVersion -> [EventData] -> Store m AppendResult
        ReadStreamForward :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
        ReadStreamBackward :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
        ReadAllForward :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
        ReadAllBackward :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
        GetStream :: StreamName -> Store m (Maybe StreamInfo)
        LinkToStream :: StreamName -> [EventId] -> Store m LinkResult
        ReadCategoryForward :: CategoryName -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
        AppendMultiStream :: [(StreamName, ExpectedVersion, [EventData])] -> Store m [AppendResult]
        SoftDeleteStream :: StreamName -> Store m (Maybe StreamId)
        HardDeleteStream :: StreamName -> Store m (Maybe StreamId)
        UndeleteStream :: StreamName -> Store m (Maybe StreamId)

    type instance DispatchOf Store = Dynamic

`Store :> es` constraint; dynamic dispatch, mockable.

Interpreter (`Effect.hs:68–202`):

    runStorePool ::
        (IOE :> es, Error StoreError :> es) =>
        KirokuStore -> Eff (Store : es) a -> Eff es a

`KirokuStore` carries pool, publisher, optional event handler. Pool is `Hasql.Pool.Pool` (created via `withStore`).

Resource effect (`Effect/Resource.hs:34–54`): `KirokuStoreResource` (`Static WithSideEffects`) carries the handle; `withKirokuStore settings action` acquires and installs.

Convenience: `runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)`.

**No type-level constraints on payloads**: `EventData.payload` is `Value`. There is no codec framework. Keiro must add typed payloads.

## Concurrency Guarantees

- **Optimistic concurrency control** via `ExpectedVersion`. No application-layer locks.
- **Idempotency keys** via caller-supplied `EventData.eventId`. A retry of the same id either succeeds (prior attempt rolled back) or surfaces `DuplicateEvent`.
- **Deduplication** via `events_pkey` uniqueness on `event_id`.
- **No partition/serial keys** in kiroku.
- **Advisory locks** used only by `appendMultiStream` to pre-lock streams in `stream_id` order.
- **MVCC safety**: Strategy E uses atomic UPDATE+RETURNING on the `$all` row to claim contiguous `globalPositions`. Throughput ceiling ~50K events/s.
- **Soft-deletes**: `deleted_at` timestamp prevents new appends. Hard deletes require `SET LOCAL kiroku.enable_hard_deletes = 'on'`.

## Tests Worth Reading

`Main.hs:34–449`:

- Append variants (39–127): NoStream, StreamExists, ExactVersion, AnyVersion. Batch append. Global-position contiguity.
- Idempotency (129–155): duplicate event ID rejection.
- Pagination (191–211): forward cursor, exclusive semantics.
- Read paths (157–227): forward/backward/all/order/version. Read-your-own-writes.
- Empty/nonexistent streams (237–240): empty Vector, no exception.
- Integration (263–301): full cycle (append multiple streams, read stream, read $all, getStream).
- Linking (306–425): single/multiple, version bump, soft-deleted target rejection.
- Category reads (429–449): fan-in, pagination, global-position order.

Property tests (`Test/Properties.hs`); concurrency tests (`Test/Concurrency.hs`); failure injection (`Test/FailureInjection.hs`).

## Gaps for Keiro

1. **No typed payload codecs** — `EventData.payload` is raw `Value`. Keiro must add a codec layer (typeclass, profunctor optics, or generic-derived) and version-evolution helpers.
2. **No typed `StreamId` per aggregate** — `StreamName` is untyped `Text`. Keiro must define `newtype AggregateId a = AggregateId StreamName`.
3. **No snapshot read/write API** — replay from version 0 is N/A for large streams. Keiro must add a sidecar table and load-with-fallback hydration.
4. **No read-decide-append combinator** — the optimistic-concurrency cycle is implicit in tests; keiro needs a first-class API.
5. **No batched/multi-stream hydration helper** — `appendMultiStream` covers atomic append; keiro must add the symmetric load+decide helper for multi-stream commands.
6. **No subscription projection-rebuild helper** — primitives are low-level; keiro needs a "rebuild from scratch" or "catch up slow subscriber" combinator.
7. **No serialization/encryption hooks** — no `enrichEvent` interpreter hook. Out-of-band only.
8. **No correlation/causation helpers** — fields are stored, but no tracing-context injection or chain-walking helpers.
9. **No point-in-time replay** — no API to read events up to a timestamp/global position.
10. **No first-class transaction primitive** that wraps `read → append` for single streams (only `appendMultiStream` opens a tx).

### Top 5 most consequential gaps

- No snapshot read/write API.
- No typed payload codecs.
- No typed `StreamId` per aggregate type.
- No read-decide-append combinator with retry on `WrongExpectedVersion`.
- No subscription projection-rebuild helper.
