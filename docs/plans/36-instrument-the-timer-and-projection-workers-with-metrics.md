---
id: 36
slug: instrument-the-timer-and-projection-workers-with-metrics
title: "Instrument the timer and projection workers with metrics"
kind: exec-plan
created_at: 2026-06-03T04:20:10Z
intention: "intention_01kt5v38ztez0tt5b63nr7gbnx"
master_plan: "docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md"
---

# Instrument the timer and projection workers with metrics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is a Haskell event-sourcing framework. It runs several background "workers"
— small loops that poll a PostgreSQL database and do one unit of work per pass.
Two of those workers are covered by this plan:

- The **timer worker** (`runTimerWorker` in `keiro/src/Keiro/Timer.hs`). A
  "timer" is a row in the `keiro_timers` table that says "wake process manager
  X at time T". The worker claims the earliest due timer, runs a caller-supplied
  `fire` action on it, and marks it fired.
- The **async projection path** (`applyAsyncProjection` in
  `keiro/src/Keiro/Projection.hs`, plus the position-wait machinery `waitFor` in
  `keiro/src/Keiro/ReadModel.hs`). An "async projection" is a read-model update
  that runs later, from a subscription that drains the global event log. A
  "read model" is a SQL table queried on the read side; "projection lag" is how
  far behind the live event log that table's subscription is.

Today these workers emit no operational numbers. An operator running keiro in
production can see per-run *traces* (spans) but cannot answer "how many timers
are overdue right now?", "how late are timers firing?", or "how far behind is my
read model?". Those are the numbers an operator alerts on.

After this change, an application that wires an OpenTelemetry SDK meter into the
timer worker and the projection path will see, on any metrics exporter (OTLP in
production, the handle/stdout exporter in a demo, the in-memory exporter in
tests), six instruments:

- `keiro.timer.backlog` — a gauge: how many timers are scheduled and already due.
- `keiro.timer.fire.lag` — a histogram: how late (in seconds) each claimed timer
  was, i.e. `now − fireAt`.
- `keiro.timer.attempts` — a histogram: how many times the claimed timer had been
  attempted.
- `keiro.timer.stuck` — a gauge: how many timers are "stuck" (claimed `Firing`
  but never completed), per the definition that ExecPlan EP-34 introduces. This
  instrument lands last and depends on EP-34 (see Milestone M3).
- `keiro.projection.lag` — a gauge: store head global position minus the
  subscription's checkpoint position (how many events the read model is behind).
- `keiro.projection.wait.timeouts` — a counter: how many times a `PositionWait`
  read-your-writes query gave up waiting for the projection to catch up.

You can see it working by running the keiro test suite (`cabal test keiro-test`):
new tests drive a due timer through the worker and assert the three timer
instruments were recorded; drive a read model deliberately behind the log and
assert the lag gauge; and force a position-wait timeout and assert the timeout
counter. All six instruments degrade to a no-op when no meter is supplied, so
every existing caller keeps compiling and behaving exactly as before.

"Term of art" reminders used throughout this plan:

- **Instrument** — a named OpenTelemetry metric object you record values into.
  A **Counter** only goes up (`counterAdd`). A **Gauge** is a current value you
  set each time (`gaugeRecord`). A **Histogram** records a distribution of
  observations (`histogramRecord`). These three recording functions live in
  `OpenTelemetry.Metric.Core` (re-exported by `OpenTelemetry.Metric` in
  `hs-opentelemetry-sdk`).
- **Synchronous instrument** — one you record into inline, from your own code,
  when you have the value. The opposite is an *observable* (asynchronous)
  instrument whose callback the SDK runs at export time. This plan records
  everything **synchronously** from inside the worker, because only the worker
  holds the `Store` effect needed to query the database (see Decision Log).
- **Meter** — the factory that creates instruments (`OpenTelemetry.Metric.Core`'s
  `Meter`). Applications obtain one from an SDK `MeterProvider` via `getMeter`.
- **No-op** — when no meter is configured, recording does nothing and costs one
  `Maybe` branch.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1.1 Confirm EP-33 has landed: `Keiro.Telemetry` exports `KeiroMetrics`, `newKeiroMetrics`, and the timer recording helpers; record the exact exported names in the Decision Log. (2026-06-03)
- [x] M1.2 Add the read-only backlog count query `countDueTimers` to `keiro/src/Keiro/Timer/Schema.hs` and re-export it from `keiro/src/Keiro/Timer.hs`. (2026-06-03)
- [x] M1.3 Thread `Maybe KeiroMetrics` into `runTimerWorker`/`runTimerWorkerWith` as the leading argument and record `keiro.timer.backlog`, `keiro.timer.fire.lag`, and `keiro.timer.attempts` each pass. (2026-06-03)
- [x] M1.4 Update the existing `runTimerWorker`/`runTimerWorkerWith` call sites in `keiro/test/Main.hs` to pass `Nothing`. (2026-06-03)
- [x] M1.5 Add the M1 timer-metrics test asserting the three timer instruments under the in-memory metric exporter; run `cabal test keiro-test`. (2026-06-03)
- [x] M2.1 Added `storeHeadPosition`/`positionGap` and `recordProjectionLag` to `Keiro.Projection`; exported `readSubscriptionPosition` from `Keiro.ReadModel`; records `keiro.projection.lag`. (2026-06-03)
- [x] M2.2 Threaded `Maybe KeiroMetrics` through `runQuery`/`runQueryWith`/`waitIfNeeded`/`waitFor`; increments `keiro.projection.wait.timeouts` on the `ReadModelWaitTimeout` branch. (2026-06-03)
- [x] M2.3 Added the M2 projection tests (lag gauge behind-the-log; wait-timeout counter); `cabal test keiro-test` passes (92 examples, 0 failures). (2026-06-03)
- [x] M3.1 EP-34 has landed: stuck = `status = 'firing'` per `StuckTimerFilter`; added `countStuckTimers` to `Keiro.Timer.Schema` mirroring `findStuckTimers`. (2026-06-03)
- [x] M3.2 Record `keiro.timer.stuck` in the timer worker (via `anyStuckTimer`, before the claim) and add the M3 stuck-gauge test; `cabal test keiro-test` passes. (2026-06-03)
- [x] M4 Extended the `docs/user/operations.md` Observability paragraph to name the six timer/projection instruments, deferring the full catalogue to EP-37. (2026-06-03)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03: At authoring time both EP-33
  (`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`)
  and EP-34
  (`docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md`) are
  still unfilled skeletons. Their *contracts* are nevertheless fixed by the
  MasterPlan
  (`docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md`):
  its Decision Log pins the `KeiroMetrics` record + `newKeiroMetrics :: (MonadIO
  m) => Meter -> m KeiroMetrics` shape and the "workers accept `Maybe
  KeiroMetrics`" convention, and its Surprises & Discoveries pin the current
  `TimerStatus = Scheduled | Firing | Fired | Cancelled` and flag that EP-34 may
  add a terminal `Dead`-like state. This plan consumes those contracts by
  reference; if EP-33 or EP-34 ship with different spellings, the implementer
  must reconcile names at M1.1 / M3.1 and record the reconciliation in this
  Decision Log.
- 2026-06-03: The keiro event store (kiroku) exposes
  `Kiroku.Store.Read.readAllBackward :: GlobalPosition -> Int32 -> Eff es
  (Vector RecordedEvent)`. Its doc comment (verified in
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Read.hs`)
  states: "To start from the most recent event, pass `GlobalPosition 0` (treated
  as 'after everything' by the SQL)." So `readAllBackward (GlobalPosition 0) 1`
  returns the single head event, whose `globalPosition` field *is* the store
  head position. This is exactly the number needed for projection lag and avoids
  inventing a new store query. (`RecordedEvent` carries `globalPosition ::
  GlobalPosition` and `createdAt :: UTCTime`, confirmed in
  `kiroku-store/src/Kiroku/Store/Types.hs`.)

