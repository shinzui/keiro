---
id: 39
slug: durable-sleep-on-the-timer-table
title: "Durable sleep on the timer table"
kind: exec-plan
created_at: 2026-06-03T14:39:45Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
master_plan: "docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md"
---

# Durable sleep on the timer table


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture


After this change a workflow author can write a durable pause inside an ordinary
`Keiro.Workflow` do-block:

```haskell
demo :: (Workflow :> es, IOE :> es) => Eff es (Int, Int)
demo = do
  a <- step (StepName "a") (liftIO incr)   -- side effect #1
  sleepNamed (StepName "cool") 300          -- durable wait, survives a restart
  b <- step (StepName "b") (liftIO incr)   -- side effect #2
  pure (a, b)
```

and run it with `runWorkflow (WorkflowName "demo") wid demo`. On the **first** run, the
workflow executes `a`, journals it, *arms a Postgres timer* for the sleep, and **suspends**
— `runWorkflow` returns `Suspended` and the journal `wf:demo-<wid>` holds only the
`StepRecorded "a"` event. The `b` side effect has not run. The process can now crash, be
redeployed, or sit idle for the full 300 seconds: the only durable state of the pause is a
single row in the existing `keiro_timers` table, so the wait genuinely survives a restart
with **no external scheduler and no in-memory timer thread**.

When the timer becomes due, the existing timer worker (`runTimerWorker`) fires it. The fire
action we add in this plan recognises the row as a *workflow sleep* (by a discriminator in
its JSON payload), reconstructs the workflow's journal stream, and appends a
`StepRecorded "sleep:cool"` completion event to it. A later `runWorkflow` of the same
workflow id — driven in production by EP-42's resume worker, or simply re-invoked — replays:
`step "a"` short-circuits to its recorded result, `sleepNamed "cool"` sees its completion
already journaled and returns immediately, and only `step "b"` runs for real. The workflow
returns `Completed (1, 2)` and the shared side-effect counter is exactly `2` — neither `a`
nor the sleep re-ran their effects.

**What a user can do after this plan that they could not before:** insert a durable delay
into a workflow with one call, kill the process during the delay, restart, and watch the
workflow wake and continue from exactly where it paused — proven by a database-backed test
that exercises the full arm → suspend → fire → resume cycle, plus a real-time variant with a
small positive delay showing the wait actually elapses.

Term definitions used throughout (define-on-first-use, per the plan spec):

- *workflow journal* — the kiroku (PostgreSQL event-store) stream named
  `wf:<workflow-name>-<workflow-id>` that holds one `StepRecorded` event per executed or
  resolved step plus a terminal `WorkflowCompleted` event. The journal *is* the workflow's
  durable history; there is no separate history table. Owned by EP-38
  (`docs/plans/38-workflow-journal-and-named-step-replay-core.md`).
- *suspension* — a workflow pausing partway through because an awaited result is not yet
  journaled. `runWorkflow` then returns `Suspended` (a constructor of `WorkflowOutcome a`,
  owned by EP-38) instead of `Completed a`. The pause is resumed by a later `runWorkflow`
  once the awaited step's completion is journaled by some external event — here, a timer
  firing.
- *arming action* — a one-shot effectful action that registers a *wake source* for a
  suspended workflow. For sleep, arming schedules a `keiro_timers` row. EP-38's `awaitStep`
  runs the arming action exactly once on the miss path and then suspends; because a resumed
  workflow re-enters `awaitStep` and re-runs the arming action on every resume until the
  step resolves, the arming action **must be idempotent**.
- *timer worker* — the existing background loop `runTimerWorker`
  (`keiro/src/Keiro/Timer.hs`) that claims one due `keiro_timers` row at a time with
  `FOR UPDATE SKIP LOCKED`, hands it to a caller-supplied *fire action*, and marks it
  `Fired` once the fire action returns the id of the event it produced.
- *fire action* — the `TimerRow -> Eff es (Maybe EventId)` callback the timer worker invokes
  for a claimed timer. Returning `Just eid` marks the timer `Fired` and records `eid`;
  returning `Nothing` leaves it `Firing` to be retried. This plan supplies a fire action that
  knows how to wake a workflow.


## Progress


- [x] M1 (2026-06-03) — `sleepNamed`/`sleep` authoring surface added in a new
  `Keiro.Workflow.Sleep` module on top of EP-38's `awaitStep`/`currentWorkflow`/
  `freshOrdinal`; deterministic timer id (`sleepTimerId`) and sleep-payload helpers
  (`sleepTimerPayload`/`parseSleepPayload`/`sleepStepName`). Module added to
  `keiro.cabal` `exposed-modules`. `cabal build keiro` green; pure unit tests assert the
  timer id is deterministic + distinct, the payload round-trips and rejects a non-sleep
  payload, and the step name is prefixed.
- [x] M2 (2026-06-03) — `workflowSleepFireAction` (using EP-38's
  `appendJournalEntryReturningId`) and `runWorkflowTimerWorker` (the routing timer worker)
  added to `Keiro.Workflow.Sleep`. `cabal build keiro` green.
- [x] M3 (2026-06-03) — Database test: first `runWorkflow` returns `Suspended` with only
  `StepRecorded "a"` journaled and a `Scheduled` `keiro_timers` row carrying a recognised
  workflow-sleep payload; firing via `runWorkflowTimerWorker` journals
  `StepRecorded "sleep:cool"` and marks the timer `Fired`; a second `runWorkflow` returns
  `Completed (1,2)` with the counter at `2`. Test green in `cabal test keiro`.
- [x] M4 (2026-06-03) — Real-time variant with a 1s positive delay proving the wait
  actually elapses (worker with `now < fireAt` returns `Right Nothing` and the journal does
  not gain the sleep; after `threadDelay`, a worker with `now >= fireAt` fires). Cabal
  wiring done; Haddock contract recap and the `sleep`-ordinal determinism caveat are in the
  `Keiro.Workflow.Sleep` module header. Full `cabal test keiro` (105 examples, 0 failures)
  and `cabal build all` (incl. jitsurei) green.


