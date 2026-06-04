---
id: 50
slug: listen-notify-push-delivery-for-subscriptions-and-workflow-resume
title: "LISTEN NOTIFY push delivery for subscriptions and workflow resume"
kind: exec-plan
created_at: 2026-06-03T21:28:37Z
intention: "intention_01kt7npy22e5tb3ybycsgeqdnm"
master_plan: "docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md"
---

# LISTEN NOTIFY push delivery for subscriptions and workflow resume

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today keiro's background workers — the workflow resume / crash-recovery worker
(`keiro/src/Keiro/Workflow/Resume.hs`), the durable-timer worker
(`keiro/src/Keiro/Timer.hs`), and the integration-event outbox publisher
(`keiro/src/Keiro/Outbox.hs`) — make progress by *polling*. Each worker runs one
"claim, process, commit" pass and then `threadDelay`s a fixed interval (the resume
worker's default is one full second; see `defaultWorkflowResumeOptions` in
`keiro/src/Keiro/Workflow/Resume.hs`). That fixed sleep is also the worst-case
latency: when a child workflow completes and journals its parent's awaited
`child:<id>` step, the parent is not re-invoked until the *next* poll pass, which
can be up to `pollInterval` away. For batch workloads a one-second floor is fine.
For an interactive workflow — a human approval that should resume a saga the
instant the approval event lands, or a chain of parent/child workflows that should
cascade to completion without a perceptible stall — a multi-hundred-millisecond
floor per hop is the difference between "snappy" and "laggy".

After this change, those workers stop sleeping a fixed interval and instead **wait
to be woken**. Postgres has a built-in publish/subscribe primitive: a session can
`LISTEN <channel>` to register interest in a named channel, and any session can
`NOTIFY <channel>, <payload>` to wake every listener on that channel. "LISTEN" is
the SQL statement a connection issues to subscribe; "NOTIFY" is the statement that
fires a message; both are plain SQL, require no extension, and deliver across the
existing Postgres connection. The kiroku event store *already* fires a `NOTIFY` on
its `<schema>.events` channel on every append (a database trigger does this — see
Context and Orientation), and *already* runs one dedicated long-lived listener
connection per store that fans those notifications out in-process. This plan makes
keiro's own workers ride that existing wake signal: a worker runs its pass, then
blocks until either (a) a relevant `NOTIFY` arrives — meaning "something was
appended, go look" — or (b) a bounded fallback timeout elapses. On a `NOTIFY` it
wakes within milliseconds; if a `NOTIFY` is ever missed (a listener reconnect, a
dropped notification), the fallback timeout guarantees the worker still runs a poll
pass and drains the work durably.

**What a user can do after this change that they cannot do today:** start a
workflow whose parent waits on a child, complete the child, and observe the parent
resume within roughly a hundred milliseconds instead of up to a full `pollInterval`
later — verified by a test that measures the wakeup latency. And: with the listener
deliberately disabled (the missed-NOTIFY scenario), observe that the same parent
*still* resumes, just on the fallback timeout — verified by a second test proving
push is an optimization layered over the durable poll, never a replacement for it.

**The single most important discovery shaping this plan** (recorded in full in
Surprises & Discoveries): the upstream LISTEN/NOTIFY machinery this feature was
expected to *introduce* in kiroku/shibuya **already exists and ships today**.
Kiroku's bootstrap migration creates a `notify_events()` trigger that fires
`pg_notify('<schema>.events', '<stream_name>,<stream_id>,<stream_version>')` on
every append; `Kiroku.Store.Notification.Notifier` runs one dedicated listener
connection per `KirokuStore`, maintains a broadcast tick channel and a per-category
wake counter, and the kiroku subscription worker's `Category` live loop already
waits on that counter with a 30-second safety-poll fallback. The work that remains
is therefore overwhelmingly **keiro-side**: teach keiro's poll-loop drivers to wait
on kiroku's existing wake signal instead of `threadDelay`. The original
"fire NOTIFY upstream / expose a LISTEN connection" framing from
`docs/research/10-workflow-roadmap.md` §6.11 is already satisfied upstream; this
plan re-scopes the upstream ask down to one small, optional ergonomics item and
forwards it to `docs/research/11-upstream-roadmap.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (keiro-side, spike): **dropped.** `withFreshDatabase`/`runSqlOn` are not exported from
  `Keiro.Test.Postgres`, so the manual-NOTIFY spike + standalone `hasql-notifications` listener
  are replaced by testing the `WakeSignal` against real appends through `withFreshStore` (M3),
  which exercises the real production wake path. See the Decision Log.
- [x] M1 (keiro-side): added `keiro/src/Keiro/Wake.hs` (`WakeSignal`, `WakeReason`,
  `wakeSignalFromStore`, `neverWake`) backed by kiroku's `Notifier.tickChan` (dup'd once,
  zero new connections), added `stm` to the keiro lib deps and `Keiro.Wake` to exposed-modules.
  `cabal build keiro` green (2026-06-03).
- [ ] M2 (keiro-side): add push-aware worker entry points
  `runWorkflowResumeWorkerPush` (and the generic `runPollLoopWith` driver) that
  wait on a `WakeSignal` instead of `threadDelay`, with the existing
  `pollInterval` repurposed as the fallback timeout. The fixed-poll
  `runWorkflowResumeWorker` stays unchanged as the durable baseline.
- [ ] M3 (keiro-side): integration test — measure sub-second resume latency under
  push (parent/child cascade) and assert it is well under the fallback timeout.
- [ ] M4 (keiro-side): fallback-correctness test — disable the wake signal and
  prove the same workflow still drains on the fallback timeout (push dropped ⇒
  poll still works).
- [ ] M5 (keiro-side): document the pool-sizing story (one shared listener
  connection per store, not per worker) and the channel/payload contract in the
  module haddock and in this plan's Interfaces section.
- [ ] M6 (upstream surface): state the re-scoped upstream ask precisely and forward
  it to `docs/research/11-upstream-roadmap.md` as a new Optional entry. No upstream
  code is required for this plan to ship.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The upstream LISTEN/NOTIFY substrate already exists in kiroku — the feature is
  almost entirely keiro-side.** `docs/research/10-workflow-roadmap.md` §6.11
  describes this feature as "replace shibuya-kiroku-adapter's polling with a
  Postgres `LISTEN` channel" and the parent MasterPlan's Dependency Graph assigns
  EP-50 an explicit *upstream* sub-scope ("a notification channel"). On inspection
  of the live kiroku tree that channel is already built and shipped:

  - The bootstrap migration
    `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`
    (lines 145–159) defines:

    ```sql
    -- NOTIFY on stream changes (fires once per append, not per event)
    CREATE OR REPLACE FUNCTION notify_events() RETURNS TRIGGER AS $$
    BEGIN
        PERFORM pg_notify(
            TG_TABLE_SCHEMA || '.events',
            NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version
        );
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS stream_events_notify ON streams;
    CREATE TRIGGER stream_events_notify
        AFTER INSERT OR UPDATE ON streams
        FOR EACH ROW EXECUTE FUNCTION notify_events();
    ```

    So a `NOTIFY` on channel `<schema>.events` (e.g. `kiroku.events`) fires on every
    append, with payload `stream_name,stream_id,stream_version`.

  - `Kiroku.Store.Notification`
    (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Notification.hs`)
    runs the listener. `startNotifier` (lines 113–136) acquires a **dedicated**
    connection, tags it `application_name = 'kiroku-listener'`, issues
    `LISTEN <schema>.events`, and spawns a thread that on each notification both
    writes a `()` tick to a broadcast `TChan` and bumps a per-category counter
    (`handleNotification`, lines 221–225). The `Notifier` record exports
    `tickChan :: TChan ()` and `categoryGenerations :: TVar (Map Text Word64)`
    (lines 44–62). The category is derived from the payload exactly as the
    `streams.category` column is (`categoryFromPayload`, lines 234–238: the prefix
    before the first `-`).

  - `withStore`
    (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Connection.hs`,
    lines 206–266) starts exactly **one** `Notifier` per store (line 249) and stores
    it on the `KirokuStore` handle as the field `notifier :: Notifier` (line 145).
    `KirokuStore(..)` and `Notifier(..)` both export their fields, so a keiro caller
    holding the handle can reach `store.notifier.categoryGenerations`.

  - The kiroku subscription worker already *uses* this for `Category` subscriptions:
    `liveLoopCategoryNotify`
    (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`,
    lines 433–480) blocks on the category's generation counter and falls back to a
    30-second safety poll (`categorySafetyPollMicros`, lines 76–77) so a notification
    lost across a listener reconnect is reconciled. This is the exact
    "push as optimization over a durable poll" shape this plan needs, already proven
    upstream.

  Evidence the listener is **one connection per store, not per subscriber**: `withStore`
  calls `startNotifier` once and every subscriber shares the broadcast `TChan` /
  category-generation `TVar`. This resolves the §6.11 worry that "LISTEN/NOTIFY
  introduces a long-lived connection per subscriber that complicates connection-pool
  sizing" — the long-lived connection already exists and is already amortized across
  all subscribers. (See the Decision Log and the pool-sizing discussion in Plan of
  Work M5.)

