---
id: 96
slug: ack-coupled-sharded-subscription-delivery-with-rebalance-under-load-coverage
title: "Ack-coupled sharded subscription delivery with rebalance-under-load coverage"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
master_plan: "docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md"
---

# Ack-coupled sharded subscription delivery with rebalance-under-load coverage

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Parent MasterPlan: `docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md` (this plan is EP-96, Phase 2). Per that master plan's Integration Point 4, this plan **defines** the per-event acknowledgement surface that plan `docs/plans/100-process-manager-failure-paths-dead-lettering-rejected-commands-and-surfacing-retry-exhaustion.md` (EP-100) will later use for its shard-path dead-letter posture. Every commit made under this plan must carry the git trailer `ExecPlan: docs/plans/96-ack-coupled-sharded-subscription-delivery-with-rebalance-under-load-coverage.md`.


## Purpose / Big Picture

keiro's sharded subscription worker (`keiro/src/Keiro/Subscription/Shard/Worker.hs`) lets a pool of identical processes cooperatively drain one event category: each process leases some of the category's N hash buckets and runs one reader per owned bucket. The module's own documentation promises "every event is processed by exactly one worker, none twice, none skipped" and "no event is dropped" (Worker.hs:9-10, 25-26). Today that promise is false: during a rebalance — which happens on **every cold start**, because a starting worker over-claims buckets and then sheds the excess (Worker.hs:20-23, 219-225) — the worker can silently and permanently lose the event that is in the handler at the moment a bucket is shed. No process manager, projection, or read model ever sees that event, and nothing records that it was skipped.

After this change, the sharded worker acknowledges each event to the underlying kiroku store **only after the keiro handler has finished it**, so the persisted checkpoint can never move past an unprocessed event. A shed or crash mid-handler results in redelivery to the bucket's next owner (at-least-once, no gaps) instead of loss. As a second, deliberate behavior change, a handler that keeps throwing on one event no longer kills the whole bucket reader in an infinite restart loop: the event is redelivered a bounded number of times and then recorded in kiroku's dead-letter table while the subscription moves on. You can see all of it working by running the new tests in `keiro/test/Main.hs`: a rebalance-under-load drain that loses events on the current code and loses none afterwards, a batch-tail kill/restart that proves redelivery, and a zombie-overlap test that proves the duplicate (not loss) failure mode.


## Progress

- [ ] M1: batch-tail kill test written and shown failing (event lost) against the unmodified worker; failure transcript captured in Surprises & Discoveries
- [ ] M1: rebalance-under-load test written and shown failing (or flaking with `count < total`) against the unmodified worker; transcript captured
- [ ] M2: `ShardAck` / `ShardDelivery` types and `runShardedSubscriptionGroupAck` added to `keiro/src/Keiro/Subscription/Shard/Worker.hs`
- [ ] M2: `startReader` converted from `subscriptionStream` to `subscriptionAckStream`; reply written after the handler returns
- [ ] M2: `ShardedWorkerOptions` gains `handlerRetryDelay` and `retryPolicy` with validation in `mkShardedWorkerOptions`
- [ ] M2: existing "reader killed by a handler exception is restarted" test rewritten for the new bounded-retry semantics
- [ ] M2: stale zombie docstring (Worker.hs:44-48) rewritten; module contract prose updated; all shard tests green; committed together with the M1 tests
- [ ] M3: zombie-overlap duplicate test written and passing (duplicates observed, zero loss)
- [ ] M3: poison-event dead-letter test written and passing (bounded retries, row in kiroku's dead-letter table, drain continues)
- [ ] M4: master plan EP-96 checkboxes ticked; Outcomes & Retrospective written; revision note appended


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. M1 must add the captured failing-test transcripts here.)


## Decision Log

