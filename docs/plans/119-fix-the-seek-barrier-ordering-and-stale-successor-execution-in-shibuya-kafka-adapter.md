---
id: 119
slug: fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter
title: "Fix the seek-barrier ordering and stale-successor execution in shibuya-kafka-adapter"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
master_plan: "docs/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review.md"
---

# Fix the seek-barrier ordering and stale-successor execution in shibuya-kafka-adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This plan file is checked into the keiro repository (`/Users/shinzui/Keikaku/bokuno/keiro`), but every code change it specifies happens in a different repository: **shibuya-kafka-adapter**, at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. A second repository, **shibuya** (the shibuya-core framework, at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`), is read but never modified. keiro has **no library dependency** on either repository — no keiro `.cabal` file mentions them for the runtime path (keiro's own `keiro-test` suite depends on `shibuya-core` for unrelated reasons, but nothing in keiro links against `shibuya-kafka-adapter`). The coupling is contract and documentation: keiro's integration guide tells deployments to consume Kafka through this adapter, so the adapter's correctness is a keiro production concern. Every command below states its working directory explicitly.

The July 2026 transport review found the adapter's retry path unsound in two verified ways. First (finding KFK-2, HIGH severity, fires on *every* retry that has buffered same-partition successors — no race needed): when a message handler fails and the adapter arranges redelivery, up to 100 already-buffered messages from the same partition still execute their handlers *before* the failed message is redelivered. Their side effects run out of order, and because downstream consumers (keiro's idempotent inbox in particular) deduplicate the later in-order redeliveries, the inversion is committed permanently. Second (finding KFK-1, CRITICAL): when one of those stale buffered successors *itself* fails, its retry bookkeeping overwrites the adapter's "seek barrier" with a *higher* offset and seeks the partition *forward*, past the still-unprocessed failed message. Under realistic conditions (a downstream outage causing consecutive fast failures, plus broker latency or ingest backpressure) the failed message is lost permanently — in the running session *and* across restarts, because Kafka's committed offset has no gap tracking.

After this plan is implemented: a failed record blocks its partition's successors from executing until it has been redelivered and processed (per-partition order is preserved end to end), and no interleaving of retries can move the barrier or the partition position past an unprocessed failed offset. You can see it working by running three new adapter test cases that fail against today's code and pass after the fix, plus the full adapter suite (unit + live-broker integration) staying green.

