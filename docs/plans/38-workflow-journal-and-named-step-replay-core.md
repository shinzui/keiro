---
id: 38
slug: workflow-journal-and-named-step-replay-core
title: "Workflow journal and named-step replay core"
kind: exec-plan
created_at: 2026-06-03T14:39:45Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
master_plan: "docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md"
---

# Workflow journal and named-step replay core

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan creates the foundation of Keiro's v2 *durable execution* runtime. "Durable
execution" means a user can write a long-running function as an ordinary Haskell
do-block and have its side effects *journaled* (recorded) at named checkpoints, so the
function can be paused and resumed across process crashes, redeployments, and idle gaps
without re-running side effects that already happened. The marquee user-visible behavior
this plan delivers is the **named-step journal and its replay**: a user writes

```haskell
demo :: (Workflow :> es, IOE :> es) => Eff es (Int, Int)
demo = do
  a <- step (StepName "first")  (liftIO incrementAndRead)   -- side effect #1
  b <- step (StepName "second") (liftIO incrementAndRead)   -- side effect #2
  pure (a, b)
```

and runs it with `runWorkflow (WorkflowName "demo") wfId demo`. The **first** run
executes both `incrementAndRead` side effects and appends two `StepRecorded` events to a
kiroku stream named `wf:demo-<wfId>`. A **second** run of the *same* `runWorkflow` call
with the *same* `wfId` (which is exactly what a crash-and-restart looks like) replays:
each `step` whose name is already in the journal returns the recorded result **without
running the side effect again**. After this plan, a novice can prove durability in a
test: a shared `IORef` counter increments exactly twice across two `runWorkflow`
invocations, and the two runs return identical results.

This plan does *not* ship any *wake source* — `sleep`, `awakeable`, and child workflows
are sibling plans under the same MasterPlan
(`docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md`). It *does*,
however, own the **suspension primitive** all three of them build on: a workflow can
pause partway through (waiting on a future timer fire, an external signal, or a child's
completion) and be resumed later. Because a paused workflow has no result yet,
`runWorkflow` returns a `WorkflowOutcome a` (`Completed a` or `Suspended`), and the core
exposes `awaitStep` — "look up this step's recorded result; if it is not journaled yet,
run an *arming* action once and suspend this run." The wake-source plans supply only the
arming action (schedule a timer, register an awakeable, spawn a child); the suspend/resume
machinery lives here so EP-39, EP-40, and EP-43 stay independent of one another.

What this plan fixes — the contracts every sibling plan builds on: the `Keiro.Workflow`
effect, the `step`/`awaitStep`/`runWorkflow` surface, the `WorkflowOutcome` type, the
`StepRecorded`/`WorkflowCompleted` journal events and their codec, the `wf:<name>-<id>`
stream naming, the in-memory journal pre-load and short-circuit replay, the suspension
mechanism, the `keiro_workflow_steps` index table, and the deterministic journal-event id
that makes a double-append collapse to one row. EP-38 itself ships no wake source, so a
workflow that uses only `step` always runs straight through to `Completed`.

Term definitions used throughout (define-on-first-use, per the plan spec):

- *kiroku* — the PostgreSQL event store Keiro is built on. An *append* writes events to a
  named *stream*; a *read* returns the stream's events in order. Accessed through the
  `Store` effect (an `effectful` effect), re-exported by Keiro.
- *effectful* — the algebraic-effects library this codebase uses. An *effect* is a type
  like `Store` or (new here) `Workflow`; `(Store :> es)` is a constraint meaning "the
  effect row `es` provides `Store`"; `Eff es a` is a computation in that row. A *dynamic*
  effect is interpreted at runtime by a handler (`interpret`).
- *journal* — the kiroku stream `wf:<workflow-name>-<workflow-id>` holding one
  `StepRecorded` event per executed step plus a terminal `WorkflowCompleted` event. The
  journal *is* the workflow's durable history; there is no separate history table.
- *named step* — a fragment of the workflow identified by a string label (`StepName`),
  not by its position in the source. Replay matches on the label, so reordering code
  between deploys does not corrupt an in-flight workflow.


## Progress

- [x] M1 (2026-06-03) — `Keiro.Workflow.Types`: `WorkflowName`, `WorkflowId`, `StepName`,
  `WorkflowOutcome`, the `WorkflowJournalEvent` sum type, the `WorkflowState` alias, the
  `workflowStreamName` helper, and the `workflowJournalCodec`. Compiles; the codec
  round-trips both events via the workflow tests (decode of read-back journal events).
- [x] M2 (2026-06-03) — `keiro_workflow_steps` table: migration SQL, `Keiro.Workflow.Schema`
  with the hasql statements and the `recordStepTx` / `loadStepIndex` / `stepExists` /
  `findUnfinishedWorkflowIds` helpers. Migration applies under the suite fixture
  (`Applying 2026-06-03-00-00-00-keiro-workflow-steps.sql`).
- [x] M3 (2026-06-03) — `Keiro.Workflow`: the `Workflow` effect, `step`, `awaitStep`,
  `currentWorkflow`, `freshOrdinal`, `runWorkflow` and `runWorkflowWith` (returning
  `WorkflowOutcome a`), `appendJournalEntry`/`appendJournalEntryReturningId`, the
  suspension mechanism, and the journal/replay handler. A two-step workflow journals each
  step once and returns `Completed`; an unresolved `awaitStep` yields `Suspended`; an
  external completion lets the next run finish.
- [x] M4 (2026-06-03) — Replay proof: a second `runWorkflow` of the same id short-circuits
  both steps; a shared counter increments exactly twice across two runs (journal stays at
  3 events). Same-named step in one run reuses the first's recorded result. Tests green.
