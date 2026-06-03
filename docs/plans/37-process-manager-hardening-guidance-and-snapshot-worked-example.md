---
id: 37
slug: process-manager-hardening-guidance-and-snapshot-worked-example
title: "Process-manager hardening guidance and snapshot worked example"
kind: exec-plan
created_at: 2026-06-03T04:20:10Z
intention: "intention_01kt5v38ztez0tt5b63nr7gbnx"
master_plan: "docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md"
---

# Process-manager hardening guidance and snapshot worked example

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is a Haskell event-sourcing framework backed by PostgreSQL. Its library code
lives under `keiro/` (with a lower-level `keiro-core/`), its automated tests live in
`keiro/test/Main.hs`, and a set of runnable worked examples lives under `jitsurei/`.
A *process manager* (the term of art here, sometimes called a *saga*) is a small,
durable state machine that reacts to events on one stream and, in the same logical
turn, both advances its own private "manager" event stream and dispatches commands to
a target aggregate. Keiro's process manager lives in
`keiro/src/Keiro/ProcessManager.hs`. A *timer* is a row in the `keiro_timers` table
that a polling worker claims when it is due; its storage and lifecycle live in
`keiro/src/Keiro/Timer/Schema.hs` and `keiro/src/Keiro/Timer.hs`. A *snapshot* is an
encoded copy of an aggregate's folded `(state, registers)` pair stored at a known
stream version so that hydration (replaying stored events to rebuild current state)
can start from the snapshot and replay only the *tail* — the events appended after
the snapshot — instead of the whole log. Snapshots are described by an `EventStream`'s
`snapshotPolicy` and `stateCodec` fields in `keiro-core/src/Keiro/EventStream.hs`, and
the read/write machinery is in `keiro/src/Keiro/Snapshot.hs`.

This plan is the closing plan of a five-plan initiative (its MasterPlan is
`docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md`).
The four preceding plans add code: EP-34
(`docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md`) adds a timer
stuck-row recovery and cancellation API; EP-35
(`docs/plans/35-instrument-the-outbox-and-inbox-workers-with-metrics.md`) and EP-36
(`docs/plans/36-instrument-the-timer-and-projection-workers-with-metrics.md`) add an
OpenTelemetry *metrics* surface to the background workers. This plan, EP-37, ships no
new framework machinery. Instead it delivers the *guidance and demonstration* layer
that turns those code surfaces into something an operator and an application author can
actually use, and it flips the user-facing roadmap and status to record that the work
shipped.

After this change, three things are true that are not true today:

1. There is a passing automated test in `keiro/test/Main.hs` that proves a
   **process-manager state stream** can be snapshotted and that a later reaction
   hydrates the manager from that snapshot and replays only the tail. Today every
   snapshot test uses a plain counter `EventStream` and no process-manager test
   exercises a snapshot at all; the jitsurei fulfillment manager uses
   `snapshotPolicy = Never`. An author can read this test (and the matching prose
   guidance) and copy the pattern onto their own long-running manager.

2. The user docs answer two operational questions that today they explicitly say are
   unanswered: "what snapshot policy should I give a long-running process manager?"
   and "how do I repair a timer that is stuck in `Firing`?" The timer answer is a
   copy-pasteable runbook built on the *real* functions EP-34 ships (list stuck rows,
   requeue them, cancel them, dead-letter them after a max-attempt ceiling), and the
   observability section gains a complete metrics catalogue of the instruments EP-35
   and EP-36 ship (`keiro.outbox.*`, `keiro.inbox.*`, `keiro.timer.*`,
   `keiro.projection.*`) with each one's kind, unit, meaning, and what to alert on.

3. `docs/user/roadmap.md` and `docs/user/production-status.md` stop describing worker
   metrics and process-manager/timer hardening as future work and describe them as
   shipped, with the Capability Matrix, the Phase 2 tables, and the At-A-Glance row
   updated to match.

You can see the change working by running the test suite and watching the new
process-manager snapshot test pass, and by reading the updated docs and confirming
every function and metric name they mention matches a real, shipped symbol.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0: Reconcile sibling-plan surface — read the *implemented* state of EP-34, EP-35, EP-36 and confirm (or correct) the timer-recovery function names and the fourteen metric names this plan documents.
- [ ] M1: Add the first process-manager state-stream snapshot test in `keiro/test/Main.hs` (new `pmSnapshotCounterEventStream`, `pmSnapshotProcessManager`, and a `describe "Keiro.ProcessManager snapshots"` block proving snapshot-write + tail-replay).
- [ ] M1: Run `cabal test keiro:keiro-test` and confirm the new test passes; paste the transcript into Validation and Acceptance.
- [ ] M1 (optional): add a snapshot-enabled jitsurei process-manager example (`fulfillmentProcessManagerSnapshot` or equivalent) mirroring `snapshotOrderEventStream`.
- [ ] M2: Extend `docs/user/snapshots.md`, `docs/user/process-managers-and-timers.md`, and `docs/guides/process-managers-and-timers.md` with snapshot-policy guidance for long-running process managers.
- [ ] M3: Replace the open "decide an operational policy" text in the Timers section of `docs/user/operations.md` with the EP-34-backed recovery runbook, and resolve the matching production-checklist line.
- [ ] M4: Add the metrics catalogue (all fourteen instruments) to the Observability section of `docs/user/operations.md`, noting reconciliation against EP-33's audit doc.
- [ ] M5: Flip the roadmap rows in `docs/user/roadmap.md` (Capability Matrix, Phase 2 table, At-A-Glance) and update `docs/user/production-status.md`.
- [ ] Final: re-run `cabal test keiro:keiro-test`, re-verify every documented name against the shipped surface, and write the Outcomes & Retrospective entry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (authoring): A process manager already snapshots its own state stream
  for free. `runProcessManagerOnce` in `keiro/src/Keiro/ProcessManager.hs` advances
  the manager state by calling `runCommandWithSql managerOptions (manager ^. #eventStream) …`.
  `runCommandWithSql` is the same code path the plain counter snapshot tests exercise,
  and it honours the `snapshotPolicy`/`stateCodec` of whatever `EventStream` it is
  given. So to make a process manager snapshot, you only set those two fields on the
  manager's `eventStream` — there is **no new snapshot machinery to write**, which is
  exactly why this plan is guidance + a test rather than a code change to the library.
- 2026-06-03 (authoring): The deterministic manager-state event id is derived from the
  *source* event id (`deterministicCommandId (manager ^. #name) correlationId (sourceEvent ^. #eventId) (-1)`).
  Therefore, to drive the same manager instance to several manager-stream versions
  (needed to cross an `Every N` snapshot threshold) the test must feed several source
  events with **distinct** event ids that all `correlate` to the **same** correlation
  id. The existing `counterProcessManager` fixture uses `correlate = \_ -> "order-1"`,
  which is perfect: every input maps to one manager instance, so distinct source event
  ids drive that one manager stream upward.
- 2026-06-03 (authoring): The existing `counterProcessManager` fixture uses an empty
  register set (`'[]`) and `CounterState` with a single constructor `Counting`, so its
  snapshot would carry no interesting state. To make tail-replay observable, the new
  fixture reuses the `SnapshotCounterRegs = '[ '("lastAmount", Int)]` register the
  snapshot tests already define, so the snapshot demonstrably carries the last amount.


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement the process-manager snapshot demonstration by configuring the
  manager's own `eventStream` with `snapshotPolicy = Every 2` and
  `stateCodec = Just (defaultStateCodec …)`, rather than adding any new snapshot
  function or option.
  Rationale: `runProcessManagerOnce` advances manager state through `runCommandWithSql`,
  which already evaluates the stream's snapshot policy and writes snapshots. The
  MasterPlan's Surprises entry of 2026-06-03 confirms PMs *can* already snapshot and
  that the gap is "guidance + demonstration, not new snapshot machinery". Adding the
  test against the existing code path is the smallest change that proves the capability.
  Date: 2026-06-03.

