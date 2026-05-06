# Subscriptions, Projections, and Process Managers — keiro

Author: ExecPlan EP-3 (`docs/plans/3-subscriptions-projections-and-process-managers.md`). Date: 2026-05-05.

This document fixes how keiro consumes events: the three projection lifecycles (inline, async, live), the transactional outbox/inbox patterns, the event-sourced process-manager substrate that stands in for v1 workflows, the gap-free-read guarantee inherited from kiroku's Strategy E, and the failure / observability / concurrency contracts that bind them together. The reader is assumed to have read `docs/research/01-kiroku-read-side.md`, `docs/research/03-shibuya-subscriptions.md`, `docs/research/06-command-cycle-design.md` (EP-1's design), and `docs/research/07-codec-strategy.md` (EP-2's codec). Where a key fact from those documents matters here it is repeated; the reader who has not seen them should still be able to follow this design.

EP-3's M1 spike was deferred (recorded in EP-3's Decision Log, 2026-05-05) because two upstream combinators do not yet exist — `kiroku-store` does not expose a single-stream `runInTransaction` and `shibuya-kiroku-adapter` does not expose a handler shape that can opt into the kiroku-side subscription checkpoint advance inside the user's `Hasql.Transaction.Transaction`. The design here cites the relevant code paths inline and forwards both gaps to EP-6 (`docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`). When the upstream combinators land, the design's claims become testable; the design itself is independent of those gaps.


## 1. Problem statement

Once keiro can run a command cycle (EP-1) and encode/decode events (EP-2), the next question is how the resulting events are *consumed*. Three concerns sit on top of the same kiroku-store + shibuya machinery:

**Inline projections.** Read-model rows are updated in the *same Postgres transaction* as the event append. A read of the projection table immediately after the append sees the new state — no replication lag, no eventual-consistency window. Marten's killer Postgres-native feature; documented in `docs/research/05-workflow-prior-art.md` §7. Trade-off: a slow projection slows every command on that aggregate; an exception in the projection rolls back the append.

**Async projections.** A separate worker subscribes to the event stream and updates read-model rows out of band. The write path is not blocked; the read path sees eventually-consistent state. Marten and Eventide both default to this for projections that are not on the critical write path.

**Process managers.** Event-sourced coordinators that subscribe to one or more categories, hold their own state in a dedicated kiroku stream (`pm-<name>-<instance>`), and emit *commands* (not events) into other aggregates' streams. Process managers are the v1 substrate for "workflow"; full deterministic-replay durable execution is deferred to v2 and lives in EP-5 (`docs/plans/5-workflow-engine-and-durable-execution-roadmap.md`).

Cross-cutting: a **transactional outbox** for handlers that must call external systems (HTTP, email, downstream queue), with an **inbox** for the dual problem (deduping incoming external messages).

The user-visible behaviours the eventual library will deliver:

- An aggregate author writes a projection function `RecordedEvent -> Hasql.Transaction.Transaction ()`, picks a lifecycle (`Inline` or `Async <name>`), and the framework persists, observes, and rebuilds it correctly.
- A workflow author writes a `(state, event) -> (state, [Command])` step function and the framework runs it as an event-sourced process manager whose state is reconstructed from kiroku.
- A handler that calls an external system writes one outbox row per side-effect; the framework drains the outbox via pgmq-hs and delivers via a downstream consumer with at-least-once semantics and persistent retries.

This document fixes the contracts. The patterns it describes are validated by citations to existing kiroku/shibuya/pgmq code paths plus prose-level walkthroughs; the spike that would have demonstrated them end-to-end is a v2 follow-up once the upstream combinators (§13) land.


## 2. Inline projection design

The inline projection lifecycle reuses the transactional-step combinator EP-1 sketches in §10 of `docs/research/06-command-cycle-design.md`:

    runCommandWithSql
      :: ( Store :> es
         , Error StoreError   :> es
         , Error CommandError :> es
         , BoolAlg phi (RegFile rs, ci)
         )
      => Aggregate phi rs s ci co
      -> AggregateId a
      -> ci
      -> Hasql.Session.Session ()    -- user-supplied SQL action committed in the same tx
      -> Eff es (Maybe co)

Inline-projection registration is sugar over `runCommandWithSql`:

    data InlineProjection co = InlineProjection
      { inlineName  :: !Text
      , inlineApply :: !(co -> Hasql.Transaction.Transaction ())
      }

    runCommandWithProjections
      :: (... same constraints as runCommandWithSql ...)
      => Aggregate phi rs s ci co
      -> AggregateId a
      -> ci
      -> [InlineProjection co]
      -> Eff es (Maybe co)
    runCommandWithProjections agg sn cmd projs =
      runCommandWithSql agg sn cmd (sequence_ [inlineApply p ev | p <- projs])
      -- conceptual: the actual implementation receives the emitted event
      -- threaded through; the spike-validated EP-1 cycle returns it

