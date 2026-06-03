---
id: 40
slug: awakeables-and-external-completion
title: "Awakeables and external completion"
kind: exec-plan
created_at: 2026-06-03T14:39:45Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
master_plan: "docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md"
---

# Awakeables and external completion

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds **awakeables** to Keiro's v2 durable-execution runtime. An *awakeable* is a
durable promise: a workflow allocates an opaque id, hands that id to some external system
(a webhook endpoint, a human approver, an LLM tool call), pauses, and is resumed later when
that external system *signals* the id with a result. Nothing is polled; the workflow simply
suspends until the outside world calls back.

After this plan, a user can write a workflow like this:

```haskell
approvalFlow :: (Workflow :> es) => Eff es Text
approvalFlow = do
  (aid, await) <- awakeableNamed (StepName "approval")  -- allocate a durable promise
  -- (hand `aid` to a webhook handler / human / LLM tool here)
  decision <- await                                     -- SUSPEND until signalled
  step (StepName "use") (pure (decision <> "!"))        -- resume with the payload
```

and run it with `runWorkflow (WorkflowName "approval") wfId approvalFlow`. The **first**
`runWorkflow` returns `Suspended` (the workflow parked on `await`), and a row appears in a
new `keiro_awakeables` table with status `pending`. An external caller later runs
`signalAwakeable aid "ok"`. That call writes the payload into the table **and** appends a
`StepRecorded` event to the workflow's journal recording the resolved value. The **next**
`runWorkflow` of the same workflow id replays past the now-resolved `await`, runs the
remaining steps, and returns `Completed "ok!"`.

What a user gains that they could not do before: **human-in-the-loop and third-party
callback workflows without a polling loop or a bespoke "wait for event X into stream Y then
react in a process manager" hand-wiring.** The workflow author writes `await` as if it were
an ordinary blocking call; the runtime makes the suspend/resume durable.

This plan builds directly on top of EP-38 (the workflow journal and named-step replay core,
`docs/plans/38-workflow-journal-and-named-step-replay-core.md`), which is checked into this
repository. EP-38 owns the suspension machinery; this plan supplies only the *wake source*
(the awakeable's arming action and its external-completion path). The contracts this plan
consumes from EP-38 are recapped in detail in "Context and Orientation" so a novice does not
need to read EP-38 in full first, but EP-38 must be implemented and merged before this plan
can be built.

Term definitions (define-on-first-use, per the plan spec):

- *awakeable* — a durable promise an external system resolves. The workflow side is the
  pair `(AwakeableId, await)`; the external side is `signalAwakeable`.
- *signal* / *resolve* — to provide an awakeable's result from outside the workflow, by
  calling `signalAwakeable aid payload`. This completes the promise.
- *suspend* — a workflow run aborts partway through and `runWorkflow` returns `Suspended`,
  leaving the journal short of a terminal `WorkflowCompleted` event. EP-38 owns this.
- *resume* — a later `runWorkflow` of the same workflow id re-invokes the function from the
  top, short-circuiting every already-journaled step, until it either suspends again or
  completes. EP-42 (the resume worker) automates this; this plan triggers it manually in
  tests by calling `runWorkflow` a second time.
- *arming action* — the `Eff es ()` that EP-38's `awaitStep` runs *once* on the suspend path
  to set up the wake source. For an awakeable, arming means inserting a `pending` row into
  `keiro_awakeables`. EP-38 requires the arming action to be **idempotent** because every
  resume re-runs it until the step resolves.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-06-03) — `keiro_awakeables` table: migration SQL + `Keiro.Workflow.Awakeable.Schema` with
  the hasql statements and the `registerAwakeableTx` / `lookupAwakeable` /
  `completeAwakeableTx` / `cancelAwakeableTx` / `countPendingAwakeables` helpers. Migration
  applies under the test harness; the schema round-trip test inserts pending rows, completes
  one idempotently, cancels another, and asserts the pending count drops to 0.
- [x] M2 (2026-06-03) — `Keiro.Workflow.Awakeable`: `AwakeableId` (deterministic v5 UUID newtype),
  `awakeableNamed`, `awakeable` (ordinal convenience), `signalAwakeable`, `cancelAwakeable`,
  and the `WorkflowAwakeableCancelled` exception. Compiles; `deterministicAwakeableId` is
  stable across two calls and label-sensitive (proven by a pure test).
- [x] M3 (2026-06-03) — End-to-end suspend → signal → resume proof against ephemeral Postgres: first run
  `Suspended` + pending row + no journal completion; `signalAwakeable` flips the row and
  appends the `StepRecorded "awk:…"`; second run `Completed "ok!"`. Test green.
- [x] M4 (2026-06-03) — Idempotency + cancellation + crash-safe proofs: a second `signalAwakeable` returns `False` and
  does not change the recorded value; `cancelAwakeable` flips a pending row to `cancelled`
  and a subsequent run throws `WorkflowAwakeableCancelled`; a re-signal of a row completed
  out-of-band re-appends the missing journal entry. Tests green.