- Decision: fix the worker by switching to kiroku's existing ack-coupled bridge `subscriptionAckStream` rather than changing kiroku or adding keiro-side checkpointing.
  Rationale: the bridge already exists in the pinned kiroku revision and is proven in production shape by the shibuya-kiroku adapter (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs:125-153` in the kiroku repository); the defect is purely keiro's choice of the non-acking bridge. Matches the parent master plan's Decision Log entry of 2026-07-12.
  Date: 2026-07-12

- Decision (design decision "a" — ack posture per outcome): handler returns normally → reply `Continue` (checkpoint may advance); handler throws a **synchronous** exception → reply `Retry` (bounded by kiroku's `retryMaxAttempts`, after which kiroku dead-letters the event and advances); bucket shed / worker shutdown / any **asynchronous** exception → no reply at all (the kiroku worker stays blocked, is cancelled, and the unacknowledged event is redelivered to the bucket's next owner). No `Stop` and no halt-style outcome on this path: a bucket reader has no operator sitting behind it to make a halt decision, and "cancel without advancing" — the shibuya adapter's `AckHalt` behavior — is exactly what the shed path already does.
  Rationale: success-ack is the fix for the loss; Retry-on-exception deliberately converts today's infinite reader-restart loop (Worker.hs:264-271 kills and the reconcile pass restarts) into bounded-retry-then-dead-letter, which is observable and replayable; no-reply-on-shed is what makes rebalance lossless. Mapping exceptions to `Retry` rather than immediate `DeadLetter` is conservative — EP-100 owns refining the shard-path dead-letter posture through the surface this plan exposes.
  Date: 2026-07-12

- Decision (design decision "b" — in-flight window): the per-reader in-flight window shrinks to exactly **one** event; no keiro-side buffer of unacknowledged events is kept.
  Rationale: kiroku's ack bridge already serializes delivery — its worker blocks inside the bridge handler until the consumer replies (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs:191-200`), so at most one unacknowledged `AckItem` exists per subscription at any time; a keiro-side buffer would require strictly ordered ack bookkeeping for zero throughput gain, because parallelism in this design comes from running N bucket readers, not from pipelining within one bucket. The `bufferSize` option is kept (the bridge validates it ≥ 1) purely for API stability.
  Date: 2026-07-12

- Decision (design decision "c" — the EP-100 hook): expose a keiro-owned per-event ack surface — `ShardAck` (`ShardAckOk` / `ShardAckRetry` / `ShardAckDeadLetter`), a `ShardDelivery` record carrying the event, its zero-based redelivery attempt, and its bucket, and a new entry point `runShardedSubscriptionGroupAck` — rather than leaking kiroku's `SubscriptionResult` through keiro's public API. The existing `runShardedSubscriptionGroup` with its `RecordedEvent -> IO ()` handler is kept as a thin wrapper over the ack variant.
  Rationale: kiroku's `SubscriptionResult` contains `Stop`, which is meaningless (and dangerous — it checkpoints at the stopping event and ends the reader) for a bucket reader; a keiro-owned three-way type is the minimal honest vocabulary, and it is the exact interface the master plan's Integration Point 4 says EP-100 consumes for shard-path dead-lettering. Existing callers keep compiling unchanged.
  Date: 2026-07-12

- Decision: the module docstring's claim that a zombie worker "can then write an older kiroku consumer-group checkpoint and enlarge the redelivery window" (Worker.hs:44-48) is fixed as **documentation only**, no behavior change.
  Rationale: kiroku's checkpoint upserts use `GREATEST(subscriptions.last_seen, EXCLUDED.last_seen)` for both the plain and the consumer-group-member statements (`kiroku-store/src/Kiroku/Store/SQL.hs:1198-1205` and `1243-1250` in the kiroku repository), so a laggard can never move a checkpoint backward; the only zombie effect is brief duplicate delivery, which the at-least-once contract already covers. The parent master plan's Surprises section records the same finding.
  Date: 2026-07-12