- [x] M5 (2026-06-03) — Cabal wiring (`Keiro.Workflow{,.Types,.Schema}` added to
  `exposed-modules`; `containers` added to build-depends), the reserved-prefix /
  build-gotcha / contract-recap Haddock block atop `Keiro.Workflow`. Full `cabal test
  keiro` green (100 examples, 0 failures) and `cabal build all` green.


## Surprises & Discoveries

- 2026-06-03 (cross-plan, recorded during parallel drafting of the sibling plans): the
  wake-source plans EP-39 (sleep), EP-40 (awakeables), and EP-43 (child workflows) all
  need two small handler accessors this plan must therefore own and ship:
  `currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)` (so an arming
  action can key a timer/awakeable/child to its own workflow instance) and `freshOrdinal
  :: (Workflow :> es) => Text -> Eff es Int` (a per-run, per-namespace counter so `sleep`/
  `awakeable` convenience forms that do not take an explicit name get a *deterministic*
  ordinal name like `sleep:0`, `awk:1` that is stable across replays). Owning one
  `freshOrdinal` here prevents the two plans from inventing two divergent counters. M3
  builds both; they read the handler's per-run `IORef` state. EP-39 additionally needs
  `appendJournalEntryReturningId` (the same append but returning the `EventId`, so a fired
  timer can record it via `markTimerFired`); it is a trivial variant of
  `appendJournalEntry` and is added here.
- 2026-06-03 (cross-plan): EP-41 (snapshots) needs a per-run options record; rather than
  let EP-41 refactor `runWorkflow` into `runWorkflowWith`, this plan ships
  `runWorkflowWith :: WorkflowRunOptions -> ...` with a minimal `WorkflowRunOptions {
  pageSize }` and `defaultWorkflowRunOptions`, and defines `runWorkflow = runWorkflowWith
  defaultWorkflowRunOptions`. EP-41 adds a `snapshotPolicy` field, EP-44 adds `metrics`/
  `tracer` fields — all additive to the same record, which is the canonical home for
  per-run options across the initiative (the MasterPlan records this). EP-42's resume
  worker re-invokes through `runWorkflowWith` so resumed runs honor the same options.