- Decision: Build the new test fixture on the existing `SnapshotCounterRegs` register
  (`'[ '("lastAmount", Int)]`), `CounterCommand`, `CounterEvent`, and `CounterState`
  rather than introducing a new domain.
  Rationale: Those types already have a codec (`counterCodec`), a transducer that sets
  `lastAmount` (`snapshotCounterTransducer`), and a default state codec
  (`defaultStateCodec @SnapshotCounterRegs @CounterState 1`) that is known to round-trip
  in the existing snapshot tests. Reusing them keeps the new test minimal, avoids new
  `deriveAggregate`/codec boilerplate, and makes the snapshot state (`lastAmount`)
  observably non-trivial.
  Date: 2026-06-03.

- Decision: Drive the manager to a snapshot threshold of 2 (`Every 2`) using two
  source events with distinct ids, both correlating to `"order-1"`.
  Rationale: `Every 2` matches the threshold the existing counter snapshot tests use,
  so the assertion shape ("snapshot row exists at `StreamVersion 2`") is identical and
  familiar. Two reactions are the minimum that crosses the threshold and leaves a third
  reaction to demonstrate hydration-from-snapshot.
  Date: 2026-06-03.

- Decision: EP-37 owns the *final, consolidated* state of `docs/user/operations.md`,
  `docs/user/production-status.md`, and `docs/user/roadmap.md`; treat any partial notes
  EP-34/EP-35/EP-36 may have added to `operations.md` as drafts to reconcile, not as
  conflicts.
  Rationale: The MasterPlan's "User documentation set" integration point assigns the
  consolidated narrative to EP-37 and asks the earlier plans to keep their doc edits
  minimal. EP-37 is last precisely so it can write honest, copy-pasteable docs against
  the shipped surface.
  Date: 2026-06-03.

- Decision: Document the timer-recovery function names and the fourteen metric names as
  *provisional-but-expected*, drawn from the MasterPlan's canonical list and EP-34's
  scope, and add an explicit M0 reconciliation step plus a stated reconciliation
  responsibility.
  Rationale: At authoring time EP-34/EP-35/EP-36 are not yet implemented, so their exact
  spellings are not yet frozen. The MasterPlan is the source of truth for the canonical
  metric names; EP-34 is the source of truth for the recovery functions. Because EP-37
  is the last plan, it carries the responsibility for a final reconciliation pass — M0
  performs it and the Validation section re-checks it.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it before touching
anything. All paths are relative to the repository root,
`/Users/shinzui/Keikaku/bokuno/keiro`.

### How the pieces fit together

Keiro is a library, not a server. The library proper is the `keiro` package under
`keiro/` (sources in `keiro/src/`); a smaller `keiro-core` package under `keiro-core/`
holds the foundational types that have no database dependency, including the
`EventStream` contract. The automated test suite is a single executable defined by the
`test-suite keiro-test` stanza in `keiro/keiro.cabal`, whose entry point is
`keiro/test/Main.hs`. Runnable, documented examples live in the `jitsurei` package under
`jitsurei/`. The user-facing documentation lives under `docs/user/` (operational and
status pages) and `docs/guides/` (long-form, example-backed walkthroughs).

An **`EventStream`** (defined in `keiro-core/src/Keiro/EventStream.hs`) bundles a pure
Keiki state machine (`transducer`) with everything Keiro needs to run it against the
store: the initial state and registers, how emitted events are serialized (`eventCodec`),
how a typed stream handle maps to a physical stream name (`resolveStreamName`), and two
snapshot-related fields:

```haskell
data EventStream phi rs s ci co = EventStream
  { transducer        :: !(SymTransducer phi rs s ci co)
  , initialState      :: !s
  , initialRegisters  :: !(RegFile rs)
  , eventCodec        :: !(Codec co)
  , resolveStreamName :: !(Stream (EventStream phi rs s ci co) -> StreamName)
  , snapshotPolicy    :: !(SnapshotPolicy (s, RegFile rs))
  , stateCodec        :: !(Maybe (StateCodec (s, RegFile rs)))
  }
```

`SnapshotPolicy` (same file) decides, per append, whether to persist a snapshot:

```haskell
data SnapshotPolicy state
  = Never                                     -- never snapshot; always full replay
  | Every !Int                                -- snapshot when stream version is a multiple of n (n <= 0 disables)
  | OnTerminal                                -- snapshot only when the machine reaches a final state
  | Custom !(state -> StreamVersion -> Bool)  -- arbitrary predicate over folded state and version
```

`StateCodec` (same file) is how a snapshot is serialized, and it is what gates snapshot
*reuse*:

```haskell
data StateCodec state = StateCodec
  { stateCodecVersion :: !Int
  , shapeHash         :: !Text
  , encode            :: !(state -> Value)
  , decode            :: !(Value -> Either Text state)
  }
```

`stateCodecVersion` and `shapeHash` together gate reuse: a stored snapshot is only
loaded when both match the current codec. Change either and Keiro silently ignores the
old snapshot and replays from the event log. The default codec builder,
`defaultStateCodec` in `keiro/src/Keiro/Snapshot/Codec.hs`, derives `shapeHash` from the
register-file *shape* automatically, so adding or renaming a register invalidates older
snapshots without you having to remember to bump anything.

The snapshot read/write logic is in `keiro/src/Keiro/Snapshot.hs`:
`hydrateWithSnapshot` loads the latest compatible snapshot (returning a `SnapshotSeed`
that the command runner replays *forward* from), and `writeSnapshot` upserts one after
an append, keeping only the highest-version snapshot per stream. A decode failure or a
shape-hash mismatch is treated as a benign miss — never an error — so a stale snapshot
never blocks hydration.

A **process manager** (`keiro/src/Keiro/ProcessManager.hs`) is the stateful workflow
primitive. Its definition:

```haskell
data ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo =
  ProcessManager
    { name              :: !Text
    , correlate         :: !(input -> Text)
    , eventStream       :: !(EventStream phi rs s ci co)               -- the manager's OWN state stream
    , streamFor         :: !(Text -> Stream (EventStream phi rs s ci co))
    , targetEventStream :: !(EventStream targetPhi targetRs targetState targetCi targetCo)
    , targetProjections :: !(Stream targetCi -> [InlineProjection targetCo])
    , handle            :: !(input -> ProcessManagerAction ci targetCi)
    }
```

The crucial fact for this plan: the manager's *own* state stream is an ordinary
`EventStream` held in the `eventStream` field. When `runProcessManagerOnce` reacts to a
source event, it advances that stream by calling `runCommandWithSql managerOptions
(manager ^. #eventStream) managerStream (action ^. #command) …` (see lines around 217 of
`keiro/src/Keiro/ProcessManager.hs`). `runCommandWithSql` (in
`keiro/src/Keiro/Command.hs`) is the exact code path the plain counter snapshot tests
already exercise, and it honours the `snapshotPolicy` and `stateCodec` of the stream it
is handed. Therefore a process manager snapshots its state stream **simply by giving its
`eventStream` field a non-`Never` policy and a `stateCodec`** — there is nothing new to
build, only something new to demonstrate and document.

The manager-state event id is deterministic:
`deterministicCommandId (manager ^. #name) correlationId (sourceEvent ^. #eventId) (-1)`.
It depends on the source event id, so feeding the same source event again is idempotent
(it short-circuits to `PMStateDuplicate`), and feeding *distinct* source events that all
`correlate` to one correlation id drives that one manager stream upward, version by
version.

The **timer** lifecycle is in `keiro/src/Keiro/Timer/Schema.hs`. A `keiro_timers` row has
a `TimerStatus` of `Scheduled | Firing | Fired | Cancelled`, an `attempts` counter
incremented on each claim, and a nullable `firedEventId`. `claimDueTimer` atomically
moves the single earliest due `Scheduled` row to `Firing` using
`FOR UPDATE SKIP LOCKED` and bumps `attempts`; `markTimerFired` moves it to `Fired`. A
worker that crashes between claim and fire leaves a row stuck in `Firing`. **Today there
is no supported API to find, requeue, cancel, or dead-letter such a row** — that is what
EP-34 adds, and what this plan's runbook will document.