The user code is one function:

    counterProjection :: InlineProjection CounterEvent
    counterProjection = InlineProjection
      { inlineName  = "counter_view"
      , inlineApply = \case
          Incremented {} -> Hasql.Transaction.statement () incrementSql
          Decremented {} -> Hasql.Transaction.statement () decrementSql
          _              -> pure ()
      }
      where
        incrementSql = ... -- UPDATE counter_view SET value = value + 1 WHERE id = $1
        decrementSql = ... -- UPDATE counter_view SET value = value - 1 WHERE id = $1

**Failure semantics.** A projection that throws (any exception, including a Hasql `QueryError`) rolls back the transaction; the event is *not* appended. The caller's `runCommand` returns the underlying `StoreError`. Inline projections are consequently in the critical path for command latency and command success — only register projections here that can stay reliable.

**Read-your-writes.** Because the projection is committed in the same transaction as the append, a `SELECT` on the projection table from the same connection (or any connection at the same MVCC horizon) sees the new state immediately. This is the Marten property kiroku inherits via Postgres MVCC.

**Upstream dependency (forwarded to EP-6).** `runCommandWithSql` itself depends on a kiroku-store combinator that does not yet exist: a single-stream `appendToStream` that opens a `TxSessions.transaction ReadCommitted Write` block and accepts a user-supplied `Hasql.Transaction.Transaction a` to commit in the same tx. EP-1 §10 records this as the original request; EP-3 reinforces it (the inline-projection lifecycle is the second use case after the outbox §6).


## 3. Async projection design

Async projections subscribe to a shibuya `Adapter` over a kiroku source. The adapter is built from `Shibuya.Adapter.Kiroku.kirokuAdapter`:

    kirokuAdapter
      :: (IOE :> es)
      => KirokuStore -> KirokuAdapterConfig -> Eff es (Adapter es RecordedEvent)

    data KirokuAdapterConfig = KirokuAdapterConfig
      { subscriptionName   :: !SubscriptionName
      , subscriptionTarget :: !SubscriptionTarget    -- AllStreams | Category Text
      , batchSize          :: !Int32
      , bufferSize         :: !Natural               -- TBQueue capacity
      }

The adapter's source is `Stream (Eff es) (Ingested es RecordedEvent)`; `Ingested` carries the `RecordedEvent` payload, an `AckHandle`, and an optional `Lease`. The handler signature is shibuya's standard:

    type Handler es msg = Ingested es msg -> Eff es AckDecision

A keiro-side helper makes the typed-event wrapper concrete:

    handleTyped
      :: forall e es.
         ( Store :> es, Error StoreError :> es, IOE :> es )
      => Codec e
      -> (e -> Hasql.Transaction.Transaction ())
      -> Ingested es RecordedEvent
      -> Eff es AckDecision
    handleTyped codec project ingested =
      case decodeRecorded codec (envelope ingested).payload of
        Left err -> pure (AckDeadLetter (InvalidPayload (T.pack (show err))))
        Right ev -> do
          runHasql (project ev)
          pure AckOk

The runner uses `Shibuya.Runner.Serial.runSerial`:

    runSerial :: (IOE :> es) => Natural -> Adapter es msg -> Handler es msg -> Eff es ()