- Decision: add `handlerRetryDelay :: RetryDelay` (default 1 s) and `retryPolicy :: RetryPolicy` (default kiroku's `defaultRetryPolicy`, five total deliveries) to `ShardedWorkerOptions`.
  Rationale: the exception→`Retry` mapping needs a delay value, and kiroku sleeps that delay between redeliveries while the bucket head-of-line blocks — tests need it small (fractions of a second) and production wants it configurable; the retry bound must be tunable for the same reason. Both flow directly into the kiroku `SubscriptionConfig` the reader already builds.
  Date: 2026-07-12

- Decision: the M1 reproduction tests are written first and **run** against the unmodified worker to capture the loss, but are committed only together with the M2 fix, in one commit.
  Rationale: every commit must leave the test suite green; the red run still happens and its transcript is preserved in Surprises & Discoveries as the evidence that the tests actually exercise the loss window (the existing failover test deliberately avoids it — see Context).
  Date: 2026-07-12


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained: it defines every term and names every file. All keiro paths are relative to this repository's root. kiroku and shibuya paths are relative to the **kiroku repository's** root — kiroku is a separate project consumed as a source dependency: `cabal.project` in this repo pins `kiroku-store` to git tag `6399844a507a3ea5a3974181b4d8c1380f2f7b5b`, and cabal unpacks that exact source under `dist-newstyle/src/kiroku-*/` where you can read it. That pinned revision already exports everything this plan needs (verified: `subscriptionAckStream` and `AckItem` are present in the unpacked `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`), so **no kiroku changes and no pin bump are required**.

**The moving parts.** kiroku is the PostgreSQL event store. An *event* is an immutable record in its `events` table; every event has a store-wide *global position* (a monotonically increasing integer). A *category subscription* delivers, in global-position order, every event whose stream name starts with a category prefix (for example every `orders-*` stream). A *consumer group* of size N splits one category N ways: kiroku hashes each event's originating stream id into one of N *buckets* (member indexes 0..N-1), and a reader for member i sees only bucket i's events. Each `(subscription name, member)` pair has its own *checkpoint* — a row in kiroku's `subscriptions` table recording the highest global position that member has consumed. A restarted reader resumes from its checkpoint; everything at or below the checkpoint is never delivered to that member again. That is why a wrongly advanced checkpoint means permanent loss.

**keiro's sharding layer.** `keiro/src/Keiro/Subscription/Shard.hs` implements bucket *leases*: a table (`keiro_subscription_shards`) in which each bucket row records an owner worker id and a lease expiry. `acquireOwnedBuckets` renews held leases and claims up to a fair share more; `relinquish` releases buckets; `ownershipSnapshot` lists ownership. `keiro/src/Keiro/Subscription/Shard/Worker.hs` turns leases into running readers: `reconcileShardsOnce` (Worker.hs:192-240) runs one pass — estimate live workers, claim/renew, *shed* excess buckets above the fair share (Worker.hs:219-225), then start a reader for each newly owned bucket and stop the reader for each lost one. `runShardedSubscriptionGroup` (Worker.hs:297-328) loops that pass forever. *Shedding* is routine, not exceptional: a cold-starting worker briefly believes it is alone, over-claims, and gives buckets back as peers appear — the module header says so itself (Worker.hs:20-23).

**The defect.** `startReader` (Worker.hs:254-277) opens a kiroku reader for one bucket using the **plain** streamly bridge `subscriptionStream` (Worker.hs:262). A *bridge* here is a small adapter in `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` that converts kiroku's push-based subscription into a pull-based stream over a bounded queue. The plain bridge replies `Continue` to the kiroku worker **at the moment an event is pulled from the queue, before the keiro handler runs** (Stream.hs:141-156; the module's own docs at Stream.hs:5-11 say exactly this). `Continue` tells kiroku's subscription worker the event is consumed; when the worker finishes a batch it persists the checkpoint at the batch tail (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:677-683`) — concurrently with keiro's drain thread (the thread forked at Worker.hs:263-271 that feeds pulled events into the handler) still executing the handler on that tail event. Now shed the bucket: `stopReader` runs `cancelAction` and then `killThread` on the drain thread (Worker.hs:273-277), killing the handler mid-flight. The checkpoint has already advanced past the in-flight event, so the bucket's next owner resumes **past** it. The event is silently lost. The window is worst exactly when it matters: a caught-up reader receives live batches of one event, so *every* event is a batch tail, and *every* mid-handler shed loses the in-flight event. This directly contradicts the module contract ("none skipped", Worker.hs:9-10; "no event is dropped", Worker.hs:25-26; "at-least-once", Worker.hs:41-43).

**Secondary defects.** (1) No per-event retry or dead-letter: a handler exception propagates out of the drain fold, the reader thread dies, `forkFinally`'s cleanup reports `ShardReaderDied` and removes the reader from the map (Worker.hs:264-271), and the next reconcile pass restarts it — an infinite restart loop on a poison event (each restart also redelivers from the checkpoint). (2) The docstring claims a zombie worker "can then write an older … checkpoint" (Worker.hs:44-48); that is stale — kiroku's checkpoint upserts use `GREATEST` (kiroku `SQL.hs:1198-1205`, `1243-1250`), so regression is impossible and only duplicate delivery remains.

