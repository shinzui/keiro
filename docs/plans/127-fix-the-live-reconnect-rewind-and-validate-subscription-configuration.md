---
id: 127
slug: fix-the-live-reconnect-rewind-and-validate-subscription-configuration
title: "Fix the live-reconnect rewind and validate subscription configuration"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
---

# Fix the live-reconnect rewind and validate subscription configuration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

kiroku is the PostgreSQL event store at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (all kiroku paths below are relative to it; keiro paths are relative to this repository, `/Users/shinzui/Keikaku/bokuno/keiro`). Its subscription worker delivers events to handlers, first catching up from a durable checkpoint, then going "live". This plan fixes four confirmed robustness defects in that machinery — findings KRS-2, KRS-6, KRS-4, and KRS-5 of the parent master plan (`docs/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md`):

- KRS-2 (MEDIUM): a live subscription that hits one transient database error during a live fetch rewinds to the cursor it ENTERED live mode with and re-delivers everything processed since — unbounded re-delivery after hours of live progress. keiro's shard readers use exactly this live path and eat the burst.
- KRS-6: `batchSize` is never validated. Zero silently stalls category/consumer-group subscriptions forever while they report `Live`; on the non-group AllStreams path zero causes PERMANENT LOSS of the catch-up gap (mechanism below). Negative values produce a perpetual reconnect loop.
- KRS-4 (LOW/MEDIUM): a checkpoint row records only a position, not what it is a position INTO. Retargeting a subscription name (say `Category "orders"` to `Category "payments"`) silently resumes at the old global position, skipping the new target's history.
- KRS-5 (LOW): a user-supplied `decodeHook` that throws wedges the shared event publisher in a silent retry-forever loop, stalling every AllStreams subscriber while everything reports `Live`.

After this plan: a live reconnect resumes from real progress (a test that fails today proves it); `subscribe` rejects `batchSize < 1` at call time with a typed error; a checkpoint is bound to its target and a retarget is refused loudly with a documented override; and a throwing `decodeHook` crashes the publisher loudly with a typed observability event instead of spinning silently.


## Progress

- [ ] M1: `ConnectionLost` FSM input carries the live position; `liveExitToInput` reads `posRef`; reconnect-after-progress test added to `kiroku-store/test/Test/SubscriptionReconnect.hs` (fails against unmodified code, passes after).
- [ ] M2: `InvalidBatchSize` typed error; `subscribe` validates `batchSize >= 1`; tests for 0 and negative.
- [ ] M3: checkpoint bound to target via `stream_name`; migration `0009` (sentinel backfill) written and recorded in the master plan's Integration Points; `SubscriptionTargetMismatch` typed error + documented override; tests.
- [ ] M4: `decodeHook` must-not-throw contract documented; publisher fails loudly on a throwing hook (typed event + thread crash); poison-hook test.
- [ ] Living sections updated; ADR distillation pass done.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix KRS-2 by carrying the position on the error exit (`ConnectionLost` gains a `GlobalPosition` field), mirroring the `HandlerStopped` shape, rather than having the FSM's `Live` state track per-batch progress for the DB-driven paths.
  Rationale: The DB-driven live loops deliberately run to a terminal exit without feeding the FSM per batch (their internal cursor + `posRef` are the progress record); teaching the FSM about per-batch live progress would restructure the loop/driver seam for no additional safety, while the exit already has one sibling (`LiveHandlerStopped`) that reads `posRef` — symmetry is the smallest correct fix.
  Date: 2026-07-23

- Decision: KRS-5 resolves as CRASH, not skip: a throwing `decodeHook` kills the publisher thread after emitting a typed event.
  Rationale: Skipping the batch would silently lose events for every AllStreams subscriber (the hook is the only transform applied; there is no per-event fallback), violating at-least-once. Crashing preserves at-least-once (a restarted publisher re-fetches from `lastPublished`) and matches the worker-side behavior, where the same hook throwing during a catch-up fetch already kills the worker loudly. Resolution of the master plan's "decide skip-vs-crash" open point.
  Date: 2026-07-23

