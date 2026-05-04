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

1. read `docs/research/08-subscription-and-process-manager-design.md`, which fixes the design of the three lifecycles, the outbox table, the high-water-mark algorithm, and the process-manager state model;
2. run a working spike at `spikes/subscriptions/` that demonstrates an inline projection, an async projection, a tiny process manager, and an outbox relay against a real Postgres instance.

The user-visible behaviour the eventual library will deliver: an aggregate author writes a projection function `event -> Hasql.Session ()`, picks a lifecycle (`Inline` or `Async name`), and the framework persists, observes, and rebuilds it correctly. A workflow author writes a `(state, event) -> (state, [command])` step function and the framework runs it as an event-sourced process manager.


## Progress

- [ ] M1.1 — Bootstrap `spikes/subscriptions/` cabal package depending on `kiroku-store`, `keiki`, `shibuya-core`, `shibuya-kiroku-adapter`, `shibuya-pgmq-adapter`, `pgmq-hs`, `effectful`, `hasql`, `ephemeral-pg`.
- [ ] M1.2 — Define a sample `Order` aggregate (reusing the codec from EP-2's spike if available) and a `Counter` from EP-1.
- [ ] M1.3 — Implement an *inline projection*: `appendEventsAndUpdateProjection` opens a hasql `TxSessions.transaction ReadCommitted Write`, calls kiroku's append SQL plus a user-supplied projection update, commits both as one.
- [ ] M1.4 — Implement an *async projection*: a shibuya handler subscribes to a category via `shibuya-kiroku-adapter`, decodes events through the codec, runs the user's projection function, advances a checkpoint in the same hasql transaction as the projection write.
- [ ] M1.5 — Implement a tiny *process manager*: subscribes to `order-*`, maintains its own state in a `pm-orderfulfillment-<id>` stream, emits a `ReserveInventory` command into a separate aggregate stream when an `OrderPlaced` event is seen.
- [ ] M1.6 — Implement an *outbox relay*: a handler appends events to kiroku and inserts an outbox row in the same transaction; a separate worker reads the outbox via pgmq-hs and prints it (stand-in for HTTP delivery).
- [ ] M1.7 — Demonstrate *gap-free reads*: stage two concurrent appenders, then verify the async subscriber observes every event exactly once, in `globalPosition` order, with no skips or duplicates. Cite kiroku's Strategy E (atomic counter on the `$all` row, `stream_id = 0`) as the mechanism that makes this work without subscriber-side gap detection.
- [ ] M2.1 — Write `docs/research/08-subscription-and-process-manager-design.md`.
- [ ] M2.2 — Update `docs/research/00-overview.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Adopt three projection lifecycles (Inline, Async, Live) following Marten.
  Rationale: Marten's three-tier model is the cleanest articulation of the projection-consistency tradeoff (`docs/research/05-workflow-prior-art.md` §7). Live (compute-on-read) is essentially "do nothing"; the framework must support Inline and Async.
  Date: 2026-05-04.

- Decision: Rely on kiroku's existing Strategy E global-position guarantee. Do *not* introduce a Marten-style high-water-mark.
  Rationale: Kiroku's `docs/DESIGN.md` documents Strategy E: an atomic `UPDATE … RETURNING` on the `$all` row (`stream_id = 0`) inside the same transaction that inserts events claims contiguous `globalPosition`s (1, 2, 3, …) with immediate read-your-own-writes and no MVCC vulnerability. Strategy E was chosen specifically to avoid Marten's HWM operational complexity. Re-introducing HWM at the subscriber layer would re-pay the very tax kiroku declined. Subscribers can advance their `last_seen` to any observed `globalPosition` without gap-detection logic. (This decision supersedes an earlier draft of this plan that recommended the Marten approach; correction made on review.)
  Date: 2026-05-04.

- Decision: Process managers are themselves event-sourced — their state is rebuilt from events on a `pm-<name>-<instance>` stream, not from a row in a state table.
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


## Outcomes & Retrospective

(To be filled during and after implementation.)


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
- *Process manager* — an event-sourced coordinator with state of type `s` and step function `(s, event) -> (s, [command])`. The process manager's own state is reconstructed by replaying its own command-emission events from a stream of the form `pm-<name>-<instance>`.
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
   - Reconstruct PM state by reading the PM's own stream `pm-orderfulfillment-<correlationId>` first.
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
- *Observability* — what spans/metrics each lifecycle emits; tie to shibuya-metrics + OpenTelemetry hooks already in shibuya.
- *Test strategy* — for each lifecycle, the acceptance behavior to verify.
- *Open questions / upstream gaps* — likely items to forward to EP-6: a kiroku-side combinator that exposes `runInTransaction :: Hasql.Session a -> Eff es a` so handlers can append events plus update projection rows plus advance the subscription checkpoint inside one transaction; possibly a kiroku-side durable-timer table.

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
- EP-6 (upstream roadmap) — receives the kiroku-side request for `runInTransaction` and (potentially) a durable-timer table. (No `highWaterMark` upstream request: kiroku's Strategy E supersedes that need.)


## Revisions

- 2026-05-04: Removed Marten high-water-mark machinery (decision, milestone, design-doc subsection, validation criterion, signature, upstream request). Replaced with explicit reliance on kiroku's existing Strategy E global-position guarantee, documented in `kiroku/docs/DESIGN.md`. Added a corresponding "gap-free reads" demonstration milestone that asserts the absence of gaps under concurrent appenders, citing Strategy E in the test header. Reason: kiroku deliberately chose Strategy E *to avoid* the operational complexity of HWM; recommending HWM at the subscriber layer would have re-paid the very tax kiroku declined.
