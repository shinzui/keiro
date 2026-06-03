---
id: 43
slug: child-workflows-spawn-wait-and-cancel
title: "Child workflows: spawn, wait, and cancel"
kind: exec-plan
created_at: 2026-06-03T14:39:45Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
master_plan: "docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md"
---

# Child workflows: spawn, wait, and cancel

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds **child workflows** to Keiro's v2 durable-execution runtime. A *child
workflow* is a second workflow spawned from inside a running *parent* workflow. The
parent records a handle to that child in its own journal, so the parent↔child
relationship is durable: if the process crashes and the parent is later re-invoked from
the top, it does **not** re-spawn the child — it finds the recorded handle and proceeds.
The parent can wait for the child's result and can cancel the child.

"Durable execution" (the foundation EP-38 established, checked into this repo at
`docs/plans/38-workflow-journal-and-named-step-replay-core.md`) means a user writes a
long-running function as an ordinary Haskell `Eff` do-block whose side effects are
*journaled* (recorded) at named checkpoints, so the function can be paused and resumed
across crashes without re-running effects that already happened. The *journal* is a
kiroku event stream named `wf:<workflow-name>-<workflow-id>` holding one event per
checkpoint. This plan layers a composition primitive — spawn/await/cancel a child — onto
that journal, reusing exactly the same suspend-until-journaled mechanism EP-38 built for
awakeables, rather than inventing a second suspension path.

After this plan, a user can write a parent workflow like this and run it with the EP-42
resume worker (or, before EP-42 lands, by re-invoking `runWorkflow` in a loop):

```haskell
parent :: (Workflow :> es, Store :> es) => Eff es Text
parent = do
  h      <- spawnChild (WorkflowName "ship-order") (WorkflowId "ord-7") shipWorkflow
  result <- awaitChild h                  -- SUSPEND until the child completes
  _      <- step (StepName "notify") (pure ("shipped: " <> result))
  pure result
```

`spawnChild name wid child` records the child in the parent's journal as a
`StepRecorded` whose step name is `child:<childId>` (so a replay short-circuits the
spawn), registers the child as a runnable, unfinished workflow that the EP-42 resume
worker will drive to completion, and returns a `ChildHandle Text`. `awaitChild h`
suspends the parent until the child's completion is propagated into the *parent's*
journal as a `StepRecorded "child:<childId>:result"` carrying the child's decoded result.
When the child finishes, a hook in `runWorkflowWith` appends that result entry to the
parent's journal, which is exactly the wake source the parent's `awaitStep` resolves on.
`cancelChild h` marks the child cancelled and appends a `WorkflowCancelled` event to the
child's journal so the child's next resume short-circuits and stops.