- [x] M5 (2026-06-03) — Cabal wiring (both new modules appended to `keiro/keiro.cabal`), contract-recap
  Haddock on `Keiro.Workflow.Awakeable`, full suite green via `cabal test keiro` (112
  examples, 0 failures) and `cabal build all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (implementation): **EP-38 already shipped every contract this plan proposed, so
  no EP-38 changes were needed.** `currentWorkflow` and `freshOrdinal` are on the `Workflow`
  effect (folded in during EP-38, per the MasterPlan's 2026-06-03 parallel-drafting Surprises
  entry), so `awakeableNamed`/`awakeable` consume them directly with the clean shape (1)
  signature. The cross-plan contracts below were therefore all adopted by EP-38 before this
  plan landed; none required a fallback.
- 2026-06-03 (implementation): **`signalAwakeable` carries `(IOE :> es, Store :> es)`, not
  `(Store :> es)` as this plan's "Context and Orientation" recap assumed.** The *shipped*
  `appendJournalEntry`/`appendJournalEntryReturningId` (EP-38) require `(IOE :> es, Store :>
  es)` — they pre-check `stepExists` and call `getCurrentTime`-style IO — so any external
  completion path that journals must also have `IOE`. This is free for real callers (a webhook
  handler, the resume worker) which all run with `IOE`. The plan's M2 signature block listed
  `signalAwakeable :: (Store :> es, ToJSON r) => …`; the real signature adds `IOE`. Recorded so
  EP-42/EP-44 thread `IOE` when they call `signalAwakeable`.
- 2026-06-03 (implementation): **The crash-safe re-append (M4) is the final shape, not the
  "simple form".** `signalAwakeable` decides what to journal as: the value just written when it
  performed the `pending → completed` transition, else the row's stored `payload` when the row
  is already `Completed` (re-append for a crash between the row update and the journal append),
  else nothing (`pending`-race or `cancelled`). The returned `Bool` is strictly "did *this*
  call perform the transition", so a `False` return can still have repaired the journal — its
  Haddock says so. `appendJournalEntry`'s own idempotence (deterministic id + `stepExists`
  pre-check) makes the re-append a no-op once the entry is present.
- 2026-06-03 (implementation): **Constructor-name clashes need care for any consumer importing
  both modules.** `AwakeableStatus` has `Pending`/`Completed`/`Cancelled`, which clash with
  `WorkflowOutcome (Completed, …)` and `TimerStatus (Cancelled, …)`. `Keiro.Workflow.Awakeable`
  avoids the clash by importing `Keiro.Workflow` *explicitly* (it never brings in the
  `WorkflowOutcome` constructors), so `Completed`/`Cancelled` resolve unambiguously to the
  schema's. Downstream test/consumer code (and EP-42/EP-43) should import
  `Keiro.Workflow.Awakeable.Schema` **qualified** when it also imports the workflow/timer
  surfaces. The test suite imports it as `Awk`.
- 2026-06-03 (implementation): **The codd `LaxCheck` schema-diff line is expected noise.** The
  test harness applies `allKeiroMigrations` with `VerifySchemas = LaxCheck` against an empty
  on-disk expected schema, so codd logs a large "DB and expected schemas do not match …" diff
  after applying `2026-06-03-01-00-00-keiro-awakeables.sql`. `LaxCheck` only logs; it does not
  fail the run — the suite is green (112 examples, 0 failures). Same behavior EP-38/EP-39 saw.

Cross-plan contracts proposed by this plan (all **adopted by EP-38 before this plan landed** —
no fallback was needed):

- **Shared `freshOrdinal :: (Workflow :> es) => Text -> Eff es Int` on EP-38.** Both this
  plan's `awakeable` ordinal convenience and EP-39's `sleep` (which has the identical need to
  derive a stable id without a user-supplied label) require a per-run monotonic counter keyed
  by a namespace string. Rather than each plan inventing its own `IORef`-backed counter inside
  its arming path, EP-38 should own a single `freshOrdinal` helper on the `Workflow` handler
  (the handler already holds per-run mutable state — the journal `IORef`), returning the next
  ordinal for a given prefix on each call within a run and resetting per `runWorkflow`
  invocation. This keeps one counter mechanism, not two divergent ones, and keeps ordinal
  derivation deterministic across replays (the counter advances in source order, which is the
  documented positional caveat). **Proposed contract for the MasterPlan/EP-38 to adopt.** If
  EP-38 has not shipped it when EP-40 lands, EP-40 ships only `awakeableNamed` and defers
  `awakeable` (see the M2 Decision Log note).

- **`currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)` on EP-38.**
  `awakeableNamed` must derive its deterministic `AwakeableId` from the running workflow's
  name and id without the user re-passing them. EP-38's handler already knows both (it built
  the journal stream name from them), so exposing a reader-style accessor on the `Workflow`
  effect is a small additive change. EP-39's `sleep` (deterministic timer id) and EP-43's
  child spawn (deterministic child id) need the same accessor, so this is a shared contract,
  not an awakeable-only one. **Proposed contract for the MasterPlan/EP-38 to adopt.**

- **`countPendingAwakeables` for EP-44.** This plan exposes `countPendingAwakeables` in
  `Keiro.Workflow.Awakeable.Schema` specifically so EP-44 can back the MasterPlan's named
  `keiro.workflow.awakeables.pending` gauge without re-deriving the query. Recorded so EP-44
  knows the seam exists.


## Decision Log

Record every decision made while working on the plan.

- Decision: Make `AwakeableId` a `newtype AwakeableId = AwakeableId UUID` whose value is a
  **deterministic** v5 UUID over `("keiro":"awakeable":workflowName:workflowId:label)`, not a
  random `UUID.nextRandom`.
  Rationale: A workflow is re-invoked from the top on every resume (EP-38's replay model). If
  `awakeableNamed (StepName "approval")` minted a *fresh random* id on each run, the resumed
  run would allocate a different id than the one already handed to the external system and
  already journaled, so the `await` hit path would never match. Determinism makes a
  re-invoked workflow allocate the *same* id, exactly the same concern EP-39's `sleep` has
  with its timer id and EP-38's `step` has with its journal event id
  (`deterministicCommandId` in `keiro/src/Keiro/ProcessManager.hs`). The id is derived from
  the stable user-supplied `StepName` label, so it is reproducible without any per-run state.
  Date: 2026-06-03.

- Decision: The stable primitive is `awakeableNamed :: StepName -> Workflow (AwakeableId,
  await)`, which takes a caller-supplied label. Also ship an `awakeable :: Workflow
  (AwakeableId, await)` ordinal convenience that derives the label from a per-run counter,
  with a documented caveat.
  Rationale: A user-supplied label is the only *fully* deterministic option — it survives
  code edits that insert/remove awakeables elsewhere in the workflow, the same robustness
  argument EP-38 makes for named steps over positional history
  (`docs/research/10-workflow-roadmap.md` §4: "named steps, not positional history"). The
  ordinal convenience matches the roadmap's bare `awakeable :: Workflow es (AwakeableId, Eff
  es a)` signature (§4) and is ergonomic, but a positional counter is fragile across edits;
  the Haddock for `awakeable` states the caveat and points users at `awakeableNamed`. The
  ordinal needs a per-run counter that EP-39 (sleep) needs identically — see the cross-plan
  contract in Surprises & Discoveries.
  Date: 2026-06-03.

- Decision: `signalAwakeable` does two writes — it updates the `keiro_awakeables` row to
  `completed`/`payload`/`completed_at` **and** appends a `StepRecorded` to the owner
  workflow's journal — and it uses EP-38's `appendJournalEntry` for the journal write rather
  than re-implementing the deterministic-id + duplicate-handling logic.
  Rationale: EP-38's integration contract (MasterPlan Integration Points, "The suspension
  primitive") says a wake source's external-completion path appends a `StepRecorded` carrying
  the awaited step name and the resolved value so the next run takes the `awaitStep` hit path.
  Routing through `appendJournalEntry` keeps the journal-write logic in one place and reuses
  the deterministic event id that makes a double-signal collapse to one journal row.
  Date: 2026-06-03.

- Decision: `signalAwakeable` is idempotent and returns `Bool`: `True` when it transitioned a
  `pending` row to `completed`, `False` when the row was already `completed` or `cancelled`
  (no-op, recorded value unchanged).
  Rationale: An at-least-once delivery webhook may signal twice; the second call must not
  clobber the first payload nor re-fire the journal append with a different value. The status
  guard (`WHERE status = 'pending'`) in the `UPDATE` makes the table write idempotent; the
  `Bool` return is computed from `rowsAffected` so the caller learns whether it was the one
  that resolved it. The journal append is only done when the row transition succeeds.
  Date: 2026-06-03.

- Decision: `cancelAwakeable` flips a `pending` row to `cancelled` and writes **no** journal
  entry; a workflow run that re-enters `await` on a cancelled awakeable throws
  `WorkflowAwakeableCancelled aid` (an exception carrying the id), rather than suspending
  again or completing.
  Rationale: A cancelled awakeable will never be signalled, so suspending forever is wrong and
  silently completing would fabricate a result. Throwing a typed exception lets the workflow
  author catch it (`Effectful.Exception.catch`) to run compensation, and lets EP-42's resume
  worker mark the workflow failed. The arming action (`registerAwakeableTx`, `ON CONFLICT DO
  NOTHING`) checks the existing row's status before suspending: if it is already `cancelled`,
  `awaitStep`'s arm step throws instead of suspending. We do not journal the cancellation as a
  `StepRecorded` because there is no result value to record; the table row is the source of
  truth and the await re-derives the cancelled state on each resume.
  Date: 2026-06-03.

- Decision: Fold the schema into a dedicated `Keiro.Workflow.Awakeable.Schema` module (not
  into `Keiro.Workflow.Awakeable`), mirroring the `Keiro.Timer` / `Keiro.Timer.Schema` split.
  Rationale: The MasterPlan's "Module layout" integration point names
  `Keiro.Workflow.Awakeable (+ its schema)`. Keeping the hasql statements in a `.Schema`
  sibling matches the existing convention (`Keiro/Timer/Schema.hs`,
  `Keiro/Outbox/Schema.hs`) and lets EP-44 import `countPendingAwakeables` from the schema
  module for its gauge without pulling in the effect surface.
  Date: 2026-06-03.


- Decision: `signalAwakeable`'s final type is `(IOE :> es, Store :> es, ToJSON r) =>
  AwakeableId -> r -> Eff es Bool`, and its journal decision is the crash-safe form: journal
  the just-written value on a successful transition, the stored payload on an
  already-`completed` row, nothing otherwise. The `Bool` return reports only the transition.
  Rationale: the shipped EP-38 `appendJournalEntry` requires `IOE` (see Surprises), and the
  M2 transaction-boundary note requires the re-append-from-stored-payload behavior so a crash
  between the row update and the journal append self-heals on a later signal. Implemented the
  refined version directly rather than shipping the simple form first.
  Date: 2026-06-03.

- Decision: Used shape (1) — the `currentWorkflow` reader accessor on the `Workflow` effect —
  for `awakeableNamed`, with no EP-38 change required (EP-38 had already shipped
  `currentWorkflow` and `freshOrdinal`). `awakeable`'s ordinal label is `ord:<n>` derived from
  `freshOrdinal awakeableStepPrefix`.
  Rationale: keeps `awakeableNamed :: StepName -> Eff es (AwakeableId, Eff es a)` clean, as the
  plan preferred; the fallback (explicit pass-through) was unnecessary.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-03): complete and green.** All five milestones landed; the full keiro
suite is green (112 examples, 0 failures) and `cabal build all` (including jitsurei) links.
The plan's purpose — human-in-the-loop / third-party-callback workflows without a polling loop
— is delivered: a workflow author writes `(aid, await) <- awakeableNamed (StepName "…")` then
`v <- await`, and the runtime makes the suspend (first `runWorkflow` → `Suspended` + a
`pending` row) and the external resume (`signalAwakeable aid payload` → row `completed` + a
`StepRecorded "awk:<uuid>"` → next `runWorkflow` → `Completed`) durable. Idempotent double
signals, crash-safe journal repair, and cancellation (`WorkflowAwakeableCancelled`) are all
proven.

**What went smoothly:** EP-38 had already absorbed every cross-plan contract this plan
proposed (`currentWorkflow`, `freshOrdinal`, the idempotent `appendJournalEntry`, the `awk:`
prefix), so the plan reduced to "supply the wake source": a `keiro_awakeables` table + schema
helpers, the allocation/await wrapper, and the external-completion path. No EP-38 edits were
needed.

**Deviations from the plan-as-written** (all in Surprises & Discoveries / Decision Log):
`signalAwakeable` gained an `IOE` constraint (the shipped `appendJournalEntry` needs it); the
crash-safe re-append was implemented as the final form from the start; and the ordinal label
is `ord:<n>`.

**Seams left for downstream plans:** `countPendingAwakeables` (EP-44 gauge);
`WorkflowAwakeableCancelled` for EP-42 to record as a failure and EP-43 to reuse the
await/signal mechanism; `lookupAwakeable` for EP-42 to classify an awakeable-blocked workflow.
No gaps or follow-ups outstanding.


## Context and Orientation

The working tree is at `/Users/shinzui/Keikaku/bokuno/keiro`. The library packages are
`keiro-core` (pure contracts), `keiro` (the runtime), `keiro-migrations` (embedded SQL),
`keiro-test-support` (PostgreSQL test fixtures), and `jitsurei` (worked examples). This plan
adds two new modules to the `keiro` package (`Keiro.Workflow.Awakeable` and
`Keiro.Workflow.Awakeable.Schema`) and one migration file to `keiro-migrations`.

This plan **hard-depends on EP-38**
(`docs/plans/38-workflow-journal-and-named-step-replay-core.md`), which is checked into the
repository. Read it if anything below is unclear, but the contracts you consume are recapped
here so you need not. EP-38 delivers the module `Keiro.Workflow` (and `Keiro.Workflow.Types`,
`Keiro.Workflow.Schema`) exposing exactly these (from EP-38's "Interfaces and Dependencies"):

```haskell
-- Keiro.Workflow.Types
newtype WorkflowName = WorkflowName Text
newtype WorkflowId   = WorkflowId Text
newtype StepName     = StepName Text
data WorkflowJournalEvent = StepRecorded { stepName :: Text, result :: Value, recordedAt :: UTCTime }
                          | WorkflowCompleted { recordedAt :: UTCTime }