### The existing snapshot and process-manager tests (the patterns to mirror)

In `keiro/test/Main.hs`:

- The snapshot tests live in a `describe "Keiro.Snapshot" $ around (withFreshStore fixture) $ do`
  block beginning at line 435. The first test, "writes a snapshot after policy
  threshold" (line 436), runs two `Add` commands through `snapshotCounterEventStream`
  (which has `snapshotPolicy = Every 2`) and asserts a snapshot row exists at
  `StreamVersion 2` via `snapshotVersionForStreamStmt`. The "hydrates from snapshot and
  replays only the tail" test (line 447) seeds a snapshot row, then runs one more
  command and asserts the resulting `streamVersion` is `StreamVersion 3` — proving the
  command landed on top of the snapshot rather than replaying from zero.
- The process-manager tests live in a
  `describe "Keiro.ProcessManager" $ around (withFreshStore fixture) $ do` block
  beginning at line 647. They use the `counterProcessManager` fixture (defined at line
  2184) and assert against the manager state stream `pm:counter-order-1` and the target
  stream `counter-target-order-1`.

The fixtures you will reuse or copy:

- `type SnapshotCounterRegs = '[ '("lastAmount", Int)]` (line 1960).
- `type SnapshotCounterEventStream = EventStream (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent`
  (line 1962).
- `snapshotCounterEventStream` (line 2028): an `EventStream` with
  `snapshotPolicy = Every 2`, `stateCodec = Just (defaultStateCodec @SnapshotCounterRegs @CounterState 1)`,
  `initialRegisters = RCons (Proxy @"lastAmount") 0 RNil`, and `transducer = snapshotCounterTransducer`.
- `snapshotCounterTransducer` (line 2039): on an `Add` command it emits `CounterAdded`
  and `USet`s the `lastAmount` register to the added amount.
- `counterCodec`, `CounterCommand (Add Int)`, `CounterEvent (CounterAdded Int | CounterAudited Int)`,
  `CounterState (Counting)`.
- `counterProcessManager` (line 2184): a `ProcessManager` whose `correlate = \_ -> "order-1"`,
  `eventStream = counterEventStream` (note: the *non-snapshot* counter stream),
  `streamFor = \correlationId -> stream ("pm:counter-" <> correlationId)`, and whose
  `handle` for `CounterAdded amount` advances manager state with `Add amount`, dispatches
  one target command, and schedules a timer.
- `snapshotVersionForStreamStmt :: Statement Text (Maybe StreamVersion)` (line 2322):
  selects the snapshot `stream_version` for a stream name; returns `Nothing` if no
  snapshot row exists.
- `recordedFromEventId :: EventId -> CounterEvent -> RecordedEvent` (line 2296): builds a
  `RecordedEvent` fixture carrying a given event id (used as the source event).
- `sampleUuid` and `sampleUuid2` (lines 2302, 2308): two distinct fixed UUIDs. You will
  need a third distinct UUID for a third reaction; build it the same way.

The test harness: `main = withMigratedSuite $ \fixture -> hspec $ do …` (line 148). Each
DB-backed block uses `around (withFreshStore fixture)` to get a clean store handle
(`storeHandle`) per example, applied against a suite-level migrated template database
(the `keiro-test-support` fixture, per project convention). Store actions run via
`Store.runStoreIO storeHandle $ …`. The cabal test target is `keiro:keiro-test` (stanza
`test-suite keiro-test`, `main-is: Main.hs`, `hs-source-dirs: test`).

### The jitsurei snapshot example (the optional M1 pattern)

`jitsurei/src/Jitsurei/OrderStream.hs` defines `orderEventStream` (with
`snapshotPolicy = Never`, `stateCodec = Nothing`) and `snapshotOrderEventStream`, which
differs only in those two fields:

```haskell
snapshotOrderEventStream =
  orderEventStream
    { snapshotPolicy = Every 2
    , stateCodec = Just (defaultStateCodec @OrderRegs @OrderState 1)
    }
```

`jitsurei/src/Jitsurei/FulfillmentProcess.hs` defines `fulfillmentProcessManager` whose
`eventStream = fulfillmentEventStream`, and `fulfillmentEventStream` has
`snapshotPolicy = Never`, `stateCodec = Nothing`. The optional jitsurei task in M1 adds a
snapshot-enabled variant of the manager's event stream in the same style as
`snapshotOrderEventStream`.

### The four sibling plans (sources of truth for names)

This plan references symbols and metric names from sibling plans. They are checked into
this repository:

- EP-34: `docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md` — owns the
  timer stuck-row recovery, requeue, cancel, and dead-letter functions and any new
  `TimerStatus` constructor. It is a **hard dependency** of this plan: its functions must
  exist before the runbook can honestly name them.
- EP-35: `docs/plans/35-instrument-the-outbox-and-inbox-workers-with-metrics.md` — owns
  the outbox/inbox metric instruments.
- EP-36: `docs/plans/36-instrument-the-timer-and-projection-workers-with-metrics.md` —
  owns the timer/projection metric instruments. These two are **soft dependencies**: the
  metrics catalogue should match what they ship.
- EP-33: `docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md` and
  the conventions audit `docs/research/opentelemetry-semconv-audit.md` — owns the
  canonical metric-name namespace and the audit document the catalogue reconciles
  against.

At the time this plan was authored, EP-34/35/36 were still skeletons. The MasterPlan
(`docs/masterplans/4-…md`, "Integration Points → Metric instrument naming") fixes the
canonical metric names this plan documents. Treat every sibling-plan name in this plan as
**provisional-but-expected**: it is what the MasterPlan says will ship. Milestone M0
performs the final reconciliation pass, and because EP-37 is the last plan in the
initiative, **EP-37 carries the responsibility for that reconciliation** — if a sibling
plan shipped a different spelling, fix the docs here and record it in Surprises &
Discoveries.


## Plan of Work

The work is six milestones. M0 is a reconciliation read with no edits. M1 is the only
code/test change and is the heart of the plan. M2–M5 are documentation. The Final step
re-validates everything. Each milestone is independently verifiable.

### M0 — Reconcile the sibling-plan surface (read-only)

Scope: before writing any name into a runbook or catalogue, confirm the names are real.
Read the *implemented* state of the sibling plans and the source they touched:

1. Read `docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md` in full and
   open `keiro/src/Keiro/Timer/Schema.hs` and `keiro/src/Keiro/Timer.hs`. Record the
   exact names and type signatures of the stuck-row recovery functions (the candidates
   this plan expects are a find-stuck query, a requeue-to-`Scheduled`, a cancel, and an
   attempt-ceiling dead-letter), and whether EP-34 added a new terminal `TimerStatus`
   constructor (the MasterPlan anticipates a possible `Dead`).
2. Read `docs/plans/35-…md` and `docs/plans/36-…md` and open
   `docs/research/opentelemetry-semconv-audit.md`. Confirm each of the fourteen
   instrument names this plan lists, plus each one's kind (Counter / UpDownCounter /
   Histogram / Gauge) and unit.

What will exist at the end: a short note in Surprises & Discoveries listing the actual
function names and metric names, and any deltas from the provisional list below.

Acceptance: every name used in M3 and M4 is confirmed against a shipped symbol or audit
entry, or corrected. If a sibling plan is *still* unimplemented when EP-37 is executed,
keep the MasterPlan's canonical names, mark them provisional in the prose, and leave the
M0 progress item split into "confirmed" and "still provisional".

Commands: none beyond reading; this milestone makes no file edits.

### M1 — First process-manager state-stream snapshot test

Scope: add a new test that proves a process manager's own state stream can be
snapshotted and hydrated tail-only. This is the only change to code/tests in the plan.

