# Upstream Roadmap for Kiroku and Keiki — keiro

Author: ExecPlan EP-6 (`docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`). Date: 2026-05-06.

This document is the synthesis output of the keiro research-foundation MasterPlan. It consolidates every upstream feature gap identified by EP-1 through EP-5 into a single, prioritized backlog the upstream maintainers (kiroku, keiki, shibuya) can schedule against. It is design-only: it enumerates feature requests and their constraints; it does not design the upstream features themselves.

The reader is assumed to have read the parent MasterPlan at `docs/masterplans/1-keiro-research-foundation.md` and the five sibling design documents `docs/research/06-command-cycle-design.md` (EP-1), `docs/research/07-codec-strategy.md` (EP-2), `docs/research/08-subscription-and-process-manager-design.md` (EP-3), `docs/research/09-snapshot-strategy.md` (EP-4), and `docs/research/10-workflow-roadmap.md` (EP-5). Where a key fact from those documents matters here it is repeated; the reader who has not seen them should still be able to follow this synthesis.


## 1. Problem statement

The user stated explicitly that "Both kiroku and keiki still need more features to support keiro, we'll develop them in parallel." The five sibling design documents each enumerate feature requests in their own "Open questions and upstream gaps" section, but each plan saw only its own slice of the surface. A maintainer trying to schedule kiroku changes from EP-1's §14 risks duplicating, missing, or mis-prioritising items that EP-3 and EP-4 also depend on. This document is the single, complete list with priorities, rationales, design constraints, and a sequencing recommendation, written so that a kiroku/keiki/shibuya maintainer can read one section and schedule sprints without further conversation.

The keiro implementation MasterPlan (the one that follows this research foundation) will treat the **Blocking** items here as gates and the **Wanted** items as parallel work. Items not landed by then are documented workarounds at the keiro layer; the implementer is not blocked, only inconvenienced.


## 2. How to read this document

### Priority semantics

- **Blocking** — keiro v1 cannot ship without this. The gap has no acceptable workaround at the keiro layer. Schedule before keiro implementation begins.
- **Wanted** — keiro v1 *can* ship without this, with a workaround that is mildly wasteful or that surrenders a desired guarantee (for example, exactly-once turning into at-least-once). Schedule for the v1.x window so the workaround can be retired before it ossifies. A few Wanted items are flagged "(Blocking for EP-N)" — they do not block keiro v1 overall, but they block a specific child plan's full design. EP-N's design records the workaround and recommends landing the upstream item first if possible.
- **Optional** — small, isolated, easily worked around at the keiro layer. Schedule when convenient; missing the v1.x window is fine.

### Provenance

Every entry carries a *Provenance* line citing the child plan(s) and section that introduced or reinforced the request. A maintainer asking "why do we need this?" finds the answer one click away. Entries with multiple customers (e.g., the keiki register-file helper, claimed by EP-1, EP-2, and EP-4) name every customer; landing the helper once satisfies all of them.

### Per-entry shape

Each entry answers, in order:

1. *What is missing today.* A one-sentence statement of the current state, with a `file:line` citation against the live upstream tree where applicable.
2. *What keiro needs.* A signature sketch (Haskell) or a behavioural description.
3. *Why.* One paragraph linking back to the customer plan(s) and explaining the design pressure.
4. *Priority.* Blocking / Wanted / Optional (with sub-classification where relevant).
5. *Design constraint.* What the upstream maintainer must preserve when implementing.
6. *Suggested sequencing.* Where in the dependency DAG this item sits.

The shape is verbose by design. EP-6's Decision Log records that the rationale and provenance must be one-click for each gap; that requirement drives the per-entry verbosity.


## 3. Sequencing recommendation

The four-block ordering below is what an implementation MasterPlan for keiro v1 should treat as ground truth. Items inside a block can run concurrently; items in earlier blocks unblock items in later blocks.

**Block 1 — Hard prerequisites for keiro v1 implementation.** One item.

- *kiroku-store: single-stream `runInTransaction` combinator* (§4.1).

**Block 2 — Parallel work with keiro v1 implementation, retiring v1 workarounds.** Six items, all Wanted; safe to land in any order.

- *kiroku-store: Streamly-native single-stream forward read* (§4.2).
- *kiroku-store: Postgres 18 deployment documentation* (§4.3).
- *shibuya-kiroku-adapter: `HandlerInTransaction` shape for transactional checkpoint advance* (§5.1).
- *keiki: register-file `<-> Aeson.Value` helper* (§7.1) — shared with EP-1, EP-2, EP-4.
- *keiki: register-file shape hash* (§7.2) — lands alongside §7.1.
- *keiki: structured error model on `step`/`omega`* (§7.3).

**Block 3 — Quality-of-life Wanted items, schedule for v1.x.** Five items.

- *kiroku-store: prefix-style category subscription* (§4.4).
- *kiroku-store: migration tooling story* (§4.5).
- *shibuya-core: supervised non-adapter-shaped worker entry point* (§6.1).
- *keiki: compile-time check that event payloads are inverse-recoverable* (§7.4).
- *keiki: compensate direction on `SymTransducer`* (§7.5).
- *keiki: optional constrained effectful reads in `decide`* (§7.6).

**Block 4 — Optional, schedule when convenient.** Six items.

- *kiroku-store: `enrichEvent`/encoder hook in the interpreter* (§4.6).
- *kiroku-store: `correlation_id`/`causation_id` chain-walking helpers* (§4.7).
- *kiroku-store: combined snapshot + tail-events read query* (§4.8).
- *kiroku-store: `lookupStreamId :: StreamName -> Eff es (Maybe StreamId)` helper* (§4.9).
- *kiroku-store: `readStreamUntil` for point-in-time replay* (§4.10).
- *keiki: property-test helpers (Given/When/Then)* (§7.7).
- *keiki: in-keiki schema-evolution / upcaster framework* (§7.8).

The DAG between blocks is forward-only: nothing in Block 2 depends on anything in Block 3 or 4; nothing in Block 3 depends on anything in Block 4. Within a block, items are independent unless explicitly noted (the only intra-block coupling is §7.1 and §7.2, which a single keiki PR is expected to deliver together).


## 4. kiroku-store roadmap