- 2026-06-03 (cross-plan): EP-43 (child workflows) will add `WorkflowCancelled` and
  `WorkflowFailed` constructors to `WorkflowJournalEvent` (additive within `schemaVersion =
  1` — leave the codec open for them, as M1 already notes), a `Cancelled` arm to
  `WorkflowOutcome`, a handler short-circuit that aborts a run whose journal carries
  `WorkflowCancelled`, and a completion hook on `runWorkflowWith` (to propagate a child's
  result into its parent's journal). These are handler extensions EP-43 owns; this plan
  only needs to keep the codec, the outcome type, and the handler structured so those
  additions are local, not rewrites.
- 2026-06-03 (implementation): **Idempotent journaling is achieved by pre-load gating, not
  by catching `DuplicateEvent`.** The plan suggested treating kiroku's `DuplicateEvent` as
  success. In practice, the journal append is combined with the `keiro_workflow_steps`
  index upsert in one transaction via `runTransactionAppending`, and a duplicate
  caller-supplied event id inside a transaction surfaces as a generic `ConnectionError`
  (the unique-violation raises a SQL exception; `runTransaction` only maps it to
  `ConnectionError`, not the clean `DuplicateEvent` the bare `appendToStream` path gives) —
  and it would also condemn the index write. So instead of catching, the handler **never
  re-appends**: the journal map is pre-loaded from the stream (the source of truth), so a
  `step` hit short-circuits before any append, and the terminal `WorkflowCompleted` /
  external `appendJournalEntry` paths pre-check existence with `stepExists` before
  appending. The deterministic v5 id (over `("keiro":"workflow":name:id:stepName)`) is kept
  as belt-and-suspenders for the genuinely concurrent two-runner case (which EP-42 serializes
  with claims). Net effect for downstream plans: `appendJournalEntry` is **idempotent** — a
  repeated call for an already-journaled step is a no-op returning the deterministic id.
- 2026-06-03 (implementation): **`appendJournalEntry`/`appendJournalEntryReturningId` carry
  an `IOE :> es` constraint**, not just `Store :> es` as the Interfaces sketch showed. The
  combined append+index transaction goes through `runTransactionAppending`, which needs
  `IOE` (UUID prep + `getCurrentTime` happen in IO before the transaction body). Every wake
  source that calls these helpers (EP-39's timer worker, EP-40's `signalAwakeable`, EP-43's
  child completion) already runs with `IOE` in scope, so this is not a real restriction; it
  is recorded so those plans annotate their signatures accordingly.
- 2026-06-03 (implementation): suspension is implemented with an internal
  `WorkflowSuspend` exception thrown via `Effectful.Exception.throwIO` and caught at the top
  of `runWorkflowWith` (mapped to `Suspended`). `Effectful.Exception.throwIO`/`catch` work
  directly in `Eff es` (no `liftIO` wrapper), and the catch is type-directed so it only
  intercepts `WorkflowSuspend`, never the runtime's `WorkflowError`s or user exceptions.
- 2026-06-03 (implementation): `containers` was not previously a `keiro` dependency; it had
  to be added to both the library and test-suite `build-depends` for `Data.Map.Strict`
  (the `WorkflowState = Map Text Value` representation). `Data.Aeson`'s `.=`/`.:` clash with
  `lens` operators re-exported by `Keiro.Prelude`, so aeson operators are used qualified
  (`Aeson..=`, `Aeson..:`) — the same idiom the rest of the codebase uses.


## Decision Log

- Decision: Model the workflow surface as an `effectful` higher-order dynamic effect
  `Workflow`, with `step :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es
  a -> Eff es a`, rather than a free monad or a bespoke `Workflow es a` newtype.
  Rationale: The roadmap (`docs/research/10-workflow-roadmap.md` §4) calls `Workflow es
  a` "an effectful-style effect (a labelled wrapper around `Eff es a`)". A higher-order
  dynamic effect lets `step` receive the user's `Eff es a` action and choose to run it or
  short-circuit it, using effectful's `localSeqUnlift` to run the action in the
  surrounding context. This keeps workflows first-class `Eff` computations so users can
  freely mix `Store`, `IOE`, and other effects between steps, exactly as the roadmap's
  "code between steps can be anything" promise requires.
  Date: 2026-06-03.

- Decision: Require `ToJSON a, FromJSON a` on a step's result (Aeson) for v2, rather than
  a full keiro `Codec a` with upcasters per step.
  Rationale: A step result is a single value, not an event sum type; Aeson instances are
  the lightest authoring requirement and most step results are records or primitives.
  Per-step schema evolution (upcasters) is a forward-compatible enhancement: the journal
  stores each result as a self-describing JSON `Value`, so a later plan can swap the
  `ToJSON/FromJSON` constraint for a richer `StepCodec a` without changing the journal
  format. Recorded so a future evolution plan knows the door is open.
  Date: 2026-06-03.

- Decision: The core owns suspension. `runWorkflow` returns `WorkflowOutcome a`
  (`Completed a | Suspended`), and the core exposes `awaitStep :: StepName -> Eff es () ->
  Eff es a` ("decode the recorded result, or arm a wake source once and suspend"). EP-38
  ships no wake source itself.
  Rationale: `sleep` (EP-39), `awakeable` (EP-40), and child-wait (EP-43) are all the same
  shape — "is the awaited result journaled yet? if not, arm a wake source and pause." Put
  that shape in the core so the three wake-source plans stay independent (parallel Wave 2/
  Wave 4) rather than each depending on whichever introduced suspension first. It also
  forces `runWorkflow`'s return type to admit a paused run up front, avoiding a
  breaking signature change when the first wake source lands.
  Date: 2026-06-03.

- Decision: Journal entries get deterministic event ids — a v5 UUID over
  `("keiro" : "workflow" : workflowName : workflowId : stepName)` — and the append treats
  kiroku's `DuplicateEvent` as success.
  Rationale: This mirrors `Keiro.ProcessManager.deterministicCommandId`
  (`keiro/src/Keiro/ProcessManager.hs`). If two runners race (or a run retries after a
  partial append) the second append of the same step collapses to the same row instead
  of duplicating the journal, giving idempotent journaling for free.
  Date: 2026-06-03.


## Outcomes & Retrospective

**Achieved (2026-06-03).** The foundation of the v2 durable-execution runtime is in the
tree and proven by tests. A user can write a `Workflow`-effect do-block, run it with
`runWorkflow (WorkflowName "demo") wid action`, and get durable named-step journaling and
replay: the journal is the kiroku stream `wf:<name>-<id>`, each `step` records its result
once, and a re-run short-circuits already-journaled steps without re-running side effects.
The suspension primitive (`awaitStep` + `WorkflowOutcome (Completed | Suspended)`) and the
reusable external-completion helper (`appendJournalEntry`) are in place, so EP-39
(`sleep`), EP-40 (`awakeable`), and EP-43 (child workflows) can each supply only an arming
action and a completion append without depending on one another. Discovery for EP-42's
resume worker is `findUnfinishedWorkflowIds` over the `keiro_workflow_steps` index — no
kiroku prefix subscription needed.

**Shipped surface (stable contracts for EP-39…EP-45):** module `Keiro.Workflow` (effect
`Workflow`; `step`, `awaitStep`, `currentWorkflow`, `freshOrdinal`; `runWorkflow`,
`runWorkflowWith`, `WorkflowRunOptions { pageSize }`, `defaultWorkflowRunOptions`;
`appendJournalEntry`, `appendJournalEntryReturningId`; `WorkflowError`), `Keiro.Workflow.Types`
(`WorkflowName`, `WorkflowId`, `StepName`, `WorkflowJournalEvent (StepRecorded |
WorkflowCompleted)`, `workflowJournalCodec`, `WorkflowState = Map Text Value`,
`WorkflowOutcome`, `completedStepName`, `sleepStepPrefix`/`awakeableStepPrefix`/`childStepPrefix`),
and `Keiro.Workflow.Schema` (`WorkflowStepRow`, `recordStepTx`, `loadStepIndex`, `stepExists`,
`findUnfinishedWorkflowIds`) plus migration `2026-06-03-00-00-00-keiro-workflow-steps.sql`.

**Evidence.** `cabal test keiro` (the `Keiro.Workflow` group):

```text
Keiro.Workflow
  journals each step once, returns Completed, and runs each side effect once [✔]
  replays recorded steps without re-running their side effects [✔]
  reuses the recorded result for a repeated step name in one run [✔]
  suspends on an unresolved awaitStep, journaling no completion [✔]
  resumes and completes once an awaited step is externally completed [✔]
  discovers unfinished workflows via the step index [✔]

Finished in 10.6428 seconds
100 examples, 0 failures
Test suite keiro-test: PASS
```

**Deviations from the plan** (all recorded in Surprises & Discoveries): idempotency is by
pre-load gating + `stepExists` rather than catching `DuplicateEvent`; the journal helpers
carry an `IOE` constraint; `containers` was added as a dependency. None change the
documented downstream contracts.

**What remains:** nothing for EP-38. The wake sources (EP-39/40/43), snapshots (EP-41),
resume worker (EP-42), observability (EP-44), and docs (EP-45) build on this surface.


## Context and Orientation

The working tree is at `/Users/shinzui/Keikaku/bokuno/keiro`. The library packages are
`keiro-core` (pure contracts), `keiro` (the runtime), `keiro-migrations` (embedded SQL),
`keiro-test-support` (PostgreSQL test fixtures), and `jitsurei` (worked examples). This
plan adds new modules to the `keiro` package and one migration to `keiro-migrations`.
There is **no** `Keiro.Workflow` module today — the entire surface is greenfield.

You will build on these existing pieces. Read them before starting; the line numbers are
guides, not guarantees.

**The `Store` effect (from kiroku, re-exported through Keiro).** This is how you append
to and read from streams. The relevant operations and their Keiro-facing signatures:

```haskell
-- appendToStream targetStream expectedVersion events
appendToStream :: (Store :> es) => StreamName -> ExpectedVersion -> [EventData] -> Eff es AppendResult

-- constant-memory streaming read, pages internally
readStreamForwardStream :: (Store :> es) => StreamName -> StreamVersion -> Int32 -> Stream (Eff es) RecordedEvent

-- run a hasql transaction (multiple statements commit together)
runTransaction :: (Store :> es) => Tx.Transaction a -> Eff es a
```

`StreamName`, `StreamVersion`, `EventId`, `GlobalPosition`, `EventType` are newtypes over
`Text`/`Int64`/`UUID` from kiroku's `Kiroku.Store.Types`. `ExpectedVersion` controls
optimistic concurrency; for a journal where you never conflict on concurrent appends you
can use `Any` (append regardless of version) — but prefer the deterministic-id idempotency
below over version checks. `RecordedEvent` carries the fields you read back:

```haskell
data RecordedEvent = RecordedEvent
  { eventId        :: !EventId
  , eventType      :: !EventType
  , streamVersion  :: !StreamVersion
  , globalPosition :: !GlobalPosition
  , payload        :: !Value          -- JSONB; the encoded step result lives here
  , metadata       :: !(Maybe Value)  -- the codec stamps "schemaVersion" here
  , createdAt      :: !UTCTime
  , ...
  }
```

`EventData` is what you append (the write-side dual):

```haskell
data EventData = EventData
  { eventId       :: !(Maybe EventId)  -- Just <deterministic id> for idempotency
  , eventType     :: !EventType
  , payload       :: !Value
  , metadata      :: !(Maybe Value)
  , causationId   :: !(Maybe UUID)
  , correlationId :: !(Maybe UUID)
  }
```

An append that collides on a caller-supplied `eventId` surfaces `DuplicateEvent`
(`Kiroku.Store.Append`); treat it as success.

**The `Codec` type (`keiro-core/src/Keiro/Codec.hs`).** This is how Keiro turns a domain
event sum type into versioned JSON for kiroku. You will build one `Codec
WorkflowJournalEvent`:

```haskell
data Codec e = Codec
  { eventTypes    :: !(NonEmpty Text)       -- allow-list of wire tags
  , eventType     :: !(e -> Text)           -- value -> its tag
  , schemaVersion :: !Int                   -- start at 1
  , encode        :: !(e -> Value)
  , decode        :: !(Value -> Either Text e)
  , upcasters     :: ![Upcaster]            -- [] for v1
  }

encodeForAppendWithMetadata :: Codec e -> Maybe Value -> e -> Either CodecError EventData
decodeRecorded              :: Codec e -> RecordedEvent -> Either CodecError e
```

`encodeForAppendWithMetadata` validates the tag against `eventTypes`, encodes, and stamps
`schemaVersion` into metadata; `decodeRecorded` reverses it (running upcasters if any).

**The deterministic-id pattern (`keiro/src/Keiro/ProcessManager.hs`, ~lines 154–176).**
Copy its shape exactly for journal ids:

```haskell
deterministicCommandId :: Text -> Text -> EventId -> Int -> EventId
deterministicCommandId managerName correlationId sourceEventId emitIndex =
  EventId $ UUID.V5.generateNamed UUID.V5.namespaceURL $
    fmap (fromIntegral . fromEnum) $ Text.unpack $
      Text.intercalate ":" [ "keiro", "process-manager", managerName, correlationId
                           , UUID.toText (eventIdToUuid sourceEventId), Text.pack (show emitIndex) ]
```

**The stream-naming convention.** v1 process managers name their state stream
`pm:<name>-<correlationId>` (the jitsurei examples use `fulfillment-<orderId>` and
`esc-<incidentId>`; the canonical convention is in
`docs/research/08-subscription-and-process-manager-design.md` §5). v2 workflows use
`wf:<workflow-name>-<workflow-id>` (`docs/research/10-workflow-roadmap.md` §4). You own
this convention.

**The schema-module + migration convention.** Study `keiro/src/Keiro/Timer/Schema.hs` and
`keiro/src/Keiro/Outbox/Schema.hs`: a `*/Schema.hs` module defines the row type, the
`Store`-effect query helpers (`runTransaction $ Tx.statement args stmt`), and the hasql
`Statement` values with their `Encoders`/`Decoders`. Migrations are timestamped SQL files
in `keiro-migrations/sql-migrations/` (existing:
`2026-05-17-00-00-00-keiro-bootstrap.sql` … `2026-05-17-03-00-00-keiro-timer-recovery.sql`),
embedded by the Template Haskell `embedDir "sql-migrations"` in
`keiro-migrations/src/Keiro/Migrations.hs` and exposed via `allKeiroMigrations`. The
public surface is `Keiro.Migrations.allKeiroMigrations` and the `keiro-migrate`
executable.

> **Build gotcha (lost an hour for the EP-34 author — do not repeat it).** Adding a new
> `.sql` file under `sql-migrations/` does **not** trigger recompilation of
> `Keiro.Migrations`: cabal reports "Up to date" and skips ghc even with
> `-fforce-recomp`, because `embedDir` is a Template Haskell directory read that GHC's
> recompilation checker does not track per-file. After adding your migration, force a
> content recompile of `Keiro.Migrations` (edit a comment in
> `keiro-migrations/src/Keiro/Migrations.hs`, or run `cabal clean`) before building.

**The effectful higher-order dynamic-effect pattern.** Keiro's existing effects (e.g. the
re-exported `Store`) use `type instance DispatchOf Eff = Dynamic` and `interpret`. For a
*higher-order* effect (one whose operation takes a monadic action, like `Step`), you
interpret with access to `localSeqUnlift` so you can run the embedded action in the outer
row. The skeleton is:

```haskell
import Effectful
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift, send)

data Workflow :: Effect where
  Step :: (ToJSON a, FromJSON a) => StepName -> m a -> Workflow m a

type instance DispatchOf Workflow = Dynamic

step :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a
step name action = send (Step name action)
```

Read the effectful docs you already have on disk via `mori` if the `localSeqUnlift`
signature is unfamiliar (`mori registry show effectful/effectful --full`).


## Plan of Work

Five milestones. Each is independently verifiable; commit after each.

### Milestone 1 — Types and the journal codec

Create `keiro/src/Keiro/Workflow/Types.hs`. Define:

- `newtype WorkflowName = WorkflowName Text` and `newtype WorkflowId = WorkflowId Text`
  (a UUID-as-text or any stable string id supplied by the caller), `newtype StepName =
  StepName Text`, each `deriving stock (Eq, Show, Generic)` with `Ord` where useful.
- `workflowStreamName :: WorkflowName -> WorkflowId -> StreamName`, returning
  `StreamName ("wf:" <> name <> "-" <> wid)`. Document that `:` and `-` are structural
  and that names/ids must not contain them ambiguously (the v1 PM convention has the same
  caveat).
- The journal event sum type:

  ```haskell
  data WorkflowJournalEvent
    = StepRecorded { stepName :: !Text, result :: !Value, recordedAt :: !UTCTime }
    | WorkflowCompleted { recordedAt :: !UTCTime }
    deriving stock (Eq, Show, Generic)
  ```

  Leave room in the codec's `eventTypes` allow-list for `WorkflowFailed` and
  `WorkflowCancelled`, which sibling plans (EP-42 resume, EP-43 child workflows) will add
  as additional constructors. Note this in a comment so they know the codec is the place
  to extend, and that additions stay within `schemaVersion = 1` (purely additive).