What a user gains that they could not do before: **fan-out / fan-in composition of
durable workflows** — a parent orchestrates one or more children, waits for their
results, and can abandon a child it no longer needs, with the whole relationship
surviving a crash. This is the v2 child-workflow feature from
`docs/research/10-workflow-roadmap.md` §6.3 ("A workflow spawned by a parent workflow,
recorded in the parent's journal so the parent can wait on or cancel it").

Term definitions used throughout (define-on-first-use, per the plan spec):

- *parent / child* — the spawning workflow and the spawned workflow. Each is an ordinary
  `runWorkflow`-able workflow with its own journal stream; the only added structure is a
  recorded link from parent to child.
- *child id* — the `WorkflowId` of the child, supplied by the parent's `spawnChild` call.
  Combined with the child's `WorkflowName` it names the child's journal stream
  `wf:<childName>-<childId>` exactly like any workflow.
- *child handle* — `ChildHandle a`, an in-memory value `spawnChild` returns carrying the
  child's name, id, and the awaited-step name; `awaitChild`/`cancelChild` take it.
- *parent link* — a durable record, stored in the new `keiro_workflow_children` table,
  that the child's id/name maps back to the parent's id/name plus the awaited step name,
  so when the child completes the runtime knows whose journal to propagate the result to.
- *arming action* — the `Eff es ()` that EP-38's `awaitStep` runs once on the suspend
  path. For a child, arming re-asserts the parent link and the child's runnable marker
  (idempotent), so a resume that re-enters `awaitChild` does not duplicate anything.
- *suspend / resume* — a workflow run aborts partway through (`runWorkflow` returns
  `Suspended`) and is later re-invoked from the top, short-circuiting journaled steps.
  EP-38 owns this. The EP-42 resume worker automates resume; this plan triggers it
  manually in tests when EP-42 has not yet landed.


## Progress

- [ ] M1 — `keiro_workflow_children` table: migration SQL + `Keiro.Workflow.Child.Schema`
  with the hasql statements (`registerChildTx`, `lookupChild`, `lookupChildrenOfParent`,
  `markChildResultTx`, `markChildCancelledTx`, `childStatus`, `countActiveChildren`).
  Migration applies under the test harness; a unit test inserts a child link, marks it
  completed, marks another cancelled, and reads them back.
- [ ] M2 — `Keiro.Workflow.Child`: `ChildId`/`ChildHandle`, `spawnChild`, `awaitChild`,
  `cancelChild`, the `WorkflowChildCancelled` exception, and the `childResultStepName`
  helper. Compiles; the spawn-step name and result-step name derivations are stable.
- [ ] M3 — EP-38 handler extensions consumed here: `runWorkflowWith` (parent-link
  completion hook) and the `WorkflowCancelled` short-circuit. Add the `WorkflowCancelled`
  (and `WorkflowFailed`) constructors to EP-38's `WorkflowJournalEvent` codec; teach the
  handler to abort a run whose journal carries `WorkflowCancelled`. Cross-plan contract
  recorded in Surprises & Discoveries.
- [ ] M4 — End-to-end spawn → drive child → propagate result → resume parent proof against
  ephemeral Postgres, driven by the EP-42 resume worker (registry has both) or a manual
  `runWorkflow` loop. Parent ends `Completed`; parent journal has `child:<id>:result`; child
  journal has its steps + `WorkflowCompleted`. Test green.
- [ ] M5 — Crash-survival + cancellation proofs: re-invoking the parent does not re-spawn
  the child; cancelling a child appends `WorkflowCancelled`, the child stops, and
  `awaitChild` throws `WorkflowChildCancelled`. Tests green.
- [ ] M6 — Cabal wiring (append `Keiro.Workflow.Child` + `.Schema`), Haddock contract recap,
  full suite green via `cabal test keiro`.


## Surprises & Discoveries

(None yet.)

Cross-plan contracts proposed by this plan (to be confirmed by the MasterPlan / EP-38
during implementation — recorded here at planning time so they are not lost):

- **`WorkflowCancelled` and `WorkflowFailed` constructors on EP-38's
  `WorkflowJournalEvent` codec.** EP-38's `Keiro.Workflow.Types` already reserves room in
  the codec's `eventTypes` allow-list for these (EP-38 M1 explicitly notes "Leave room in
  the codec's `eventTypes` allow-list for `WorkflowFailed` and `WorkflowCancelled`"). This
  plan adds them as real constructors. The addition is **purely additive within
  `schemaVersion = 1`** (a new wire tag added to the allow-list; old journals never carry
  it, so no upcaster is needed). `WorkflowCancelled { recordedAt :: UTCTime }` is the
  cancellation marker this plan writes to a child's journal; `WorkflowFailed { reason ::
  Text, recordedAt :: UTCTime }` is included opportunistically because EP-42 (resume
  worker) needs a terminal failure marker and the MasterPlan's Integration Points name
  both as additions "EP-42 or EP-43 may need". **Proposed contract for the MasterPlan /
  EP-38 to record.**

- **EP-38 handler must short-circuit a workflow whose journal carries `WorkflowCancelled`.**
  Cancellation only matters if a cancelled child actually *stops*. EP-38's journal/replay
  handler (in `runWorkflow`/`runWorkflowWith`) must, during its journal pre-load, notice a
  `WorkflowCancelled` event and abort the run before executing any further un-journaled
  step — mapping the outcome to a new `Cancelled` arm of `WorkflowOutcome` (see the
  Decision Log) or by throwing the same suspension-style sentinel EP-38 already uses and
  reporting cancellation. This is a **handler extension this plan owns** (EP-38's
  Integration Points invites exactly this: "If a downstream plan needs a handler capability
  EP-38 did not provide … it extends EP-38's handler and records the addition"). **Proposed
  contract for the MasterPlan / EP-38 to record.**

- **`runWorkflowWith` with a child-completion hook on EP-38.** When a workflow that has a
  recorded parent link completes, its result must be propagated to the parent's journal.
  The cleanest seam is a variant of `runWorkflow`, `runWorkflowWith :: RunWorkflowOptions
  -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)`,
  whose options carry an `onComplete :: Value -> Eff es ()` hook fired with the child's
  encoded result on `Completed`. The resume worker (EP-42) and this plan supply a hook that
  looks up the parent link and appends the `child:<id>:result` `StepRecorded` to the
  parent's journal. EP-38 must export `runWorkflowWith` (or an equivalent terminal hook).
  If EP-38 ships only `runWorkflow`, this plan adds `runWorkflowWith` as the additive
  extension and records it here and in the MasterPlan's Surprises & Discoveries. **Proposed
  contract for the MasterPlan / EP-38 to record.**

- **Dedicated `keiro_workflow_children` table (NOT a reuse of `keiro_awakeables`).** The
  MasterPlan's "`keiro_awakeables` table (EP-40)" Integration Point explicitly says: "EP-43
  … whether it reuses `keiro_awakeables` or adds a parallel `keiro_workflow_children` table
  is an EP-43 decision recorded here once made." **Decision: add a dedicated
  `keiro_workflow_children` table** (rationale in the Decision Log). **Proposed contract for
  the MasterPlan / EP-40 Integration Point to record.**


## Decision Log

- Decision: Add a dedicated `keiro_workflow_children(parent_id, parent_name, child_id,
  child_name, await_step, status, result jsonb, …)` table rather than reusing
  `keiro_awakeables` for the parent-wait link.
  Rationale: The MasterPlan leaves this choice to EP-43 (the "`keiro_awakeables` table"
  Integration Point). A parent↔child relationship is a first-class relation an operator
  inspects ("which children does this parent have, and what is each child's status?"); an
  awakeable row carries only `owner_workflow_id` + `payload` and has no slot for a child's
  *name*, *status lifecycle distinct from a promise*, or the parent→child direction needed
  to answer "list all children of parent X". Overloading `keiro_awakeables` would force
  encoding the child id into the awakeable id and the child name into the payload, losing
  the queryability that makes children operable. A dedicated table also keeps the cancel
  semantics clean (a child has a `cancelled` status that means "stop running", which is
  different from an awakeable's `cancelled` meaning "this promise will never resolve"). The
  wait *mechanism* is still reused (EP-38's `awaitStep` + journal propagation); only the
  storage is separate. Cost is one small additive table and migration, which the schema
  conventions make cheap.
  Date: 2026-06-03.

- Decision: Spawning a child is journaled in the **parent's** journal as a `StepRecorded`
  whose `stepName = childStepPrefix <> childIdText` (i.e. `child:<childId>`), using EP-38's
  `step`/`appendJournalEntry` path, so a replay of the parent does not re-spawn.
  Rationale: EP-38 fixes the reserved prefix `childStepPrefix = "child:"` for exactly this
  (MasterPlan Decision Log, 2026-06-03: "Journal `sleep`, `awakeable`, and child handles as
  the same `StepRecorded` event with reserved step-name prefixes"). Recording the spawn as a
  named step means the replay short-circuit EP-38 already implements makes a re-invoked
  parent skip the spawn body and return the same handle — the durability guarantee for free.
  Date: 2026-06-03.

- Decision: The spawn does **not** run the child inline. `spawnChild` writes the child's
  empty/started journal marker, registers the parent link + a runnable marker, and relies on
  the EP-42 resume worker plus the application's `WorkflowRegistry` (WorkflowName→definition
  map) to drive the child to completion. A child's `WorkflowName` **must** be present in the
  resume worker's registry, exactly like any resumable workflow.
  Rationale: Running the child synchronously inside the parent's `Eff` would block the
  parent's run, couple the two workflows' transactions, and defeat the point of independent
  durable journals (a crash mid-child would corrupt the parent's run). The resume worker is
  already the component that drives any unfinished workflow forward (EP-42); a freshly
  spawned, unfinished child is just another row it discovers via
  `findUnfinishedWorkflowIds`. This keeps spawn cheap and crash-safe and reuses EP-42's
  drive loop rather than adding a second driver. The cost — the child definition must be
  registered — is documented prominently and is identical to the requirement for *any*
  resumable workflow, so it is not a new burden.
  Date: 2026-06-03.

- Decision: `awaitChild h = awaitStep (StepName (childResultStepName childId)) arm`, where
  `childResultStepName cid = childStepPrefix <> cid <> ":result"` (i.e.
  `child:<childId>:result`) and `arm` idempotently re-asserts the parent link + runnable
  marker.
  Rationale: A parent waiting on a child is the *same shape* as waiting on an awakeable
  (EP-40) — "is the result journaled yet? if not, arm a wake source once and suspend." The
  MasterPlan's central integration contract ("The suspension primitive") says to reuse this,
  not reinvent it. The child's completion hook appends a `StepRecorded` whose `stepName ==
  child:<childId>:result` to the parent's journal, so on the next parent run `awaitStep`
  takes the hit path and decodes the child's result. Using a `:result` suffix distinct from
  the `child:<childId>` spawn step keeps the spawn record (which short-circuits the spawn)
  and the completion record (which the parent awaits) as two separate journal entries with
  unambiguous names.
  Date: 2026-06-03.

- Decision: `cancelChild h` appends a `WorkflowCancelled` event to the **child's** journal
  and sets the child row `status = cancelled`; the EP-38 handler short-circuits a workflow
  whose journal carries `WorkflowCancelled`, so the child's next resume stops without running
  remaining steps. `awaitChild` on a cancelled child throws `WorkflowChildCancelled childId`.
  Rationale: The child must observe cancellation through its durable journal (not an
  in-memory flag) so the signal survives a crash and is seen on the next resume — symmetric
  with how EP-40's `cancelAwakeable` makes `await` re-derive a cancelled state on each
  resume. Writing `WorkflowCancelled` into the child journal is the minimal durable signal;
  the handler short-circuit (the cross-plan contract above) is what makes it *take effect*.
  The parent throwing `WorkflowChildCancelled` mirrors EP-40's `WorkflowAwakeableCancelled`:
  a cancelled child will never produce a result, so suspending forever is wrong and
  fabricating a result is wrong; a typed exception lets the parent author run compensation
  (`Effectful.Exception.catch`) and lets the resume worker record the parent failed. The
  parent learns of the cancellation because `cancelChild` also writes a sentinel
  `child:<childId>:result` journal entry tagged as cancelled (a JSON object `{"cancelled":
  true}`) so `awaitChild`'s hit path can detect it and throw rather than decode it as a
  result.
  Date: 2026-06-03.

- Decision: Add a `Cancelled` arm to EP-38's `WorkflowOutcome` (`Completed a | Suspended |
  Cancelled`) so a cancelled child's `runWorkflow` reports `Cancelled` rather than throwing
  out of the handler.
  Rationale: A cancelled run is a distinct terminal outcome from `Completed`/`Suspended`; the
  resume worker (EP-42) and tests need to observe it without catching an exception out of
  `runWorkflow`. This is additive to the `WorkflowOutcome` sum EP-38 owns (EP-38 currently
  ships `Completed a | Suspended`); adding `Cancelled` is forward-compatible for EP-39/EP-40
  which only pattern-match the arms they produce. Recorded as a cross-plan contract.
  Date: 2026-06-03.

- Decision: The spawn writes the child's *started* journal marker as an empty append (no
  events) plus a `keiro_workflow_children` row with `status = running`; it does **not** write
  a `StepRecorded` into the child journal. The child's first real journal events come from
  the resume worker running the child definition.
  Rationale: The discovery query EP-38 exposes (`findUnfinishedWorkflowIds`) finds workflows
  that have at least one `keiro_workflow_steps` row but no `__workflow_completed__` row. A
  freshly spawned child has no steps yet, so to make it discoverable the spawn inserts a
  child link row and the registration also seeds a runnable marker the resume worker keys
  off. EP-43 therefore drives child discovery off `keiro_workflow_children` (status =
  running, child not completed) in addition to `findUnfinishedWorkflowIds`, so a
  zero-step child is still picked up. Recorded so EP-42's drive loop knows to union the two
  discovery sources.
  Date: 2026-06-03.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The working tree is at `/Users/shinzui/Keikaku/bokuno/keiro`. The library packages are
`keiro-core` (pure contracts), `keiro` (the runtime), `keiro-migrations` (embedded SQL),
`keiro-test-support` (PostgreSQL test fixtures), and `jitsurei` (worked examples). This
plan adds two new modules to the `keiro` package (`Keiro.Workflow.Child` and
`Keiro.Workflow.Child.Schema`), one migration file to `keiro-migrations`, and a small set
of additive extensions to EP-38's `Keiro.Workflow`/`Keiro.Workflow.Types`.

This plan **hard-depends on EP-38**
(`docs/plans/38-workflow-journal-and-named-step-replay-core.md`, checked into this repo)
and **soft-depends on EP-40**
(`docs/plans/40-awakeables-and-external-completion.md`) and **EP-42**
(`docs/plans/42-workflow-resume-and-crash-recovery-worker.md`). It consumes EP-38's
suspension machinery and reuses EP-40's await/signal *pattern* (not its table). EP-42's
resume worker is what drives a spawned child to completion and wakes the parent; if EP-42
has not landed when this plan is implemented, drive workflows by calling `runWorkflow` in a
loop in the test (the dependency is recorded in the tests).

### What EP-38 gives you (recapped so you need not read it in full)

EP-38 delivers `Keiro.Workflow` and `Keiro.Workflow.Types` exposing (from EP-38's
"Interfaces and Dependencies"):

```haskell
-- Keiro.Workflow.Types
newtype WorkflowName = WorkflowName Text
newtype WorkflowId   = WorkflowId Text
newtype StepName     = StepName Text
data WorkflowJournalEvent = StepRecorded { stepName :: Text, result :: Value, recordedAt :: UTCTime }
                          | WorkflowCompleted { recordedAt :: UTCTime }