- **keiro's resume/timer/outbox workers do NOT currently ride a kiroku
  subscription.** The resume worker's own module docstring is explicit:
  "Discovery is the `findUnfinishedWorkflowIds` index query only — *no kiroku `wf:`
  prefix subscription* is used or needed, so this surface has zero upstream
  dependency" (`keiro/src/Keiro/Workflow/Resume.hs`, lines 44–46). They are
  index-query pollers, not stream consumers. That is why the keiro-side work is to
  add a *wake signal* to the existing poll loop, not to convert the workers into
  shibuya-adapter subscriptions.

(Further discoveries to be appended during implementation.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat the upstream NOTIFY/LISTEN surface as **already delivered** and
  re-scope EP-50 to a keiro-side push-aware poll loop. The only upstream item
  forwarded is an Optional ergonomics helper (a typed "wait for a stream/category
  notification" combinator on `KirokuStore`, so keiro need not reach into the
  `Notifier` record's internals).
  Rationale: The `notify_events()` trigger, the dedicated `kiroku-listener`
  connection, the broadcast `TChan`, the per-category generation counter, and a
  reference poll-fallback loop (`liveLoopCategoryNotify`) all already exist and
  ship in the kiroku tree (see Surprises & Discoveries for `file:line` evidence).
  Inventing a parallel upstream channel would duplicate working machinery and
  contradict the MasterPlan's instruction to scope, not assume, the upstream piece.
  Date: 2026-06-03.

- Decision: Push is layered over polling; the durable guarantee always rests on the
  poll. The fixed-interval workers (`runWorkflowResumeWorker`, `runTimerWorker`,
  `publishClaimedOutbox` schedulers) remain exactly as they are. The new push-aware
  entry points reuse the *same* single-pass primitives (`resumeWorkflowsOnce`,
  `runTimerWorkerWith`, `publishClaimedOutbox`) and only change *when* the next pass
  fires: on a wake signal or on a bounded fallback timeout.
  Rationale: PLANS.md and the MasterPlan both require that correctness never depends
  on a notification arriving. A `NOTIFY` is best-effort (Postgres drops queued
  notifications if the listener is disconnected, and the payload is advisory). Making
  the fallback timeout the durability backstop means a dropped `NOTIFY` only delays
  work to the fallback interval; it never loses it. This mirrors kiroku's own
  `liveLoopCategoryNotify` safety-poll design.
  Date: 2026-06-03.

- Decision: The wake signal keys on the kiroku **category** generation counter, not
  on a bespoke keiro channel. Workflow journal streams are named
  `wf:<workflow-name>-<workflow-id>` (`workflowStreamName`,
  `keiro/src/Keiro/Workflow/Types.hs:86-88`), whose kiroku category is
  `wf:<workflow-name>` (prefix before the first `-`). The resume worker can wait on
  the union of the relevant `wf:*` categories' counters, or — simpler and chosen for
  v1 — wait on the *global* tick channel (`Notifier.tickChan`), which fires on every
  append regardless of category. A global tick may wake the worker for an unrelated
  append; that costs one extra (cheap, indexed) `findUnfinishedWorkflowIds` pass and
  is strictly an over-notification, never an under-notification.
  Rationale: The resume worker's registry can hold workflows of many names, and a
  single workflow's relevant category set changes as workflows are spawned. Waiting
  on the global tick is correct (it fires on every append, so it never misses a
  relevant one), trivially implemented (one `dupTChan` + a fallback timer), and the
  cost of a spurious wake is one indexed query. A per-category refinement (wait only
  on `wf:*` categories) is recorded as a future optimization in Idempotence and
  Recovery; it is not needed for the sub-second acceptance.
  Date: 2026-06-03.

- Decision: Channel-naming scheme and payload are **inherited from kiroku
  unchanged**: channel `<schema>.events` (default `kiroku.events`), payload
  `stream_name,stream_id,stream_version`. keiro does not define its own channel or
  payload. keiro treats the payload as a minimal wake signal and ignores its
  contents (it re-queries durably via `findUnfinishedWorkflowIds`), matching the
  MasterPlan's "minimal: just a wake signal" guidance.
  Rationale: Re-using kiroku's channel means the single existing listener connection
  serves keiro's wake needs for free; a separate keiro channel would need a second
  trigger and a second listener connection, re-introducing exactly the pool-sizing
  concern §6.11 raised. Ignoring the payload keeps correctness independent of payload
  parsing and of which specific stream fired.
  Date: 2026-06-03.

- Decision: The push-aware worker takes the `KirokuStore` handle directly (to reach
  `store.notifier`), in addition to running its discovery pass through the `Store`
  effect via `Kiroku.Store.Effect.runStoreIO`. The application already holds the
  handle and runs workers with `Store.runStoreIO store action` (see
  `jitsurei/app/Main.hs`).
  Rationale: The wake signal lives on the concrete handle (`store.notifier`), not in
  the abstract `Store` effect. Passing the handle to the *driver* (which already runs
  in `IO`) while keeping each *pass* in the `Store` effect keeps the testable
  single-pass primitive (`resumeWorkflowsOnce`) untouched and effect-polymorphic.
  Date: 2026-06-03.


- Decision (implementation): **Adapt to the real test harness and surfaces, which differ
  from the plan's assumptions.** (1) `keiro/test/Main.hs` is an **hspec** suite, not tasty, so
  tests are added as `describe`/`it` blocks in `Main.hs` (filtered with `--match`), not as
  separate tasty modules with `-p`. (2) `Keiro.Test.Postgres` exports only
  `Fixture`/`withMigratedSuite`/`withFreshStore`/`withFreshStores2` — **not** `withFreshDatabase`
  or `runSqlOn` — so the M0 manual-NOTIFY spike and the `hasql-notifications` standalone listener
  are dropped; the `WakeSignal` is instead exercised against **real appends** through
  `withFreshStore` (which runs a live kiroku `Notifier`), which tests the real production wake path
  rather than a synthetic NOTIFY. (3) `runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError,
  IOE] a -> IO (Either StoreError a)`, so `runWorkflowResumeWorkerPush`'s registry row is
  `'[Store, Error StoreError, IOE]`, not the plan's `'[IOE, Store]`. (4) The smoke/latency tests use
  `Control.Concurrent` (`forkIO`/`killThread`) + `System.Timeout.timeout` rather than the `async`
  package, avoiding a new dependency.
  Rationale: the plan's intent (sub-second push latency + durable fallback) is harness-independent;
  these are faithful adaptations to what the repo actually provides, and testing against real
  appends is a stronger end-to-end proof than a manual NOTIFY. Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of keiro, kiroku, or Postgres pub/sub.

**The repositories.** keiro lives at `/Users/shinzui/Keikaku/bokuno/keiro` (this
repo). It is a Haskell event-sourcing framework built on three dependencies you will
need to read:

- **kiroku** — the Postgres event store, at
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Its core package is
  `kiroku-store` (`.../kiroku-store/src/Kiroku/Store/...`). To find any kiroku
  source on disk, run `mori registry show shinzui/kiroku --full`; the path above is
  the registered root.
- **shibuya** — the supervised queue-processing framework, at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. Its kiroku bridge is the
  separate package `shibuya-kiroku-adapter` at
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter`.
- **keiki** — the pure functional core; not relevant to this plan.

**Postgres LISTEN/NOTIFY, defined.** PostgreSQL has a built-in asynchronous
messaging primitive with two SQL statements. A database session issues
`LISTEN some_channel;` to register interest in a named channel. Any session (the
same one or another) issues `NOTIFY some_channel, 'some payload';` to send a message
to every session currently listening on `some_channel`. The listening session
receives the payload asynchronously over its existing connection (in libpq, via the
notification queue you poll or block on). Notifications are *best-effort across
disconnects*: if a listening session is not connected at the moment a `NOTIFY`
fires, that notification is gone — Postgres does not durably queue it. This is why
push must always be backed by a durable poll. NOTIFY messages fired inside a
transaction are delivered only when (and if) that transaction commits, so a
listener is never woken for an append that rolled back.

**Where the NOTIFY fires (upstream, already built).** Kiroku's bootstrap migration
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`
(lines 145–159) creates a trigger `stream_events_notify` on the `streams` table that
runs `notify_events()` after every insert/update. That function calls
`pg_notify('<schema>.events', '<stream_name>,<stream_id>,<stream_version>')`. With
the default schema `kiroku`, the channel is `kiroku.events`. The comment is precise:
"fires once per append, not per event" — the `streams` row's `stream_version` is
bumped once per append regardless of how many events that append carried.

**Who listens (upstream, already built).** `Kiroku.Store.Notification`
(`.../kiroku-store/src/Kiroku/Store/Notification.hs`) defines `Notifier`, started
once per store by `withStore`
(`.../kiroku-store/src/Kiroku/Store/Connection.hs:206-266`). The `Notifier`:

- holds a **dedicated** Postgres connection (separate from the query pool), tagged
  `application_name = 'kiroku-listener'` so operators can see it in
  `pg_stat_activity`, that issues `LISTEN kiroku.events`;
- exposes `tickChan :: TChan ()` — a broadcast channel that gets a `()` written on
  *every* notification (consumers call STM `dupTChan` to get a private copy); and
- exposes `categoryGenerations :: TVar (Map Text Word64)` — a per-category counter
  bumped on every notification, where the category is the stream-name prefix before
  the first `-`.

It reconnects with capped exponential backoff and tolerates lost notifications by
relying on consumers' safety-poll fallbacks. The `KirokuStore` handle carries this
as its `notifier` field; both `KirokuStore(..)` and `Notifier(..)` export their
fields, so keiro code holding the handle can read `store.notifier.tickChan`.

**keiro's workers (what this plan changes).** Three background workers in keiro run
the classic "claim work, process it, commit, then wait, repeat" shape:

- **The workflow resume / crash-recovery worker**, `keiro/src/Keiro/Workflow/Resume.hs`.
  Its single-pass primitive is `resumeWorkflowsOnce` (lines 199–251): it queries
  `findUnfinishedWorkflowIds` (workflows that have journaled steps but no terminal
  completion marker) plus `findRunningChildIds`, and re-invokes each through
  `runWorkflowWith` / `runChildWorkflow`. Re-invocation is idempotent: an
  already-journaled step short-circuits, so only the un-journaled tail runs, and a
  completed workflow drops out of discovery. The loop driver
  `runWorkflowResumeWorkerWith` (lines 270–277) is literally
  `forever $ do { resumeWorkflowsOnce …; threadDelay (pollInterval opts) }`. The
  default `pollInterval` is `1_000_000` µs = 1 second (`defaultWorkflowResumeOptions`,
  lines 147–153). This fixed sleep is the latency this plan attacks.

- **The durable-timer worker**, `keiro/src/Keiro/Timer.hs`. `runTimerWorkerWith`
  claims at most one due timer per pass with `FOR UPDATE SKIP LOCKED` and fires it.
  The application schedules it per tick.

- **The integration-event outbox publisher**, `keiro/src/Keiro/Outbox.hs`.
  `publishClaimedOutbox` claims a batch and publishes each row; the application
  schedules it per tick. (Outbox push is in scope only as documentation: the same
  wake primitive applies, but the acceptance tests target the resume worker because
  it has the clearest interactive-latency story via parent/child cascades.)

The common shape — a testable single-pass function plus a thin loop driver that
sleeps a fixed interval — is what makes the push retrofit minimal: replace the
fixed sleep with "wait for wake or fallback timeout".

**How the application runs a worker.** The application holds a `KirokuStore` (from
`Kiroku.Store.withStore`) and runs effectful actions with `Store.runStoreIO store
action` (see `jitsurei/app/Main.hs`, which runs `runWorkflow` and the resume worker
this way). So a push-aware worker entry point can accept the handle and still run
each pass in the `Store` effect.

**Test infrastructure.** keiro's database tests use `keiro-test-support`
(`keiro-test-support/src/Keiro/Test/Postgres.hs`). It spins up an ephemeral Postgres
(via the `ephemeral-postgres` machinery), migrates a *template* database once per
suite, and clones a fresh database per test. The two helpers this plan uses:

- `withFreshStore :: Fixture -> (Store.KirokuStore -> IO ()) -> IO ()` — clones a
  fresh migrated DB and opens a `KirokuStore` (with its notifier + publisher) against
  it (lines 96–99).
- `withFreshDatabase :: Fixture -> (Text -> IO a) -> IO a` — clones a fresh DB and
  hands you its **libpq connection string** (lines 114–117). Combined with
  `runSqlOn :: Text -> Text -> IO ()` (lines 176–186), which runs an arbitrary SQL
  command against a connection string, this is how a test issues a **manual
  `NOTIFY`** to prove the LISTEN wait wakes without needing a real append.

Tests live in `keiro/test/Main.hs` (a single tasty entry point); new test modules
are added under `keiro/test/` and wired into that `Main`.

**Why "category" matters here.** A keiro workflow's journal stream is
`wf:<workflow-name>-<workflow-id>` (`workflowStreamName`,
`keiro/src/Keiro/Workflow/Types.hs:86-88`). Its kiroku category — the prefix before
the first `-` — is `wf:<workflow-name>`. So a `NOTIFY` for any append to a workflow
journal carries a payload whose category is `wf:<name>`, and bumps that category's
generation counter. This plan's v1 waits on the *global* tick (every append) rather
than filtering to `wf:*` categories, for the reasons in the Decision Log; the
category mechanism is documented because the per-category refinement is the natural
future optimization.


## Plan of Work

The work is six milestones. M0–M5 are **keiro-side** and are everything needed for
the feature to ship and pass acceptance. M6 is the **upstream surface**: it requires
no upstream code for this plan to ship and only records a re-scoped, Optional
ergonomics ask. Each milestone is independently verifiable.

### M0 — Spike: prove the LISTEN wait wakes on a manual NOTIFY (keiro-side)

**Scope.** Before changing any worker, prove the raw mechanism in isolation: a
session that `LISTEN kiroku.events` wakes when another session issues
`NOTIFY kiroku.events, '...'`. This de-risks every later milestone and is the
literal mechanism the acceptance test in M4 reuses.

**What will exist at the end.** A throwaway test module
`keiro/test/Keiro/WakeSpikeSpec.hs` (wired into `keiro/test/Main.hs`) that, against
an ephemeral database, opens a dedicated listener connection with
`hasql`/`hasql-notifications`, issues a manual `NOTIFY` via `runSqlOn`, and asserts
the listener's callback fires within, say, 500 ms.

**How.** Use `keiro-test-support`'s `withFreshDatabase` to get a connection string.
Open a listener connection with `Hasql.Connection.acquire`, `Hasql.Notifications.listen`
on the `kiroku.events` channel, and a `waitForNotifications` callback that writes to
an `MVar`. From a *second* connection (or `runSqlOn connStr "NOTIFY kiroku.events,
'wf:demo-1,1,1'"`), fire the notification. Assert the `MVar` is filled before a
timeout.

**Acceptance.** `cabal test keiro:test --test-options='-p WakeSpike'` passes; the
listener callback observed the manual NOTIFY. (The kiroku `Notifier` already does
exactly this internally, so this spike is mostly a confidence check that the
ephemeral DB, channel name, and `hasql-notifications` wiring behave as expected in
the keiro test harness.) Mark the spike module for deletion or fold it into M3/M4
once those land; record the decision in Progress.

### M1 — A `WakeSignal` primitive (keiro-side)

**Scope.** Introduce a tiny, reusable "wait until notified or until a bounded
timeout" abstraction so the worker drivers do not each re-derive the STM. It is
backed by kiroku's existing `Notifier` so no new connection is opened.

**What will exist at the end.** A new module `keiro/src/Keiro/Wake.hs` exporting:

```haskell
-- | A source of "something was appended, go look" wake-ups, layered over a
-- bounded fallback timeout so a missed notification never stalls progress.
data WakeSignal = WakeSignal
  { waitForWake :: Int -> IO WakeReason
  -- ^ Block until a notification arrives OR the given fallback timeout
  --   (microseconds) elapses, whichever is first. Returns which happened.
  }

data WakeReason = WokenByNotify | WokenByTimeout
  deriving stock (Eq, Show)

-- | Build a 'WakeSignal' from a running kiroku store's notifier. Duplicates the
-- broadcast tick channel ('dupTChan') so this consumer has its own cursor and
-- never steals another consumer's ticks. Opens NO new database connection: it
-- rides the single dedicated listener connection the store already holds.
wakeSignalFromStore :: KirokuStore -> IO WakeSignal

-- | A 'WakeSignal' that never fires a notification — every wait elapses the
-- fallback timeout. Used to simulate "all NOTIFYs dropped" and to give the
-- fixed-poll workers an unchanged shape under the same driver.
neverWake :: WakeSignal
```

**How.** `wakeSignalFromStore store` reads `store.notifier.tickChan`, `dupTChan`s
it once, and returns a `WakeSignal` whose `waitForWake timeoutMicros` does:

```haskell
waitForWake timeoutMicros = do
  myChan <- atomically (dupTChan tickChan)   -- done once at construction, not per call
  timer  <- registerDelay timeoutMicros
  atomically $
        (readTChan myChan >> pure WokenByNotify)
    `orElse`
        (readTVar timer >>= check >> pure WokenByTimeout)
```

(The `dupTChan` is performed once when the `WakeSignal` is built, not on every wait,
so ticks arriving between waits are not lost — they queue in the duplicated channel.
Drain any backlog non-blockingly at the start of each wait so a single wait does not
return immediately for each of N queued ticks; one return per "there is new work"
episode is sufficient because the worker re-queries durably.) `neverWake` ignores
the channel and only arms the `registerDelay` timer.

**Acceptance.** Unit test in `keiro/test/Keiro/WakeSpec.hs`: construct a `WakeSignal`
over a store, assert `waitForWake` returns `WokenByTimeout` when idle within a small
margin of the timeout, and `WokenByNotify` promptly after a manual `NOTIFY`. Assert
`neverWake` always returns `WokenByTimeout`.

### M2 — Push-aware worker entry points (keiro-side)

**Scope.** Add a generic push-aware loop driver and a workflow-resume entry point
that uses it. Leave every existing fixed-interval entry point untouched.

**What will exist at the end.** In `keiro/src/Keiro/Workflow/Resume.hs`, two new
exports:

```haskell
-- | Generic push-aware poll loop: run one pass, then block on the wake signal
-- with the given fallback timeout, forever. The pass is the durable unit; the
-- wake only shortens the gap between passes. A missed NOTIFY costs at most one
-- fallback interval of latency, never lost work.
runPollLoopWith ::
  WakeSignal ->
  Int ->            -- fallback timeout (microseconds)
  IO () ->          -- one pass (already wrapped to run in IO)
  IO ()

-- | The workflow resume worker, push-aware. Runs 'resumeWorkflowsOnce' on each
-- pass; between passes it waits on the store's notifier (sub-second wake on any
-- append) and falls back to 'pollInterval' (now the fallback timeout, not a
-- fixed sleep) so a dropped notification still drains the backlog.
runWorkflowResumeWorkerPush ::
  KirokuStore ->
  WorkflowResumeOptions ->
  WorkflowRegistry '[IOE, Store] ->
  IO ()
```

**How.**
- `runPollLoopWith wake fallback pass = forever (pass >> waitForWake wake fallback)`.
  It ignores the returned `WakeReason` for control flow (both reasons mean "run
  another pass"); the reason is available for telemetry if desired.
- `runWorkflowResumeWorkerPush store opts registry` builds
  `wake <- wakeSignalFromStore store`, then runs `runPollLoopWith wake (pollInterval
  opts) onePass` where `onePass = void (Store.runStoreIO store (resumeWorkflowsOnce
  opts registry))`. The `pollInterval` field is **repurposed** as the fallback
  timeout — its meaning shifts from "fixed gap" to "maximum gap when no notification
  arrives", which is strictly better for latency and identical for the
  no-notification worst case. Document this repurposing in the haddock.

  Note on the registry's effect row: `resumeWorkflowsOnce` is
  `(IOE :> es, Store :> es) => WorkflowResumeOptions -> WorkflowRegistry es -> Eff es
  ResumeSummary`. The push entry point pins `es ~ '[IOE, Store]` (the concrete row
  `runStoreIO` provides) so the registry type is fully determined for the
  application; if a caller needs a richer row, they can use `runPollLoopWith`
  directly with their own `runStoreIO`-equivalent. Record this choice in Progress.

- A symmetric `runTimerWorkerPush` and an outbox push scheduler are *documented* in
  Interfaces as the same pattern but are **out of scope to implement** in this plan
  (the resume worker carries acceptance); note this so a future contributor adds
  them mechanically.

**Acceptance.** The module compiles and exports the new entry points; the existing
`runWorkflowResumeWorker` / `runWorkflowResumeWorkerWith` are byte-for-byte
unchanged. A smoke test constructs `runWorkflowResumeWorkerPush` over a fresh store,
runs it on an `Async`, and cancels it — proving it starts and stops cleanly.

### M3 — Sub-second latency acceptance (keiro-side)

**Scope.** Prove the user-visible win: a parent workflow waiting on a child resumes
within sub-second of the child's completion under push, versus up to `pollInterval`
without it.

**What will exist at the end.** An integration test
`keiro/test/Keiro/PushLatencySpec.hs` that, against a fresh store:

1. Registers a parent workflow that awaits a child and a child workflow.
2. Starts the child, runs it to completion (its completion journals the parent's
   awaited `child:<id>` step and fires the kiroku `NOTIFY` on append).
3. Runs `runWorkflowResumeWorkerPush store opts registry` with a *deliberately large*
   `pollInterval` (say 10 seconds) so that if push did **not** work, the parent could
   not possibly resume in under 10 s.
4. Measures wall-clock time from the child's completion append to the parent reaching
   `Completed` (observed via the resume summary / a completion marker).

**Acceptance.** The measured latency is well under one second (assert, e.g., `< 1 s`),
and far under the 10 s `pollInterval` — proving the parent resumed because of the
`NOTIFY`, not because of the fallback. Capture the measured value in this plan's
Validation section and in Outcomes.

### M4 — Fallback correctness acceptance (keiro-side)

**Scope.** Prove push is strictly an optimization: with notifications disabled, the
same scenario still completes — just on the fallback timeout.

**What will exist at the end.** A variant test
`keiro/test/Keiro/PushFallbackSpec.hs` that runs the M3 scenario but drives the
worker with `runPollLoopWith neverWake fallback onePass`, where `neverWake` never
delivers a notification and `fallback` is small (say 200 ms). This simulates "every
NOTIFY was dropped".

**Acceptance.** The parent still reaches `Completed`, on roughly the fallback
interval (assert it completes, and that it took at least one fallback interval and no
more than a small multiple). This proves the durable poll alone drains the work; the
notification only shortens latency.

(Optionally, a stronger variant: run the real `runWorkflowResumeWorkerPush` but
delete/disable the trigger via SQL — `DROP TRIGGER stream_events_notify ON kiroku.streams;`
through `runSqlOn` — so no real `NOTIFY` fires, and assert the same fallback-drain
behavior. Prefer the `neverWake` variant as the primary test because it does not
mutate schema; keep the trigger-drop variant as a documented manual check.)

### M5 — Pool-sizing and contract documentation (keiro-side)

**Scope.** Document, in the new module's haddock and in this plan, the two
operational facts that make this safe: the pool-sizing story and the channel/payload
contract.

**Pool-sizing story (the §6.11 concern, resolved).** §6.11 worried that
"LISTEN/NOTIFY introduces a long-lived connection per subscriber that complicates
connection-pool sizing." This plan introduces **zero** new long-lived connections.
The single dedicated `kiroku-listener` connection already exists per `KirokuStore`
(opened by `withStore`, separate from the query pool, tagged in `pg_stat_activity`).
keiro's `WakeSignal` rides that connection by `dupTChan`-ing the in-process broadcast
channel — an STM operation, not a database connection. N keiro workers over one store
share one listener connection and N cheap STM cursors. The documented cap is
therefore: **one listener connection per store, independent of the number of
push-aware workers.** The query pool (`poolSize` in the connection settings) is sized
exactly as before; push adds nothing to it. If an operator runs multiple stores
(schema-per-tenant), that is one listener connection per store, which is the existing
kiroku contract and not changed by this plan.

**Channel/payload contract.** Inherited from kiroku: channel `<schema>.events`
(default `kiroku.events`); payload `stream_name,stream_id,stream_version`. keiro
treats the notification as an opaque wake signal and ignores the payload; correctness
rests on the subsequent durable `findUnfinishedWorkflowIds` query. keiro defines no
channel of its own.

**Acceptance.** The haddock in `keiro/src/Keiro/Wake.hs` and the
`runWorkflowResumeWorkerPush` haddock state both facts; this plan's Interfaces and
Idempotence sections record them. A reader can answer "how many connections does push
add?" (zero) and "what wakes the worker?" (kiroku's `kiroku.events` NOTIFY) from the
docs alone.

### M6 — Upstream surface (scoped, forwarded; no upstream code required)

**Scope.** Record the precise, re-scoped upstream ask and forward it to
`docs/research/11-upstream-roadmap.md`. This plan ships without it.

**The ask, precisely stated.** Today keiro reaches `store.notifier.tickChan` /
`store.notifier.categoryGenerations` by importing `Kiroku.Store.Notification` and
`Kiroku.Store.Connection` and reading the `Notifier`/`KirokuStore` record fields
directly. That works (the fields are exported) but couples keiro to kiroku's internal
representation. The Optional ergonomics ask is a small public combinator on kiroku
that returns a wake handle without exposing the `Notifier` internals, for example:

```haskell
-- in Kiroku.Store (re-exported), kiroku-side
-- | A duplicated wake channel for this store's append notifications. STM-only;
-- opens no connection. Optionally scoped to a category prefix.
storeWakeChannel :: KirokuStore -> IO (TChan ())
storeWakeCategoryGen :: KirokuStore -> Text -> IO (TVar Word64)   -- per-category counter view
```

**Priority and disposition.** Optional. keiro v1 ships by reading the exported record
fields; the combinator is a maintenance nicety that decouples keiro from the
`Notifier` record shape. This is the *only* upstream item EP-50 carries, and it is
not on the critical path.

**Forwarding.** Add a new subsection to `docs/research/11-upstream-roadmap.md` under
the kiroku-store roadmap (§4), e.g. "§4.11 — public store-wake combinator (Optional;
Provenance: EP-50)", noting that the underlying LISTEN/NOTIFY substrate (the
`notify_events` trigger, the `Notifier`, the per-category counters) already shipped in
the 2026-05-16 bootstrap migration and that EP-50 found the §6.11 channel already
present. Record in this plan's Progress when the forwarding edit lands.

**Acceptance.** `docs/research/11-upstream-roadmap.md` contains the new Optional entry
with the signature sketch and the "already-shipped substrate" note; this plan's
Interfaces section restates it.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`
unless noted. The toolchain is `cabal`. The test suite is `keiro:test` (a tasty
runner; filter with `--test-options='-p <pattern>'`).

**Confirm the upstream substrate exists (read-only, no build).**

```bash
mori registry show shinzui/kiroku --full
grep -n "pg_notify\|notify_events\|stream_events_notify" \
  /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql
```

Expected: the `grep` shows the `notify_events()` function calling
`pg_notify(TG_TABLE_SCHEMA || '.events', NEW.stream_name || ',' || NEW.stream_id ||
',' || NEW.stream_version)` and the `stream_events_notify` trigger on `streams`.

**M0 — spike (write the file, then run):**

```bash
$EDITOR keiro/test/Keiro/WakeSpikeSpec.hs   # listener over withFreshDatabase + manual NOTIFY
$EDITOR keiro/test/Main.hs                   # wire the spec into the tasty tree
cabal test keiro:test --test-options='-p WakeSpike'
```

Expected transcript (abridged):

```text
WakeSpike
  listener wakes on a manual NOTIFY: OK (0.42s)

All 1 tests passed (0.42s)
```

The manual NOTIFY the spike issues is exactly:

```sql
NOTIFY "kiroku.events", 'wf:demo-1,1,1';
```

issued through `runSqlOn connStr` (note: the channel name `kiroku.events` contains a
`.`, so it must be quoted as an identifier in the `NOTIFY` statement, or issued via
`pg_notify('kiroku.events', 'wf:demo-1,1,1')` which avoids the quoting question —
prefer the `SELECT pg_notify(...)` form in the test).

**M1–M2 — implement and build:**

```bash
$EDITOR keiro/src/Keiro/Wake.hs                 # WakeSignal, wakeSignalFromStore, neverWake
$EDITOR keiro/src/Keiro/Workflow/Resume.hs      # runPollLoopWith, runWorkflowResumeWorkerPush
$EDITOR keiro/keiro.cabal                        # add Keiro.Wake to exposed-modules
cabal build keiro
```

Expected: clean build. If a new `.cabal` exposed-module is added but GHC reports it
cannot find `Keiro.Wake`, re-run `cabal build keiro` after saving the `.cabal`
(cabal re-reads the module list on the next invocation).

**M1–M2 — unit/smoke tests:**

```bash
cabal test keiro:test --test-options='-p Wake'        # WakeSpec: timeout vs notify, neverWake
cabal test keiro:test --test-options='-p ResumePushSmoke'
```

**M3 — latency acceptance:**

```bash
$EDITOR keiro/test/Keiro/PushLatencySpec.hs
cabal test keiro:test --test-options='-p PushLatency'
```

Expected transcript (abridged; the measured latency is recorded in Validation):

```text
PushLatency
  parent resumes sub-second after child completes (pollInterval=10s): OK (0.13s)
    measured resume latency: 0.087s

All 1 tests passed (0.13s)
```

**M4 — fallback acceptance:**

```bash
$EDITOR keiro/test/Keiro/PushFallbackSpec.hs
cabal test keiro:test --test-options='-p PushFallback'
```

Expected: passes; the parent completes on the ~200 ms fallback with no notification.

**Full suite (final gate):**

```bash
cabal test keiro:test
```

Expected: all tests pass, including the unchanged existing resume-worker tests.


## Validation and Acceptance

Acceptance is two observable behaviors, each backed by an automated test, plus a
documentation gate.

**1. Sub-second wakeup under push (latency win).** With `runWorkflowResumeWorkerPush`
driving the resume worker and a deliberately large `pollInterval` (10 s) as the
fallback, a parent workflow waiting on a child resumes within sub-second of the
child's completion append. Test: `keiro/test/Keiro/PushLatencySpec.hs`, run with
`cabal test keiro:test --test-options='-p PushLatency'`. The assertion is "measured
resume latency `< 1 s`" while the fallback is 10 s, so a pass is only possible if the
kiroku `NOTIFY` woke the worker (the fallback could not have fired in under 10 s).
Record the measured value here when M3 lands. Interpretation: a pass proves push
works and delivers the interactive-latency win; a failure where the latency is
~10 s would indicate the notification path is not wired (worker is falling back to
the poll only).

**2. Correctness preserved when NOTIFY is dropped (durability backstop).** With the
worker driven by `runPollLoopWith neverWake fallback onePass` (no notification ever
delivered) and a small fallback (200 ms), the same parent still reaches `Completed`.
Test: `keiro/test/Keiro/PushFallbackSpec.hs`, run with
`cabal test keiro:test --test-options='-p PushFallback'`. The assertion is "parent
completes, taking at least one and at most a few fallback intervals". Interpretation:
a pass proves the durable poll alone drains the work — push is an optimization, not a
dependency. A documented manual variant drops the `stream_events_notify` trigger via
`runSqlOn connStr "DROP TRIGGER stream_events_notify ON kiroku.streams"` and runs the
real `runWorkflowResumeWorkerPush`, expecting the same fallback-drain (kept manual to
avoid schema mutation in the automated suite).

**3. The mechanism wakes on a manual NOTIFY (M0 spike / M1 unit).** `WakeSpec` /
`WakeSpike` prove a listener wakes within ~500 ms of a manual
`SELECT pg_notify('kiroku.events', '…')`, independent of any worker. This isolates
the LISTEN/NOTIFY wiring from the worker logic and is the in-repo substitute for an
end-to-end upstream-NOTIFY test (though, per Surprises & Discoveries, the real
upstream NOTIFY already fires on append, so M3 exercises the *real* path and M0/M1
exercise the manual-NOTIFY path).

**4. No regression in the fixed-poll path.** `cabal test keiro:test` passes in full,
including the unchanged `runWorkflowResumeWorker` tests, proving the additive entry
points did not alter the durable baseline.

**5. Documentation gate.** The haddock for `keiro/src/Keiro/Wake.hs` and
`runWorkflowResumeWorkerPush` states (a) push adds zero connections — one shared
`kiroku-listener` per store — and (b) the channel is kiroku's `kiroku.events` with
the `stream_name,stream_id,stream_version` payload, treated as an opaque wake.


## Idempotence and Recovery

Every step is safe to repeat. Editing source and re-running `cabal build` /
`cabal test` is idempotent. The tests use `keiro-test-support`'s clone-per-test
fixture, so each run starts from a fresh migrated database and re-running a test
never carries state between runs.

The runtime behavior is idempotent by construction, inherited unchanged from the
existing workers:

- A wake (whether by `NOTIFY` or by timeout) only triggers `resumeWorkflowsOnce`,
  which is already idempotent: `findUnfinishedWorkflowIds` returns only workflows
  lacking a terminal marker, re-invocation short-circuits already-journaled steps,
  and a completed workflow drops out of discovery (see `resumeWorkflowsOnce` haddock,
  `keiro/src/Keiro/Workflow/Resume.hs:184-198`). Two wakes in quick succession
  therefore converge to the same journal with each side effect run at most once.
- A **spurious wake** (the global tick fired for an unrelated append) costs exactly
  one extra indexed `findUnfinishedWorkflowIds` query that finds nothing new. This is
  the deliberate trade for waiting on the global tick rather than filtering to `wf:*`
  categories (Decision Log). It is an over-notification, never an under-notification.
- A **missed `NOTIFY`** (listener mid-reconnect, or notification dropped because the
  listener was momentarily disconnected) is recovered by the fallback timeout: the
  next pass runs no later than `fallback` microseconds after the previous one,
  exactly as the original fixed-poll loop did. Correctness never depends on a
  notification arriving.

**Recovery / rollback.** The change is purely additive: new module `Keiro.Wake`, new
exports on `Keiro.Workflow.Resume`. To roll back, the application simply calls the
unchanged `runWorkflowResumeWorker` (fixed poll) instead of
`runWorkflowResumeWorkerPush`. No schema change, no migration, nothing to undo in the
database. The kiroku trigger and listener are pre-existing and untouched.

**Future optimization (recorded, not implemented).** Refine `wakeSignalFromStore` to
wait on the specific `wf:*` category counters in `store.notifier.categoryGenerations`
rather than the global tick, eliminating spurious wakes from unrelated categories.
This requires the worker to know which categories it cares about (derivable from the
registry's workflow names) and to re-arm the wait as the relevant category set
changes. It is a strict reduction in spurious wakes with identical correctness; defer
until a profiled workload shows spurious-wake query volume matters.


## Interfaces and Dependencies

**New keiro module: `Keiro.Wake`** (`keiro/src/Keiro/Wake.hs`).

```haskell
module Keiro.Wake
  ( WakeSignal (..)
  , WakeReason (..)
  , wakeSignalFromStore
  , neverWake
  ) where

import Kiroku.Store.Connection (KirokuStore (..))     -- exposes the 'notifier' field
import Kiroku.Store.Notification (Notifier (..))        -- exposes 'tickChan'

data WakeSignal = WakeSignal { waitForWake :: Int -> IO WakeReason }
data WakeReason = WokenByNotify | WokenByTimeout deriving stock (Eq, Show)

wakeSignalFromStore :: KirokuStore -> IO WakeSignal
neverWake :: WakeSignal
```

`wakeSignalFromStore` opens no database connection; it `dupTChan`s the store's
existing broadcast tick channel (`store.notifier.tickChan`). `waitForWake t` blocks
until a tick arrives or `t` microseconds elapse, returning which occurred.

**New exports on `Keiro.Workflow.Resume`** (`keiro/src/Keiro/Workflow/Resume.hs`):

```haskell
runPollLoopWith ::
  WakeSignal ->
  Int ->             -- fallback timeout in microseconds
  IO () ->           -- one pass, pre-wrapped to IO
  IO ()

runWorkflowResumeWorkerPush ::
  KirokuStore ->
  WorkflowResumeOptions ->
  WorkflowRegistry '[IOE, Store] ->
  IO ()
```

`runWorkflowResumeWorkerPush store opts registry` is the push-aware sibling of the
existing `runWorkflowResumeWorker`/`runWorkflowResumeWorkerWith` (which remain
unchanged as the durable fixed-poll baseline). It builds a `WakeSignal` from the
store, then loops `resumeWorkflowsOnce opts registry` (run via
`Kiroku.Store.Effect.runStoreIO`), waiting on the signal between passes with
`pollInterval opts` *repurposed as the fallback timeout*. The same pattern applies
mechanically to `Keiro.Timer.runTimerWorker` and `Keiro.Outbox.publishClaimedOutbox`
(documented, not implemented in this plan).

**Dependencies used (all already in keiro's dependency set or kiroku's public API):**

- `Kiroku.Store.Connection (KirokuStore (..))` — the store handle and its `notifier`
  field. `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Connection.hs:142-179`.
- `Kiroku.Store.Notification (Notifier (..))` — `tickChan`, `categoryGenerations`.
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Notification.hs:44-62`.
- `Kiroku.Store.Effect (Store, runStoreIO)` — to run each pass in the `Store` effect
  against the concrete handle (the `runStoreIO store action` shape the app already
  uses, see `jitsurei/app/Main.hs`).
- `Control.Concurrent.STM` (`TChan`, `dupTChan`, `readTChan`, `registerDelay`,
  `readTVar`, `check`, `orElse`, `atomically`) — the wait primitive.
- `keiro-test-support` (`Keiro.Test.Postgres`: `withFreshStore`, `withFreshDatabase`,
  `runSqlOn`) — the ephemeral-DB fixture and the raw-SQL escape hatch used to issue a
  manual `NOTIFY` in tests.
- `hasql` / `hasql-notifications` — used only in the M0 spike to open a standalone
  listener; the production path rides kiroku's `Notifier` and needs neither directly.

**The upstream ask (re-scoped, Optional), to forward to
`docs/research/11-upstream-roadmap.md`:** a public combinator on kiroku that returns
a wake channel (and/or a per-category counter view) without exposing the `Notifier`
record internals, e.g. `storeWakeChannel :: KirokuStore -> IO (TChan ())`. The
underlying LISTEN/NOTIFY substrate (the `notify_events` trigger, the dedicated
listener connection, the per-category counters) **already shipped** in the
2026-05-16 kiroku bootstrap migration, so this is the *only* upstream surface EP-50
carries and it is not on the critical path. keiro v1 ships by reading the exported
record fields directly.

---

Git trailers — every commit made while working on this plan must carry:

```text
MasterPlan: docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md
ExecPlan: docs/plans/50-listen-notify-push-delivery-for-subscriptions-and-workflow-resume.md
Intention: intention_01kt7npy22e5tb3ybycsgeqdnm
```