- `workflowJournalCodec :: Codec WorkflowJournalEvent` built per `Keiro.Codec`:
  `eventTypes = "StepRecorded" :| ["WorkflowCompleted"]`, `eventType` projects the
  constructor name, `schemaVersion = 1`, `encode`/`decode` via Aeson (derive
  `ToJSON`/`FromJSON` or hand-write), `upcasters = []`.
- `type WorkflowState = Map Text Value` — the accumulated step-name → encoded-result map
  the replay handler holds in memory. **This alias is the integration contract EP-41
  (snapshots) consumes**; it must be a `Map Text Value`.
- `data WorkflowOutcome a = Completed a | Suspended deriving stock (Eq, Show, Functor)` —
  the result of `runWorkflow`. `Completed a` means the workflow ran to its end and a
  `WorkflowCompleted` event was journaled; `Suspended` means the workflow paused at an
  unresolved `awaitStep` (the wake source has been armed and the run will be resumed
  later by EP-42's worker). **This type is the integration contract EP-39/EP-40/EP-42/
  EP-43 consume.** EP-38 ships no wake source, so within this plan `runWorkflow` only ever
  returns `Completed`; the `Suspended` path is exercised by a test that calls `awaitStep`
  with a never-arming action (see M3).
- The reserved step-name prefixes, as exported constants and a Haddock block:
  `sleepStepPrefix = "sleep:"`, `awakeableStepPrefix = "awk:"`, `childStepPrefix =
  "child:"`. Document that EP-39/EP-40/EP-43 journal their suspensions as ordinary
  `StepRecorded` events whose `stepName` carries these prefixes, so the replay loop stays
  uniform. **This is an integration contract** — those plans must use exactly these
  strings.

Acceptance for M1: `cabal build keiro` succeeds with the new module added to
`exposed-modules`, and a unit test round-trips a `StepRecorded` and a `WorkflowCompleted`
through `encodeForAppendWithMetadata`/`decodeRecorded` (encode to `EventData`, wrap into a
`RecordedEvent`-shaped value or decode the `Value` directly, assert equality).

### Milestone 2 — The `keiro_workflow_steps` table and schema module

Add the migration `keiro-migrations/sql-migrations/2026-06-03-00-00-00-keiro-workflow-steps.sql`
(timestamp strictly after the last existing migration). The table is the fast-lookup index
the runtime hot path and the EP-42 resume worker use so they need not rescan the journal
stream:

```sql
CREATE TABLE keiro_workflow_steps (
  workflow_id    text        NOT NULL,
  workflow_name  text        NOT NULL,
  step_name      text        NOT NULL,
  result         jsonb       NOT NULL,
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workflow_id, step_name)
);

-- Discovery index for the resume worker: find workflows that have steps but no
-- terminal completion marker. The reserved step_name '__workflow_completed__' is
-- written when a workflow finishes (see Keiro.Workflow).
CREATE INDEX keiro_workflow_steps_workflow_idx
  ON keiro_workflow_steps (workflow_id);
```

Use codd's migration syntax (look at an existing file for the `-- codd:` header
conventions). Then create `keiro/src/Keiro/Workflow/Schema.hs` following
`Keiro/Timer/Schema.hs`:

- `data WorkflowStepRow = WorkflowStepRow { workflowId :: !Text, workflowName :: !Text,
  stepName :: !Text, result :: !Value, recordedAt :: !UTCTime }`.
- `recordStepTx :: WorkflowStepRow -> Tx.Transaction ()` — an `INSERT ... ON CONFLICT
  (workflow_id, step_name) DO NOTHING`, so a replayed/raced write is a no-op. This is
  called **inside the same transaction** as the journal append (M3) so the index and the
  journal stay consistent.