data WorkflowOutcome a    = Completed a | Suspended      -- this plan adds `Cancelled`
type WorkflowState = Map Text Value
workflowStreamName   :: WorkflowName -> WorkflowId -> StreamName    -- "wf:<name>-<id>"
workflowJournalCodec :: Codec WorkflowJournalEvent
completedStepName    :: Text                              -- "__workflow_completed__"
sleepStepPrefix, awakeableStepPrefix, childStepPrefix :: Text  -- "sleep:", "awk:", "child:"

-- Keiro.Workflow
data Workflow :: Effect
step          :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a
awaitStep     :: (Workflow :> es, FromJSON a) => StepName -> Eff es () -> Eff es a
runWorkflow   :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
appendJournalEntry :: (Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()
```

EP-39/EP-40 proposed two further small additions to EP-38's surface that this plan also
reuses for deterministic child ids; assume they are present (EP-40's Surprises &
Discoveries lists them as shared contracts):

```haskell
currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)   -- the running wf's name+id
freshOrdinal    :: (Workflow :> es) => Text -> Eff es Int                  -- per-run monotonic counter by prefix
```

If EP-38 has not yet shipped `currentWorkflow`/`freshOrdinal`/`runWorkflowWith` when this
plan is implemented, this plan adds them to EP-38's effect/handler as the additive
extensions EP-38's Integration Points explicitly invite, and records each addition in this
plan's Surprises & Discoveries **and** in the MasterPlan's Surprises & Discoveries.

The three EP-38 pieces this plan leans on hardest:

- **`awaitStep name arm`** — "look up `name` in the journal; if a `StepRecorded` with that
  `stepName` is present, decode its `result` and return it; otherwise run `arm` exactly once
  (idempotently) and suspend this run." `awaitChild`'s wait is exactly
  `awaitStep (StepName (childResultStepName childId)) arm`. EP-38 guarantees `arm` is re-run
  on **every** resume until the step resolves, which is why `arm` (re-asserting the parent
  link) must be idempotent.

- **`appendJournalEntry name wid event`** — appends a `WorkflowJournalEvent` to the journal
  stream `wf:<name>-<id>` under a deterministic event id, treating kiroku's `DuplicateEvent`
  as success. The child-completion hook calls this on the *parent's* stream with a
  `StepRecorded { stepName = child:<childId>:result, result = childResult, … }`;
  `cancelChild` calls it on the *child's* stream with a `WorkflowCancelled`.

- **The reserved prefix `childStepPrefix = "child:"`** — EP-38's reserved prefix for child
  journal entries. This plan must use exactly that prefix so EP-38's replay loop stays
  uniform. The spawn step is `child:<childId>`; the awaited completion step is
  `child:<childId>:result`.

### The deterministic-id and schema conventions

Read these before starting; they are the templates this plan copies:

- **The deterministic-id pattern** (`keiro/src/Keiro/ProcessManager.hs`,
  `deterministicCommandId`, ~lines 162–176). The child's spawn-step name uses the
  caller-supplied child `WorkflowId` directly (it is already a stable string), so no UUID
  derivation is needed for the step name; but if you ever need a derived id, copy this shape.

- **The schema-module + migration convention.** Study `keiro/src/Keiro/Timer/Schema.hs`
  (the closest template) and `keiro/src/Keiro/Outbox/Schema.hs`: a `*/Schema.hs` module
  defines the row type, the `Store`-effect query helpers (`runTransaction $ Tx.statement
  args stmt`), and the hasql `Statement` values built with `preparable` (from
  `Hasql.Statement`) and `Contravariant.Extras.contrazip*` for multi-parameter encoders.
  The status column is stored as text and mapped via a `statusToText`/`statusFromText`
  pair, with the decode fallback being the most conservative status (mirroring
  `Keiro/Timer/Schema.hs`).

- **Migrations.** Timestamped SQL files live in `keiro-migrations/sql-migrations/`
  (existing: `2026-05-17-00-00-00-keiro-bootstrap.sql` … `2026-05-17-03-00-00-keiro-timer-recovery.sql`;
  plus EP-38's `2026-06-03-00-00-00-keiro-workflow-steps.sql` and EP-40's
  `2026-06-03-01-00-00-keiro-awakeables.sql`). This plan adds
  `2026-06-03-02-00-00-keiro-workflow-children.sql` (timestamp strictly after EP-40's
  `2026-06-03-01-00-00`). The files are embedded by `embedDir "sql-migrations"` in
  `keiro-migrations/src/Keiro/Migrations.hs` and exposed via `allKeiroMigrations`. The
  existing migration files are bare SQL (no `-- codd:` header), which codd treats as a
  single in-transaction migration — match that.

  > **Build gotcha (cost the EP-34 author an hour — do not repeat it).** Adding a new `.sql`
  > file under `sql-migrations/` does **not** trigger recompilation of `Keiro.Migrations`:
  > cabal reports "Up to date" and skips ghc even with `-fforce-recomp`, because `embedDir` is
  > a Template Haskell directory read GHC's recompilation checker does not track per-file.
  > After adding your migration, force a content recompile of `Keiro.Migrations` (edit a
  > comment in `keiro-migrations/src/Keiro/Migrations.hs`, or run `cabal clean`) before
  > building or running the test suite, or your new table will be silently absent at runtime.

- **The test harness.** The suite is a single `keiro/test/Main.hs` (exitcode-stdio, hspec)
  that runs against an ephemeral PostgreSQL database via `keiro-test-support`. The top-level
  wrapper is `withMigratedSuite :: (Fixture -> IO a) -> IO a` (suite-level
  template-database fixture — applies `allKeiroMigrations` once into a template, then each
  test clones it cheaply; imported at `keiro/test/Main.hs:21` from `Keiro.Test.Postgres`).
  Per-test you wrap a `describe` group with `around (withFreshStore fixture)` to get a fresh
  `Store.KirokuStore` handle. Run effectful `Store` computations with `Store.runStoreIO
  storeHandle $ ...`. Follow how the existing `describe "Keiro.Timer" $ around (withFreshStore
  fixture)` group acquires a store and exercises `scheduleTimerTx`/`runTimerWorker`. Per the
  project memory, use the suite-level template-database fixture, not per-example migration.

There is **no** `Keiro.Workflow.Child` module today — it is greenfield, layered on EP-38.

### The `WorkflowRegistry` (from EP-42)

EP-42 introduces a `WorkflowRegistry` — a map from `WorkflowName` to a runnable workflow
definition (a function the resume worker can invoke to produce the `Eff (Workflow : es) a`
to re-run). The resume worker uses it to drive any unfinished workflow forward. For child
workflows this matters concretely: **a spawned child's `WorkflowName` must be in the
registry**, or the resume worker cannot construct and run the child. This plan's tests build
a registry containing both the parent and the child definition. If EP-42 has not landed,
the test substitutes a hand-written drive loop that calls `runWorkflow` for each unfinished
workflow id until all are `Completed`/`Cancelled` — functionally the registry-plus-loop the
worker automates.


## Plan of Work

Six milestones. Each is independently verifiable; commit after each with the git trailers
named in "Interfaces and Dependencies".


### Milestone 1 — The `keiro_workflow_children` table and schema module

Scope: the durable storage for parent↔child links and the hasql helpers that read and
write it. At the end, the table exists in a migrated database and a unit test inserts a
link, marks it completed, cancels another, and reads them back.

Add the migration
`keiro-migrations/sql-migrations/2026-06-03-02-00-00-keiro-workflow-children.sql` (timestamp
strictly after EP-40's `2026-06-03-01-00-00-keiro-awakeables.sql`):

```sql
CREATE TABLE IF NOT EXISTS keiro_workflow_children (
  child_id      TEXT        NOT NULL,
  child_name    TEXT        NOT NULL,
  parent_id     TEXT        NOT NULL,
  parent_name   TEXT        NOT NULL,
  await_step    TEXT        NOT NULL,   -- "child:<childId>:result" in the parent journal
  status        TEXT        NOT NULL DEFAULT 'running',
  result        JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at  TIMESTAMPTZ,
  PRIMARY KEY (child_id, child_name),
  CONSTRAINT keiro_workflow_children_status_chk
    CHECK (status IN ('running', 'completed', 'cancelled'))
);