data WorkflowOutcome a    = Completed a | Suspended      -- result of runWorkflow
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

The two EP-38 pieces this plan leans on hardest:

- **`awaitStep name arm`** — "look up `name` in the journal; if a `StepRecorded` with that
  `stepName` is present, decode its `result` and return it; otherwise run `arm` exactly once
  (idempotently) and **suspend** this run." `awakeable`'s `await` is exactly
  `awaitStep (StepName (awakeableStepPrefix <> idText)) (registerAwakeableTx … )`. EP-38
  guarantees `arm` is re-run on **every** resume until the step resolves, which is why
  `registerAwakeableTx` must be idempotent (an `INSERT … ON CONFLICT DO NOTHING`).

- **`appendJournalEntry name wid event`** — appends a `WorkflowJournalEvent` to the journal
  stream `wf:<name>-<id>` under a deterministic event id, treating kiroku's `DuplicateEvent`
  as success. `signalAwakeable` calls this with `StepRecorded { stepName =
  awakeableStepPrefix <> idText, result = toJSON payload, recordedAt = now }`. The next run
  then sees that `StepRecorded` and takes the `awaitStep` hit path.

The `awakeableStepPrefix = "awk:"` constant is EP-38's reserved prefix for awakeable
journal entries (MasterPlan Decision Log, 2026-06-03: "Journal `sleep`, `awakeable`, and
child handles as the same `StepRecorded` event with reserved step-name prefixes"). This plan
must use exactly that prefix so EP-38's replay loop stays uniform.

You will also use the **`Store` effect** (kiroku, re-exported through Keiro) and the
**deterministic-id pattern**. Read these before starting:

- **`Store` and transactions.** `runTransaction :: (Store :> es) => Tx.Transaction a -> Eff
  es a` runs one or more hasql statements that commit together; `appendToStream` /
  `readStreamForwardStream` append and read streams. `signalAwakeable` runs its table update
  and (separately) the journal append; the journal append goes through `appendJournalEntry`.
  See `keiro/src/Keiro/Timer/Schema.hs` for the exact `runTransaction $ Tx.statement args
  stmt` idiom.

- **The schema-module + migration convention.** Study `keiro/src/Keiro/Timer/Schema.hs` (the
  module this plan copies most directly) and `keiro/src/Keiro/Outbox/Schema.hs`: a
  `*/Schema.hs` module defines the row type, the `Store`-effect query helpers, and the hasql
  `Statement` values with their `Hasql.Encoders`/`Hasql.Decoders`. The `preparable` builder
  (from `Hasql.Statement`) takes a SQL string (triple-quoted), an encoder, and a decoder. Use
  `contrazip2`/`contrazip6` (from `Contravariant.Extras`) for multi-param encoders, exactly
  as `Keiro/Timer/Schema.hs` does.

- **The deterministic-id pattern** (`keiro/src/Keiro/ProcessManager.hs`,
  `deterministicCommandId`, ~lines 162–176). Copy its shape for `AwakeableId`:

  ```haskell
  import Data.UUID.V5 qualified as UUID.V5
  import Data.UUID qualified as UUID

  deterministicAwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
  deterministicAwakeableId (WorkflowName name) (WorkflowId wid) label =
    AwakeableId $
      UUID.V5.generateNamed UUID.V5.namespaceURL $
        fmap (fromIntegral . fromEnum) $
          Text.unpack $
            Text.intercalate ":" ["keiro", "awakeable", name, wid, label]
  ```

- **Migrations.** Timestamped SQL files live in `keiro-migrations/sql-migrations/`. The last
  workflow-core migration is EP-38's `2026-06-03-00-00-00-keiro-workflow-steps.sql`; this
  plan adds `2026-06-03-01-00-00-keiro-awakeables.sql` (strictly after it). The files are
  embedded by `embedDir "sql-migrations"` in `keiro-migrations/src/Keiro/Migrations.hs` and
  exposed via `allKeiroMigrations`.

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
  test clones it cheaply), and per-test you wrap a `describe` group with `around (withFreshStore
  fixture)` to get a fresh `Store.KirokuStore` handle (`Keiro.Test.Postgres`). Run effectful
  `Store` computations with `Store.runStoreIO storeHandle $ ...`. Follow how the existing
  `describe "Keiro.Timer" $ around (withFreshStore fixture)` group in `keiro/test/Main.hs`
  (~line 1012) acquires a store and exercises `scheduleTimerTx`/`runTimerWorker`.