- `loadStepIndex :: (Store :> es) => WorkflowId -> Eff es (Map Text Value)` — `SELECT
  step_name, result FROM keiro_workflow_steps WHERE workflow_id = $1`, folded into a
  `Map`. (The handler can use either this or a journal-stream read to pre-load; M3 picks
  the journal-stream read as the source of truth and uses the index for existence/lookup.
  Expose both so EP-42 can use `loadStepIndex` for discovery.)
- `findUnfinishedWorkflowIds :: (Store :> es) => Eff es [(Text, Text)]` — returns
  `(workflow_id, workflow_name)` pairs that have at least one step row but no row with
  `step_name = '__workflow_completed__'`. **EP-42 (resume worker) consumes this**; expose
  it now even though this plan does not run a worker. Implement as:

  ```sql
  SELECT DISTINCT s.workflow_id, s.workflow_name
  FROM keiro_workflow_steps s
  WHERE NOT EXISTS (
    SELECT 1 FROM keiro_workflow_steps c
    WHERE c.workflow_id = s.workflow_id AND c.step_name = '__workflow_completed__'
  );
  ```

Define the reserved completion sentinel `completedStepName :: Text =
"__workflow_completed__"` in `Keiro.Workflow.Types` and use it both when the handler
finishes a workflow (M3, it writes a `__workflow_completed__` index row alongside the
`WorkflowCompleted` journal event) and in this query.

Acceptance for M2: after `cabal clean` (the build gotcha) and `cabal build`, running the
migrations against an ephemeral database (the test harness in `keiro-test-support`) shows
`keiro_workflow_steps` present; a small test inserts two step rows + a completion row for
one workflow and only a step row for another, then asserts `findUnfinishedWorkflowIds`
returns exactly the second.

### Milestone 3 — The `Keiro.Workflow` effect, `step`, and `runWorkflow`

Create `keiro/src/Keiro/Workflow.hs`. Define the effect and the surface from the Context
section. Then implement `runWorkflow`:

```haskell
runWorkflow ::
  (IOE :> es, Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  Eff (Workflow : es) a ->
  Eff es a
```

Handler algorithm:

1. **Pre-load the journal.** Read the journal stream with `readStreamForwardStream
   (workflowStreamName name wid) (StreamVersion 0) pageSize`, decode each event with
   `workflowJournalCodec`, and fold the `StepRecorded` entries into a `WorkflowState`
   (`Map Text Value`). Hold it in an `IORef` (created via `liftIO`) so the interpreter can
   read and extend it as steps run. (Reading the stream is the source of truth; the
   `keiro_workflow_steps` index is a derived view kept in sync by `recordStepTx`.)
2. **Interpret `Step name action`** with `interpret` + `localSeqUnlift`:
   - Let `key = unStepName name`. Look it up in the `IORef` map.
   - **Hit:** decode the stored `Value` to `a` via `fromJSON`; on success return it
     **without running `action`**. On a decode failure, fail loudly (a journal that
     cannot be decoded into the expected type is a programmer error — the step's result
     type changed incompatibly; surface a clear error mentioning the step name).
   - **Miss:** run `action` via `localSeqUnlift` to get `a :: a`; `encode` it to a
     `Value`; build a `StepRecorded { stepName = key, result = v, recordedAt = now }`;
     in **one** `runTransaction`, append it to the journal stream (with a deterministic
     event id over `("keiro":"workflow":name:wid:key)` and `DuplicateEvent`-as-success)
     **and** call `recordStepTx` to upsert the index row; then insert `key -> v` into the
     `IORef` map and return `a`.
3. **On normal completion of the whole computation,** after the interpreted action
   returns its final `a`: append a `WorkflowCompleted` journal event (deterministic id
   over `("keiro":"workflow":name:wid:"__workflow_completed__")`, `DuplicateEvent`-as-
   success) and a `keiro_workflow_steps` row with `step_name = completedStepName` and a
   `result` of JSON `null`, in one transaction. Return `Completed a`.

Now add the **suspension primitive** every wake-source plan builds on. Add to the
`Workflow` effect an `Await` operation and expose:

```haskell
-- Look up `name` in the journal. If a wake source has already recorded its completion
-- (a StepRecorded whose stepName == name, carrying the resolved result), decode and
-- return it. Otherwise run `arm` exactly once (idempotently schedule a timer / register
-- an awakeable / spawn a child — the wake source's job) and SUSPEND this run.
awaitStep :: (Workflow :> es, FromJSON a) => StepName -> Eff es () -> Eff es a
```

Handler branch for `Await name arm`:

- Let `key = unStepName name`. Look it up in the `IORef` journal map.
- **Hit:** decode the stored `Value` to `a` and return it (the wake source resolved it on
  an earlier external event). This is identical to the `Step` hit path.
- **Miss:** run `arm` via `localSeqUnlift` (it performs the wake-source's idempotent
  arming — e.g. `scheduleTimerTx` inside its own transaction). Then **suspend**: abort the
  rest of this run so `runWorkflow` returns `Suspended`. Implement suspension with a
  sentinel exception thrown in `Eff` (e.g. a `data WorkflowSuspend = WorkflowSuspend`
  thrown via `throwIO`/`Effectful.Exception`) that `runWorkflow` catches at the top and
  maps to `Suspended`; do **not** journal anything for the await on the miss path (the
  wake source journals the completion later). Document clearly that `arm` must be
  idempotent because a workflow that suspends and is resumed will re-enter `awaitStep`
  from the top on each resume until the completion is journaled — every resume re-runs
  `arm` until the step resolves, so `arm` (e.g. scheduling a timer with a deterministic
  `timerId`) must collapse repeats to a no-op.