This plan is child EP-1 of the master plan at `docs/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review.md` (keiro-repo-relative path). Two sibling plans exist and are referenced by path only: `docs/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge.md` (producer side, independent of this plan) and `docs/plans/121-enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs.md` (consumer configuration enforcement and keiro's docs; it consumes this plan's Decision Log and rides or follows this plan's adapter release). Per the master plan's Integration Points, this plan must NOT edit `docs/guides/integration-events-with-kafka.md` or `docs/user/production-status.md` in keiro — those belong exclusively to plan 121. This plan records its externally visible semantics (the new ordering guarantee and the version number) in its own Decision Log for plan 121 to quote.


## Progress

- [ ] Milestone 1: monotone seek barrier — `Map.insertWith min`, barrier-before-delay, seek only when at-or-below the existing barrier — implemented in `Shibuya/Adapter/Kafka/Internal.hs`.
- [ ] Milestone 1: consecutive double-retry test added and passing (barrier stays at the first failed offset; no forward seek).
- [ ] Milestone 1: latching-loss regression test added and passing (failed offset is stored before any successor; barrier clears only via the failed offset's own success).
- [ ] Milestone 2: lock-step emission (finalize-gated source) implemented — `inFlight` gate in `KafkaAdapterState`, finalize-side release in `mkAckHandle`, `lockStep` stream combinator, pipeline rewired in `Shibuya/Adapter/Kafka.hs`.
- [ ] Milestone 2: buffered-successor ordering test (seekable scripted log) added and passing (successor handlers never run while the barrier is below them; redelivered failed record processed first).
- [ ] Milestone 2: emission-blocks-until-finalize test added and passing.
- [ ] Milestone 2: existing `testBarrierSkipsSuccessorStore` re-documented as the storeGuarded backstop for the new contract.
- [ ] Milestone 3: module documentation (`Shibuya/Adapter/Kafka.hs` Message Lifecycle and Serial sections) updated to the new guarantee.
- [ ] Milestone 3: CHANGELOG entry written; version bumped to 0.9.0.0 across the three package `.cabal` files.
- [ ] Milestone 3: full suite green including live-broker integration tests against Redpanda.
- [ ] Milestone 3: master plan Progress checkboxes for EP-1 updated; version recorded for plan 121.

## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Realize the master plan's "processing-time barrier check" as *lock-step emission* (the adapter's source stream emits the next record only after the previous record's finalize has completed), entirely inside shibuya-kafka-adapter, rather than as a pre-handler hook.
  Rationale: shibuya-core offers no interposition point between its bounded inbox and the handler. `Shibuya.Handler.Handler es msg` is a bare function `Message es msg -> Eff es AckDecision`; `processOne` (shibuya-core `src/Shibuya/Internal/Runner/Supervised.hs:559-622`) calls it directly; `Ingested` (shibuya-core `src/Shibuya/Core/Ingested.hs`) carries only `envelope`, `ack`, and `lease` — no gate the adapter could populate. The two alternatives were rejected: (a) adding a pre-handler hook to shibuya-core expands this plan's repository scope beyond what the master plan's Integration Points allocate to EP-1 (adapter only) and forces a coordinated shibuya-core release; (b) exporting a handler-wrapping combinator that callers must remember to apply reproduces exactly the "caller must remember" trap class that sibling plan 121 exists to eliminate. Lock-step makes the pull-time stale check (`dropStaleRecords`) *be* the processing-time check by collapsing the ingest-to-process buffer to at most one unfinalized record, at negligible throughput cost under the adapter's mandatory Serial processing (librdkafka's background fetcher keeps its local queue full regardless of when the adapter polls).
  Date: 2026-07-23

- Decision: In the `AckRetry` branch, set the (monotone) barrier *before* sleeping the retry delay, reversing the current delay-then-insert order.
  Rationale: today `delayRetry` runs first (`Internal.hs:190`) and the barrier insert second, so during a nonzero retry delay the barrier is absent or low and freshly polled successors sail past `dropStaleRecords` into the buffer. With the monotone `insertWith min` the overwrite hazard that the old ordering incidentally mitigated is gone, so barrier-first is strictly safer: stale records polled during the sleep are dropped immediately.
  Date: 2026-07-23

- Decision: Version the release as **0.9.0.0** (breaking position under this repository's 0.X convention), and record that number for plan 121 and keiro's docs.
  Rationale: the retry-path processing contract changes observably (buffered successors no longer execute), `KafkaAdapterState` gains a field (the record constructor is exported), and sibling plan 121's enforcement work is expected to ride the same release with a signature change to `kafkaAdapter`/`kafkaAdapterWith`. The repo's CHANGELOG history (0.7.0.0, 0.8.0.0) bumps the second component for breaking changes.
  Date: 2026-07-23

- Decision: Keep the existing `testBarrierSkipsSuccessorStore` test (`AckHandleTest.hs:108-118`) rather than deleting it, re-titled and re-documented as a backstop test for `storeGuarded`.
  Rationale: under the new contract a stale successor should never reach finalize at all (lock-step prevents it), but `storeGuarded`'s refusal to store above the barrier remains correct defense-in-depth and the test still passes; its comment must stop implying that successor execution is expected behavior.
  Date: 2026-07-23

- Decision: New ordering tests are mock-level (no broker), driving the real pipeline functions against a scripted, seekable in-memory log via the effect interpreter pattern already used by `AckHandleTest`/`AdapterTest`.
  Rationale: the failure interleavings need deterministic control of poll batches and seek behavior; the live-broker integration suite stays as end-to-end confirmation.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The three repositories and how they relate

- `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter` — the repository this plan modifies. It is a cabal multi-package repo (`shibuya-kafka-adapter` the library, `shibuya-kafka-adapter-jitsurei` runnable examples, `shibuya-kafka-adapter-bench` benchmarks), currently version 0.8.0.1, with a `flake.nix` dev shell (enter with `nix develop`) and a `Justfile`. The library test suite runs with `cabal test shibuya-kafka-adapter` from the repo root; its integration tests require a live Redpanda broker at `127.0.0.1:9092` started with `just process-up` in another shell.
- `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` — the shibuya-core framework repository. **Read-only for this plan.** The adapter depends on `shibuya-core ^>=0.8.0.1` from Hackage; the local checkout is for reading the exact code the adapter runs against.
- `/Users/shinzui/Keikaku/bokuno/keiro` — where this plan file lives. No code changes here except updating this plan and the master plan's Progress section. keiro's `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq job telemetry), which is not relevant to this work — no relevant ADR exists. The adapter repository has no `docs/adr/` directory at all (only `docs/masterplans` and `docs/plans`).

### What the adapter is and how a message flows through it

"shibuya" is a queue-processing framework: an *adapter* (here, Kafka) produces a stream of messages, and the framework runs an application *handler* over them, one at a time (this adapter mandates *Serial* processing — see below). Terms used throughout:

- **ConsumerRecord** — hw-kafka-client's polled message: topic, partition, offset, key, value, headers.
- **Ingested** — shibuya-core's framework-side wrapper (`shibuya-core src/Shibuya/Core/Ingested.hs`): an `Envelope` (metadata + payload) plus an `AckHandle` (the adapter-provided finalizer). Handlers receive the reduced `Message` view (envelope only, no ack handle); the framework owns finalization.
- **AckDecision** — the handler's verdict: `AckOk` (done), `AckRetry (RetryDelay d)` (redeliver), `AckDeadLetter`, `AckHalt`.
- **Bounded inbox** — shibuya-core's buffer between its *ingester* thread (which pulls the adapter's stream) and its *processor* thread (which runs handlers). Created at `shibuya-core src/Shibuya/Internal/Runner/Supervised.hs:250` (`newBoundedInbox inboxSize`); default `inboxSize` is 100 (`shibuya-core src/Shibuya/App.hs:153`). It is **one global FIFO per processor**, not per-partition.
- **Offset store vs. commit** — librdkafka separates "store" (mark an offset as ready to commit, in client memory) from "commit" (write to the broker). The adapter uses manual store (`storeOffsetMessage` on `AckOk`) plus auto-commit; the committed value per partition is a single scalar with **no gap tracking** — the adapter's own haddock says so (`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs:39-46`).
- **Seek barrier** — the adapter's per-partition retry bookkeeping: `seekBarrier :: IORef (Map (TopicName, PartitionId) Offset)` inside `KafkaAdapterState` (`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs:59-74`). When a record at offset N gets `AckRetry`, the adapter records N in this map and calls `seekPartitions` back to N so the broker redelivers from N.

The adapter's stream pipeline is assembled in `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs:176-179`:

```haskell
let messageSource =
        ingestedStream (mkIngested state config) $
            dropStaleRecords state $
                kafkaSource state config
```

`kafkaSource` (`Internal.hs:133-154`) polls batches under a shared `consumerLock` (a fair-FIFO `MVar`; every librdkafka call in the adapter takes it, and each call's timeout is capped at `maxPollHoldMillis = 100` ms, `Internal.hs:99-121`). `dropStaleRecords` (`Internal.hs:156-169`) filters out records *above* the barrier (`cr.crOffset <= barrierOff` keeps; strictly greater drops, `Internal.hs:167-169`). `ingestedStream` wraps survivors as `Ingested` values via `mkIngested` (`Internal.hs:267-276`), which pairs the envelope with `mkAckHandle` (`Internal.hs:180-213`).

`mkAckHandle`'s `AckRetry` branch today (`Internal.hs:189-203`) does, in order: (1) `delayRetry delay` — sleep; (2) `atomicModifyIORef' state.seekBarrier` with a plain `Map.insert (partitionKey cr) cr.crOffset` (`Internal.hs:191-193`) — an insert that overwrites in **both** directions; (3) `seekPartitions` back to `cr.crOffset`. The `AckOk` and `AckDeadLetter` branches call `storeGuarded` (`Internal.hs:239-253`), which consults the barrier: no barrier → store; `crOffset <= barrier` → **delete the barrier and store** (`Internal.hs:250-251`); `crOffset > barrier` → suppress the store.

On the framework side, `processOne` (`shibuya-core src/Shibuya/Internal/Runner/Supervised.hs:559-622`) invokes the handler **unconditionally** for every inbox record; a handler *exception* is substituted with `AckRetry (RetryDelay 0)` (`Supervised.hs:609-613`) so the adapter always sees a finalization. The barrier is consulted only at finalize (`storeGuarded`), which suppresses the offset store — it never prevents handler execution. The KeyedScheduler (per-partition scheduling in shibuya-core) is not in play: it engages only for `PartitionedInOrder` with `Ahead`/`Async` concurrency (`Supervised.hs:513-520`), and this adapter mandates Serial (`Kafka.hs:39-46`); under Serial the processor is a plain `Stream.mapM processAction` over the global inbox FIFO (`Supervised.hs:514-516`).

### Finding KFK-2 — stale successors execute their handlers (HIGH, adversarially confirmed, no race needed)

The stale filter (`dropStaleRecords`) runs at ingest-pull time, **upstream of the bounded inbox**. Records polled *before* a failure are already sitting in the inbox when the failure's finalize sets the barrier. Concretely: partition P delivers offsets 42, 43, ..., 142 (one poll batch of 100 fills the inbox); the handler fails on 42; finalize sets the barrier to 42 and seeks P back to 42. But 43..142 are already buffered past the filter. `processOne` runs the handler for each of them — their effects execute *before* 42 is redelivered. Their `AckOk` finalizes hit `storeGuarded`, which suppresses their stores (43 > barrier 42) — the *offsets* are protected, but the *effects already ran out of order*. When the seek's fresh in-order copies of 43..142 arrive, `dropStaleRecords` drops them (43 > 42 while the barrier stands... precisely: after redelivered 42 succeeds, `storeGuarded` deletes the barrier, and the *stale* copies were the ones processed; the fresh copies of 43..142 polled after the seek are dropped by the filter only while the barrier stands — the surviving redelivered copies dedupe downstream). With keiro's idempotent inbox as the handler, the in-order redeliveries return `InboxDuplicate` without re-running effects. Either way the inversion is permanent. The adapter's own test suite *encodes* this behavior as expected: `test/Shibuya/Adapter/Kafka/AckHandleTest.hs:108-118` (`testBarrierSkipsSuccessorStore`) finalizes offset 43 with `AckOk` between the retry of 42 and 42's redelivery, asserting only that 43's *store* is suppressed.

### Finding KFK-1 — a stale successor's own retry seeks forward and latches loss (CRITICAL)

Now let one of those buffered stale successors fail. Timeline: 42 fails → barrier := 42, seek to 42. Buffered stale 43 runs (KFK-2) and *also* fails — the common mode is a downstream outage, where every handler throws and `processOne` substitutes `AckRetry (RetryDelay 0)` (`Supervised.hs:609-613`), so there is no sleep. 43's `AckRetry` branch executes: `Map.insert` **overwrites** the barrier 42 → 43, then seeks P **forward** to 43, past unprocessed 42. `seekPartitions` is a thin binding to `rd_kafka_seek_partitions` (hw-kafka-client `src/Kafka/Consumer.hs:299-303`; kafka-effectful passes it straight through) — it repositions the fetcher and purges librdkafka's pre-fetched undelivered queue, but it cannot touch records already delivered into the app.

The loss latches when the fresh copy of 42 (from the first seek) is never fetched between the two seeks. Two verified interleavings: (i) the single poll that can interpose between the two finalizes (the `consumerLock` is a fair-FIFO `MVar`, and each poll holds it at most `maxPollHoldMillis` = 100 ms, `Internal.hs:113-121`) comes back empty, because 42 must round-trip from the broker within 100 ms — broker throttling or cross-DC latency defeats that; (ii) *zero* polls interpose because the ingester is blocked pushing into the full inbox (backpressure), not waiting on the lock. Once the partition position has passed 42 with both copies extinguished, recovery is impossible: the barrier (now 43) can only be *lowered* by an `AckRetry` from an offset ≤ 42, and no such record exists anymore. When redelivered 43 eventually succeeds, `storeGuarded` sees 43 ≤ barrier 43, **deletes the barrier and stores 43** (`Internal.hs:250-251`); auto-commit commits 44; 42 is lost in-session *and* across restart (no gap tracking). Note which paths are exposed: keiro's decision-returning handlers use 1–5 s retry delays, and because `delayRetry` currently runs *before* the barrier insert, the barrier stays low during the sleep, giving the fresh 42 time to arrive — an accidental mitigation. Exception-throwing handlers get `RetryDelay 0` and no such protection. The adapter suite has **no test** for consecutive double retries.

### The fix (per the master plan's Decision Log — one mechanism closes both)

1. **Monotone barrier, never seek forward (KFK-1).** In the `AckRetry` branch replace the plain `Map.insert` with `Map.insertWith min`, and seek only when this record's offset is at or below any existing barrier (i.e. only when it establishes or re-establishes the minimum). A stale successor's retry then neither raises the barrier nor moves the partition position forward.
2. **Lock-step emission (KFK-2).** Gate the adapter's source so that at most one unfinalized record is in flight between the adapter and the framework: the stream waits for the previous record's finalize before pulling the next record through `dropStaleRecords`. Pull time then *is* processing time — a successor cannot be evaluated against the barrier until the record ahead of it has finalized (and possibly set that barrier), so stale successors are dropped before they ever reach the inbox, their handlers never run, and the redelivered failed record is the next thing processed. See the Decision Log for why this is the adapter-local realization of the master plan's "processing-time barrier check" (shibuya-core has no pre-handler hook).

### Verified sound — do not regress

The review confirmed these behaviors correct; the milestones must leave them intact and the full suite proves it: store-only-on-`AckOk` ordering relative to downstream inbox commit; `commitAllOffsets` on shutdown (`Kafka.hs:184-190`) including the ignored `RdKafkaRespErrNoOffset`; consumer-lock serialization with 100 ms bounded holds (`Internal.hs:99-121` — the SIGSEGV rationale in the `consumerLock` haddock is real, do not weaken it); the fatal/transient error taxonomy (`ackAttempt`/`recordFatalError`, `Internal.hs:215-237`, and `skipNonFatal`/`isFatal` from hw-kafka-streamly); verbatim header pass-through (landed in 0.7.0.0, commit 424a4c2) with its `ConvertTest.hs:91-99` pinning; and rebalance barrier clearing (`kafkaRebalanceHandler`, `Kafka.hs:217-233`).


## Plan of Work

### Milestone 1 — monotone barrier and no forward seek (closes KFK-1)

Scope: `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, `AckRetry` branch of `mkAckHandle`, plus two new mock-level tests. At the end of this milestone, no sequence of `AckRetry` finalizes can raise the barrier or seek forward, and two tests that fail against 0.8.0.1 pass. This milestone is independently verifiable without the lock-step work.

Rewrite the `AckRetry` branch (`Internal.hs:189-203`) to this order and content: first update the barrier monotonically and learn whether this record owns the minimum; then sleep the retry delay; then seek only if it owns the minimum. Concretely, replace the branch body with:

```haskell
AckRetry (RetryDelay delay) -> do
    shouldSeek <-
        Effectful.liftIO $
            atomicModifyIORef' state.seekBarrier $ \barriers ->
                let existing = Map.lookup (partitionKey cr) barriers
                    barriers' = Map.insertWith min (partitionKey cr) cr.crOffset barriers
                 in (barriers', maybe True (cr.crOffset <=) existing)
    Effectful.liftIO $ delayRetry delay
    if shouldSeek
        then
            ackAttempt state $
                withConsumerLock state $
                    seekPartitions
                        [ TopicPartition
                            { tpTopicName = cr.crTopic
                            , tpPartition = cr.crPartition
                            , tpOffset = PartitionOffset (unOffset cr.crOffset)
                            }
                        ]
                        (boundedLockTimeout config.pollTimeout)
        else pure ()
```

Semantics to preserve exactly: `shouldSeek` is `True` when there was no barrier (fresh failure — must seek, as `testAckRetrySeeks` asserts) or when this offset is ≤ the existing barrier (a *lower* failure, or the same record failing again — re-establish the seek). It is `False` precisely when a stale successor (offset > barrier) retries: barrier unchanged, no seek, no forward movement. The barrier is now visible *before* the retry sleep (see Decision Log entry two). Update the `mkAckHandle` haddock (`Internal.hs:171-179`) to say: "`AckRetry` → monotonically lower (never raise) the per-partition seek barrier and seek back to the failed offset only when this record is at or below the current barrier; a stale successor's retry is a no-op on both barrier and position."

Add two test cases to `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/AckHandleTest.hs`, using its existing mock consumer (`runFinalizer`, `finalizeRecord`, `recordAt`, `MockState.seekCalls`):

- `testConsecutiveDoubleRetryKeepsBarrier` — finalize `recordAt 42` with `AckRetry (RetryDelay 0)`, then finalize `recordAt 43` with `AckRetry (RetryDelay 0)` (the stale successor failing). Read `state.seekBarrier` directly (import `readIORef`; the map is keyed by `(TopicName "orders", PartitionId 0)`) and assert the barrier is `Offset 42`. Assert `seekCalls` contains exactly one seek, to `PartitionOffset 42` — no seek to 43. Against 0.8.0.1 this fails on both assertions (barrier 43; two seeks, the second to 43). This is the KFK-1 regression test.
- `testLatchingLossRegression` — drive the `storeGuarded`-clear path that latched the loss: finalize 42 `AckRetry 0`; finalize 43 `AckRetry 0`; then finalize `recordAt 42` with `AckOk` (the redelivered failed record) and assert `storeAttempts == 1` and the barrier map is now empty (42 ≤ 42 stores and deletes); then finalize `recordAt 43` with `AckOk` and assert `storeAttempts == 2`. The invariant proven: 42 is stored before 43, and the barrier is cleared only by the failed offset's own success. Against 0.8.0.1 the sequence instead stores 43 first (43 ≤ overwritten barrier 43) with 42 never stored.

Register both in the module's `tests` list. Acceptance: from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`, `cabal test shibuya-kafka-adapter --test-options='-p "AckHandle"'` passes with the new cases listed; with the source change temporarily reverted (`git stash -- shibuya-kafka-adapter/src`) the two new cases fail.

### Milestone 2 — lock-step emission (closes KFK-2)

Scope: `Internal.hs` (state field, ack-handle release, new stream combinator), `Kafka.hs` (pipeline wiring), and a new mock-level test module with a seekable scripted log. At the end, the adapter never hands the framework a record while an earlier record is unfinalized, so a retry's barrier is always consulted for successors *before* their handlers can run; two new tests prove it.

Work items, in order:

1. Add an in-flight gate to `KafkaAdapterState` (`Internal.hs:59-74`): a field `inFlight :: !(TVar Bool)` (`False` = idle). Initialize with `newTVarIO False` in `newKafkaAdapterState`. Document it: "True while a record emitted by the lock-step source has not yet completed its finalize. The source refuses to emit the next record until this returns to False, so at most one unfinalized record exists between adapter and framework; this is what makes the pull-time stale check in `dropStaleRecords` a processing-time check."
2. Release the gate at finalize completion in `mkAckHandle`: wrap the entire decision dispatch so that *every* branch — including all `ackAttempt` outcomes and the fatal-slot path — ends by resetting the gate. Use `Effectful.Exception.finally` (already imported qualified as `Exception`):

   ```haskell
   mkAckHandle state config cr = AckHandle $ \decision ->
       dispatch decision `Exception.finally` releaseInFlight
     where
       releaseInFlight =
           Effectful.liftIO $ atomically $ writeTVar state.inFlight False
       dispatch = \case
           AckOk -> ...            -- existing branches unchanged
   ```

   `ackAttempt` already swallows `KafkaError`s into the fatal slot, so `finally` fires on the ordinary return path; it additionally covers async exceptions during shutdown.
3. Add the combinator to `Internal.hs` (export it from the module's Stream Construction group):

   ```haskell
   -- | Emit at most one unfinalized record: wait until the previous record's
   -- finalize has released the in-flight gate (or shutdown/fatal is flagged)
   -- BEFORE pulling the next record from upstream, then mark it in flight.
   -- Pulling after the wait is what lets 'dropStaleRecords' observe any
   -- barrier the previous finalize installed.
   lockStep ::
       (IOE :> es) =>
       KafkaAdapterState ->
       Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))) ->
       Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
   ```

   Implementation shape: `Stream.mapM` is not enough (the wait must precede the upstream *pull*), so implement with `Stream.unfoldrM` over `Stream.uncons` of the upstream, or wrap the upstream with a pre-pull action — the essential loop is: (a) `atomically $ do { busy <- readTVar state.inFlight; shut <- readTVar state.shutdownVar; if busy && not shut then retry else pure () }` — also read `state.fatalError` via a pre-check outside STM (it is an `IORef`; check it before the STM wait and again after, matching `kafkaSource`'s own step which terminates on the fatal slot); (b) pull one element from upstream; (c) for a `Right` record, `atomically $ writeTVar state.inFlight True` before yielding; `Left` errors pass through without touching the gate (they terminate the stream downstream in `ingestedStream`). The shutdown escape means a record that is never finalized (halt path with the processor stopped) cannot wedge the ingester: `adapter.shutdown` sets `shutdownVar`, the wait unblocks, the next `kafkaSource` step observes shutdown and ends the stream.
4. Rewire the pipeline in `Kafka.hs:176-179`:

   ```haskell
   let messageSource =
           ingestedStream (mkIngested state config) $
               lockStep state $
                   dropStaleRecords state $
                       kafkaSource state config
   ```

   Order matters and must be documented at the wiring site: the stale filter sits *upstream* of the gate so that each record is tested against the barrier at the moment it is released for processing, not at poll time. (A record dropped by the filter never touches the gate.)
5. New test module `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/LockStepTest.hs`, registered in `test/Main.hs`. Build a scripted, seekable mock consumer in the style of `AckHandleTest`'s `runMockConsumer` but with a stateful log: an `IORef` holding `(records :: [ConsumerRecord ...], position :: Int)`; `PollMessageBatch` returns the next `batchSize` records from `position` (empty when exhausted); `SeekPartitions [tp] _` resets `position` to the index of the requested offset; `StoreOffsetMessage` appends to a store list. Two test cases:
   - `testSuccessorsWaitForFailedRecord` — log holds offsets 42, 43, 44 in partition 0; drive the full production pipeline (`ingestedStream (mkIngested state config) $ lockStep state $ dropStaleRecords state $ kafkaSource state config`) with a driver that folds the stream, simulating Serial processing: for each `Ingested`, record the envelope's offset in a `processedOrder` list, decide via a script (42 fails the first time with `AckRetry (RetryDelay 0)`, everything else `AckOk`), and invoke the ack handle with that decision before demanding the next element (that is exactly what `Stream.mapM` + `Stream.fold Fold.drain` gives you). Set `shutdownVar` when 44 has succeeded so the source ends. Assert `processedOrder == [42, 42, 43, 44]` — the stale buffered copies of 43/44 (which the mock poll returned in 42's first batch) never reached the driver, because the gate held them upstream until 42's `AckRetry` finalize installed the barrier, after which `dropStaleRecords` dropped them and the seek replayed the log from 42. Against 0.8.0.1-wiring (no `lockStep`) the observed order is `[42, 43, 44, 42, ...]` — the KFK-2 inversion.
   - `testEmissionBlocksUntilFinalize` — prove the gate actually blocks: pull the first `Ingested` from the pipeline (via `Stream.uncons`), do *not* finalize it, and attempt to pull the second under `System.Timeout.timeout 100000` from a separate driver step; assert the timeout fires (`Nothing`). Then finalize the first with `AckOk` and assert the second pull yields offset 43 promptly. Run the two pulls in one Eff thread with the timeout wrapping only the second uncons (the gate wait is in STM `retry`, which `timeout` interrupts cleanly).
6. Re-document `testBarrierSkipsSuccessorStore` in `AckHandleTest.hs` (keep the assertions): retitle to "storeGuarded backstop: stale successor finalize does not store", with a comment stating that under lock-step a stale successor never reaches finalize in production and this guard is defense-in-depth.

Acceptance: `cabal test shibuya-kafka-adapter --test-options='-p "LockStep"'` passes both cases; reverting only the `Kafka.hs` wiring makes `testSuccessorsWaitForFailedRecord` fail with the inverted order in its message. `-p "AckHandle"` still passes.

### Milestone 3 — documentation, version, release, full-suite proof

Scope: adapter haddocks, CHANGELOG, version bump, live-broker run, and the cross-plan bookkeeping. At the end, the adapter describes its new guarantee, is releasable as 0.9.0.0, and the whole suite (including the pre-existing 10 integration cases against Redpanda) is green.

1. `Shibuya/Adapter/Kafka.hs` module haddock: in "Message Lifecycle", change step 4 to state the new contract: "On `AckRetry`, the offset is not stored; the adapter monotonically records the lowest failed offset per partition, seeks back to it, and *withholds all later records of every partition from processing until the failed record has been redelivered and finalized* (the source emits lock-step with finalization, so successors buffered behind a failure neither execute handlers nor store offsets)." In "Serial Operation Required", add that lock-step emission additionally bounds in-flight records to one, and that the section's caller contract (no `Async`/`Ahead`) is unchanged. In the "Rebalance Callback Helper" section, keep the barrier-clearing description (unchanged behavior).
2. `CHANGELOG.md` (adapter package dir `shibuya-kafka-adapter/CHANGELOG.md`), new top section following the house style (`## 0.9.0.0 — <date>` with "Breaking Changes" / "Bug Fixes" subsections):

   ```markdown
   ## 0.9.0.0 — 2026-07-XX

   ### Breaking Changes

   - Retry semantics: after an `AckRetry`, records buffered behind the failed
     offset are no longer handed to the handler; the source now emits lock-step
     with finalization, so per-partition processing order is preserved across
     retries. `KafkaAdapterState` gains an `inFlight` field.

   ### Bug Fixes

   - A stale successor's own `AckRetry` no longer overwrites the seek barrier
     upward or seeks the partition forward past an unprocessed failed offset
     (the barrier is monotone: `Map.insertWith min`; forward seeks on retry are
     suppressed). This closes a permanent-message-loss window under
     consecutive fast failures.
   ```

3. Bump `version:` to `0.9.0.0` in all three cabal files (`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`, `shibuya-kafka-adapter-jitsurei/...cabal`, `shibuya-kafka-adapter-bench/...cabal` — the repo keeps them on a shared version line per its CHANGELOG convention) and adjust the jitsurei/bench `build-depends` on the library accordingly.
4. Full suite against a live broker (commands in Concrete Steps). All pre-existing integration cases must pass unchanged — they exercise happy-path consumption, multi-partition, and retry-redelivery; the retry-redelivery one now implicitly also validates lock-step under a real broker.
5. Record for the siblings: this plan's Decision Log already fixes the version (0.9.0.0) and the ordering guarantee wording; update the master plan's two EP-1 Progress checkboxes (`docs/masterplans/18-...md` in the keiro repo) and this plan's own Progress section. Plan 121 (path above) reads the version from here; keiro consumes the adapter **via documentation only** (no library dependency), so no keiro build metadata changes.

Do not publish to Hackage as part of this plan unless the user asks; "releasable" (version, changelog, green suite) is the deliverable, and plan 121 decides whether its enforcement change rides 0.9.0.0 or cuts 0.10.0.0 next.


## Concrete Steps

All adapter commands run from the adapter repo root. Enter the dev shell first — it provides GHC 9.12.4, cabal, and librdkafka:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
nix develop
```

Build and run unit-level tests (no broker needed — excludes the Integration group by tasty pattern):

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
cabal build all
cabal test shibuya-kafka-adapter --test-options='-p "!/Integration/"'
```

Expected tail of a passing unit run (counts grow as milestones add cases; the shape is what matters):

```text
  AckHandle
    consecutive double retry keeps barrier and does not seek forward: OK
    latching-loss regression: failed offset stores first and clears barrier:  OK
  LockStep
    successors wait for failed record: OK
    emission blocks until finalize:    OK
All N tests passed
```

Run a single group while iterating:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
cabal test shibuya-kafka-adapter --test-options='-p "AckHandle"'
cabal test shibuya-kafka-adapter --test-options='-p "LockStep"'
```

Full suite including integration tests — needs Redpanda on `127.0.0.1:9092`. In a second terminal:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
nix develop
just process-up
```

then in the first terminal:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
just create-topics
cabal test shibuya-kafka-adapter
```

Expected: `All N tests passed` with the Integration group included. When done: `just process-down`.

To demonstrate a new test failing against the old code (evidence for the plan's living sections), stash only the source change and rerun the pattern:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
git stash push -- shibuya-kafka-adapter/src
cabal test shibuya-kafka-adapter --test-options='-p "AckHandle"' ; git stash pop
```

Commit per milestone in the adapter repo (Conventional Commits), e.g. `fix(retry)!: monotone seek barrier; never seek forward on a stale successor retry` and `fix(ordering)!: lock-step source emission so buffered successors cannot run before a failed record`. Update this plan file (in the keiro repo) and the master plan's Progress at each stopping point; commit those in the keiro repo separately (`docs(plans): ...`).


## Validation and Acceptance

Acceptance is behavioral, per milestone:

- Milestone 1: with only the `Internal.hs` barrier change, `testConsecutiveDoubleRetryKeepsBarrier` proves that after 42-fails-then-43-fails the barrier reads `Offset 42` and exactly one seek (to 42) was issued; `testLatchingLossRegression` proves 42 stores before 43 and clears the barrier itself. Both demonstrably fail against the unmodified source (run the stash transcript above; expected failure text: `expected: Offset 42` / `but got: Offset 43`, and a `seekCalls` list containing `PartitionOffset 43`).
- Milestone 2: `testSuccessorsWaitForFailedRecord` proves handler-visible order `[42, 42, 43, 44]` under a mid-batch failure (the first element is 42's failing attempt, the second its redelivered success); `testEmissionBlocksUntilFinalize` proves the gate blocks a second emission until finalize and releases promptly after. Reverting only the `Kafka.hs` pipeline wiring flips the first test's observed order to start `[42, 43, 44, ...]`.
- Milestone 3: full suite (unit + Integration against Redpanda) passes; `grep -n "0.9.0.0" shibuya-kafka-adapter/CHANGELOG.md` shows the new entry; the three cabal files carry `version: 0.9.0.0`.
- Regression guard: every pre-existing test in `AckHandleTest`, `AdapterTest`, `ConvertTest`, and `IntegrationTest` passes unmodified except `testBarrierSkipsSuccessorStore`, whose assertions are unchanged but whose title/comment now describe the backstop role.


## Idempotence and Recovery

All steps are ordinary source edits plus test runs — safe to repeat. The milestones are independent enough to recover from partial work: milestone 1's barrier change stands alone (it closes KFK-1 even if milestone 2 stalls), and the plan's Progress section must record any such split. If the lock-step combinator dead-ends (e.g., an unforeseen streamly interaction), the recovery path is: keep milestone 1, mark the gate work as blocked in Progress, record the obstacle in Surprises & Discoveries, and re-plan the KFK-2 mechanism in the Decision Log *before* writing more code — do not ship a partial gate, since a gate that sometimes releases early is strictly worse than the documented status quo. No destructive operations exist in this plan; there is no migration and no data at risk in development. Redpanda state from integration runs is disposable (`just process-down`, `just delete-topics`).


## Interfaces and Dependencies

Languages/tools: Haskell (GHC 9.12.4 via the adapter repo's `nix develop`), cabal, tasty/tasty-hunit (existing test deps), streamly 0.11 / streamly-core 0.3 (existing), `stm` (existing dep of the library). No new dependencies are added to any cabal file except possibly `stm` in the test stanza if not already transitively present (the library already depends on `stm ^>=2.5`).

At the end of milestone 2 the following must exist with these exact names and module paths in the `shibuya-kafka-adapter` library:

- `Shibuya.Adapter.Kafka.Internal.KafkaAdapterState` gains `inFlight :: !(TVar Bool)`; `newKafkaAdapterState` initializes it to `False`.
- `Shibuya.Adapter.Kafka.Internal.lockStep :: (IOE :> es) => KafkaAdapterState -> Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))) -> Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))`, exported.
- `Shibuya.Adapter.Kafka.kafkaAdapterWith` wires `ingestedStream . lockStep state . dropStaleRecords state . kafkaSource state` (public signatures of `kafkaAdapter`/`kafkaAdapterWith` unchanged in this plan; plan 121 may change them for config enforcement).
- The `AckRetry` branch of `Shibuya.Adapter.Kafka.Internal.mkAckHandle` uses `Map.insertWith min` and the `shouldSeek` guard as specified in milestone 1; all finalize branches release `inFlight` via `finally`.

Upstream interfaces relied on (read, not modified): shibuya-core 0.8.0.1 `Shibuya.Adapter.Adapter` record (`adapterName`/`source`/`shutdown`), `Shibuya.Core.AckHandle.AckHandle`, `Shibuya.Core.Ingested.mkIngested`; hw-kafka-client ≥5.3 `seekPartitions`, `storeOffsetMessage`, `pollMessageBatch` via the `kafka-effectful ^>=0.3` `KafkaConsumer` effect (`Kafka.Effectful.Consumer.Effect`). The sibling plan `docs/plans/120-...md` changes `kafka-effectful`'s *producer* side only — no interface overlap with this plan.