There is **no** `Keiro.Workflow.Awakeable` module today — it is greenfield, layered on EP-38.


## Plan of Work

Five milestones. Each is independently verifiable; commit after each with the git trailers
named in "Interfaces and Dependencies".


### Milestone 1 — The `keiro_awakeables` table and schema module

Scope: the durable storage for awakeables and the hasql helpers that read and write it. At
the end, the table exists in a migrated database and a unit test can insert a pending row,
complete it, cancel another, and count the pending ones.

Add the migration
`keiro-migrations/sql-migrations/2026-06-03-01-00-00-keiro-awakeables.sql` (timestamp strictly
after EP-38's `2026-06-03-00-00-00-keiro-workflow-steps.sql`):

```sql
CREATE TABLE IF NOT EXISTS keiro_awakeables (
  awakeable_id        UUID PRIMARY KEY,
  owner_workflow_name TEXT        NOT NULL,
  owner_workflow_id   TEXT        NOT NULL,
  status              TEXT        NOT NULL DEFAULT 'pending',
  payload             JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at        TIMESTAMPTZ,
  CONSTRAINT keiro_awakeables_status_chk
    CHECK (status IN ('pending', 'completed', 'cancelled'))
);

-- Gauge support (EP-44 keiro.workflow.awakeables.pending) and operator triage.
CREATE INDEX IF NOT EXISTS keiro_awakeables_pending_idx
  ON keiro_awakeables (status)
  WHERE status = 'pending';

-- Find all awakeables owned by one workflow instance (operator repair, EP-42/EP-43).
CREATE INDEX IF NOT EXISTS keiro_awakeables_owner_idx
  ON keiro_awakeables (owner_workflow_name, owner_workflow_id);
```

The existing migration files (`keiro-migrations/sql-migrations/2026-05-17-01-00-00-keiro-outbox.sql`)
are bare SQL (no `-- codd:` header line); match that — codd treats a header-less file as a
single in-transaction migration, which is correct here (one `CREATE TABLE`).

Then create `keiro/src/Keiro/Workflow/Awakeable/Schema.hs`, copying the structure of
`keiro/src/Keiro/Timer/Schema.hs`. Define:

- `data AwakeableStatus = Pending | Completed | Cancelled deriving stock (Eq, Show, Generic)`
  with `statusToText`/`statusFromText` helpers (the decode fallback should be `Cancelled`, the
  same defensive choice `Keiro/Timer/Schema.hs` makes for an unrecognized status).
- `data AwakeableRow = AwakeableRow { awakeableId :: !UUID, ownerWorkflowName :: !Text,
  ownerWorkflowId :: !Text, status :: !AwakeableStatus, payload :: !(Maybe Value),
  createdAt :: !UTCTime, updatedAt :: !UTCTime, completedAt :: !(Maybe UTCTime) }
  deriving stock (Eq, Show, Generic)`.
- `registerAwakeableTx :: UUID -> Text -> Text -> Tx.Transaction ()` — `INSERT INTO
  keiro_awakeables (awakeable_id, owner_workflow_name, owner_workflow_id, status) VALUES
  ($1, $2, $3, 'pending') ON CONFLICT (awakeable_id) DO NOTHING`. **Idempotent** by the
  `ON CONFLICT DO NOTHING`, which is what EP-38's arm contract requires. Runs inside the
  caller's transaction (the arming action runs it via `runTransaction`).
- `lookupAwakeable :: (Store :> es) => UUID -> Eff es (Maybe AwakeableRow)` —
  `SELECT … FROM keiro_awakeables WHERE awakeable_id = $1` via `runTransaction $ Tx.statement
  uuid lookupAwakeableStmt`, decoding the full row (`D.rowMaybe`).
- `completeAwakeableTx :: UUID -> Value -> UTCTime -> Tx.Transaction Bool` — `UPDATE
  keiro_awakeables SET status = 'completed', payload = $2, completed_at = $3, updated_at =
  now() WHERE awakeable_id = $1 AND status = 'pending'`, returning `(> 0) <$> D.rowsAffected`.
  The `status = 'pending'` guard makes a double-signal a no-op (returns `False`). Runs inside
  the caller's transaction so the row update and the journal append in `signalAwakeable` can
  be reasoned about together (see M2's note on transaction boundaries).
- `cancelAwakeableTx :: UUID -> Tx.Transaction Bool` — `UPDATE keiro_awakeables SET status =
  'cancelled', updated_at = now() WHERE awakeable_id = $1 AND status = 'pending'`, returning
  `(> 0) <$> D.rowsAffected`. Only `pending` rows can be cancelled; a completed awakeable is
  left untouched (returns `False`).
- `countPendingAwakeables :: (Store :> es) => Eff es Int` — `SELECT count(*) FROM
  keiro_awakeables WHERE status = 'pending'`. **EP-44 (observability) consumes this** for its
  `keiro.workflow.awakeables.pending` gauge; expose it now even though this plan ships no
  gauge.

Use `preparable` for the `Statement` values and `Contravariant.Extras.contrazip*` for the
multi-parameter encoders, exactly as `Keiro/Timer/Schema.hs` does. The status column is read
back as text and mapped via `statusFromText`.

Acceptance for M1: after adding the migration, running `cabal clean && cabal build keiro`
(the `embedDir` gotcha), a new DB test group inserts a pending row, asserts `lookupAwakeable`
returns it with `status = Pending`, runs `completeAwakeableTx` and asserts it returns `True`
and a re-run returns `False`, inserts and `cancelAwakeableTx`s a second row, and asserts
`countPendingAwakeables` returns `0` after both are resolved.


### Milestone 2 — The `Keiro.Workflow.Awakeable` surface

Scope: the user-facing primitives `AwakeableId`, `awakeableNamed`, `awakeable`,
`signalAwakeable`, `cancelAwakeable`, and the `WorkflowAwakeableCancelled` exception. At the
end, the module compiles and the deterministic-id derivation is proven stable across two
calls.

Create `keiro/src/Keiro/Workflow/Awakeable.hs`. Define:

- `newtype AwakeableId = AwakeableId UUID deriving stock (Eq, Show, Generic)`, with
  `awakeableIdToUuid :: AwakeableId -> UUID` and `awakeableIdText :: AwakeableId -> Text`
  (`UUID.toText` of the inner value — used to build the `"awk:" <> idText` step name) and a
  `ToJSON`/`FromJSON` instance over its `UUID` (so a workflow can `step`-record the id if it
  wishes, and so a webhook payload can carry it).
- `deterministicAwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId` exactly as
  in "Context and Orientation".
- `data WorkflowAwakeableCancelled = WorkflowAwakeableCancelled AwakeableId
  deriving stock (Eq, Show); instance Exception WorkflowAwakeableCancelled` (from
  `Control.Exception` / re-exported by `Effectful.Exception`).
- The two allocation primitives. Both need the current `WorkflowName`/`WorkflowId` to derive
  the id and the `Store` to register the row. **Coordination point:** EP-38's `Workflow`
  effect must expose the running workflow's name and id to handler-side code so an awakeable
  can derive its deterministic id without the user re-passing them. Two acceptable shapes —
  pick whichever EP-38 actually provides and record it in the Decision Log:

  1. *Reader-style accessor on the `Workflow` effect* — EP-38 adds (or already has) an
     operation `currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)` that
     the handler answers from its closure. `awakeableNamed` calls it. **Preferred** — it keeps
     `awakeableNamed`'s signature clean (`StepName -> Eff es (AwakeableId, Eff es a)`).
  2. *Explicit pass-through* — `awakeableNamedFor :: WorkflowName -> WorkflowId -> StepName ->
     …` and the user threads the ids. Ugly; only a fallback if EP-38 exposes no accessor.

  If EP-38 does **not** expose `currentWorkflow`, this milestone adds it to EP-38's effect (a
  small, additive change EP-38's "Integration Points" explicitly invites: "If a downstream
  plan needs a handler capability EP-38 did not provide … it extends EP-38's handler and
  records the addition") and records the addition in this plan's Surprises & Discoveries and
  in the MasterPlan's Surprises & Discoveries. Assume shape (1) below.

  ```haskell
  awakeableNamed ::
    (Workflow :> es, Store :> es, FromJSON a) =>
    StepName ->
    Eff es (AwakeableId, Eff es a)
  awakeableNamed (StepName label) = do
    (name, wid) <- currentWorkflow
    let aid    = deterministicAwakeableId name wid label
        stepNm = StepName (awakeableStepPrefix <> awakeableIdText aid)
        arm    = registerAwakeableArm name wid aid     -- idempotent INSERT (see below)
        await  = awaitCancellable aid stepNm arm        -- awaitStep + cancel guard (see below)
    pure (aid, await)
  ```

  The arming action:

  ```haskell
  registerAwakeableArm :: (Store :> es) => WorkflowName -> WorkflowId -> AwakeableId -> Eff es ()
  registerAwakeableArm (WorkflowName name) (WorkflowId wid) aid =
    runTransaction $ registerAwakeableTx (awakeableIdToUuid aid) name wid
  ```

  The cancel-aware await wraps EP-38's `awaitStep`. Before suspending, it must notice a
  `cancelled` row and throw rather than suspend forever. The cleanest place to check is
  *inside* the arming action, because EP-38 runs `arm` on the suspend path on every resume:

  ```haskell
  awaitCancellable ::
    (Workflow :> es, Store :> es, FromJSON a) =>
    AwakeableId -> StepName -> Eff es () -> Eff es a
  awaitCancellable aid stepNm arm =
    awaitStep stepNm $ do
      existing <- lookupAwakeable (awakeableIdToUuid aid)
      case existing of
        Just row | row ^. #status == Cancelled ->
          Effectful.Exception.throwIO (WorkflowAwakeableCancelled aid)
        _ -> arm     -- idempotent register (no-op if the pending row already exists)
  ```

  Why this works: `awaitStep` only runs its `arm` argument on the **miss** path (the
  awakeable not yet signalled). On a miss it registers (or re-confirms) the pending row, then
  suspends — *unless* the row is already `cancelled`, in which case `arm` throws and the
  exception propagates out of `runWorkflow` instead of suspending. On the **hit** path
  (`signalAwakeable` already journaled the result) `awaitStep` decodes and returns the payload
  without running `arm` at all, so a signalled-then-cancelled race still returns the signalled
  value (signal wins, which is correct — a resolved promise cannot be un-resolved).

- The ordinal convenience:

  ```haskell
  awakeable ::
    (Workflow :> es, Store :> es, FromJSON a) =>
    Eff es (AwakeableId, Eff es a)
  awakeable = do
    n <- freshOrdinal awakeableStepPrefix          -- per-run counter; see cross-plan contract
    awakeableNamed (StepName ("ord:" <> Text.pack (show n)))
  ```

  Haddock for `awakeable` must carry the caveat: the ordinal label is **positional** — adding
  or removing an `awakeable` call earlier in the workflow shifts every later ordinal and so
  changes their derived ids, which corrupts an in-flight workflow exactly the way EP-38 warns
  positional history does. Prefer `awakeableNamed` for anything that may outlive a code edit.
  `freshOrdinal` is the shared per-run counter described in the cross-plan contract below; if
  EP-38 has not yet shipped it when this milestone lands, ship `awakeable` behind a local
  `IORef`-backed counter the handler threads, or defer `awakeable` to a follow-up and ship
  only `awakeableNamed` (record the choice in the Decision Log).

- The external-completion API:

  ```haskell
  signalAwakeable :: (Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
  signalAwakeable aid result = do
    mrow <- lookupAwakeable (awakeableIdToUuid aid)
    case mrow of
      Nothing  -> pure False                       -- unknown id: nothing to resolve
      Just row -> do
        now <- liftIO getCurrentTime
        completed <- runTransaction $
          completeAwakeableTx (awakeableIdToUuid aid) (toJSON result) now
        when completed $
          appendJournalEntry
            (WorkflowName (row ^. #ownerWorkflowName))
            (WorkflowId   (row ^. #ownerWorkflowId))
            (StepRecorded
               { stepName   = awakeableStepPrefix <> awakeableIdText aid
               , result     = toJSON result
               , recordedAt = now
               })
        pure completed
  ```

  Note on transaction boundaries: `completeAwakeableTx` commits the row update, then
  `appendJournalEntry` commits the journal append separately. If the process dies between the
  two, the row is `completed` but the journal lacks the `StepRecorded`; the next `runWorkflow`
  would suspend again (await miss) and re-register a no-op pending row. To make this
  self-healing, `signalAwakeable` is safe to call again (it sees `completed`, returns `False`,
  and skips the append) — so a *repair* path is needed: a re-signal of an already-completed
  awakeable whose journal entry is missing should re-append. The simplest robust rule:
  **always append the journal entry when the row is `completed` and the stored payload
  matches**, i.e. compute `completed` as "the row is now completed" (either we just completed
  it, or it was already completed with this payload), and append using the row's stored
  payload, treating `DuplicateEvent` as success (which `appendJournalEntry` already does). The
  return `Bool` stays "did *this* call perform the pending→completed transition". This keeps
  signalling idempotent *and* crash-safe. Implement this refined version; the snippet above is
  the simple form to start from in M3 and harden in M4. Record the final shape in the
  Decision Log.

- `cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool` — `runTransaction $
  cancelAwakeableTx (awakeableIdToUuid aid)`. Returns `True` if it transitioned a `pending`
  row to `cancelled`, `False` otherwise.

Acceptance for M2: `cabal build keiro` succeeds with the new module wired into
`exposed-modules`; a pure unit test asserts `deterministicAwakeableId (WorkflowName "w")
(WorkflowId "1") "approval"` equals itself across two calls and differs when the label
changes.


### Milestone 3 — End-to-end suspend → signal → resume proof

Scope: the headline behavior. No new production code beyond fixes uncovered by the test. At
the end, a DB-backed test proves the full lifecycle.

In `keiro/test/Main.hs`, add `describe "Keiro.Workflow.Awakeable" $ around (withFreshStore
fixture) $ do …` with the validation workflow:

```haskell
approvalFlow :: (Workflow :> es, Store :> es) => Eff es Text
approvalFlow = do
  (aid, await) <- awakeableNamed (StepName "approval")
  v <- await
  step (StepName "use") (pure (v <> "!"))
```

The test (run each `Store` computation with `Store.runStoreIO storeHandle $ ...`):

1. `runWorkflow (WorkflowName "approval") (WorkflowId "wf1") approvalFlow` and assert the
   result is `Suspended`.
2. Read the awakeable id back: it is deterministic, so recompute it in the test with
   `deterministicAwakeableId (WorkflowName "approval") (WorkflowId "wf1") "approval"`. Assert
   `lookupAwakeable` for that id returns a row with `status = Pending` and `payload = Nothing`.
3. Read the journal stream `wf:approval-wf1` and assert it contains **no** `WorkflowCompleted`
   and **no** `StepRecorded "awk:…"` yet (only at most nothing, since the first step is the
   await).
4. `signalAwakeable aid (Text "ok")` and assert it returns `True`. Then assert the row is now
   `status = Completed` with `payload = Just (toJSON ("ok" :: Text))`, and the journal now
   contains a `StepRecorded` whose `stepName == "awk:" <> awakeableIdText aid` and whose
   `result == toJSON ("ok" :: Text)`.
5. `runWorkflow (WorkflowName "approval") (WorkflowId "wf1") approvalFlow` a **second** time
   and assert the result is `Completed "ok!"`. Assert the journal now also contains a
   `WorkflowCompleted`.

Acceptance for M3: that test is green under `cabal test keiro`. This is the plan's central
observable outcome.


### Milestone 4 — Idempotency and cancellation proofs

Scope: the two robustness behaviors. At the end, two more tests pin them down.

- **Idempotent signal.** After M3's step 5, call `signalAwakeable aid (Text "later")` and
  assert it returns `False`. Re-read the row and assert `payload` is **still** `Just (toJSON
  "ok")` (unchanged). Re-read the journal and assert there is still exactly **one**
  `StepRecorded "awk:…"` with `result == toJSON "ok"` (the deterministic event id collapsed
  any re-append, and the status guard skipped the second update).

- **Cancellation.** Fresh workflow `WorkflowId "wf2"`: run `approvalFlow` once (it suspends
  and registers a pending awakeable). Recompute its id, call `cancelAwakeable aid`, and assert
  it returns `True` and the row is `status = Cancelled`. Run `approvalFlow` for `wf2` again
  and assert it throws `WorkflowAwakeableCancelled aid` — exercise with
  `Test.Hspec.shouldThrow` (or catch via `Effectful.Exception.try` and assert the `Left`),
  whichever the suite's existing exception tests use. Assert the journal for `wf2` still has
  **no** `WorkflowCompleted`.

Also add the crash-safe-signal regression (the M2 transaction-boundary concern): complete an
awakeable via `completeAwakeableTx` directly (simulating "row completed but journal append
not yet done"), confirm the journal lacks the `StepRecorded`, then call `signalAwakeable` with
the same payload and assert the journal **now** has the `StepRecorded` even though
`signalAwakeable` returned `False` (it re-appended the missing entry from the stored payload).

Acceptance for M4: both/all three tests green under `cabal test keiro`.


### Milestone 5 — Cabal wiring, contract recap, full-suite green

Scope: make the modules part of the package and document the contracts downstream plans
consume.

- Append `Keiro.Workflow.Awakeable` and `Keiro.Workflow.Awakeable.Schema` to the
  `exposed-modules` stanza of `keiro/keiro.cabal` (the list around lines 34–56). **Append your
  two lines only; do not reorder the existing list** — sibling plans (EP-39, EP-42, EP-43)
  append their own modules to the same stanza, and minimal diffs avoid merge churn (a
  MasterPlan integration point).
- If `keiro/src/Keiro.hs` (the umbrella module) re-exports the workflow surface (check whether
  it re-exports `Keiro.Timer` etc.), add a re-export of `Keiro.Workflow.Awakeable` matching
  that convention. If EP-38 chose not to re-export `Keiro.Workflow` through the umbrella,
  match its choice and do not re-export here.
- Add a Haddock block at the top of `Keiro.Workflow.Awakeable` recapping for downstream plans:
  `AwakeableId` (deterministic v5 id), `awakeableNamed`/`awakeable`/`signalAwakeable`/
  `cancelAwakeable`, the `WorkflowAwakeableCancelled` exception, that awakeables journal as
  `StepRecorded` under the `awk:` prefix, and that `countPendingAwakeables`
  (in `Keiro.Workflow.Awakeable.Schema`) backs EP-44's `keiro.workflow.awakeables.pending`
  gauge.

Acceptance for M5: full `cabal test keiro` green; `cabal build all` (including jitsurei)
green; the contract recap Haddock is present.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. The repo builds with
`cabal` under a Nix-provided GHC; use `cabal build keiro` and `cabal test keiro`.

```bash
# M1 — table + schema module
$EDITOR keiro-migrations/sql-migrations/2026-06-03-01-00-00-keiro-awakeables.sql
$EDITOR keiro-migrations/src/Keiro/Migrations.hs   # touch a comment to force TH recompile (build gotcha)
$EDITOR keiro/src/Keiro/Workflow/Awakeable/Schema.hs
$EDITOR keiro/keiro.cabal                           # append Keiro.Workflow.Awakeable.Schema
cabal clean && cabal build keiro                    # clean is the reliable way past the embedDir gotcha

# M2 — the effect surface
$EDITOR keiro/src/Keiro/Workflow/Awakeable.hs
$EDITOR keiro/keiro.cabal                           # append Keiro.Workflow.Awakeable
cabal build keiro

# M3–M4 — tests
$EDITOR keiro/test/Main.hs                           # add the Keiro.Workflow.Awakeable group
cabal test keiro

# M5 — full build
cabal build all
cabal test keiro
```

Expected `cabal test keiro` transcript once M3–M4 land (hspec, abbreviated):

```text
Keiro.Workflow.Awakeable
  suspends on an unsignalled awakeable and records a pending row
  resumes with the signalled payload after signalAwakeable
  is idempotent: a second signal returns False and does not change the value
  throws WorkflowAwakeableCancelled after cancelAwakeable
  re-appends a missing journal entry when re-signalled (crash-safe)

Finished in N.NNNN seconds
NN examples, 0 failures
```

Capture the real transcript into the Validation section and Progress when the tests are green.


## Validation and Acceptance

The plan is accepted when `cabal test keiro` is green and the awakeable lifecycle is
observable exactly as below. Use the validation workflow from M3
(`awakeableNamed (StepName "approval") >>= \(_, await) -> await >>= \v -> step (StepName
"use") (pure (v <> "!"))`).

- **Suspend on await.** The **first** `runWorkflow (WorkflowName "approval") (WorkflowId
  "wf1") approvalFlow` returns `Suspended`. The `keiro_awakeables` table has exactly one row
  for the deterministic id, `status = pending`, `payload = NULL`. The journal stream
  `wf:approval-wf1` has no `WorkflowCompleted` event.
- **Signal resolves.** `signalAwakeable aid "ok"` returns `True`. The row becomes
  `status = completed`, `payload = "ok"` (JSON), `completed_at` set. The journal gains a
  `StepRecorded` whose `stepName = "awk:<uuid>"` and `result = "ok"`.
- **Resume completes.** The **second** `runWorkflow` of the same `WorkflowId "wf1"` returns
  `Completed "ok!"` (the `await` hit path returned `"ok"`, the `"use"` step appended `"!"`),
  and the journal gains a `WorkflowCompleted`.
- **Idempotent signal.** A second `signalAwakeable aid "later"` returns `False`; the stored
  payload is still `"ok"`; the journal still has exactly one `StepRecorded "awk:<uuid>"` with
  result `"ok"`.
- **Cancellation.** For a fresh `WorkflowId "wf2"` suspended on its awakeable,
  `cancelAwakeable aid` returns `True` and the row becomes `status = cancelled`. The next
  `runWorkflow` of `wf2` throws `WorkflowAwakeableCancelled aid` and journals no
  `WorkflowCompleted`.
- **Pending gauge support.** `countPendingAwakeables` returns the number of `pending` rows
  (e.g. `1` while `wf1` is suspended, `0` after it is signalled). This is the seam EP-44 reads
  for `keiro.workflow.awakeables.pending`.

Each bullet is a concrete assertion in the `Keiro.Workflow.Awakeable` test group. Capture the
green transcript here in the final revision as evidence.


## Idempotence and Recovery

Re-running any milestone is safe. Source edits are idempotent. The migration is additive and
guarded by codd's applied-migration ledger (re-applying is a no-op); the `CREATE TABLE IF NOT
EXISTS` and `CREATE INDEX IF NOT EXISTS` make a manual re-run harmless too.

The runtime operations are idempotent by construction:

- `registerAwakeableTx` is `ON CONFLICT DO NOTHING`, so every resume re-arming the awakeable
  is a no-op — exactly what EP-38's "arm must be idempotent" contract requires.
- `signalAwakeable` guards its table update with `WHERE status = 'pending'`, so a second
  signal does not overwrite the first payload, and it re-appends the journal entry from the
  stored payload (treating kiroku's `DuplicateEvent` as success via `appendJournalEntry`), so
  a crash between the row update and the journal append self-heals on the next signal.
- `cancelAwakeable` guards with `WHERE status = 'pending'`, so cancelling an already-completed
  or already-cancelled awakeable is a no-op (`False`).

Recovery paths: if you add the migration but hit the `embedDir` build gotcha (cabal says "Up
to date" but `keiro_awakeables` is missing at runtime), run `cabal clean` and rebuild. If a
test leaves awakeable rows behind, the suite-level template-database fixture gives each test a
fresh clone, so there is nothing to clean up by hand. A workflow stuck `pending` forever
because the external system never called back is repaired operationally by `signalAwakeable`
(resolve it) or `cancelAwakeable` (abandon it); EP-45's operations guide documents this.


## Interfaces and Dependencies

Libraries/modules used and why: `effectful` (the `Store` effect and `Effectful.Exception`
for `WorkflowAwakeableCancelled`); kiroku's `Store` effect re-exported by Keiro (the journal
append via EP-38's `appendJournalEntry`, and `runTransaction` for the table writes);
`Keiro.Workflow` and `Keiro.Workflow.Types` (EP-38 — `awaitStep`, `appendJournalEntry`,
`WorkflowName`/`WorkflowId`/`StepName`, `WorkflowJournalEvent (StepRecorded)`,
`awakeableStepPrefix`, `workflowStreamName`, `currentWorkflow` if EP-38 exposes it);
`aeson` (`Value`, `ToJSON`, `FromJSON`, `toJSON` for payloads); `uuid`/`Data.UUID.V5`
(deterministic `AwakeableId`); `hasql`/`hasql-th` (the schema statements, matching
`Keiro/Timer/Schema.hs`); and `keiro-migrations` (the new SQL file).

Types, signatures, and modules that must exist at the end of this plan (the contracts EP-42,
EP-43, EP-44, and EP-45 consume — keep these stable):

```haskell
-- Keiro.Workflow.Awakeable.Schema
data AwakeableStatus = Pending | Completed | Cancelled
data AwakeableRow = AwakeableRow
  { awakeableId :: UUID, ownerWorkflowName :: Text, ownerWorkflowId :: Text
  , status :: AwakeableStatus, payload :: Maybe Value
  , createdAt :: UTCTime, updatedAt :: UTCTime, completedAt :: Maybe UTCTime }
registerAwakeableTx    :: UUID -> Text -> Text -> Tx.Transaction ()        -- idempotent INSERT
lookupAwakeable        :: (Store :> es) => UUID -> Eff es (Maybe AwakeableRow)
completeAwakeableTx    :: UUID -> Value -> UTCTime -> Tx.Transaction Bool   -- pending->completed
cancelAwakeableTx      :: UUID -> Tx.Transaction Bool                       -- pending->cancelled
countPendingAwakeables :: (Store :> es) => Eff es Int                       -- EP-44 gauge

-- Keiro.Workflow.Awakeable
newtype AwakeableId = AwakeableId UUID
deterministicAwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
data WorkflowAwakeableCancelled = WorkflowAwakeableCancelled AwakeableId   -- Exception
awakeableNamed  :: (Workflow :> es, Store :> es, FromJSON a) => StepName -> Eff es (AwakeableId, Eff es a)
awakeable       :: (Workflow :> es, Store :> es, FromJSON a) => Eff es (AwakeableId, Eff es a)
signalAwakeable :: (Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool
```

Downstream consumers and what they take from here:

- EP-42 (resume worker): the resume path drives a suspended-on-awakeable workflow's second
  `runWorkflow`; it observes `keiro_awakeables` (via `lookupAwakeable`) to classify a
  workflow as awakeable-blocked, and treats `WorkflowAwakeableCancelled` as a failure to
  record.
- EP-43 (child workflows): may model "wait for child" on the same await/signal mechanism;
  reads `keiro_awakeables` if it reuses it (an EP-43 decision).
- EP-44 (observability): `countPendingAwakeables` backs the
  `keiro.workflow.awakeables.pending` gauge; the `signalAwakeable`/`cancelAwakeable` call
  sites are instrumentation points.
- EP-45 (worked example + docs): the awakeable authoring surface and the operator repair
  guidance (signal/cancel a stuck pending awakeable).

Every commit while implementing this plan must carry all three git trailers:

```text
MasterPlan: docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md
ExecPlan: docs/plans/40-awakeables-and-external-completion.md
Intention: intention_01kt6y4cb6eqz9mq48kf2xw8n1
```