## Surprises & Discoveries


- 2026-06-03 (implementation): **All three EP-38 contract additions this plan needed already
  shipped.** `currentWorkflow`, `freshOrdinal`, and `appendJournalEntryReturningId` are all
  exported from `Keiro.Workflow` (EP-38 folded them in during its own implementation — see the
  MasterPlan Surprises entry). So neither fallback in this plan's Decision Log / Interfaces was
  needed: `sleep` ships (not dropped), and `workflowSleepFireAction` uses the exported
  `appendJournalEntryReturningId` rather than recomputing the journal-event id. `awaitStep`'s
  recorded result is decoded at type `Value` (via a private `awaitValue = awaitStep` helper) so
  the sleep does not depend on a `FromJSON ()` instance — the `Null` result decodes identically.
- 2026-06-03 (implementation): **`.=` is ambiguous in a module importing both `aeson` and
  `Keiro.Prelude`.** `Keiro.Prelude` re-exports the full `Control.Lens` surface, which includes
  a `.=` (state-setter). Building the timer payload therefore needs the qualified `Aeson..=`
  (the same workaround `Keiro.Workflow.Types` already uses). Recorded so EP-40/EP-43 (which also
  build JSON payloads) qualify the operator from the start.
- 2026-06-03 (implementation): **`step "b"` after the sleep is itself a journaled step.** The
  M3 journal after a completed run is four events —
  `[StepRecorded "a", StepRecorded "sleep:cool", StepRecorded "b", WorkflowCompleted]`, not
  three. The first draft of the assertion omitted `b`; the durable behaviour was correct all
  along (counter `== 2`, result `(1,2)` proving only `b` re-ran). A trivial fact, but the kind
  of off-by-one a downstream test author copying this pattern should expect.


## Decision Log


- Decision: Make `sleepNamed :: (Workflow :> es) => StepName -> NominalDiffTime -> Eff es ()`
  the stable primitive and `sleep :: (Workflow :> es) => NominalDiffTime -> Eff es ()` an
  ordinal-named convenience built on it.
  Rationale: EP-38's `awaitStep` keys the journal on a `StepName`, and replay matches that
  name across runs, so a sleep's step name must be **deterministic across replays**. A
  user-supplied name (`sleepNamed`) is unconditionally stable: the same source always
  produces the same name regardless of how the surrounding code is reordered between deploys.
  An ordinal scheme ("the Nth sleep gets `sleep:N`") is convenient but its determinism is
  conditional — reordering or adding sleeps between deploys shifts the ordinals and can make a
  resumed in-flight workflow re-arm a *different* timer. We provide `sleep` for ergonomics but
  document the caveat and recommend `sleepNamed` for anything that must survive a code change
  mid-flight. See the freshOrdinal contract note below.
  Date: 2026-06-03.

- Decision: Implement the ordinal scheme for `sleep` by adding one helper to EP-38's surface,
  `freshOrdinal :: (Workflow :> es) => Text -> Eff es Int`, rather than threading a counter
  through the user's code or guessing an ordinal from journal contents.
  Rationale: An ordinal must be assigned *deterministically per run*, in source order,
  independent of which steps short-circuited. The only component that observes every
  `Workflow` operation in order on every run is EP-38's handler, which already holds the
  per-run replay state in an `IORef`. A `freshOrdinal namespace` operation that returns
  `0,1,2,…` per namespace per run (an `IORef (Map Text Int)` counter in the handler) gives
  `sleep` a stable ordinal without polluting user code. This is a **new cross-plan contract**
  added to EP-38; it is recorded in Interfaces and Dependencies and in Surprises & Discoveries
  so the MasterPlan picks it up. If EP-38 declines to add it, `sleep` ships as
  `sleep delta = sleepNamed (StepName ("sleep:" <> <hash of call-site>))` is **not** viable
  (no stable call-site hash in Haskell), so `sleep` would instead be dropped and only
  `sleepNamed` shipped — recorded here so the fallback is explicit.
  Date: 2026-06-03.

- Decision: Derive the timer id deterministically as a v5 UUID over
  `("keiro" : "workflow-sleep" : workflowName : workflowId : sleepStepName)`, mirroring
  `Keiro.ProcessManager.deterministicCommandId`.
  Rationale: EP-38's central integration contract requires the arming action to be idempotent
  because every resume re-runs it. `scheduleTimerTx` upserts on `timerId` (re-arming only
  while the row is still `Scheduled`), so a deterministic id makes every re-arm collapse to a
  no-op (or a harmless `fire_at` refresh while still scheduled) instead of inserting a second
  timer. The step name is included so two distinct sleeps in one workflow get distinct timers.
  Date: 2026-06-03.

- Decision: Route a fired timer to a workflow journal entirely through the caller-supplied
  fire action plus a JSON payload discriminator — **no `keiro_timers` schema change**.
  Rationale: `TimerRow` already carries `processManagerName`, `correlationId`, and `payload`.
  We set `processManagerName = unWorkflowName name` and `correlationId = unWorkflowId wid` so
  the fire action can reconstruct `workflowStreamName name wid`, and we put a discriminator
  `{"kind":"keiro.workflow.sleep","step":"sleep:cool"}` in `payload` so a single timer worker
  can distinguish workflow-sleep timers from ordinary process-manager timers and route each
  appropriately. The existing fire-action hook is sufficient; the MasterPlan's `keiro_timers`
  reuse integration point predicted exactly this. No migration is owned by this plan.
  Date: 2026-06-03.