- 2026-06-03 (M1.1 reconciliation): EP-33 shipped the helper names this plan
  assumed, with two deltas the implementation reconciled:
  - The position-wait counter helper is `recordProjectionWaitTimeouts` (plural),
    not the singular `recordProjectionWaitTimeout` the M2.2 sketch used.
  - `keiro.timer.fire.lag` was declared by EP-33 in **milliseconds** (unit
    `"ms"`), not seconds as this plan's Purpose/M1 text assumed. `diffUTCTime`
    yields seconds, so the worker records `realToFrac (now - fireAt) * 1000`.
    The Purpose bullet's "(in seconds)" is therefore stale; EP-37 (which owns the
    consolidated metric catalogue) must document fire.lag as milliseconds.
  - Confirmed EP-33 exports (verbatim): `recordTimerBacklog :: Maybe KeiroMetrics
    -> Int64 -> m ()` (gauge), `recordTimerStuck :: ... -> Int64 -> m ()` (gauge),
    `recordTimerFireLag :: ... -> Double -> m ()` (histogram), `recordTimerAttempts
    :: ... -> Double -> m ()` (histogram), `recordProjectionLag :: ... -> Int64 ->
    m ()` (gauge), `recordProjectionWaitTimeouts :: ... -> Int64 -> m ()` (counter).
    All take `Maybe KeiroMetrics` and no-op on `Nothing`.
- 2026-06-03 (EP-34 reshaped the worker): EP-34 made `runTimerWorkerWith ::
  TimerWorkerOptions -> ...` the real implementation and `runTimerWorker` a thin
  alias. The meter is threaded into **both** as the leading `Maybe KeiroMetrics`
  argument (`runTimerWorker = runTimerWorkerWith metrics defaultTimerWorkerOptions`),
  and the recording happens once inside `runTimerWorkerWith`. The constraint
  gained `IOE :> es` (the EP-33 helpers are `MonadIO`), matching how EP-35
  instrumented the outbox/inbox; every existing call site already runs under
  `Store.runStoreIO`, which provides `IOE`.
- 2026-06-03 (M3 done early): EP-34 is Complete, so M3 shipped together with M1
  rather than deferred. `keiro.timer.stuck` is recorded from `countStuckTimers now
  anyStuckTimer` evaluated **before** the claim — at that point every `firing` row
  is one a prior pass stranded (the row this pass is about to claim is still
  `scheduled`), giving a clean "rows needing recovery" count. Per the MasterPlan's
  EP-34 discovery, `dead` rows are a distinct terminal state and are not counted
  as stuck (the predicate is `status = 'firing'`). The test harness names are the
  real EP-33/EP-35 ones (`inMemoryMetricExporter`, `flattenScalarPoints`,
  `flattenHistogramPoints`), not the provisional `withInMemoryMeter`/`metricPoints`
  the Concrete Steps sketched.
- 2026-06-03 (M2 name clash): EP-33's gauge helper is itself named
  `recordProjectionLag`, so the public `Keiro.Projection.recordProjectionLag`
  (the `AsyncProjection -> Eff es ()` entry point this plan adds) would shadow it.
  Resolved by importing `Keiro.Telemetry` **qualified** in `Keiro.Projection`
  (`import Keiro.Telemetry qualified as Telemetry`) and calling
  `Telemetry.recordProjectionLag` inside the public function. The Concrete Steps
  sketch had assumed EP-33 would name its helper `recordProjectionLagValue`; it
  did not.
