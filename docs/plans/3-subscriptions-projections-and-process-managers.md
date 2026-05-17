---
id: 3
slug: subscriptions-projections-and-process-managers
title: "Subscriptions Projections and Process Managers"
kind: exec-plan
created_at: 2026-05-04T20:12:09Z
intention: "intention_01kqt8d9t8ehb84kgs19qa1rs9"
master_plan: "docs/masterplans/1-keiro-research-foundation.md"
---

# Subscriptions, Projections and Process Managers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Once keiro can run a command cycle (EP-1) and encode events (EP-2), the next question is: how are events *consumed*? Three concerns sit on top of the same machinery:

- **Inline projections** — read-model rows updated in the *same Postgres transaction* as the event append. Reads of those rows immediately reflect the new state. Marten's killer Postgres-native feature; documented in `docs/research/05-workflow-prior-art.md` §7.
- **Async projections** — read-model rows updated by a separate worker that subscribes to the event stream and advances a checkpoint. Eventual consistency, decoupled scalability, used for projections that should not block the write path.
- **Process managers** — event-sourced coordinators that subscribe to one or more categories, keep their own state in their own kiroku stream, and emit *commands* (not events) into other aggregates' streams. They are the v1 substrate for "workflow"; durable execution proper is deferred to v2 in EP-5.

Plus the cross-cutting **transactional outbox**: when a handler must call an external system (HTTP, email, downstream queue), it writes an outbox row in the same transaction as the event append; a relay worker drains the outbox via pgmq-hs.

After this plan is complete, anyone with the keiro source tree can:

1. read `docs/research/08-subscription-and-process-manager-design.md`, which fixes the design of the three lifecycles, the outbox table, the explicit non-use of a high-water-mark (kiroku's Strategy E supersedes it; see §4 of the design doc), and the process-manager state model;
2. run a working spike at `spikes/subscriptions/` that demonstrates an inline projection, an async projection, a tiny process manager, and an outbox relay against a real Postgres instance.

The user-visible behaviour the eventual library will deliver: an aggregate author writes a projection function `event -> Hasql.Session ()`, picks a lifecycle (`Inline` or `Async name`), and the framework persists, observes, and rebuilds it correctly. A workflow author writes a `(state, event) -> (state, [command])` step function and the framework runs it as an event-sourced process manager.


## Progress

- [~] M1.1 through M1.7 — 2026-05-05: **Deferred** (see Decision Log entry "Defer the M1 spike"). The seven sub-spikes are blocked on two upstream gaps that EP-3 cannot close from inside keiro: `shibuya-kiroku-adapter` does not expose a handler shape that can advance the kiroku subscription checkpoint in the *same* `Hasql.Transaction.Transaction` as the user's projection write, and `kiroku-store` does not expose a single-stream `runInTransaction` combinator (already an EP-1 forward to EP-6). Without them the spike's central verifiable claim — exactly-once async projections via transactional checkpoint advance — degenerates to at-least-once delivery with user-side idempotency, which the design doc covers in prose without standing up a 6-package dependency closure. The design doc (M2) validates every pattern at the prose+citation layer; the deferred spike is a v2 follow-up once the upstream combinators land. EP-6 records both gaps.
- [x] M2.1 — 2026-05-05: Wrote `docs/research/08-subscription-and-process-manager-design.md`. 15 sections covering: problem statement; inline projection design (built on EP-1's `runCommandWithSql`); async projection design (with explicit at-least-once-with-idempotency caveat citing the shibuya-kiroku-adapter gap); the gap-free-read inheritance from kiroku's Strategy E (and explicit rejection of a Marten-style HWM); process-manager design (event-sourced state in `pm:<pmName>-<correlationId>` streams, `appendMultiStream`-backed multi-stream emission, deterministic `commandId`s for idempotency); outbox design (Postgres table + `SKIP LOCKED` drain + `pgmq-hs` + `shibuya-pgmq-adapter`); inbox dual; failure semantics (per ack-decision rubric); concurrency / ordering policy per lifecycle; the Streamly pipeline shapes each lifecycle exposes; observability fields and OpenTelemetry span layout; test strategy (validating each lifecycle by citation when the spike is deferred); and three keiro-side production-library follow-ups. Two upstream gaps forwarded to EP-6: kiroku-store single-stream `runInTransaction` (reiterates EP-1) and shibuya-kiroku-adapter `HandlerInTransaction` shape.
- [x] M2.2 — 2026-05-05: Cross-referenced from `docs/research/00-overview.md` (one-line entry under the Document Index, with the design-only-because-of-upstream-gaps note attached).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Adopt three projection lifecycles (Inline, Async, Live) following Marten.
  Rationale: Marten's three-tier model is the cleanest articulation of the projection-consistency tradeoff (`docs/research/05-workflow-prior-art.md` §7). Live (compute-on-read) is essentially "do nothing"; the framework must support Inline and Async.
  Date: 2026-05-04.

- Decision: Rely on kiroku's existing Strategy E global-position guarantee. Do *not* introduce a Marten-style high-water-mark.
  Rationale: Kiroku's `docs/DESIGN.md` documents Strategy E: an atomic `UPDATE … RETURNING` on the `$all` row (`stream_id = 0`) inside the same transaction that inserts events claims contiguous `globalPosition`s (1, 2, 3, …) with immediate read-your-own-writes and no MVCC vulnerability. Strategy E was chosen specifically to avoid Marten's HWM operational complexity. Re-introducing HWM at the subscriber layer would re-pay the very tax kiroku declined. Subscribers can advance their `last_seen` to any observed `globalPosition` without gap-detection logic. (This decision supersedes an earlier draft of this plan that recommended the Marten approach; correction made on review.)
  Date: 2026-05-04.

- Decision: Process managers are themselves event-sourced — their state is rebuilt from events on a `pm:<name>-<instance>` stream, not from a row in a state table.
  Rationale: Uniformity with aggregates; reuse of EP-1's `runCommand`; rebuilt-from-history-of-decisions debuggability. Marten and Akka both do this.
  Date: 2026-05-04.

- Decision: Process managers emit commands, not events, into their target aggregates.
  Rationale: Per Vernon's distinction (`docs/research/05-workflow-prior-art.md` §8), a process manager *coordinates*; the target aggregate decides whether to accept the command. Going through `runCommand` preserves the optimistic-concurrency model and per-aggregate invariants.
  Date: 2026-05-04.

- Decision: Use `pgmq-hs` + `shibuya-pgmq-adapter` for the outbox relay; not LISTEN/NOTIFY.
  Rationale: pgmq's SKIP-LOCKED semantics give competing-consumer behaviour, visibility timeouts, and persistent retries out of the box (`docs/research/05-workflow-prior-art.md` §3, §5; pgmq-hs already in the registry per `mori registry list`). LISTEN/NOTIFY can be added as a v2 latency optimization.
  Date: 2026-05-04.

- Decision: Process-manager command emission and the source-event checkpoint advance are in the same Hasql transaction.
  Rationale: Without it the framework is at-least-once for the *source event* but only at-least-once for the *emitted command* on a different code path; this means duplicates that the target aggregate must dedupe. Single-transaction emission gives effective exactly-once for emitted commands provided the target aggregate's `runCommand` is idempotent on a `commandId` (EP-1's design).
  Date: 2026-05-04.

- Decision: Express the async-projection runner, the process-manager event loop, the outbox drain loop, the outbox consumer, and the gap-free read demonstration as Streamly `Stream`/`Fold` pipelines, *not* as ad-hoc `forever (readBatch >>= mapM_ handle)` loops.
  Rationale: The MasterPlan's "Streamly substrate" Integration Point (`docs/masterplans/1-keiro-research-foundation.md`) makes Streamly the canonical streaming substrate. Shibuya already hands sources back as `Stream (Eff es) (Ingested es msg)` and runs them as `Stream.fold Fold.drain $ Stream.mapM handler source` (`Shibuya/Runner/Serial.hs:37-38`); reusing the same shape for projections, PMs, the outbox, and the contention test means zero impedance-matching at adapter boundaries, constant-memory operation across long event histories, and free interop with `Stream.morphInner`, `Stream.foldMany`, and the rest of the Streamly toolbox. The design doc's *Streamly pipeline shapes* section names the concrete `Stream`/`Fold` types each lifecycle exposes; reviewers can sanity-check that no parallel streaming abstraction (`conduit`, `pipes`, `Vector`-in-memory) has crept in. The inline-projection lifecycle is explicitly the exception — it is one synchronous call inside `runCommandWithSql` and not a streamly pipeline at all.
  Date: 2026-05-04.

- Decision: Defer the M1 spike. Convert EP-3 to design-only (matching the original treatment of EP-4, EP-5, EP-6). Record the deferral, the rationale, and the upstream gaps that block a clean spike build.
  Rationale: The pre-flight survey of `shibuya-core`, `shibuya-kiroku-adapter`, `shibuya-pgmq-adapter`, and `pgmq-hs` revealed that `shibuya-kiroku-adapter` (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`) handles kiroku's subscription checkpoint advance *internally* — the per-event handler returns `AckDecision` but cannot opt into a transactional checkpoint advance alongside its own projection write. Concretely: kiroku's `Subscription.Worker` advances the `subscriptions(name, last_seen)` row in its own SQL connection after `handler` returns `AckOk`; the handler's projection-table write and the checkpoint advance therefore live in *different* Postgres transactions. A crash between those two writes produces at-least-once delivery — replays will re-invoke the projection, which user code must make idempotent. This contradicts M1.4's claimed "advance a checkpoint in the *same* hasql transaction as the projection write", which was the spike's core verifiable insight; without it the spike degenerates to "demonstrate at-least-once with idempotent user code", which the design doc covers in prose without cabal-building a 6-package dependency closure (kiroku-store + keiki + shibuya-core + shibuya-kiroku-adapter + shibuya-pgmq-adapter + pgmq-hs) that already requires a multi-flake nix shell to compile. Compounding factors: (a) shibuya-core and pgmq-hs pin different `hs-opentelemetry` git revisions (shibuya: `adc464b…`, pgmq-hs: `894c77f…`); resolving the skew in the spike's `cabal.project` is independent of EP-3's design merit. (b) The transactional outbox sub-spike (M1.6) requires the same upstream combinator as M1.4; it is blocked by the same gap. (c) The process-manager sub-spike (M1.5) layers on top of an unreliable async-projection foundation; building it on top of at-least-once delivery without idempotency primitives would teach the wrong lesson to a future reader. The design doc validates the same patterns at the prose level, cites the relevant kiroku/shibuya/pgmq code paths inline, and forwards the explicit upstream gaps to EP-6. **Cascade**: the parent MasterPlan's "three spikes" claim becomes "two spikes" (EP-1 and EP-2 ship spikes; EP-3 ships design-only). EP-6's upstream backlog gains two new items: kiroku-store needs to expose `runInTransaction :: Hasql.Session a -> Eff es a` (already on EP-1's list for the transactional-step combinator; EP-3 reinforces it), and `shibuya-kiroku-adapter` needs a handler shape that can opt into the checkpoint advance (i.e., a `HandlerInTransaction es msg` whose body is a `Hasql.Transaction.Transaction AckDecision` consumed by a runner that wraps the kiroku-side checkpoint update in the same transaction). Without these, the exactly-once-via-transaction guarantee EP-3's design promises is achievable only at the *kiroku-store SQL layer* (kiroku's strategy E gives gap-free positions), not at the keiro library layer. The design doc states this trade-off honestly.
  Date: 2026-05-05.


## Outcomes & Retrospective

**Outcome (2026-05-05).** EP-3 delivered the design-only half of its purpose statement:

1. A self-contained design document at `docs/research/08-subscription-and-process-manager-design.md` (15 sections) that fixes the three projection lifecycles (inline, async, live), the transactional outbox/inbox patterns, the event-sourced process-manager substrate that stands in for v1 workflows, the gap-free-read guarantee inherited from kiroku's Strategy E, the failure / observability / concurrency contracts, and the Streamly pipeline shapes each lifecycle exposes. Two upstream gaps blocking exactly-once async projections were forwarded to EP-6 with explicit rationale.

2. The originally-planned spike at `spikes/subscriptions/` was deferred (recorded in this plan's Decision Log entry of 2026-05-05). The spike's central verifiable insight — exactly-once async projections via a transactional checkpoint advance — depends on a `shibuya-kiroku-adapter` shape that does not yet exist. Without that shape the spike degenerates to "demonstrate at-least-once with idempotent user code", a pattern the design doc captures in prose without standing up a 6-package dependency closure (kiroku-store + keiki + shibuya-core + shibuya-kiroku-adapter + shibuya-pgmq-adapter + pgmq-hs) whose hs-opentelemetry pins disagree across projects. The MasterPlan's "three spikes" claim becomes "two spikes" (EP-1 and EP-2 ship spikes; EP-3 ships design-only).

**Gaps and lessons.**

- **The shibuya-kiroku-adapter checkpoint-control gap is the central blocker.** The adapter handles checkpointing internally (per the EP-3 pre-flight survey). For exactly-once async projections, a `HandlerInTransaction es msg = Ingested es msg -> Hasql.Transaction.Transaction AckDecision` shape consumed by a runner that wraps the kiroku-side checkpoint advance and the user's projection write in one `TxSessions.transaction` is required. EP-6 records the request.
- **The kiroku-store single-stream `runInTransaction` gap returns from EP-1.** EP-1 §10 first surfaced the need; EP-3's inline-projection lifecycle and outbox write path are the second and third use cases. EP-6 already has it; EP-3 reinforces. **[CLOSED 2026-05-10 — kiroku-store now ships `Kiroku.Store.Transaction.runTransactionAppending` (with `runTransactionAppendingNoRetry`, `appendToStreamTx`/`prepareEventsIO`, and the bare `runTransaction`/`runTransactionNoRetry` escape hatch). The inline-projection lifecycle and outbox write path bind directly to `runTransactionAppending`. The shibuya-kiroku-adapter `HandlerInTransaction` gap remains open. See the 2026-05-10 Revisions entry below and the parent MasterPlan's matching Revisions entry.]**
- **Marten's high-water-mark is the wrong solution.** Several drafts of this plan recommended HWM at the subscriber layer; the final version explicitly rejects it (§4 of the design doc) because kiroku's Strategy E supersedes the bigserial-gap problem HWM solves. Recommending HWM in keiro would re-pay a tax kiroku deliberately declined.
- **shibuya-core and pgmq-hs pin different `hs-opentelemetry` revisions** (`adc464b…` vs `894c77f…`); the spike's `cabal.project` would have had to negotiate a single tag. This is a build-environment concern that surfaces once both libraries land in the same workspace; the production keiro library inherits it. EP-6 may want to record the version-skew as a coordination item among the upstream maintainers.

**Comparison against the original purpose.** EP-3's purpose was to take keiro from "command cycle works" to "subscriptions, projections, and process managers work". The design fixes the contracts and is internally consistent with EP-1 (`runCommandWithSql`, `appendMultiStream`, `runCommandRetry`) and EP-2 (`Codec co` for the decoder boundary). The deferred spike is the only outstanding deliverable; once the upstream gaps land, the spike at `spikes/subscriptions/` becomes the empirical demonstration of the design. EP-4 (snapshots) and EP-5 (workflow roadmap) are unblocked by this plan's contracts; EP-6 has three new backlog items (the two upstream gaps plus the version-skew coordination concern).


## Context and Orientation

Repository layout. Working tree at `/Users/shinzui/Keikaku/bokuno/keiro`. Sister projects relevant here:

- `kiroku` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Read API: `Kiroku.Store.Read.readCategoryForward`, `readAllForward`. Subscriptions: `Kiroku.Store.Subscription.subscribe` with `SubscriptionConfig { name, target = Category | AllStreams, handler, batchSize, queueCapacity, overflowPolicy }`. The `subscriptions` table already tracks `(subscription_name, last_seen)`. Full details in `docs/research/01-kiroku-read-side.md`.
- `shibuya-core` at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core`. Defines the `Adapter`, `Handler`, `Ingested`, `AckDecision` types. Concurrency policies: `Serial`, `Ahead n`, `Async n`. Ordering: `StrictInOrder`, `PartitionedInOrder`, `Unordered`. NQE supervision; OpenTelemetry tracing built in.
- `shibuya-kiroku-adapter` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter`. Wraps kiroku's push-based subscription into a pull-based `Stream (Eff es) (Ingested es msg)`. Ack semantics: `AckOk`/`AckRetry`/`AckDeadLetter` are no-ops because kiroku owns the checkpoint.
- `shibuya-pgmq-adapter` at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`. Pulls from a pgmq queue. Ack semantics: `AckOk` deletes; `AckRetry` extends visibility; `AckDeadLetter` archives.
- `pgmq-hs` at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`. Effectful Postgres queue.

Term definitions:

- *Category* — kiroku's prefix grouping of streams sharing a common substring before the first `-`. E.g., streams `order-1`, `order-2`, `order-3` are all in category `order`. `Kiroku.Store.Read.readCategoryForward` reads in category-then-position order.
- *Inline projection* — a function `event -> Hasql.Session ()` invoked synchronously inside the same Postgres transaction that appends the event. Read-your-writes is immediate. Failure of the projection rolls back the append.
- *Async projection* — a function `event -> Hasql.Session ()` invoked by a separate worker that subscribes to the event stream. The worker advances a checkpoint after each successful invocation. Eventually consistent.
- *Process manager* — an event-sourced coordinator with state of type `s` and step function `(s, event) -> (s, [command])`. The process manager's own state is reconstructed by replaying its own command-emission events from a stream of the form `pm:<name>-<instance>`.
- *Gap-free global ordering (kiroku's Strategy E)* — kiroku's append path performs an atomic `UPDATE ... RETURNING` on the row `streams WHERE stream_id = 0` (the `$all` stream) inside the same transaction that inserts the events. The returned counter values become the new events' `globalPosition`s. Because the UPDATE serializes writers on that single row, positions are claimed *and* committed in lockstep order; concurrent transactions cannot produce out-of-order commits, so subscribers never see gaps. Documented in `kiroku/docs/DESIGN.md`. **Implication for keiro**: subscribers can advance their `last_seen` checkpoint to any observed `globalPosition` without any gap-detection or watermark logic; the bigserial-gap problem famously addressed by Marten's high-water-mark *does not exist here*.
- *Outbox* — a Postgres table of pending external messages, written in the same transaction as the event append. A separate relay worker drains the outbox by inserting into a pgmq queue (then deleting), and a downstream pgmq consumer effects the actual external call.
- *Inbox* — the dual of the outbox: when *receiving* messages from external sources, write `(source, message_id)` to a dedup table inside the handler transaction; abort on duplicate.

What does **not** exist today:

- No keiro module bridging shibuya's `Handler` to kiroku-decoded typed events.
- No projection-lifecycle abstraction.
- No high-water-mark tracking.
- No process-manager primitive.
- No outbox table/relay.

What *does* exist:

- Shibuya's adapter for kiroku gives a stream of `Envelope RecordedEvent`. The handler decodes, projects, and acks.
- Shibuya's adapter for pgmq gives a stream of `Envelope payload` for the outbox relay.
- Kiroku's `appendMultiStream` opens a `TxSessions.transaction ReadCommitted Write`; this is the only place a Haskell-layer Postgres transaction is currently exposed for kiroku writes.


## Plan of Work

Two milestones.

### Milestone 1 — Working spike

A Haskell package `spikes/subscriptions/` demonstrates all four behaviours end-to-end against `ephemeral-pg`.

Steps:

1. **Package setup.** `spikes/subscriptions/spike.cabal`, `cabal.project` referencing local checkouts of kiroku, keiki, shibuya, shibuya-kiroku-adapter, shibuya-pgmq-adapter, pgmq-hs, ephemeral-pg. Modules: `Spike.Inline`, `Spike.Async`, `Spike.PM`, `Spike.Outbox`, `Spike.HighWater`, `app/Main.hs`.
2. **Inline projection.** In `Spike.Inline`:

       appendAndProject
         :: KirokuStore
         -> StreamName -> ExpectedVersion -> [EventData]
         -> (RecordedEvent -> Hasql.Session ())   -- projection update
         -> IO (Either StoreError ())

   Implementation: open `TxSessions.transaction ReadCommitted Write`, run kiroku's append-events SQL (port the SQL out of `Kiroku.Store.Append.Effect` if necessary; or call kiroku's `AppendToStream` interpreter directly inside a `useTx` if exposed), then run the user's projection update statement, commit. Build a sample projection: a `counter_projection (id text primary key, value int)` table updated to `value = value + 1` on each `Incremented` event from the `Counter` aggregate.
3. **Async projection.** In `Spike.Async`:
   - Construct a shibuya `Adapter` from `shibuya-kiroku-adapter` targeting `Category "counter"`.
   - Handler signature: `Ingested es RecordedEvent -> Eff es AckDecision`.
   - Inside the handler: decode payload via the codec from EP-2 (or inlined for the spike); update the projection table; advance a `subscriptions(name, last_seen)` row in the **same transaction** as the projection update.
   - Use shibuya's `Serial + StrictInOrder` for the spike (concurrency comes later).
4. **Process manager.** In `Spike.PM`:
   - Subscribe to `order-*` category (separate aggregate from Counter).
   - Reconstruct PM state by reading the PM's own stream `pm:orderfulfillment-<correlationId>` first.
   - Step function: `(PMState, OrderEvent) -> (PMState, [Command])`. On `OrderPlaced`, emit `ReserveInventory` against an `inventory-<sku>` aggregate. On `OrderCancelled`, emit `ReleaseInventory`.
   - Emission: open one `TxSessions.transaction`; append the new commands' resulting events into both the PM's stream and the target aggregate's stream via `appendMultiStream`; advance the source-event subscription checkpoint inside the same transaction.
5. **Outbox.** In `Spike.Outbox`:
   - Create `outbox(id bigserial primary key, payload jsonb, queued_at timestamptz default now())` in the spike schema.
   - When the inline projection runs, also insert a row into `outbox` with the same payload.
   - Stand up a relay loop: read `outbox` rows, push them onto a pgmq queue via `pgmq-hs`, delete the outbox row inside one transaction.
   - Stand up a pgmq consumer (via `shibuya-pgmq-adapter`) that prints the payload.
6. **Gap-free read demonstration.** In `Spike.GapFree`:
   - Spawn two concurrent appender threads, each writing 1 000 events to distinct streams in a tight loop.
   - Run an async-projection subscriber that consumes from `$all` in `globalPosition` order.
   - Assert: the subscriber sees exactly 2 000 events, contiguous `globalPosition`s with no gaps, no duplicates. Cite kiroku's Strategy E in the test's comment header so a future reader understands *why* this works without a watermark layer.
   - Note for the design doc: the equivalent test in a Marten-shaped store would require running the high-water-mark daemon. We have nothing to run.

Acceptance for M1: `cabal run spike` exits 0 and prints a transcript showing each of the five sub-spikes succeeding, plus a forced concurrent-write race where the subscriber demonstrably waits before advancing past the gap.

### Milestone 2 — Design document

Write `docs/research/08-subscription-and-process-manager-design.md`. Self-contained. Structure:

- *Problem statement* — three lifecycles, outbox, process managers; why they belong in one document.
- *Inline projection design* — the `runCommandWithSql` combinator from EP-1's design, applied here. Show how a projection is registered and invoked. Failure semantics: a projection error rolls back the append.
- *Async projection design* — the shibuya adapter + handler + checkpoint pattern. Define the `subscriptions` table extensions if any. Define the `decodeRecorded` boundary point (cite EP-2's `Codec`).
- *Gap-free reads — why no watermark is needed* — explain Strategy E (atomic counter on the `$all` row), reference `kiroku/docs/DESIGN.md`, contrast with Marten's bigserial+HWM approach. State the consequence for keiro: subscribers' `last_seen` can advance to any observed position with no gap-detection layer.
- *Process manager design* — types, the `(state, event) -> (state, [command])` step, the PM state stream naming convention, the multi-stream commit pattern.
- *Outbox design* — table layout, relay worker shape, idempotency contract for downstream consumers (rely on `commandId` already in EP-1).
- *Inbox design* — dual table, dedup-on-insert, how it composes with handlers.
- *Failure semantics* — `AckRetry`, `AckDeadLetter`, projection errors, PM emission errors, outbox-relay failure.
- *Concurrency policy* — strict-in-order for inline, partitioned-in-order for async (partition by stream id), unordered for outbox relay.
- *Streamly pipeline shapes* — name the concrete `Stream`/`Fold` types each lifecycle exposes, since the MasterPlan (`docs/masterplans/1-keiro-research-foundation.md`'s "Streamly substrate" Integration Point) makes Streamly the canonical substrate. Specifically:
  - **Async projection** — the source is `shibuya-kiroku-adapter`'s `Stream (Eff es) (Ingested es RecordedEvent)`; the runner is `Stream.fold Fold.drain $ Stream.mapM (decodeAndProject codec project) source` (this is the same shape as `Shibuya/Runner/Serial.hs:37-38`). The projection function is lifted into the stream's `Eff es`, so the per-event Hasql transaction (projection update + checkpoint advance) sits inside the `Stream.mapM` step.
  - **Inline projection** — *not* a `Stream` at all: it is one synchronous call inside `runCommandWithSql` from EP-1. Document this asymmetry explicitly so reviewers do not look for a streamly pipeline where there isn't one.
  - **Process manager** — same source `Stream` as the async projection, but the `Stream.mapM` step folds the PM's joint state via `Fold.foldlM' pmStep (initialPMState, [])` over a *batched* slice (`Stream.foldMany (Fold.take n Fold.toList)`-style batching, mirroring `Shibuya/Stream.hs:38`'s `batchStream`) when the PM emits multi-stream commands, so multiple input events can collapse into one `appendMultiStream` transaction. The trade-off (latency vs. throughput) is documented; default is no batching for clarity.
  - **Outbox relay** — two pipelines composed: (a) the *drain* loop is `Stream.unfoldrM` over `SELECT … FROM outbox … LIMIT n FOR UPDATE SKIP LOCKED` mapped through `Stream.mapM enqueueAndDelete` then `Fold.drain`; (b) the *consume* loop is `shibuya-pgmq-adapter`'s `Stream (Eff es) (Ingested es OutboxPayload)` consumed by `Stream.fold Fold.drain $ Stream.mapM deliverExternally source`.
  - **Gap-free read demo (M1.7)** — built on `shibuya-kiroku-adapter`'s `Stream (Eff es) (Ingested es RecordedEvent)` with `Fold.foldlM' assertContiguousGlobalPosition (GlobalPosition 0)` as the validating fold.

  The point of naming these shapes in the design doc is twofold: (1) reviewers can sanity-check that no parallel streaming abstraction (`conduit`, `pipes`, `Vector`-of-events held in memory) has crept into a sub-pipeline; (2) implementers know exactly which Streamly primitives they will reach for, so the spike's module structure (`Spike.Async`, `Spike.PM`, `Spike.Outbox`, `Spike.GapFree`) is straightforward.
- *Observability* — what spans/metrics each lifecycle emits; tie to shibuya-metrics + OpenTelemetry hooks already in shibuya.
- *Test strategy* — for each lifecycle, the acceptance behavior to verify.
- *Open questions / upstream gaps* — likely items to forward to EP-6: a kiroku-side combinator that exposes `runInTransaction :: Hasql.Session a -> Eff es a` so handlers can append events plus update projection rows plus advance the subscription checkpoint inside one transaction **[CLOSED 2026-05-10 — shipped as `Kiroku.Store.Transaction.runTransactionAppending`; the projection/outbox write path uses it directly. The "advance the subscription checkpoint inside one transaction" half remains open and depends on the still-pending shibuya-kiroku-adapter `HandlerInTransaction` shape.]**; possibly a kiroku-side durable-timer table.

Acceptance for M2: doc exists, is referenced from `docs/research/00-overview.md`, and a reviewer can answer "should this projection be inline or async?" and "how does keiro avoid skipping events under concurrent appenders?" purely from this document.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

Bootstrap and run the spike:

    mkdir -p spikes/subscriptions/app spikes/subscriptions/src/Spike
    # author files per Plan of Work milestone 1
    cd spikes/subscriptions
    cabal build all
    cabal run spike

Expected (truncated):

    [sub-spike] inline projection: counter at 7 after 3 events (read-your-writes)
    [sub-spike] async projection: caught up after 12 events; checkpoint=12
    [sub-spike] process manager: emitted ReserveInventory for order-42
    [sub-spike] outbox relay: 5 messages forwarded to pgmq, consumed downstream
    [sub-spike] gap-free test: 2 concurrent appenders × 1000 events each; subscriber observed 2000 contiguous globalPositions, no gaps
    [sub-spike] OK

Write the design doc:

    # author docs/research/08-subscription-and-process-manager-design.md
    # update docs/research/00-overview.md to add the new entry


## Validation and Acceptance

All must hold:

1. `cabal build all` from `spikes/subscriptions` exits 0.
2. `cabal run spike` exits 0 and prints `OK`.
3. Inline projection: a read of the projection table immediately after the spike's first append shows the projected row (no latency window).
4. Async projection: the handler is invoked exactly once per event, the checkpoint advances monotonically, and the projection table eventually reflects every event.
5. Process manager: an `OrderPlaced` event causes a `ReserveInventory` event to appear on the inventory aggregate's stream within the spike's run.
6. Outbox: every inline projection invocation produces an outbox row that the relay drains, and the pgmq consumer prints it.
7. Gap-free reads: under concurrent appenders, the async subscriber observes every `globalPosition` exactly once with no skips and no duplicates, with no subscriber-side gap-detection logic — courtesy of kiroku's Strategy E.
8. `docs/research/08-subscription-and-process-manager-design.md` exists and is referenced from `docs/research/00-overview.md`.


## Idempotence and Recovery

Spike is throwaway; every run starts a fresh `ephemeral-pg`. Re-running is safe.

If the gap-free test is flaky, the bug is real — kiroku's Strategy E should make this rock-solid. Investigate (concurrent appenders, the SQL kiroku emits) before relaxing the assertion. Do not paper over a real correctness defect with a watermark.

If the outbox relay loop hangs because pgmq-hs and shibuya-pgmq-adapter version-skew, fix the cabal.project pins; do not bypass the relay (the whole point of the spike is to demonstrate the relay).

The design document is a normal Markdown file; saving the same content twice is a no-op.


## Interfaces and Dependencies

Libraries used:

- `kiroku-store` — append/read APIs, subscription primitives.
- `keiki` — pure decider for the PM's step function.
- `shibuya-core` — adapter/handler abstractions.
- `shibuya-kiroku-adapter` — turns kiroku subscriptions into shibuya pull streams.
- `shibuya-pgmq-adapter` — pulls outbox-relayed messages from pgmq.
- `pgmq-hs` — Postgres queue for the outbox relay.
- `effectful`, `hasql`, `aeson`, `text`, `vector`, `ephemeral-pg` — supporting infrastructure.
- `streamly` and `streamly-core` (registered as `composewell/streamly`) — `Streamly.Data.Stream` (`Stream`, `unfoldrM`, `mapM`, `morphInner`, `foldMany`, `take`, `repeatM`, `catMaybes`, `filter`) and `Streamly.Data.Fold` (`Fold`, `foldlM'`, `drain`, `take`, `toList`). Already a transitive dependency through shibuya-core (`Shibuya/Adapter.hs:12`, `Shibuya/Stream.hs`, `Shibuya/Runner/{Serial,Ingester,Supervised}.hs`) and through kiroku-store (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`); the spike depends on it directly so the projection / PM / outbox-relay pipelines can be assembled without going through shibuya for sub-pipelines that do not consume from a queue.

Function signatures that must exist by the end of M1:

    -- spikes/subscriptions/src/Spike/Inline.hs
    appendAndProject
      :: KirokuStore
      -> StreamName -> ExpectedVersion -> [EventData]
      -> (RecordedEvent -> Hasql.Session ())
      -> IO (Either StoreError ())

    -- spikes/subscriptions/src/Spike/Async.hs
    asyncProjectionHandler
      :: Codec e -> (e -> Hasql.Session ())
      -> Ingested es RecordedEvent
      -> Eff es AckDecision

    -- spikes/subscriptions/src/Spike/PM.hs
    processManagerHandler
      :: Codec eIn -> Codec eOut
      -> (PMState -> eIn -> (PMState, [(StreamName, [eOut])]))
      -> Ingested es RecordedEvent
      -> Eff es AckDecision

    -- (no high-water-mark module needed — kiroku's Strategy E handles ordering at the source)

By the end of M2, `docs/research/08-subscription-and-process-manager-design.md` is the source of truth for the production-shape signatures.

Downstream consumers:

- EP-4 (snapshots) — async projections may use snapshots to short-circuit replay; cross-link.
- EP-5 (workflow roadmap) — process managers are the v1 substrate; EP-5 must explain the v2 upgrade path on top of them.
- EP-6 (upstream roadmap) — receives the kiroku-side request for `runInTransaction` **[CLOSED 2026-05-10 — shipped as `Kiroku.Store.Transaction.runTransactionAppending`]** and (potentially) a durable-timer table. (No `highWaterMark` upstream request: kiroku's Strategy E supersedes that need.)


## Revisions

- 2026-05-10: **Marked the kiroku-store single-stream `runInTransaction` upstream gap as CLOSED.** Kiroku-store now ships `Kiroku.Store.Transaction` with `runTransactionAppending`/`runTransactionAppendingNoRetry` (single-stream append + user-supplied `(AppendResult -> Tx.Transaction a)` continuation in one ACID transaction; signature `StreamName -> ExpectedVersion -> [EventData] -> (AppendResult -> Tx.Transaction a) -> Eff es (Either StoreError a)`), `appendToStreamTx`/`prepareEventsIO`/`PreparedEvent` (the lower-level `Tx.Transaction`-flavored building block), and `runTransaction`/`runTransactionNoRetry` (the bare escape hatch over `Hasql.Transaction.Transaction`, `BEGIN`/`COMMIT` against the pool at `ReadCommitted`/`Write`). The `Store` effect gained `RunTransaction` and `RunTransactionNoRetry` constructors; new `AppendConflict (..)` error surface with `appendConflictToStoreError` projects conflict outcomes onto `StoreError`. Live source: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Transaction.hs`. **Cascade for this plan**: §2's inline-projection lifecycle and §6's outbox write path bind directly to `runTransactionAppending` rather than the `appendMultiStream`-with-singleton-list workaround the design doc and this plan body documented; the deferred M1 spike's blocker on this gap is half-removed (the kiroku-store half closes; the shibuya-kiroku-adapter `HandlerInTransaction` half remains open as of 2026-05-10). Inline `[CLOSED]` markers were added to lines 92, 200, and 300 of this plan body. The published EP-3 design doc at `docs/research/08-subscription-and-process-manager-design.md` is preserved verbatim per the closed-doc convention; a top-of-file corrections note plus inline markers at §1 framing, §2 inline-projection upstream-dependency, §13 upstream-gaps, and §"Summary of forward-looking work" record the closure overlay. The parent MasterPlan's 2026-05-10 Surprises & Discoveries entry "cross-cutting, follow-up to the EP-8 M3 discovery — full kiroku transaction API surface" and matching Revisions entry document the cascade. EP-3 status remains Complete; only doc-level cross-references are refreshed. The deferred-spike status is unchanged because the second of the two upstream gaps (shibuya-kiroku-adapter `HandlerInTransaction`) is still open. Reason: the user shipped the kiroku transaction primitive and asked for a comprehensive doc cascade.

- 2026-05-04: Removed Marten high-water-mark machinery (decision, milestone, design-doc subsection, validation criterion, signature, upstream request). Replaced with explicit reliance on kiroku's existing Strategy E global-position guarantee, documented in `kiroku/docs/DESIGN.md`. Added a corresponding "gap-free reads" demonstration milestone that asserts the absence of gaps under concurrent appenders, citing Strategy E in the test header. Reason: kiroku deliberately chose Strategy E *to avoid* the operational complexity of HWM; recommending HWM at the subscriber layer would have re-paid the very tax kiroku declined.

- 2026-05-04: Made the use of Streamly's `Stream` and `Fold` explicit. Added a *Streamly pipeline shapes* subsection to the M2 design-doc outline that names the concrete `Stream (Eff es) …` and `Fold (Eff es) …` types each lifecycle exposes (async projection, inline projection's deliberate non-pipeline shape, process-manager loop with optional `Stream.foldMany` batching, outbox drain + consume, gap-free read demo). Added `streamly` and `streamly-core` as direct dependencies of the spike. Added a Decision Log entry. Reason: matches the MasterPlan's new "Streamly substrate" Integration Point; reuses the substrate shibuya and kiroku-store already hand back; avoids parallel streaming abstractions creeping in per sub-pipeline.