- Decision: KRS-4 target binding uses the existing `stream_name` column with a `'$legacy'` sentinel backfill migration; encoding: `'$all'` for AllStreams, `'$category-<name>'` for categories.
  Rationale: The master plan directs using the existing column. But every existing row holds the DEFAULT `'$all'` regardless of true target (the column was never written), so `'$all'` cannot mean "AllStreams" for pre-existing rows without silently blessing retargets in both directions. A one-statement migration rewriting existing rows to `'$legacy'` makes the ambiguity explicit: `'$legacy'` rows are adopted (bound on first save), anything else must match exactly. This plan claims migration number 0009 (next free after `0008-schema-management-comment.sql`) — record the claim in the master plan's Integration Points when landing, and coordinate with plan 126, which owns `subscriptions`-table schema changes but, as planned, needs no migration of its own.
  Date: 2026-07-23

- Decision: Validation for `batchSize` happens in `subscribe` only (throw, like `InvalidConsumerGroup`), not defensively in `fetchBatch`.
  Rationale: One authoritative gate at construction keeps the hot fetch path branch-free, matches the existing group-bounds precedent (`Subscription.hs:113-119`), and catches the misconfiguration before any thread or DB work exists.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All code edits in this plan are in the kiroku repo (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`; ignore `dist-newstyle`). No keiro-side code changes — keiro benefits by consuming the next kiroku release (see the release note at the end).

ADR context: keiro's `docs/adr/` contains only `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq telemetry — not relevant to this plan). The kiroku repo's ADRs (0001 stream-name resolution, 0002 consumer groups, 0003 dedicated schema) are background; none covers the subscription worker's reconnect or validation behavior. No relevant ADR exists for this work.