**The proven fix pattern.** kiroku ships a second bridge in the same module: `subscriptionAckStream` (Stream.hs:174-228). Each stream element is an `AckItem` (Stream.hs:83-93) carrying the event, a zero-based redelivery attempt counter (`ackAttempt`), and a one-shot reply variable (`ackReply :: TMVar SubscriptionResult`). The kiroku worker **blocks inside its handler** until the consumer fills the reply (Stream.hs:191-200), and only then acts on it: `Continue` lets the batch walk (and eventually the tail checkpoint) proceed; `Retry delay` redelivers the same event after `delay`, bounded by the config's `retryMaxAttempts` (`kiroku-store/src/Kiroku/Store/Subscription/Types.hs:173-179`, default five total deliveries per `defaultRetryPolicy` at Types.hs:187-188), after which the worker dead-letters the event with `DeadLetterMaxAttempts` and advances past it (kiroku `Worker.hs:710-714`); `DeadLetter reason` records the event in kiroku's `kiroku.dead_letters` table and advances the checkpoint past it atomically in one statement (kiroku `Worker.hs:707-708`, `728-757`). The shibuya-kiroku adapter already consumes this bridge in production shape: `toIngestedAck` (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs:125-140`) writes the reply after its handler decides, and `toKirokuResult` (Convert.hs:148-153) maps `AckOk`→`Continue`, `AckRetry`→`Retry`, `AckDeadLetter`→`DeadLetter`, while `AckHalt` cancels the subscription **without** replying — no checkpoint advance, so the halting event replays on restart (Convert.hs:115-117). Our shed path uses exactly that no-reply-cancel move.

**Why the existing tests never caught this.** The shard test suites live in `keiro/test/Main.hs:5484-5698`. The failover test's own comment (Main.hs:5608-5614) says it lets ownership converge on the **empty** category first "so the churn of cold-start rebalancing touches no events", then seeds and drains under stable membership. The loss window — a shed while a handler is mid-event — is therefore never exercised. The harness pieces you will reuse: `withFreshStore fixture` (per-example migrated database), `createShardSinkSql` (Main.hs:8706-8709, a `shard_sink` table with `event_id` primary key so the recording handler is idempotent), `seedOrders` (Main.hs:8714-8731, appends `perStream` events to each of `nStreams` `orders-*` streams), `sinkHandler` (Main.hs:8734-8742), `shardSinkCount` (8755), `maxWorkersPerStream` (8769), `distinctWorkers` (8784), `waitUntilSinkCount` (8797), `waitShardsBalanced` (8814), `waitShardsUnowned` (8834). PostgreSQL is provisioned by `keiro-test-support/src/Keiro/Test/Postgres.hs`: `withMigratedSuite` (called once in `main`, Main.hs:317) starts a cached ephemeral PostgreSQL server via the `ephemeral-pg` library, migrates one template database with the kiroku and keiro migrations, and clones a fresh database per example — no external database or `just postgres-start` is needed; you only need the repo's dev shell (there is a `.envrc`; use `direnv` or `nix develop`) so `initdb`/`postgres`/`cabal` are on PATH.

**Build and test commands** (all from the repository root, `/…/keiro`, inside the dev shell): `cabal build keiro` builds the library; `cabal test keiro-test` runs the whole suite; `cabal test keiro-test --test-options='--match "Sharded subscription"'` runs only the shard specs (hspec substring match — also matches the new describe blocks if you keep "Sharded subscription" in their names); `just haskell-verify` is the full local gate (`cabal build all`, the three test suites, website checks) and `just verify` adds process-compose and migration checks. The jitsurei example package is out of scope per the master plan (user directive 2026-07-12) and must not be cited or migrated.


## Plan of Work

### Milestone 1 — Characterize the loss (red)

Scope: write the two loss-demonstrating tests and run them against the unmodified worker so we have proof they exercise the window the existing suite avoids. Nothing is committed in this milestone (the commit happens with the fix in Milestone 2, keeping every commit green); the failing transcripts are pasted into Surprises & Discoveries.

Both tests go in `keiro/test/Main.hs` in a new `describe "Sharded subscription ack coupling"` block wrapped in `around (withFreshStore fixture)`, next to the existing shard suites (after Main.hs:5698).

**Test A — batch-tail kill and redelivery.** One worker, `shardCount = 1` (one bucket, one reader, deterministic ownership), short `leaseTtl` (3 s) and `renewInterval` (0.3 s). Create the sink table, seed a handful of events (for example `seedOrders store 1 5` — one stream, five events; a single catch-up batch, so the last event is the batch tail). The handler records each event via `sinkHandler`-style insert, but for the **tail** event (recognize it when the sink count is about to reach the total, or by comparing the event's payload counter) it first signals an `MVar` "I am in the handler" and then blocks taking a second, never-filled `MVar`. The test waits on the in-handler signal, then `killThread`s the worker's driver thread (this runs `runShardedSubscriptionGroup`'s `finally` cleanup, which calls `stopReader` — `cancelAction` plus `killThread` on the drain thread, killing the blocked handler exactly as a shed would — and relinquishes the leases so the next worker can claim immediately). Then start a **second** worker with a plain recording handler and assert `waitUntilSinkCount store total 20_000_000` succeeds and `shardSinkCount` equals `total`. Against the unmodified worker this fails: the plain bridge acked the tail at pull time, kiroku checkpointed the batch at its tail (kiroku `Worker.hs:677-683`) while the handler sat blocked, and the second worker resumes past the tail — the sink stays at `total - 1` forever.

**Test B — rebalance under load.** Seed **first** (inverting the existing failover test's deliberate ordering): `seedOrders store 12 5` (60 events), sink table created. Options: `shardCount = 4`, `leaseTtl = 3`, `renewInterval = 0.3`, and — critically — `batchSize = 1`, so every delivered event is a batch tail and every mid-handler kill on the old code loses the in-flight event. The handler is `sinkHandler` preceded by a `threadDelay` of ~30 ms, keeping a handler in flight at almost all times. Start worker 1 alone; wait until the sink shows some progress (say ≥ 5 rows) proving the drain is mid-stream; then start worker 2. Worker 1's next reconcile pass sees two live workers, its claim exceeds the fair share, and it **sheds** buckets (Worker.hs:219-225) — `stopReader` kills live readers mid-handler. That is the forced bucket shed mid-stream; no additional test seam is needed because cold-start over-claim plus a second joiner triggers shedding by design (the lease TTL and membership seams in `keiro/src/Keiro/Subscription/Shard.hs` stay available if the implementer wants a more surgical trigger, for example driving `reconcileShardsOnce` by hand). Assert `waitUntilSinkCount store total 30_000_000` and `shardSinkCount == total`: every seeded event processed by *some* owner, at least once, no gaps. Do **not** assert `maxWorkersPerStream == 1` here — re-homing legitimately splits streams across workers; duplicates are absorbed by the sink's primary key. Kill both workers at the end. Against the unmodified worker this times out with `count < total` (each shed that lands mid-handler on a batch tail loses one event; with `batchSize = 1` that is every mid-handler shed).

Acceptance for M1: both tests compile, run, and fail against the unmodified worker for the *predicted* reason (missing events, not harness errors); the transcripts are recorded in Surprises & Discoveries.

### Milestone 2 — Ack-coupled delivery and the EP-100 surface (green)

Scope: convert the worker to the ack bridge, introduce the per-event ack surface, adjust the one existing test whose semantics change, fix the stale docs, and commit everything (including M1's tests) as one green commit.

Edits, all in `keiro/src/Keiro/Subscription/Shard/Worker.hs` unless noted:

1. **New public types.** Define the keiro-owned ack vocabulary and delivery record (export them from the module's export list, and re-export kiroku's `RetryDelay` and `DeadLetterReason` so callers need not import kiroku directly):

    ```haskell
    -- | Per-event disposition a sharded handler returns. This is the surface
    -- EP-100 builds its shard-path dead-letter posture on.
    data ShardAck
        = ShardAckOk
        -- ^ Event fully processed; the checkpoint may advance past it.
        | ShardAckRetry !RetryDelay
        -- ^ Redeliver this event after the delay; bounded by 'retryPolicy',
        -- after which kiroku dead-letters it and advances.
        | ShardAckDeadLetter !DeadLetterReason
        -- ^ Record in kiroku's dead-letter table and advance immediately.

    -- | One delivery to a sharded handler.
    data ShardDelivery = ShardDelivery
        { event :: !RecordedEvent
        , attempt :: !Word
        -- ^ zero-based redelivery count (from kiroku's 'AckItem'): 0 on first
        -- delivery, 1 on the first retry redelivery, …
        , bucket :: !Int
        -- ^ the consumer-group member this reader owns
        }

    type ShardEventHandler = ShardDelivery -> IO ShardAck
    ```

    There is deliberately no halt constructor: cancelling without advancing (the shibuya `AckHalt` move) is the shed path, not a handler decision.

2. **Options.** Add to `ShardedWorkerOptions`: `handlerRetryDelay :: !RetryDelay` (used by the compatibility wrapper when a handler throws) and `retryPolicy :: !RetryPolicy` (passed into the kiroku subscription config). Defaults in `defaultShardedWorkerOptions`: `RetryDelay 1` and `defaultRetryPolicy`. Extend `mkShardedWorkerOptions` and `ShardedWorkerConfigError` with validation: a negative `handlerRetryDelay` and a `retryMaxAttempts < 1` are rejected (`InvalidShardHandlerRetryDelay`, `InvalidShardRetryMaxAttempts`).

3. **`startReader` conversion.** Replace the `subscriptionStream` call (Worker.hs:262) with `subscriptionAckStream store subConfig (opts ^. #bufferSize)`, set `Sub.retryPolicy = opts ^. #retryPolicy` in `subConfig`, and change the drain fold to reply **after** the handler:

    ```haskell
    let step item = do
            outcome <- ackHandler ShardDelivery
                { event = ackEvent item
                , attempt = ackAttempt item
                , bucket = bucket
                }
            atomically (putTMVar (ackReply item) (toSubscriptionResult outcome))
    tid <- forkFinally (Stream.fold (Fold.drainMapM step) stream) …
    ```

    with `toSubscriptionResult` mapping `ShardAckOk → Continue`, `ShardAckRetry d → Retry d`, `ShardAckDeadLetter r → DeadLetter r` (the same shape as the adapter's `toKirokuResult`, Convert.hs:148-153, minus halt). `stopReader` stays exactly as it is (Worker.hs:273-277): on a shed, `cancelAction` cancels the kiroku subscription (interrupting a worker blocked on an unfilled reply — the bridge documents this at Stream.hs:167-172) and `killThread` kills the drain thread; because no reply was written for the in-flight event, its checkpoint never advanced and the next owner redelivers it. That is the fix.

4. **Handler-fault containment.** `startReader`'s `step` wraps the `ackHandler` call so a **synchronous** exception becomes `ShardAckRetry (opts ^. #handlerRetryDelay)` instead of killing the reader; asynchronous exceptions (`killThread` during a shed delivers one) must be rethrown untouched. Concretely: catch `SomeException`, and rethrow when `fromException e :: Maybe SomeAsyncException` is `Just`. The reader-death path (`forkFinally` cleanup, `ShardReaderDied`, reconcile restart) remains, but now only fires for stream-level failures — database errors on fetch/checkpoint/dead-letter-insert rethrown by the bridge — for which restart-and-resume-from-checkpoint is the correct response.

5. **Entry points.** Add `runShardedSubscriptionGroupAck :: KirokuStore -> SubscriptionName -> ShardedWorkerOptions -> ShardEventHandler -> IO ()` — the body of today's `runShardedSubscriptionGroup` generalized to the ack handler (thread the handler through `reconcileShardsOnce` and `startReader`, whose handler parameters change type to `ShardEventHandler`). Reimplement `runShardedSubscriptionGroup` (unchanged signature, so all existing callers and tests compile) as a wrapper whose handler runs the plain `RecordedEvent -> IO ()` action on `delivery ^. #event` and returns `ShardAckOk`; the exception→retry mapping of item 4 covers it automatically since it sits below both entry points.

6. **Existing test rewrite.** The test "a reader killed by a handler exception is restarted and drains" (`keiro/test/Main.hs:5668-5698`) asserts the old semantics: first handler throw → reader dies → `ShardReaderDied` reported → restart drains. Under the new semantics a first throw is retried in place. Rewrite it as "a handler exception is retried in place and drains": same one-shot-throwing handler, but assert the drain completes, the sink reaches `total` (the thrown-at event was redelivered by `Retry`, not by a reader restart), and that **no** `ShardReaderDied` error was reported (assert the collected errors contain none, inverting the old expectation). Use a small `handlerRetryDelay` (for example `RetryDelay 0.05`) so the redelivery is fast.

7. **Documentation fixes.** In the module header: the "no event is dropped" sentence (Worker.hs:25-26) gains its justification ("the reader acknowledges each event only after the handler returns, so a shed bucket's checkpoint never covers an unprocessed event"); the handler-contract paragraph (Worker.hs:40-48) is rewritten — at-least-once with brief duplicate overlap stands, but the zombie sentence becomes: a zombie that keeps reading past `leaseTtl` can only cause duplicate delivery, never checkpoint regression, because kiroku's checkpoint upsert is monotonic (`GREATEST`, kiroku `SQL.hs:1198-1205` and `1243-1250`); drop the "can write an older checkpoint … future fencing generation" claim. Document the new failure semantics: a throwing handler is retried up to `retryMaxAttempts` total deliveries, then dead-lettered to kiroku's `kiroku.dead_letters` table and the subscription advances (no more infinite restart loops), and `ShardReaderDied` now signals stream-level failures only. Document `ShardAck` as the per-event surface EP-100 consumes.

Acceptance for M2: `cabal build keiro` clean; `cabal test keiro-test --test-options='--match "Sharded subscription"'` fully green, including M1's two tests and the rewritten exception test; one commit containing tests + fix + docs with the ExecPlan trailer.

### Milestone 3 — Duplicate-window and dead-letter coverage

Scope: pin down the two remaining behaviors as executable documentation — duplicates are possible (and are the *only* zombie effect), and poison events dead-letter instead of looping.

**Test C — zombie-overlap duplicates, no loss.** Choreograph a brief dual ownership using `reconcileShardsOnce` directly (it is exported precisely as "the single testable unit", Worker.hs:188-191) rather than the loop driver: build a `ShardLease` for worker A with a short `leaseTtl` (2 s), call `reconcileShardsOnce` once so A claims the bucket(s) and starts readers, and then never renew — A is now a *zombie*: its readers run but its leases lapse. Seed events. A's handler records each delivery into a raw **delivery log** (an `IORef [EventId]` or a sink table *without* a primary key — this test must count deliveries, not distinct events) and also into the idempotent `shard_sink`; block A's handler on its first event (MVar) so A holds one event unacknowledged. After A's TTL expires, start worker B (loop driver, normal recording handler writing to the same delivery log and sink). B claims the expired buckets and — because A never acked, so the member checkpoint never moved — redelivers from the start: every event A already touched is delivered again by B. Assert: `shardSinkCount == total` (no loss), the raw delivery count is **strictly greater** than `total` (duplicates observed — at minimum A's blocked first event was also delivered by B), and then release A's MVar and stop A's readers via the returned state. Document in the test comment that duplicates here are the *expected contract* (at-least-once; downstream consumers dedup on `eventId`, exactly as keiro's async-projection guidance and the sink's primary key model) and that loss is the defect being excluded. Note the monotonic checkpoint means A's late acks cannot regress B's progress.

**Test D — poison event dead-letters and the drain continues.** One worker, `shardCount = 1`, `retryPolicy = RetryPolicy 3`, `handlerRetryDelay = RetryDelay 0.05`. Seed a few events; the handler throws for exactly one poisoned payload (every time it is delivered) and records the rest. Assert: the sink reaches `total - 1`; the poisoned event appears in kiroku's dead-letter table (query it from the test — verify the exact table and schema name against the kiroku migrations in the pinned source, expected `kiroku.dead_letters`, with `reason_summary` mentioning max attempts, cf. `DeadLetterMaxAttempts` rendering at kiroku `Fsm.hs:132-137`); the raw delivery count for the poisoned event equals `retryMaxAttempts` (3 total deliveries: kiroku counts the first delivery as attempt 1, kiroku `Worker.hs:698-721`); and no `ShardReaderDied` was reported. This is the executable proof that the infinite-restart-loop defect is gone and is the seam EP-100's shard-path work extends.

Acceptance for M3: both tests green in the shard match run; committed with the trailer.

### Milestone 4 — Closeout

Scope: update the parent master plan (`docs/masterplans/14-…md`) Progress section — tick the two EP-96 checkboxes and set the registry row's status; write this plan's Outcomes & Retrospective; append a revision note; run the full `just haskell-verify` gate one final time.


## Concrete Steps

All commands run from the repository root (the directory containing `cabal.project`), inside the dev shell (`direnv allow` once, or prefix with `nix develop -c`).

```bash
cabal build keiro
```

Expected: compiles without warnings-as-errors failures. Then the focused test loop used throughout:

```bash
cabal test keiro-test --test-options='--match "Sharded subscription"'
```

Expected while on M1 (unmodified worker, new tests present):

```text
Sharded subscription ack coupling
  redelivers a batch-tail event whose handler was killed mid-flight FAILED [1]
  loses no events when a bucket is shed mid-drain (rebalance under load) FAILED [2]
...
2 examples failed
```

(the first fails with the sink stuck at `total - 1`, the second with `count < total`). Capture that transcript into Surprises & Discoveries. Expected from M2 onward: all shard examples pass, 0 failures. Final gates:

```bash
cabal test keiro-test
just haskell-verify
```

Commit shape (M2 example):

```text
fix(shard): ack-couple sharded subscription delivery to the handler

Switch startReader to kiroku's subscriptionAckStream and reply per event
after the keiro handler returns: success -> Continue, sync exception ->
Retry (bounded, then kiroku dead-letters and advances), shed/cancel -> no
reply (redelivery to the next owner). Adds the ShardAck/ShardDelivery
surface and runShardedSubscriptionGroupAck (the EP-100 hook), retry knobs
on ShardedWorkerOptions, rebalance-under-load and batch-tail-kill tests,
and fixes the stale zombie-checkpoint docstring (GREATEST upsert).

ExecPlan: docs/plans/96-ack-coupled-sharded-subscription-delivery-with-rebalance-under-load-coverage.md
```

This section must be updated with the actual transcripts and any deviations as work proceeds.


## Validation and Acceptance

The change is accepted when all of the following observable behaviors hold, each backed by a named test in `keiro/test/Main.hs`:

1. **Batch-tail kill redelivery** (Test A): with a handler blocked on the tail event of a batch, killing the worker and starting a fresh one drains the category completely — `shardSinkCount` reaches the seeded total. On the pre-change code this same test demonstrably sticks at `total - 1`.
2. **Rebalance under load loses nothing** (Test B): seeding before membership converges and forcing a cold-start shed mid-drain (second worker joins while the first is processing, `batchSize = 1`, slow handler) still ends with every seeded event in the sink. At-least-once is the contract: duplicates may occur (absorbed by the sink's `event_id` primary key) but gaps may not.
3. **Zombie overlap yields duplicates, never loss** (Test C): a non-renewing owner overlapping its successor produces a raw delivery count strictly above the total while the deduplicated sink equals the total; the test's comments document duplicates as expected at-least-once behavior.
4. **Poison events dead-letter with a bounded budget** (Test D): a persistently throwing handler causes exactly `retryMaxAttempts` deliveries of the poisoned event, a row in kiroku's dead-letter table, an uninterrupted drain of the remaining events, and no `ShardReaderDied` report.
5. **Regression suite**: every pre-existing shard test still passes, with the single documented semantic rewrite of the handler-exception test (retry-in-place instead of reader restart); `cabal test keiro-test` and `just haskell-verify` are green.

Interpreting results: an hspec failure prints the failing expectation and the actual value; a timeout in `waitUntilSinkCount` returning `False` in tests A/B is the loss signature. All four new tests use per-example cloned databases, so they cannot contaminate each other.


## Idempotence and Recovery

Every step is safe to repeat. The tests run against per-example database clones created and dropped by `keiro-test-support/src/Keiro/Test/Postgres.hs`, so re-running after a crash leaves no residue (a killed test run can leave `keiro_test_N` clones behind on the cached ephemeral server; they are recreated fresh under new names on the next run and the cached server is disposable — worst case remove the ephemeral-pg cache directory it prints on startup). The code change is a single-module edit plus test additions; if a milestone goes wrong mid-way, `git checkout -- keiro/src/Keiro/Subscription/Shard/Worker.hs keiro/test/Main.hs` returns to the last green commit. No schema migrations, no data migrations, and no kiroku changes are involved. The only semantic risk to production consumers is the intentional one (bounded-retry-then-dead-letter instead of infinite restart), which is why it is stated in the module docs, the Decision Log, and the commit message; rollback is reverting the commit.

Timing-sensitive tests (A–D) must be written to tolerate slow machines: prefer event-driven gates (MVar handshakes, `waitUntilSinkCount`, `waitShardsBalanced`) over bare sleeps, and keep the generous timeouts the existing suite uses (tens of seconds). If Test B proves flaky at demonstrating *pre-fix* loss (a probabilistic window), that is acceptable — its post-fix assertion (no loss) is the deterministic, committed acceptance; the deterministic pre-fix witness is Test A.


## Interfaces and Dependencies

Dependencies (all already present; no `.cabal` or `cabal.project` changes expected): `kiroku-store` pinned at tag `6399844a507a3ea5a3974181b4d8c1380f2f7b5b`, providing `Kiroku.Store.Subscription.Stream` (`subscriptionAckStream`, `AckItem(..)`), `Kiroku.Store.Subscription.Types` (`SubscriptionResult(..)`, `RetryPolicy(..)`, `defaultRetryPolicy`), and the `RetryDelay(..)` / `DeadLetterReason(..)` re-exports; `streamly-core` (`Stream.fold`, `Fold.drainMapM`); `stm` (`putTMVar`, `atomically`). The keiro test suite additionally uses `hasql` statements for the sink/dead-letter queries, as the existing helpers at `keiro/test/Main.hs:8706-8794` already do.

At the end of Milestone 2, `keiro/src/Keiro/Subscription/Shard/Worker.hs` must export, in addition to today's surface:

```haskell
data ShardAck = ShardAckOk | ShardAckRetry !RetryDelay | ShardAckDeadLetter !DeadLetterReason

data ShardDelivery = ShardDelivery
    { event :: !RecordedEvent
    , attempt :: !Word
    , bucket :: !Int
    }

type ShardEventHandler = ShardDelivery -> IO ShardAck

runShardedSubscriptionGroupAck ::
    KirokuStore -> SubscriptionName -> ShardedWorkerOptions -> ShardEventHandler -> IO ()

-- unchanged signature, now a wrapper over the ack variant:
runShardedSubscriptionGroup ::
    KirokuStore -> SubscriptionName -> ShardedWorkerOptions -> (RecordedEvent -> IO ()) -> IO ()

-- changed: handler parameter becomes ShardEventHandler
reconcileShardsOnce ::
    KirokuStore -> ShardLease -> ShardedWorkerOptions ->
    IORef (Map Int RunningReader) -> ShardEventHandler -> IO (Set Int)
```

with `ShardedWorkerOptions` extended by `handlerRetryDelay :: !RetryDelay` and `retryPolicy :: !RetryPolicy`, and `ShardedWorkerConfigError` extended by `InvalidShardHandlerRetryDelay` and `InvalidShardRetryMaxAttempts`. `ShardAck`, `ShardDelivery`, `ShardEventHandler`, and `runShardedSubscriptionGroupAck` together are the contract this plan owes EP-100 (`docs/plans/100-process-manager-failure-paths-dead-lettering-rejected-commands-and-surfacing-retry-exhaustion.md`): EP-100's shard-path dead-letter posture is expressed as a `ShardEventHandler` returning `ShardAckDeadLetter`/`ShardAckRetry` per event, and must not need any further hook from this module.