- Decision: Reuse EP-38's reserved `sleepStepPrefix = "sleep:"` for the journaled sleep step
  name. A `sleepNamed (StepName "cool")` records its completion as `StepRecorded` with
  `stepName = "sleep:cool"`.
  Rationale: The MasterPlan fixes `sleep:` as the reserved prefix for sleep steps so the
  replay loop's name-lookup stays uniform; EP-38 exports the constant. `sleepNamed` prepends
  it so the user's chosen suffix becomes the durable discriminator while the prefix keeps the
  journal self-describing (an operator scanning the journal sees `sleep:` and knows it is a
  durable wait, not an ordinary step).
  Date: 2026-06-03.

- Decision: Use EP-38's exported `appendJournalEntryReturningId` in `workflowSleepFireAction`
  (the "preferred" path from Interfaces and Dependencies), not the id-recompute fallback.
  Rationale: EP-38 shipped `appendJournalEntryReturningId` (it pre-checks `stepExists` and
  returns the deterministic id, idempotently), so the fire action returns the appended
  `EventId` to `markTimerFired` without this plan duplicating EP-38's id formula. The fragile
  fallback is therefore unused.
  Date: 2026-06-03.


## Outcomes & Retrospective


Shipped in two commits on 2026-06-03:

- `feat(workflow): add durable sleep on the timer table (EP-39 M1–M2)` — the
  `Keiro.Workflow.Sleep` module and its `keiro.cabal` registration.
- `test(workflow): prove the durable-sleep arm/suspend/fire/resume cycle (EP-39 M3–M4)` — the
  `Keiro.Workflow.Sleep` describe block in `keiro/test/Main.hs`.

**What exists now that did not before.** A workflow author writes `sleepNamed (StepName "…")
delta` (or the ordinal `sleep delta`) between steps; the first run arms a deterministic
`keiro_timers` row and suspends; the durable wait is a single Postgres row, so it survives a
crash/redeploy/idle gap with no external scheduler and no in-memory timer thread; a timer
worker running `workflowSleepFireAction` (directly, or via `runWorkflowTimerWorker` alongside
process-manager timers) wakes the workflow by journaling `StepRecorded "sleep:<suffix>"`; and
a later run replays past the sleep, re-running only post-sleep side effects.

**No migration, no `keiro_timers` schema change.** Confirmed in code: routing is entirely the
caller-supplied fire action plus the `{"kind":"keiro.workflow.sleep","step":"…"}` payload
discriminator. Workflow sleeps inherit the timer subsystem's recovery surface
(`findStuckTimers`/`requeueStuckTimer`/`cancelTimer`/`deadLetterTimer`) for free.

**Surface delivered (stable for EP-44/EP-45):** `sleepNamed`, `sleep`,
`workflowSleepFireAction`, `runWorkflowTimerWorker`, `sleepTimerId`, `sleepStepName`,
`sleepTimerPayload`, `parseSleepPayload`, `workflowSleepKind` — all from `Keiro.Workflow.Sleep`.

**Green evidence.**

```text
Keiro.Workflow.Sleep
  derives a deterministic, distinct timer id [✔]
  round-trips and recognises its timer payload [✔]
  prefixes the journal step name with the reserved sleep prefix [✔]
  arms a timer and suspends, then a fired timer resumes the workflow [✔]
  respects a positive delay: not due before fire_at, fires after [✔]

105 examples, 0 failures
```

`cabal build all` (including jitsurei) is green.

**Forward note for downstream plans.** EP-44 (observability) may surface a `keiro.timer.*`
workflow-sleep dimension off the `parseSleepPayload` discriminator. EP-45 (the runbook) should
document that a sleep whose timer is never drained — or one an operator `cancelTimer`-s — stays
suspended until intervention (already noted in the module Haddock).


## Context and Orientation


The working tree is at `/Users/shinzui/Keikaku/bokuno/keiro`. The library packages are
`keiro-core` (pure contracts), `keiro` (the runtime), `keiro-migrations` (embedded SQL),
`keiro-test-support` (PostgreSQL test fixtures), and `jitsurei` (worked examples). This plan
adds code only to the `keiro` package and a test to `keiro/test/Main.hs`. **No migration and
no new table** — the whole point is to reuse the existing `keiro_timers` infrastructure.

This plan is a child of MasterPlan 5
(`docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md`) and **hard-depends
on EP-38** (`docs/plans/38-workflow-journal-and-named-step-replay-core.md`). You cannot start
until EP-38 is complete because you build directly on its surface. Read EP-38 first. The
exact EP-38 contracts this plan consumes (all exported from `Keiro.Workflow` /
`Keiro.Workflow.Types`):

- The `Workflow` effect and `runWorkflow :: (IOE :> es, Store :> es) => WorkflowName ->
  WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)`.
- `awaitStep :: (Workflow :> es, FromJSON a) => StepName -> Eff es () -> Eff es a` — the
  arm-once-then-suspend primitive. On a journal **miss** it runs its second argument (the
  arming action) exactly once and suspends the run (so `runWorkflow` returns `Suspended`); on
  a **hit** it decodes and returns the journaled result. This is the entire mechanism `sleep`
  is built on.
- `WorkflowOutcome a = Completed a | Suspended`.
- `appendJournalEntry :: (Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent
  -> Eff es ()` — appends a journal event under a deterministic id, treating kiroku's
  `DuplicateEvent` as success. The fire action uses this to record the sleep's completion.
- `WorkflowJournalEvent = StepRecorded { stepName :: Text, result :: Value, recordedAt ::
  UTCTime } | WorkflowCompleted { recordedAt :: UTCTime }`.
- `workflowStreamName :: WorkflowName -> WorkflowId -> StreamName` (returns
  `StreamName ("wf:" <> name <> "-" <> wid)`).