`kiroku-store` is the Postgres event-store package at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store`. The `Store` effect lives in `src/Kiroku/Store/Effect.hs`; the SQL schema in `sql/schema.sql`; the public API in `src/Kiroku/Store/{Append,Read,Subscription}.hs` and the dispatch in `src/Kiroku/Store/Effect.hs`.

### 4.1 Single-stream `runInTransaction` combinator (Blocking)

*What is missing today.* `appendToStream` runs as a single SQL `WITH`-CTE inside `Pool.use` (no Haskell-layer transaction); only `appendMultiStream` and `HardDeleteStream` open a `TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write` block. Verified at `kiroku-store/src/Kiroku/Store/Effect.hs:160` (`appendMultiStream`) and `:190` (`HardDeleteStream`); all other `Store` cases use `usePool` which is plain `Pool.use` against a `Hasql.Session.Session`. There is no public combinator that wraps a single-stream append and a user-supplied `Hasql.Transaction.Transaction a` in one `TxSessions.transaction`.

*What keiro needs.* A public combinator with this shape (or near-equivalent):

    appendToStreamInTransaction
      :: (HasCallStack, Store :> es)
      => StreamName
      -> ExpectedVersion
      -> [EventData]
      -> (StreamId -> AppendResult -> Hasql.Transaction.Transaction a)
      -> Eff es a

The user-supplied `Hasql.Transaction.Transaction a` runs *after* the append's SQL inside the same `TxSessions.transaction`, sees the just-appended events under MVCC's `ReadCommitted` isolation, and commits or rolls back atomically with the append. The `StreamId` and `AppendResult` are passed in so the user code can correlate (e.g., write the new events' `globalPosition` into a projection table without re-reading).

An alternative shape — exposing a generic `runInTransaction :: Hasql.Transaction.Transaction a -> Eff es a` and letting the user assemble append + side-effect inside it — would also work, provided the resulting transaction respects the same `ReadCommitted, Write` semantics `appendMultiStream` uses.

*Why.* EP-1's transactional-step combinator `runCommandWithSql` (`docs/research/06-command-cycle-design.md` §10) is the canonical primitive that both EP-3's inline-projection lifecycle (`docs/research/08-subscription-and-process-manager-design.md` §2) and EP-3's outbox write path (§6) are built on. Without it, every keiro transactional-step caller must route through `appendMultiStream` with a single-element list, paying the cost of the `appendMultiStream` advisory-lock-pre-acquisition for a single-stream operation. The advisory locks are not strictly *wrong* on a single-stream call (one lock acquired, one released, no contention with other writers on different streams), but they are wasteful, and the workaround is mildly user-hostile (the public API for an inline projection should not name `appendMultiStream`).

*Priority.* **Blocking.** Without this combinator, keiro v1's transactional-step API cannot exist with a clean signature. Either keiro builds the workaround into its public API (exposing `runCommandWithSql` that secretly routes through `appendMultiStream`, locking the user into the workaround forever) or it ships without `runCommandWithSql`, which deletes the inline-projection lifecycle and the outbox write path — features the implementation MasterPlan treats as v1 must-have.

*Design constraint.* The combinator must accept an arbitrary user-supplied `Hasql.Transaction.Transaction a` and commit it in the same tx as the append. The transaction must use `ReadCommitted` isolation matching `appendMultiStream`'s existing block (changing isolation at this boundary would create a per-call decision point keiro does not need). Error handling must surface the same `StoreError` variants as `appendToStream` plus any user-side error propagated through `Hasql.Transaction.Transaction` (the error model can mirror `runCommandRetry`'s use of `Error StoreError`).

*Suggested sequencing.* Block 1. This is the only Block-1 item. Land before keiro v1 implementation starts.

*Provenance.* EP-1 §10 (the transactional-step primitive design); EP-1 §14 (kiroku gap "Single-stream transactional append"); EP-3 §2 (inline-projection lifecycle); EP-3 §6 (outbox write path); EP-3 §13 ("kiroku-store: Single-stream `runInTransaction`"); MasterPlan Surprises & Discoveries entry of 2026-05-05 (EP-1).

### 4.2 Streamly-native single-stream forward read (Wanted)

*What is missing today.* `Kiroku.Store.Read.readStreamForward` returns `Vector RecordedEvent` — a paginated read materialized in memory (`docs/research/01-kiroku-read-side.md` §"Read APIs"). The kiroku-store subscription bridge `Kiroku.Store.Subscription.Stream` already returns a `Streamly.Data.Stream.Stream IO RecordedEvent` for live subscriptions; the missing piece is the analogous shape for non-subscription single-stream forward reads.

*What keiro needs.* A new function, sibling to the existing `readStreamForward`:

    readStreamForwardStream
      :: (Store :> es, Error StoreError :> es)
      => StreamName
      -> StreamVersion        -- exclusive cursor; 0 = read from beginning
      -> Stream (Eff es) RecordedEvent

The `Stream` is built by paginating the existing `readStreamForward` in chunks (default 256 events per page) and flattening into a `Stream`-shaped output, exactly the wrapper EP-1's hydration currently builds at the keiro layer (`docs/research/06-command-cycle-design.md` §5's `hydrationStream`). Lifting it upstream removes the wrapper from every keiro user's path and makes the streaming shape consistent with `Subscription.Stream`.

*Why.* EP-1's hydration pipeline is a Streamly `Stream → Fold` running in constant memory; the parent MasterPlan's "Streamly substrate" Integration Point fixes this as the canonical multi-event shape for keiro. With `readStreamForward` returning a `Vector`, keiro must wrap in `Stream.unfoldrM` and paginate manually — a few dozen lines that work but duplicate machinery the kiroku-store team already wrote for the subscription bridge.

*Priority.* **Wanted.** keiro v1 ships with the wrapper. The wrapper is a few dozen mechanical lines and is fully expressible at the keiro layer (`docs/research/06-command-cycle-design.md` §5 already shows it). Replacing the wrapper with a kiroku-side `Stream` retires duplicated paging logic; it does not unblock any keiro v1 feature.

*Design constraint.* The new `readStreamForwardStream` must use the same per-page batched read kiroku-store already implements (so `Vector`-returning `readStreamForward` and `Stream`-returning `readStreamForwardStream` share a single SQL path and a single set of error semantics). The page size should be configurable per call (256 default) so callers with very wide events or very long streams can tune memory.

*Suggested sequencing.* Block 2. Independent of every other item. Lift the existing batched-read loop to return a `Stream`; unit tests can be derived from the existing `Vector`-based tests by `Stream.toList`-folding the new output.

*Provenance.* EP-1 §14 ("Streamly-native single-stream forward read"); MasterPlan Decision Log entry of 2026-05-04 (Streamly substrate); MasterPlan Revisions entry of 2026-05-04 (Streamly substrate canonicalised).

### 4.3 Postgres 18 deployment documentation (Wanted)

*What is missing today.* Kiroku's embedded `schema.sql` uses `uuidv7()` (verified at `kiroku-store/sql/schema.sql:2` — `-- Requires PostgreSQL 18+ (for uuidv7())` — and at `:25` — `event_id UUID PRIMARY KEY DEFAULT uuidv7()`). The dependency on PG 18 is documented inside the SQL file but not surfaced anywhere a deployer would see before runtime. Production deployments on Postgres 17.x fail at schema initialization with `function uuidv7() does not exist`.

*What keiro needs.* The Postgres 18 requirement must be prominent in `kiroku-store/README.md` (or its top-level equivalent) and in any deployment guide kiroku publishes. Optional secondary work: a polyfill `CREATE FUNCTION uuidv7()` definition for Postgres 17 or earlier, shipped as an opt-in `schema-pg17-compat.sql` for environments that cannot upgrade.

*Why.* The user's outer Nix profile ships PG 17.9; the kiroku-project flake pins `pkgs.postgresql_18` for development, but downstream deployments using their own pins will not. The keiro implementation MasterPlan will likely run into this constraint on a CI environment or staging host that has not yet rolled forward to PG 18. Documenting the requirement turns a runtime failure into a pre-deployment checklist item.

*Priority.* **Wanted.** Not a code change in kiroku; a documentation change. The constraint exists today and is not changing. Surfacing it earlier prevents avoidable cycles.

*Design constraint.* No code constraint. The README addition should name the specific Postgres 18 feature kiroku depends on (`uuidv7()`) so a reader can decide whether to upgrade or to install a polyfill.

*Suggested sequencing.* Block 2. Independent of every other item.

*Provenance.* EP-1 §14 ("Postgres-version requirement documentation"); MasterPlan Surprises & Discoveries entry of 2026-05-05 (EP-1, "kiroku's embedded `schema.sql` uses Postgres 18's `uuidv7()` function").

### 4.4 Prefix-style category subscription (Wanted)

*What is missing today.* `Kiroku.Store.Subscription` exposes `SubscriptionTarget = AllStreams | Category CategoryName`; the `Category` variant matches an exact category derived from `stream_name` via the Eventide convention `<category>-<id>` (the prefix before the first `-`, computed by the `streams.category` generated column at `kiroku-store/sql/schema.sql`). There is no string-prefix or pattern-matching variant.

*What keiro needs.* Either a new `SubscriptionTarget` variant — for example, `CategoryPrefix Text` matching every stream whose `stream_name` starts with the given prefix — or a generalised pattern-matching variant. The keiro v1 use case is observing every process-manager state stream as a category: PM streams are named `pm-<pmName>-<correlationId>`, so the prefix `pm-` matches every PM stream regardless of which PM produced it. v2 workflows will use the `wf-` prefix the same way.

*Why.* EP-5's v1 substrate names PM state streams `pm-<pmName>-<correlationId>` (`docs/research/08-subscription-and-process-manager-design.md` §5; `docs/research/10-workflow-roadmap.md` §2). The current `Category Text` exact-match means an operator wanting to observe every PM in the deployment must register one subscription per PM name — fine for a small deployment, irritating at scale, and impossible if PMs are added dynamically without restarting the subscriber.

*Priority.* **Wanted.** keiro can register one subscription per known PM at registration time, computing the names from the `EventStream` registry. The workaround scales with the static list of PMs; it does not scale with dynamically-added PMs (which keiro v1 does not support anyway). Lifting the prefix-style category subscription upstream removes this constraint cleanly.

*Design constraint.* The new variant must continue to use kiroku's existing publisher-driven re-query mechanism on category subscriptions (per `docs/research/01-kiroku-read-side.md` §"Subscriptions Hook" and `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`). Performance must be no worse than `Category` exact match: the SQL `WHERE stream_name LIKE $1 || '%'` plus an index supporting prefix lookups is the natural shape. The existing `streams.category` generated column does not help (it is computed for exact-match categories); a btree index on `streams.stream_name` is sufficient.

*Suggested sequencing.* Block 3. After Block 1 (no dependency, but the v1 workaround is easy enough to live with through Block 2).

*Provenance.* EP-5 §9 ("kiroku-side: process-manager state-stream naming convention"); MasterPlan Surprises & Discoveries entry of 2026-05-06 (EP-5, "three new questions that touch upstream libraries").

### 4.5 Migration tooling story (Wanted)

*What is missing today.* Kiroku's schema initialization is a single embedded `schema.sql` run idempotently at app startup (`kiroku-store/src/Kiroku/Store/Schema.hs`). There is no migration tool: schema changes mean editing `schema.sql` and trusting that `IF NOT EXISTS` handles the additive cases. Adding columns, dropping columns, changing types, renaming tables — all are manual operator work today.

*What keiro needs.* A migration tool integrated with kiroku's startup path — `codd` or `hasql-migration` are the obvious candidates (per `docs/research/01-kiroku-read-side.md` §"Storage & Migrations"). Each migration is a versioned `.sql` file; kiroku's startup applies pending migrations in order, records applied versions in a tracking table, and refuses to start if a migration has been deleted or modified.

*Why.* keiro adds five new tables (`keiro_subscriptions`, `keiro_outbox`, `keiro_inbox`, `keiro_snapshots`, `keiro_timers`; v2 adds two more — `keiro_workflow_steps`, `keiro_awakeables`). Each is created idempotently in keiro's own `schema.sql` bundle (per `docs/research/09-snapshot-strategy.md` §2 — the `keiro_snapshots` migration uses `CREATE TABLE IF NOT EXISTS`), but evolutionary changes to those tables require migration tooling that does not exist. Without it, every schema change is an out-of-band operator playbook ("connect to prod, run this `ALTER TABLE`, hope for the best"). The lift is upstream because kiroku owns the schema initialization machinery; keiro inherits whatever kiroku ships.

*Priority.* **Wanted.** Not blocking — additive `CREATE TABLE` migrations work fine via `IF NOT EXISTS`. Becomes critical the first time a keiro table needs an `ALTER`. The keiro implementation MasterPlan can ship with the additive-only constraint in v1; v1.x bumps onto the proper tool when it lands.

*Design constraint.* The chosen migration tool should be embeddable in kiroku-store's existing startup path so deployments do not need a separate operator step. `codd` and `hasql-migration` both have library APIs that fit.

*Suggested sequencing.* Block 3. Independent of every other item; can land any time before the first non-additive schema change.

*Provenance.* `docs/research/01-kiroku-read-side.md` §"Storage & Migrations" ("**No migration tooling in kiroku itself** — schema.sql is embedded and run once at app startup"); EP-4 §2 (mentions the keiro migration depends on `streams` already existing — i.e., implicitly takes a position on ordering that a migration tool would formalise).

### 4.6 `enrichEvent` / encoder hook in the interpreter (Optional)

*What is missing today.* The `Store` effect's interpreter (`runStorePool`) does not expose a hook for cross-cutting concerns at the event-data boundary (`docs/research/01-kiroku-read-side.md` §"Effectful Surface" and Gap #8). A user wanting to encrypt event payloads, compress them, or inject OpenTelemetry trace context into metadata must do so at every call site.

*What keiro needs.* An interpreter-level hook of the shape:

    data StoreSettings = StoreSettings
      { enrichEvent :: Maybe (EventData -> IO EventData)
      , decodeHook  :: Maybe (RecordedEvent -> IO RecordedEvent)
      , …
      }

so encryption, compression, and trace-context injection can be wired once at the interpreter setup site and applied uniformly.

*Why.* keiro's observability layer (`docs/research/06-command-cycle-design.md` §12) wants to inject `keiro.span.trace_id`/`keiro.span.span_id` into `EventData.metadata` on every append. With no hook, keiro builds this into its own `runCommand` wrapper — fine for keiro's first-class write path, but every direct kiroku call site (e.g., a user calling `appendToStream` outside `runCommand`) bypasses the injection.

*Priority.* **Optional.** keiro's `runCommand` is the first-class write path; bypassing it loses the observability convention anyway, and the surface area of "user calls kiroku directly" is small. The hook is a nice-to-have for users who want kiroku-level observability.

*Design constraint.* The hook must run inside the interpreter — not at the SQL level — so it sees the typed `EventData` before encoding. The hook must be optional and default to no-op; existing kiroku users must see no behavioural change.

*Suggested sequencing.* Block 4. Schedule when convenient.

*Provenance.* `docs/research/01-kiroku-read-side.md` §"Gaps for Keiro" #8.

### 4.7 `correlation_id` / `causation_id` chain-walking helpers (Optional)

*What is missing today.* `RecordedEvent` carries `correlationId` and `causationId` fields (`docs/research/01-kiroku-read-side.md` §"Type Model"), and they are written to indexed columns (`ix_events_correlation_id`, `ix_events_causation_id` per the schema), but kiroku does not expose helpers for walking causation chains, querying every event with a given correlation, or stitching OpenTelemetry trace context.

*What keiro needs.* Functions of the shape:

    findCausationChain :: EventId -> Eff es [RecordedEvent]
    findByCorrelation  :: UUID    -> Eff es [RecordedEvent]
    extractTraceContext :: RecordedEvent -> Maybe TraceContext
    injectTraceContext  :: TraceContext -> EventData -> EventData

The first two are SQL-shape helpers (the indexes already support them); the second two are application-level helpers that interact with `hs-opentelemetry`.

*Why.* EP-3's process managers (`docs/research/08-subscription-and-process-manager-design.md` §5) carry causation chains: a PM emits a command whose resulting event's `causationId` is the source event's `eventId`. Reconstructing the chain for an operator who is debugging a stuck saga is a common request. Without the helpers, every team writes their own walker.

*Priority.* **Optional.** The SQL is straightforward; keiro can ship its own helper at the keiro layer. Lifting it upstream is a maintenance nicety, not a correctness one.

*Design constraint.* The OpenTelemetry-aware helpers should depend on `hs-opentelemetry` only as an optional dep so kiroku-store stays minimal. The MasterPlan's Surprises & Discoveries entry of 2026-05-05 (EP-3) flags `hs-opentelemetry` version skew between shibuya-core and pgmq-hs as a build-environment coordination item; whatever kiroku picks must not deepen that skew.

*Suggested sequencing.* Block 4.

*Provenance.* `docs/research/01-kiroku-read-side.md` §"Gaps for Keiro" #9.

### 4.8 Combined snapshot + tail-events read query (Optional)

*What is missing today.* EP-4's snapshot read is keyed on `stream_id` and returns the latest snapshot row; EP-1's hydration then reads tail events from `streamVersion + 1` forward. Two queries, two round-trips.

*What keiro needs.* A combined read that returns the latest snapshot row plus every event past the snapshot's `stream_version` in one round-trip:

    readStreamFromSnapshot
      :: StreamName
      -> Eff es (Maybe SnapshotRow, Stream (Eff es) RecordedEvent)

The snapshot row is `Maybe` (no snapshot yet); the stream of events is open-ended.

*Why.* EP-4 §15 records this as a v2 optimization. Saves one round-trip per command on hot aggregates; meaningful at high throughput, irrelevant otherwise.

*Priority.* **Optional.** keiro v1 uses two queries; the cost is one extra round-trip per command, which is well below the network noise on a Postgres-on-localhost deployment. Hot remote-Postgres deployments may want this; not a v1 concern.

*Design constraint.* The combined query must remain consistent under MVCC: the snapshot row and the tail events must reflect the same point-in-time view. A single Postgres `BEGIN; SELECT snapshot; SELECT tail FROM events; COMMIT;` block (or a snapshot-isolation transaction) gives this for free. The combined helper depends on `keiro_snapshots` existing, which is a keiro-owned table — kiroku-store would need to take a dep on the keiro table or accept a generic "sidecar table" interface. The latter is more general but more complex.

*Suggested sequencing.* Block 4. Schedule only after profiling confirms snapshot+tail reads are a hot path.

*Provenance.* EP-4 §15 ("two questions deferred to v2"); EP-4's published §11 ("Integration with EP-1").

### 4.9 `lookupStreamId :: StreamName -> Eff es (Maybe StreamId)` helper (Optional)

*What is missing today.* `Kiroku.Store.Read.getStream` returns `Maybe StreamInfo` carrying the `StreamId`, but it is overweight for the use case "I just need the surrogate id, not the full row." Internal kiroku code already calls a `findStreamId` SQL statement (visible at `kiroku-store/src/Kiroku/Store/SQL.hs`); it is not exposed publicly.

*What keiro needs.* A public combinator:

    lookupStreamId :: StreamName -> Eff es (Maybe StreamId)

EP-4's snapshot write uses an inline `SELECT stream_id FROM streams WHERE stream_name = $1` to resolve the id from the name; if profiling shows the duplicate name→id resolution is hot (the snapshot read also keys on `stream_id`), exposing the existing internal helper saves a row decode.

*Why.* EP-4 §15 records this as an optimization candidate, not a correctness gap. The current `getStream` works; it just decodes more than necessary.

*Priority.* **Optional.** Schedule only if profiling identifies the resolution as hot.

*Design constraint.* No new SQL; lift the existing internal helper to public.

*Suggested sequencing.* Block 4.

*Provenance.* EP-4 §15 ("kiroku: optional `lookupStreamId` helper"); EP-4 §6 (the snapshot read SQL is keyed on `stream_id`).

### 4.10 `readStreamUntil` for point-in-time replay (Optional)

*What is missing today.* `readStreamForward` accepts a starting cursor but no ending cursor; reading the events of a stream as of timestamp `T` or `globalPosition P` requires reading the whole stream and filtering at the application layer.

*What keiro needs.* A bounded read:

    readStreamUntil
      :: StreamName
      -> StreamVersion       -- start (exclusive)
      -> EndCursor           -- end (inclusive); UntilPosition GlobalPosition | UntilTimestamp UTCTime | UntilVersion StreamVersion
      -> Eff es (Vector RecordedEvent)

*Why.* Useful for debugging, time-travel queries, and audit replay. Not used by any keiro v1 lifecycle.

*Priority.* **Optional.** Schedule when convenient.

*Design constraint.* The end-cursor variants must be SQL-friendly (each translates to a `WHERE` clause on indexed columns).

*Suggested sequencing.* Block 4.

*Provenance.* `docs/research/01-kiroku-read-side.md` §"Gaps for Keiro" #10.


## 5. shibuya-kiroku-adapter roadmap

`shibuya-kiroku-adapter` is the bridge package at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter`. It exposes `Shibuya.Adapter.Kiroku.kirokuAdapter :: KirokuStore -> KirokuAdapterConfig -> Eff es (Adapter es RecordedEvent)`.