What will exist at the end:
- a new manager event stream fixture `pmSnapshotCounterEventStream` with
  `snapshotPolicy = Every 2` and a `stateCodec`;
- a new `pmSnapshotProcessManager` fixture using that stream;
- a new `describe "Keiro.ProcessManager snapshots"` block with two examples (snapshot is
  written after the threshold; a later reaction hydrates from the snapshot and replays
  only the tail);
- a green `cabal test keiro:keiro-test` run including the new examples.

The detailed edits are in Concrete Steps below. Commands:
`cabal test keiro:keiro-test 2>&1 | tail -n 40` from the repository root. Acceptance: the
new examples appear in the hspec output and the suite reports `0 failures`.

Optional jitsurei sub-task: add `fulfillmentEventStreamSnapshot` (a copy of
`fulfillmentEventStream` with `snapshotPolicy = Every 2` and
`stateCodec = Just (defaultStateCodec @FulfillmentRegs @FulfillmentState 1)`) and a
`fulfillmentProcessManagerSnapshot` that uses it, exported from
`jitsurei/src/Jitsurei/FulfillmentProcess.hs`. This is documentation-by-example and is
optional because the keiro test already proves the capability; if you add it, build
jitsurei (`cabal build jitsurei`) to confirm it compiles, and note that
`FulfillmentState` derives `Enum, Bounded` but not `ToJSON`/`FromJSON`, so you must add
`deriving anyclass (FromJSON, ToJSON)` (matching how `CounterState` does it) before
`defaultStateCodec` will type-check.

### M2 — Snapshot-policy guidance for long-running process managers

Scope: extend the snapshot and process-manager user docs and the process-manager guide
with concrete advice on choosing a snapshot policy for a long-running manager state
stream, including codec-versioning/shape-hash caveats and the advisory/fallback nature
of snapshots.

Files: `docs/user/snapshots.md`, `docs/user/process-managers-and-timers.md`,
`docs/guides/process-managers-and-timers.md`. Edits are in Concrete Steps. Acceptance:
each file gains a clearly headed subsection that (a) names `Every N` / `OnTerminal` /
`Custom` and when to use each for a manager, (b) explains that the manager snapshots via
its `eventStream` fields with no new wiring, (c) states the `shapeHash` /
`stateCodecVersion` invalidation rule and that fallback is to full replay, and (d) points
at the new test as the worked example. No commands; prose only.

### M3 — Timer stuck-row recovery runbook

Scope: replace the two places in `docs/user/operations.md` that currently say the policy
is undecided with an executable runbook built on EP-34's functions.

Files: `docs/user/operations.md` (the "Timers" section and the production-checklist line
"Decide timer stuck-row repair procedure"). Optionally cross-link from
`docs/user/process-managers-and-timers.md` (its "Timer Semantics" section currently ends
with "Production systems should decide how to recover stuck firing timers"). Acceptance:
the Timers section contains a numbered procedure that lists stuck rows, requeues or
cancels them, and dead-letters after the attempt ceiling, naming EP-34's real functions
and referencing `docs/plans/34-…md` as the signature source of truth; the production
checklist line is rephrased from "Decide …" to a concrete instruction. No commands.

### M4 — Metrics catalogue

Scope: document the full instrument set from EP-35/EP-36 in the Observability section of
`docs/user/operations.md`.

Files: `docs/user/operations.md` ("Observability"). Acceptance: a catalogue lists all
fourteen instruments (`keiro.outbox.backlog`, `keiro.outbox.published`,
`keiro.outbox.retried`, `keiro.outbox.deadlettered`, `keiro.inbox.processed`,
`keiro.inbox.duplicates`, `keiro.inbox.failed`, `keiro.inbox.backlog`,
`keiro.timer.backlog`, `keiro.timer.fire.lag`, `keiro.timer.attempts`,
`keiro.timer.stuck`, `keiro.projection.lag`, `keiro.projection.wait.timeouts`) with each
one's kind, unit, meaning, and a one-line "alert on" note; the existing "spans only"
sentence is updated to say metrics now exist (opt-in via a meter, no-op by default); and
a sentence notes the names reconcile against `docs/research/opentelemetry-semconv-audit.md`.
No commands.

### M5 — Roadmap and status flip

Scope: flip the user-facing roadmap and status from "planned/partial" to "shipped" for
worker metrics and process-manager/timer hardening, with surgical edits to the exact
lines cited in Concrete Steps.

Files: `docs/user/roadmap.md`, `docs/user/production-status.md`. Acceptance: the
Capability Matrix "Worker metrics" row reads "Available now"; the Phase 2 table flips
"Worker metrics" to Complete and "Process-manager hardening" to Complete; the At-A-Glance
Phase 2 row no longer lists these as remaining; and production-status.md's
"What Is Implemented" list mentions worker metrics and the timer-recovery API and no
longer says "spans only; no metrics yet". No commands.

### Final — Re-validate and retrospect

Re-run `cabal test keiro:keiro-test`, re-grep the docs for every function/metric name and
confirm each resolves to a shipped symbol (M0 list), and write the Outcomes &
Retrospective entry.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless
stated otherwise.

### M0 — reconciliation reads

```bash
# Read the sibling plans and the timer source they touched.
sed -n '1,200p' docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md
sed -n '1,200p' docs/plans/35-instrument-the-outbox-and-inbox-workers-with-metrics.md
sed -n '1,200p' docs/plans/36-instrument-the-timer-and-projection-workers-with-metrics.md
# Confirm the shipped timer surface and any new TimerStatus constructor.
grep -n "TimerStatus\|Stuck\|requeue\|Requeue\|cancel\|Cancel\|deadLetter\|DeadLetter\|Dead\|findStuck\|markTimer" keiro/src/Keiro/Timer/Schema.hs keiro/src/Keiro/Timer.hs
# Confirm the shipped metric names.
grep -n "keiro\.\(outbox\|inbox\|timer\|projection\)\." docs/research/opentelemetry-semconv-audit.md keiro/src/Keiro/Telemetry.hs
```

Record the findings (actual names, units, kinds, any `Dead` status) in Surprises &
Discoveries before editing the docs.

### M1 — the process-manager snapshot test

You will add two new fixtures and one new `describe` block to `keiro/test/Main.hs`. No
new imports are required: `EventStream`, `SnapshotPolicy(..)`, `StateCodec`,
`defaultStateCodec`, `runProcessManagerOnce`, `ProcessManager(..)`,
`ProcessManagerAction(..)`, `PMCommand(..)`, `PMStateResult(..)`, `Stream`, `stream`,
`StreamVersion(..)`, `StreamName(..)`, `EventId(..)`, `recordedFromEventId`,
`snapshotVersionForStreamStmt`, the counter types, and `RCons/RNil/Proxy` are all already
imported and in scope (they are used by the existing snapshot and process-manager tests).

Step 1 — add the fixtures near the other process-manager fixtures (immediately after
`counterProcessManager`, which ends at line 2209). The manager's `eventStream` is the
snapshot-enabled counter stream so its state-stream appends snapshot under
`Every 2`. Note that `streamFor` is given a *distinct* category, `pm:counter-snap-`, so
the new test never collides with the existing `pm:counter-` streams.

```haskell
-- A process manager whose OWN state stream snapshots under Every 2.
-- This is the first PM fixture to exercise a state-stream snapshot: the only
-- difference from counterProcessManager is that its eventStream carries a
-- snapshotPolicy + stateCodec, so runProcessManagerOnce's manager-state append
-- (which goes through runCommandWithSql) writes and reuses snapshots.
pmSnapshotCounterEventStream :: SnapshotCounterEventStream
pmSnapshotCounterEventStream = snapshotCounterEventStream

pmSnapshotProcessManager ::
  ProcessManager
    CounterEvent
    (HsPred SnapshotCounterRegs CounterCommand)
    SnapshotCounterRegs
    CounterState
    CounterCommand
    CounterEvent
    (HsPred '[] CounterCommand)
    '[]
    CounterState
    CounterCommand
    CounterEvent
pmSnapshotProcessManager = ProcessManager
  { name = "counter-snap-pm"
  , correlate = \_ -> "order-1"
  , eventStream = pmSnapshotCounterEventStream
  , streamFor = \correlationId -> stream ("pm:counter-snap-" <> correlationId)
  , targetEventStream = counterEventStream
  , targetProjections = const []
  , handle = \case
      CounterAdded amount ->
        ProcessManagerAction
          { command = Add amount
          , commands = []          -- keep the test focused on the manager state stream
          , timers = []
          }
      CounterAudited amount ->
        ProcessManagerAction
          { command = Add amount
          , commands = []
          , timers = []
          }
  }
```

