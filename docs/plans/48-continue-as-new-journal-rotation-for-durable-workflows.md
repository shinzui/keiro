---
id: 48
slug: continue-as-new-journal-rotation-for-durable-workflows
title: "Continue-as-new journal rotation for durable workflows"
kind: exec-plan
created_at: 2026-06-03T21:28:37Z
intention: "intention_01kt7npy22e5tb3ybycsgeqdnm"
master_plan: "docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md"
---

# Continue-as-new journal rotation for durable workflows

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change a developer can write a durable workflow that runs an *unbounded*
number of steps — a poller that loops forever, a per-day rolling process, a
subscription-drain loop — without the workflow's append-only history growing without
limit. Today every step a workflow runs appends one event to a single kiroku stream
named `wf:<name>-<id>` (a "journal"), and every run or crash-recovery resume reads
that whole stream (or a snapshot plus the tail) to rebuild the workflow's accumulated
state. A workflow that runs a million steps has a million-event journal, and even with
snapshots the operational footprint (the stream, its index rows, its snapshot blobs)
grows forever. That is the wall §6.4 of `docs/research/10-workflow-roadmap.md` names:

> **Continue-as-new.** Snapshot the workflow's state, rotate its journal stream,
> resume against the rotated stream.

This plan delivers exactly that as a new primitive on the existing workflow effect.
When a workflow's body calls

```haskell
continueAsNew :: (Workflow :> es, Aeson.ToJSON s) => s -> Eff es a
```

the runtime (1) takes a snapshot of the workflow's current accumulated step-result
state using the snapshot machinery that already exists (`writeWorkflowSnapshot` /
`workflowStateCodec`, from `keiro/src/Keiro/Workflow/Snapshot.hs`), (2) appends a
terminal **rotation marker** to the current journal generation that closes it and
names the next generation, and (3) causes the *next* run of the same logical workflow
to start against a fresh, empty journal generation seeded only by that snapshot. The
caller's *logical* identity — the `(WorkflowName, WorkflowId)` pair, e.g.
`("daily-roller", "tenant-7")` — never changes; only the *physical* stream the journal
is written to rotates underneath it. The crash-recovery resume worker
(`Keiro.Workflow.Resume.resumeWorkflowsOnce`) and the unfinished-workflow discovery
query (`findUnfinishedWorkflowIds`) keep pointing at the *current* generation, so a
rotated workflow resumes transparently.

**The user-visible behavior you can see working.** A test workflow runs a long loop
(say 300 steps) and calls `continueAsNew` every 50 steps to fold its running total into
a fresh seed. After the run completes you can read the database and observe two things
at once: (a) each physical journal generation stream holds at most a bounded number
of events — never more than the per-generation cap `K` (here `K ≈ 52`: 50 work steps
plus the seed-restore step plus the rotation marker) — even though the workflow did
300 steps total across 6 generations; and (b) the workflow still returns the *correct*
final result (the same total a single non-rotating run would compute). Bounded journal
length plus correct result is the whole point: replay and hydration stay fast forever.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 (generation storage): added `2026-06-05-00-00-00-keiro-workflow-generation.sql`
  adding the `generation` column to `keiro_workflow_steps`, re-keying to
  `(workflow_id, workflow_name, generation, step_name)`, and widening the lookup index.
  `cabal test keiro-migrations-test` green (1 example, 0 failures) on a fresh apply
  (2026-06-03). Folded plan 47's `workflow_name` re-key in, since plan 47 had not landed.
- [x] Milestone 2 (journal event + codec): added the `WorkflowContinuedAsNew {generation, recordedAt}`
  constructor to `WorkflowJournalEvent` + `workflowJournalCodec` (additive, `schemaVersion = 1`,
  no upcaster), `continuedAsNewStepName = "__workflow_continued_as_new__"`, and the
  `loadJournal`/`journalKey`/`journalRow` arms. `cabal build keiro` green; codec round-trip
  example passes (2026-06-03).
- [x] Milestone 3 (generation-aware naming + load + record): added `workflowGenerationStreamName`
  (gen 0 keeps the legacy name), `currentGeneration` (MAX query), `generation` on
  `WorkflowStepRow`/`recordStepStmt` (4-col `ON CONFLICT`), name+gen on `stepExists`/`loadStepIndex`,
  and threaded `gen` through `runWorkflowWith`/`loadJournal`/`appendJournalTx`/`recordStep`/
  `appendCompletion`/`appendJournalEntryReturningId`/`deterministicJournalId`. `cabal build keiro`
  green; full `cabal test keiro` green — **134 examples, 0 failures**, proving generation 0 is
  behavior-preserving (2026-06-03).
- [x] Milestone 4 (`continueAsNew` primitive): added the `ContinueAsNew` effect op + handler arm
  (throws the `WorkflowRotate` sentinel), the `ContinuedAsNew` outcome, the top-level
  `rotateGeneration` (seed-step-on-next-gen-first ordering + advisory snapshot + terminal marker),
  the exported `continueAsNew`/`restoreSeed`, `continueSeedStepName`, and the `bumpForOutcome`
  arm in Resume. `cabal build keiro` green (2026-06-03).
- [x] Milestone 5 (resume + discovery point at current generation): rewrote
  `findUnfinishedWorkflowIdsStmt` as a `current_gen` CTE that scopes the terminal-marker
  check to `MAX(generation)` per logical id, so a rotated-away generation's marker never
  masks a still-running newer generation. The resume worker needed no change (re-invocation
  runs through `runWorkflowWith`, which resolves the current generation). `cabal test keiro`
  green — 134 examples, 0 failures (2026-06-03).
- [ ] Milestone 6 (acceptance test): add the bounded-journal rotation test to
  `keiro/test/Main.hs`; prove each generation ≤ K across N rotations and the correct final result.
