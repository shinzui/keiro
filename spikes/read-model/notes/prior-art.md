# Read-Model Prior-Art Notes (EP-8 M1)

These are working notes feeding into `docs/research/12-read-model-query-api-and-lifecycle.md`. They are not part of the published design; the published design distils these.

The five reference systems from `docs/research/05-workflow-prior-art.md` are revisited with a *read-side* lens: what query API does each expose, what consistency modes are available, how schema evolution and rebuild work, and what is worth stealing for keiro.


## Marten (.NET, Postgres)

**Query API.** `IDocumentSession.Query<T>()` (LINQ over JSONB-stored documents) and `IDocumentSession.LoadAsync<T>(id)`. Read models (called "projections" in Marten) are documents in the same Postgres database as the event store. Each projection type has its own table.

**Consistency modes.** Three projection lifecycles map directly to consistency modes:
- *Inline*: projection runs in the same transaction as the event append. Strong consistency — read after write sees the new state immediately. Trade-off: slows the write path; an exception in the projection rolls back the append.
- *Async (Async Daemon)*: a daemon worker subscribes to the event log and updates projection rows out-of-band. Eventual consistency. The daemon tracks a high-water-mark for gap detection (kiroku's Strategy E makes this unnecessary; see `docs/research/05-workflow-prior-art.md` corrections note and `docs/research/08-…` §4).
- *Live*: state is computed on read by folding events. No persisted read-model rows; trades read latency for eliminating projection-update overhead. Useful for low-frequency queries or low-cardinality entities.

**Schema evolution.** Projections carry a `ProjectionVersion`. Rebuilds are operator-initiated: stop the daemon, rebuild from `position = 0`, restart. The daemon supports rebuild-with-shadow-table for hot rebuilds in newer versions. Marten distinguishes between projection schema changes (additive — new columns) and breaking changes (require rebuild).

**Steal for keiro.** The three-lifecycle naming (inline / async / live) is already in EP-3 (`docs/research/08-…` §3). The *consistency-mode-as-API-parameter* idea — where the same `ReadModel q r` value carries a `ConsistencyMode` and `runQuery` selects behaviour off it — is the cleanest articulation in any of the surveyed systems. Marten conflates "consistency mode" with "projection lifecycle"; keiro should *separate* them so that an async projection can be queried with `Eventual` (raw read), `PositionWait` (block until projection caught up), or — at v2 if we add it — `Strong` (read in a tx after a write that triggered an inline projection on the same data).


## Eventide / message-db (Ruby, Postgres)

**Query API.** None at the framework level. Read models are plain Postgres tables; queries are application code (raw SQL or whatever the application uses). Eventide takes the position that read-model design is application-specific and refuses to add abstraction.

**Consistency modes.** Async only. Eventide has no inline projection concept: every projection is a subscription handler reading from the event log and writing to its own tables. Read-after-write is up to the application — typically optimistic UI or polling.

**Schema evolution.** Application-managed. Standard SQL migrations + idempotent re-projection scripts.

**Steal for keiro.** The "raw access is fine" baseline — keiro must not *force* applications onto a typed `ReadModel q r` wrapper. Applications that prefer raw hasql against their projection tables should be able to use them directly; the typed wrapper is for the *consistency-mode infrastructure* (the position-wait helper, the rebuild metadata table), not to gate access to data. Keiro should expose the underlying table name on the `ReadModel` value so applications can drop into raw hasql when the typed query API gets in the way.


## Axon (Java, JVM)

**Query API.** `QueryGateway.query(query, responseType)` plus `@QueryHandler`-annotated methods on read-model components. Query routing goes through the gateway: the gateway dispatches to the appropriate handler by query type. Subscription queries (`subscriptionQuery`) push updates as projections change.

**Consistency modes.** Eventual by default; subscription queries provide a streaming "as the projection updates" view. No native strong-consistency mode — Axon assumes the read store may be a different database from the write store.

**Schema evolution.** Token-based: each projection processes events up to a stored "tracking token". To rebuild, reset the token to zero. Hot rebuild via shadow projection is application-coded.

**Steal for keiro.** The QueryGateway pattern is heavier than keiro needs — it's designed for distributed event-sourced systems where queries route across services. Keiro is library-shaped and Postgres-only; an in-process typed `ReadModel q r` is sufficient. *However*, the *subscription query* idea (a stream of read-model updates) is interesting for v2 — keiro can layer it on top of `waitFor` later. **Defer to v2.**


## EventStoreDB (Erlang/JS server, multi-language clients)

**Query API.** None — EventStoreDB is the *write store*. Read models are entirely application-side; subscriptions feed the application's read-store code, which writes to an application-chosen database (Postgres, ElasticSearch, Redis, etc.). The "BYO read store" pattern.

**Consistency modes.** Per-application. The server provides at-least-once subscription delivery; the application implements its own consistency.

**Schema evolution.** Application-managed.

**Steal for keiro.** The BYO read-store pattern is *not* what keiro wants. Keiro is Postgres-only by the MasterPlan's 2026-05-04 substrate decision; the read store is the same Postgres instance as the event store. This lets us offer inline projections (Marten's killer feature) and lets `waitFor` read `subscriptions.last_seen` directly from kiroku's existing table without a network hop. The BYO model is *more general* but pays for that generality with an inability to provide strong-consistency reads.