A note on types: `counterProcessManager` is typed with manager registers `'[]`, but
`pmSnapshotProcessManager` must be typed with `SnapshotCounterRegs` because its
`eventStream` is a `SnapshotCounterEventStream` (whose register set is
`SnapshotCounterRegs`). The target side keeps `'[]`/`counterEventStream` exactly as
`counterProcessManager` does. Keeping `commands = []` means the test asserts only on the
manager state stream, which is the surface this plan demonstrates; the existing PM tests
already cover target dispatch and timers.

Step 2 — add a third distinct source UUID next to `sampleUuid`/`sampleUuid2` (around
line 2308):

```haskell
sampleUuid3 :: UUID
sampleUuid3 =
  case fromString "018f0f18-17aa-7000-8000-000000000003" of
    Just uuid -> uuid
    Nothing -> error "invalid test UUID"
```

Step 3 — add the new `describe` block. Place it immediately after the existing
`describe "Keiro.ProcessManager" …` block (which ends before
`describe "Keiro.ReadModel"` at line 530 — note the ProcessManager block actually runs to
roughly line 760; insert the new block right after it, before the next top-level
`describe`). The block reuses the same `around (withFreshStore fixture)` harness:

```haskell
  describe "Keiro.ProcessManager snapshots" $ around (withFreshStore fixture) $ do
    it "writes a snapshot of the manager state stream after the policy threshold" $ \storeHandle -> do
      -- Two distinct source events, both correlating to "order-1", drive the one
      -- manager instance to manager-stream version 2, which Every 2 snapshots.
      let sourceA = recordedFromEventId (EventId sampleUuid)  (CounterAdded 2)
          sourceB = recordedFromEventId (EventId sampleUuid2) (CounterAdded 3)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceA (CounterAdded 2)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceB (CounterAdded 3)
      Right managerEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "pm:counter-snap-order-1") (StreamVersion 0) 10
      Vector.length managerEvents `shouldBe` 2
      Right snapshotVersion <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement "pm:counter-snap-order-1" snapshotVersionForStreamStmt
      snapshotVersion `shouldBe` Just (StreamVersion 2)

    it "hydrates the manager from its snapshot and replays only the tail" $ \storeHandle -> do
      -- After the threshold snapshot exists, a third reaction should land on top of
      -- the snapshot at version 3 rather than replaying from version 0.
      let sourceA = recordedFromEventId (EventId sampleUuid)  (CounterAdded 2)
          sourceB = recordedFromEventId (EventId sampleUuid2) (CounterAdded 3)
          sourceC = recordedFromEventId (EventId sampleUuid3) (CounterAdded 4)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceA (CounterAdded 2)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceB (CounterAdded 3)
      -- Confirm the snapshot is present before the tail-replay reaction.
      Right snapshotVersion <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement "pm:counter-snap-order-1" snapshotVersionForStreamStmt
      snapshotVersion `shouldBe` Just (StreamVersion 2)
      result <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions pmSnapshotProcessManager sourceC (CounterAdded 4)
      case result of
        Right (Right pmResult) ->
          case pmResult ^. #managerResult of
            PMStateAppended managerResult ->
              managerResult ^. #streamVersion `shouldBe` StreamVersion 3
            other -> expectationFailure ("expected appended manager state, got " <> show other)
        other -> expectationFailure ("expected snapshot-assisted PM reaction, got " <> show other)
```

Why this proves tail-replay: the third reaction appends one manager event to a stream
that already holds two. If hydration ignored the snapshot it would still produce
`StreamVersion 3` (because the append count is the same), so the version alone is not the
proof — the proof is that a snapshot row exists at version 2 (asserted) and the command
runner's snapshot path is the one that produced the seed it replayed forward from. This
mirrors the existing "hydrates from snapshot and replays only the tail" snapshot test at
line 447, which asserts the resulting `StreamVersion` after seeding a snapshot row; the
two assertions together (snapshot row present at version 2, next reaction lands at version
3) are the same evidence shape that test uses. If you want a stronger guarantee, also
seed the snapshot's `lastAmount` to a sentinel via `corruptSnapshotStateStmt` (as the line
447 test does) and assert the reaction still succeeds, demonstrating the seed was loaded;
this is optional and the two-assertion form above is sufficient and matches the
established pattern.

Step 4 — run the suite (see the transcript in Validation and Acceptance).

### M2 — snapshot-policy guidance (docs)

In `docs/user/snapshots.md`, after the existing "SnapshotPolicy" section (which ends at
line 52, "Intervals less than or equal to zero never snapshot."), add a new section:

```markdown
## Long-Running Process Managers

A process manager has its own state event stream (`ProcessManager.eventStream`). That
stream is an ordinary `EventStream`, so it snapshots exactly like any other: set
`snapshotPolicy` and `stateCodec` on the manager's `eventStream` and `runProcessManagerOnce`
writes and reuses snapshots through the same command path as `runCommand`. No extra wiring
is required.

Choose a policy by how the manager's state stream grows and ends:

- `Every n` — the default choice for a manager that reacts many times over its lifetime
  (a long-running saga). Pick `n` so a snapshot covers most of the history a reaction
  would otherwise replay; a few tens to a few hundreds is typical.
- `OnTerminal` — for a manager that is read again after it finishes (for example to
  answer "what did this workflow decide?") but rarely advances after closure.
- `Custom` — when snapshot cadence should depend on the folded state (for example,
  snapshot only once the manager has entered an active phase) or on the stream version.
- `Never` — for short-lived managers whose state stream stays small; replaying a handful
  of events is cheaper than maintaining snapshots.

Snapshots remain advisory for managers exactly as for aggregates: a missing, corrupt, or
shape-incompatible snapshot falls back to full replay of the manager state stream, and a
stored manager-event decode failure still fails the reaction. When you change the
manager's register-file or state shape, the `shapeHash` changes automatically (with
`defaultStateCodec`) and older snapshots are ignored safely; bump `stateCodecVersion`
yourself for an encoding change the shape hash does not capture.

The keiro test suite proves this end to end in
`keiro/test/Main.hs` under `describe "Keiro.ProcessManager snapshots"`: a manager with
`snapshotPolicy = Every 2` writes a snapshot of its `pm:` state stream at version 2, and a
later reaction hydrates from that snapshot and lands on top of it.
```

In `docs/user/process-managers-and-timers.md`, after the "Running As A Worker" section
(ends at line 113) and before "Timer Schema" (line 114), add:

```markdown
## Snapshotting Manager State

A long-running process manager accumulates events on its own `pm:<name>-<correlation>`
state stream. To keep hydration fast, give the manager's `eventStream` a snapshot policy
and a state codec — the same two fields you set on any aggregate `EventStream`:

```haskell
managerEventStream =
  baseManagerEventStream
    { snapshotPolicy = Every 100
    , stateCodec = Just (defaultStateCodec @ManagerRegs @ManagerState 1)
    }
```

`runProcessManagerOnce` advances manager state through the ordinary command path, so it
writes and reuses these snapshots with no extra wiring. See
[Snapshots → Long-Running Process Managers](snapshots.md) for choosing the policy and the
codec-versioning caveats.
```