### 5.1 `HandlerInTransaction` shape for transactional checkpoint advance (Wanted, Blocking for exactly-once async projections)

*What is missing today.* The adapter's `toIngested` (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs:42-47`) documents the checkpoint behaviour: "`AckOk`, `AckRetry`, `AckDeadLetter` — no-op (checkpoint is managed by the Kiroku subscription worker, not by the handler)." The kiroku subscription worker advances `subscriptions(subscription_name, last_seen)` after the handler returns, in its own SQL connection. The handler's projection write (whatever it does) and the checkpoint advance therefore live in *different* Postgres transactions; a crash between them produces at-least-once delivery.

*What keiro needs.* A new handler shape and a runner that consumes it:

    type HandlerInTransaction es msg = Ingested es msg -> Hasql.Transaction.Transaction AckDecision

    runSerialInTransaction
      :: (IOE :> es)
      => Adapter es RecordedEvent
      -> HandlerInTransaction es RecordedEvent
      -> Eff es ()

The new runner opens a `TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write` block per ingested event, runs the user's `Hasql.Transaction.Transaction AckDecision`, and — only on a successful `AckOk` — performs the kiroku-side `UPDATE subscriptions SET last_seen = $cursor WHERE subscription_name = $name` *inside the same transaction*. The user's projection write and the checkpoint advance commit atomically; a crash between them is impossible.