## Restate (Rust, custom storage)

**Query API.** Restate workflows expose a query interface for accessing workflow-local state (`get_state(key)`). Not CQRS read models in the conventional sense — these are the workflow's own state, queried by the workflow.

**Consistency modes.** Strong: workflow state is in the same partition as the workflow execution.

**Schema evolution.** Per-workflow versioning.

**Steal for keiro.** Restate's read story is orthogonal to CQRS read models. Its `get_state` corresponds to v2 `runWorkflow`'s journaled state access (see `docs/research/10-workflow-roadmap.md` §6), not to a queryable view derived from events. Note the distinction in the design doc but do not import the abstraction.


## Synthesis: what keiro should ship for v1

The five systems agree on the broad shape — read models live in Postgres tables maintained by projections — and disagree on (a) whether to provide a typed wrapper at the framework level, (b) how to expose consistency modes, and (c) how rebuild works.

Recommendations for the design doc:

1. **Provide a typed `ReadModel q r` wrapper.** Symmetric with EP-1's `EventStream phi rs s ci co` write-side wrapper. Carries name, table, codec, consistency-mode default, version, shape-hash. Without the wrapper, the keiro library has nowhere to attach the rebuild metadata or the consistency-mode behaviour.

2. **Expose three consistency modes**: `Strong` (only valid when a read model is fed by an *inline* projection), `Eventual` (raw read), `PositionWait { timeoutMs }` (block until `subscriptions.last_seen` ≥ target position, then read). The mode is an explicit parameter of `runQuery`, defaulting to whatever the `ReadModel` value declares.

3. **Allow raw hasql escape hatch.** The `ReadModel` value exposes its table name and codec so applications can write raw hasql when the typed query API is too restrictive. This addresses the Eventide objection.

4. **Rebuild protocol with shadow table.** `keiro_read_models(name, version, shape_hash, last_built_at)` records each read model's metadata. Rebuild creates a shadow table `<name>_v<new_version>` populated by replay-from-zero, then atomically swaps. Live projection continues serving the old table until the swap.

5. **Schema-change detection.** Compute a shape hash over the read-model row schema (analogous to EP-4's `regfile_shape_hash`) and refuse to query if the on-disk version's hash mismatches the compiled version's hash — return `ReadModelStaleSchema` rather than serving stale data. Distinguishes from EP-4 snapshots (advisory, fall-through-on-failure) — read models *cannot* fall through; serving stale data silently is the failure mode this guard prevents.

6. **No subscription queries in v1.** Defer Axon-style streaming queries to v2; they require the `HandlerInTransaction` shape EP-6 §5.1 records as a Wanted gap.

7. **No QueryGateway-style routing.** Library-shaped, in-process; queries are direct function calls on `ReadModel q r` values, not bus dispatches.

8. **Document the BYO-read-store path as out-of-scope.** Applications that want a non-Postgres read store can implement their own projections that write to Elasticsearch / Redis / etc.; keiro will not provide framework support for that path. This is consistent with the MasterPlan's Postgres-only substrate decision.