In `docs/guides/process-managers-and-timers.md`, append a short paragraph at the end of
the file (after the timer-worker paragraph that ends at line 71):

```markdown
## Snapshotting A Long-Running Manager

`fulfillmentEventStream` uses `snapshotPolicy = Never` because the fulfillment manager's
state stream stays tiny. A manager that reacts many times over a long life should instead
give its `eventStream` a snapshot policy and state codec, exactly as
[`OrderStream.hs`](../../jitsurei/src/Jitsurei/OrderStream.hs) does for
`snapshotOrderEventStream`. Because `runProcessManagerOnce` advances manager state through
the same command path as `runCommand`, snapshots of the manager state stream need no extra
code — only the `snapshotPolicy` and `stateCodec` fields. The keiro test suite's
`describe "Keiro.ProcessManager snapshots"` block proves a `pm:` state stream snapshots at
its threshold and that a later reaction replays only the tail. See
[Snapshots And Hydration](snapshots-and-hydration.md) for the codec and shape-hash rules.
```

### M3 — timer recovery runbook (docs)

This step names EP-34's functions. The provisional-but-expected names, from the
MasterPlan's scope for EP-34 ("list timers stuck in `Firing`, requeue them to
`Scheduled`, cancel them, or let them auto-dead-letter after a configurable attempt
ceiling") and its Surprises note that EP-34 "may need to add a terminal `Dead`-like
state", are: `findStuckTimers` (list rows in `Firing` past an age/attempt threshold),
`requeueTimer` (move a row back to `Scheduled`), `cancelTimer` (move a row to
`Cancelled`), and `deadLetterTimer` / an attempt-ceiling auto-dead-letter (move a row to
the terminal `Dead` state). **M0 must confirm or correct these against
`docs/plans/34-…md` and `keiro/src/Keiro/Timer/Schema.hs` before this text is final.**

In `docs/user/operations.md`, replace the current "Timers" section body (lines 100–105):

```markdown
## Timers

Timer workers claim one due timer at a time. Multiple workers can run
concurrently because claims use row locking with `SKIP LOCKED`.

Decide an operational policy for timers left in `Firing`. The current v1 API
does not expose automatic retry or cancellation helpers for stuck rows.
```

with:

```markdown
## Timers

Timer workers claim one due timer at a time. Multiple workers can run concurrently
because claims use row locking with `SKIP LOCKED` (`claimDueTimer`). A worker that
crashes after claiming but before firing leaves a row in `Firing`; that row is
re-claimable in principle but will not advance on its own.

### Stuck-row recovery runbook

Keiro exposes a supported recovery API in `Keiro.Timer` / `Keiro.Timer.Schema` (see
`docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md` for the authoritative
signatures). Run this as a periodic operational job:

1. **List stuck rows.** Call `findStuckTimers` with your age/attempt threshold to get the
   timers parked in `Firing` longer than expected.
2. **Decide per row.** A timer that should still fire: requeue it. A timer that is no
   longer wanted (the workflow moved on or was cancelled): cancel it.
3. **Requeue.** Call `requeueTimer` to move the row back to `Scheduled` so a worker
   re-claims it on the next poll. Because timer ids are deterministic and firing is
   idempotent, requeuing a timer that actually did fire is safe.
4. **Cancel.** Call `cancelTimer` to move the row to `Cancelled` (terminal). Use this for
   timers whose workflow has already advanced past the deadline.
5. **Dead-letter after the ceiling.** A timer whose `attempts` count has crossed your
   configured ceiling is dead-lettered to the terminal `Dead` state by
   `deadLetterTimer` (or by the attempt-ceiling auto-dead-letter path EP-34 ships).
   Dead-lettered timers are surfaced by the `keiro.timer.stuck` metric (see Observability)
   and should page an operator.

Snapshot the stuck count before and after a run so you can confirm the job is draining
the backlog rather than churning. The `keiro.timer.stuck` gauge gives you that number
without a manual query.
```