*Why.* EP-3 §3 records that the design's exactly-once async-projection claim depends on this shape; without it, async projections are at-least-once with user-side idempotency (recorded in the published EP-3 design as the v1 default). The MasterPlan's Surprises & Discoveries entry of 2026-05-05 (EP-3) explicitly forwards this gap and notes that EP-3's spike was deferred because the central exactly-once-via-transaction claim cannot be verified without it.

*Priority.* **Wanted (Blocking for exactly-once).** keiro v1 ships with at-least-once async projections. Handlers must be idempotent (typically by writing rows keyed on `eventId` or `INSERT ... ON CONFLICT DO NOTHING`). Lifting the gap upstream retires the at-least-once constraint and the user-side idempotency burden.

*Design constraint.* The new runner must coexist with the existing `runSerial` (from `shibuya-core`'s `Shibuya.Runner.Serial`) — keiro v1's at-least-once path uses the existing runner unchanged. The transactional-checkpoint runner is additive. The shape change to kiroku is essentially: surface the checkpoint-advance SQL statement so the adapter-runner can call it inside the user's tx, rather than running it autonomously after the handler returns. This is a kiroku-store change as well as a shibuya-kiroku-adapter change; the two must land together.

*Suggested sequencing.* Block 2. Independent of §4.1 in principle (the adapter's checkpoint-advance SQL is a separate path from the append SQL), but co-scheduling the two PRs is reasonable since both touch transaction boundaries in kiroku-store.

*Provenance.* EP-3 §3 ("Failure semantics — at-least-once"); EP-3 §13 ("shibuya-kiroku-adapter: Handler shape that opts into the kiroku checkpoint advance"); MasterPlan Surprises & Discoveries entry of 2026-05-05 (EP-3, "Exactly-once is achievable but blocked by an upstream gap").


## 6. shibuya-core roadmap

`shibuya-core` is the supervised-worker substrate at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core`. Most of shibuya's surface is consumed unchanged by keiro; the one item EP-5 raises is a generalisation question.

### 6.1 Supervised non-adapter-shaped worker entry point (Wanted)

*What is missing today.* Shibuya's runners (`Shibuya/Runner/{Serial,Ingester,Supervised}.hs`) supervise *adapter*-shaped workers — workers that consume a `Stream (Eff es) (Ingested es msg)` source plus a `Handler es msg`. The durable-timer worker (`docs/research/10-workflow-roadmap.md` §3) is not adapter-shaped: it polls `keiro_timers` directly via `SELECT … FOR UPDATE SKIP LOCKED` and does not consume a shibuya stream.

*What keiro needs.* Either (a) a shibuya-side generalisation that supervises non-adapter-shaped workers (a function `Eff es ()` plus restart policy plus observability hooks), or (b) keiro wraps the timer worker as a degenerate adapter whose source is a `Stream` of "tick events" the worker uses to drive its polling loop.

Option (b) — the workaround at the keiro layer — is straightforward: a 50-line shim. Option (a) — the upstream lift — is more general and lets shibuya host other non-adapter workers (the outbox drain worker, EP-3 §6 — also a polling loop, also currently keiro-side).

*Why.* keiro wants to host the timer worker on shibuya's supervised-worker substrate to inherit free OpenTelemetry spans (timer fires become observable spans alongside subscription deliveries) and free shibuya-metrics gauges (timer-fire latency, queue depth). Without the upstream lift, the timer worker runs as a stand-alone OS process and the operator monitors it separately.

*Priority.* **Wanted.** keiro v1 can ship with the timer worker as a stand-alone process or as a degenerate adapter. The upstream lift is an operator-experience improvement, not a feature gate.

*Design constraint.* The new worker shape must be supervised by NQE (per `docs/research/03-shibuya-subscriptions.md` §"Concurrency & Supervision") and must surface OpenTelemetry spans through `Shibuya.Telemetry.*`. Restart policy semantics must mirror the adapter-runner: bounded restarts, escalation to the supervisor on repeated failure.

*Suggested sequencing.* Block 3. Schedule when shibuya's roadmap revisits the supervisor's surface area.

*Provenance.* EP-5 §3 ("Open question forwarded to EP-6"); EP-5 §9 ("shibuya-side: should the durable-timer worker reuse shibuya's supervisor?"); MasterPlan Surprises & Discoveries entry of 2026-05-06 (EP-5).


## 7. keiki roadmap

`keiki` is the pure functional core at `/Users/shinzui/Keikaku/bokuno/keiki`. The keiro ⇄ keiki contract is the native `SymTransducer phi rs s ci co` (per the MasterPlan's Decision Log entry of 2026-05-04, "Reject `Keiki.Decider` as the keiro ⇄ keiki contract"). All gaps below are framed against that contract.

### 7.1 Register-file `<-> Aeson.Value` helper (Wanted, Blocking for EP-4)

*What is missing today.* `RegFile rs` is keiki's typed heterogeneous tuple of `(Symbol, Type)` slots (`docs/research/02-keiki-decide-loop.md` §"The Fold"). keiki performs no serialization; the survey records that "keiki commits to a single static schema per deployment. Schema evolution is an *application* concern" and that "JSON/CBOR/Protobuf codecs live in the runtime." There is no helper for walking the slot list and producing/consuming `Aeson.Value`.

*What keiro needs.* A keiki-side serialization class plus the encoder/decoder pair:

    class RegFileToJSON rs where
      regFileToJSON   :: RegFile rs -> Aeson.Value
      regFileFromJSON :: Aeson.Value -> Either String (RegFile rs)

Default instances are derived per slot from the slot type's `Aeson.ToJSON` / `Aeson.FromJSON`, walking the type-level slot list at compile time. The shape is analogous to `Keiki.Generics`'s existing `mkInCtor` machinery extended to registers.

*Why.* Three customers:

- *EP-1* (`docs/research/06-command-cycle-design.md` §14) — the snapshot path needs `(s, RegFile rs) -> Aeson.Value`.
- *EP-2* (`docs/research/07-codec-strategy.md` §12) — reiterates EP-1's request for the same reason.
- *EP-4* (`docs/research/09-snapshot-strategy.md` §15 #1) — `StateCodec (s, RegFile rs)` cannot be derived without it; every aggregate author hand-rolls the encoding by walking the slot list.

Without the helper, every keiro user with a non-trivial register file writes a hand-rolled walker per aggregate. This is mechanical but tedious and easy to get wrong (slot order, encoding format, missing slots). The helper consolidates the work into one keiki-side primitive.

*Priority.* **Wanted (Blocking for EP-4).** EP-4's `StateCodec` is fully expressible without the helper — the aggregate author just writes the walker by hand. v1 keiro can ship; the cost is per-aggregate boilerplate. Lifting the helper upstream removes the boilerplate cleanly.

*Design constraint.* The helper must compose with keiki's existing `Keiki.Generics.mkInCtor` machinery so an aggregate author who already uses `mkInCtor` for input constructors gets a uniform deriving experience for registers. The `Aeson.Value` shape produced should be a JSON object keyed by the slot's `Symbol` (so the JSON is browseable: `{"timer": "2026-05-06T...", "retry_count": 3}`).

*Suggested sequencing.* Block 2. Lands together with §7.2 (the shape hash) — both are register-file-shape concerns and both can be derived from the same compile-time walk.

*Provenance.* EP-1 §14 ("Register-file serialization helper"); EP-2 §12 ("Register-file serialization helper"); EP-4 §3, §15 #1; MasterPlan Surprises & Discoveries entry of 2026-05-05 (EP-2, "no upstream change to kiroku — `EventData.metadata`, …, the only EP-2-flagged upstream item is keiki-side"); MasterPlan Surprises & Discoveries entry of 2026-05-06 (EP-4, "EP-6 gains a *second* keiki-side gap").

### 7.2 Register-file shape hash (Wanted, Blocking for EP-4)

*What is missing today.* The register-file slot list `rs` is a type-level `[(Symbol, Type)]`. keiki has no way today to compute a stable `Text` hash of that shape. The keiki survey notes that "register-file shape changes invalidate existing snapshots (snapshot validation uses a register-file shape hash)" but the hash is not computed by keiki — it is alluded to as something the application would do.

*What keiro needs.* A keiki-side class with a stable hash derivation:

    class KnownRegFileShape rs where
      regFileShapeHashFor :: Proxy rs -> Text

The default instance hashes the rendered representation of each `(Symbol, Type)` pair at compile time (using `KnownSymbol` for the slot name and `Typeable` / `TypeRep` for the slot type). The hash must be:

- Stable across builds (deterministic).
- Sensitive to slot reorderings, slot renames (Symbol changes), and slot-type changes.
- Insensitive to type-class instance changes that do not affect the slot's `TypeRep` (so adding `Show` to a slot type does not invalidate snapshots).

*Why.* EP-4 §3 records that the codec-version integer alone cannot detect register-file slot reshapes that preserve the JSON shape (swapping two slots of the same JSON type, renaming a slot whose `Symbol` does not appear in the encoded JSON). The shape hash is the secondary discriminant that catches these cases. EP-4 §15 #2 names EP-4 as the only customer today; the helper is small enough that landing it alongside §7.1 in the same keiki PR is the natural shape.

*Priority.* **Wanted (Blocking for EP-4).** Without the hash, EP-4's snapshot reader has only the `state_codec_version` integer to discriminate, and a slot-swap-without-codec-bump silently round-trips into a wrong runtime shape. The aggregate author can compute the hash by hand if needed; lifting the helper upstream means every aggregate gets it for free.

*Design constraint.* The hash must be deterministic across GHC versions and across module compilations. SHA-256 over a canonicalised `[(Symbol, TypeRep)]` rendering is the recommended shape; any other deterministic hash is fine. The function must be pure (no `IO`).

*Suggested sequencing.* Block 2. Lands together with §7.1.

*Provenance.* EP-4 §15 #2; `docs/research/02-keiki-decide-loop.md` §"Codecs & Serialization" ("snapshot validation uses a register-file shape hash"); MasterPlan Surprises & Discoveries entry of 2026-05-06 (EP-4, "Promote the register-file shape hash to a first-class column").

### 7.3 Structured error model on `step` / `omega` (Wanted)

*What is missing today.* `step` and `omega` return `Maybe (s, RegFile rs, Maybe co)` and `Maybe co` respectively (`docs/research/02-keiki-decide-loop.md` §"The Decide"). `Nothing` conflates three distinct outcomes:

- **Legitimate model rejection** — no edge fires for this command in this state.
- **Guard failed** — an edge's guard returned `False` when applied to the recovered input.
- **Edge update failed** — currently impossible (updates are total), but the v2 register-typed updates may not be.

A keiro caller seeing `Nothing` from `step` cannot tell which case applies and conservatively maps every `Nothing` to `CommandError.CommandRejected`. This is correct for the first case and lossy for the second.

*What keiro needs.* A typed return:

    data StepResult phi rs s co
      = Fired !s !(RegFile rs) !(Maybe co)  -- typical case, optionally with event
      | NoEdge                              -- no active edge for this command
      | GuardFailed !Reason                 -- an edge's guard returned False
      | UpdateFailed !Reason                -- (v2-typed updates) update failed

    step
      :: BoolAlg phi (RegFile rs, ci)
      => SymTransducer phi rs s ci co
      -> s -> RegFile rs -> ci -> StepResult phi rs s co

The same shape applies to `omega`. The `Reason` field (a free-form `Text` is acceptable v1; a structured type is acceptable v2) carries operator-actionable diagnostic information.

*Why.* EP-1 §14 records the request: keiro's `CommandError` distinguishes `DecodeError`, `ReplayError`, `CommandRejected`, and infrastructure errors. Today every `Nothing` from `step` becomes `CommandRejected` with the original `Show ci` representation as the only diagnostic. With the structured return, keiro can emit a richer `CommandError` and the caller can attribute root cause cleanly.

*Priority.* **Wanted.** keiro v1 ships with the conservative `Nothing → CommandRejected` mapping. The richer error model is a quality-of-debugging win, not a feature gate.

*Design constraint.* The shape change is breaking for direct keiki users (every existing `case step … of Just _ -> … Nothing -> …` must adapt). keiki may want to ship the new shape behind a new function name (`stepDetailed`?) and deprecate the `Maybe`-returning variant on a release boundary.

*Suggested sequencing.* Block 2. Independent of every other item.

*Provenance.* EP-1 §14 ("Structured error model on `step`/`omega`"); `docs/research/02-keiki-decide-loop.md` §"Gaps for Keiro" #3.

### 7.4 Compile-time check that event payloads are inverse-recoverable (Wanted)

*What is missing today.* keiki's `solveOutput` walks an edge's `OutFields` to invert an observed event back into the input that produced it (so `applyEvent` can replay through the matching edge's update). It only inverts:

- `TLit r` — literal,
- `TReg ix` — register read (treated as a no-op in the inverse),
- `TInpCtorField ic ix` — direct projection of a field of the named input constructor.

Computed terms (`TApp1 f t`, `TApp2 f a b`) defeat the inverse: `solveOutput` returns `Nothing`, `applyEvent` returns `Nothing`, replay raises `ReplayError`. The constraint is well-defined and stated in `docs/research/02-keiki-decide-loop.md`, but it is enforced at runtime — a `Nothing` from `applyEvent` deep into the replay loop — rather than at compile time.

*What keiro needs.* A typeclass or TH-level check that every `OutFields` an aggregate's edges produce contains no `TApp1`/`TApp2` term. The check must run at compile time so the aggregate fails to build, not at runtime when the spike crashes on its first replay.

*Why.* EP-1 §14 records the request: the EP-1 spike's first run crashed on `Incremented { newValue = counter + 1 }` because `+ 1` is a `TApp2` term that `solveOutput` cannot invert. The crash was at runtime, deep into a Postgres transaction. The aggregate author's mental model — "I wrote `newValue = counter + 1`, the type-checker accepted it" — gives no hint that the runtime will fail.

*Priority.* **Wanted.** keiro v1 ships with the runtime check (the `ReplayError` carries the offending event type so the operator can attribute root cause). The compile-time check is a quality-of-development win for aggregate authors.

*Design constraint.* The check must be expressible at the `OutFields` type-level (or via TH at the edge-construction site). It must produce a clear error message naming the offending term and the edge it lives on.

*Suggested sequencing.* Block 3. Schedule after §7.3 (the structured error model) so the runtime path is solid before the compile-time path is added.

*Provenance.* EP-1 §14 ("Compile-time check that event payloads are inverse-recoverable"); EP-2 §12 ("Reiterated from EP-1 §14"); MasterPlan Surprises & Discoveries entry of 2026-05-05 (EP-1, "keiki's `solveOutput` only inverts direct term shapes").

### 7.5 Compensate direction on `SymTransducer` (Wanted)

*What is missing today.* `SymTransducer phi rs s ci co` carries a forward direction (`step :: ci -> Maybe (s, RegFile rs, Maybe co)`) but no symmetric *compensate* direction. v1 sagas in keiro are authored as ordinary process managers whose step function emits compensating commands when failure events arrive — the application's event vocabulary carries the compensation, the PM's step function is the policy (`docs/research/10-workflow-roadmap.md` §2 #4).

*What keiro needs.* Either (a) an additional direction on the transducer:

    compensate
      :: BoolAlg phi (RegFile rs, ci)
      => SymTransducer phi rs s ci co
      -> s -> RegFile rs -> ci -> co -> Maybe co'

(or a similar shape that names the inverse explicitly), or (b) a documented pattern for composing forward + compensating transducers via existing `Keiki.Composition` combinators (`compose`/`alternative`/`feedback1`).

*Why.* EP-5 §9 records the question: making saga compensation a first-class formalism rather than an application convention would support the future SBV/z3 verification layer over compensation correctness. The argument against is that sagas are a small-enough subset of process managers that the application convention works fine; adding a direction complicates `compose`/`alternative`/`feedback1` and the verification story.

*Priority.* **Wanted.** v1 keiro ships sagas as application-level process managers (per the published EP-5 design). Lifting compensation to a typed concept is a quality-of-formalism win that EP-6 expects keiki's roadmap to weigh against its own verification milestones. It is not a feature gate for keiro v1.

*Design constraint.* If keiki adds the direction, it must compose cleanly with the existing combinators. If keiki rejects the direction, EP-5's v1 design (compensation via application convention) is the canonical answer and can be documented in `docs/research/10-workflow-roadmap.md` as the stable shape.

*Suggested sequencing.* Block 3. Schedule when keiki's verification roadmap is being scoped.

*Provenance.* EP-5 §9 ("keiki-side: should `step` carry a `compensate` direction for sagas?"); MasterPlan Surprises & Discoveries entry of 2026-05-06 (EP-5).

### 7.6 Optional constrained effectful reads in `decide` (Wanted)

*What is missing today.* keiki's `step` is pure: it cannot perform IO and cannot read external state (`docs/research/02-keiki-decide-loop.md` §"Effectful Story"; `keiki/docs/research/effects-boundary.md`). Decisions that need a database lookup must pre-fetch the value into the command payload at the call site.

*What keiro needs.* A way to permit *effectful read* in the decide phase under explicit constraints — read-only, deterministic, memoizable — perhaps via a new `SymTransducer` variant that takes an `Eff es` constraint set:

    data SymTransducerE phi rs s ci co es
    stepE :: SymTransducerE phi rs s ci co es -> s -> RegFile rs -> ci -> Eff es (StepResult …)

The `es` set is restricted to read-only effects (no `Store`-write capabilities, no `IO` writes), and the read must be deterministic on the input arguments so a replay produces the same result.

*Why.* EP-1 §14 records the request: workflow steps that look up external state on every step (blacklist lookups, feature flags) currently force the application to pre-fetch into the command payload. The pre-fetch dance is awkward at the call site and couples the command construction to the decision logic. Lifting the constraint inside keiki — under an explicit constraint set — would make these workflows cleaner.

*Priority.* **Wanted.** v1 keiro ships with pre-fetch-into-command (per the survey's "runtime adapter must pre-fetch and embed reads in the command payload"). Lifting the constraint upstream is a v1.x quality-of-life improvement.

*Design constraint.* The new variant must preserve replay-safety: a recorded event must replay to the same state regardless of the external state at replay time. This typically means the read result must be journaled into the event payload (or a register-file slot) so replay does not re-fetch.

*Suggested sequencing.* Block 3. Schedule when keiki's effects-boundary work resumes.

*Provenance.* EP-1 §14 ("Optional effectful reads in `decide`"); `docs/research/02-keiki-decide-loop.md` §"Gaps for Keiro" #4.

### 7.7 Property-test helpers (Given/When/Then) (Optional)

*What is missing today.* keiki's tests are hand-written `Hspec` against `applyEvent`/`reconstitute`; there are no Given/When/Then helpers (`docs/research/02-keiki-decide-loop.md` §"Testing"). EventStream authors writing their own tests against keiki's primitives must build the test machinery themselves.

*What keiro needs.* Property-test helpers:

    given :: SymTransducer phi rs s ci co -> [co] -> TestSpec phi rs s ci co
    whenC :: TestSpec phi rs s ci co -> ci -> TestSpec phi rs s ci co
    thenE :: TestSpec phi rs s ci co -> [co] -> Property
    thenS :: TestSpec phi rs s ci co -> s -> Property

so `given (transducer) [event1, event2] & whenC command3 & thenE [expectedEvent]` reads as a Given/When/Then sentence.

*Why.* `docs/research/02-keiki-decide-loop.md` §"Testing" notes "Given-When-Then helpers — none provided; tests are hand-written `Hspec`." EventStream authors writing keiro v1 will want them; without them every team builds its own test framework. Lifting it upstream means every keiki user gets the same vocabulary.

*Priority.* **Optional.** keiro can ship its own helpers at the keiro layer (a reasonable v1 production-library work item recorded in EP-2 §12 alongside the codec test composer). Lifting upstream is a uniform-experience win, not a feature gate.

*Design constraint.* The helpers must compose cleanly with keiki's existing test discipline (the EP-2 verdict on `hindsight` already prescribes a roundtrip property test plus golden tests per supported version; the new keiki helpers are orthogonal).

*Suggested sequencing.* Block 4.

*Provenance.* `docs/research/02-keiki-decide-loop.md` §"Testing"; EP-2 §10 (the test discipline keiro adopts on top).

### 7.8 In-keiki schema-evolution / upcaster framework (Optional)

*What is missing today.* keiki performs no schema evolution: codecs and upcasters are entirely keiro's responsibility per EP-2's design (`docs/research/07-codec-strategy.md` §2). The keiki survey notes "schema-evolution-aware in design, but **serialization is not implemented in keiki itself**" (`docs/research/02-keiki-decide-loop.md` §"Codecs & Serialization").

*What keiro needs.* If keiki ships its own upcaster framework, keiro can choose between keiro-side codecs (per EP-2's value-level design) or keiki-side codecs (per the keiki framework). EP-2's verdict on `hindsight` is "selectively borrow at the value level" with a deliberate rejection of the type-level machinery; a keiki-side framework should not re-introduce the rejected machinery without giving keiro a way to opt out.

*Why.* EP-2 §12 records this as a candidate keiki feature. v1 keiro keeps codecs at the keiro layer (the EP-2 published design uses a value-level `Codec e` record). Lifting codecs upstream is not necessary, and may create coupling EP-2's design deliberately avoids.

*Priority.* **Optional.** v1 keiro ships with keiro-side codecs. The keiki team owns this decision; keiro is not a stakeholder until keiki ships the framework.

*Design constraint.* If keiki adopts a codec framework, it must be optional at the keiro consumption boundary — keiro must be able to use its own value-level `Codec e` without keiki's framework.

*Suggested sequencing.* Block 4. Schedule per keiki's roadmap, not keiro's.

*Provenance.* `keiki/docs/research/schema-evolution.md`; EP-2 §12.


## 8. Cross-cutting items

### 8.1 Typed `StreamId a` per aggregate

*What is missing today.* kiroku's `StreamName` is `Text`-shaped and intentionally untyped at the API boundary (`docs/research/01-kiroku-read-side.md` §"Type Model"; `docs/research/01-kiroku-read-side.md` §"Gaps for Keiro" #2). keiro defines a typed wrapper at the keiro layer: `newtype AggregateId a = AggregateId { unAggregateId :: StreamName }` (`docs/research/06-command-cycle-design.md` §3).

*Verdict.* Keep the typed wrapper at the keiro layer for v1. EP-1 §3 explicitly chose this shape over pushing `newtype StreamName a` upstream to kiroku, on two grounds: (a) kiroku's API is intentionally untyped at the boundary and promoting `StreamName` to a parameterised newtype upstream would force every kiroku caller to bear a phantom they may not need; (b) keiro can pair `AggregateId a` with an `EventStream` lookup so the whole contract is recovered from a single type-level tag — a layer kiroku has no consumer for. EP-6 endorses this verdict: the typed wrapper is a keiro concept, not a kiroku concept. No kiroku-side action.

*Sequencing.* No upstream work; keiro v1 ships the wrapper at its own layer. If a future kiroku use case wants typed identity, EP-6 revisits.

*Provenance.* EP-1 §3 ("`AggregateId a` newtype and aggregate-type machinery"); `docs/research/01-kiroku-read-side.md` §"Gaps for Keiro" #2.

### 8.2 Streamly substrate

*Verdict.* No upstream work. Streamly is already a transitive dependency of every keiro user via `kiroku-store` (`Kiroku.Store.Subscription.Stream`) and `shibuya-core` (`Shibuya/Adapter.hs`, `Shibuya/Stream.hs`, `Shibuya/Runner/{Serial,Ingester,Supervised}.hs`). The MasterPlan's "Streamly substrate" Integration Point makes this canonical. The single Streamly-related kiroku item that *is* a gap — a `Stream`-returning single-stream forward read — is captured in §4.2.

*Sequencing.* No upstream work beyond §4.2.

*Provenance.* MasterPlan Decision Log entry of 2026-05-04 ("Treat Streamly's `Stream` and `Fold` … as the canonical in-process streaming substrate for keiro"); MasterPlan Integration Points (Streamly substrate); EP-1 §5; EP-3 §10; EP-4 §6, §11.

### 8.3 `hs-opentelemetry` version coordination

*What is missing today.* shibuya-core and pgmq-hs depend on different `hs-opentelemetry` revisions (per the MasterPlan's Surprises & Discoveries entry of 2026-05-05, EP-3): shibuya-core pins commit `adc464b…`, pgmq-hs pins `894c77f…`. When both libraries land in the same workspace, the version skew is a build-environment coordination item.

*What keiro needs.* The two upstream maintainers should converge on a single `hs-opentelemetry` revision before keiro v1's implementation MasterPlan begins integrating both libraries. The choice of revision is shibuya/pgmq-hs's call, not keiro's.

*Priority.* **Wanted.** Workaround at the keiro layer: pin one revision in keiro's `cabal.project` and accept whatever the resulting flag-set forces. This is brittle and regresses if either library bumps; lifting upstream is the proper fix.

*Suggested sequencing.* Block 2. Schedule together with the implementation MasterPlan's first build pass.

*Provenance.* MasterPlan Surprises & Discoveries entry of 2026-05-05 (EP-3, "the `hs-opentelemetry` version-skew between shibuya-core … and pgmq-hs … as a build-environment coordination item").


## 9. Explicitly NOT gaps

This section records items that earlier drafts of EP-6 (or a maintainer reading the surveys without the design documents) might mistake for gaps. Each entry explains why it is *not* a gap — usually because a specific keiro design decision absorbed it.

### 9.1 High-water-mark (HWM) for async-subscriber gap detection

*Verdict.* Not a gap. Kiroku's Strategy E (atomic `UPDATE … RETURNING` on the row `streams WHERE stream_id = 0`, claimed inside the same transaction that inserts events) produces *gap-free contiguous* `globalPosition`s with immediate read-your-own-writes. The bigserial-gap problem famously addressed by Marten's HWM does not exist here. The MasterPlan's Decision Log entry of 2026-05-04 explicitly removed the HWM recommendation; EP-3 §4 records the rejection in the published design.

*Provenance.* MasterPlan Decision Log entry of 2026-05-04 ("Remove the recommendation to adopt Marten's high-water-mark"); EP-3 §4 ("Implication for keiro: A subscriber's `last_seen` checkpoint can advance to *any* observed `globalPosition` without any gap-detection or watermark logic").

### 9.2 Streamly dependency or Streamly-shaped adapter at kiroku-store beyond what already exists

*Verdict.* Not a gap. kiroku-store already exposes `Kiroku.Store.Subscription.Stream`; shibuya-kiroku-adapter already lifts that into a shibuya `Stream (Eff es) (Ingested es RecordedEvent)`; shibuya's runners already consume those streams via `Stream.fold Fold.drain`. Streamly is therefore already a transitive dependency on every keiro user's path. The single Streamly-related kiroku item that *is* a gap — a `Stream`-returning single-stream forward read — is captured at §4.2 above.

*Provenance.* MasterPlan Integration Points (Streamly substrate); §8.2.

### 9.3 `Process` or `ProcessManager` primitive in keiki distinct from `SymTransducer`

*Verdict.* Not a gap. `SymTransducer phi rs s ci co` already *is* the right primitive for process managers — its register file carries process-manager state, ε-edges express silent transitions, and `Keiki.Composition`'s `compose`/`alternative`/`feedback1` express coordination. Process managers are a *use* of `SymTransducer`, not a separate type to add to keiki. EP-6's plan-level Revision of 2026-05-04 records the correction; the MasterPlan's Decision Log entry of 2026-05-04 ("Reject `Keiki.Decider` as the keiro ⇄ keiki contract") is the upstream cause.

*Provenance.* EP-6 plan Revisions entry of 2026-05-04; MasterPlan Decision Log entry of 2026-05-04.

### 9.4 Codec layer changes at kiroku

*Verdict.* Not a gap. EP-2's codec layer rides entirely on existing kiroku primitives: `EventData.metadata` (carries the `schemaVersion` integer), `EventData.eventType` (carries the stable per-constructor type tag), `EventData.payload` (carries the encoded `Aeson.Value`). No kiroku-side code change is required to support EP-2's codec design.

*Provenance.* EP-2 §12 ("No changes required for the codec layer itself"); MasterPlan Surprises & Discoveries entry of 2026-05-05 (EP-2, "no upstream change to kiroku").

### 9.5 Asymmetry between `Codec e` and `StateCodec t`

*Verdict.* Intentional, not a gap. EP-4's `StateCodec` carries one `stateCodecVersion :: Int` and *no* upcaster chain, where EP-2's `Codec e` carries a per-record version and a consecutive-upcaster chain. The asymmetry follows from snapshots being *advisory* (a stale row falls through to full replay rather than blocking a working command path), so there is no correctness reason to read an old snapshot format. EP-2 and EP-4 reuse the same Aeson primitives and the same record-of-functions ergonomics; the per-customer signatures are not nominal subtypes of each other and are not expected to be.

*Provenance.* MasterPlan Surprises & Discoveries entry of 2026-05-06 (EP-4, "EP-4 deliberately diverges from EP-2's codec design on one structural axis"); EP-4 §12 ("What this plan does *not* inherit").

### 9.6 Server-side scripted projections

*Verdict.* Rejected outright (will not be revisited in v2). `docs/research/05-workflow-prior-art.md` §7 ("Avoid") flags EventStoreDB's JavaScript projections as "operationally fragile and a debugging nightmare." Listed in the EP-5 v2-stretch-features section under "rejected" so the "no, never" decision is explicit.

*Provenance.* `docs/research/10-workflow-roadmap.md` §6 (item #7).


## 10. Open questions for upstream maintainers

The synthesis identifies four questions where the upstream maintainer's input is needed before scheduling. EP-6 forwards them to the relevant maintainers; their answers feed back into the implementation MasterPlan's gating.

### 10.1 keiki: do you want to take ownership of the codec layer in v1.x?

EP-2 keeps codecs at the keiro layer (per the published `docs/research/07-codec-strategy.md` design). §7.8 records this as Optional. The question for keiki: does keiki's roadmap include shipping a codec/upcaster framework that keiro could adopt? If yes, EP-6 schedules the migration in v1.x; if no, the keiro-layer codecs are the stable shape.

### 10.2 keiki: do you want a `compensate` direction on `SymTransducer` or is compensation an application-level concern?

§7.5 frames the question. The argument for is verification (a typed compensate direction supports the SBV/z3 layer); the argument against is composability complexity. EP-6 schedules the gap (Wanted, Block 3) only if keiki's verification roadmap pulls compensation into the typed surface.

### 10.3 shibuya: should the durable-timer worker be hosted on the supervised-worker substrate?

§6.1 frames the question. EP-6 schedules the gap (Wanted, Block 3) only if shibuya's roadmap is generalising the supervisor anyway; otherwise keiro hosts the timer worker as a stand-alone process or a degenerate adapter.

### 10.4 keiki: is the SBV/z3 verification layer (and therefore `phi`) on the v2 roadmap with concrete commitment?

The 2026-05-09 cost-benefit audit recorded in the parent MasterPlan's Surprises & Discoveries surfaced this as the largest unrealised future-bet in keiro v1's contract decision. The keiro contract `EventStream phi rs s ci co` carries the `phi` symbolic predicate parameter and the `BoolAlg phi (RegFile rs, ci)` constraint everywhere — every `runCommand`/`runCommandRetry`/`tick` signature, every `EventStream` instance, every test fixture pays the parameter overhead. The benefit lives entirely in the future v2 SBV/z3 verification layer (per the parent MasterPlan's 2026-05-04 contract Decision Log: *"the symbolic predicate carrier `phi` that the v2 SBV/z3 verification layer will consume"*).

The keiki side has Plan #6 (`keiki/docs/plans/6-sbv-backed-boolalg-instance-for-symbolic-emptiness.md`) suggesting the verification work is real, and `Keiki.Symbolic` already exists in keiki at `src/Keiki/Symbolic.hs` exporting `discoverSym`/`Sym`/etc. So the work is underway. **The question is about commitment, not feasibility.** Specifically:

1. Is the SBV/z3 verification path committed to ship in keiki v2.x with a concrete milestone, or is it exploratory and may slip indefinitely?
2. If it slips: does keiki provide guidance on whether keiro should drop `phi` from the contract (a breaking change for any v1 consumer with `BoolAlg` constraints) or carry the unused parameter forever as inert overhead?
3. Are there interim verification benefits (compile-time edge guards, property-test generation) that could justify `phi` even without z3?

The answer feeds back to the implementation MasterPlan: a "yes, committed" answer leaves the v1 contract as-is and lets `phi` overhead be amortised against future verification value; a "no, exploratory" answer would prompt a contract revision (either dropping `phi` or marking it `Refl`-defaulted) BEFORE v1 ships, since contract changes after v1 are far more expensive than before.

This question does not block v1 implementation — `phi` is plumbed correctly today and v1 works without it active. It blocks **the v1 retrospective**: knowing whether the choice was right means knowing whether the future-bet pays off.

The four questions are mutually independent. Each maintainer can answer in isolation.


## 11. Citation snapshot

This section records the exact paths and line numbers cited in the surveys and design documents at the time of EP-6 synthesis (2026-05-06), so a future reader can compare against the then-current upstream and identify which gaps have been closed.

**kiroku-store (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/`):**

- `src/Kiroku/Store/Effect.hs:160` — `appendMultiStream`'s `TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn` call site.
- `src/Kiroku/Store/Effect.hs:190` — `HardDeleteStream`'s `TxSessions.transaction` call site.
- `src/Kiroku/Store/Effect.hs:48–61` — the `Store` effect's GADT declaration. (No single-stream tx-aware constructor.)
- `sql/schema.sql:2` — `-- Requires PostgreSQL 18+ (for uuidv7())`.
- `sql/schema.sql:25` — `event_id UUID PRIMARY KEY DEFAULT uuidv7()`.
- `sql/schema.sql:74–78` — `subscriptions` table: `subscription_name TEXT NOT NULL UNIQUE`, `last_seen BIGINT NOT NULL DEFAULT 0`.
- `src/Kiroku/Store/Read.hs:27–33` — `readStreamForward :: StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)`.
- `src/Kiroku/Store/Subscription/Stream.hs` — already returns `Streamly.Data.Stream.Stream IO RecordedEvent`.
- `src/Kiroku/Store/Subscription/Types.hs:27–32` — `SubscriptionTarget = AllStreams | Category CategoryName` (no prefix variant).

**shibuya-kiroku-adapter (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter/`):**

- `src/Shibuya/Adapter/Kiroku/Convert.hs:42–47` — comment confirming "checkpoint is managed by the Kiroku subscription worker, not by the handler".
- `src/Shibuya/Adapter/Kiroku/Convert.hs:34` — `import Shibuya.Core.Ack (AckDecision (..))`.

**keiki (`/Users/shinzui/Keikaku/bokuno/keiki/`):**

- `src/Keiki/Core.hs:470–475` — `SymTransducer` data declaration.
- `src/Keiki/Core.hs:610–621` — `delta`/`omega` signatures returning `Maybe`.
- `src/Keiki/Core.hs:657–692` — `applyEvent`/`reconstitute` signatures.
- `src/Keiki/Decider.hs:67–72` — the legacy `Decider` facade (rejected by the MasterPlan as the keiro ⇄ keiki contract).
- `src/Keiki/Composition.hs` — `compose`/`alternative`/`feedback1`.
- `src/Keiki/Generics.hs:132–149` — `mkInCtor` (the existing generic-derivation helper that §7.1's `RegFileToJSON` would extend).

A spot-check on three of the above (`kiroku-store/src/Kiroku/Store/Effect.hs:160,190`, `kiroku-store/sql/schema.sql:2,25,74–78`, `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs:42–47`) was performed during EP-6's synthesis and all citations matched the current source. If a future check reveals a citation has drifted, the divergence should be recorded in EP-6's Surprises & Discoveries section and the citation updated.


## 12. How to verify

A reviewer with access only to this document and the parent MasterPlan should be able to:

1. *Answer "what new features must kiroku-store add for keiro v1 to work?"* — §4.1 (Blocking) plus §5.1 (Blocking-for-exactly-once at the adapter boundary, with kiroku-store implications). Optionally §4.2 through §4.5 (Wanted) for v1.x.

2. *Answer "what new features must keiki add for keiro v1 to work?"* — §7.1 and §7.2 (Wanted, Blocking for EP-4 snapshots) plus §7.3 (Wanted, error-model improvement). Optionally §7.4 through §7.6 for v1.x.

3. *Answer "what is the recommended sequencing?"* — §3's four-block ordering. Block 1 has one item; everything else can run in parallel after Block 1.

4. *Answer "what design constraints does keiro impose on the upstream change?"* — every Blocking and Wanted entry carries an explicit *Design constraint* paragraph.

5. *Answer "which gaps were considered and rejected?"* — §9 records six rejections with rationale and provenance, so a future reader does not re-litigate them.

6. *Spot-check a citation against current upstream source* — §11 lists every cited file:line. Three of the six most-load-bearing citations were spot-checked at synthesis time (recorded in §11's last paragraph); a future reviewer can replicate the check by running the same `grep` and `Read` operations.

If any of the above is not derivable from this document plus the design documents it cross-references, the document is incomplete and must be revised.


## 13. Summary

The keiro research foundation produces six design documents (EP-1 through EP-6) and three working spikes (EP-1, EP-2; EP-3 deferred). The synthesis here consolidates seventeen upstream feature requests across kiroku-store, shibuya-kiroku-adapter, shibuya-core, and keiki, plus three cross-cutting items, plus six explicitly-not-gaps. One item is **Blocking** for keiro v1 implementation: kiroku-store's single-stream `runInTransaction` combinator (§4.1). Six items are **Wanted** in Block 2 (parallel with v1 implementation): kiroku-store Streamly-native single-stream forward read, kiroku-store Postgres 18 docs, shibuya-kiroku-adapter `HandlerInTransaction` shape, keiki register-file `<-> Aeson.Value` helper plus shape hash, and keiki structured error model on `step`/`omega`. Six items are **Wanted** in Block 3 (v1.x quality-of-life). Eight items are **Optional** in Block 4. Three open questions are forwarded to the upstream maintainers for input.

The keiro implementation MasterPlan that follows this research foundation can begin work as soon as §4.1 lands. Every other Block-2 item can land in parallel with the implementation; every Block-3 and Block-4 item retires a workaround the implementation MasterPlan documents. No Blocking item depends on any other Blocking item — the dependency DAG is shallow.

The research foundation's exit criterion is now met: a self-consistent design exists across `docs/research/06-` through `docs/research/11-`, three working spikes plus one design-only deferral document the upstream gaps that prevented the third spike, and this document delivers the prioritised upstream backlog ready to feed an implementation MasterPlan in each upstream project.
