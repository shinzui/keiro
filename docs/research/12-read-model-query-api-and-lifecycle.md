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

**The transactional-step combinator wraps `appendMultiStream` plus user SQL in one transaction.** EP-1 §10 documents the combinator. Inline projections are exactly this combinator with the user SQL being the read-model row update. The combinator does *not* wrap single-stream `appendToStream` because kiroku-store does not yet expose that primitive's transaction (EP-6 §4.1 — kiroku-store single-stream `runInTransaction`). Inline projections in v1 must therefore route through `appendMultiStream` with a singleton stream list. This document inherits that constraint.

**Streamly is the streaming substrate.** Per the MasterPlan's 2026-05-04 streamly-substrate decision, every multi-event boundary in keiro is expressed as a `Streamly.Data.Stream.Stream` and consumed via `Fold`. The async projection worker is a `Stream.fold Fold.drain` over the adapter's source. The `waitFor` helper is *not* streaming — it is a single SQL polling loop in `Eff es` — but the projection workers it observes are. This document does not introduce a parallel streaming abstraction.

**Postgres-only.** Per the MasterPlan's locked substrate, read models live in Postgres tables in the same database as the event store. The "BYO read store" pattern (EventStoreDB-style; see `spikes/read-model/notes/prior-art.md` §"EventStoreDB") is out of scope. Applications that want a non-Postgres read store can implement their own projections that write elsewhere; keiro will not provide framework support for that path.


## 5. The Typed `ReadModel q r` Wrapper

(Drafted in M2.)


## 6. Schema Evolution and Rebuild Protocol

(Drafted in M2.)


## 7. Multi-Stream Read Models

(Drafted in M2.)


## 8. Idempotency-Token Propagation

(Drafted in M2.)


## 9. Read Model vs Snapshot vs Projection

(Drafted in M2.)


## 10. Position-Wait Implementation

(Drafted in M2.)
