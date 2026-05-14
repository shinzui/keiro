# Read Model Query API and Lifecycle Design

This document fixes how applications *query* state derived from events: the typed `ReadModel q r` wrapper exposed by `Keiro.ReadModel`, the read-after-write consistency-mode taxonomy (`Strong` / `Eventual` / `PositionWait`), the schema-evolution and rebuild-from-zero protocol, the multi-stream read-model story, the idempotency-token propagation pattern, and the relationship between read models, snapshots, and projections (three primitives with overlapping mechanisms but distinct purposes). The reader is assumed to have read `docs/research/01-kiroku-read-side.md`, `docs/research/06-command-cycle-design.md` (EP-1's design), `docs/research/08-subscription-and-process-manager-design.md` (EP-3's design — *the* closest neighbour), and `docs/research/09-snapshot-strategy.md` (EP-4's snapshot design — for the read-model-vs-snapshot distinction). Where a key fact from those documents matters here it is repeated; the reader who has not seen them should still be able to follow this design.

This is a research document produced by ExecPlan EP-8 of the research-foundation MasterPlan (`docs/masterplans/1-keiro-research-foundation.md`). The accompanying spike at `spikes/read-model/` validates the typed API, all three consistency modes, and the position-wait failure mode.


## 1. Purpose

EP-3's `docs/research/08-subscription-and-process-manager-design.md` covers the *write side* of read models: the three projection lifecycles that maintain read-model rows (inline / async / live), the at-least-once delivery semantics that follow from `shibuya-kiroku-adapter` advancing kiroku's `subscriptions.last_seen` in a separate connection from the projection write, and the consequent idempotency requirement on user-supplied projection functions. EP-4's `docs/research/09-snapshot-strategy.md` covers snapshots: a sidecar `keiro_snapshots` table caching folded aggregate state for `runCommand`'s hydration phase, advisory and fall-through-on-failure.

Neither plan covers the *read side as a queryable surface*. This document fills that gap. After reading this document, an application author can answer:

- **What is a read model?** A denormalized, queryable representation of state derived from one or more event streams. Lives in Postgres tables maintained by a projection worker. Externally queryable by application code via a typed API exposed by keiro.
- **How do I query a read model?** Through `runQuery :: ReadModel q r -> q -> Eff es r`, where `ReadModel q r` is a typed wrapper carrying the table name, query function, codec, version, shape hash, and a default consistency mode.
- **What consistency can I rely on after a command?** One of three modes: *Strong* (inline projection — read after write sees the new state immediately, in the same transaction), *Eventual* (async projection — read may briefly see stale state), or *PositionWait* (async projection plus a caller-side wait — `waitFor :: ReadModel q r -> GlobalPosition -> Eff es ()` blocks until the projection's `subscriptions.last_seen` advances past the appended event's `globalPosition`).
- **How do I rebuild a read model whose schema changed?** Through the `keiro_read_models(name, version, shape_hash, last_built_at)` metadata table and a shadow-table swap protocol: bump the version, populate a `<name>_v<new_version>` shadow table by replay-from-zero, then atomically `RENAME` to swap. The live projection continues serving the old table until the swap.
- **How do read models relate to snapshots and projections?** Three primitives with distinct purposes. *Snapshots* (EP-4) accelerate `runCommand`'s hydration; advisory; never queried by application code. *Projections* (EP-3) are the *workers* (the verb) that consume events and update read-model rows. *Read models* (this document) are the *queryable artefacts* (the noun) — externally queried, lifecycle-managed, version-and-shape-hash gated.
- **What happens to my read model if the projection crashes mid-way?** The projection is re-driven from the last committed `subscriptions.last_seen` (kiroku's checkpoint table). Because the async lifecycle is at-least-once, the projection function must be idempotent — keiro propagates the source event's id onto the read-model row through a `source_event_id UUID UNIQUE` column so duplicate writes are detectable.

The contract this document fixes is `Keiro.ReadModel`, a small public module exposing the `ReadModel q r` record, `runQuery`, `waitFor`, and the rebuild orchestration helpers. The implementation MasterPlan inherits the contract verbatim.


## 2. Definitions

The terms defined here are used throughout this document and the implementation MasterPlan that follows. Each term is defined in plain language and anchored to a concrete keiro artefact.

**Read model.** A denormalized, queryable representation of state derived from one or more event streams. Concretely: a Postgres table whose rows are written by a projection worker and read by application code. A read model has a stable name (e.g., `counter_view`), a versioned schema (incremented on incompatible changes), and a consistency-mode default for queries against it.

**Projection.** The worker process that consumes events and writes/updates read-model rows. Three lifecycles, owned by EP-3:
- *Inline*: runs in the same Postgres transaction as the event append (via the transactional-step combinator from EP-1 §10). Strong consistency. EP-3 §3 trade-off: a slow projection slows every command on that aggregate; an exception in the projection rolls back the append.
- *Async*: a separate worker subscribes to the event stream and updates read-model rows out-of-band. Eventual consistency. At-least-once delivery; idempotent projection function required (EP-3 §3 again).
- *Live*: state is computed on read by folding events; no persisted read-model rows. Useful for low-frequency queries or low-cardinality entities.

**Read-after-write consistency.** The guarantee a caller has when reading a read model immediately after a command. Three modes (this document's §3 taxonomy):
- *Strong*: read sees post-write state with no waiting. Only valid when the read model is fed by an inline projection.
- *Eventual*: read may briefly see stale state. Always valid; implies the application tolerates or hides the lag (e.g., optimistic UI).
- *PositionWait*: caller blocks until the projection's `subscriptions.last_seen` ≥ a target `GlobalPosition` (typically the position returned by the command that triggered the relevant event), then reads. Valid for async projections.

**Read-model rebuild.** The act of repopulating a read-model table by replaying events from `globalPosition = 0`. Required when (a) the read-model schema changes incompatibly, (b) the projection logic is fixed (was wrong, now correct), or (c) an operator decides to repair drift. The protocol must allow rebuild to run alongside the live projection without serving stale state during the rebuild window — keiro's protocol uses a shadow table populated in the background and atomically swapped in at the end.

**Read-model row id.** Each read-model row is keyed by a primary key chosen by the application (e.g., a `streamId` for one-row-per-aggregate views, or a synthetic id for multi-row views). The keiro framework does not impose a key shape; it imposes a *uniqueness constraint* on `source_event_id UUID NOT NULL UNIQUE` so the at-least-once async lifecycle's duplicate writes are detectable.

**Position-wait helper.** `waitFor :: ReadModel q r -> GlobalPosition -> Eff es ()`. Polls kiroku's `subscriptions(subscription_name, last_seen)` table for the projection that feeds the named read model, returning when `last_seen` ≥ the target position. Configurable per-call timeout; on timeout returns a `WaitTimeout` error in `Eff es`'s error channel.

**Shape hash.** A stable hex digest computed over the read-model row's compiled schema (column names, column types, keiro version). Stored both on the in-memory `ReadModel` value (computed at compile or first-use time) and on each row of `keiro_read_models` (persisted at last successful rebuild). A query against a read model whose persisted shape hash mismatches the compiled value returns a `ReadModelStaleSchema` error rather than silently serving rows whose layout has drifted. Mirrors EP-4's `regfile_shape_hash` (`docs/research/09-…` §2, §6) but with a stronger semantics: snapshots fall through on hash mismatch, read models hard-fail.

**Source event id.** The `EventData.eventId :: UUID` of the kiroku event whose application caused the read-model row to be written. Propagated onto the read-model row as `source_event_id UUID NOT NULL UNIQUE`. Enables duplicate-detection under at-least-once async delivery: re-applying an event whose id is already on a row is a no-op.

**Multi-stream read model.** A read model whose rows are derived from events across more than one event-stream type — e.g., an `OrderView` that aggregates events from both `Order` and `Payment` streams. Implemented by subscribing the projection to a kiroku *category subscription* (events for any stream whose name matches a prefix). The category-subscription primitive may need a kiroku enhancement; §7 records the gap.

**`Keiro.ReadModel`.** The public Haskell module this document specifies. Exposes `ReadModel q r`, `runQuery`, `waitFor`, the `ConsistencyMode` constructor set, and the rebuild orchestration helpers. The exact module shape is fixed in §5.


## 3. The Consistency-Mode Taxonomy

Three consistency modes, each anchored to a projection lifecycle and exposed by the `ReadModel q r` API. The mode is declared on the `ReadModel` value as the default and may be overridden per-call when needed.


### 3.1 Strong

**Mechanism.** The read model is fed by an *inline projection* (EP-3 §3). The projection runs in the same Postgres transaction as the event append, via the transactional-step combinator (`docs/research/06-…` §10). When `runCommand` returns success, the read-model rows it touched are already committed.

**Reader contract.** A `runQuery readModel q` call issued *after* a successful `runCommand` sees post-write state with zero latency overhead. No polling, no waiting. The read may even share the *same* connection if the application chooses (the transaction has committed by the time `runCommand` returns; subsequent reads on any connection see the new rows).

**Failure mode.** A slow inline projection slows every command on the aggregate; an exception in the projection rolls back the append. The application is on the critical write path. Reserve `Strong` for read models whose update path is fast and reliable — typically a single `INSERT … ON CONFLICT DO UPDATE` on a covered table.

**API surface.** `ConsistencyMode` value: `Strong`. Declared on the `ReadModel` value at construction time; cannot be selected per-call (a read model fed by an async projection is not strongly consistent regardless of the caller's wishes).

**When to choose.** UI showing the just-saved entity, where the user expects immediate visibility (the canonical "I saved the form, I see my changes" pattern). Audit logs that must be queryable from the same request that created them.


### 3.2 Eventual

**Mechanism.** The read model is fed by an *async projection* (EP-3 §3). A separate worker (a shibuya runner consuming `shibuya-kiroku-adapter`'s subscription stream) updates read-model rows after the write transaction commits. The async lifecycle is at-least-once: a crash between the projection write and `subscriptions.last_seen` advance produces a re-delivery; idempotent projection functions are required.

**Reader contract.** A `runQuery readModel q` call may briefly see stale state. The lag is bounded by projection throughput (typically tens to hundreds of milliseconds for low-latency workloads) but is not zero. The application either tolerates the lag (dashboards, search, reports) or hides it (optimistic UI patches the local cache pending confirmation).

**Failure mode.** A stuck or crashed projection worker accumulates lag; queries continue to succeed but return increasingly stale data. Operators monitor `subscriptions.last_seen` lag versus the global head; alerts fire when the gap exceeds an SLO. Rebuild protocol exists for the case where lag becomes intractable (§6).

**API surface.** `ConsistencyMode` value: `Eventual`. The default for read models without an explicit mode.

**When to choose.** Dashboards, reports, search indexes, audit views queried out-of-band. Anywhere the read traffic does not need to see the just-saved state.


### 3.3 PositionWait

**Mechanism.** The read model is fed by an async projection, *plus* the caller blocks before reading until the projection's `subscriptions.last_seen` advances past a target `GlobalPosition`. The target position is typically the value `runCommand` returns in its result (EP-1 §6 — `RunCommandResult` carries the appended events' positions). The `waitFor` helper polls `subscriptions.last_seen` for the named subscription and returns when the value is ≥ the target.

**Reader contract.** After `waitFor readModel position` returns, a subsequent `runQuery readModel q` sees the state up to that position. The wait time pays the projection's lag *on the read path only* — the write path was unaffected.

**Failure mode.** A stuck projection causes `waitFor` to time out. The configurable per-call timeout (default 5 seconds, declared on the `ReadModel` value or overridden per-call) bounds the worst case. On timeout, `waitFor` returns `WaitTimeout { wtTarget, wtObserved }` in `Eff es`'s error channel; the application either retries or falls back to optimistic-UI semantics.

**API surface.** `ConsistencyMode` value: `PositionWait { pwTimeoutMs :: Int }`. The timeout may be overridden per call by passing an explicit override to `runQuery` or by calling `waitFor` directly before `runQuery`.

**When to choose.** The same scenarios as `Strong`, when the read model is fed by an async projection (because the projection is too slow or unreliable to put on the inline path) but the caller still needs read-after-write semantics. Trades write latency for read latency: writes are fast, reads occasionally pay the projection lag.


### 3.4 Mode Selection Decision Tree

A reader scanning this section should be able to pick a mode without reading the rest of the document.

1. **Does the read model's projection do anything slow or fallible?** (Network calls, large computations, external service hits.) If *yes*, the projection cannot be inline — it would put that slow/fallible work on every write. Skip to step 3.
2. **Is the read after a write user-perceptible?** (e.g., the user just saved a form and is about to reload the page.) If *yes*: choose `Strong`. The projection lifecycle must be inline.
3. **Does the read after a write need to see the post-write state?** If *no* (dashboards, reports, search): choose `Eventual`.
4. **If yes**: choose `PositionWait`. Set a timeout that bounds your worst-case read latency under projection lag. Consider whether a fall-back to optimistic UI on timeout is acceptable.

Default for new read models: `Eventual` — the broadest applicability with the lowest infrastructure cost. Upgrade to `PositionWait` or `Strong` when a specific use case demands.


### 3.5 Comparison Table

A scannable summary. The full text in §3.1–§3.3 is authoritative; this table is for orientation only.

|                          | Strong                      | Eventual                  | PositionWait                  |
| ------------------------ | --------------------------- | ------------------------- | ----------------------------- |
| Projection lifecycle     | Inline                      | Async                     | Async                         |
| Write path latency       | Pays projection cost        | Unaffected                | Unaffected                    |
| Read after write sees    | Post-write state            | May see pre-write state   | Post-write state (after wait) |
| Read latency             | Standard                    | Standard                  | Pays projection lag           |
| Failure if projection slow | Slow writes               | Stale reads               | Wait timeout                  |
| Worker required          | None (runs in caller's tx)  | Yes                       | Yes                           |
| At-least-once duplicates | Not possible (single tx)    | Possible                  | Possible                      |
| API selection            | Per-`ReadModel` value       | Per-`ReadModel` (default) | Per-`ReadModel` or per-call   |


## 4. Substrate Facts

This section captures the load-bearing facts about kiroku and shibuya that the read-model design depends on. They are documented elsewhere; they are repeated here so a reader of this document can follow the design without context-switching.

**Kiroku gives gap-free contiguous global positions.** Every appended event is assigned a `globalPosition :: Int64` by kiroku's "Strategy E": an atomic `UPDATE … RETURNING` on the row `streams WHERE stream_id = 0` *inside* the same transaction that inserts the events (`kiroku/docs/DESIGN.md` §"Core Design Choice: Strategy E"). Concurrent transactions cannot produce out-of-order commits; subscribers see positions `1, 2, 3, …` contiguously with immediate read-your-own-writes. This is the fact the `PositionWait` mode relies on: when `runCommand` returns `globalPosition = 42`, every async projection sees event 42 *after* it sees events 1–41 — no gaps, no out-of-order delivery, no high-water-mark daemon needed (per the MasterPlan's 2026-05-04 HWM rejection and `docs/research/08-…` §4).

**Kiroku exposes subscription progress via `subscriptions(subscription_name, last_seen)`.** Each subscription's progress is tracked as a single row in this table. After a worker (the `shibuya-kiroku-adapter` runner) finishes processing event N, it updates the row to set `last_seen = N`. The `waitFor` helper reads this row directly: `SELECT last_seen FROM subscriptions WHERE subscription_name = $1`. No bespoke API, no LISTEN/NOTIFY (deferred to v2), just a single SELECT polled at a configurable cadence.

**`shibuya-kiroku-adapter` advances `subscriptions.last_seen` in a separate connection from the projection write.** As of 2026-05-05 the adapter runner advances the checkpoint after the user's handler returns `AckOk` (or any `Ack*` other than `AckHalt`), in its own SQL connection. The projection write and the checkpoint advance therefore live in *different* Postgres transactions. A crash between the two produces at-least-once delivery: a replay re-invokes the projection. EP-6 §5.1 records the `HandlerInTransaction` shape as the upstream fix that would convert this to exactly-once. Until that lands, async projections are at-least-once and projection functions must be idempotent (EP-3 §3). This document inherits the at-least-once semantics for `Eventual` and `PositionWait` modes.

**The transactional-step combinator wraps a single-stream append plus user SQL in one transaction.** EP-1 §10 documents the combinator. Inline projections are exactly this combinator with the user SQL being the read-model row update. As of 2026-05-10 kiroku-store ships `Kiroku.Store.Transaction.runTransactionAppending :: (HasCallStack, IOE :> es, Store :> es) => StreamName -> ExpectedVersion -> [EventData] -> (AppendResult -> Tx.Transaction a) -> Eff es (Either StoreError a)` (and the no-retry sibling, the lower-level `appendToStreamTx` building block, and the bare `runTransaction` escape hatch). EP-1 §10's combinator binds directly to this wrapper for single-stream commands; the previously documented `appendMultiStream`-with-singleton-list workaround (which earlier drafts of this section recommended on the strength of the then-open EP-6 §4.1 gap) is no longer required. EP-8's spike at `spikes/read-model/src/Spike/Command.hs` (lines 23 and 130) is the first in-tree consumer of the wrapper and implements the inline-projection lifecycle as a direct call. The closure is recorded in the parent MasterPlan's 2026-05-10 Surprises & Discoveries entry "cross-cutting, follow-up to the EP-8 M3 discovery — full kiroku transaction API surface".

**Streamly is the streaming substrate.** Per the MasterPlan's 2026-05-04 streamly-substrate decision, every multi-event boundary in keiro is expressed as a `Streamly.Data.Stream.Stream` and consumed via `Fold`. The async projection worker is a `Stream.fold Fold.drain` over the adapter's source. The `waitFor` helper is *not* streaming — it is a single SQL polling loop in `Eff es` — but the projection workers it observes are. This document does not introduce a parallel streaming abstraction.

**Postgres-only.** Per the MasterPlan's locked substrate, read models live in Postgres tables in the same database as the event store. The "BYO read store" pattern (EventStoreDB-style; see `spikes/read-model/notes/prior-art.md` §"EventStoreDB") is out of scope. Applications that want a non-Postgres read store can implement their own projections that write elsewhere; keiro will not provide framework support for that path.


## 5. The Typed `ReadModel q r` Wrapper

The `Keiro.ReadModel` module exports a single record type that bundles everything keiro needs to query a read model and enforce its consistency-mode and version contracts. The shape is symmetric with EP-1's `EventStream phi rs s ci co` write-side wrapper: a value-level record of fields, no type-level machinery, no record-of-functions ergonomic loss.


### 5.1 Module surface

The module exports:

    module Keiro.ReadModel
      ( ReadModel (..)
      , ConsistencyMode (..)
      , WaitTimeout (..)
      , ReadModelStaleSchema (..)
      , runQuery
      , runQueryWith
      , waitFor
      , readModelTable
      , readModelSubscription
      ) where

The body of `Keiro.ReadModel` is the implementation of `runQuery`, `runQueryWith`, and `waitFor`; the rebuild orchestration helpers live in a sibling module `Keiro.ReadModel.Rebuild` (specified in §6) so applications that never rebuild on a hot system do not transitively import the rebuild machinery.


### 5.2 The record

    data ReadModel q r = ReadModel
      { rmName            :: Text
      , rmTable           :: Text
      , rmSubscription    :: Text
      , rmVersion         :: Int
      , rmShapeHash       :: Text
      , rmConsistency     :: ConsistencyMode
      , rmQuery           :: q -> Hasql.Statement.Statement q r
      , rmRowCodec        :: Codec r
      }

Each field is load-bearing.

- `rmName :: Text` — application-globally-unique identifier. Used as the primary key of the `keiro_read_models` metadata table (§6) and in OpenTelemetry attributes (`keiro.read_model.name`).
- `rmTable :: Text` — the Postgres table name for read-model rows. Distinct from `rmName` because rebuilds rotate through `<rmName>_v<version>` tables (§6.2). At any point in time `rmTable` is the *current* (live, post-swap) table name; the rebuild protocol owns the table-name lifecycle.
- `rmSubscription :: Text` — the kiroku subscription name that feeds this read model. `waitFor` queries `subscriptions WHERE subscription_name = rmSubscription` to learn the projection's progress. For inline projections (where there is no subscription) the field carries a sentinel string `"<inline>"` and `waitFor` short-circuits to a no-op (the read is already consistent by the time the caller has a `runCommand` result).
- `rmVersion :: Int` — incremented on incompatible schema changes. Compared against the persisted version on `keiro_read_models` to detect missing rebuilds (§6).
- `rmShapeHash :: Text` — hex digest computed over the read-model row's compiled schema (column names, column types, library version). Compared against the persisted shape hash on `keiro_read_models` to detect drift even when the version was bumped manually but the schema was changed silently (§6). Mirrors EP-4's `regfile_shape_hash` (`docs/research/09-…` §2, §6) but with hard-fail rather than fall-through semantics.
- `rmConsistency :: ConsistencyMode` — the default consistency mode for queries against this read model. Per-call overrides via `runQueryWith`.
- `rmQuery :: q -> Hasql.Statement.Statement q r` — the application's query function. Builds a hasql `Statement` (parametric SQL plus encoder plus decoder) from a query value. Decoupling the query function from `runQuery`'s consistency-mode handling lets the application use any hasql query shape (parameterised, prepared, decoded into the target row type) without keiro inspecting the SQL.
- `rmRowCodec :: Codec r` — EP-2's value-level codec for the row's encoded form. Used by the rebuild protocol (§6) to (de)serialise rows to JSONB during shadow-table population, and by the diagnostic `dumpRow` helper (not part of the public surface but useful in tests).


### 5.3 `ConsistencyMode`

    data ConsistencyMode
      = Strong
      | Eventual
      | PositionWait { pwTimeoutMs :: !Int }
      deriving (Eq, Show)

Three constructors. `Strong` is permitted only on read models declared as fed by an inline projection (the framework checks at registration time — §6.4); declaring `Strong` on an async-fed read model is a startup error, not a runtime error. The default `pwTimeoutMs` is 5000 (5 seconds); applications override per-call via `runQueryWith`.


### 5.4 `runQuery` and `runQueryWith`

Two query functions, the second a generalisation of the first.

    runQuery
      :: (Reader Pool.Pool :> es, Error WaitTimeout :> es,
          Error ReadModelStaleSchema :> es, IOE :> es)
      => ReadModel q r
      -> q
      -> Maybe GlobalPosition  -- target position for PositionWait; ignored for Strong/Eventual
      -> Eff es r

    runQueryWith
      :: (Reader Pool.Pool :> es, Error WaitTimeout :> es,
          Error ReadModelStaleSchema :> es, IOE :> es)
      => ReadModel q r
      -> q
      -> ConsistencyMode       -- override the rmConsistency default
      -> Maybe GlobalPosition
      -> Eff es r

Behaviour by mode:

- *Strong*: `runQuery rm q _` checks the persisted `version` and `shape_hash` against the in-memory `rmVersion`/`rmShapeHash`; on mismatch throws `ReadModelStaleSchema`. Otherwise runs `rmQuery q` against `rmTable` directly. The position parameter is ignored.
- *Eventual*: identical to *Strong* — schema check, then query. The position parameter is ignored. (The mode differs in what the projection lifecycle is; from `runQuery`'s perspective the work is the same.)
- *PositionWait { pwTimeoutMs }*: schema check, then `waitFor rm targetPosition` (using `pwTimeoutMs` as the timeout), then run the query. If the position parameter is `Nothing`, the call degrades to `Eventual` semantics (no wait); the application is responsible for passing the position from the most recent `runCommand` result when read-after-write is required.

Why the position is `Maybe`: a read may not have a "the just-prior write" — e.g., a dashboard refresh, or a query unrelated to a recent command. `Nothing` means "I have no target; just read what's there." Equivalent to `Eventual` semantics for that call.


### 5.5 `waitFor`

    waitFor
      :: (Reader Pool.Pool :> es, Error WaitTimeout :> es, IOE :> es)
      => ReadModel q r
      -> GlobalPosition
      -> Eff es ()

Implementation specified in §10. Polls `subscriptions WHERE subscription_name = rmSubscription` and returns when `last_seen >= target`. For inline-fed read models (`rmSubscription == "<inline>"`) returns immediately as a no-op.


### 5.6 Errors

Two error types in the public surface.

    data WaitTimeout = WaitTimeout
      { wtTarget   :: !GlobalPosition
      , wtObserved :: !GlobalPosition
      , wtModel    :: !Text
      } deriving (Eq, Show)

    data ReadModelStaleSchema = ReadModelStaleSchema
      { rssModel             :: !Text
      , rssCompiledVersion   :: !Int
      , rssPersistedVersion  :: !Int
      , rssCompiledShapeHash :: !Text
      , rssPersistedShapeHash :: !Text
      } deriving (Eq, Show)

Both are returned in `Eff es`'s error channel via the `Error` effect (effectful's standard pattern, mirroring `StoreError` in EP-1 §4). Applications can `Error.runErrorWith` selectively to choose error handling per-call.


### 5.7 Worked example

    counterView :: ReadModel Text (Maybe Int)
    counterView = ReadModel
      { rmName         = "counter_view"
      , rmTable        = "counter_view"
      , rmSubscription = "counter-view"
      , rmVersion      = 1
      , rmShapeHash    = $(computeShapeHashTH ''CounterRow)  -- TH or value-level helper
      , rmConsistency  = Eventual
      , rmQuery        = \name ->
          Hasql.Statement.Statement
            "SELECT current_value FROM counter_view WHERE counter_name = $1"
            (Encoders.param (Encoders.nonNullable Encoders.text))
            (Decoders.rowMaybe (Decoders.column (Decoders.nonNullable Decoders.int4)))
            True
      , rmRowCodec     = counterRowCodec
      }

Use:

    -- Issue a command that increments the counter
    result <- runCommand counterEventStream "main" Increment

    -- Read the result with read-after-write semantics
    let pos = lastAppendedPosition result
    value <- runQueryWith counterView "main" (PositionWait { pwTimeoutMs = 1000 }) (Just pos)
    -- value == Just (n+1)

The `runQueryWith` call blocks until the async projection catches up to `pos`, then reads. The total read latency is the projection lag (typically tens of milliseconds), bounded by the 1000 ms timeout.


## 6. Schema Evolution and Rebuild Protocol

Read models are versioned, rebuildable artefacts. The protocol must let an operator (a) bump a read model's schema, (b) rebuild from `globalPosition = 0`, and (c) atomically swap the new version into place — *while the live projection continues serving the old version* — without serving stale or partial data at any point.


### 6.1 The metadata table

A single Postgres table records each read model's persisted version and shape hash.

    CREATE TABLE keiro_read_models
      ( name            TEXT        PRIMARY KEY
      , version         INT         NOT NULL
      , shape_hash      TEXT        NOT NULL
      , last_built_at   TIMESTAMPTZ NOT NULL DEFAULT now()
      , status          TEXT        NOT NULL DEFAULT 'live'
              CHECK (status IN ('live', 'rebuilding'))
      );

One row per read model. `name` is the application-globally-unique `rmName`. `version` and `shape_hash` are the *currently live* values — i.e., what the live `rmTable` was built against. `last_built_at` records the wall-clock time of the last successful rebuild (or first build). `status` flags an in-progress rebuild so concurrent operators don't stomp on each other.

Owned by `Keiro.ReadModel.Rebuild`. The `keiro_read_models` table is created by a keiro initialisation migration (filed as a kiroku-side adjacent migration, separate from kiroku's own schema).


### 6.2 The rebuild protocol

Eight steps. Each is idempotent and recoverable.

1. **Bump the in-memory `rmVersion`** (and `rmShapeHash` if the schema changed). Code-side change; recompile. The compiled `rmVersion` now exceeds the persisted `keiro_read_models.version`.

2. **Application startup detects mismatch.** On first `runQuery` against the read model, `Keiro.ReadModel` compares compiled `(rmVersion, rmShapeHash)` to the persisted row in `keiro_read_models`. On mismatch, the read model is "stale" — `runQuery` returns `ReadModelStaleSchema` rather than serving rows whose layout has drifted.

3. **Operator initiates rebuild.** A keiro CLI subcommand (or programmatic call to `Keiro.ReadModel.Rebuild.rebuild`) takes the `ReadModel` value:

        rebuild
          :: (Reader Pool.Pool :> es, IOE :> es, Log :> es)
          => ReadModel q r
          -> RebuildOptions
          -> Eff es RebuildResult

   `rebuild` performs steps 4–8 below.

4. **Acquire the rebuild lock.** `UPDATE keiro_read_models SET status = 'rebuilding' WHERE name = $1 AND status = 'live'`. If zero rows updated, another rebuild is already in progress; abort with a clear error. The status flip is atomic.

5. **Create the shadow table.** `CREATE TABLE <rmTable>_v<newVersion> (LIKE <rmTable> INCLUDING ALL)` — copies the column definitions, indexes, and constraints from the live table. Override columns the schema change altered via subsequent `ALTER TABLE`. The shadow table is the new schema; the live table is unchanged.

6. **Replay events from `globalPosition = 0`.** Open a kiroku subscription named `<rmSubscription>-rebuild-<newVersion>` that reads from position 0. Run the read model's projection function against it, writing into the shadow table. Use Streamly's `Stream.fold Fold.drain` shape (consistent with EP-3 §3 async lifecycle). Track progress in `subscriptions(subscription_name, last_seen)` like any other subscription. The live projection (still consuming from `<rmSubscription>` on the unmodified live table) continues to serve queries.

7. **Catch up and pause writes briefly.** When the rebuild subscription's `last_seen` reaches the global head (or within a configurable lag tolerance), pause new event appends momentarily (a kiroku-side advisory lock on the `streams` table — exact mechanism deferred to the implementation MasterPlan), let both the live and rebuild subscriptions drain to the same position, then proceed. The pause window is small (target: under 100 ms for low-traffic systems; larger systems can use a non-pause variant that accepts a brief stale-read window — see §6.5).

8. **Atomic swap.** Inside one Postgres transaction:

        BEGIN;
        ALTER TABLE <rmTable> RENAME TO <rmTable>_v<oldVersion>_retired;
        ALTER TABLE <rmTable>_v<newVersion> RENAME TO <rmTable>;
        UPDATE keiro_read_models
          SET version = <newVersion>,
              shape_hash = <newShapeHash>,
              last_built_at = now(),
              status = 'live'
          WHERE name = $1;
        COMMIT;

   Re-resume event appends. The retired table can be dropped after a holding period (default: 7 days) by a separate `Keiro.ReadModel.Rebuild.dropRetired` operation.


### 6.3 Rebuild failure recovery

A rebuild that crashes mid-way leaves `keiro_read_models.status = 'rebuilding'` and a partial shadow table. Recovery:

- The shadow table is *named with the new version*, so a re-run of `rebuild` for the same version re-uses it; the subscription progresses from where it left off.
- If the user wants to abandon the rebuild (e.g., the new schema was wrong), `Keiro.ReadModel.Rebuild.abandonRebuild` drops the shadow table and resets `status = 'live'`.
- The live table is never touched until step 8, so a crashed rebuild never affects production reads.


### 6.4 Inline-projection schema changes

Inline projections do *not* have a separate worker; the projection runs in the application's command path. A schema change for an inline-fed read model still uses the same `rebuild` flow, but step 7's "pause writes" becomes "drain the inflight commands and refuse new ones for the swap window" — keiro's runtime exposes a `withReadModelSwap` helper that holds the application's command intake while the swap runs. The compiled `Strong` mode validation (§5.3) ensures inline-fed read models are flagged at registration so operators know the swap window will affect the write path.


### 6.5 Non-pause variant: shadow-then-promote with brief stale window

For systems where pausing event appends is too disruptive, an alternative protocol omits step 7's pause and accepts a small stale-read window:

7'. The rebuild subscription catches up to a moving target (the global head). The catch-up loop bounds wait (default: 30 seconds). When `head - last_seen` is below threshold (default: 10 events) the rebuild is declared "caught up enough"; step 8 runs without a pause. Reads against the live table during the swap may briefly see the old version. The trade-off (continuity over strict read-your-own-writes during the swap) is documented and operator-selectable via `RebuildOptions`.

The pause variant (§6.2 step 7) is the default; the non-pause variant is opt-in.


## 7. Multi-Stream Read Models

A read model whose rows are derived from events across more than one event-stream type. The canonical example: an `OrderView` that aggregates events from `Order` streams (`OrderPlaced`, `OrderShipped`, …) and `Payment` streams (`PaymentAuthorised`, `PaymentCaptured`, …).


### 7.1 Subscribing to a category

The projection consumes a kiroku *category subscription*: events from any stream whose name matches a prefix or pattern. Two implementation paths:

- **(a) Application-level multiplexing.** The projection runs N subscriptions (one per source stream type) in parallel via shibuya's runner abstractions. Each subscription's events are dispatched to a shared handler that updates the same read-model row. The `subscriptions` table holds N rows (one per subscription). `waitFor` for this read model must check *all N* `last_seen` values are ≥ the target position; the helper exposes a `waitForAll :: ReadModel q r -> [(Text, GlobalPosition)] -> Eff es ()` variant.
- **(b) Kiroku category subscription.** A single subscription whose source matches a stream-name prefix or pattern (e.g., `order-*` or `payment-*`). One row in `subscriptions`; standard `waitFor` works. Requires a kiroku-side enhancement.

Path (a) works today with existing kiroku and shibuya primitives. Path (b) is preferred for new code if kiroku ships the prefix-style category subscription.


### 7.2 Identified upstream gap

EP-5 §9 already records "kiroku-side prefix-style category subscriptions for `pm-`/`wf-` streams" as an upstream question. EP-8 §7 widens the scope: the same primitive is needed for multi-stream read models, not only for workflow streams. The cascade goes into the MasterPlan's Surprises & Discoveries with the existing EP-5 entry referenced.

The implementation MasterPlan should treat path (a) as the v1 baseline (works today) and path (b) as a Wanted upgrade once the kiroku prefix-style category subscription lands.


### 7.3 Schema evolution for multi-stream read models

Identical to single-stream (§6). The `rmShapeHash` is computed over the read-model row schema regardless of how many streams feed it. The rebuild protocol replays from `globalPosition = 0`; if path (a) is used, the rebuild creates N parallel rebuild subscriptions, all of which write to the shadow table, and step 7's catch-up waits for all N.


## 8. Idempotency-Token Propagation

The async projection lifecycle is at-least-once (EP-3 §3, this document §4). A duplicate event delivery would otherwise produce duplicate read-model writes. The mechanism that prevents this is a `source_event_id UUID NOT NULL UNIQUE` column on every read-model row, populated with the kiroku `EventData.eventId` of the source event.


### 8.1 The constraint

Every read-model table created by keiro must include:

    source_event_id UUID NOT NULL UNIQUE

The `Keiro.ReadModel.Rebuild` machinery emits a startup-time check that the live `rmTable` has this column with the constraint; a missing constraint is a registration error. (Inline-fed read models have no at-least-once concern but still carry the column for symmetry; the column is no-op insurance and costs only a UUID per row.)


### 8.2 The write pattern

Projection writes use:

    INSERT INTO <rmTable> (..., source_event_id) VALUES (..., $eventId)
      ON CONFLICT (source_event_id) DO NOTHING;

Or, when an event *updates* an existing row keyed by something other than `source_event_id`:

    INSERT INTO <rmTable> (id, ..., source_event_id) VALUES ($id, ..., $eventId)
      ON CONFLICT (id) DO UPDATE SET
        ... = EXCLUDED....,
        source_event_id = EXCLUDED.source_event_id
      WHERE <rmTable>.source_event_id IS DISTINCT FROM EXCLUDED.source_event_id;

The `WHERE` clause on the `DO UPDATE` is the key idempotency check: the update fires only if the existing row's `source_event_id` is *different* from the incoming event's id. A re-delivery of the same event finds the row already up-to-date by that event and skips the update.


### 8.3 Multi-event-per-row read models

Some read models are updated by multiple events for a single row (e.g., an `OrderView` row updated by `OrderPlaced` then `OrderShipped`). The single `source_event_id` column cannot record all source events; using the *most recent* event's id loses the property "this row reflects events up to position X."

Two patterns:

- **(a) Last-write-wins source_event_id.** Stores only the most recent event's id. Idempotency works for the *most recent* event; older duplicate deliveries are suppressed only if their event id matches the row's current `source_event_id`. Acceptable for read models whose events are strictly ordered per row (e.g., per-aggregate views).
- **(b) Per-event-type source_event_id columns.** Stores `placed_event_id`, `shipped_event_id`, … as separate columns. Each event handler updates only its column on its event type. Idempotency works per event type. Used when the read model can receive events out-of-order or when multiple event types update the same row.

Pattern (a) is the default. Pattern (b) is documented in §8 of the design doc and is application-coded; keiro doesn't enforce it.


## 9. Read Model vs Snapshot vs Projection

Three primitives. Easy to conflate; conflation produces design errors. This section establishes the distinction.


### 9.1 The three primitives

- **Snapshot** (EP-4, `docs/research/09-…`). The encoded joint state `(s, RegFile rs)` for an event stream, cached in the `keiro_snapshots` table. Used *internally* by `runCommand`'s hydration phase to skip ahead to a known state instead of folding from event 0. *Advisory*: a stale or missing snapshot falls through to full replay; `runCommand` correctness does not depend on the snapshot being present or fresh. *Internal*: never queried by application code. *Per-stream*: keyed on `kiroku.stream_id`; one snapshot per event stream instance.

- **Projection** (EP-3, `docs/research/08-…`). The *worker* (the verb) that consumes events and writes/updates read-model rows. Three lifecycles (inline / async / live). Each projection has a name (used as the kiroku subscription name) and is wired to one or more event streams via shibuya runners (or the inline transactional-step combinator). Projections are *processes*; they have lifecycles, supervision, and OpenTelemetry attributes.

- **Read model** (this document). The *queryable artefact* (the noun). A Postgres table whose rows are written by a projection and read by application code via the typed `ReadModel q r` API. Read models are *resources*; they have a schema, a version, a shape hash, a consistency-mode default, and a rebuild lifecycle.

A common shorthand: a projection *maintains* a read model. The projection is the worker; the read model is the data plus its query API.


### 9.2 Why three, not one or two

Several plausible-sounding consolidations are *wrong*:

- *"Snapshots are just internal read models."* Wrong. Snapshots are advisory and fall through on failure; read models hard-fail on stale schemas (§5.6 `ReadModelStaleSchema`). Treating snapshots as read models would either make `runCommand` depend on read-model freshness (rejected by EP-4 §3 advisory framing) or strip read models of the staleness guard (rejected by §5).
- *"Read models are projections."* Wrong. A projection is a process; a read model is a table-plus-query-API. The same projection process can maintain multiple read-model tables (e.g., a projection that updates both an `orders` view and an `orders_summary` view from the same event stream). Conflating the two would force a 1:1 mapping that doesn't reflect how applications actually use the primitives.
- *"Snapshots and read models are both 'derived state'."* Almost. Both are derived; both are persisted. But the *visibility* and *failure mode* differ: snapshots are private to keiro and fall through; read models are public and hard-fail. Different failure modes mean different APIs, which means different types.


### 9.3 Cross-references

- For snapshot mechanics, see `docs/research/09-snapshot-strategy.md`. For the advisory-fall-through framing (the contrast point with read models), see §3 and §12 of that document.
- For projection mechanics, see `docs/research/08-subscription-and-process-manager-design.md`. §3 covers the three lifecycles; §13 explicitly records the non-use of snapshots in projection lifecycles (a separate non-overlap with this document's §9).
- This document's §5 (typed `ReadModel q r` wrapper) and §6 (rebuild) are the read-model-specific surfaces that no other document covers.


## 10. Position-Wait Implementation

The `waitFor` helper is small enough to fit in this document end-to-end.


### 10.1 Signature and contract

    waitFor
      :: (Reader Pool.Pool :> es, Error WaitTimeout :> es, IOE :> es)
      => ReadModel q r
      -> GlobalPosition
      -> Eff es ()

After `waitFor rm target` returns successfully, `subscriptions WHERE subscription_name = rmSubscription rm` has `last_seen >= target`. A subsequent `runQuery rm q` therefore observes the read-model state up to event `target`. On timeout (per `rmConsistency`'s `pwTimeoutMs` or per-call override), the helper returns `WaitTimeout { wtTarget, wtObserved, wtModel }` in the error channel.


### 10.2 Polling loop

The implementation is a polling loop with exponential back-off, capped at a maximum interval.

    waitFor rm target = do
      let pollMin = 50  -- ms, initial poll interval
          pollMax = 500 -- ms, max poll interval (cap)
          timeoutMs = case rmConsistency rm of
            PositionWait t -> t
            _              -> 5000  -- conservative default for non-PositionWait callers
      startedAt <- liftIO getMonotonicTimeMs
      let loop interval = do
            observed <- queryLastSeen (rmSubscription rm)
            if observed >= target
              then pure ()
              else do
                now <- liftIO getMonotonicTimeMs
                if now - startedAt >= timeoutMs
                  then throwError (WaitTimeout target observed (rmName rm))
                  else do
                    liftIO (threadDelay (interval * 1000))  -- threadDelay takes µs
                    loop (min pollMax (interval * 2))
      loop pollMin

Poll cadence: 50 ms, 100 ms, 200 ms, 400 ms, 500 ms, 500 ms, … cap at 500 ms. Worst-case wakeup latency to detect projection caught-up is bounded by the max interval. The exponential ramp keeps low-latency cases fast (50 ms initial) while avoiding hot-spinning on `subscriptions` for slow projections.


### 10.3 The `queryLastSeen` SQL

A single statement, prepared:

    SELECT last_seen FROM subscriptions WHERE subscription_name = $1

Returns the current `last_seen` for the named subscription. If the row does not exist, the helper throws `WaitTimeout` with `wtObserved = 0`: the projection has never run (or was deleted), so no progress has been recorded.

The function executes against a connection from the keiro `Pool.Pool`. The pool is shared with `runCommand` and `runQuery`; a slow `waitFor` does not exhaust a private pool.


### 10.4 LISTEN/NOTIFY rejected for v1

A more responsive implementation would use Postgres LISTEN/NOTIFY: the `shibuya-kiroku-adapter` runner could `NOTIFY` after each `last_seen` advance, and `waitFor` would `LISTEN` instead of polling. Latency would drop to near-zero.

This is **deferred to v2**. Reasons:

- It requires a coordinated change in `shibuya-kiroku-adapter` to issue the `NOTIFY`, in keiro to issue the `LISTEN`, and a reliable in-process notification dispatch (the existing `hasql-notifications` package is the natural target). Each piece is small but the coordination is non-trivial.
- The polling implementation is correct, simple, and bounded. For the single-instance Postgres workloads keiro targets in v1 (per `docs/research/05-…` synthesis), 50–500 ms latency on the read path under projection lag is acceptable.
- The MasterPlan's general posture against LISTEN/NOTIFY (Vision & Scope, deferred features list) is to defer push-based delivery to v2.

The implementation MasterPlan can revisit this when v2 is in scope.


### 10.5 Timeout selection guidance

Default `pwTimeoutMs = 5000` (5 seconds). Adjust per use case:

- *Interactive UI after save*: 1000–2000 ms. Beyond ~2 seconds the user perceives the save as failing; better to show optimistic UI and fall back to "syncing…" than to block longer.
- *API request handler in a fast service*: 500–1500 ms. The whole HTTP request budget is typically 3–5 seconds; spending most of that on `waitFor` defeats the purpose.
- *Background reconciliation jobs*: 30000+ ms (or `Eventual` mode without a wait). Tolerate larger lag for non-interactive paths.

The `RebuildOptions`-style configuration system (§6.5) extends to consistency-mode tuning: applications can declare per-read-model timeout overrides centrally rather than at every call site.


### 10.6 Inline-fed read models short-circuit

For read models declared with `Strong` consistency (and therefore inline projections), `rmSubscription = "<inline>"` and `waitFor` returns immediately as a no-op:

    waitFor rm _ | rmSubscription rm == "<inline>" = pure ()

The check is a string comparison; no SQL roundtrip. The semantic is: "the read model is consistent at the moment of the calling command's commit; there is nothing to wait for."