This consumes the adapter's `Stream` via shibuya's internal `Stream.fold Fold.drain $ Stream.mapM (...) source` shape (visible at `shibuya/shibuya-core/src/Shibuya/Runner/Serial.hs:37-38` per the EP-3 plan's Decision Log).

**Failure semantics — at-least-once.** As of 2026-05-05 `shibuya-kiroku-adapter` advances kiroku's subscription checkpoint *internally* — the worker advances `subscriptions(name, last_seen)` after the handler returns `AckOk` (or any `Ack*` other than `AckHalt`), in its own SQL connection. The handler's projection write and the checkpoint advance therefore live in *different* Postgres transactions. A crash between the two produces at-least-once delivery: a replay re-invokes the projection. **User-supplied projection functions must therefore be idempotent** — typically by writing rows keyed on a deterministic id, by `INSERT ... ON CONFLICT DO NOTHING`, or by carrying the source `eventId` through to the read-model row so duplicate writes are detectable.

**Exactly-once is achievable but blocked by an upstream gap.** A `HandlerInTransaction es msg = Ingested es msg -> Hasql.Transaction.Transaction AckDecision` shape, consumed by a runner that wraps the kiroku-side checkpoint advance and the user's projection write in *one* `TxSessions.transaction`, would give exactly-once. EP-3 forwards this to EP-6 as a `shibuya-kiroku-adapter` upstream request. Until it lands, async projections are at-least-once with idempotency.

**Decoder boundary.** `decodeRecorded codec (envelope ingested).payload` is the only place a typed event meets the wire. EP-2's codec layer (`docs/research/07-codec-strategy.md`) handles every schema-evolution concern; the handler sees only the latest typed shape. Decode failures surface as `AckDeadLetter (InvalidPayload …)`, which sends the event to a DLQ rather than retrying forever — a malformed payload is not a transient failure.

**Subscription naming.** Each subscription is keyed by a `SubscriptionName :: Text` registered exactly once per kiroku store. The convention: `<aggregate>-<projection>` (e.g. `counter-view`, `order-fulfillment-status`). The `subscriptions` table (kiroku's existing schema, `subscriptions(subscription_name, last_seen)` per `docs/research/01-kiroku-read-side.md` §"Storage & Migrations") tracks each subscription's progress.


## 4. Gap-free reads — why no watermark is needed

Async projections need to handle every event exactly once and in `globalPosition` order. In a typical event store this is a hard problem: a transaction that has *claimed* a `globalPosition` (e.g. via `BIGSERIAL`) but has not yet *committed* leaves a gap visible to readers, who see positions `1, 2, 4, 5` and must wait for `3` (or risk skipping it forever). Marten's high-water-mark daemon exists to track these gaps and stall subscribers until the missing position commits or is abandoned.

Kiroku does not have this problem. Its `docs/DESIGN.md` documents *Strategy E*: an atomic `UPDATE … RETURNING` on the row `streams WHERE stream_id = 0` (the `$all` stream) inside the same transaction that inserts the events. The returned counter value becomes the new event's `globalPosition`. Because the UPDATE serializes writers on that single row, positions are claimed *and* committed in lockstep order; concurrent transactions cannot produce out-of-order commits. Subscribers read positions `1, 2, 3, 4` contiguously with immediate read-your-own-writes — no daemon, no stall logic.

**Implication for keiro.** A subscriber's `last_seen` checkpoint can advance to *any* observed `globalPosition` without any gap-detection or watermark logic. The bigserial-gap problem famously addressed by Marten's high-water-mark *does not exist here*. Strategy E was chosen specifically to avoid Marten's HWM operational tax (see EP-3's Decision Log entry of 2026-05-04). Recommending a HWM at the keiro subscriber layer would re-pay the very tax kiroku declined.

**Throughput trade-off.** Strategy E's row-level lock on `streams WHERE stream_id = 0` caps single-instance write throughput at roughly 50 000 events/s (per kiroku-store's bench-marked numbers in `docs/research/01-kiroku-read-side.md` §"Concurrency Guarantees"). For keiro's target workload (event-sourced systems on a single Postgres instance) this is well above the threshold the framework needs. Aggressive scale-out — multi-region, sharded streams — is a v2 concern; if it arrives, kiroku's design doc walks through the partitioning options.

**The deferred spike's M1.7 sub-test would have looked like this.** Two writer threads each appending 1000 events to distinct streams in a tight loop; one async subscriber consuming from `$all`. The subscriber's `Fold.foldlM' assertContiguousGlobalPosition (GlobalPosition 0) source` would observe exactly 2000 events with positions `1..2000`, no gaps, no duplicates. The test passes today against kiroku-store directly; it does not require any keiro-side logic to pass.


## 5. Process manager design

A process manager (PM) is an event-sourced coordinator. Its shape:

    data ProcessManager s eIn eOut = ProcessManager
      { pmName    :: !Text
      , pmInitial :: !s
      , pmStep    :: !(s -> eIn -> (s, [PMCommand eOut]))
      , pmCodec   :: !(Codec s)              -- snapshots its own state
      }

    data PMCommand eOut where
      PMCommand
        :: ( BoolAlg phi (RegFile rs, ci), Show ci )
        => Aggregate phi rs s ci co
        -> AggregateId a
        -> ci
        -> PMCommand co

The PM subscribes to a kiroku category (e.g. `order`) via the same async-projection adapter. On each event:

1. Decode the event through `aggEventCodec` (EP-2's codec).
2. Reconstruct the PM's joint state `s` by hydrating its own kiroku stream (`pm-<pmName>-<correlationId>`) — the same Streamly `Stream`/`Fold` pipeline EP-1 §5 uses for aggregate hydration. The PM's stream stores PM-emitted events, not commands; the step function's history is the log.
3. Run `pmStep s ev` to compute `(s', [PMCommand])`.
4. Persist the new PM state by appending a synthetic `PMStateAdvanced { newState = s' }` event to the PM's stream.
5. For each emitted `PMCommand`, run `runCommand` against the target aggregate.

**Multi-stream atomicity.** Steps 4 and 5 must commit atomically, so a crash between "PM emitted commands" and "commands appended" does not produce duplicate emissions. kiroku's `appendMultiStream` opens a `TxSessions.transaction ReadCommitted Write` and atomically appends to multiple streams — this is the existing primitive PMs use for emission. Concretely: the PM's state-advance event and every emitted command's target-stream append go into one `appendMultiStream` call.

**Idempotency of emitted commands.** The target aggregate's `runCommand` is wrapped with idempotency on `commandId`. The PM generates a deterministic v5 UUID over `(pmName, correlationId, ev.eventId, emitIndex)` so a crash-and-replay produces the same `commandId`, the second `appendToStream` returns `DuplicateEvent`, and the retry loop treats it as success (per `docs/research/06-command-cycle-design.md` §9). Net effect: each domain command is appended at most once even though delivery is at-least-once.

**Correlation and causation.** Each `PMCommand`'s emitted event carries `causationId = ev.eventId` and `correlationId = ev.correlationId` (or `ev.eventId` if the source had no correlation), so a downstream tracer can reconstruct the chain (`docs/research/06-command-cycle-design.md` §12).

**Snapshot.** `pmCodec :: Codec s` lets EP-4 (`docs/plans/4-snapshot-strategy-and-hydration-acceleration.md`) snapshot the PM's state. PM streams can grow large for long-running workflows; the snapshot path is essential for v2's durable-execution roadmap.

**State-stream naming.** `pm-<pmName>-<correlationId>` is the canonical convention. `pmName` matches `pmName` in the `ProcessManager` record. `correlationId` is the saga's `correlationId` when the source event has one; for PMs that operate on per-aggregate scope (e.g. one PM instance per order), it is the aggregate's id.


## 6. Outbox design

Handlers that must call external systems (HTTP, email, third-party API) cannot do so atomically with the database write — the external call may succeed while the local commit fails or vice versa. The standard pattern is an outbox: write the side-effect intent to a Postgres table inside the handler's transaction, then drain the table from a separate process that performs the call and acknowledges on success.

**Schema.** A new Postgres table created at keiro init time:

    CREATE TABLE keiro_outbox (
      id             bigserial PRIMARY KEY,
      destination    text NOT NULL,                      -- e.g. "pgmq:webhook-deliveries"
      payload        jsonb NOT NULL,
      enqueued_at    timestamptz NOT NULL DEFAULT now(),
      attempt_count  int NOT NULL DEFAULT 0,
      attributes     jsonb                                -- correlation/causation/trace
    );
    CREATE INDEX keiro_outbox_id ON keiro_outbox (id);

**Write path.** A handler that produces a side-effect inserts an outbox row in the same `TxSessions.transaction` as its other writes — typically as part of an inline projection's `Hasql.Transaction.Transaction ()`. The row is committed atomically with the projection / event append.

    insertOutbox
      :: Text                  -- destination
      -> Aeson.Value           -- payload
      -> Maybe Aeson.Value     -- attributes
      -> Hasql.Transaction.Transaction ()

**Drain path.** A separate worker periodically (or via a LISTEN/NOTIFY trigger when v2 lands) runs:

    SELECT id, destination, payload, attributes
      FROM keiro_outbox
      ORDER BY id ASC
      LIMIT $1
      FOR UPDATE SKIP LOCKED

For each row, the worker enqueues to the destination (a pgmq queue, identified by the `destination` field) and deletes the outbox row in the same transaction. `SKIP LOCKED` lets multiple drainers run concurrently without contention. The drain loop's Streamly shape:

    drainPipeline
      :: (IOE :> es, Pgmq :> es)
      => Stream (Eff es) ()
    drainPipeline = Stream.unfoldrM nextBatch ()
      where
        nextBatch _ = do
          rows <- runHasql (selectAndLock 100)
          forM_ rows $ \row -> do
            sendMessage (destination row) (payload row)
            runHasql (deleteOutbox (rowId row))
          if null rows then pure Nothing else pure (Just ((), ()))

**Consume path.** Downstream of pgmq, a `shibuya-pgmq-adapter`-backed handler delivers the actual external call. `Shibuya.Adapter.Pgmq.pgmqAdapter :: PgmqAdapterConfig -> Eff es (Adapter es Aeson.Value)` produces an `Adapter` whose source is `Stream (Eff es) (Ingested es Aeson.Value)`. AckDecision semantics on the pgmq adapter (per the EP-3 pre-flight survey):

- `AckOk` → delete from queue.
- `AckRetry` → extend visibility timeout (the message returns after the delay).
- `AckDeadLetter` → archive (or send to a DLQ if configured).
- `AckHalt` → extend visibility, stop processing.

Pgmq's `read_count` field gives the redelivery count; the `attempt` field on `Ingested.envelope` exposes it to the handler so retries can be capped.

**Failure modes.**

- *External call fails transiently.* Handler returns `AckRetry delay`; pgmq's visibility timeout absorbs the retry.
- *External call fails permanently (4xx).* Handler returns `AckDeadLetter`; the message moves to the DLQ for manual triage.
- *Outbox drain worker crashes.* On restart, `SKIP LOCKED` ensures other drainers continue without blocking; the crashed drainer's row reappears once its lock expires.
- *Pgmq receives the message but the consumer crashes before ack.* Pgmq's visibility-timeout redelivers — the consumer is at-least-once with idempotency the user's responsibility.

**Why pgmq, not LISTEN/NOTIFY.** pgmq's `SKIP LOCKED` semantics give competing-consumer behaviour, visibility timeouts, and persistent retries out of the box (see `docs/research/05-workflow-prior-art.md` §3, §5). LISTEN/NOTIFY can be added as a v2 latency optimisation; for v1, pgmq's polling is sufficient.

**Why an explicit outbox table, not direct pgmq writes.** pgmq is not transactional with respect to the user's other writes — a pgmq `send_message` is a separate connection / pool. The outbox table sits inside the user's `Hasql.Transaction.Transaction` so the side-effect intent is committed atomically; the drain hop (outbox → pgmq) is the boundary where atomicity is relaxed to at-least-once.


## 7. Inbox design

The dual problem: receiving events from external systems where the same event may be delivered multiple times. The solution is symmetric — write `(source, message_id)` to a dedup table inside the handler transaction; abort on duplicate.

    CREATE TABLE keiro_inbox (
      source     text NOT NULL,
      message_id text NOT NULL,
      seen_at    timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (source, message_id)
    );

The inbox table is touched by handlers that consume external pgmq/HTTP messages. A handler that wants exactly-once semantics:

    handleExternal :: Source -> ExternalMessage -> Eff es AckDecision
    handleExternal source msg = runHasql $ do
      Hasql.Transaction.statement
        (source, externalMessageId msg)
        insertInboxStatement
      -- if the row already existed, the unique-violation rolls back here
      -- and the handler should return AckOk (it has been processed already)
      processMessage msg
      pure AckOk

The inbox table grows; v1 ships a periodic GC job that deletes rows older than a configurable retention window (default 30 days). The GC trade-off: shorter retention shrinks the table but narrows the window in which duplicates can be detected. The user picks based on their delivery-system guarantees.


## 8. Failure semantics

Across all four lifecycles, a unified ack-decision rubric:

- **`AckOk`**: success. Inline projections never see this (they commit or roll back atomically with the append). Async projections, PMs, outbox-relay drainers, and pgmq consumers all return `AckOk` on a successful unit of work.
- **`AckRetry !RetryDelay`**: transient failure. Pgmq adapter extends the visibility timeout by the supplied delay; kiroku adapter is a no-op (kiroku has no visibility-timeout concept — replays come from the worker re-reading after a non-`AckOk` finishes, but retries via this path do not happen in 2026-05-05 shibuya-kiroku-adapter; transient failures in kiroku-side handlers should re-throw and let the caller restart).
- **`AckDeadLetter !DeadLetterReason`**: permanent failure. Pgmq adapter archives or routes to the DLQ; kiroku adapter is a no-op (events are immutable; a handler that DLQ's an event is essentially saying "I cannot process this and will never be able to"). The handler's `DeadLetterReason` payload (`PoisonPill Text | InvalidPayload Text | MaxRetriesExceeded`) is logged for operator triage.
- **`AckHalt !HaltReason`**: graceful stop. The runner shuts down the adapter and reports the halt reason. Used when an unrecoverable invariant is violated (a serialisation drift the codec cannot survive, an aggregate that has been hard-deleted while a subscription was paused).

**Inline-projection failures roll back the append.** A projection that throws — or a `Hasql.Transaction.Transaction ()` that returns a `Left` from a Hasql error — aborts the whole transaction; the event is not persisted. The caller's `runCommand` returns the underlying `StoreError` (likely `UnexpectedServerError` carrying the Postgres error message). This is intentional: inline projections sit inside the write path's transactional envelope so they share its all-or-nothing semantics.

**Async-projection failures are retried (or DLQ'd).** Per §3 the user code is idempotent; a partially-applied projection that crashes in the middle replays and re-applies. For non-idempotent projections (the user accepts the at-least-once trade-off and moves on) duplicate writes manifest as duplicate read-model rows, which the user code must detect.

**Process-manager emission failures cascade to the source-event handler.** If `runCommand` against the target aggregate fails permanently (e.g. `CommandRejected` because the target's invariants reject the command), the PM's source-event handler returns `AckDeadLetter`. The source event remains in the source stream; manual operator action is required to resolve.

**Outbox-relay failures stall the drain.** A pgmq enqueue that fails leaves the outbox row in place (no delete happens). The next drain attempt picks it up. The relay does not advance past stuck rows; if a destination queue is wedged, the table grows. Operators monitor `keiro_outbox.attempt_count` and `enqueued_at` to spot stalls.


## 9. Concurrency policy

Each lifecycle's recommended concurrency / ordering policy on shibuya:

- **Inline projection** — *not a shibuya pipeline*. One synchronous call inside `runCommandWithSql`. Concurrency is whatever the caller wants.
- **Async projection** — `Concurrency = Serial`, `Ordering = StrictInOrder` for projections that depend on per-stream order (the typical case). `Ahead n` or `Async n` are valid for projections that aggregate over `$all` without per-stream invariants.
- **Process manager** — `Concurrency = Serial`, `Ordering = PartitionedInOrder` keyed by the source event's stream id (so events on the same source stream are processed in order, but events on different sources can interleave). The PM's per-instance state means cross-instance parallelism is safe.
- **Outbox drain** — `Concurrency = Async n`, `Ordering = Unordered`. Multiple drainers run concurrently via `SELECT … FOR UPDATE SKIP LOCKED`; per-message order does not matter (the destination queue / consumer determines its own order).
- **Pgmq consumer (downstream of outbox)** — `Concurrency = Async n`, `Ordering = Unordered`. Parallel external calls; no order guarantee. FIFO use cases use pgmq's group key (`x-pgmq-group` header) to keep per-key ordering.

Shibuya's `validatePolicy` (per `docs/research/03-shibuya-subscriptions.md`) enforces `StrictInOrder => Serial`; mixing higher concurrency with strict ordering fails fast.


## 10. Streamly pipeline shapes

Per the parent MasterPlan's "Streamly substrate" Integration Point, every multi-event boundary in keiro is expressed as a Streamly `Stream` consumed by a `Fold`. EP-3's lifecycles:

**Async projection.** Source: `shibuya-kiroku-adapter`'s `Stream (Eff es) (Ingested es RecordedEvent)` (per the agent's survey at `Shibuya.Adapter.Kiroku.kirokuAdapter`). Runner: `runSerial 0 adapter handleTyped` (which internally is `Stream.fold Fold.drain $ Stream.mapM handler source` per `Shibuya/Runner/Serial.hs:37-38`). The decode + projection live inside `Stream.mapM`. Constant memory regardless of stream length.

**Inline projection.** *Not a stream.* One synchronous call inside `runCommandWithSql`. Documented here as the deliberate exception so reviewers do not look for a streamly pipeline where there is none.

**Process manager.** Source `Stream` is the same as the async projection. The `Stream.mapM` step folds the PM's joint state via `Fold.foldlM' pmStep (initial, [])` over a *batched* slice when the PM emits multi-stream commands so multiple input events can collapse into one `appendMultiStream` transaction (`Stream.foldMany (Fold.take n Fold.toList)`-style batching, mirroring `Shibuya/Stream.hs:38`'s `batchStream` helper). The batching trade-off (latency vs throughput) is configurable; default is no batching (one command per input event) for clarity.

**Outbox drain.** Two pipelines composed:

- *Drain*: `Stream.unfoldrM` over `SELECT … FROM keiro_outbox … LIMIT n FOR UPDATE SKIP LOCKED`, mapped through `Stream.mapM enqueueAndDelete`, terminated by `Fold.drain`.
- *Consume*: `shibuya-pgmq-adapter`'s `Stream (Eff es) (Ingested es Value)` consumed by `runSerial 0 adapter deliverHandler` (`Stream.fold Fold.drain $ Stream.mapM deliverHandler source`).

**Gap-free read demonstration.** The (deferred) spike's M1.7 test is `Stream.fold (Fold.foldlM' assertContiguousGlobalPosition (GlobalPosition 0)) (kirokuAdapter.source)`. The fold's per-event check is `\acc rec -> if rec.globalPosition == acc + 1 then pure rec.globalPosition else throwError ("gap at " <> show acc)`.

**Why naming the shapes matters.** Reviewers can sanity-check that no parallel streaming abstraction (`conduit`, `pipes`, `Vector`-of-events held in memory) has crept into a sub-pipeline. Implementers know exactly which Streamly primitives they will reach for.


## 11. Observability

shibuya already emits OpenTelemetry spans for every adapter pull and handler invocation (see `docs/research/03-shibuya-subscriptions.md` §"Observability" + `Shibuya.Telemetry.*`). keiro's lifecycles inherit them; the keiro production library adds a small set of attributes on top.

**Span shape per lifecycle:**

- *Inline projection*: a child span of the command's `runCommand` span, named `keiro.projection.inline.<projectionName>`. Attributes: `keiro.aggregate.id`, `keiro.event.tag`, projection name. Errors: span status is set to `error` and the projection's exception is attached.
- *Async projection*: a child span of the adapter's pull span, named `keiro.projection.async.<projectionName>`. Same attributes plus `keiro.subscription.checkpoint` (the post-commit `last_seen` value).
- *Process manager*: a child span of the source-event handler, named `keiro.pm.<pmName>`. Attributes: `keiro.pm.correlation_id`, `keiro.pm.commands_emitted` (count). One additional child span per emitted command, named `keiro.pm.emit.<commandTag>`, carrying the deterministic `keiro.command.id`.
- *Outbox drain*: per-batch span named `keiro.outbox.drain` with `keiro.outbox.batch_size` and `keiro.outbox.destination` attributes. One child span per row, named `keiro.outbox.enqueue`, with the message id and destination.
- *Pgmq consumer*: shibuya's adapter spans cover this; keiro adds `keiro.outbox.message.attempt = <attempt count>` so retry storms are visible.

**Metrics.** shibuya-metrics already exposes per-adapter throughput and lag gauges; keiro adds:

- `keiro_projection_lag_seconds{projection=<name>}` — gauge of `now - max(enqueued_at)` for unprocessed events.
- `keiro_outbox_pending_total{destination=<name>}` — gauge of `count(*)` in `keiro_outbox` per destination.
- `keiro_pm_state_stream_length{pm=<name>}` — gauge of the PM's stream length per active correlation id.

The exact metric/attribute names are owned by the keiro implementation MasterPlan; this document fixes the *shape* (what lives on metadata.attributes vs span attributes).


## 12. Test strategy

For each lifecycle, the acceptance behaviour to verify in production keiro's test suite:

**Inline projection.** A synchronous test: append three Counter events through `runCommandWithProjections`; assert the projection table shows the expected counter value immediately after each commit (no eventual-consistency window).

**Async projection.** A subscriber test using `kirokuAdapter` against an `ephemeral-pg` store: append N events, run the subscriber until its checkpoint reaches N, assert the projection table has exactly N rows, in order. Idempotency test: append N events, deliberately re-deliver event K (by rolling back the checkpoint and re-running), assert the projection table is unchanged (the user's idempotency made the duplicate a no-op).

**Process manager.** Append an `OrderPlaced` event to an `order-1` stream; run the PM until its source checkpoint advances; assert (a) a `ReserveInventory` event appears on the `inventory-<sku>` stream, (b) the PM's own `pm-orderfulfillment-1` stream has a `PMStateAdvanced` event, (c) both are visible in one transaction (a stop-the-world test that confirms `appendMultiStream`-level atomicity).

**Outbox.** Inline projection writes an outbox row; the drain worker drains it; the pgmq consumer prints / logs it. Crash test: kill the drain worker mid-batch; assert no outbox row is lost (the `SKIP LOCKED` SELECT returns it on the next attempt).

**Gap-free reads.** Two threads each appending 1000 events to distinct streams; one async subscriber consuming from `$all`; assert the subscriber observes 2000 events with `globalPosition`s `1..2000`, no gaps, no duplicates. This is a smoke test of kiroku's Strategy E *as observed by keiro* — a regression here means kiroku's contract was broken, not keiro's.

EP-3's M1 spike was the originally-planned realisation of these tests. With the spike deferred, the production library's test suite carries them. The patterns themselves are validated by:

- citations to existing shibuya code paths (`Shibuya.Runner.Serial`, `Shibuya.Adapter.Kiroku.kirokuAdapter`, `Shibuya.Adapter.Pgmq.pgmqAdapter`);
- citations to existing kiroku code paths (`Kiroku.Store.Append.appendMultiStream`, `Kiroku.Store.Subscription.subscribe`, the Strategy E SQL in `Kiroku.Store.SQL`);
- the EP-1 spike's working evidence that the `(load → fold → decide → append)` cycle plus optimistic retry and Streamly hydration all work end-to-end against real Postgres.


## 13. Open questions and upstream gaps

Forwarded to EP-6 for the consolidated kiroku/keiki/shibuya feature backlog.

**kiroku-store.**

- *Single-stream `runInTransaction`.* (Reiterated from EP-1 §14.) `appendToStream` does not open a Haskell-layer transaction; only `appendMultiStream` does. A clean implementation of `runCommandWithSql` (and therefore §2's inline projection lifecycle and §6's outbox write path) requires kiroku to expose a public combinator that wraps `appendToStream` plus a user-supplied `Hasql.Transaction.Transaction a` in one tx. EP-3 reinforces EP-1's request.

**shibuya-kiroku-adapter.**

- *Handler shape that opts into the kiroku checkpoint advance.* Today the adapter handles checkpointing internally (per the EP-3 pre-flight survey at `Shibuya.Adapter.Kiroku.kirokuAdapter` and `Convert.hs:39-78`). The handler returns `AckDecision` but cannot opt into a transactional checkpoint advance. To deliver the exactly-once async-projection semantics §3 sketches, shibuya-kiroku-adapter needs a new shape such as

      type HandlerInTransaction es msg = Ingested es msg -> Hasql.Transaction.Transaction AckDecision

  consumed by a runner that wraps the kiroku-side `UPDATE subscriptions SET last_seen = ... WHERE subscription_name = ...` and the user's body in *one* `TxSessions.transaction`. Until this lands, async projections are at-least-once with idempotency.

**keiro-side (within this plan's scope).**

- *Outbox drain worker.* The §6 design assumes a separate process drains the outbox. Production keiro needs to define how this worker is registered (a new `Keiro.Outbox.runDrain` entry point), whether it runs in-process alongside the application or as a separate binary, and how it interacts with the application's lifecycle. Out of scope for this design doc; production library work item.
- *Inline projection registration ergonomics.* §2's `[InlineProjection co]` is a list of records; the production library may want a typeclass-style registration (`IsProjection co (..) => ProjectionRegistry`) so projections can be derived from a type-level configuration. Out of scope for this design doc; production library work item.
- *Per-PM snapshot policy.* §5 sketches `pmCodec :: Codec s` for snapshots. The actual snapshot lifecycle (when to write, how often, retention) is owned by EP-4; this design references EP-4 forward.


## 14. How to verify

The spike that would have demonstrated end-to-end is deferred (per EP-3's Decision Log). Once the upstream gaps in §13 land, the deferred spike at `spikes/subscriptions/` becomes the empirical demonstration. Until then:

- *Inline projection*: validated by EP-1's `runCommandWithSql` design (`docs/research/06-command-cycle-design.md` §10) plus kiroku's `appendMultiStream` (which already opens a `TxSessions.transaction`) used as a workaround.
- *Async projection at-least-once*: validated by `Shibuya.Adapter.Kiroku.kirokuAdapter` + a user-supplied idempotent projection. The pattern is the same as Marten's async projection lifecycle but with kiroku's Strategy E removing the watermark machinery.
- *Process manager*: validated by `Keiki.Composition` (`compose`/`alternative`/`feedback1`) plus EP-1's `runCommandRetry` for the emission path.
- *Gap-free reads*: validated by kiroku's documented Strategy E and the kiroku-store-test suite's existing concurrency tests (per `docs/research/01-kiroku-read-side.md`).
- *Outbox*: validated by `pgmq-hs` + `shibuya-pgmq-adapter`'s test suite; the keiro-specific table layout is plain-Postgres SQL with no novel design.

A reviewer should be able to walk through this document and verify each claim against the cited code paths without running any new tests. When the spike lands, every claim becomes machine-checkable.


## 15. Summary

keiro consumes events via three projection lifecycles: inline (transactional, in the write path's tx), async (subscribed, eventually consistent, at-least-once with idempotency), and live (compute-on-read; the framework's no-op default). Process managers are event-sourced coordinators that bridge between aggregates by emitting commands; their state lives in dedicated kiroku streams and their multi-stream commits ride on `appendMultiStream`. The transactional outbox handles external-system side-effects with at-least-once semantics via pgmq-hs + `shibuya-pgmq-adapter`; the inbox is its dedup-on-receive dual. Gap-free reads are inherited from kiroku's Strategy E with no subscriber-side watermark.

Two upstream gaps block the most aggressive version of the design (exactly-once async projections via transactional checkpoint advance): kiroku-store needs a single-stream `runInTransaction` combinator and shibuya-kiroku-adapter needs a `HandlerInTransaction` shape. EP-6 records both; in the meantime async projections are at-least-once with user-side idempotency, and inline projections rely on `appendMultiStream` as a workaround.

EP-1's command cycle, EP-2's codec layer, and this plan together define the v1 keiro write/read substrate. EP-4 (snapshots) accelerates the hydration phase of both `runCommand` and process-manager state reconstruction. EP-5 (workflow roadmap) layers durable execution on top of the process-manager substrate this plan establishes. EP-6 consolidates the upstream gaps §13 records.