- `sleepStepPrefix :: Text` (the constant `"sleep:"`).
- `newtype WorkflowName = WorkflowName Text`, `newtype WorkflowId = WorkflowId Text`,
  `newtype StepName = StepName Text`, with accessors `unWorkflowName`, `unWorkflowId`,
  `unStepName` (or pattern-match the newtypes; match EP-38's exact accessor names when it
  lands — if EP-38 does not export `un*` helpers, coerce or pattern-match).

The existing timer subsystem you reuse (read these files; line numbers are guides):

- `keiro/src/Keiro/Timer/Types.hs` — `data TimerRequest = TimerRequest { timerId :: TimerId,
  processManagerName :: Text, correlationId :: Text, fireAt :: UTCTime, payload :: Value }`
  and `newtype TimerId = TimerId UUID`. A caller-chosen `timerId` makes scheduling idempotent.
- `keiro/src/Keiro/Timer/Schema.hs` — `scheduleTimerTx :: TimerRequest -> Tx.Transaction ()`
  (an upsert that **re-arms only while the row is still `Scheduled`**, via
  `ON CONFLICT (timer_id) DO UPDATE ... WHERE keiro_timers.status = 'scheduled'`); the
  `TimerRow` row type (`timerId`, `processManagerName`, `correlationId`, `fireAt`, `payload`,
  `status`, `attempts`, `firedEventId`); and `TimerStatus = Scheduled | Firing | Fired |
  Cancelled | Dead`. `claimDueTimer` atomically moves the earliest due `Scheduled` row to
  `Firing` and bumps `attempts`; `markTimerFired` records the produced `EventId`.
- `keiro/src/Keiro/Timer.hs` — `runTimerWorker :: (IOE :> es, Store :> es) => Maybe
  KeiroMetrics -> UTCTime -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)`.
  It records gauges/histograms, claims one due timer, runs the fire action, and on a
  `Just eid` result calls `markTimerFired (timer ^. #timerId) eid`. The fire action receives
  the claimed `TimerRow` and returns the `Maybe EventId` it appended. **This is the exact
  extension point** — supply a fire action that wakes a workflow.

The deterministic-id template (`keiro/src/Keiro/ProcessManager.hs`, ~lines 162–176):

```haskell
deterministicCommandId :: Text -> Text -> EventId -> Int -> EventId
deterministicCommandId managerName correlationId sourceEventId emitIndex =
  EventId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
      Text.unpack $
        Text.intercalate ":"
          [ "keiro", "process-manager", managerName, correlationId
          , UUID.toText (eventIdToUuid sourceEventId), Text.pack (show emitIndex) ]
```

We copy this shape for the deterministic **timer** id (over different name components).

The test harness (`keiro/test/Main.hs`): DB-backed describe-blocks use
`around (withFreshStore fixture)` (from `Keiro.Test.Postgres`, the suite-level
template-database fixture noted in the project memory — do not migrate per-example) and run
effects with `Store.runStoreIO storeHandle (… :: Eff es a)`. The existing timer tests at
~lines 1012–1180 are the template: they `scheduleTimerTx counterTimerRequest`, then
`runTimerWorker Nothing dueTimerTime fireAction`, and assert against `keiro_timers` and the
target stream. `dueTimerTime = UTCTime (ModifiedJulianDay 1) 0`; `counterTimerRequest` (line
~2706) shows the `TimerRequest` shape. We will mimic these.


## Plan of Work


Four milestones. Each is independently verifiable; commit after each. The work is small and
purely additive — it threads the existing timer subsystem into EP-38's suspension primitive.


### Milestone 1 — The `sleep`/`sleepNamed` authoring surface


Goal: a workflow author can call `sleepNamed`/`sleep`, and the first run arms a deterministic
timer and suspends. At the end of this milestone the authoring surface compiles and the
arming side (id derivation + payload) is unit-tested in isolation, without yet needing the
firing/worker side.

Create `keiro/src/Keiro/Workflow/Sleep.hs`. It depends on `Keiro.Workflow` (EP-38),
`Keiro.Timer`, `Keiro.Timer.Types`, `Kiroku.Store.Transaction` (`runTransaction`), and the
UUID/aeson libraries. Define:

- The discriminator constants and payload helpers:

  ```haskell
  -- The payload "kind" tag that marks a keiro_timers row as a workflow sleep,
  -- distinguishing it from an ordinary process-manager timer so a single timer
  -- worker can route each correctly.
  workflowSleepKind :: Text
  workflowSleepKind = "keiro.workflow.sleep"

  -- Build the JSON payload carried on the timer row.
  sleepTimerPayload :: Text -> Value          -- the full "sleep:<suffix>" step name
  sleepTimerPayload sleepStepName =
    object [ "kind" .= workflowSleepKind, "step" .= sleepStepName ]

  -- Recognise + extract: Just stepName for a workflow-sleep payload, Nothing otherwise.
  parseSleepPayload :: Value -> Maybe Text
  parseSleepPayload v = case v of
    Object o | KeyMap.lookup "kind" o == Just (String workflowSleepKind) ->
      case KeyMap.lookup "step" o of
        Just (String s) -> Just s
        _               -> Nothing
    _ -> Nothing
  ```

- The deterministic timer id:

  ```haskell
  -- A v5 UUID over ("keiro":"workflow-sleep":name:wid:sleepStepName). Stable across
  -- replays, so re-arming the same sleep on every resume is an idempotent upsert.
  sleepTimerId :: WorkflowName -> WorkflowId -> Text -> TimerId
  sleepTimerId name wid sleepStepName =
    TimerId $
      UUID.V5.generateNamed UUID.V5.namespaceURL $
        fmap (fromIntegral . fromEnum) $
        Text.unpack $
          Text.intercalate ":"
            [ "keiro", "workflow-sleep"
            , unWorkflowName name, unWorkflowId wid, sleepStepName ]
  ```