- [ ] Milestone 7 (full green): `cabal build all`, `cabal test keiro`, `cabal test jitsurei-test`;
  reconcile the MasterPlan Integration Points note (the chosen generation scheme).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (M0 reconcile): **Plan 47 has NOT landed.** The as-shipped
  `keiro_workflow_steps` primary key is `(workflow_id, step_name)` (not the
  `(workflow_id, workflow_name, step_name)` plan 47 introduces), the lookup index is
  `(workflow_id)`, and `stepExists`/`loadStepIndex` take only a `WorkflowId` (no
  `WorkflowName`). Evidence:

  ```text
  $ grep -n "PRIMARY KEY" keiro-migrations/sql-migrations/2026-06-03-00-00-00-keiro-workflow-steps.sql
  17:  PRIMARY KEY (workflow_id, step_name)
  $ grep -n "stepExists ::\|loadStepIndex ::" keiro/src/Keiro/Workflow/Schema.hs
  76:loadStepIndex :: (Store :> es) => WorkflowId -> Eff es (Map Text Value)
  84:stepExists :: (Store :> es) => WorkflowId -> Text -> Eff es Bool
  ```

  Per the plan's own "Before starting, reconcile" note, this EP therefore folds plan
  47's name-awareness into its own edits: the M1 migration re-keys to
  `(workflow_id, workflow_name, generation, step_name)` (doing plan 47's job and
  EP-48's at once), and M3 gives `stepExists`/`loadStepIndex` an explicit
  `WorkflowName` parameter alongside the new `generation`. `stepExists`/`loadStepIndex`
  have no callers outside `Schema.hs`/`Workflow.hs`, so widening their arity is safe.
  The external append helpers (`appendJournalEntry` / `appendJournalEntryReturningId`,
  called by Sleep/Awakeable/Child wake sources) keep their logical `(name, wid)`
  signature and resolve the current generation internally.


## Decision Log

Record every decision made while working on the plan.

- Decision: Represent a generation as an **integer `generation` column on
  `keiro_workflow_steps`** plus a **physical journal stream `wf:<name>-<id>#<gen>`**,
  keeping the *logical* identity `(WorkflowName, WorkflowId)` stable.
  Rationale: The MasterPlan's "Journal generation naming and discovery" integration
  point names EP-48 as the owner of the scheme and lists exactly these two candidates
  ("a `wf:<name>-<id>#<gen>` physical stream with the logical id unchanged, or a
  generation column on `keiro_workflow_steps`"). I take **both, together**, because
  each alone is insufficient: a physical-stream suffix alone gives the journal a place
  to live but no queryable "what is the current generation?" without scanning stream
  names, which the index exists precisely to avoid; a generation column alone changes
  the index key but leaves the journal stream name ambiguous (two generations would
  share one kiroku stream and their step appends would collide on the deterministic
  event id). The column answers "which generation is current?" cheaply (it joins the
  `(workflow_id, workflow_name)` key plan 47 introduces), and the `#<gen>` suffix gives
  each generation its own physical stream so per-generation journals are genuinely
  bounded and independently snapshottable. The `#` separator is new and distinct from
  the structural `:` and `-` already reserved in `workflowStreamName`, so it cannot
  collide with an existing boundary.
  Date: 2026-06-03.

- Decision: Add a **terminal `WorkflowContinuedAsNew { generation, recordedAt }`
  constructor** to `WorkflowJournalEvent` (additive within `schemaVersion = 1`, no
  upcaster), where `generation` is the *next* generation this marker rotates into.
  Rationale: The MasterPlan fixes the convention: "EP-48 adds a terminal rotation
  marker (e.g. `WorkflowContinuedAsNew { generation, snapshotRef, recordedAt }`) that
  closes one journal generation and names the next; the resume worker and
  `findUnfinishedWorkflowIds` must treat it as terminal-for-this-generation-but-continued
  (distinct from `WorkflowCompleted`)." I keep the constructor name
  `WorkflowContinuedAsNew` verbatim. I drop the `snapshotRef` field: the snapshot is
  already addressable by `(streamId, version)` through the existing
  `keiro_snapshots` upsert (`writeWorkflowSnapshot`), and the *next* generation's
  physical stream is derived from `generation` plus the stable logical id, so the
  marker needs only the next-generation number and a timestamp. This mirrors EP-43's
  precedent (`WorkflowCancelled` / `WorkflowFailed` carry only what they must), keeping
  the codec minimal. The constructor is purely additive: old journals never carry the
  `"WorkflowContinuedAsNew"` tag, so no upcaster is needed.
  Date: 2026-06-03.

- Decision: The **current generation is the maximum `generation` value present in
  `keiro_workflow_steps` for `(workflow_id, workflow_name)`**, defaulting to `0` when
  the workflow has no rows yet.
  Rationale: A rotation marker for generation *g* commits in the same transaction that
  writes the next generation's seed step under generation *g* (see Milestone 4), so the
  highest generation with any index row is unambiguously the current one. Using `MAX`
  needs no extra "current generation" bookkeeping table and is index-supported by the
  `(workflow_id, workflow_name)` lookup index (plan 47). A workflow that never rotates
  stays at generation `0` and behaves byte-for-byte as it does today.
  Date: 2026-06-03.

- Decision: On entering a rotated generation, the runtime **journals the carried
  snapshot state as the new generation's seed via the snapshot table, not as replayed
  step rows**, and the new generation's journal starts empty (version 0).
  Rationale: `loadJournal` already seeds the in-memory step map from
  `loadWorkflowSnapshot` and then tail-replays. By writing the pre-rotation accumulated
  state as a snapshot *of the new generation's stream* at version 0, the next run hydrates
  from the snapshot and reads an empty tail — which is exactly "resume against the rotated
  stream" with a bounded (here zero-length) journal. This reuses EP-41's machinery
  end to end and introduces no new "seed step" event type, keeping the journal codec's
  growth to the single `WorkflowContinuedAsNew` tag.
  Date: 2026-06-03.

- Decision: `continueAsNew :: (Workflow :> es, Aeson.ToJSON s) => s -> Eff es a` is a
  **non-returning** operation from the workflow author's perspective (its result type is
  fully polymorphic `a`), implemented by throwing an internal sentinel that unwinds the
  run to `runWorkflowWith`, just as the suspension primitive does today.
  Rationale: The brief proposes this shape. A `forall a. … -> Eff es a` result is the
  honest type: control never returns to the caller within the *same* run after a
  rotation — the rotated continuation runs in the *next* run/resume. The existing
  `WorkflowSuspend` sentinel (caught in `runWorkflowWith`) is the proven pattern for
  unwinding a workflow run without returning; a parallel `WorkflowRotate` sentinel
  reuses it. The `s` the author passes is the seed for the next generation; the runtime
  encodes it with the workflow's own `Aeson` instances into the snapshot map under a
  reserved key, and the *next*-generation body restores it via a reserved seed step.
  Date: 2026-06-03.


- Decision (M4): `restoreSeed` is typed
  `(Workflow :> es, Aeson.ToJSON s, Aeson.FromJSON s) => s -> Eff es s`, adding the
  `Aeson.ToJSON s` constraint the Plan-of-Work signature omitted.
  Rationale: `restoreSeed def = step (StepName continueSeedStepName) (pure def)` and
  `step` itself requires `(Aeson.ToJSON a, Aeson.FromJSON a)` (it journals the result on
  a miss and decodes it on a hit). On the very first generation `restoreSeed` misses and
  must journal `toJSON def`, so `ToJSON s` is genuinely needed. The carried seed already
  has `ToJSON` (it is what the author passes to `continueAsNew`), so the extra constraint
  is free in practice. Date: 2026-06-03.

- Decision (M4): `rotateGeneration` writes the next generation's seed snapshot
  __unconditionally__ on rotation, ignoring the run's `snapshotPolicy`.
  Rationale: the seed step alone carries state forward correctly (the next run's
  `loadJournal` reads it and `restoreSeed` hits it); the snapshot is a pure
  optimization that lets the next generation hydrate in O(1) instead of re-reading the
  one seed event. Rotation is exactly the moment a fresh snapshot earns its keep
  (a new, otherwise-empty generation), and a snapshot is advisory — a miss only costs a
  single event read — so writing it always, rather than gating on a policy meant for the
  hot step path, is both safe and the point of the feature. Date: 2026-06-03.

- Decision (M4): the rotation appends the seed step on generation @g+1@ __before__ the
  terminal marker on generation @g@, each guarded by a `stepExists` check.
  Rationale: this is the crash-safe ordering the plan's Idempotence section prescribes.
  Once the seed step commits, `MAX(generation)` — and so `currentGeneration` — is
  @g+1@, so any re-run resolves to @g+1@, hydrates from the seed, and never re-enters
  generation @g@. A crash between the two appends therefore still converges to "continue
  from the seed", never re-running generation @g@'s work; the marker on @g@ is an audit
  record whose absence is harmless because discovery scopes to `MAX(generation)`.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this fully before editing; it assumes no prior knowledge of the repository.

**The repository.** Keiro is a Haskell event-sourcing framework built on three
libraries — `kiroku` (a PostgreSQL event store), `keiki` (event-sourcing
transducers/codecs), and `shibuya` (message-stream adapters) — using the `effectful`
effect system. The relevant Cabal packages are `keiro` (the runtime, including the
durable-workflow modules), `keiro-migrations` (embedded SQL migrations applied by
`codd`), `keiro-test-support` (test fixtures), and `jitsurei` (worked examples). All
Cabal commands in this plan run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`. The framework tables live in the PostgreSQL
schema named `kiroku` (the runtime's `Store` connects with `search_path = kiroku`).

**What a durable workflow is.** A *durable workflow* is an ordinary `effectful`
computation of type `Eff (Workflow : es) a`, written as a `do`-block, whose side
effects are recorded ("journaled") at *named checkpoints* called *steps*. A step
`step (StepName "charge") action` runs `action` once and appends a `StepRecorded`
event carrying the JSON-encoded result to the workflow's journal; on a later *replay*
(re-running the function from the top after a crash, a redeploy, or a resume) that same
`step` returns the recorded result *without* re-running `action`. The runtime is in
`keiro/src/Keiro/Workflow.hs` (the `Workflow` effect, `runWorkflow`,
`runWorkflowWith`, `loadJournal`, `appendJournalTx`, the interpreter `handler`) and
its leaf types are in `keiro/src/Keiro/Workflow/Types.hs`.

**The journal stream.** A workflow instance's journal is a kiroku *stream* (an
append-only, version-ordered sequence of events) named by `workflowStreamName` in
`keiro/src/Keiro/Workflow/Types.hs`:

```haskell
workflowStreamName :: WorkflowName -> WorkflowId -> StreamName
workflowStreamName (WorkflowName name) (WorkflowId wid) =
  StreamName ("wf:" <> name <> "-" <> wid)
```

So `("order-fulfillment", "ord-7")` journals to `wf:order-fulfillment-ord-7`. The `:`
and `-` are *structural* separators. This plan adds a third structural separator `#`
to distinguish *generations*.

**The journal events and their codec.** `WorkflowJournalEvent` (in
`Keiro.Workflow.Types`) is the sum of event types written to a journal. Today:

```haskell
data WorkflowJournalEvent
  = StepRecorded {stepName :: !Text, result :: !Aeson.Value, recordedAt :: !UTCTime}
  | WorkflowCompleted {recordedAt :: !UTCTime}
  | WorkflowCancelled {recordedAt :: !UTCTime}
  | WorkflowFailed {reason :: !Text, recordedAt :: !UTCTime}
```

`workflowJournalCodec :: Codec WorkflowJournalEvent` (same module) serializes these to
and from self-describing JSON objects carrying a `"kind"` discriminator. The `Codec`
type (in `keiro-core/src/Keiro/Codec.hs`) has fields `eventTypes` (the complete set of
type tags), `eventType`, `schemaVersion` (currently `1`), `encode`, `decode`, and
`upcasters`. The module's own Haddock fixes the *additive-constructor convention* this
plan must honor: a new event type is added by appending its tag to `eventTypes`, a
branch to `eventType`/`encode`/`decode`, **within `schemaVersion = 1`**, with **no
upcaster**, because old journals never carry the new tag. EP-43 added
`WorkflowCancelled` and `WorkflowFailed` exactly this way; EP-48 adds
`WorkflowContinuedAsNew` the same way.

**The accumulated state and snapshots.** As a workflow runs, the runtime holds a
`WorkflowState = Map Text Aeson.Value` (alias in `Keiro.Workflow.Types`): a map from
step name to that step's recorded JSON result. `keiro/src/Keiro/Workflow/Snapshot.hs`
persists that map so a long workflow need not re-read its whole journal:

- `workflowStateCodec :: StateCodec WorkflowState` encodes the map straight to JSON
  with a fixed shape-hash sentinel `"keiro.workflow.stepmap.v1"` and codec version `1`.
- `writeWorkflowSnapshot :: (Store :> es) => StreamId -> StreamVersion -> WorkflowState -> Eff es ()`
  upserts a `keiro_snapshots` row for a journal stream (keeping only the highest
  version per stream).
- `loadWorkflowSnapshot :: (Store :> es) => StreamName -> Eff es (Maybe (WorkflowState, StreamVersion))`
  resolves the stream id, reads the latest matching snapshot, and returns the seed map
  plus the version it was taken at — or `Nothing` (meaning "replay from version 0")
  when there is no stream, no matching snapshot, or an undecodable one. **Snapshots are
  advisory: a missing or stale snapshot only costs performance, never correctness.**

EP-48 reuses these three verbatim. The rotation seed is written with
`writeWorkflowSnapshot` against the *next generation's* physical stream id at version 0.

**How a run loads, runs, and appends.** `runWorkflowWith` (in `Keiro.Workflow`):

1. short-circuits to `Cancelled` if a `WorkflowCancelled` marker exists;
2. calls `loadJournal options name wid`, which seeds from `loadWorkflowSnapshot` and
   folds the journal stream's events after the snapshot version into the
   `Map Text Aeson.Value`;
3. interprets the `Workflow` effect with `handler journalRef ordinalRef`: a `Step` hit
   returns the journaled result; a `Step` miss runs the action, calls `recordStep`
   (which calls `appendJournalTx`), and updates the in-memory map; an `Await` hit
   returns the journaled result; an `Await` miss runs the arming action and throws the
   internal `WorkflowSuspend` sentinel, which `runWorkflowWith` catches and turns into
   `Suspended`;
4. on the computation returning, appends a `WorkflowCompleted` marker via
   `appendCompletion` and returns `Completed result`.

`appendJournalTx name wid event` is the core append: it encodes the event with
`workflowJournalCodec`, computes a *deterministic* event id from
`("keiro" : "workflow" : name : id : stepName)` (a v5 UUID, so a re-append of the same
step collapses to the same row), appends it to `workflowStreamName name wid`, and in
the *same transaction* upserts an index row via `recordStepTx`. This determinism is why
concurrent or retried writes are safe.

**The derived index `keiro_workflow_steps`.** The journal *stream* is the source of
truth for replay; `keiro_workflow_steps` (created by
`keiro-migrations/sql-migrations/2026-06-03-00-00-00-keiro-workflow-steps.sql`, queried
by `keiro/src/Keiro/Workflow/Schema.hs`) is a fast-lookup view kept in the same
transaction as each append. Its columns today are `workflow_id`, `workflow_name`,
`step_name`, `result`, `recorded_at`, with `PRIMARY KEY (workflow_id, step_name)`.
The Schema module exposes `recordStepTx` (upsert), `stepExists` (one-step existence
check), `loadStepIndex` (all steps for an instance), and `findUnfinishedWorkflowIds`
(every `(workflow_id, workflow_name)` with steps but no terminal marker — the seam the
resume worker drives).

**Plan 47 re-keys this index.** `docs/plans/47-key-workflow-step-index-and-discovery-on-workflow-id-and-name.md`
(a sibling fix the MasterPlan assumes lands) changes the primary key to
`(workflow_id, workflow_name, step_name)`, widens the lookup index to
`(workflow_id, workflow_name)`, and gives `stepExists`/`loadStepIndex` an explicit
`WorkflowName` parameter. **This plan composes with plan 47**: the `generation` column
joins that key, becoming `(workflow_id, workflow_name, generation, step_name)`. If plan
47 has not landed when you implement this, the migration here still works (it adds a
column and re-states the key including `workflow_name`); reconcile the exact key in
Milestone 1 against whichever of plan 47 / the base migration is present, and record
the reconciliation in Surprises.

**The crash-recovery resume worker.** `keiro/src/Keiro/Workflow/Resume.hs` provides
`resumeWorkflowsOnce :: (IOE :> es, Store :> es) => WorkflowResumeOptions -> WorkflowRegistry es -> Eff es ResumeSummary`.
On each pass it calls `findUnfinishedWorkflowIds` (and `findRunningChildIds`), looks
each discovered `(WorkflowName, WorkflowId)` up in a `WorkflowRegistry es =
Map WorkflowName (WorkflowDef es)` (the application's "how to rebuild this workflow's
body from its id" map), and re-invokes it through `runWorkflowWith`. A `WorkflowDef`
is `WorkflowDef { runDef :: WorkflowId -> Eff (Workflow : es) a }` (existential in `a`).
`ResumeSummary` records `discovered`, `resumed`, `completed`, `stillSuspended`,
`unknownName`. EP-48 must keep discovery and re-invocation pointed at the *current*
generation so a rotated workflow resumes transparently.

**The migration convention.** Each migration file under
`keiro-migrations/sql-migrations/` must begin with `SET search_path TO kiroku,
pg_catalog;` (the convention `docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md`
fixes; the workflow tables live in `kiroku`, and `search_path` is session-scoped).
Files are timestamped; the latest existing is
`2026-06-03-02-00-00-keiro-workflow-children.sql`, so this plan's migration is
timestamped after it. **Build gotcha (recorded in MasterPlan 5 and repeated by
MasterPlan 6's Integration Points):** adding a new `.sql` file under
`sql-migrations/` does *not* reliably retrigger compilation of `Keiro.Migrations`
(its `embedDir` Template-Haskell directory read is not tracked per-file by GHC's
recompilation checker). After adding a migration, edit a comment in
`keiro-migrations/src/Keiro/Migrations.hs` or run `cabal clean` before building.

**Terms defined.** *Generation* = one physical journal stream for a logical workflow
instance; rotation advances the generation number and starts a fresh stream. *Rotation
marker* = the terminal `WorkflowContinuedAsNew` event closing one generation and naming
the next. *Seed* = the application state the author passes to `continueAsNew`, carried
into the next generation via a snapshot so the rotated workflow starts from it.
*Logical identity* = the `(WorkflowName, WorkflowId)` pair the author and the registry
see, stable across rotations. *Physical stream* = `wf:<name>-<id>#<gen>`, the actual
kiroku stream a generation's events live on. *Current generation* = the highest
`generation` value present in the index for a logical identity (0 if none).


## Plan of Work

The work is seven milestones, each independently verifiable. Milestones 1–2 add the
storage and codec surface (a generation column; the rotation event). Milestone 3 makes
the runtime's naming, load, and append generation-aware while leaving generation `0`
behaving exactly as today. Milestone 4 adds the `continueAsNew` primitive and its
handler. Milestone 5 points discovery and resume at the current generation. Milestone 6
is the observable acceptance test. Milestone 7 is the full-repo green gate and the
MasterPlan reconciliation.

**Before starting, reconcile the as-shipped surface.** Plan 47 may already have
re-keyed `keiro_workflow_steps` and changed `stepExists`/`loadStepIndex` to take a
`WorkflowName`. Run, from the repository root:

```bash
ls keiro/src/Keiro/Workflow
grep -n "PRIMARY KEY\|workflow_name" keiro-migrations/sql-migrations/*workflow-steps*.sql
grep -n "stepExists ::\|loadStepIndex ::\|findUnfinishedWorkflowIdsStmt" keiro/src/Keiro/Workflow/Schema.hs
```

Note the current primary key and whether `stepExists`/`loadStepIndex` already carry a
`WorkflowName` parameter; the steps below assume plan 47's name-aware shape and add a
`generation` to it. If plan 47 has *not* landed, fold its name-awareness into your edits
here (the rotation correctness depends on identity being `(id, name, generation)`, not
`id` alone) and record it in Surprises.


### Milestone 1: the generation column (storage)

**Scope.** Add a migration that adds an integer `generation` column to
`keiro_workflow_steps` (default `0`, `NOT NULL`), folds it into the primary key, and
widens the lookup index so the current-generation query is index-supported. **At the
end of this milestone** a fresh database has a `keiro_workflow_steps.generation`
column, every existing query still works (the default `0` makes pre-rotation rows
generation-0), and `cabal test keiro-migrations-test` is green.

Create `keiro-migrations/sql-migrations/2026-06-05-00-00-00-keiro-workflow-generation.sql`:

```sql
-- Resolve unqualified names into the Kiroku schema (search_path is session-scoped;
-- see docs/plans/46-...). The kiroku schema and keiro_workflow_steps already exist.
SET search_path TO kiroku, pg_catalog;

-- Continue-as-new (EP-48) rotates a long-running workflow onto a fresh journal
-- *generation* so its history stays bounded. The logical identity
-- (workflow_id, workflow_name) is stable; the generation discriminates the
-- physical journal stream wf:<name>-<id>#<gen>. Generation 0 is the pre-rotation
-- default, so every existing row and every never-rotating workflow is unaffected.
ALTER TABLE keiro_workflow_steps
  ADD COLUMN IF NOT EXISTS generation integer NOT NULL DEFAULT 0;

-- Fold the generation into the key so two generations of the same logical
-- workflow do not collide on a reserved step name (e.g. the terminal markers).
-- Adding a column to the key is a strict relaxation: no existing row can violate
-- the wider key. Assumes plan 47 has already keyed on (workflow_id, workflow_name,
-- step_name); reconcile the constraint name with \d kiroku.keiro_workflow_steps.
ALTER TABLE keiro_workflow_steps DROP CONSTRAINT keiro_workflow_steps_pkey;
ALTER TABLE keiro_workflow_steps
  ADD PRIMARY KEY (workflow_id, workflow_name, generation, step_name);

-- Support the current-generation lookup (MAX(generation) per id+name).
DROP INDEX IF EXISTS keiro_workflow_steps_workflow_idx;
CREATE INDEX IF NOT EXISTS keiro_workflow_steps_workflow_idx
  ON keiro_workflow_steps (workflow_id, workflow_name, generation);
```

If plan 47 has *not* landed, the current key is `(workflow_id, step_name)`; in that
case the `ADD PRIMARY KEY` above is still correct (it includes `workflow_name`, doing
plan 47's job and EP-48's at once), and you must also fold `workflow_name` and
`generation` into `recordStepStmt`'s `ON CONFLICT`, `stepExists`, `loadStepIndex`, and
`findUnfinishedWorkflowIdsStmt` in Milestone 3 — exactly the edits plan 47 specifies,
plus the generation. Confirm the existing primary-key constraint name with
`\d kiroku.keiro_workflow_steps` before relying on `keiro_workflow_steps_pkey`.

After adding the file, defeat the `embedDir` recompile gotcha: edit a comment in
`keiro-migrations/src/Keiro/Migrations.hs` (or `cabal clean`) so the embedded set
refreshes. Acceptance: `cabal test keiro-migrations-test` passes on a fresh apply, and
`\d kiroku.keiro_workflow_steps` shows the `generation` column and the four-column
primary key.


### Milestone 2: the rotation journal event + codec (additive)

**Scope.** Add the `WorkflowContinuedAsNew` constructor to `WorkflowJournalEvent` and
to `workflowJournalCodec`, additively within `schemaVersion = 1`, with no upcaster.
Add a reserved step name for the marker's index row. **At the end of this milestone**
`cabal build keiro` is green and a round-trip test (`decode . encode == id`) for the
new constructor passes.

Edit `keiro/src/Keiro/Workflow/Types.hs`:

1. Add the constructor to the sum:

   ```haskell
   data WorkflowJournalEvent
     = StepRecorded {stepName :: !Text, result :: !Aeson.Value, recordedAt :: !UTCTime}
     | WorkflowCompleted {recordedAt :: !UTCTime}
     | WorkflowCancelled {recordedAt :: !UTCTime}
     | WorkflowFailed {reason :: !Text, recordedAt :: !UTCTime}
     | WorkflowContinuedAsNew {generation :: !Int, recordedAt :: !UTCTime}
       -- ^ Terminal-for-this-generation rotation marker (EP-48). 'generation'
       --   is the NEXT generation this rotation opens. Additive within
       --   schemaVersion 1: old journals never carry the "WorkflowContinuedAsNew"
       --   tag, so no upcaster is needed.
   ```

2. Extend `workflowJournalCodec`: append `"WorkflowContinuedAsNew"` to `eventTypes`,
   add the `WorkflowContinuedAsNew{} -> "WorkflowContinuedAsNew"` branch to
   `eventType`, an `encode` branch
   (`"kind"`, `"generation"`, `"recordedAt"`), and a `decode` branch
   (`WorkflowContinuedAsNew <$> o .: "generation" <*> o .: "recordedAt"`).

3. Add a reserved step name (next to `completedStepName` / `cancelledStepName` /
   `failedStepName`) for the marker's index row and export it:

   ```haskell
   continuedAsNewStepName :: Text
   continuedAsNewStepName = "__workflow_continued_as_new__"
   ```

   This is the index row written when a generation rotates; it makes that generation
   terminal *for itself* in the index (a rotated-away generation has its marker row and
   so drops out of any per-generation "unfinished" check), while the *current*
   generation is the one with no such row and no `WorkflowCompleted` row. Add it to the
   module export list.

Because `loadJournal` folds journal events into the step map, add the new constructor
to its `case`:

```haskell
Right (WorkflowContinuedAsNew _ _) -> pure journal   -- contributes nothing to the map
```

(in `keiro/src/Keiro/Workflow.hs`, the `accumulate` helper inside `loadJournal`). A
rotation marker carries no step result, so it adds nothing to the folded state — the
same treatment `WorkflowCompleted` / `WorkflowCancelled` / `WorkflowFailed` already get.

Acceptance: `cabal build keiro` green; a new HSpec example in `keiro/test/Main.hs`'s
`describe "Keiro.Workflow.Snapshot codec"` (or a `describe "Keiro.Workflow.Types
codec"`) asserts `(workflowJournalCodec ^. #decode) ((workflowJournalCodec ^. #encode)
(WorkflowContinuedAsNew 3 t)) == Right (WorkflowContinuedAsNew 3 t)` for a fixed `t`.


### Milestone 3: generation-aware naming, load, and append

**Scope.** Teach the runtime to address a *physical* generation stream while keeping
the *logical* identity stable, default everything to generation `0`, and add the
current-generation lookup. **At the end of this milestone** `cabal build keiro` is
green and a default (never-rotating) workflow still writes to `wf:<name>-<id>#0` (or,
to avoid churn on existing journals, to `wf:<name>-<id>` for generation 0 — see the
naming note) and behaves exactly as before.

Add to `keiro/src/Keiro/Workflow/Types.hs` a generation-aware physical stream name and
export it:

```haskell
-- | The PHYSICAL journal stream for a given generation of a logical workflow.
-- Generation 0 keeps the legacy name 'wf:<name>-<id>' (so already-running,
-- never-rotated workflows are byte-for-byte unchanged); generation g > 0 adds the
-- '#<g>' suffix. The '#' is a new structural separator, distinct from ':' and '-'.
workflowGenerationStreamName :: WorkflowName -> WorkflowId -> Int -> StreamName
workflowGenerationStreamName name wid gen
  | gen <= 0  = workflowStreamName name wid
  | otherwise = let StreamName base = workflowStreamName name wid
                 in StreamName (base <> "#" <> Text.pack (show gen))
```

Keeping generation 0 on the legacy name is deliberate: it makes this whole feature a
strict superset of today's behavior, so no existing journal stream is renamed and the
EP-45 worked example, the existing tests, and any deployed workflow keep working with
zero data migration. Record this choice in the Decision Log if you keep it (recommended).

Add the current-generation lookup to `keiro/src/Keiro/Workflow/Schema.hs`:

```haskell
-- | The current (highest) generation recorded for a logical workflow, or 0 if
-- it has no step rows yet. Index-supported by the (workflow_id, workflow_name,
-- generation) lookup index.
currentGeneration :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es Int
```

backed by `SELECT COALESCE(MAX(generation), 0) FROM keiro_workflow_steps WHERE
workflow_id = $1 AND workflow_name = $2`. Export it from `Keiro.Workflow.Schema` and
re-export it from `Keiro.Workflow`.

Thread the generation through the index writes and existence checks. `WorkflowStepRow`
gains a `generation :: !Int` field; `recordStepStmt` inserts it and its `ON CONFLICT`
target becomes `(workflow_id, workflow_name, generation, step_name)`; `stepExists`
and `loadStepIndex` gain a generation parameter (or, simpler and recommended, take the
generation alongside the existing `WorkflowName`/`WorkflowId`):

```haskell
stepExists :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Text -> Eff es Bool
loadStepIndex :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Eff es (Map Text Value)
```

In `keiro/src/Keiro/Workflow.hs`, `runWorkflowWith` resolves the current generation
once at the top (`gen <- currentGeneration name wid`) and threads it into: the journal
stream name everywhere `workflowStreamName name wid` appears (replace with
`workflowGenerationStreamName name wid gen`), `loadJournal` (which now reads the
generation stream and the generation's snapshot), `appendJournalTx` /
`appendCompletion` / `recordStep` (so the index row and the deterministic event id are
namespaced by generation — fold `gen` into `deterministicJournalId` so two generations'
same-named steps get distinct ids), and the cancellation short-circuit (`stepExists
name wid gen cancelledStepName`). Keep all the existing call shapes; you are only
adding a generation argument that defaults to the resolved current generation.

`deterministicJournalId` must include the generation so a step named `"s1"` in
generation 0 and generation 1 produce *different* kiroku event ids (they live on
different physical streams but the id is global). Change its intercalation to
`["keiro", "workflow", name, wid, Text.pack (show gen), key]` and pass `gen` from the
single call site (`appendJournalTx`).

Acceptance: `cabal build keiro` green; the existing
`describe "Keiro.Workflow"` / `"Keiro.Workflow snapshots"` / `"Keiro.Workflow.Resume"`
suites still pass unchanged (`cabal test keiro`), proving generation 0 is behavior-
preserving. Update any test/call site that constructed a `WorkflowStepRow` or called
`stepExists`/`loadStepIndex` to the new arities.


### Milestone 4: the `continueAsNew` primitive

**Scope.** Add the `ContinueAsNew` operation to the `Workflow` effect, its handler arm,
and the exported `continueAsNew` function. **At the end of this milestone** a workflow
body can call `continueAsNew seed`, and a run that reaches it (a) snapshots the next
generation's seed, (b) journals a `WorkflowContinuedAsNew` marker on the *current*
generation, and (c) returns from `runWorkflowWith` with a new outcome
`ContinuedAsNew` (see below) so the caller/resume worker knows to re-invoke.

Add a new constructor to `WorkflowOutcome` in `keiro/src/Keiro/Workflow/Types.hs`:

```haskell
data WorkflowOutcome a
  = Completed a
  | Suspended
  | Cancelled
  | ContinuedAsNew     -- ^ EP-48: the run rotated onto a fresh generation; a
                       --   subsequent run/resume of the same logical id continues
                       --   from the carried seed. Distinct from 'Suspended' (a wake
                       --   source is pending) and 'Completed' (the workflow is done).
  deriving stock (Eq, Show, Functor)
```

Add the effect operation in `keiro/src/Keiro/Workflow.hs`:

```haskell
data Workflow :: Effect where
  ...
  -- | Snapshot the carried seed, rotate onto a fresh journal generation, and
  -- unwind this run; the next run/resume continues from the seed. Never returns
  -- to the caller within this run (result type is fully polymorphic).
  ContinueAsNew :: (Aeson.ToJSON s) => s -> Workflow m a
```

and the public function (export it from `Keiro.Workflow`):

```haskell
continueAsNew :: (Workflow :> es, Aeson.ToJSON s) => s -> Eff es a
continueAsNew seed = send (ContinueAsNew seed)
```

Add an internal sentinel mirroring `WorkflowSuspend`:

```haskell
data WorkflowRotate = WorkflowRotate !Aeson.Value
  deriving stock (Show)
instance Exception WorkflowRotate
```

Handler arm (in `handler`):

```haskell
ContinueAsNew seed -> throwIO (WorkflowRotate (Aeson.toJSON seed))
```

Catch it in `runWorkflowWith` alongside the suspend catch. The proven pattern today is:

```haskell
outcome <- (Completed <$> runHandler)
  `catch` (\WorkflowSuspend -> pure Suspended)
```

Extend it to also catch `WorkflowRotate`:

```haskell
outcome <- (Completed <$> runHandler)
  `catch` (\WorkflowSuspend -> pure Suspended)
  `catch` (\(WorkflowRotate seedJson) -> rotate seedJson)
```

where `rotate seedJson` does the rotation **idempotently** in this order:

1. Compute `nextGen = gen + 1` and the next physical stream
   `workflowGenerationStreamName name wid nextGen`.
2. Build the next generation's seed map: a single reserved entry mapping a reserved
   *seed step name* to `seedJson`, i.e. `Map.singleton continueSeedStepName seedJson`
   (add `continueSeedStepName = "__workflow_seed__"` to `Keiro.Workflow.Types` and
   export it). The next generation's body restores the seed by reading this step.
3. Resolve the next generation's stream id (it has no events yet, so use
   `lookupStreamId`; if `Nothing`, the snapshot's `writeWorkflowSnapshot` still needs a
   stream id — write a single zero-effect `StepRecorded continueSeedStepName seedJson`
   into the next-generation stream via `appendJournalTx … nextGen` first, which creates
   the stream and gives generation `nextGen` exactly one event, then snapshot from that
   `AppendResult`'s `streamId`/`streamVersion`). This makes the next generation start
   with a one-event journal (the seed step), which is bounded and replay-cheap, and is
   what the `K` cap in acceptance accounts for.
4. In the **current** generation, append the terminal marker
   `WorkflowContinuedAsNew nextGen now` via `appendJournalTx name wid gen …` only if
   `continuedAsNewStepName` does not already exist for `(name, wid, gen)` (idempotent:
   a re-run after a crash mid-rotation re-arms but does not double-write).
5. Return `ContinuedAsNew`.

Because step 3 writes the seed step on the *next* generation and step 4 writes the
marker on the *current* generation, and both use deterministic, generation-namespaced
ids, the whole rotation is idempotent: re-running a workflow that already rotated finds
`continuedAsNewStepName` present in generation `gen`, so `runWorkflowWith` — which
resolves `gen` to the *current* (highest) generation `nextGen` at the top — never
re-enters generation `gen` at all. A run always operates on the current generation.

**The author's restore side.** A workflow that uses `continueAsNew` reads its carried
seed at the top of its body via an ordinary journaled step, e.g.:

```haskell
rollingCounter :: (Workflow :> es) => Eff es Int
rollingCounter = do
  seed <- restoreSeed 0          -- reads __workflow_seed__ if present, else the default
  loopFrom seed
```

Provide a helper `restoreSeed :: (Workflow :> es, Aeson.FromJSON s) => s -> Eff es s`
in `Keiro.Workflow` that does `step (StepName continueSeedStepName) (pure def)` — i.e.
it returns the journaled seed (written by the previous generation's rotation) on a hit,
or the supplied default on the first generation's miss. Because the seed step is
journaled into the new generation in rotation step 3, the next run's `loadJournal`
seeds the map from the snapshot (which contains exactly that one entry), and
`restoreSeed`'s `step` hits it without re-running anything. Export `restoreSeed`.

Acceptance: `cabal build keiro` green; the Milestone 6 test exercises the full path.


### Milestone 5: discovery and resume point at the current generation

**Scope.** Ensure `findUnfinishedWorkflowIds` reports a logical workflow as unfinished
when its *current* generation lacks a terminal `WorkflowCompleted`/`WorkflowCancelled`
marker (a `WorkflowContinuedAsNew` marker on an *older* generation must not count as
"finished"), and that the resume worker re-invokes against the current generation.
**At the end of this milestone** `cabal build keiro` is green and a workflow that
rotated and then crashed is rediscovered and resumed on its current generation.

Edit `findUnfinishedWorkflowIdsStmt` in `keiro/src/Keiro/Workflow/Schema.hs` so the
"has a terminal marker?" check is scoped to the **current generation**. The cleanest
form: a workflow `(workflow_id, workflow_name)` is unfinished when, at its maximum
generation, there is no `__workflow_completed__` or `__workflow_cancelled__` row.
`__workflow_continued_as_new__` is deliberately *not* in that terminal set, so a
rotated-away generation does not make the logical workflow look finished — but because
we scope to `MAX(generation)`, the rotated-away (lower) generation's marker is never
even considered. Concretely:

```sql
SELECT s.workflow_id, s.workflow_name
FROM keiro_workflow_steps s
GROUP BY s.workflow_id, s.workflow_name
HAVING NOT EXISTS (
  SELECT 1 FROM keiro_workflow_steps c
  WHERE c.workflow_id = s.workflow_id
    AND c.workflow_name = s.workflow_name
    AND c.generation = MAX(s.generation)
    AND c.step_name IN ('__workflow_completed__', '__workflow_cancelled__')
)
```

(The literals must keep matching `completedStepName`/`cancelledStepName` in
`Keiro.Workflow.Types`.) This returns each logical workflow at most once and treats it
as finished only when its newest generation reached a true terminal. Verify the exact
`HAVING`/correlated-subquery form compiles on the project's PostgreSQL (18+); an
equivalent CTE that first computes `MAX(generation)` per `(id, name)` and joins back is
acceptable if the correlated `MAX` in the subquery is awkward — record whichever form
you ship.

The resume worker needs no change to its *discovery union* logic (it consumes
`findUnfinishedWorkflowIds`'s `(id, name)` pairs), and its re-invocation already goes
through `runWorkflowWith`, which (after Milestone 3) resolves the current generation
itself. So once `findUnfinishedWorkflowIds` is generation-correct, the resume worker is
automatically generation-correct: it re-invokes the logical id, and `runWorkflowWith`
loads the current generation's journal. Confirm by reading
`keiro/src/Keiro/Workflow/Resume.hs` that re-invocation does not bypass
`runWorkflowWith` (it does not — `WorkflowDef`'s `runDef` is run *through*
`runWorkflowWith`).

Acceptance: `cabal build keiro` green; a resume-after-rotation example in Milestone 6
shows a rotated, then crashed, workflow is rediscovered and driven to completion on its
current generation.


### Milestone 6: the bounded-journal acceptance test

**Scope.** Add a test to `keiro/test/Main.hs` that proves the user-visible behavior:
across N rotations each generation's journal stays bounded by `K`, and the workflow
returns the correct final result. **At the end of this milestone**
`cabal test keiro` is green and this test fails on a tree without the
`continueAsNew`/rotation code (it would never rotate and the single journal would grow
to N steps).

The test uses the existing ephemeral-Postgres fixture: the `Keiro.Workflow` describe
blocks already use `around (withFreshStore fixture)` (see
`keiro/test/Main.hs` ~line 2022), which hands each example a fresh, migrated store
handle `storeHandle` driven via `Store.runStoreIO storeHandle`. Add a new
`describe "Keiro.Workflow continue-as-new" $ around (withFreshStore fixture)` block.

Define a rolling-counter workflow that runs a fixed number of work steps, rotating
every `rotateEvery`:

```haskell
-- A workflow that adds 'batch' work steps to a running total carried across
-- generations via continueAsNew. 'remaining' counts how many more work steps to
-- do across all generations; 'rotateEvery' bounds each generation's work steps.
rollingTotal ::
  (Workflow :> es, IOE :> es) =>
  IORef Int -> Int -> Int -> Eff es Int
rollingTotal sideEffectCounter rotateEvery remaining = do
  seed <- restoreSeed (0 :: Int)            -- running total from the previous generation
  total <- go seed 0
  pure total
  where
    go acc done
      | done >= remaining = pure acc        -- all work finished: this generation completes
      | done >= rotateEvery = continueAsNew acc   -- bound this generation; carry acc onward
      | otherwise = do
          n <- step (StepName ("w" <> Text.pack (show done)))
                    (liftIO (incrementAndRead sideEffectCounter))  -- a real side effect
          go (acc + n) (done + 1)
```

Note `remaining` and `rotateEvery` are *closed over per generation*: across rotations
the resume worker re-invokes the same `WorkflowDef`, so register a `WorkflowDef` whose
`runDef` rebuilds `rollingTotal` with the *total* remaining count; the carried `seed`
(the running total) is what differs per generation, and `done` resets each generation
because each generation's body starts fresh and replays only its own (bounded) journal.
To keep `remaining` correct across generations, carry the *pair* `(runningTotal,
stepsDoneSoFar)` as the seed (a small `Generic`/`ToJSON`/`FromJSON` record), so each
generation knows how many of the global N steps remain. The exact closure shape is the
implementer's to settle; the *acceptance* below does not depend on it, only on bounded
per-generation journals and a correct final total.

Drive it through the resume worker and assert:

1. **First run rotates.** `runWorkflow (WorkflowName "roller") (WorkflowId "r-1")
   (rollingTotal counter rotateEvery total)` returns `Right ContinuedAsNew` (the first
   generation did `rotateEvery` steps and rotated).
2. **Resume to completion.** Loop `resumeWorkflowsOnce defaultWorkflowResumeOptions
   registry` (registry mapping `"roller"` to a `WorkflowDef` that rebuilds the body)
   until a pass reports `completed = 1` and the final outcome is `Completed expected`,
   where `expected` is the sum of `total` side-effect increments (e.g. with a counter
   that returns `1` each step, `expected == total`). Bound the loop (e.g. ≤ N+2 passes)
   so a non-rotating regression hangs visibly rather than looping forever.
3. **Each generation's journal is bounded.** For each generation `g` from `0` to the
   final generation, read the physical stream
   `workflowGenerationStreamName (WorkflowName "roller") (WorkflowId "r-1") g` with
   `Store.readStreamForward streamName (StreamVersion 0) 1000` and assert its length is
   `≤ K`, where `K = rotateEvery + 2` (at most `rotateEvery` work steps, plus the
   one-event seed step that opened the generation, plus the one terminal marker —
   `WorkflowContinuedAsNew` for a rotated generation or `WorkflowCompleted` for the
   final one). With `total = 300` and `rotateEvery = 50`, there are 6 generations and
   each journal holds ≤ 52 events — **never the 300 a single non-rotating run would
   hold.** Assert this for every generation.
4. **Total events across generations equals the work plus overhead, and is split.**
   Optionally assert `sum of per-generation lengths == total + overhead` and that no
   single generation exceeds `K`, making the "bounded per generation, not in aggregate"
   property explicit.
5. **Correct result.** The final `Completed expected` proves rotation did not drop or
   double-count any step (each side effect ran exactly once: assert
   `readIORef counter == total`).

Prove the regression direction: on a tree where `continueAsNew` is a no-op that just
returns (or before this plan's code exists), the workflow never rotates, generation 0's
journal holds all `total` steps, and the per-generation `≤ K` assertion in (3) fails for
`total > K`. State this in the test's comment so a future reader sees what it guards.

Acceptance: `cabal test keiro` runs this example green; the per-generation length
assertions and the final-total assertion are the observable proof.


### Milestone 7: full-repo green and MasterPlan reconciliation

**Scope.** Build and test the whole workspace, then record the chosen generation scheme
in MasterPlan 6's Integration Points / Surprises (the MasterPlan names EP-48 as the
owner of "journal generation naming and discovery"). **At the end of this milestone**
every command in Validation and Acceptance has been run and the MasterPlan notes the
`generation`-column-plus-`#<gen>`-stream scheme.

Run `cabal build all`, `cabal test keiro`, `cabal test jitsurei-test`. Then add a
Surprises entry to
`docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md`
recording: the generation scheme chosen (a `generation` column joined to the
`(workflow_id, workflow_name)` key, plus a `wf:<name>-<id>#<gen>` physical stream with
generation 0 keeping the legacy name); the new `WorkflowContinuedAsNew` constructor and
that it was the first additive edit to the codec in MasterPlan 6 (so EP-49 appends after
it, per the Integration Points convention); and the `ContinuedAsNew` `WorkflowOutcome`.


## Concrete Steps

Run all commands from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. The
`keiro` DB tests use an ephemeral PostgreSQL fixture (`withFreshStore`), so no external
database setup is required for `cabal test keiro`.

**Step 0 — reconcile the as-shipped surface:**

```bash
ls keiro/src/Keiro/Workflow
grep -n "PRIMARY KEY\|workflow_name" keiro-migrations/sql-migrations/*workflow-steps*.sql
grep -n "stepExists ::\|loadStepIndex ::\|findUnfinishedWorkflowIdsStmt\|recordStepStmt" keiro/src/Keiro/Workflow/Schema.hs
```

Expected: the current primary key (either `(workflow_id, step_name)` or — if plan 47
landed — `(workflow_id, workflow_name, step_name)`), and whether
`stepExists`/`loadStepIndex` already carry a `WorkflowName`. Adjust Milestones 1 and 3
to the present shape.

**Step 1 — add the generation migration (Milestone 1):**

```bash
$EDITOR keiro-migrations/sql-migrations/2026-06-05-00-00-00-keiro-workflow-generation.sql
$EDITOR keiro-migrations/src/Keiro/Migrations.hs   # touch a comment to defeat embedDir recompile gotcha
cabal test keiro-migrations-test
```

Expected tail:

```text
All N tests passed (…s)
```

and `\d kiroku.keiro_workflow_steps` (against a migrated DB) shows the `generation`
column and the four-column primary key.

**Step 2 — add the rotation event + codec (Milestone 2):**

```bash
$EDITOR keiro/src/Keiro/Workflow/Types.hs        # WorkflowContinuedAsNew + codec + reserved names
$EDITOR keiro/src/Keiro/Workflow.hs              # loadJournal accumulate branch
cabal build keiro
```

Expected: `Compiling Keiro.Workflow.Types …` then green, no warnings (the package
builds with `-Wall`; treat any warning as a failure to fix).

**Step 3 — generation-aware naming, load, append (Milestone 3):**

```bash
$EDITOR keiro/src/Keiro/Workflow/Types.hs        # workflowGenerationStreamName
$EDITOR keiro/src/Keiro/Workflow/Schema.hs       # currentGeneration, generation in row/stmts
$EDITOR keiro/src/Keiro/Workflow.hs              # thread gen through run/load/append/id
cabal build keiro
cabal test keiro                                  # existing workflow suites must stay green
```

Expected: green build; `cabal test keiro` shows the pre-existing workflow examples
passing unchanged (generation 0 is behavior-preserving).

**Step 4 — the `continueAsNew` primitive (Milestone 4):**

```bash
$EDITOR keiro/src/Keiro/Workflow/Types.hs        # ContinuedAsNew outcome + reserved seed name
$EDITOR keiro/src/Keiro/Workflow.hs              # ContinueAsNew op, handler, rotate, continueAsNew, restoreSeed
cabal build keiro
```

Expected: green.

**Step 5 — discovery/resume on current generation (Milestone 5):**

```bash
$EDITOR keiro/src/Keiro/Workflow/Schema.hs       # findUnfinishedWorkflowIdsStmt scoped to MAX(generation)
cabal build keiro
```

Expected: green.

**Step 6 — the bounded-journal acceptance test (Milestone 6):**

```bash
$EDITOR keiro/test/Main.hs                        # describe "Keiro.Workflow continue-as-new"
cabal test keiro
```

Expected: the new examples pass; the per-generation `≤ K` and final-total assertions
hold.

**Step 7 — full green and MasterPlan note (Milestone 7):**

```bash
cabal build all
cabal test keiro
cabal test jitsurei-test
$EDITOR docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md
```

Expected: all builds and suites pass; the MasterPlan Surprises records the generation
scheme and the new constructor.


## Validation and Acceptance

Acceptance is **observable behavior**, not the presence of code. The three checks below
must all pass.

**Check 1 — a long workflow's journal stays bounded across rotations.** The Milestone 6
test runs a 300-step rolling-total workflow that calls `continueAsNew` every 50 steps,
drives it through `resumeWorkflowsOnce` to completion, then reads each physical
generation stream `wf:roller-r-1`, `wf:roller-r-1#1`, …, `wf:roller-r-1#5` and asserts
each holds **≤ 52 events** (`K = rotateEvery + 2`). A single non-rotating run would put
all 300 steps on one stream; the bounded per-generation length is the proof that
rotation works. Run:

```bash
cabal test keiro
```

and observe the `Keiro.Workflow continue-as-new` examples pass. The load-bearing
assertion a reader verifies by eye in the test source: for every generation `g`,
`Vector.length (events of wf:roller-r-1#g) <= 52`.

**Check 2 — the rotated workflow returns the correct final result.** The same test
asserts the final outcome is `Completed total` (with a unit-increment side effect,
`total == 300`) and that the side-effect counter equals `total` (each work step ran
exactly once — rotation neither dropped nor double-counted a step). This proves
rotation preserves semantics, not just bounds storage.

**Check 3 — discovery and resume follow the current generation.** A sub-example
rotates a workflow once, simulates a crash before the rotated generation completes
(throw inside a later step), then asserts `findUnfinishedWorkflowIds` still reports
`("r-1", "roller")` (the *current*, rotated generation is unfinished — the older
generation's `WorkflowContinuedAsNew` marker does **not** mask it), and that a further
`resumeWorkflowsOnce` pass drives the current generation to `Completed`. This is the
crash-recovery-across-rotation proof.

These checks fail on a tree without this plan's code: with no `continueAsNew`, the
workflow never rotates, generation 0 holds all 300 events, and Check 1's `≤ 52`
assertion fails.


## Idempotence and Recovery

**The migration** (Milestone 1) is a one-way, additive key relaxation: adding a column
with a default and folding it into the primary key cannot introduce a duplicate (the
old key already guaranteed uniqueness on the narrower tuple), so it is safe on populated
tables and `codd` records it by filename and never re-runs it. To roll back, revert the
code and leave the migration applied — the wider key and the `generation` column are
backward-compatible with generation-blind queries (they default to and read `0`).

**The rotation itself** is idempotent by the same deterministic-id discipline the rest
of the runtime uses. A rotation writes two append-only facts: the next generation's seed
step (on `wf:<name>-<id>#<g+1>`) and the current generation's `WorkflowContinuedAsNew`
marker (on the current stream), each under a deterministic, generation-namespaced event
id and each guarded by a `stepExists`/`appendCompletion`-style "only if not present"
check. If a process crashes *during* a rotation:

- *After* the seed step but *before* the marker: the next run resolves the current
  generation as still `g` (the marker that would advance the index's `MAX(generation)`
  is not yet written — the seed step lives on generation `g+1`, so `MAX(generation)` is
  already `g+1` once the seed step's index row commits). Reconcile this ordering
  carefully in Milestone 4: write the marker (which makes generation `g` terminal) and
  the seed step in a deterministic order so `currentGeneration` is monotonic. The safe
  ordering is: **append the next-generation seed step first** (advancing `MAX(generation)`
  to `g+1`), **then** the marker on generation `g`. After the seed step commits, any
  re-run resolves the current generation to `g+1`, loads its (snapshot-seeded) journal,
  and `restoreSeed` returns the carried seed — so even a crash between the two appends
  converges to "continue from the seed", never re-running generation `g`'s work.
- *After* the marker: the workflow is fully rotated; the next run operates on `g+1`.

Because `runWorkflowWith` always resolves and operates on the *current* (highest)
generation, and every append is deterministic and existence-guarded, re-invoking a
rotated workflow any number of times converges to one journal per generation with each
side effect run at most once — the same convergence guarantee EP-38's step
short-circuit already gives within a generation, now extended across them.

**The acceptance test** uses a throwaway ephemeral database per example
(`withFreshStore`), so it can be re-run freely.


## Interfaces and Dependencies

This plan builds **only** on the already-shipped MasterPlan 5 surface (the
`Keiro.Workflow` effect, the `wf:` journal, `workflowJournalCodec`,
`WorkflowRunOptions`, the resume worker) plus EP-41's snapshot reuse
(`workflowStateCodec` / `writeWorkflowSnapshot` / `loadWorkflowSnapshot` in
`keiro/src/Keiro/Workflow/Snapshot.hs`). It adds no new package dependency. Per the
MasterPlan's Dependency Graph it hard-depends on nothing and **soft-relates to EP-49**
(`docs/plans/49-workflow-versioning-and-patch-api.md`): whichever of EP-48/EP-49 lands
first owns the additive edit to `workflowJournalCodec`'s `eventTypes`/`encode`/`decode`
and the second appends its constructor after it. This plan assumes it lands first and
adds `WorkflowContinuedAsNew`; if EP-49 landed first, append `WorkflowContinuedAsNew`
after its constructor and record it in the MasterPlan Surprises.

**Types and signatures that must exist at the end of each milestone** (full module
paths):

- `keiro-migrations/sql-migrations/2026-06-05-00-00-00-keiro-workflow-generation.sql` —
  adds `keiro_workflow_steps.generation integer NOT NULL DEFAULT 0`, folds it into the
  primary key, and widens the lookup index (Milestone 1).
- `Keiro.Workflow.Types`:
  - `WorkflowJournalEvent` gains `WorkflowContinuedAsNew {generation :: !Int, recordedAt :: !UTCTime}`;
    `workflowJournalCodec` gains the matching `eventTypes`/`eventType`/`encode`/`decode`
    branches (additive, `schemaVersion = 1`, no upcaster) (Milestone 2).
  - `continuedAsNewStepName :: Text` (`"__workflow_continued_as_new__"`) and
    `continueSeedStepName :: Text` (`"__workflow_seed__"`), exported (Milestones 2, 4).
  - `workflowGenerationStreamName :: WorkflowName -> WorkflowId -> Int -> StreamName`,
    exported (Milestone 3).
  - `WorkflowOutcome a` gains `ContinuedAsNew` (Milestone 4).
- `Keiro.Workflow.Schema`:
  - `WorkflowStepRow` gains `generation :: !Int`; `recordStepStmt` inserts it with
    `ON CONFLICT (workflow_id, workflow_name, generation, step_name)`.
  - `currentGeneration :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es Int`, exported.
  - `stepExists :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Text -> Eff es Bool`.
  - `loadStepIndex :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Eff es (Map Text Value)`.
  - `findUnfinishedWorkflowIdsStmt` scoped to the current (MAX) generation (Milestone 5).
- `Keiro.Workflow`:
  - `continueAsNew :: (Workflow :> es, Aeson.ToJSON s) => s -> Eff es a`, exported.
  - `restoreSeed :: (Workflow :> es, Aeson.FromJSON s) => s -> Eff es s`, exported.
  - the `Workflow` effect gains `ContinueAsNew :: (Aeson.ToJSON s) => s -> Workflow m a`;
    the interpreter handles it and `runWorkflowWith` catches the internal `WorkflowRotate`
    sentinel and returns `ContinuedAsNew`; `currentGeneration` is resolved once per run
    and threaded through naming/load/append; `deterministicJournalId` includes the
    generation. Re-export `currentGeneration` and `workflowGenerationStreamName`.
- `Keiro.Workflow.Resume` — unchanged in signature; correct by construction once
  `findUnfinishedWorkflowIds` is generation-aware (re-invocation already runs through
  `runWorkflowWith`, which resolves the current generation).

Unaffected and relied upon as-is: the snapshot module (`writeWorkflowSnapshot` /
`loadWorkflowSnapshot` are called against the per-generation stream id, with no code
change); the `keiro_workflow_children` table and `findRunningChildIds`; `Keiro.Codec`'s
additive-constructor convention.

**Git trailers.** Every commit must carry, after a blank line:

```text
MasterPlan: docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md
ExecPlan: docs/plans/48-continue-as-new-journal-rotation-for-durable-workflows.md
Intention: intention_01kt7npy22e5tb3ybycsgeqdnm
```