- 2026-06-03 (M2 arithmetic): `Keiro.Prelude` does not re-export the numeric
  operators (`(-)` etc.); the codebase convention is to qualify them as
  `Prelude.-` (see `Keiro.ReadModel`'s `Prelude.* `). `positionGap` uses
  `headP Prelude.- checkP`.
- 2026-06-03 (call-site fan-out): adding the leading `Maybe KeiroMetrics` to
  `runTimerWorker`/`runQuery`/`runQueryWith` and the `IOE` constraint to the timer
  worker rippled into the **jitsurei** demo package, which is a separate cabal
  package not exercised by `keiro-test`. Updated every caller to pass `Nothing`
  (`jitsurei/app/Main.hs`, `jitsurei/test/Main.hs`, `Jitsurei/Paging.hs`,
  `Jitsurei/AgentQualRouter.hs`, `Jitsurei/EscalationProcess.hs`,
  `Jitsurei/Timers.hs`) and added `IOE :> es` to `Jitsurei.Timers.runPaymentTimeoutWorker`.
  `cabal build jitsurei jitsurei-test` is green. Wiring the demo's metrics into a
  handle/stdout exporter is left to EP-37, which owns the demo and docs.


## Decision Log

Record every decision made while working on the plan.

- Decision: Compute `keiro.projection.lag` as **store head global position minus
  the subscription checkpoint position**, read via `readAllBackward
  (GlobalPosition 0) 1` for the head and `readSubscriptionPosition
  subscriptionName` for the checkpoint, and record the difference as the gauge
  value (clamped at 0).
  Rationale: The MasterPlan's Integration Points allow either a
  head-minus-checkpoint subtraction or a per-event `now − recordedEvent.createdAt`
  age, and asks this plan to pick one and justify it. Head-minus-checkpoint is a
  true backlog count (events not yet projected), it reuses two functions that
  already exist (`readAllBackward` in kiroku and `readSubscriptionPosition` in
  `Keiro.ReadModel`), and it is meaningful even when the projection is idle
  (no event currently being processed). The per-event-age alternative requires a
  `RecordedEvent` in hand and reads zero whenever the worker is caught up, which
  conflates "caught up" with "idle". Head-minus-checkpoint is therefore the
  better operator signal. Both `GlobalPosition` values are `Int64`; the gauge
  records `fromIntegral (max 0 (head − checkpoint))` as a `Double`.
  Date: 2026-06-03.

- Decision: All six instruments are recorded **synchronously** from inside the
  worker (the timer worker pass; the projection drain; the `waitFor` timeout
  branch), never as observable/asynchronous gauges with export-time callbacks.
  Rationale: This is the MasterPlan-level decision (its Decision Log, "Backlog
  and lag are recorded as synchronous instruments ... written by each worker on
  every poll pass"). An observable callback runs on the SDK collection thread and
  would need its own database access, which the library does not own; the workers
  already hold the `Store` effect, so synchronous recording needs no new
  application wiring and is accurate to within one poll interval.
  Date: 2026-06-03.

- Decision: Thread the meter as a trailing `Maybe KeiroMetrics` argument on the
  worker entry points (`runTimerWorker`, the async projection drain helper, and
  `runQueryWith`/`waitFor`), defaulting to "record nothing" on `Nothing`. Do not
  introduce a new options record solely for this plan.
  Rationale: The MasterPlan's "Worker option records / entry points" integration
  point says EP-36 threads the handle into exactly these functions following
  EP-33's documented convention (handle passed explicitly, defaulting to no-op),
  matching the existing `Maybe Tracer` idiom in `Keiro.Telemetry`. A trailing
  `Maybe` argument is the smallest change that keeps every current caller working
  by passing `Nothing`. If EP-33 instead bundles the handle into an options
  record, follow that; record the deviation here.
  Date: 2026-06-03.

- Decision: Add only **read-only count queries** to
  `keiro/src/Keiro/Timer/Schema.hs` (`countDueTimers` in M1, `countStuckTimers`
  in M3). Do not add or modify any mutation/recovery function there.
  Rationale: `Keiro.Timer.Schema` is a shared file between this plan and EP-34
  (MasterPlan Integration Points: "EP-34 owns new mutation functions ... EP-36
  owns new read-only count queries"). Keeping strictly to read-only counts avoids
  a conflicting edit. EP-34 lands first in Wave 1, so by the time M3 runs the
  stuck definition and any new status constructor already exist.
  Date: 2026-06-03.

- Decision: Ship the timer instruments (M1) and projection instruments (M2)
  before the stuck gauge (M3), and gate M3 explicitly on EP-34.
  Rationale: EP-36 only *softly* depends on EP-34 (MasterPlan Dependency Graph).
  `keiro.timer.stuck` needs EP-34's formal "stuck" definition (and possibly a new
  terminal `TimerStatus`), but the other five instruments do not. Shipping them
  first delivers value without waiting on EP-34 and keeps each milestone
  independently verifiable.
  Date: 2026-06-03.

- Decision: Keep the `docs/user/operations.md` change to a single short note and
  defer the full metrics catalogue to EP-37.
  Rationale: MasterPlan "User documentation set": EP-37 owns the consolidated
  final state of the user docs; EP-35/EP-36 keep their `operations.md` edits
  minimal to avoid churn.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

All four milestones shipped. The timer worker (`runTimerWorker` /
`runTimerWorkerWith`) and the read side now emit the six instruments promised in
Purpose — `keiro.timer.backlog`, `keiro.timer.fire.lag`, `keiro.timer.attempts`,
`keiro.timer.stuck`, `keiro.projection.lag`, `keiro.projection.wait.timeouts` —
through the opt-in `Maybe KeiroMetrics` handle, degrading to a no-op on
`Nothing`. `cabal test keiro-test` passes (92 examples, 0 failures), with four new
metric examples (timer backlog/fire-lag/attempts, timer stuck, projection lag,
position-wait timeout). `cabal build jitsurei jitsurei-test` is green after
threading `Nothing` through the demo's callers.

Deviations from the original draft, all reconciled in Decision Log / Surprises:
- M3 shipped together with M1 rather than deferred, because EP-34 was already
  Complete. The stuck gauge counts `status = 'firing'` rows (EP-34's
  `anyStuckTimer`) read before the claim, so it reflects rows stranded by prior
  passes; `dead` is treated as a separate terminal state, not stuck.
- `keiro.timer.fire.lag` is recorded in **milliseconds** to match EP-33's
  declared unit, not seconds as Purpose/M1 text assumed. EP-37 (catalogue owner)
  should correct the "(in seconds)" phrasing.
- The wait-timeout helper is `recordProjectionWaitTimeouts` (plural); the public
  projection-lag entry point is `Keiro.Projection.recordProjectionLag`, with the
  same-named EP-33 helper imported qualified to avoid the clash.

Gaps / handoffs to EP-37: the demo does not yet wire a real meter (handle/stdout
exporter) into the timer worker or projection path; the full metric catalogue
(units, kinds, semconv alignment) and the corrected fire.lag unit live with EP-37.


## Context and Orientation

This section assumes no prior knowledge of the repository.

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. The library lives
under `keiro/` with sources in `keiro/src/` and a single test executable in
`keiro/test/Main.hs`. The build is Cabal; the test target is `keiro-test`
(declared in `keiro/keiro.cabal`, `test-suite keiro-test`, `main-is: Main.hs`).
Database tests run against an ephemeral PostgreSQL instance provided by the
`keiro-test-support` package; the suite obtains a migrated "fixture" once and
each example gets a fresh store from it (see "the test harness" below).

The four source files this plan edits, and what each currently is:

- `keiro/src/Keiro/Timer.hs` — the timer worker. It re-exports the timer types
  and storage from `Keiro.Timer.Types` / `Keiro.Timer.Schema`, and defines:

  ```haskell
  runTimerWorker ::
    (Store :> es) =>
    UTCTime ->
    (TimerRow -> Eff es (Maybe EventId)) ->
    Eff es (Maybe TimerRow)
  runTimerWorker now fire = do
    due <- claimDueTimer now
    case due of
      Nothing -> pure Nothing
      Just timer -> do
        fired <- fire timer
        for_ fired (markTimerFired (timer ^. #timerId))
        pure (Just timer)
  ```

  `Store :> es` means "the effect list `es` includes the kiroku `Store` effect",
  i.e. the function can talk to the database. `claimDueTimer now` selects the
  earliest `Scheduled` timer with `fire_at <= now` using `FOR UPDATE SKIP
  LOCKED`, moves it to `Firing`, and bumps its `attempts` count.

- `keiro/src/Keiro/Timer/Schema.hs` — the `keiro_timers` table SQL. It defines
  `TimerStatus = Scheduled | Firing | Fired | Cancelled`, the `TimerRow` record
  (fields include `fireAt :: UTCTime`, `attempts :: Int`, `status ::
  TimerStatus`), and the storage functions `scheduleTimerTx`, `claimDueTimer`,
  `markTimerFired`. Each storage function builds a `Hasql.Statement` and runs it
  with `Kiroku.Store.Transaction.runTransaction`. This is the file shared with
  EP-34; this plan only *adds read-only count queries* here.

- `keiro/src/Keiro/Projection.hs` — projections. `applyAsyncProjection ::
  AsyncProjection -> RecordedEvent -> Tx.Transaction ()` applies one event's
  read-model update; it returns a `Hasql.Transaction.Transaction ()` for a
  subscription worker to run. An `AsyncProjection` carries `subscriptionName ::
  Text` (the checkpoint cursor) and `idempotencyKey :: RecordedEvent ->
  EventId`. Note: this module does *not* itself contain a polling drain loop in
  the current tree — the application drives `applyAsyncProjection` per event (the
  test does so directly). This plan therefore records projection lag at the point
  the application drains events; see Plan of Work M2 for the exact shape.

- `keiro/src/Keiro/ReadModel.hs` — read-side queries with consistency. Relevant
  pieces:
  - `ConsistencyMode = Strong | Eventual | PositionWait !PositionWaitOptions`.
    `PositionWait` means "block until the read model's subscription reaches a
    target log position, giving read-your-writes".
  - `PositionWaitOptions { target :: Maybe GlobalPosition, timeoutMicros :: Int,
    pollMicros :: Int }`.
  - `waitFor :: (IOE :> es, Store :> es) => PositionWaitOptions -> ReadModel q r
    -> GlobalPosition -> Eff es (Either ReadModelError ())` — the polling loop. It
    repeatedly calls `readSubscriptionPosition (readModel ^. #subscriptionName)`
    and, when `timeoutMicros` elapses before the target is reached, returns
    `Left (ReadModelWaitTimeout name target observed)`. This `ReadModelWaitTimeout`
    branch is exactly where `keiro.projection.wait.timeouts` is incremented.
  - `readSubscriptionPosition :: (Store :> es) => Text -> Eff es (Maybe
    GlobalPosition)` — reads the `last_seen` column from the `subscriptions`
    table for a subscription name. This is the checkpoint side of the lag
    computation.
  - `runQueryWith :: (IOE :> es, Store :> es) => ConsistencyMode -> ReadModel q r
    -> q -> Eff es (Either ReadModelError r)` calls `waitFor` via
    `waitIfNeeded`. The meter is threaded through `runQueryWith` → `waitIfNeeded`
    → `waitFor`.

- `keiro/src/Keiro/Telemetry.hs` — the single telemetry import for the library.
  Today it exports span helpers under the `Maybe Tracer` opt-in pattern (e.g.
  `withProducerSpan :: Maybe Tracer -> ...` runs the body unwrapped when given
  `Nothing`). EP-33 extends this module with the metrics surface; this plan only
  *consumes* it.

How to read the store head position (needed for projection lag): kiroku's
`Kiroku.Store.Read.readAllBackward (GlobalPosition 0) 1` returns the single most
recent event in the global `$all` log; its `globalPosition` field is the head.
When the log is empty the vector is empty and the head is treated as 0.

The EP-33 contract this plan depends on (from the MasterPlan Decision Log,
restated here so this plan is self-contained):

- A record `KeiroMetrics` holding the constructed instruments.
- A builder `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics` that
  creates every instrument once from an SDK `Meter`.
- Recording helpers that take a `Maybe KeiroMetrics` and treat `Nothing` as
  "record nothing". This plan calls those helpers; it does not record into raw
  instruments directly. The canonical helper names are not yet fixed by EP-33;
  this plan refers to them by intent (e.g. "the helper that records
  `keiro.timer.backlog`") and the implementer binds them to EP-33's real names at
  M1.1, recording the mapping in the Decision Log. The canonical *instrument*
  names (owned by EP-33) are the six listed in Purpose.

The EP-34 contract this plan depends on (only at M3): a formal definition of a
"stuck" timer (rows in `Firing` past an attempt/age threshold, or a new terminal
status such as `Dead`) and any new `TimerStatus` constructor, both recorded in
the MasterPlan's Surprises & Discoveries when EP-34 lands.

The test harness (from `keiro/test/Main.hs`, already in the tree): `main =
withMigratedSuite $ \fixture -> hspec $ do ...`. DB-backed describe-blocks use
`around (withFreshStore fixture)`, so each `it` receives a `storeHandle`. Inside
an example you run store actions with `Store.runStoreIO storeHandle $ ...`. The
in-memory **span** exporter is already imported
(`OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)`); the in-memory
**metric** exporter is `OpenTelemetry.Exporter.InMemory.Metric
(inMemoryMetricExporter)` and returns `(MetricExporter, IORef
[ResourceMetricsExport])`. The SDK pieces to build a real meter for a test live
in `OpenTelemetry.Metric` (`hs-opentelemetry-sdk`): `createMeterProvider`,
`defaultSdkMeterProviderOptions`, `getMeter`, `exportMetricsOnce` /
`forceFlushMeterProvider`, and `noopMeterProvider`. All of these are already test
dependencies (see `keiro/keiro.cabal`'s `test-suite keiro-test` block, which
lists `hs-opentelemetry-exporter-in-memory` and `hs-opentelemetry-sdk`), so this
plan adds **no new dependency**. EP-33 builds the reusable in-memory metric test
harness (a helper that gives you a `Meter` plus a way to force a collect/export
and read the exported instruments back from the `IORef`); this plan reuses it.


## Plan of Work

The work is four milestones. M1 instruments the timer worker. M2 instruments the
projection lag and position-wait timeout. M3 adds the timer stuck gauge, gated on
EP-34. M4 is the minimal docs note. Each milestone is independently verifiable by
running `cabal test keiro-test`.

Throughout, "the helper that records X" means an EP-33-provided function of the
shape `recordX :: (MonadIO m) => Maybe KeiroMetrics -> <value> -> m ()` that
does nothing on `Nothing`. Bind these to EP-33's real names at M1.1.


### Milestone M1 — timer worker backlog / fire.lag / attempts

Scope: thread `Maybe KeiroMetrics` into `runTimerWorker` and record
`keiro.timer.backlog`, `keiro.timer.fire.lag`, and `keiro.timer.attempts` on
each pass. At the end of M1 a test can schedule a due timer, run the worker once
under an in-memory meter, force an export, and read back all three instruments.

First, confirm EP-33 has landed (M1.1). Open
`keiro/src/Keiro/Telemetry.hs` and verify it exports `KeiroMetrics`,
`newKeiroMetrics`, and recording helpers for the timer instruments. Record the
exact exported names in the Decision Log so the rest of the milestone uses them
verbatim. If EP-33 has *not* landed, stop: this plan hard-depends on it.

Second (M1.2), add a read-only backlog count to
`keiro/src/Keiro/Timer/Schema.hs`. Add a function

```haskell
-- | Count timers that are scheduled and already due at @now@ — the timer
-- backlog. Read-only; does not claim or modify any row.
countDueTimers :: (Store :> es) => UTCTime -> Eff es Int
countDueTimers now =
  runTransaction $
    Tx.statement now countDueTimersStmt
```

backed by a statement that mirrors `claimDueTimer`'s WHERE clause but counts
instead of locking:

```haskell
countDueTimersStmt :: Statement UTCTime Int
countDueTimersStmt =
  preparable
    """
    SELECT count(*)
    FROM keiro_timers
    WHERE status = 'scheduled'
      AND fire_at <= $1
    """
    (E.param (E.nonNullable E.timestamptz))
    (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))
```

Add `countDueTimers` to the module's export list (after `markTimerFired`) and
re-export it from `keiro/src/Keiro/Timer.hs` (add `, countDueTimers` to the
`-- * Storage` export group, which already re-exports `Keiro.Timer.Schema`'s
storage functions). Use the existing imports already present in
`Keiro.Timer.Schema` (`Hasql.Decoders qualified as D`, `Hasql.Encoders qualified
as E`, `Hasql.Statement (Statement, preparable)`, `runTransaction`); no new
imports are needed.

Third (M1.3), thread the meter into the worker and record the three instruments.
Change `runTimerWorker`'s signature to take a trailing `Maybe KeiroMetrics`:

```haskell
runTimerWorker ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
runTimerWorker metrics now fire = do
  backlog <- countDueTimers now
  recordTimerBacklog metrics backlog          -- keiro.timer.backlog (gauge)
  due <- claimDueTimer now
  case due of
    Nothing -> pure Nothing
    Just timer -> do
      recordTimerFireLag metrics (now `diffUTCTime` (timer ^. #fireAt))  -- keiro.timer.fire.lag (histogram, seconds)
      recordTimerAttempts metrics (timer ^. #attempts)                   -- keiro.timer.attempts (histogram)
      fired <- fire timer
      for_ fired (markTimerFired (timer ^. #timerId))
      pure (Just timer)
```

Notes:
- `recordTimerBacklog` / `recordTimerFireLag` / `recordTimerAttempts` are the
  EP-33 helper names bound at M1.1; substitute the real names.
- `diffUTCTime` comes from `Data.Time.Clock`; add it to the imports in
  `Keiro.Timer.hs`. The fire lag is `now − fireAt`; since the worker only claims
  timers with `fire_at <= now`, this is non-negative. Histograms accept a
  `Double`; `diffUTCTime` yields a `NominalDiffTime` — convert with
  `realToFrac`. The exact unit (seconds) is owned by EP-33's instrument
  definition; the value passed here is seconds.
- `attempts` is an `Int`; convert as the EP-33 helper expects (likely
  `fromIntegral`).
- Adding `IOE :> es` to the constraint: the EP-33 recording helpers are
  `MonadIO`, and `Eff es` is `MonadIO` only when `IOE :> es`. The timer test
  already runs inside `Store.runStoreIO`, which provides `IOE`, so this does not
  break callers. If EP-33's helpers turn out not to need `MonadIO` in `Eff`,
  drop the constraint.
- Recording the backlog gauge *before* the claim is deliberate: it counts the
  due rows as the worker sees them at the start of the pass, including the one it
  is about to claim.

Fourth (M1.4), fix the existing call site. `keiro/test/Main.hs` calls
`runTimerWorker` in the `describe "Keiro.Timer"` block (around line 851 and line
866). Update both to pass the meter as the new first argument. The pre-existing
non-metrics test passes `Nothing`:

```haskell
runTimerWorker Nothing dueTimerTime $ \_ -> do ...
runTimerWorker Nothing dueTimerTime (\_ -> pure (Just firedEventId))
```

Search for any other `runTimerWorker` callers with `grep -rn "runTimerWorker"
keiro/` and fix each the same way. Existing application callers that pass no
meter become "pass `Nothing`" — a one-token change that preserves behavior
(no-op recording).

Fifth (M1.5), add the M1 test. See "Concrete Steps" for the exact test body. It
schedules `counterTimerRequest` (already defined in the test file, due at
`dueTimerTime`), runs the worker once under an in-memory meter, forces an export,
and asserts that `keiro.timer.backlog`, `keiro.timer.fire.lag`, and
`keiro.timer.attempts` each appear in the exported metrics with a sensible value
(backlog ≥ 1, one fire.lag observation, attempts observation of 1).

Acceptance for M1: `cabal test keiro-test` passes, including the new
"records timer backlog, fire lag, and attempts" example; the pre-existing timer
test still passes unchanged in behavior.


### Milestone M2 — projection lag and position-wait timeouts

Scope: record `keiro.projection.lag` when the application drains async-projection
events, and `keiro.projection.wait.timeouts` when a `PositionWait` query times
out. At the end of M2 a test can drive a read model behind the log and assert the
lag gauge, and force a wait timeout and assert the counter.

First (M2.1), add a projection-lag recording entry point. Because the current
tree has no in-library polling drain loop (the application calls
`applyAsyncProjection` per event, as the test does), add a thin helper to
`keiro/src/Keiro/Projection.hs` that the application calls once per drain pass to
record the lag for a subscription. It needs the `Store` effect (to read the head
and the checkpoint) and is therefore an `Eff` action, not a `Tx.Transaction`:

```haskell
{- | Record 'keiro.projection.lag' for one async projection: the number of
events its subscription is behind the global log head. Computed as the store
head global position minus the subscription's checkpoint position (clamped at
0). A no-op when no metrics handle is supplied. Call once per drain pass,
after applying the batch.
-}
recordProjectionLag ::
  (Store :> es) =>
  Maybe KeiroMetrics ->
  AsyncProjection ->
  Eff es ()
recordProjectionLag metrics projection = do
  headPos <- storeHeadPosition
  checkpoint <- fromMaybe (GlobalPosition 0)
                  <$> readSubscriptionPosition (projection ^. #subscriptionName)
  recordProjectionLagValue metrics (positionGap headPos checkpoint)
```

where `recordProjectionLagValue :: (MonadIO m) => Maybe KeiroMetrics -> Int64 ->
m ()` is the EP-33 gauge helper, and the two small local helpers are:

```haskell
storeHeadPosition :: (Store :> es) => Eff es GlobalPosition
storeHeadPosition = do
  recent <- Store.readAllBackward (GlobalPosition 0) 1
  pure $ case Vector.toList recent of
    (event : _) -> event ^. #globalPosition
    []          -> GlobalPosition 0

positionGap :: GlobalPosition -> GlobalPosition -> Int64
positionGap (GlobalPosition headP) (GlobalPosition checkP) = max 0 (headP - checkP)
```

Imports to add in `Keiro.Projection.hs`: `Kiroku.Store.Read (readAllBackward)`
(or `Kiroku.Store qualified as Store` to mirror the test's
`Store.readAllBackward`), `Kiroku.Store.Types (GlobalPosition (..))`,
`Keiro.ReadModel (readSubscriptionPosition)` — note `readSubscriptionPosition`
is currently *not* exported from `Keiro.ReadModel`; add it to that module's
export list (in the `-- * Querying` group) as part of M2.1 so `Keiro.Projection`
can call it. Also import `Data.Vector qualified as Vector` and `Data.Maybe
(fromMaybe)` if not already in scope (the module uses `Keiro.Prelude`, which may
already re-export `fromMaybe`; check and only add what is missing).

Export `recordProjectionLag` from `Keiro.Projection`'s module header (add it to
the `-- * Asynchronous projections` export group).

Rationale recap (see Decision Log): head-minus-checkpoint is a true backlog
count, reuses existing functions, and reads non-zero whenever the projection is
genuinely behind, unlike a per-event age that reads zero when idle.

Second (M2.2), increment `keiro.projection.wait.timeouts` on a position-wait
timeout. Thread `Maybe KeiroMetrics` through the query path:

- `runQueryWith` gains a trailing `Maybe KeiroMetrics` and forwards it to
  `waitIfNeeded`, which forwards it to `waitFor`.
- `runQuery` (which calls `runQueryWith`) gains the same trailing argument and
  forwards it.
- In `waitFor`, when the loop is about to return `Left (ReadModelWaitTimeout
  ...)`, call the EP-33 counter helper first:

  ```haskell
  if elapsedMicros >= options ^. #timeoutMicros
    then do
      recordProjectionWaitTimeout metrics   -- keiro.projection.wait.timeouts (+1)
      pure (Left (ReadModelWaitTimeout (readModel ^. #name) targetPosition observed'))
    else ...
  ```

  `recordProjectionWaitTimeout :: (MonadIO m) => Maybe KeiroMetrics -> m ()` is
  the EP-33 counter helper (adds 1). `waitFor` is already `IOE :> es`, so the
  `MonadIO` requirement is satisfied.

Signature changes for M2.2 (full module paths):

```haskell
-- Keiro.ReadModel
runQuery     :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> ReadModel q r -> q -> Eff es (Either ReadModelError r)
runQueryWith :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> ConsistencyMode -> ReadModel q r -> q -> Eff es (Either ReadModelError r)
waitFor      :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> PositionWaitOptions -> ReadModel q r -> GlobalPosition -> Eff es (Either ReadModelError ())
```

Import `KeiroMetrics` and the helpers from `Keiro.Telemetry` in
`Keiro.ReadModel.hs`.

Third, fix existing read-model call sites. In `keiro/test/Main.hs` the
`describe "Keiro.ReadModel"` block calls `runQueryWith` (lines ~582, ~595) and
`runQuery` (lines ~607, ~611, ~633). Add `Nothing` as the new first argument to
each. Search with `grep -rn "runQuery\b\|runQueryWith" keiro/` and fix every
caller; application callers that do not record metrics pass `Nothing`.

Fourth (M2.3), add the M2 tests. See "Concrete Steps" for bodies:
- A lag test that appends N events via a command, sets the subscription cursor
  deliberately *behind* the head (e.g. checkpoint = head − 2), calls
  `recordProjectionLag Nothing-replaced-by-meter counterAsyncProjection`, forces
  an export, and asserts `keiro.projection.lag` recorded a value ≥ 1.
- A timeout test that reuses the existing "times out when PositionWait target is
  not reached" scenario but runs it under a meter, then asserts
  `keiro.projection.wait.timeouts` was incremented (count ≥ 1).

Acceptance for M2: `cabal test keiro-test` passes including both new examples;
the pre-existing PositionWait tests still pass (now with the extra `Nothing`/meter
argument).


### Milestone M3 — timer stuck gauge (gated on EP-34)

Scope: record `keiro.timer.stuck`. This milestone is *blocked* until EP-34
(`docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md`) has
landed, because the meaning of "stuck" and any new terminal `TimerStatus` are
EP-34's to define. Do not attempt M3 before then; M1 and M2 ship independently.

First (M3.1), read EP-34's outcome from the MasterPlan's Surprises & Discoveries
and from `Keiro.Timer.Schema`: determine the exact "stuck" predicate. Two shapes
are anticipated (use whichever EP-34 actually shipped):

- *Age/attempt threshold on `Firing`*: a timer is stuck if `status = 'firing'`
  and it has been firing longer than some threshold (e.g. `updated_at < now() −
  interval`) or `attempts >= ceiling`. In this case `countStuckTimers` takes the
  threshold parameter(s) EP-34 defines.
- *New terminal status (e.g. `Dead`)*: if EP-34 added a constructor like `Dead`
  to `TimerStatus`, "stuck" may instead mean "needs operator attention" — clarify
  against EP-34 whether the gauge counts `Firing`-past-threshold, `Dead`, or
  both. Use EP-34's own definition verbatim.

Add a read-only `countStuckTimers` to `keiro/src/Keiro/Timer/Schema.hs`,
mirroring `countDueTimers` in shape (a `count(*)` over the stuck predicate),
parameterized exactly as EP-34's definition requires, and export/re-export it the
same way. This stays read-only (no mutation), respecting the shared-file split.

Second (M3.2), record the gauge in `runTimerWorker` alongside the backlog gauge:

```haskell
stuck <- countStuckTimers <stuck-params>
recordTimerStuck metrics stuck            -- keiro.timer.stuck (gauge)
```

placed next to the existing `recordTimerBacklog` call so both gauges are written
once per pass. Add the M3 test: insert a row directly in the `firing` state with
the stuck predicate satisfied (e.g. an old `updated_at`), run the worker under a
meter, force an export, and assert `keiro.timer.stuck` recorded a value ≥ 1.

Acceptance for M3: `cabal test keiro-test` passes including the new stuck-gauge
example, using EP-34's real stuck definition.


### Milestone M4 — minimal operations note

Scope: add one short paragraph to `docs/user/operations.md` noting that the
timer and async-projection workers now emit metrics
(`keiro.timer.backlog`, `keiro.timer.fire.lag`, `keiro.timer.attempts`,
`keiro.timer.stuck`, `keiro.projection.lag`, `keiro.projection.wait.timeouts`)
when a meter is wired, and that the full metrics catalogue is documented by
EP-37. Keep it to a few sentences (MasterPlan: EP-37 owns the consolidated docs;
EP-35/EP-36 keep `operations.md` edits minimal). No test impact.

Acceptance for M4: the note exists and names the six instruments; no behavior
change.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro` unless stated otherwise.

Step 0 — orient and confirm dependencies have landed:

```bash
grep -n "KeiroMetrics\|newKeiroMetrics" keiro/src/Keiro/Telemetry.hs
grep -rn "runTimerWorker" keiro/
grep -rn "runQueryWith\|runQuery\b" keiro/
```

The first command must print the EP-33 exports (if it prints nothing, EP-33 has
not landed — stop). The other two list every call site you must update.

Step 1 — implement M1.2 / M1.3 (timer schema count + worker threading) by
editing `keiro/src/Keiro/Timer/Schema.hs` and `keiro/src/Keiro/Timer.hs` exactly
as described in Plan of Work M1.

Step 2 — update the timer call sites (M1.4) in `keiro/test/Main.hs` to pass the
meter argument (`Nothing` for the pre-existing test).

Step 3 — add the M1 test. The exact body (place it inside the existing
`describe "Keiro.Timer" $ around (withFreshStore fixture)` block, after the
existing example). It uses the EP-33 in-memory metric harness; the helper names
`withInMemoryMeter`, `forceMetricExport`, and `metricSumByName` below stand for
whatever EP-33 actually named them — bind them at M1.1. The shape is: build a
meter, build `KeiroMetrics` from it, run the worker with `Just metrics`, force an
export, read the IORef back, and assert by instrument name.

```haskell
    it "records timer backlog, fire lag, and attempts" $ \storeHandle -> do
      -- EP-33 harness: gives a Meter, a force-export action, and the export IORef.
      (meter, forceExport, exportedRef) <- withInMemoryMeter
      metrics <- newKeiroMetrics meter
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          scheduleTimerTx counterTimerRequest
      let firedEventId = EventId sampleUuid2
      workerResult <- Store.runStoreIO storeHandle $
        runTimerWorker (Just metrics) dueTimerTime (\_ -> pure (Just firedEventId))
      workerResult `shouldSatisfy` \case
        Right (Just _) -> True
        _ -> False
      forceExport
      exported <- readIORef exportedRef
      -- metricPoints exported "<name>" returns the recorded data points for an
      -- instrument by name (EP-33 harness accessor).
      length (metricPoints exported "keiro.timer.backlog")  `shouldSatisfy` (>= 1)
      length (metricPoints exported "keiro.timer.fire.lag") `shouldSatisfy` (>= 1)
      length (metricPoints exported "keiro.timer.attempts") `shouldSatisfy` (>= 1)
```

`scheduleTimerTx counterTimerRequest`, `dueTimerTime`, `sampleUuid2`, and
`EventId` are all already defined in `keiro/test/Main.hs`. `readIORef` is already
imported (line 11). `counterTimerRequest`'s `fireAt = dueTimerTime`, so the
worker (run at `dueTimerTime`) sees it as due: backlog ≥ 1, and the claimed
timer's `attempts` becomes 1 with fire lag 0 seconds (recorded as one
observation).

Step 4 — implement M2.1 / M2.2 by editing `keiro/src/Keiro/Projection.hs` and
`keiro/src/Keiro/ReadModel.hs` as in Plan of Work M2, then update the read-model
call sites in `keiro/test/Main.hs` to pass the new first argument.

Step 5 — add the M2 tests inside `describe "Keiro.ReadModel" $ around
(withFreshStore fixture)`:

```haskell
    it "records projection lag behind the log head" $ \storeHandle -> do
      (meter, forceExport, exportedRef) <- withInMemoryMeter
      metrics <- newKeiroMetrics meter
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction initializeCounterReadModelTable
      let target = stream "read-model-lag" :: Stream CounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions counterEventStream target (Add 1)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions counterEventStream target (Add 1)
      -- Leave the subscription cursor at 0 (no upsert), so the read model is
      -- two events behind the head; the gauge should record a positive lag.
      Store.runStoreIO storeHandle $
        recordProjectionLag (Just metrics) counterAsyncProjection
        >>= either (\e -> liftIO (expectationFailure (show e))) pure
      forceExport
      exported <- readIORef exportedRef
      length (metricPoints exported "keiro.projection.lag") `shouldSatisfy` (>= 1)
      -- The most recent recorded gauge value should be >= 1 (two events, cursor 0).
      lastGaugeValue exported "keiro.projection.lag" `shouldSatisfy` (>= 1)

    it "counts a position-wait timeout" $ \storeHandle -> do
      (meter, forceExport, exportedRef) <- withInMemoryMeter
      metrics <- newKeiroMetrics meter
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction initializeCounterReadModelTable
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement ("counter-read-model-sub", 1) upsertSubscriptionCursorStmt
      queryResult <- Store.runStoreIO storeHandle $
        runQueryWith
          (Just metrics)
          (PositionWait (fastWaitOptions & #target .~ Just (GlobalPosition 5)))
          counterReadModel
          "timeout"
      queryResult `shouldSatisfy` \case
        Right (Left (ReadModelWaitTimeout{})) -> True
        _ -> False
      forceExport
      exported <- readIORef exportedRef
      counterTotal exported "keiro.projection.wait.timeouts" `shouldSatisfy` (>= 1)
```

`metricPoints`, `lastGaugeValue`, and `counterTotal` are EP-33 harness accessors
(bind to their real names at M1.1). `runCommand`, `counterEventStream`,
`defaultRunCommandOptions`, `initializeCounterReadModelTable`,
`upsertSubscriptionCursorStmt`, `fastWaitOptions`, `counterReadModel`,
`counterAsyncProjection`, and `stream` are already defined in the test file. Note
`recordProjectionLag` here returns `Eff es ()` inside `Store`; the `>>=`/`either`
plumbing above is illustrative — if EP-33's helper does not error, simplify to a
plain `Store.runStoreIO storeHandle $ recordProjectionLag (Just metrics)
counterAsyncProjection`.

Step 6 — run the suite and capture the transcript:

```bash
cabal test keiro-test
```

Expected output (counts will differ as examples are added; the key signals are
the new example names passing and a zero failure count):

```text
Resolving dependencies...
Build profile: -w ghc-9.12.x -O1
...
Keiro.Timer
  claims a due timer, fires a command, and marks it complete once
  records timer backlog, fire lag, and attempts
Keiro.ReadModel
  ...
  records projection lag behind the log head
  counts a position-wait timeout
...
Finished in 12.3456 seconds
NN examples, 0 failures
Test suite keiro-test: PASS
```

Step 7 (M3, only after EP-34 lands) — add `countStuckTimers` to
`Keiro.Timer.Schema`, record `keiro.timer.stuck` in `runTimerWorker`, and add the
stuck-gauge test, then re-run `cabal test keiro-test`. The stuck-gauge test
inserts a `firing` row satisfying EP-34's stuck predicate and asserts
`metricPoints exported "keiro.timer.stuck"` is non-empty with a value ≥ 1.

Step 8 (M4) — add the short note to `docs/user/operations.md` and re-read it to
confirm it names all six instruments and points to EP-37 for the full catalogue.


## Validation and Acceptance

The change is validated entirely through `cabal test keiro-test`, run from
`/Users/shinzui/Keikaku/bokuno/keiro`. Acceptance is behavioral:

- M1: After running the timer worker once against a due timer under an in-memory
  meter and forcing an export, the exported metrics contain `keiro.timer.backlog`
  (gauge, value ≥ 1), `keiro.timer.fire.lag` (histogram, ≥ 1 observation), and
  `keiro.timer.attempts` (histogram, ≥ 1 observation). The pre-existing timer
  test still passes with identical behavior (only the extra `Nothing` argument).
- M2: After appending two events and leaving a read model's subscription cursor
  at the start, `recordProjectionLag` under a meter records `keiro.projection.lag`
  with value ≥ 1. After forcing a `PositionWait` query to time out under a meter,
  `keiro.projection.wait.timeouts` is incremented (total ≥ 1) and the query still
  returns `Left (ReadModelWaitTimeout ...)` exactly as before.
- M3 (post-EP-34): After inserting a timer satisfying EP-34's stuck predicate and
  running the worker under a meter, `keiro.timer.stuck` records value ≥ 1.
- No-op safety: every pre-existing example that now passes `Nothing` continues to
  pass, demonstrating that callers supplying no meter are unaffected.

To prove the change is effective beyond compilation, the new examples fail before
the instrumentation is added (no such instrument is ever exported, so
`metricPoints exported "<name>"` is empty and the `>= 1` assertion fails) and
pass after. Run the full suite and confirm `0 failures`.

Interpreting results: a failure naming one of the new examples with "expected:
value >= 1" means the instrument was not recorded — re-check that the helper name
bound at M1.1 matches EP-33's export and that the meter was passed as `Just
metrics`. A compile error mentioning `runTimerWorker`/`runQuery`/`runQueryWith`
arity means a call site still passes the old number of arguments — fix it to add
the leading `Nothing`/`Just metrics`.


## Idempotence and Recovery

Every step is a code edit re-applied by editing the same file; re-running
`cabal test keiro-test` is safe and repeatable. The schema additions
(`countDueTimers`, `countStuckTimers`) are pure `SELECT count(*)` statements with
no side effects, so running the worker any number of times records gauges without
changing data. The new tests each get a fresh store from the suite fixture
(`withFreshStore fixture`), so they do not interfere with one another and can be
re-run any number of times.

If M1 lands but M2 is mid-flight, the tree still compiles and the M1 tests pass:
the milestones touch disjoint functions. If a call-site update is missed, the
build fails loudly with an arity error pointing at the exact line; add the
`Nothing` argument and rebuild. To back out any milestone, revert the edits to
the named files; because the meter argument is `Maybe`, reverting a worker change
only requires also reverting its call-site `Nothing` additions.

The M3 milestone is explicitly recoverable-by-deferral: if EP-34 has not landed,
skip M3 entirely; the five other instruments are complete and shipped on their
own.


## Interfaces and Dependencies

Libraries (all already declared in `keiro/keiro.cabal`; this plan adds no new
dependency):

- `hs-opentelemetry-api` (`OpenTelemetry.Metric.Core`) — instrument types and
  the recording functions `counterAdd` / `gaugeRecord` / `histogramRecord`,
  used *inside* EP-33's helpers, not directly here.
- `hs-opentelemetry-sdk` (`OpenTelemetry.Metric`) — `createMeterProvider`,
  `getMeter`, `exportMetricsOnce` / `forceFlushMeterProvider`,
  `noopMeterProvider` (test harness only).
- `hs-opentelemetry-exporter-in-memory`
  (`OpenTelemetry.Exporter.InMemory.Metric.inMemoryMetricExporter`) — returns
  `(MetricExporter, IORef [ResourceMetricsExport])` for the test harness.
- `kiroku-store` (`Kiroku.Store.Read.readAllBackward`,
  `Kiroku.Store.Types.GlobalPosition`, `RecordedEvent`) — head-position read for
  projection lag.

Consumed by reference (from EP-33,
`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`, via
`Keiro.Telemetry`):

- `KeiroMetrics` — the record of pre-built instruments.
- `newKeiroMetrics :: (MonadIO m) => Meter -> m KeiroMetrics`.
- Recording helpers of shape `(MonadIO m) => Maybe KeiroMetrics -> <value> -> m
  ()` for: `keiro.timer.backlog`, `keiro.timer.fire.lag`,
  `keiro.timer.attempts`, `keiro.timer.stuck`, `keiro.projection.lag`,
  `keiro.projection.wait.timeouts`. Exact names bound at M1.1.
- The in-memory metric test harness (a `Meter` + force-export + exported-IORef
  accessor) built by EP-33.

Consumed by reference (from EP-34,
`docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md`, only at
M3): the formal "stuck timer" predicate and any new `TimerStatus` constructor,
recorded in the MasterPlan's Surprises & Discoveries when EP-34 lands.

Types, interfaces, and signatures that must exist at the end of each milestone
(full module paths):

- End of M1:
  - `Keiro.Timer.Schema.countDueTimers :: (Store :> es) => UTCTime -> Eff es Int`
    (and its statement `countDueTimersStmt`), re-exported from `Keiro.Timer`.
  - `Keiro.Timer.runTimerWorker :: (IOE :> es, Store :> es) => Maybe KeiroMetrics
    -> UTCTime -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe
    TimerRow)`.
- End of M2:
  - `Keiro.Projection.recordProjectionLag :: (Store :> es) => Maybe KeiroMetrics
    -> AsyncProjection -> Eff es ()`.
  - `Keiro.ReadModel.readSubscriptionPosition` exported (newly added to the
    export list).
  - `Keiro.ReadModel.runQuery`, `runQueryWith`, and `waitFor` each take a leading
    `Maybe KeiroMetrics` as shown in Plan of Work M2.
- End of M3:
  - `Keiro.Timer.Schema.countStuckTimers :: (Store :> es) => <stuck-params> ->
    Eff es Int` (parameters per EP-34's definition), re-exported from
    `Keiro.Timer`, and `runTimerWorker` records `keiro.timer.stuck` each pass.

Commit trailers for every implementation commit made while executing this plan:

```text
MasterPlan: docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md
ExecPlan: docs/plans/36-instrument-the-timer-and-projection-workers-with-metrics.md
Intention: intention_01kt5v38ztez0tt5b63nr7gbnx
```