- The full sleep step name builder, which prepends EP-38's reserved prefix:

  ```haskell
  -- "cool" -> "sleep:cool"; the durable journal step name for this sleep.
  sleepStepName :: StepName -> Text
  sleepStepName (StepName suffix) = sleepStepPrefix <> suffix
  ```

- The stable primitive `sleepNamed`. It is `awaitStep` with an arming action that schedules a
  deterministic timer in its own transaction:

  ```haskell
  sleepNamed ::
    (Workflow :> es, Store :> es, IOE :> es) =>
    StepName -> NominalDiffTime -> Eff es ()
  sleepNamed userStep delta = do
    -- We need the workflow's name and id to build the timer; awaitStep's arming
    -- action runs inside the handler's context. EP-38's awaitStep gives us the
    -- step name; the name/id come from `currentWorkflow` (see contract note below).
    (name, wid) <- currentWorkflow
    let full = sleepStepName userStep                 -- "sleep:<suffix>"
        step' = StepName full
    awaitStep step' $ do
      now <- liftIO getCurrentTime
      let req = TimerRequest
            { timerId            = sleepTimerId name wid full
            , processManagerName = unWorkflowName name
            , correlationId      = unWorkflowId wid
            , fireAt             = addUTCTime delta now
            , payload            = sleepTimerPayload full
            }
      runTransaction (scheduleTimerTx req)
    -- awaitStep returns the journaled result (JSON null) on resume; we discard it.
  ```

  Note `awaitStep`'s result type here is `()`-shaped: the fire action records
  `result = Null`, and `Null` decodes to `()` via aeson's `FromJSON ()` only if EP-38's
  `awaitStep` is instantiated at a `()`-decodable type. To be robust we decode the recorded
  value as `aeson`'s `Value` and ignore it — call `awaitStep` at type `Value` and discard:
  `_ <- (awaitStep step' arm :: Eff es Value); pure ()`. (`Value`'s `FromJSON` is the
  identity, so any recorded `result` — `Null` included — decodes cleanly. This avoids
  coupling the sleep to a `FromJSON ()` instance.)

- The ordinal convenience `sleep`:

  ```haskell
  sleep :: (Workflow :> es, Store :> es, IOE :> es) => NominalDiffTime -> Eff es ()
  sleep delta = do
    n <- freshOrdinal "sleep"            -- EP-38 contract addition (see below)
    sleepNamed (StepName (Text.pack (show n))) delta
  ```

**EP-38 contract requirements (state clearly so EP-38 provides them):**