-- List all children of one parent (operator inspection, awaitChild arm re-assertion).
CREATE INDEX IF NOT EXISTS keiro_workflow_children_parent_idx
  ON keiro_workflow_children (parent_id, parent_name);

-- Discovery for the resume worker: children still running (zero-step children too).
CREATE INDEX IF NOT EXISTS keiro_workflow_children_running_idx
  ON keiro_workflow_children (status)
  WHERE status = 'running';
```

Then create `keiro/src/Keiro/Workflow/Child/Schema.hs`, copying the structure of
`keiro/src/Keiro/Timer/Schema.hs`. Define:

- `data ChildStatus = Running | ChildCompleted | ChildCancelled deriving stock (Eq, Show,
  Generic)` with `statusToText`/`statusFromText` (decode fallback `ChildCancelled`, the
  conservative choice `Keiro/Timer/Schema.hs` makes). (The constructors are named
  `ChildCompleted`/`ChildCancelled` to avoid clashing with `WorkflowOutcome`'s `Completed`
  and EP-40's `Cancelled`.)
- `data ChildRow = ChildRow { childId :: !Text, childName :: !Text, parentId :: !Text,
  parentName :: !Text, awaitStep :: !Text, status :: !ChildStatus, result :: !(Maybe Value),
  createdAt :: !UTCTime, updatedAt :: !UTCTime, completedAt :: !(Maybe UTCTime) } deriving
  stock (Eq, Show, Generic)`.
- `registerChildTx :: ChildRow -> Tx.Transaction ()` — `INSERT INTO keiro_workflow_children
  (child_id, child_name, parent_id, parent_name, await_step, status) VALUES ($1,$2,$3,$4,$5,
  'running') ON CONFLICT (child_id, child_name) DO NOTHING`. **Idempotent** by the
  `ON CONFLICT DO NOTHING`, which is what EP-38's arm contract requires (the spawn and every
  resume's arm re-run it). Runs inside the caller's transaction.
- `lookupChild :: (Store :> es) => Text -> Text -> Eff es (Maybe ChildRow)` — by
  `(child_id, child_name)`, `D.rowMaybe`.
- `lookupChildrenOfParent :: (Store :> es) => Text -> Text -> Eff es [ChildRow]` — by
  `(parent_id, parent_name)`, `D.rowList`. (Operator inspection / awaitChild arm.)
- `markChildResultTx :: Text -> Text -> Value -> UTCTime -> Tx.Transaction Bool` — `UPDATE …
  SET status = 'completed', result = $3, completed_at = $4, updated_at = now() WHERE child_id
  = $1 AND child_name = $2 AND status = 'running'`, returning `(> 0) <$> D.rowsAffected`. The
  `status = 'running'` guard makes a double-complete a no-op.
- `markChildCancelledTx :: Text -> Text -> Tx.Transaction Bool` — `UPDATE … SET status =
  'cancelled', updated_at = now() WHERE child_id = $1 AND child_name = $2 AND status =
  'running'`, returning `(> 0) <$> D.rowsAffected`. Only `running` children can be cancelled.
- `countActiveChildren :: (Store :> es) => Eff es Int` — `SELECT count(*) FROM
  keiro_workflow_children WHERE status = 'running'`. Exposed for EP-44's potential
  `keiro.workflow.children.active` gauge (the MasterPlan's Telemetry surface owns the final
  name); expose it now even though this plan ships no gauge.

Use `preparable` for the `Statement` values and `contrazip*` for multi-parameter encoders,
exactly as `Keiro/Timer/Schema.hs` does.

Acceptance for M1: after adding the migration, `cabal clean && cabal build keiro` (the
`embedDir` gotcha), a new DB test group inserts a running child link, asserts `lookupChild`
returns it with `status = Running`, runs `markChildResultTx` and asserts it returns `True`
and a re-run returns `False`, inserts and `markChildCancelledTx`s a second child, asserts
`lookupChildrenOfParent` returns both, and asserts `countActiveChildren` returns `0` after
both are resolved.


### Milestone 2 — The `Keiro.Workflow.Child` surface

Scope: the user-facing primitives `ChildId`/`ChildHandle`, `spawnChild`, `awaitChild`,
`cancelChild`, the `WorkflowChildCancelled` exception, and the `childResultStepName` helper.
At the end, the module compiles and the spawn/result step-name derivations are stable.

Create `keiro/src/Keiro/Workflow/Child.hs`. Define:

- A type alias / wrapper for the child id. The child's id is just a `WorkflowId`; introduce
  `childResultStepName :: WorkflowId -> Text` returning `childStepPrefix <> wid <> ":result"`
  (i.e. `child:<childId>:result`) and `childSpawnStepName :: WorkflowId -> Text` returning
  `childStepPrefix <> wid` (i.e. `child:<childId>`). These are the two reserved step names.
- `data ChildHandle a = ChildHandle { childName :: !WorkflowName, childWfId :: !WorkflowId }
  deriving stock (Eq, Show)`. The phantom-ish `a` records the child's result type so
  `awaitChild` can decode without an extra type annotation; carry it via a
  `Proxy`-free phantom (`ChildHandle` has a type parameter `a` but no field of type `a`).
- `data WorkflowChildCancelled = WorkflowChildCancelled WorkflowName WorkflowId
  deriving stock (Eq, Show); instance Exception WorkflowChildCancelled` (from
  `Control.Exception`, re-exported by `Effectful.Exception`).

- `spawnChild`:

  ```haskell
  spawnChild ::
    (Workflow :> es, Store :> es, ToJSON a, FromJSON a) =>
    WorkflowName ->          -- child's name (must be in the resume worker's registry)
    WorkflowId ->            -- child's id (names the child journal)
    Eff (Workflow : es) a -> -- the child workflow definition (recorded for the registry)
    Eff es (ChildHandle a)
  spawnChild childNm childWid _childDef = do
    (parentNm, parentWid) <- currentWorkflow
    let spawnStep = StepName (childSpawnStepName childWid)
    -- Journaled as a step in the PARENT journal: a replay short-circuits this body.
    _ <- step spawnStep $ do
           now <- liftIO getCurrentTime
           runTransaction $ registerChildTx (childRow parentNm parentWid childNm childWid now)
           -- seed the child's journal so it is a discoverable, unfinished workflow:
           seedChildJournal childNm childWid
           pure (toJSON ())   -- the step's recorded result is unit; the link lives in the table
    pure (ChildHandle childNm childWid)
  ```

  `seedChildJournal` writes the child's *started* marker so the resume worker discovers it.
  Per the Decision Log, a zero-step child must still be discoverable; the
  `keiro_workflow_children` row with `status = running` is the discovery seed (EP-43 drives
  child discovery off this table, unioned with EP-38's `findUnfinishedWorkflowIds`). If EP-38
  needs at least one journal event to consider a stream "started", `seedChildJournal` appends
  a no-op started marker via `appendJournalEntry` — but prefer the table-row seed and avoid a
  spurious journal event unless EP-38's discovery requires it. Record the final choice in the
  Decision Log when implementing.

  Note `_childDef` is accepted so the user passes the child body at the spawn site for
  ergonomics and so a future inline-run mode is possible, but in this plan the child is run by
  the resume worker from the registry, **not** from this argument; document that clearly in
  the Haddock (the registry, keyed by `WorkflowName`, is the source of truth for the child's
  definition).

- `awaitChild`:

  ```haskell
  awaitChild ::
    (Workflow :> es, Store :> es, FromJSON a) =>
    ChildHandle a ->
    Eff es a
  awaitChild (ChildHandle childNm childWid) = do
    (parentNm, parentWid) <- currentWorkflow
    let resultStep = StepName (childResultStepName childWid)
        arm = do
          -- idempotent re-assertion of the parent link + runnable child marker:
          mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
          case mrow of
            Just row | row ^. #status == ChildCancelled ->
              Effectful.Exception.throwIO (WorkflowChildCancelled childNm childWid)
            _ -> pure ()   -- the spawn already registered the row; nothing more to arm
    raw <- awaitStep resultStep arm           -- raw :: Value; suspends until journaled
    case fromJSON raw of
      -- a cancelled child writes a {"cancelled": true} sentinel as its result entry:
      _ | isCancelledSentinel raw -> Effectful.Exception.throwIO (WorkflowChildCancelled childNm childWid)
      Aeson.Success a -> pure a
      Aeson.Error e   -> error ("awaitChild: cannot decode child result: " <> e)
  ```

  The key facts: `awaitStep`'s `arm` is run only on the suspend (miss) path; on the hit path
  (the child's result already journaled into the parent) it decodes and returns the child's
  result without running `arm`. The arm both (a) throws `WorkflowChildCancelled` if the child
  was cancelled while the parent was suspended, and (b) is otherwise a no-op because the spawn
  already registered the link. `awaitStep` here is used at result type `Value` (then decoded
  with `fromJSON`) so the cancellation sentinel can be detected before decoding to `a`;
  alternatively decode to `Either CancelledSentinel a` — pick the cleaner shape when
  implementing and record it.

- `cancelChild`:

  ```haskell
  cancelChild ::
    (Store :> es) =>
    ChildHandle a ->
    Eff es Bool
  cancelChild (ChildHandle childNm childWid) = do
    cancelled <- runTransaction $ markChildCancelledTx (unWorkflowId childWid) (unWorkflowName childNm)
    when cancelled $ do
      now <- liftIO getCurrentTime
      -- 1) durable cancellation marker in the CHILD journal -> child short-circuits next resume:
      appendJournalEntry childNm childWid (WorkflowCancelled { recordedAt = now })
      -- 2) wake the parent's awaitChild with a cancellation sentinel result:
      mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
      forM_ mrow $ \row ->
        appendJournalEntry
          (WorkflowName (row ^. #parentName))
          (WorkflowId   (row ^. #parentId))
          (StepRecorded { stepName = row ^. #awaitStep
                        , result = object ["cancelled" .= True]
                        , recordedAt = now })
    pure cancelled
  ```

  `cancelChild` returns `True` only when it transitioned a `running` child to `cancelled`
  (the status guard in `markChildCancelledTx` makes a double-cancel a no-op). Both
  `appendJournalEntry` writes use deterministic ids and treat `DuplicateEvent` as success, so
  a retried cancel is safe.

Acceptance for M2: `cabal build keiro` succeeds with the new module wired into
`exposed-modules`; a pure unit test asserts `childResultStepName (WorkflowId "c1") ==
"child:c1:result"` and `childSpawnStepName (WorkflowId "c1") == "child:c1"`.


### Milestone 3 — EP-38 handler extensions (codec, completion hook, cancel short-circuit)

Scope: the additive changes to EP-38's `Keiro.Workflow`/`Keiro.Workflow.Types` this plan
owns. These are the cross-plan contracts in Surprises & Discoveries. At the end, a child that
completes propagates its result to the parent journal, and a child whose journal carries
`WorkflowCancelled` stops.

1. **Codec constructors.** In `keiro/src/Keiro/Workflow/Types.hs`, add to
   `WorkflowJournalEvent`:

   ```haskell
   data WorkflowJournalEvent
     = StepRecorded     { stepName :: !Text, result :: !Value, recordedAt :: !UTCTime }
     | WorkflowCompleted { recordedAt :: !UTCTime }
     | WorkflowCancelled { recordedAt :: !UTCTime }                       -- added by EP-43
     | WorkflowFailed    { reason :: !Text, recordedAt :: !UTCTime }      -- added by EP-43
     deriving stock (Eq, Show, Generic)
   ```

   Extend `workflowJournalCodec`'s `eventTypes` allow-list to include `"WorkflowCancelled"`
   and `"WorkflowFailed"`, project them in `eventType`, and add their `encode`/`decode`
   cases. Keep `schemaVersion = 1` (purely additive — a new wire tag; old journals never
   carry it, so no upcaster). Add a round-trip unit test for both new constructors through
   `encodeForAppendWithMetadata`/`decodeRecorded`.

2. **`WorkflowOutcome` `Cancelled` arm.** Add `Cancelled` to `WorkflowOutcome`
   (`Completed a | Suspended | Cancelled`). Update EP-38's `runWorkflow` handler's outcome
   mapping (see step 4).

3. **`runWorkflowWith` completion hook.** Add to `Keiro.Workflow`:

   ```haskell
   data RunWorkflowOptions es = RunWorkflowOptions
     { onComplete :: !(Value -> Eff es ())   -- fired with the encoded final result on Completed
     }

   defaultRunWorkflowOptions :: RunWorkflowOptions es
   defaultRunWorkflowOptions = RunWorkflowOptions { onComplete = const (pure ()) }

   runWorkflowWith ::
     (IOE :> es, Store :> es) =>
     RunWorkflowOptions es ->
     WorkflowName -> WorkflowId ->
     Eff (Workflow : es) a ->
     Eff es (WorkflowOutcome a)
   ```

   `runWorkflow = runWorkflowWith defaultRunWorkflowOptions`. The handler, on `Completed a`,
   after journaling `WorkflowCompleted`, calls `onComplete (toJSON a)` (the result encoded as
   it was already encoded for the journal — thread the encoded `Value` through so a
   non-`ToJSON` top-level result is not required; in practice a child workflow returns a
   `ToJSON`/`FromJSON a` so reuse the step-encoding path).

   The **child-completion hook** EP-43 supplies (used by the resume worker and the tests)
   looks up the parent link and propagates the result:

   ```haskell
   childCompletionHook ::
     (Store :> es) =>
     WorkflowName -> WorkflowId ->   -- the completing (child) workflow's name + id
     RunWorkflowOptions es
   childCompletionHook childNm childWid =
     RunWorkflowOptions
       { onComplete = \resultValue -> do
           now  <- liftIO getCurrentTime
           done <- runTransaction $
                     markChildResultTx (unWorkflowId childWid) (unWorkflowName childNm) resultValue now
           -- propagate to the PARENT journal so the parent's awaitChild resolves:
           mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
           forM_ mrow $ \row ->
             appendJournalEntry
               (WorkflowName (row ^. #parentName))
               (WorkflowId   (row ^. #parentId))
               (StepRecorded { stepName = row ^. #awaitStep, result = resultValue, recordedAt = now })
           pure ()
       }
   ```

   This lives in `Keiro.Workflow.Child` (it depends on the child schema), not in EP-38. The
   resume worker (EP-42), when it runs a workflow that has a `keiro_workflow_children` row as
   a *child*, runs it with `runWorkflowWith (childCompletionHook childNm childWid) …` instead
   of bare `runWorkflow`. EP-43 exports `childCompletionHook` and documents that the resume
   worker must select it for any workflow that is some parent's child. (A workflow that is not
   a child uses `defaultRunWorkflowOptions`.)

4. **Cancel short-circuit.** In EP-38's `runWorkflow`/`runWorkflowWith` handler, during the
   journal pre-load (the fold over `readStreamForwardStream` that builds the `WorkflowState`),
   detect a `WorkflowCancelled` event. If present, the handler must not run any further
   un-journaled step: return `Cancelled` immediately (do not journal `WorkflowCompleted`).
   Concretely: after pre-loading, if the journal contains `WorkflowCancelled`, short-circuit
   the interpreted action — the cleanest implementation is to set a `cancelled :: Bool` flag
   in the handler's per-run state and have the `Step` interpreter throw the same suspension
   sentinel EP-38 uses for `Suspended`, but tagged so the top-level catch maps it to
   `Cancelled`. (A `Step` on a cancelled workflow aborts rather than running its side effect.)
   A simpler equivalent: have `runWorkflowWith` check for `WorkflowCancelled` in the
   pre-loaded events *before* invoking the user action at all, and return `Cancelled`
   without running anything — this works because a cancelled child should make no further
   progress. Implement the pre-check form (simplest, and correct: a cancelled workflow runs
   nothing further).

Acceptance for M3: (a) the codec round-trip test for `WorkflowCancelled`/`WorkflowFailed` is
green; (b) a unit/DB test: append a `WorkflowCancelled` to a workflow's journal, then
`runWorkflowWith defaultRunWorkflowOptions` (or `runWorkflow`) on a two-step workflow returns
`Cancelled` and the journal gains **no** new `StepRecorded`/`WorkflowCompleted`; (c) a DB
test: `runWorkflowWith (childCompletionHook childNm childWid)` on a completing child that has
a parent link appends the `child:<childId>:result` `StepRecorded` to the parent's journal
carrying the child's result.


### Milestone 4 — End-to-end spawn → drive child → resume parent proof

Scope: the headline behavior, driven by the EP-42 resume worker (registry has both parent
and child) or, if EP-42 has not landed, by a manual `runWorkflow` drive loop. At the end, a
DB-backed test proves the full lifecycle.

In `keiro/test/Main.hs`, add `describe "Keiro.Workflow.Child" $ around (withFreshStore
fixture) $ do …` with a parent and a 2-step child:

```haskell
shipWorkflow :: (Workflow :> es) => Eff es Text
shipWorkflow = do
  a <- step (StepName "pack")  (pure ("packed" :: Text))
  b <- step (StepName "label") (pure (a <> "+labelled"))
  pure b

parentWorkflow :: (Workflow :> es, Store :> es) => Eff es Text
parentWorkflow = do
  h      <- spawnChild (WorkflowName "ship") (WorkflowId "ship-1") shipWorkflow
  result <- awaitChild h
  _      <- step (StepName "notify") (pure ("done:" <> result))
  pure ("done:" <> result)
```

The drive loop (the registry-plus-worker EP-42 automates; written by hand here so the test
runs whether or not EP-42 has landed). Each `Store` computation runs under
`Store.runStoreIO storeHandle $ ...`:

1. `runWorkflow (WorkflowName "parent") (WorkflowId "p1") parentWorkflow` → assert `Suspended`
   (the parent parked on `awaitChild`). Assert the parent journal `wf:parent-p1` has a
   `StepRecorded "child:ship-1"` (the spawn short-circuit record) and **no**
   `WorkflowCompleted`. Assert `lookupChild "ship-1" "ship"` returns a `running` row whose
   `parentId = "p1"`, `parentName = "parent"`, `awaitStep = "child:ship-1:result"`.
2. Drive the child to completion **with the child-completion hook**:
   `runWorkflowWith (childCompletionHook (WorkflowName "ship") (WorkflowId "ship-1"))
   (WorkflowName "ship") (WorkflowId "ship-1") shipWorkflow` → assert `Completed
   "packed+labelled"`. Assert the child journal `wf:ship-ship-1` has `StepRecorded "pack"`,
   `StepRecorded "label"`, and `WorkflowCompleted`. Assert the hook propagated the result:
   the parent journal now has a `StepRecorded "child:ship-1:result"` whose `result == toJSON
   ("packed+labelled" :: Text)`, and `lookupChild` shows `status = ChildCompleted`.
3. Re-invoke the parent: `runWorkflow (WorkflowName "parent") (WorkflowId "p1")
   parentWorkflow` → assert `Completed "done:packed+labelled"`. Assert the parent journal now
   also has `StepRecorded "notify"` and `WorkflowCompleted`.

Acceptance for M4: that test is green under `cabal test keiro`. This is the plan's central
observable outcome — a parent spawns a 2-step child, awaits its result, and runs a `notify`
step, with parent and child driven as separate durable workflows.


### Milestone 5 — Crash-survival and cancellation proofs

Scope: the two robustness behaviors. At the end, two more tests pin them down.

- **Crash-survival (no re-spawn).** Fresh `WorkflowId "p2"`. Run `parentWorkflow` once (it
  suspends after spawning, journaling `StepRecorded "child:ship-1b"` — use a distinct child
  id per test to avoid cross-test collisions, e.g. parametrise the child id). Record the
  child row's `created_at` and the count of `keiro_workflow_children` rows for this parent.
  Re-invoke `parentWorkflow` for `p2` **before** the child completes → assert it returns
  `Suspended` again, the parent journal still has exactly one `StepRecorded
  "child:<childId>"` (the deterministic step id made the re-append a no-op — the spawn body
  did **not** re-run), and `keiro_workflow_children` still has exactly one row for this child
  with the original `created_at` (the `ON CONFLICT DO NOTHING` register was a no-op). This
  proves the spawn short-circuits on replay and the child is not re-spawned.

- **Cancellation.** Fresh parent `WorkflowId "p3"` and child id `cancel-child`. Run
  `parentWorkflow` once (suspends, child `running`). Build the handle in the test (`ChildHandle
  (WorkflowName "ship") (WorkflowId "cancel-child")`) and call `cancelChild h` → assert it
  returns `True`. Assert: (i) the child journal `wf:ship-cancel-child` now has a
  `WorkflowCancelled` event; (ii) `lookupChild "cancel-child" "ship"` shows `status =
  ChildCancelled`; (iii) the parent journal has a `StepRecorded "child:cancel-child:result"`
  whose `result == object ["cancelled" .= True]`. Then:
  - Drive the child: `runWorkflow (WorkflowName "ship") (WorkflowId "cancel-child")
    shipWorkflow` → assert `Cancelled` and the child journal has **no** `StepRecorded "pack"`
    / `WorkflowCompleted` (the cancel short-circuit stopped it before its remaining steps).
  - Re-invoke the parent: `runWorkflow (WorkflowName "parent") (WorkflowId "p3")
    parentWorkflow` → assert it **throws** `WorkflowChildCancelled (WorkflowName "ship")
    (WorkflowId "cancel-child")` (exercise with `Test.Hspec.shouldThrow`, or catch via
    `Effectful.Exception.try` and assert the `Left`, matching the suite's existing exception
    tests). Assert the parent journal has no `WorkflowCompleted`.

Acceptance for M5: both tests green under `cabal test keiro`.


### Milestone 6 — Cabal wiring, contract recap, full-suite green

Scope: make the modules part of the package and document the contracts.

- Append `Keiro.Workflow.Child` and `Keiro.Workflow.Child.Schema` to the `exposed-modules`
  stanza of `keiro/keiro.cabal` (the `library` stanza's `exposed-modules` list, currently
  ending at `Keiro.Timer.Types` around lines 34–56). **Append your two lines only; do not
  reorder the existing list** — sibling plans append their own modules to the same stanza,
  and minimal diffs avoid merge churn (a MasterPlan integration point).
- If `keiro/src/Keiro.hs` (the umbrella module) re-exports the workflow surface (check
  whether EP-38 chose to re-export `Keiro.Workflow` through the umbrella, the way `Keiro`
  re-exports `Keiro.Timer`/`Keiro.Snapshot`), add a matching re-export of `Keiro.Workflow.Child`.
  If EP-38 chose not to re-export `Keiro.Workflow`, match that and do not re-export here.
- Add a Haddock block at the top of `Keiro.Workflow.Child` recapping for downstream plans:
  `ChildHandle`, `spawnChild`/`awaitChild`/`cancelChild`, the `WorkflowChildCancelled`
  exception, the `child:<id>` spawn step and `child:<id>:result` await step, the requirement
  that a child's `WorkflowName` be in the resume worker's registry, the `childCompletionHook`
  the resume worker must select for a child workflow, and that `countActiveChildren` (in
  `Keiro.Workflow.Child.Schema`) backs a potential `keiro.workflow.children.active` gauge for
  EP-44.

Acceptance for M6: full `cabal test keiro` green; `cabal build all` (including jitsurei)
green; the contract recap Haddock is present.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. The repo builds with
`cabal` under a Nix-provided GHC; use `cabal build keiro` and `cabal test keiro`.

```bash
# M1 — table + schema module
$EDITOR keiro-migrations/sql-migrations/2026-06-03-02-00-00-keiro-workflow-children.sql
$EDITOR keiro-migrations/src/Keiro/Migrations.hs   # touch a comment to force TH recompile (build gotcha)
$EDITOR keiro/src/Keiro/Workflow/Child/Schema.hs
$EDITOR keiro/keiro.cabal                           # append Keiro.Workflow.Child.Schema
cabal clean && cabal build keiro                    # clean is the reliable way past the embedDir gotcha

# M2 — the effect surface
$EDITOR keiro/src/Keiro/Workflow/Child.hs
$EDITOR keiro/keiro.cabal                           # append Keiro.Workflow.Child
cabal build keiro

# M3 — EP-38 handler extensions (codec + completion hook + cancel short-circuit)
$EDITOR keiro/src/Keiro/Workflow/Types.hs           # WorkflowCancelled/WorkflowFailed constructors + codec
$EDITOR keiro/src/Keiro/Workflow.hs                 # WorkflowOutcome Cancelled, runWorkflowWith, cancel short-circuit
cabal build keiro

# M4–M5 — tests
$EDITOR keiro/test/Main.hs                           # add the Keiro.Workflow.Child group
cabal test keiro

# M6 — full build
cabal build all
cabal test keiro
```

Expected `cabal test keiro` transcript once M4–M5 land (hspec, abbreviated):

```text
Keiro.Workflow.Child
  spawns a child, drives it, propagates its result, and resumes the parent to Completed
  does not re-spawn the child when the parent is re-invoked (crash survival)
  cancels a child: child journal gets WorkflowCancelled, child stops, awaitChild throws

Finished in N.NNNN seconds
NN examples, 0 failures
```

Capture the real transcript into the Validation section and Progress when the tests are
green.


## Validation and Acceptance

The plan is accepted when `cabal test keiro` is green and the child-workflow lifecycle is
observable exactly as below. Use the parent/child from M4.

- **Spawn + suspend (a).** The first `runWorkflow (WorkflowName "parent") (WorkflowId "p1")
  parentWorkflow` returns `Suspended`. The parent journal `wf:parent-p1` contains a
  `StepRecorded "child:ship-1"` and **no** `WorkflowCompleted`. `keiro_workflow_children` has
  one `running` row linking child `(ship-1, ship)` to parent `(p1, parent)` with
  `await_step = "child:ship-1:result"`.
- **Drive child + propagate (a).** Running the child with `runWorkflowWith
  (childCompletionHook …) …` returns `Completed "packed+labelled"`; the child journal
  `wf:ship-ship-1` has `StepRecorded "pack"`, `StepRecorded "label"`, and `WorkflowCompleted`;
  the parent journal gains a `StepRecorded "child:ship-1:result"` carrying
  `toJSON "packed+labelled"`; the child row is `completed`.
- **Resume parent (a).** The second `runWorkflow` of `parent`/`p1` returns
  `Completed "done:packed+labelled"`; the parent journal gains `StepRecorded "notify"` and
  `WorkflowCompleted`.
- **Crash survival (b).** Re-invoking the parent before the child completes returns
  `Suspended` again and leaves exactly **one** `StepRecorded "child:<id>"` in the parent
  journal and exactly one `keiro_workflow_children` row (unchanged `created_at`) — the spawn
  did not re-run.
- **Cancel (c).** `cancelChild h` returns `True`; the child journal gains `WorkflowCancelled`;
  `lookupChild` shows `status = ChildCancelled`. Driving the child returns `Cancelled` with no
  `StepRecorded "pack"`/`WorkflowCompleted` (the child stopped before its remaining steps).
  Re-invoking the parent throws `WorkflowChildCancelled (WorkflowName "ship") (WorkflowId
  "cancel-child")` and journals no `WorkflowCompleted`.

Each bullet is a concrete assertion in the `Keiro.Workflow.Child` test group. Capture the
green transcript here in the final revision as evidence.

If EP-42's resume worker has landed by implementation time, add a second variant of the (a)
test that drives the parent and child through the worker against a `WorkflowRegistry`
containing both `parent`/`shipWorkflow` and `ship`/`shipWorkflow`, asserting the same end
states without the manual drive loop — this proves the worker selects `childCompletionHook`
for the child.


## Idempotence and Recovery

Re-running any milestone is safe. Source edits are idempotent. The migration is additive and
guarded by codd's applied-migration ledger (re-applying is a no-op); the `CREATE TABLE IF NOT
EXISTS` and `CREATE INDEX IF NOT EXISTS` make a manual re-run harmless too.

The runtime operations are idempotent by construction:

- **Spawn** is a journaled `step`: a replayed parent short-circuits the spawn body (EP-38's
  named-step replay), and `registerChildTx`'s `ON CONFLICT (child_id, child_name) DO NOTHING`
  makes the link insert a no-op on every resume — so re-invoking the parent never re-spawns
  or duplicates the child.
- **Await** re-runs its `arm` on every resume until the child's result is journaled (EP-38's
  contract); the arm only reads the child row and throws on cancellation, so it is a pure
  re-assertion with no write to duplicate.
- **Child completion** goes through `markChildResultTx` (`WHERE status = 'running'` guard, so
  a double-complete is a no-op) and `appendJournalEntry` (deterministic event id, treats
  `DuplicateEvent` as success), so the resume worker driving the same child twice does not
  double-propagate.
- **Cancel** goes through `markChildCancelledTx` (`WHERE status = 'running'` guard) and
  deterministic journal appends, so a retried cancel is a no-op after the first.

Crash recovery between the two `appendJournalEntry` writes in `childCompletionHook` (child
journal `markChildResultTx` committed but the parent-journal propagation not yet appended):
the child row is `completed` but the parent journal lacks the `child:<id>:result` entry. The
resume worker re-running the child with the hook re-propagates (the hook always looks up the
parent link and appends, treating `DuplicateEvent` as success), so the parent is eventually
woken — self-healing on the next child drive. Recovery from the `embedDir` build gotcha
(cabal says "Up to date" but `keiro_workflow_children` is missing at runtime): run `cabal
clean` and rebuild. The suite-level template-database fixture gives each test a fresh clone,
so a test that leaves child rows behind needs no manual cleanup.


## Interfaces and Dependencies

Libraries/modules used and why: `effectful` (the `Store` effect and `Effectful.Exception`
for `WorkflowChildCancelled`); kiroku's `Store` effect re-exported by Keiro (the journal
appends via EP-38's `appendJournalEntry`, and `runTransaction` for the table writes);
`Keiro.Workflow` and `Keiro.Workflow.Types` (EP-38 — `step`, `awaitStep`,
`appendJournalEntry`, `runWorkflowWith`, `currentWorkflow`, `WorkflowName`/`WorkflowId`/
`StepName`, `WorkflowJournalEvent`, `childStepPrefix`, `workflowStreamName`,
`WorkflowOutcome`); `aeson` (`Value`, `ToJSON`, `FromJSON`, `toJSON`, `object`, `(.=)`,
`fromJSON` for child results and the cancellation sentinel); `hasql`/`hasql-th` (the schema
statements, matching `Keiro/Timer/Schema.hs`); `keiro-migrations` (the new SQL file); and
(soft) `Keiro.Workflow.Resume`'s `WorkflowRegistry` from EP-42 for the worker-driven test
variant.

Types, signatures, and modules that must exist at the end of this plan:

```haskell
-- Keiro.Workflow.Child.Schema
data ChildStatus = Running | ChildCompleted | ChildCancelled
data ChildRow = ChildRow
  { childId :: Text, childName :: Text, parentId :: Text, parentName :: Text
  , awaitStep :: Text, status :: ChildStatus, result :: Maybe Value
  , createdAt :: UTCTime, updatedAt :: UTCTime, completedAt :: Maybe UTCTime }
registerChildTx        :: ChildRow -> Tx.Transaction ()                         -- idempotent INSERT
lookupChild            :: (Store :> es) => Text -> Text -> Eff es (Maybe ChildRow)
lookupChildrenOfParent :: (Store :> es) => Text -> Text -> Eff es [ChildRow]
markChildResultTx      :: Text -> Text -> Value -> UTCTime -> Tx.Transaction Bool  -- running->completed
markChildCancelledTx   :: Text -> Text -> Tx.Transaction Bool                      -- running->cancelled
countActiveChildren    :: (Store :> es) => Eff es Int                              -- potential EP-44 gauge

-- Keiro.Workflow.Child
data ChildHandle a = ChildHandle { childName :: WorkflowName, childWfId :: WorkflowId }
data WorkflowChildCancelled = WorkflowChildCancelled WorkflowName WorkflowId       -- Exception
childResultStepName :: WorkflowId -> Text     -- "child:<id>:result"
childSpawnStepName  :: WorkflowId -> Text     -- "child:<id>"
spawnChild  :: (Workflow :> es, Store :> es, ToJSON a, FromJSON a) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (ChildHandle a)
awaitChild  :: (Workflow :> es, Store :> es, FromJSON a) => ChildHandle a -> Eff es a
cancelChild :: (Store :> es) => ChildHandle a -> Eff es Bool
childCompletionHook :: (Store :> es) => WorkflowName -> WorkflowId -> RunWorkflowOptions es  -- resume worker selects this for a child
```

Additive EP-38 extensions this plan owns (cross-plan contracts — see Surprises &
Discoveries and Decision Log):

```haskell
-- Keiro.Workflow.Types  (additive within schemaVersion 1)
data WorkflowJournalEvent = ... | WorkflowCancelled { recordedAt :: UTCTime }
                                | WorkflowFailed    { reason :: Text, recordedAt :: UTCTime }
data WorkflowOutcome a    = Completed a | Suspended | Cancelled    -- adds Cancelled

-- Keiro.Workflow  (additive)
data RunWorkflowOptions es = RunWorkflowOptions { onComplete :: Value -> Eff es () }
defaultRunWorkflowOptions  :: RunWorkflowOptions es
runWorkflowWith :: (IOE :> es, Store :> es) => RunWorkflowOptions es -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
-- runWorkflow = runWorkflowWith defaultRunWorkflowOptions
-- handler additionally short-circuits a run whose journal carries WorkflowCancelled, returning Cancelled
```

Downstream consumers and what they take from here:

- EP-42 (resume worker): must select `childCompletionHook childNm childWid` (not
  `defaultRunWorkflowOptions`) when it runs a workflow that is some parent's child, and must
  union `keiro_workflow_children` (status = running) into its discovery so a zero-step child
  is picked up. It also observes `WorkflowChildCancelled` / a `Cancelled` outcome as a parent
  failure to record.
- EP-44 (observability): `countActiveChildren` backs a potential
  `keiro.workflow.children.active` gauge; `spawnChild`/`awaitChild`/`cancelChild` are
  instrumentation points.
- EP-45 (worked example + docs): the child-workflow authoring surface and the operator
  guidance (a parent stuck awaiting a child is repaired by driving or cancelling the child).

Every commit while implementing this plan must carry all three git trailers:

```text
MasterPlan: docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md
ExecPlan: docs/plans/43-child-workflows-spawn-wait-and-cancel.md
Intention: intention_01kt6y4cb6eqz9mq48kf2xw8n1
```