Be careful with effectful's higher-order interpretation: the `Step`/`Await` constructors'
`m a`/`m ()` must run in the surrounding effect context (so the user can use `Store`/`IOE`/
etc. inside a step or an arming action). `localSeqUnlift` provides the unlifting function;
see the effectful docs on disk. Because `step`/`awaitStep` carry their `ToJSON`/`FromJSON`
constraints on the constructor, the dictionaries are available in the handler branch.

Add the journal-append as a small reusable helper, e.g. `appendJournalEntry :: (Store :>
es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()`, so EP-39/EP-40/
EP-43 can record `sleep:`/`awk:`/`child:` completion entries through the same code path
rather than re-implementing the deterministic-id + duplicate-handling logic. **This helper
is an integration contract** — export it. A wake source's external completion path (the
timer worker, `signalAwakeable`, a child finishing) calls `appendJournalEntry` with a
`StepRecorded` whose `stepName` is the awaited step name and whose `result` is the
resolved value; the next `runWorkflow` then takes the `awaitStep` hit path and proceeds.

Acceptance for M3: (a) a test runs `runWorkflow (WorkflowName "demo") wid demo` where
`demo` has two `step`s each performing `liftIO (modifyIORef counter (+1)) >> liftIO
(readIORef counter)`; after the run the journal stream `wf:demo-<wid>` has exactly three
events (two `StepRecorded`, one `WorkflowCompleted`), the counter is 2, and the result is
`Completed (1, 2)`. (b) A test runs a workflow whose first action is `awaitStep (StepName
"awk:test") (pure ())` (a never-arming wake source); `runWorkflow` returns `Suspended` and
the journal contains **no** `WorkflowCompleted`. (c) After manually `appendJournalEntry`-ing
a `StepRecorded "awk:test"` with a JSON result into that workflow's journal, a second
`runWorkflow` of the same workflow takes the hit path, returns `Completed`, and journals
`WorkflowCompleted` — proving the suspend → external-completion → resume cycle works end to
end without any wake source plan.

### Milestone 4 — Replay short-circuit proof

This milestone adds no production code; it adds the durability test that justifies the
whole runtime. Using the same `demo` and a shared `IORef` counter:

- Run `runWorkflow name wid demo` once. Assert it returns `(1, 2)` and the counter is `2`.
- Run `runWorkflow name wid demo` **again** with the same `name`/`wid` (the crash-restart
  scenario). Assert it returns `(1, 2)` **again** (the recorded results) and the counter
  is **still `2`** — proving neither side effect re-ran. Assert the journal still has
  three events (the deterministic ids made the re-appends no-ops).

Also add a test that two steps with the *same* `StepName` is a usage error you detect (or,
if you choose to allow it with last-write semantics, document and test whichever you
pick — recommended: the second same-named step in one run reuses the first's recorded
result, since the journal keys on name; add a test asserting that behavior so it is
specified, not accidental).

Acceptance for M4: both tests green in `cabal test keiro`.

### Milestone 5 — Cabal wiring, reserved-prefix docs, contract recap

- Add `Keiro.Workflow`, `Keiro.Workflow.Types`, `Keiro.Workflow.Schema` to the
  `exposed-modules` stanza in `keiro/keiro.cabal` (the list around lines 34–56). Edit only
  your own lines; do not reorder the existing list (sibling plans append their own
  modules to the same stanza and minimal diffs avoid merge churn — an integration point in
  the MasterPlan).
- Ensure `Keiro` (the umbrella module, `keiro/src/Keiro.hs`) re-exports the workflow
  surface if that is the package's convention (check whether `Keiro` re-exports `Keiro.Timer`
  etc.; match it).
- Write the reserved-prefix and contract recap as a Haddock block at the top of
  `Keiro.Workflow` summarizing, for downstream plans: the effect and `step`/`runWorkflow`
  signatures, `workflowStreamName`, `workflowJournalCodec`, the `StepRecorded`/
  `WorkflowCompleted` events and the room for `WorkflowFailed`/`WorkflowCancelled`, the
  `appendJournalEntry` helper, `WorkflowState = Map Text Value`, `completedStepName`, the
  `sleep:`/`awk:`/`child:` reserved prefixes, and `findUnfinishedWorkflowIds`.

Acceptance for M5: full `cabal test keiro` green; `cabal build all` (including jitsurei)
green; the contract recap is present.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. Use the project's
toolchain (the repo builds with `cabal` under a Nix-provided GHC; run `cabal build keiro`
and `cabal test keiro`).

```bash
# M1
$EDITOR keiro/src/Keiro/Workflow/Types.hs        # types + codec + reserved constants
$EDITOR keiro/keiro.cabal                         # add Keiro.Workflow.Types to exposed-modules
cabal build keiro

# M2
$EDITOR keiro-migrations/sql-migrations/2026-06-03-00-00-00-keiro-workflow-steps.sql
$EDITOR keiro-migrations/src/Keiro/Migrations.hs  # touch a comment to force TH recompile (build gotcha)
$EDITOR keiro/src/Keiro/Workflow/Schema.hs
$EDITOR keiro/keiro.cabal                          # add Keiro.Workflow.Schema
cabal clean && cabal build keiro                   # clean is the reliable way past the embedDir gotcha

# M3–M5
$EDITOR keiro/src/Keiro/Workflow.hs
$EDITOR keiro/keiro.cabal                           # add Keiro.Workflow
$EDITOR keiro/test/Main.hs                          # add the workflow test group
cabal test keiro
```

The test suite is a single `keiro/test/Main.hs` (exitcode-stdio) that runs against an
ephemeral PostgreSQL database via `keiro-test-support`. Per the project memory, use the
suite-level template-database fixture for DB-backed tests rather than per-example
migration — follow how the existing timer/outbox/snapshot tests in `Main.hs` acquire a
store and apply `allKeiroMigrations`.


## Validation and Acceptance

The whole plan is accepted when `cabal test keiro` is green and the durability behavior is
observable:

- **Journaling:** after one `runWorkflow` of a two-step workflow, reading `wf:demo-<wid>`
  back returns three events in order: `StepRecorded "first"`, `StepRecorded "second"`,
  `WorkflowCompleted`. (Decode them with `workflowJournalCodec` and assert.)
- **Idempotent journaling:** a second identical `runWorkflow` leaves the journal at three
  events (no duplicates), because the deterministic ids collided and `DuplicateEvent` was
  treated as success.
- **Replay short-circuit:** a shared counter incremented inside each step reads `2` after
  the first run and **still `2`** after the second run, proving recorded steps do not
  re-run their side effects.
- **Discovery query:** `findUnfinishedWorkflowIds` returns a workflow that has steps but
  no `__workflow_completed__` row, and omits a completed one. (This is the seam EP-42
  builds the resume worker on.)

Capture the green test transcript in this section's final revision (the relevant
`tasty`/`hspec` group output) as evidence.


## Idempotence and Recovery

Re-running any milestone is safe: source edits are idempotent, the migration is additive
and guarded by codd's applied-migration ledger (re-applying is a no-op), and the
deterministic-id journaling means re-running a workflow never duplicates journal rows. If
you add the migration but hit the `embedDir` build gotcha (cabal says "Up to date" but the
new table is missing at runtime), run `cabal clean` and rebuild `keiro-migrations`. If a
test leaves a workflow journal behind, the template-database fixture gives each suite run
a fresh database, so there is nothing to clean up by hand.


## Interfaces and Dependencies

Libraries/modules used and why: `effectful` (the effect + higher-order interpretation),
kiroku's `Store` effect re-exported by Keiro (append/read/transaction), `Keiro.Codec`
(the journal codec), `aeson` (`Value`, `ToJSON`, `FromJSON` for step results),
`uuid`/`Data.UUID.V5` (deterministic ids), `hasql`/`hasql-th` (the schema statements,
matching `Keiro/Timer/Schema.hs`), `containers` (`Map`), and `keiro-migrations` (the new
SQL file).

Types, signatures, and modules that must exist at the end of this plan (the contracts
sibling plans EP-39…EP-45 consume — keep these stable):

```haskell
-- Keiro.Workflow.Types
newtype WorkflowName = WorkflowName Text
newtype WorkflowId   = WorkflowId Text
newtype StepName     = StepName Text
data WorkflowJournalEvent = StepRecorded { stepName :: Text, result :: Value, recordedAt :: UTCTime }
                          | WorkflowCompleted { recordedAt :: UTCTime }
data WorkflowOutcome a    = Completed a | Suspended      -- result of runWorkflow
type WorkflowState = Map Text Value
workflowStreamName   :: WorkflowName -> WorkflowId -> StreamName
workflowJournalCodec :: Codec WorkflowJournalEvent
completedStepName    :: Text                    -- "__workflow_completed__"
sleepStepPrefix, awakeableStepPrefix, childStepPrefix :: Text  -- "sleep:", "awk:", "child:"

-- Keiro.Workflow.Schema
data WorkflowStepRow = WorkflowStepRow { workflowId :: Text, workflowName :: Text, stepName :: Text, result :: Value, recordedAt :: UTCTime }
recordStepTx              :: WorkflowStepRow -> Tx.Transaction ()
loadStepIndex             :: (Store :> es) => WorkflowId -> Eff es (Map Text Value)
findUnfinishedWorkflowIds :: (Store :> es) => Eff es [(Text, Text)]   -- (workflow_id, workflow_name)

-- Keiro.Workflow
data Workflow :: Effect
step          :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a
awaitStep     :: (Workflow :> es, FromJSON a) => StepName -> Eff es () -> Eff es a   -- arm-once-then-suspend
runWorkflow   :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
runWorkflowWith :: (IOE :> es, Store :> es) => WorkflowRunOptions -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
appendJournalEntry          :: (Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()
appendJournalEntryReturningId :: (Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es EventId
-- Per-run handler accessors used by the wake-source plans (EP-39/EP-40/EP-43) to build
-- deterministic ids without the user re-threading the workflow identity:
currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)
freshOrdinal    :: (Workflow :> es) => Text -> Eff es Int   -- per-run, per-namespace counter

-- Options record (minimal here; EP-41 adds `snapshotPolicy`, EP-44 adds `metrics`/`tracer`).
data WorkflowRunOptions = WorkflowRunOptions { pageSize :: Int32 }
defaultWorkflowRunOptions :: WorkflowRunOptions
-- runWorkflow = runWorkflowWith defaultWorkflowRunOptions
```

Downstream consumers and what they take from here:

- EP-39 (sleep): `step`/`appendJournalEntry`, `sleepStepPrefix`, the journal/replay
  handler recognizing a `sleep:` step's recorded completion.
- EP-40 (awakeables): `appendJournalEntry`, `awakeableStepPrefix`, the
  `WorkflowJournalEvent` codec to extend if needed.
- EP-41 (snapshots): `WorkflowState = Map Text Value`, `workflowStreamName`, the journal
  stream as the snapshot subject.
- EP-42 (resume worker): `findUnfinishedWorkflowIds`, `runWorkflow` (re-invocation),
  `completedStepName`.
- EP-43 (child workflows): `appendJournalEntry`, `childStepPrefix`, possibly new
  `WorkflowJournalEvent` constructors.
- EP-44 (observability): the handler call sites to instrument (`Maybe KeiroMetrics`
  threading — coordinate with the MasterPlan's Telemetry integration point).
- EP-45 (worked example + docs): the whole authoring surface.

Every commit while implementing this plan must carry all three git trailers:

```text
MasterPlan: docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md
ExecPlan: docs/plans/38-workflow-journal-and-named-step-replay-core.md
Intention: intention_01kt6y4cb6eqz9mq48kf2xw8n1
```