1. `sleepNamed` needs the current workflow's `WorkflowName`/`WorkflowId` inside the arming
   action. EP-38's handler holds these. Add `currentWorkflow :: (Workflow :> es) => Eff es
   (WorkflowName, WorkflowId)` to the `Workflow` effect (a trivial reader returning the
   handler's identity). If EP-38 instead threads name/id another way (e.g. exposing them as a
   `WorkflowContext` reader effect), adapt the two call sites above; the only requirement is
   "inside a `Workflow` computation I can obtain my own name and id."
2. `sleep` (the ordinal convenience) needs `freshOrdinal :: (Workflow :> es) => Text -> Eff es
   Int`, returning `0,1,2,…` per namespace per run, assigned in source-execution order. This
   is a **new cross-plan contract** added to EP-38 (recorded in Surprises & Discoveries and
   Interfaces). If EP-38 does not add it, ship only `sleepNamed` and drop `sleep`.

Acceptance for M1: `cabal build keiro` succeeds with `Keiro.Workflow.Sleep` added to
`exposed-modules`. A pure unit test (no DB) asserts `sleepTimerId` is deterministic
(`sleepTimerId n w s == sleepTimerId n w s` and differs for different `s`), that
`parseSleepPayload (sleepTimerPayload "sleep:cool") == Just "sleep:cool"`, that
`parseSleepPayload` returns `Nothing` for a non-sleep payload like
`object ["kind" .= ("counter-timeout" :: Text)]`, and that
`sleepStepName (StepName "cool") == "sleep:cool"`.


### Milestone 2 — The fire action and the routing timer worker


Goal: a fired workflow-sleep timer appends a `StepRecorded` completion to the right workflow
journal and returns the appended `EventId`, so `markTimerFired` records it. At the end of this
milestone the firing side compiles and composes with `runTimerWorker`.

Still in `keiro/src/Keiro/Workflow/Sleep.hs`, add:

```haskell
-- The fire action for workflow-sleep timers. For a TimerRow whose payload is a
-- workflow-sleep discriminator, reconstruct the journal stream from the row's
-- processManagerName (= workflow name) and correlationId (= workflow id), append a
-- StepRecorded { stepName = <full sleep step name from payload>, result = Null,
-- recordedAt = now } via EP-38's appendJournalEntry, and return the appended
-- EventId so the worker marks the timer Fired. Returns Nothing for a row whose
-- payload is NOT a workflow sleep (the caller should route those elsewhere).
workflowSleepFireAction ::
  (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
workflowSleepFireAction row =
  case parseSleepPayload (row ^. #payload) of
    Nothing -> pure Nothing          -- not ours; let the caller handle PM timers
    Just full -> do
      now <- liftIO getCurrentTime
      let name = WorkflowName (row ^. #processManagerName)
          wid  = WorkflowId  (row ^. #correlationId)
      eid <- appendJournalEntryReturningId name wid
               (StepRecorded { stepName = full, result = Null, recordedAt = now })
      pure (Just eid)
```

There is a wrinkle: EP-38's `appendJournalEntry` returns `()` (it hides the deterministic id
and duplicate handling). The timer worker needs the *event id* so `markTimerFired` can record
which event the firing produced. Two options:

- **Preferred:** ask EP-38 to also export `appendJournalEntryReturningId :: (Store :> es) =>
  WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es EventId` (the same code path,
  returning the deterministic id it computed and appended). This is a small, additive
  contract addition to EP-38, recorded in Interfaces and Surprises. Use it as above.
- **Fallback if EP-38 will not change:** compute the same deterministic journal-event id here
  (mirroring EP-38's id scheme exactly — a v5 UUID over
  `("keiro":"workflow":name:wid:stepName)`), call `appendJournalEntry`, and return that id.
  This duplicates EP-38's id formula, which is fragile if EP-38 changes it; prefer the export.
  Record in the Decision Log whichever was used.

Then add the routing worker that wires the fire action into `runTimerWorker`:

```haskell
-- A timer worker pass that handles BOTH workflow-sleep timers and ordinary
-- process-manager timers. For each claimed timer: if its payload is a workflow
-- sleep, wake the workflow; otherwise delegate to the supplied PM fire action.
runWorkflowTimerWorker ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->   -- fallback for non-sleep (PM) timers
  Eff es (Maybe TimerRow)
runWorkflowTimerWorker metrics now pmFire =
  runTimerWorker metrics now $ \row -> do
    mResult <- workflowSleepFireAction row
    case mResult of
      Just eid -> pure (Just eid)           -- it was a workflow sleep; handled
      Nothing  -> pmFire row                -- ordinary PM timer; delegate
```

A deployment that runs *only* workflows can pass `pmFire = \_ -> pure Nothing` (or use
`workflowSleepFireAction` directly as the `runTimerWorker` action). A deployment that mixes
process-manager timers and workflow sleeps uses `runWorkflowTimerWorker` with its existing PM
fire action as the fallback, so one timer worker drains both kinds. **No `keiro_timers` schema
change is required** (confirmed against `keiro/src/Keiro/Timer/Schema.hs`: routing is entirely
a function of the caller-supplied fire action and the JSON `payload`).

Acceptance for M2: `cabal build keiro` succeeds with the new symbols exported. (Behavioural
proof is M3 — this milestone only establishes that the firing side type-checks and composes.)


### Milestone 3 — Database proof of the arm → suspend → fire → resume cycle


Goal: the headline behaviour, proven end to end against ephemeral PostgreSQL. This milestone
adds the test that justifies the plan; it adds no production code beyond what M1/M2 shipped.

Add a `describe "Keiro.Workflow.Sleep"` block to `keiro/test/Main.hs` using
`around (withFreshStore fixture)` exactly like the existing timer tests. The test workflow:

```haskell
sleepDemo :: (Workflow :> es, Store :> es, IOE :> es) => IORef Int -> Eff es (Int, Int)
sleepDemo counter = do
  a <- step (StepName "a") (liftIO (modifyIORef' counter (+1) >> readIORef counter))
  sleepNamed (StepName "cool") 0       -- zero delta: due immediately at dueTimerTime
  b <- step (StepName "b") (liftIO (modifyIORef' counter (+1) >> readIORef counter))
  pure (a, b)
```

Test body (one `it`):

1. `counter <- newIORef 0`. Pick a `wid = WorkflowId "<uuid-text>"` and
   `name = WorkflowName "sleepdemo"`.
2. **First run suspends.** `outcome1 <- Store.runStoreIO storeHandle (runWorkflow name wid
   (sleepDemo counter))`. Assert `outcome1 == Right Suspended`. Assert `readIORef counter`
   is `1` (only `a` ran; `b` did not).
3. **Journal holds only "a".** Read `wf:sleepdemo-<wid>` via
   `Store.readStreamForward (workflowStreamName name wid) (StreamVersion 0) 100`, decode with
   `workflowJournalCodec`, and assert it is exactly `[StepRecorded {stepName = "a", ...}]`
   (one event, no `WorkflowCompleted`, no `sleep:cool`).
4. **A Scheduled timer exists.** Query `keiro_timers` for the deterministic
   `sleepTimerId name wid "sleep:cool"` and assert its `status` is `Scheduled` and its
   `payload` parses via `parseSleepPayload` to `Just "sleep:cool"`. (Reuse the test file's
   existing `timerStatusAndErrorStmt`-style helper, or add a tiny `SELECT status, payload`
   statement.)
5. **Fire the timer.** Because `delta = 0` and `fireAt = addUTCTime 0 now`, choose a `now`
   for the worker that is `>= fireAt`. The simplest is to call the worker with the *current*
   time: `now <- getCurrentTime; result <- Store.runStoreIO storeHandle (runTimerWorker
   Nothing now workflowSleepFireAction)`. Assert it returns `Right (Just timer)` with
   `timer ^. #status == Firing` (the row as claimed) and that a follow-up
   `SELECT status FROM keiro_timers WHERE timer_id = …` now reads `Fired`.
6. **Journal gains the sleep completion.** Re-read the journal; assert it is now
   `[StepRecorded "a", StepRecorded "sleep:cool"]` (two events, still no `WorkflowCompleted`).
7. **Second run completes.** `outcome2 <- Store.runStoreIO storeHandle (runWorkflow name wid
   (sleepDemo counter))`. Assert `outcome2 == Right (Completed (1, 2))`. Assert `readIORef
   counter == 2` — proving neither `a` (short-circuited by its journal hit) nor the sleep
   (resolved via its `sleep:cool` journal hit) re-ran their effects, and only `b` ran. Assert
   the journal now ends with a `WorkflowCompleted` event.

Acceptance for M3: this `it` is green in `cabal test keiro`. The assertions in steps 2, 3, 4,
6, and 7 are the observable proof of durability: the workflow paused with its wait represented
solely by a Postgres row, the timer firing woke it, and the resume short-circuited everything
that already happened.


### Milestone 4 — Real-time delay variant, cabal wiring, and docs


Goal: prove the wait *actually elapses* (a positive delay is respected, not just a zero
delta), finish packaging, and document the surface.

Add a second `it` to the same describe block: a real-time variant.

1. Build the same workflow but `sleepNamed (StepName "wait") 1` (a one-second delay), with a
   fresh `wid`.
2. First `runWorkflow` → `Suspended`, journal holds only `"a"`, a `Scheduled` timer exists
   with `fireAt ≈ now + 1s`.
3. **Not yet due:** call `runTimerWorker Nothing now0 workflowSleepFireAction` with `now0`
   captured *before* the second elapses (use the same `getCurrentTime` taken at scheduling, or
   a clock strictly before `fireAt`). Assert it returns `Right Nothing` (nothing claimable) and
   the journal still lacks `sleep:wait`. This proves the delay is enforced by `fire_at <= now`
   in the claim query, not ignored.
4. **Wait the delay, then fire:** sleep the wall clock for slightly over one second
   (`threadDelay 1_200_000`), then `now1 <- getCurrentTime` and run the worker again. Assert
   it fires (`Right (Just _)`), the journal gains `sleep:wait`, and a second `runWorkflow`
   returns `Completed`. This proves a real, elapsed durable wait — the central claim of the
   plan, demonstrated against the wall clock.

   (Keep the delay tiny — 1s — so the suite stays fast; tag the test plainly. The zero-delta
   M3 test is the deterministic workhorse; this one shows time is genuinely respected.)

Then finish packaging:

- Add `Keiro.Workflow.Sleep` to the `exposed-modules` stanza of `keiro/keiro.cabal`. Edit
  only your own line; do not reorder the list (sibling plans append to the same stanza —
  minimal diffs avoid merge churn, per the MasterPlan's module-layout integration point).
- If `Keiro` (the umbrella module `keiro/src/Keiro.hs`) re-exports the workflow surface,
  re-export `sleep`/`sleepNamed`/`runWorkflowTimerWorker`/`workflowSleepFireAction` to match
  the package convention (check whether `Keiro` re-exports `Keiro.Timer` and follow suit).
- Write a Haddock block at the top of `Keiro.Workflow.Sleep` documenting: `sleepNamed` (the
  stable primitive) vs. `sleep` (the ordinal convenience and its **determinism caveat** —
  reordering or inserting sleeps between deploys shifts ordinals and can re-arm a different
  timer for an in-flight workflow; prefer `sleepNamed` for anything that must survive a code
  change mid-flight); the payload discriminator convention
  (`{"kind":"keiro.workflow.sleep","step":"sleep:<suffix>"}`); the deterministic timer-id
  scheme; that **no `keiro_timers` schema change** is needed; and that operators must run a
  timer worker that includes `workflowSleepFireAction` (via `runWorkflowTimerWorker`, or
  directly) for sleeps to ever fire — a sleep with no worker draining its timers stays
  suspended forever.

Acceptance for M4: full `cabal test keiro` green (both sleep tests plus the existing suite);
`cabal build all` (including jitsurei) green; the Haddock contract recap and the `sleep`
caveat are present.


## Concrete Steps


Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. The repo builds with
`cabal` under a Nix-provided GHC. Build with `cabal build keiro`; test with `cabal test
keiro`.

```bash
# M1 — authoring surface
$EDITOR keiro/src/Keiro/Workflow/Sleep.hs        # sleepNamed/sleep + id/payload helpers
$EDITOR keiro/keiro.cabal                         # add Keiro.Workflow.Sleep to exposed-modules
cabal build keiro

# M2 — fire action + routing worker (same file)
$EDITOR keiro/src/Keiro/Workflow/Sleep.hs        # workflowSleepFireAction + runWorkflowTimerWorker
cabal build keiro

# M3–M4 — tests
$EDITOR keiro/test/Main.hs                         # add the "Keiro.Workflow.Sleep" describe block
cabal test keiro
cabal build all                                    # ensure jitsurei still builds
```

Expected `cabal test keiro` transcript for the new block (shape; exact wording depends on the
test framework EP-38's tests use — match it):

```text
Keiro.Workflow.Sleep
  arms a timer and suspends, then a fired timer resumes the workflow [✔]
  respects a positive delay: not due before fire_at, fires after [✔]
```

If `cabal build keiro` fails because `currentWorkflow`, `freshOrdinal`, or
`appendJournalEntryReturningId` are not yet exported by EP-38, that is the EP-38 contract gap
this plan depends on — see Interfaces and Dependencies. Coordinate the additions into EP-38
(they are small and additive) before completing this plan.


## Validation and Acceptance


This plan is accepted when `cabal test keiro` is green and the durable-sleep behaviour is
observable:

- **Suspend on first run:** a workflow with a `sleepNamed` between two steps returns
  `Suspended` on its first `runWorkflow`; the journal `wf:<name>-<id>` contains only the
  steps *before* the sleep (here just `StepRecorded "a"`), and the post-sleep side effect has
  not run (the shared counter is `1`, not `2`).
- **Durable wait is a database row:** after the first run a `keiro_timers` row exists with the
  deterministic id `sleepTimerId name wid "sleep:cool"`, `status = Scheduled`, and a payload
  that `parseSleepPayload` recognises as a workflow sleep carrying `"sleep:cool"`. This row —
  and nothing in process memory — *is* the pending wait, so it survives a restart.
- **Firing wakes the workflow:** running `runTimerWorker` (or `runWorkflowTimerWorker`) with a
  clock `>= fireAt` and `workflowSleepFireAction` appends `StepRecorded "sleep:cool"` to the
  journal and moves the timer to `Fired`.
- **Resume short-circuits:** a second `runWorkflow` of the same id returns `Completed (1, 2)`;
  the counter is `2`, proving neither the pre-sleep step nor the sleep re-ran their effects —
  only the post-sleep step ran — and the journal now ends with `WorkflowCompleted`.
- **The delay is real:** with a positive delay, a worker whose clock is before `fireAt`
  claims nothing (`Right Nothing`) and the journal does not gain the sleep completion; only
  after the wall clock passes `fireAt` does the worker fire it. This proves the wait elapses
  rather than being a no-op.

Capture the green test transcript in this section's final revision as evidence.


## Idempotence and Recovery


Re-running any milestone is safe. Source edits are idempotent; there is **no migration** so
there is nothing to apply or roll back, and no `embedDir` build gotcha to hit (this plan adds
no `.sql` file). The two idempotency-critical paths:

- **Arming is idempotent.** `sleepNamed` arms via `scheduleTimerTx` with a *deterministic*
  `timerId` (a v5 UUID over `(name, wid, sleepStepName)`). `scheduleTimerTx` upserts and
  re-arms only while the row is still `Scheduled`, so every resume that re-enters the
  not-yet-resolved sleep re-runs `arm` and collapses to the same row (a no-op, or at most a
  `fire_at` refresh while still scheduled). It cannot resurrect a `Fired` timer. This is
  exactly EP-38's "arm must be idempotent" contract.
- **Firing is idempotent.** The fire action appends the sleep completion through EP-38's
  deterministic-id journal append (`DuplicateEvent` treated as success), so a timer claimed,
  fired, then re-claimed after a worker crash (the `Firing → re-claimable` recovery path in
  `keiro/src/Keiro/Timer.hs`) re-appends the *same* journal event id and collapses to a
  no-op. At-least-once firing therefore yields exactly-once journaling.

Recovery: if a sleep timer never fires, it is a `Scheduled` (or stranded `Firing`) row in
`keiro_timers`, fully visible to the existing timer recovery tooling
(`findStuckTimers`/`requeueStuckTimer`/`cancelTimer`/`deadLetterTimer` in
`keiro/src/Keiro/Timer.hs`) — workflow sleeps inherit that operational surface for free,
which is the dividend of reusing the table. A workflow whose sleep timer is `cancelTimer`-ed
stays suspended (its `sleep:` step never resolves) until an operator intervenes; document this
in the Haddock block.


## Interfaces and Dependencies


Libraries/modules used and why: `Keiro.Workflow`/`Keiro.Workflow.Types` (EP-38 — `awaitStep`,
`runWorkflow`, `WorkflowOutcome`, `appendJournalEntry`, `StepRecorded`, `workflowStreamName`,
`sleepStepPrefix`, the `WorkflowName`/`WorkflowId`/`StepName` newtypes); `Keiro.Timer` /
`Keiro.Timer.Types` / `Keiro.Timer.Schema` (the existing `keiro_timers` subsystem —
`TimerRequest`, `scheduleTimerTx`, `runTimerWorker`, `TimerRow`, `TimerStatus`,
`markTimerFired`); `Kiroku.Store.Effect`/`Kiroku.Store.Transaction` (`Store`,
`runTransaction`); `Kiroku.Store.Types` (`EventId`); `aeson` (`Value`, `object`, `.=`, the
payload discriminator); `uuid`/`Data.UUID.V5` (the deterministic timer id);
`Data.Time`/`Data.Time.Clock` (`NominalDiffTime`, `getCurrentTime`, `addUTCTime`).

Types, signatures, and modules that must exist at the end of this plan (the surface
downstream EP-44/EP-45 consume — keep stable):

```haskell
-- Keiro.Workflow.Sleep  (NEW module this plan owns)
sleepNamed              :: (Workflow :> es, Store :> es, IOE :> es) => StepName -> NominalDiffTime -> Eff es ()
sleep                   :: (Workflow :> es, Store :> es, IOE :> es) => NominalDiffTime -> Eff es ()
workflowSleepFireAction :: (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
runWorkflowTimerWorker  :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> UTCTime
                        -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)
sleepTimerId            :: WorkflowName -> WorkflowId -> Text -> TimerId
sleepTimerPayload       :: Text -> Value
parseSleepPayload       :: Value -> Maybe Text
workflowSleepKind       :: Text   -- "keiro.workflow.sleep"
```

**NEW cross-plan contracts this plan introduces — the MasterPlan must record these and EP-38
must provide them** (all small, additive, within EP-38's existing schema version 1):

1. `currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)` — a reader on the
   `Workflow` effect returning the running workflow's own identity, so the sleep arming action
   can build a timer keyed to this workflow instance. EP-38's handler already holds this
   identity; exposing it is trivial.
2. `freshOrdinal :: (Workflow :> es) => Text -> Eff es Int` — a per-run, per-namespace
   monotone counter (`0,1,2,…`) assigned in source-execution order, so the `sleep` convenience
   can derive a deterministic ordinal step name without threading state through user code. If
   EP-38 declines this, only `sleepNamed` ships (the `sleep` convenience is dropped).
3. `appendJournalEntryReturningId :: (Store :> es) => WorkflowName -> WorkflowId ->
   WorkflowJournalEvent -> Eff es EventId` — the same append `appendJournalEntry` performs but
   returning the deterministic `EventId` it computed, so the timer fire action can return that
   id to `markTimerFired`. If EP-38 declines this, the fire action recomputes the id with
   EP-38's exact formula and `appendJournalEntry` is used (recorded in the Decision Log).

The **payload discriminator convention** `{"kind":"keiro.workflow.sleep","step":"sleep:<suffix>"}`
is also a cross-plan convention the MasterPlan should note: it is how a single timer worker
distinguishes workflow-sleep timers from process-manager timers, and EP-44 (observability) may
want to surface a `keiro.timer.*` workflow-sleep dimension off it.

This plan owns **no** migration and makes **no** `keiro_timers` schema change (confirmed
against `keiro/src/Keiro/Timer/Schema.hs`): routing is entirely a function of the
caller-supplied fire action and the JSON `payload`.

Every commit while implementing this plan must carry all three git trailers:

```text
MasterPlan: docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md
ExecPlan: docs/plans/39-durable-sleep-on-the-timer-table.md
Intention: intention_01kt6y4cb6eqz9mq48kf2xw8n1
```