Sibling plans: 125 (write path — owns all `Error.hs` taxonomy changes; this plan adds no `StoreError` constructors, only subscription-local exception types), 126 (consumer-group resize — ALSO edits `Subscription/Worker.hs` and the same checkpoint SQL statements; the functions are disjoint — 126 touches checkpoint load/save persistence of the group size, this plan touches the live-exit mapping, subscribe validation, and the checkpoint's `stream_name` binding; whichever lands second rebases the shared `saveCheckpointMemberSQL`/`getCheckpointMemberSQL`/`insertDeadLetterAndCheckpointSQL` statements mechanically), 128 (adapter).

### The subscription worker in one paragraph

`subscribe` (`kiroku-store/src/Kiroku/Store/Subscription.hs:112-137`) validates config, picks a "live source" for the target, and starts `runWorker` (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:200`). The worker loads its checkpoint once at startup (Worker.hs:212, `loadCheckpoint` at 443-461), then drives a pure finite-state machine (FSM, `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`, transition function `step` at 304-344) through states `CatchingUp` -> `Live` -> (`Paused` | `Reconnecting` | `Stopped`). Catch-up fetches batches from SQL (`fetchBatch`, Worker.hs:597-631) until it reaches the publisher's position, then goes live. There are three live mechanisms: non-group AllStreams reads a queue fed by the shared EventPublisher (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`), non-group Category runs a NOTIFY-driven loop (`liveLoopCategoryNotify`, Worker.hs:500-535), and consumer-group members run a polling loop (`liveLoopDbDriven`, Worker.hs:564-592). The worker maintains `posRef :: IORef GlobalPosition` — the last position it truly processed — written at Worker.hs:504, 568 (loop entries), 681, 687 (per event/batch in `processEvents`). Checkpoints are saved per batch tail (`processEvents` at Worker.hs:678-682: `newPos = globalPosition lastEvent; saveCheckpoint`), with `GREATEST` monotonicity in SQL (`saveCheckpointMemberSQL`, `kiroku-store/src/Kiroku/Store/SQL.hs:1243-1250`), so a checkpoint can never regress — which is why KRS-2 causes re-DELIVERY, not checkpoint corruption.

### KRS-2 mechanics (verified line by line)

The two DB-driven live loops run to a terminal exit; during the ENTIRE live period the FSM receives no input for them. So the FSM's `Live c` cursor `c` is frozen at the value it had when catch-up finished (`step` produces `Live c` from `FetchEmpty`/`CaughtUp` at Fsm.hs:308-310 and never updates it again on these paths — only `BatchFetched` at Fsm.hs:318 advances it, and that input is only produced by the queue-fed AllStreams path). The loops' real progress lives in their internal cursor and `posRef`. When a live fetch fails, the loop exits with `LiveFetchError err`, and `liveExitToInput` (Worker.hs:371-373) maps it to `ConnectionLost err` WITHOUT reading `posRef` — note the asymmetry: the `LiveHandlerStopped` sibling on line 372 DOES read `posRef`. The FSM then transitions `step (Live c) (ConnectionLost _) = Reconnecting c 1` (Fsm.hs:326) — with the stale `c`. The `Reconnecting` handler rewinds `posRef` to `c` and fetches from `c` (Worker.hs:317-319). `loadCheckpoint` is not consulted (startup-only, Worker.hs:212), so even the durable checkpoint — which is AHEAD, at the last batch tail — is ignored. Everything since live entry is re-fetched and re-delivered. The queue-fed AllStreams path is unaffected (its `Live` cursor advances per batch via `BatchFetched`, and it performs no live fetch of its own). `GREATEST` prevents checkpoint regression, so the damage is bounded to re-delivery — but unbounded in volume. keiro's shard readers are consumer-group members (`LiveFromGroupPolling`), squarely on the broken path; a process RESTART recovers better than a reconnect does, which is absurd. The existing regression test (`kiroku-store/test/Test/SubscriptionReconnect.hs`) faults at ZERO live progress — the store is empty at catch-up, so live-entry cursor equals real progress equals 0 and the rewind is invisible; that is why this bug survived it.

### KRS-6 mechanics (verified)

`subscribe` validates only the consumer group (`Subscription.hs:113-119`). `batchSize` (default 100, `kiroku-store/src/Kiroku/Store/Subscription/Types.hs:342`) flows unchecked into every fetch LIMIT (`fetchBatch` passes it at Worker.hs:612 and siblings; e.g. `readAllForwardSQL`'s `LIMIT $2` at SQL.hs:560). With `batchSize = 0`: category/group paths fetch LIMIT 0 forever — the drain loops (Worker.hs:523-530 and 575-587) see an empty batch, conclude "drained", and re-block on their gates; state reports `Live`; nothing is ever delivered. Worse, the non-group AllStreams path LOSES data: catch-up's `nextInput` (Worker.hs:261-272) compares the checkpoint against the publisher position (`pubPos`, seeded from the `$all` tail at EventPublisher.hs:156-158) — with a stale checkpoint it fetches LIMIT 0, gets nothing, and declares `CaughtUp` instantly at the stale position (Worker.hs:271); live delivery is then fed by the PUBLISHER's own batches (its batch size is 1000, EventPublisher.hs:118-119), the stale filter at Worker.hs:288 is only a lower bound (`> c` drops nothing new), and `processEvents` checkpoints at the delivered live batch tail (Worker.hs:678-682) — jumping the durable checkpoint PAST the never-fetched catch-up gap. Permanent loss, not just a stall. A negative `batchSize` makes PostgreSQL reject the LIMIT, so every fetch fails and the worker loops in `Reconnecting` forever.

### KRS-4 mechanics (verified)

`saveCheckpointMemberSQL` (SQL.hs:1243-1250) writes only name/member/last_seen/updated_at. The schema HAS a `stream_name` column for this (`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql:124`, `NOT NULL DEFAULT '$all'`) — never written, never validated. Consequence: point subscription name "proj" at `Category "orders"`, run it to global position 50000, then redeploy "proj" targeting `Category "payments"` (or `AllStreams`): `loadCheckpoint` returns 50000 and the new target's history below 50000 is silently skipped.

### KRS-5 mechanics (verified)

`decodeHook` (`kiroku-store/src/Kiroku/Store/Settings.hs:59-70`) is a user IO transform applied to every fetched batch. The shared publisher applies it once per batch before fan-out (`fullFetch` calls `decodeEvents` at EventPublisher.hs:270, before any delivery or position advance); if it throws, the publisher loop's catch-all (EventPublisher.hs:222-225) emits `KirokuEventPublisherLoopError` and loops — refetching the SAME batch and re-throwing forever. `lastPublished` freezes; AllStreams subscribers and the group live gate (which waits on the publisher position) stall while every state reads `Live`. Inconsistently, the worker-side fetch path applies the same hook (`fetchBatch`, Worker.hs:628-631) where a throw propagates and kills the worker loudly (through the `try` at Worker.hs:384-390).

### Running the tests

From `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (inside `nix develop` if `initdb` is not on PATH): `cabal test kiroku-store-test`; filter e.g. `--test-options='--match "reconnect"'`. The suite boots its own ephemeral PostgreSQL. Useful existing test hooks: `withFetchBatchHookForTest` (fault injection into `fetchBatch`, used by `Test/SubscriptionReconnect.hs`) and `withLoadCheckpointHookForTest` (Worker.hs:95-125). The keiro suite (`cabal test keiro-test` from `/Users/shinzui/Keikaku/bokuno/keiro`) is not touched by this plan.

### Release coordination

These changes ride the shared kiroku release train (kiroku-store 0.4.0.0, driven by plan 125's PVP-major; whichever of plans 125-128 lands last cuts the release). Adding a field to the FSM's `Input` type and new exception types are minor for external consumers (the FSM module is internal machinery), but the release is major anyway.


## Plan of Work

### Milestone 1 — carry the live position through the error exit (KRS-2)

Scope: `Fsm.hs`, `Worker.hs`, and the reconnect test. At the end, a reconnect after real live progress resumes from that progress; a new test that fails today proves it.

Edits:

1. `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`: change the input constructor (line 248) from `ConnectionLost !Pool.UsageError` to `ConnectionLost !GlobalPosition !Pool.UsageError` — the position is "the last position actually processed when the connection was lost". Update `step`: at Fsm.hs:315 (`CatchingUp`), 326 (`Live`), and 341 (`Reconnecting`) the transitions become `ConnectionLost p _ -> (Reconnecting (max c p) n', ...)` (use `max c p` so a defensively-wrong caller can never rewind the FSM below its own knowledge; on the live path `p >= c` always). Update the haddock on the constructor to explain why the position rides the input: the DB-driven live loops advance `posRef`, not the FSM.

2. `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:371-373`: make the error exit read the ref, mirroring its sibling:

```haskell
        liveExitToInput = \case
            LiveHandlerStopped -> HandlerStopped <$> readIORef posRef
            LiveFetchError err -> (`ConnectionLost` err) <$> readIORef posRef
```

3. Check every other producer of `ConnectionLost` (grep the module; the two `liveExitToInput` call sites at Worker.hs:290-293 are the only ones) and every FSM unit test that constructs it (grep `ConnectionLost` under `kiroku-store/test/` — `Test/SubscriptionState.hs` exercises the FSM; fix constructions to pass a position and extend expectations: from `Live (GlobalPosition 7)`, `ConnectionLost (GlobalPosition 42) err` must yield `Reconnecting (GlobalPosition 42) 1`).

4. Extend `kiroku-store/test/Test/SubscriptionReconnect.hs` with a second spec, "reconnects without re-delivering after live progress": same scaffolding as the existing spec (Category target, event handler flag on `KirokuEventSubscriptionCaughtUp`, `withFetchBatchHookForTest`), but sequence the fault AFTER live deliveries: catch up on an empty store; append events 1 and 2 and wait until the handler has seen both (they arrive via live fetches); THEN arm the hook to fail the next 2 fetches (set a `TVar` the hook consults, exactly like `failsLeft` in the existing spec); append event 3; the handler stops after seeing 3 events total. Assert: delivered positions are exactly `[1,2,3]` — no duplicates (against unmodified code this yields `[1,2,1,2,3]` because the reconnect rewinds to live-entry position 0 and refetches 1 and 2 — the checkpoint is at 2, but `Reconnecting` fetches from the STALE FSM cursor, not the checkpoint); at least one `KirokuEventSubscriptionReconnecting` was emitted; final checkpoint is 3.

Acceptance: the new spec FAILS against unmodified code with the duplicated prefix (capture the transcript in Surprises & Discoveries), then passes; the whole suite stays green (`cabal test kiroku-store-test`).

### Milestone 2 — validate batchSize at subscribe time (KRS-6)

Scope: `Subscription.hs`, `Subscription/Types.hs`, tests. Independent of milestone 1.

Define, next to `InvalidConsumerGroup` (`kiroku-store/src/Kiroku/Store/Subscription/Types.hs:397`), a typed exception `InvalidBatchSize !Int32` (stock `Eq`/`Show`, anyclass `Exception`; haddock: "batchSize must be >= 1; 0 silently stalls delivery — and can permanently skip the catch-up gap on the AllStreams path — and negative values fail every fetch"). Export it wherever `InvalidConsumerGroup` is exported (module export list, `Kiroku.Store.Subscription`, umbrella `Kiroku.Store` — follow the existing name). In `subscribe` (`Subscription.hs:113-119`), immediately after the group check:

```haskell
    when (batchSize config < 1) $
        throwIO (InvalidBatchSize (batchSize config))
```

Also update the `batchSize` field haddock in `Types.hs` (near 320-326) and the subscriptions user guide (`docs/user/subscriptions.md`) to state the constraint.

Tests (in `kiroku-store/test/Test/SubscriptionRegistry.hs` or a small new spec beside it): `subscribe` with `batchSize = 0` throws `InvalidBatchSize 0` before doing any database work (use `shouldThrow`); `batchSize = -5` throws `InvalidBatchSize (-5)`; `batchSize = 1` subscribes and delivers normally (quick smoke: one appended event arrives). No stall-reproduction test is needed — the entire point is that the pathological configs can no longer construct a worker.

Acceptance: new specs pass; full suite green.

### Milestone 3 — bind the checkpoint to its target (KRS-4)

Scope: SQL statements, `Worker.hs` load/save, a new migration, a typed error, docs, tests. Coordinate with plan 126 on the shared statements (see Context).

1. Encoding (module `Kiroku.Store.Subscription.Worker` or `Types`): a total function `targetBinding :: SubscriptionTarget -> Text` — `AllStreams -> "$all"`, `Category (CategoryName c) -> "$category-" <> c`. The `$`-prefix keeps bindings out of the application stream-name space (names starting with `$` are reserved; see `validateStreamName` in `Error.hs`).

2. Migration: new file `kiroku-store-migrations/migrations/0009-bind-subscription-checkpoints-to-target.sql`, appended to `kiroku-store-migrations/migrations/manifest`:

```sql
-- Existing checkpoint rows predate target binding: stream_name was never
-- written and always holds the default '$all', which cannot be distinguished
-- from a genuine AllStreams binding. Rewrite them to the explicit '$legacy'
-- sentinel (adopted-and-bound on first post-upgrade checkpoint write), and
-- make '$legacy' the default so any insert path that omits the column stays
-- unbound rather than claiming AllStreams.
UPDATE kiroku.subscriptions SET stream_name = '$legacy' WHERE stream_name = '$all';
ALTER TABLE kiroku.subscriptions ALTER COLUMN stream_name SET DEFAULT '$legacy';
```

   Follow the header-comment style of `0007-stream-truncate-before.sql`. Record the claimed number (0009) in the master plan's Integration Points section when landing (the parent asks for this), and tell plan 126's implementer — if 126 unexpectedly needs a migration after all, it takes 0010.

3. SQL: add the binding parameter to `saveCheckpointMemberSQL` (SQL.hs:1243-1250) — insert column `stream_name`, `DO UPDATE SET stream_name = EXCLUDED.stream_name` — and to the checkpoint half of `insertDeadLetterAndCheckpointSQL` (SQL.hs:1309-1322) plus `DeadLetterParams`. Extend `getCheckpointMemberSQL` (SQL.hs:1234-1241) to also select `stream_name`. (If plan 126 has landed, these statements already grew a `consumer_group_size` parameter — add `stream_name` alongside; the edits compose.)

4. `Worker.hs`: `saveCheckpoint` (764-776) and the dead-letter path pass `targetBinding (target config)`. `loadCheckpoint` (443-461) receives `(last_seen, stream_name)` and validates: stored `"$legacy"` -> adopt (proceed; the first save rewrites the binding); stored equals `targetBinding (target config)` -> proceed; anything else -> `throwIO (SubscriptionTargetMismatch subName member stored expected)`. Define that exception in `Subscription/Types.hs` beside `InvalidBatchSize`, with a haddock naming the override: "if the retarget is intentional, either delete the checkpoint rows (`DELETE FROM kiroku.subscriptions WHERE subscription_name = ...` — the subscription restarts from position 0) or rebind in place (`UPDATE kiroku.subscriptions SET stream_name = '<new binding>' WHERE subscription_name = ...` — the subscription keeps its position; only correct if you know the position is meaningful for the new target)". Put the same override text in `docs/user/subscriptions.md`.

5. Tests (new `kiroku-store/test/Test/SubscriptionTargetBinding.hs`, wired into `Main.hs` + cabal): (a) run a `Category "orders"` subscription past a few events; resubscribe the same name as `Category "payments"`; assert `wait` yields `Left` whose exception is `SubscriptionTargetMismatch` with stored `"$category-orders"`, expected `"$category-payments"`; (b) same for `Category` -> `AllStreams`; (c) legacy adoption: hand-write a row with `stream_name = '$legacy'` (raw SQL), subscribe with any target, assert it starts and the row is rebound after the first checkpoint save; (d) the documented rebind override unblocks case (a).

Acceptance: new spec green; full suite green (the migration runs automatically — the test fixture applies the whole migrations directory).

### Milestone 4 — contain decodeHook failures loudly (KRS-5)

Scope: `EventPublisher.hs`, `Settings.hs` docs, `Observability.hs`, a poison-hook test.

1. Contract: extend the `decodeHook` haddock (`Settings.hs:59-70` and the field at 70) — the hook MUST NOT throw; a throw is treated as fatal to the component applying it (worker: the subscription dies; publisher: the publisher dies), never silently retried or skipped.

2. New observability constructor in `kiroku-store/src/Kiroku/Store/Observability.hs`: `KirokuEventPublisherDecodeHookFailed !Text` (the exception, shown), following the existing `KirokuEventPublisherLoopError` naming/shape.

3. `EventPublisher.hs`: define an internal wrapper exception, e.g. `newtype PublisherDecodeHookFailed = PublisherDecodeHookFailed SomeException` (with `Exception` instance). In `fullFetch` (256+), wrap the hook application at line 270: `events <- decodeEvents stSettings rawEvents \`catch\` \(e :: SomeException) -> case asyncExceptionFromException e of Just ae -> throwIO ae; Nothing -> throwIO (PublisherDecodeHookFailed e)`. In the loop's catch-all (222-225), before the generic branch, test `fromException` for `PublisherDecodeHookFailed`: emit `KirokuEventPublisherDecodeHookFailed` and RETHROW — killing the publisher thread. The generic branch stays as-is for genuinely transient delivery errors. Result: one loud typed event, thread dead (observable via `Async.poll` on `publisherThread`), no spin. Document in `startPublisher`'s haddock (125-138) that a throwing `decodeHook` terminates the publisher.

4. Test (new spec, e.g. in `kiroku-store/test/Test/PublisherCallbackResilience.hs` beside the existing publisher specs, or a new module): build a store via `withTestStoreSettings` setting a `decodeHook = Just (\_ -> throwIO ...)` poison hook and an `eventHandler` collector; register an AllStreams subscriber (so the publisher takes the `fullFetch` path); append one event; assert (with a bounded wait): exactly one `KirokuEventPublisherDecodeHookFailed` is observed (not an ever-growing stream of `KirokuEventPublisherLoopError` — assert the loop-error count stays 0 or 1 over a short window, proving no spin), and the publisher thread has terminated (`Async.poll` on the store's publisher returns `Just`; reach the `EventPublisher` via the store's `#publisher` lens as `Subscription.hs:127` does). Also assert the worker-side contrast still holds: a poison hook on a category subscription kills that subscription with the hook's exception through `wait` (this pins the "consistent loudness" claim).

Acceptance: poison test green; pre-fix behavior (endless `KirokuEventPublisherLoopError`) demonstrably gone.


## Concrete Steps

`$KIROKU` = `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

```bash
cd $KIROKU
nix develop        # if initdb/postgres are not on PATH
# M1 — first run the new reconnect spec against UNMODIFIED code to capture the failure:
cabal test kiroku-store-test --test-options='--match "reconnect"'
# expect: "reconnects without re-delivering after live progress" FAILS with
# delivered == [1,2,1,2,3] (paste into Surprises & Discoveries), then after the
# Fsm/Worker edits:
cabal test kiroku-store-test --test-options='--match "reconnect"'   # PASS
```

```bash
cd $KIROKU
# M2:
cabal test kiroku-store-test --test-options='--match "batchSize"'
# M3 (migration + binding):
cabal test kiroku-store-test --test-options='--match "target"'
# M4:
cabal test kiroku-store-test --test-options='--match "decodeHook"'
# always finish with the full suite:
cabal test kiroku-store-test
```

Expected new-spec summary when all four milestones land:

```text
subscription FSM — worker-level live reconnect (EP-41 M3)
  reconnects and resumes after transient live-mode database errors [✔]
  reconnects without re-delivering after live progress [✔]
subscribe validation
  rejects batchSize 0 with InvalidBatchSize [✔]
  rejects negative batchSize [✔]
subscription target binding
  refuses a retargeted subscription name with SubscriptionTargetMismatch [✔]
  adopts $legacy rows and rebinds on first save [✔]
  documented rebind override unblocks an intentional retarget [✔]
event publisher decode hook
  a throwing decodeHook emits one typed event and stops the publisher [✔]
```


## Validation and Acceptance

Beyond compilation: (1) KRS-2 — the reconnect-after-progress spec is the acceptance: red on unmodified code with the exact duplicate prefix `[1,2,1,2,3]`, green after; (2) KRS-6 — `subscribe` with `batchSize = 0` now throws immediately (observable in ghci against a store in two lines), where before it returned a handle that sat `Live` forever; (3) KRS-4 — retargeting a name is refused with an error that names the stored and expected bindings and the override procedure; running the override then works; (4) KRS-5 — with a poison hook, the operator sees ONE `KirokuEventPublisherDecodeHookFailed` and a dead publisher instead of an infinite `KirokuEventPublisherLoopError` stream at `Live`.


## Idempotence and Recovery

All test commands are safely re-runnable (fresh ephemeral database per run). Migration 0009 is idempotent in effect (the `UPDATE` matches nothing on a second run; `ALTER ... SET DEFAULT` is absolute) and additive — it renames only the never-written default sentinel, so no live deployment loses information; rollback is the inverse `UPDATE`/`ALTER`. The FSM input change is compile-checked exhaustively (the `step` function pattern-matches `Input` totally — Fsm.hs:298-303 documents that extending `Input` forces compile errors at every site). If the `max c p` guard in `step` ever masks a real regression source, the FSM unit tests in `Test/SubscriptionState.hs` pin the intended arithmetic. The publisher change fails CLOSED (crash) — if the crash proves too aggressive for some deployment, the revert path is the single `catch` wrapper at EventPublisher.hs:270, but revisit the Decision Log entry before doing that.


## Interfaces and Dependencies

End state (all in `kiroku-store`, riding the shared 0.4.0.0 release train — see plan 125):

- `Kiroku.Store.Subscription.Fsm.Input`: `ConnectionLost !GlobalPosition !Hasql.Pool.UsageError` (field added).
- `Kiroku.Store.Subscription.Types`: new exceptions `InvalidBatchSize !Int32` and `SubscriptionTargetMismatch !SubscriptionName !Int32 !Text !Text` (member, stored binding, expected binding), both exported alongside `InvalidConsumerGroup`.
- `Kiroku.Store.Observability.KirokuEvent`: new constructor `KirokuEventPublisherDecodeHookFailed !Text`.
- `Kiroku.Store.SQL`: `saveCheckpointMemberStmt` and `getCheckpointMemberStmt` gain the `stream_name` binding column (types compose with plan 126's `consumer_group_size` addition); `DeadLetterParams` gains the binding field.
- `kiroku-store-migrations`: new migration `0009-bind-subscription-checkpoints-to-target.sql` + manifest entry (number claimed by this plan; record in the master plan's Integration Points).
- Unchanged signatures: `subscribe`, `withSubscription`, `SubscriptionConfig` (validation is behavioral), `hardDeleteStream` etc. (untouched — plan 125's territory).

No new package dependencies; everything uses hasql, stm, async, and the existing test hooks. keiro consumes these fixes passively via the release/pin bump recorded in plans 125/126 — no keiro code change is needed for this plan's findings (keiro's shard readers simply stop re-delivering after transient live faults).