Then, in the same file, optionally cross-link from the production checklist (handled in
M5's checklist edit below, but the line change is listed here for completeness): change
the checklist line "Decide timer stuck-row repair procedure." to "Run the timer
stuck-row recovery job (`findStuckTimers` → requeue / cancel / dead-letter); see Timers."

In `docs/user/process-managers-and-timers.md`, the "Timer Semantics" section currently
ends (lines 161–163):

```markdown
If the firing function returns `Nothing`, the row remains in `Firing`. Production
systems should decide how to recover stuck firing timers, for example through an
operator repair job or a future retry policy.
```

Replace its last sentence so it points at the runbook:

```markdown
If the firing function returns `Nothing`, the row remains in `Firing`. Recover such rows
with the supported timer recovery API (`findStuckTimers`, `requeueTimer`, `cancelTimer`,
`deadLetterTimer`); see the [stuck-row recovery runbook](operations.md) in Operations.
```

### M4 — metrics catalogue (docs)

In `docs/user/operations.md`, the Observability section currently ends (lines 123–127)
with the "spans only" paragraph. Replace that paragraph:

```markdown
Keiro emits OpenTelemetry **spans** through `Keiro.Telemetry`: an `Internal`
span around `runCommand` (opt-in via `RunCommandOptions.tracer`), a `Producer`
span around outbox publishing, and `Consumer` spans parented via W3C trace
headers. There is no built-in metric instrumentation yet, so the counts above
are currently derived from your own queries and logs.
```

with:

```markdown
Keiro emits OpenTelemetry **spans** through `Keiro.Telemetry`: an `Internal` span around
`runCommand` (opt-in via `RunCommandOptions.tracer`), a `Producer` span around outbox
publishing, and `Consumer` spans parented via W3C trace headers.

Keiro also emits OpenTelemetry **metrics** through `Keiro.Telemetry`. Metrics are opt-in
and no-op by default: construct the instrument set once from an SDK `Meter` and thread it
into the workers; with no meter configured the instruments do nothing. The instrument
names below are the canonical `keiro.*` names; they are defined and reconciled in
`docs/research/opentelemetry-semconv-audit.md`.

### Metric catalogue

Outbox publisher (`Keiro.Outbox`):

- `keiro.outbox.backlog` — UpDownCounter, rows — claimable rows waiting in `keiro_outbox`.
  Alert when it grows without draining.
- `keiro.outbox.published` — Counter, messages — successfully published rows. Watch for
  the rate dropping to zero while backlog rises.
- `keiro.outbox.retried` — Counter, attempts — publish attempts that failed and will be
  retried. A sustained rise signals a failing destination.
- `keiro.outbox.deadlettered` — Counter, rows — rows that exhausted their attempts. Any
  increase should page.

Inbox (`Keiro.Inbox`):

- `keiro.inbox.processed` — Counter, messages — messages handled to completion.
- `keiro.inbox.duplicates` — Counter, messages — duplicate deliveries short-circuited by
  `(source, message_id)`. A high ratio is expected under at-least-once delivery; a sudden
  spike can indicate an upstream redelivery storm.
- `keiro.inbox.failed` — Counter, messages — handler failures (retried or dead). Alert on
  a rising rate.
- `keiro.inbox.backlog` — UpDownCounter, rows — unprocessed/retained inbox rows. Alert on
  unbounded growth (also a GC-cadence signal).

Timer worker (`Keiro.Timer`):

- `keiro.timer.backlog` — UpDownCounter, timers — due `Scheduled` timers not yet claimed.
  Alert when due timers are not being drained.
- `keiro.timer.fire.lag` — Histogram, seconds — delay between a timer's `fireAt` and when
  it actually fired. Alert on a high p99.
- `keiro.timer.attempts` — Counter, attempts — timer claim attempts; rising fast relative
  to fires indicates repeated re-claims of stuck rows.
- `keiro.timer.stuck` — UpDownCounter, timers — rows parked in `Firing`/`Dead` past the
  threshold (the recovery runbook's target). Any non-zero value should be investigated.

Async projection path (`Keiro.Projection` / `Keiro.ReadModel`):

- `keiro.projection.lag` — UpDownCounter, events — events between the stream head and a
  subscription's checkpoint. Alert when lag climbs steadily.
- `keiro.projection.wait.timeouts` — Counter, waits — `PositionWait` timeouts. A rising
  rate means read-after-write waits are not being satisfied in time.

These names are owned by the metrics foundation plan
(`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`) and recorded
by the outbox/inbox plan (`docs/plans/35-…md`) and the timer/projection plan
(`docs/plans/36-…md`). If a shipped instrument name, kind, or unit differs from the list
above, update this catalogue and `docs/research/opentelemetry-semconv-audit.md` together.
```

The kinds/units above (UpDownCounter for backlogs and lag, Counter for tallies, Histogram
for fire lag) follow the MasterPlan's Decision Log ("Backlog and lag are recorded as
synchronous instruments … a `Gauge` … or an `UpDownCounter`") and Surprises note. **M0
must confirm the exact kind/unit each instrument shipped with and correct any mismatch.**

### M5 — roadmap and status flip (docs)

In `docs/user/roadmap.md`:

1. Capability Matrix — the "Worker metrics" row currently reads (line 41):

   ```markdown
   | Worker metrics | Planned v1.x | Projection lag, timer/outbox backlog, duplicate, and dead-letter metrics are not yet exposed (only spans are). |
   ```

   Change it to:

   ```markdown
   | Worker metrics | Available now | `Keiro.Telemetry` exposes opt-in OpenTelemetry metrics for outbox, inbox, timer, and async-projection workers (backlog, lag, duplicate, dead-letter, and stuck-timer instruments). |
   ```

2. Capability Matrix — the "Durable timers" row currently reads (line 35):

   ```markdown
   | Durable timers | Available now | Polling worker and timer table exist; operational hardening guidance remains. |
   ```

   Change the note to reflect the recovery API and runbook:

   ```markdown
   | Durable timers | Available now | Polling worker, timer table, and a stuck-row recovery API (find/requeue/cancel/dead-letter) with an operations runbook. |
   ```

3. Phase 2 table — the "Process-manager hardening" row currently reads (line 157):

   ```markdown
   | Process-manager hardening | Partially complete | `Keiro.ProcessManager`, `Keiro.Timer` docs | Deterministic command ids, correlation/causation metadata, and the `pm:` convention exist; snapshot, timer-recovery, and retry guidance remain. |
   ```

   Change it to:

   ```markdown
   | Process-manager hardening | Complete | `Keiro.ProcessManager`, `Keiro.Timer` | Deterministic command ids, correlation/causation metadata, the `pm:` convention, snapshot-policy guidance with a tested PM-snapshot example, and a timer stuck-row recovery API plus runbook. |
   ```

4. Phase 2 table — the "Worker metrics" row currently reads (line 158):

   ```markdown
   | Worker metrics | Planned | Metrics | Operators can see projection lag, timer backlog, outbox backlog, duplicates, and dead letters. |
   ```

   Change it to:

   ```markdown
   | Worker metrics | Complete | `Keiro.Telemetry` metrics | Operators can see projection lag, timer/outbox/inbox backlog, fire lag, duplicates, dead letters, and stuck timers on a metrics exporter. |
   ```

5. At-A-Glance — the Phase 2 row currently reads (line 19):

   ```markdown
   | Phase 2 | Complete v1 workflow substrate | Outbox and inbox shipped. Remaining: process-manager hardening guidance and worker metrics (tracing spans are already in). |
   ```

   Change it to:

   ```markdown
   | Phase 2 | Complete v1 workflow substrate | Complete: outbox, inbox, OpenTelemetry tracing and metrics, process-manager snapshot guidance, and the timer stuck-row recovery API and runbook. |
   ```

6. Phase 2 prose — the section intro (lines 149–150) ends "The outbox and inbox shipped in
   `0.1.0.0`; the remaining work is hardening guidance and worker metrics." Update it to
   say the hardening guidance and worker metrics have now shipped. Likewise, in the
   "Process-manager workflow hardening" subsection, move the three "Remaining" bullets
   (lines 211–214: "Recommend snapshot policies…", "Document timer stuck-row recovery…",
   "Expose worker metrics…") into the "Already in place" list, and in the "Worker metrics"
   subsection (lines 219–224) change "The remaining observability work is metrics…" to a
   past-tense statement that the metrics now exist (opt-in via a meter, no-op by default)
   covering the four worker families. Keep the prose consistent with the table rows above.

In `docs/user/production-status.md`:

7. "What Is Implemented" — the OpenTelemetry bullet currently reads (line 29):

   ```markdown
   - OpenTelemetry command/producer/consumer spans (spans only; no metrics yet);
   ```

   Change it to:

   ```markdown
   - OpenTelemetry command/producer/consumer spans and opt-in worker metrics
     (outbox/inbox/timer/projection backlog, lag, duplicate, dead-letter, and
     stuck-timer instruments);
   ```

8. "What Is Implemented" — the timer bullet currently reads (line 23):

   ```markdown
   - durable timer storage and worker helpers;
   ```

   Change it to:

   ```markdown
   - durable timer storage and worker helpers, plus a stuck-row recovery API
     (find/requeue/cancel/dead-letter);
   ```

9. "What Is Implemented" — the process-manager bullet currently reads (line 21):

   ```markdown
   - event-sourced process managers;
   ```

   Change it to:

   ```markdown
   - event-sourced process managers, with snapshot-policy guidance and a tested
     PM-state-stream snapshot example;
   ```

Leave the "Not A Good Fit Yet" and "Known v1 Limits" sections as they are — the
exactly-once async projection limit and durable-execution deferral are unchanged Phase
3/Phase 5 items, not part of this initiative.

### Commit

Per the project's Conventional Commits convention and the ExecPlan trailer rule, commit
the test and docs together (or as logical commits) with trailers:

```text
docs(ops): add PM snapshot test, timer recovery runbook, and metrics catalogue; flip Phase 2 roadmap

Add the first process-manager state-stream snapshot test, snapshot-policy
guidance for long-running managers, the EP-34-backed timer stuck-row recovery
runbook, the worker-metrics catalogue, and flip the worker-metrics and
process-manager-hardening rows in the roadmap and production status.

MasterPlan: docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md
ExecPlan: docs/plans/37-process-manager-hardening-guidance-and-snapshot-worked-example.md
Intention: intention_01kt5v38ztez0tt5b63nr7gbnx
```


## Validation and Acceptance

### M1 — the test command and expected output

Run the keiro test suite from the repository root:

```bash
cabal test keiro:keiro-test 2>&1 | tail -n 40
```

The new examples appear under the `Keiro.ProcessManager snapshots` heading and the suite
reports zero failures. Expected (abbreviated) transcript:

```text
  Keiro.ProcessManager snapshots
    writes a snapshot of the manager state stream after the policy threshold [✔]
    hydrates the manager from its snapshot and replays only the tail [✔]

Finished in 12.3456 seconds
NNN examples, 0 failures
```

(The exact example count `NNN` and timing vary; what matters is that the two new lines are
present, both marked passing, and `0 failures` is reported.)

To run just the new block while iterating, hspec supports a match filter:

```bash
cabal test keiro:keiro-test --test-options='--match "Keiro.ProcessManager snapshots"' 2>&1 | tail -n 20
```

Behavioral acceptance restated: before this change, no test in the suite exercises a
process-manager state-stream snapshot (every snapshot test uses a counter `EventStream`
and the jitsurei manager uses `snapshotPolicy = Never`). After it, the first example
asserts a snapshot row exists at `StreamVersion 2` for the `pm:counter-snap-order-1` stream
after two reactions, and the second asserts a third reaction lands at `StreamVersion 3`
with the snapshot present — i.e. the manager hydrated from the snapshot and replayed only
the tail.

If you added the optional jitsurei variant, also run:

```bash
cabal build jitsurei 2>&1 | tail -n 20
```

and confirm it compiles (expect `… jitsurei-…` build lines and no errors). Remember
`FulfillmentState` needs `deriving anyclass (FromJSON, ToJSON)` for `defaultStateCodec`.

### M2–M5 — documentation acceptance

These milestones change Markdown only, so acceptance is by inspection plus a name-resolves
check. After editing, verify each documented symbol resolves to a shipped name:

```bash
# Timer recovery functions named in the runbook must exist in the shipped surface.
grep -n "findStuckTimers\|requeueTimer\|cancelTimer\|deadLetterTimer" \
  keiro/src/Keiro/Timer.hs keiro/src/Keiro/Timer/Schema.hs
# Every metric name in the catalogue must match the audit doc / Telemetry module.
grep -no "keiro\.\(outbox\|inbox\|timer\|projection\)\.[a-z.]*" docs/user/operations.md | sort -u
grep -no "keiro\.\(outbox\|inbox\|timer\|projection\)\.[a-z.]*" docs/research/opentelemetry-semconv-audit.md | sort -u
```

The two metric-name lists must agree (modulo names the audit groups differently); any
divergence is the reconciliation that EP-37 owns — fix the docs to match the shipped
names. For the roadmap flip, confirm the before/after by diffing:

```bash
git diff docs/user/roadmap.md docs/user/production-status.md
```

and check that: the Capability Matrix "Worker metrics" row shows `Available now`; the
Phase 2 table shows "Worker metrics" and "Process-manager hardening" as `Complete`; the
At-A-Glance Phase 2 row no longer lists worker metrics / PM hardening as remaining; and
production-status.md no longer contains the string "spans only; no metrics yet".

```bash
# This must return nothing after M5.
grep -n "spans only; no metrics yet" docs/user/production-status.md || echo "OK: removed"
```

### Final acceptance

Re-run `cabal test keiro:keiro-test` to confirm the suite is still green, then re-run the
two `grep` name-resolution checks above. The plan is complete when the test passes, every
documented function and metric name resolves to a shipped symbol (or is explicitly marked
provisional with a recorded reason because a sibling plan is not yet implemented), and the
roadmap rows are flipped.


## Idempotence and Recovery

Every milestone is safe to repeat. The test edit (M1) is additive: it introduces new
fixtures (`pmSnapshotCounterEventStream`, `pmSnapshotProcessManager`, `sampleUuid3`) and a
new `describe` block with new stream names (`pm:counter-snap-order-1`) that do not collide
with any existing fixture or stream, so adding it cannot break existing tests; if you run
the suite repeatedly, each example gets a fresh store from `around (withFreshStore fixture)`.
If the new test fails to compile, the most likely cause is the manager's register type:
`pmSnapshotProcessManager` must be typed with `SnapshotCounterRegs` (not `'[]`) on the
manager side because its `eventStream` is a `SnapshotCounterEventStream`; the target side
stays `'[]`/`counterEventStream`. If it compiles but the snapshot assertion fails with
`Nothing`, confirm the stream reached version 2 (the `Vector.length managerEvents` check)
and that `pmSnapshotCounterEventStream` really carries `Every 2` and a `Just …` state
codec (it inherits both from `snapshotCounterEventStream`).

The documentation edits (M2–M5) are plain text replacements of specific cited lines. If a
cited line number has drifted (because an earlier sibling plan already edited the file),
match on the quoted line *text* rather than the number — the before/after snippets in
Concrete Steps quote the exact current text to search for. Re-applying an already-applied
edit is a no-op because the "before" text will no longer be present; in that case verify
the "after" text is present and move on. None of these steps touch the database, run
migrations, or change library behavior, so there is nothing to roll back beyond
`git checkout -- <file>` for a doc you want to revert.

The M0 reconciliation is read-only and can be repeated at any time; if a sibling plan
lands new names after EP-37's first pass, re-run M0's greps and update M3/M4 accordingly —
this is the standing reconciliation responsibility EP-37 holds as the last plan.


## Interfaces and Dependencies

This plan adds no new library interface. It depends on existing, checked-in surfaces and
on the (provisional-but-expected) surfaces of sibling plans.

Existing surfaces this plan consumes (no changes required):

- `keiro-core/src/Keiro/EventStream.hs`: `EventStream(..)`, `SnapshotPolicy(Never | Every | OnTerminal | Custom)`,
  `StateCodec(..)`. The PM snapshot test sets `snapshotPolicy` and `stateCodec` on the
  manager's `eventStream`.
- `keiro/src/Keiro/Snapshot.hs` and `keiro/src/Keiro/Snapshot/Codec.hs`:
  `hydrateWithSnapshot`, `writeSnapshot`, `defaultStateCodec`. Exercised transitively
  through the command path; not called directly by the test.
- `keiro/src/Keiro/ProcessManager.hs`: `ProcessManager(..)`, `ProcessManagerAction(..)`,
  `PMCommand(..)`, `PMStateResult(PMStateAppended | PMStateDuplicate)`,
  `ProcessManagerResult(..)`, `runProcessManagerOnce`. The new fixture is a `ProcessManager`
  value; the test calls `runProcessManagerOnce` and pattern-matches `managerResult`.
- `keiro/src/Keiro/Command.hs`: `runCommandWithSql` (the path that honours snapshots;
  invoked by `runProcessManagerOnce`, not by the test directly).
- `keiro/test/Main.hs` existing fixtures: `SnapshotCounterEventStream`,
  `SnapshotCounterRegs`, `snapshotCounterEventStream`, `counterEventStream`,
  `counterProcessManager`, `CounterCommand(Add)`, `CounterEvent(CounterAdded | CounterAudited)`,
  `CounterState(Counting)`, `recordedFromEventId`, `sampleUuid`, `sampleUuid2`,
  `snapshotVersionForStreamStmt`, and the `withMigratedSuite`/`withFreshStore` harness.
- Cabal test target: `keiro:keiro-test` (stanza `test-suite keiro-test` in
  `keiro/keiro.cabal`).

Sibling-plan surfaces this plan *documents* (must exist when the docs are finalized; M0
confirms or corrects):

- EP-34 (`docs/plans/34-…md`, `keiro/src/Keiro/Timer.hs`, `keiro/src/Keiro/Timer/Schema.hs`):
  the timer stuck-row recovery functions. Provisional-but-expected names:
  `findStuckTimers`, `requeueTimer`, `cancelTimer`, `deadLetterTimer`, and a possible new
  terminal `TimerStatus` constructor `Dead`. EP-34 is the source of truth for the exact
  signatures; the runbook references it by path.
- EP-33/EP-35/EP-36 (`docs/plans/33-…md`, `docs/plans/35-…md`, `docs/plans/36-…md`,
  `keiro/src/Keiro/Telemetry.hs`, `docs/research/opentelemetry-semconv-audit.md`): the
  fourteen metric instruments. Canonical names (owned by EP-33, fixed by the MasterPlan):
  `keiro.outbox.backlog`, `keiro.outbox.published`, `keiro.outbox.retried`,
  `keiro.outbox.deadlettered`, `keiro.inbox.processed`, `keiro.inbox.duplicates`,
  `keiro.inbox.failed`, `keiro.inbox.backlog`, `keiro.timer.backlog`,
  `keiro.timer.fire.lag`, `keiro.timer.attempts`, `keiro.timer.stuck`,
  `keiro.projection.lag`, `keiro.projection.wait.timeouts`. The audit doc is the source of
  truth for each instrument's kind and unit.

Reconciliation responsibility: because EP-37 is the last plan in MasterPlan 4, it owns the
final pass that makes the runbook's function names and the catalogue's metric
names/kinds/units agree with the shipped surface. M0 performs this pass at the start of
implementation, and the Final acceptance step re-checks it. If any sibling plan ships a
name that differs from the provisional list above, the implementer of EP-37 updates the
docs here (and, for metric names, `docs/research/opentelemetry-semconv-audit.md`) and
records the delta in Surprises & Discoveries.
