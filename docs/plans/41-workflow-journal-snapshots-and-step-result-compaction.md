---
id: 41
slug: workflow-journal-snapshots-and-step-result-compaction
title: "Workflow journal snapshots and step-result compaction"
kind: exec-plan
created_at: 2026-06-03T14:39:45Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
master_plan: "docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md"
---

# Workflow journal snapshots and step-result compaction


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture


A *durable workflow* in Keiro is an ordinary Haskell do-block whose side effects are
recorded ("journaled") at named checkpoints so the function can be paused and resumed
across crashes without re-running work that already happened. Concretely, a workflow is
identified by a `WorkflowName` and a `WorkflowId`, and its durable history lives in one
PostgreSQL event stream named `wf:<name>-<id>` (the *journal*). Every named `step` a
workflow runs appends one `StepRecorded` event to that journal carrying the step's name
and its JSON-encoded result. To run (or resume) a workflow, the runtime first reads the
whole journal back and folds it into an in-memory `Map Text Value` (step-name → encoded
result) — the *accumulated state* — so that each `step` whose name is already present can
return its recorded result instead of re-executing.

That fold is a full-stream replay. It is cheap for a five-step workflow and ruinous for a
long-lived one: a workflow that has run ten thousand steps would re-read ten thousand
events from PostgreSQL **on every subsequent run and on every resume**, even though it
only needs the final accumulated map. This plan removes that cost.

After this change a user can attach a *snapshot policy* to a workflow run. A snapshot is a
single row in the existing `keiro_snapshots` table holding the accumulated `Map Text
Value` serialized as JSON, tagged with the journal stream's id and the stream version it
was taken at. When a policy such as `Every 2` fires, the runtime writes that row. On the
next run, instead of replaying from version 0, the runtime loads the snapshot, seeds the
in-memory map from it, and reads **only the journal events after the snapshot's version**
("tail replay"). The accumulated map you get from snapshot-plus-tail is byte-for-byte the
map you would get from a full replay — snapshots are an optimization, never a source of
truth.

What someone can do after this change that they could not before:

- Run a workflow with `runWorkflowWith (defaultWorkflowRunOptions { snapshotPolicy = Every
  2 }) name wid body` and observe a `keiro_snapshots` row appear for the journal stream,
  decodable back to the accumulated step-result map.
- Re-hydrate that same workflow and observe — via an instrumented journal read or via the
  seeded snapshot version — that replay started *after* the snapshot rather than at version
  0, so a long journal no longer pays a full replay each time.
- Trust the result: a workflow run under `snapshotPolicy = Never` and the same workflow run
  under `snapshotPolicy = Every k` produce identical final results and identical journals.
- Survive a corrupt or stale snapshot: if the snapshot row's discriminant no longer matches
  (e.g. its shape hash was tampered with, or its JSON is garbage), the workflow still
  hydrates correctly by falling back to a full replay from version 0.

This plan is a Wave-2 extension under MasterPlan 5
(`docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md`). It hard-depends
on EP-38 (`docs/plans/38-workflow-journal-and-named-step-replay-core.md`), the journal /
replay core, and on nothing else. It reuses the EP-4 snapshot machinery
(`keiro/src/Keiro/Snapshot.hs`, `keiro/src/Keiro/Snapshot/Schema.hs`, the `keiro_snapshots`
table, and `Keiro.EventStream.StateCodec` / `SnapshotPolicy`) wholesale — the table, the
upsert, and the lookup — but supplies a *workflow-specific* `StateCodec (Map Text Value)`
because a workflow's accumulated state is dynamically keyed by step name and so cannot use
keiki's static register-file shape hash (see the Decision Log).


## Progress


Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-06-03) — Added `workflowStateCodec :: StateCodec WorkflowState` (new module
  `keiro/src/Keiro/Workflow/Snapshot.hs`) plus `loadWorkflowSnapshot`/`writeWorkflowSnapshot`,
  wired into `keiro/keiro.cabal`, and a pure round-trip unit test. `cabal build keiro` green.
- [x] M2 (2026-06-03) — Added the `snapshotPolicy :: SnapshotPolicy WorkflowState` field to
  EP-38's existing `WorkflowRunOptions` (default `Never`); `runWorkflowWith`/`runWorkflow`
  alias already existed from EP-38. All existing EP-38 workflow tests still green.
- [x] M3 (2026-06-03) — Wired the snapshot WRITE at the `step` miss path (terminal `False`)
  and the completion site (terminal `True`), reading the `AppendResult`'s `streamId`/version.
  Validation (a): a 6-step workflow under `Every 2` leaves a `keiro_snapshots` row at version
  6, decodable to the six-entry accumulated map. Plus an `OnTerminal` test asserting the
  completion-site write at version 7.
- [x] M4 (2026-06-03) — Wired the snapshot READ in `loadJournal`: seed from
  `loadWorkflowSnapshot` and read journal events only *after* the snapshot version.
  Validation (b): tail read is 1 event vs 7 for a full replay, and journaled steps
  short-circuit on re-hydration (counter unchanged).
- [x] M5 (2026-06-03) — Correctness + advisory fallback tests. Validation (c): `Never` and
  `Every 2` produce identical results and journals, and the snapshot seed equals a full
  replay. Validation (d): a mismatched shape hash and corrupt JSON both collapse to a full
  replay. Full `cabal test keiro` green (119 examples, 0 failures).


## Surprises & Discoveries


Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (M2): **EP-38 already shipped `WorkflowRunOptions`, `defaultWorkflowRunOptions`,
  and `runWorkflowWith`** (a `newtype` with only `pageSize`), so M2 collapsed to *adding the
  `snapshotPolicy` field* and converting the `newtype` to a `data`. The conversion **dropped
  the `Eq`/`Show` deriving** because `SnapshotPolicy`'s `Custom` arm holds a function; nothing
  depended on those instances. No `runWorkflowWith` introduction or `runWorkflow`-alias work
  was needed — that contract had already landed under EP-38.
- 2026-06-03 (M3): **`runTransactionAppending` already threads an `AppendResult` to its
  continuation**, so capturing `streamId`/`streamVersion` for the snapshot write needed no
  extra `lookupStreamId` round-trip. `appendJournalTx` now returns `(EventId, AppendResult)`;
  `appendJournalEntryReturningId` takes `fst`, the `step` miss path takes the `AppendResult`
  off `recordStep`, and a new `appendCompletion :: ... -> Eff es (Maybe AppendResult)` powers
  the `OnTerminal` write (returns `Nothing` on a replay where the completion marker already
  exists, so a terminal snapshot is taken exactly once on the completing run).
- 2026-06-03 (M3/test): **The `snapshotPolicy` field name collides with keiki's `EventStream`
  record field of the same name.** A bare record update `defaultWorkflowRunOptions {
  snapshotPolicy = ... }` is ambiguous (`GHC-99339`) when both records are in scope (the test
  imports both via the `Keiro` umbrella). Fix: use the generic-lens label —
  `defaultWorkflowRunOptions & #snapshotPolicy .~ Every 2` — which resolves on the concrete
  `WorkflowRunOptions` type. Recorded for EP-42/EP-44, which also construct
  `WorkflowRunOptions` in test/worker code and will hit the same ambiguity.
- 2026-06-03 (M4): **Tail-replay proof is exact, not just "fewer".** A 6-step workflow under
  `Every 2` snapshots at version 6 (the `Every` upsert keeps the highest multiple ≤ 6); the
  terminal `WorkflowCompleted` is version 7 and does *not* re-fire `Every 2`. So a re-hydration
  reads exactly 1 tail event (the v7 completion, which folds to nothing) versus 7 for a full
  replay, and the seeded map already holds all six steps. The behavioural counter check
  (steps short-circuit, side-effect counter stays at 6) corroborates the read-count proof.


## Decision Log


Record every decision made while working on the plan.

- Decision: Represent the accumulated workflow state for snapshotting as the same `Map Text
  Value` EP-38 already holds in memory (`WorkflowState`, from `Keiro.Workflow.Types`), and
  serialize it with `encode = Data.Aeson.toJSON` / `decode = first T.pack . fromJSON-via-
  Result`. Do **not** route it through `Keiro.Snapshot.Codec.defaultStateCodec`.
  Rationale: `defaultStateCodec` is built for a keiki `(state, RegFile rs)` pair and derives
  its `shapeHash` from a *statically-known* type-level register slot list via
  `Keiki.Shape.regFileShapeHash`. A workflow's step names are dynamic runtime strings, so
  there is no static slot list to hash. The MasterPlan's Decision Log fixed this on
  2026-06-03 ("Represent accumulated workflow state as `Map Text Value` and give EP-41 a
  workflow-specific `StateCodec` with a sentinel `shapeHash`"). A `Map Text Value` is
  already self-describing JSON, so it round-trips through Aeson trivially.
  Date: 2026-06-03.

- Decision: Set `workflowStateCodec`'s `shapeHash` to the **fixed sentinel string**
  `"keiro.workflow.stepmap.v1"` and its `stateCodecVersion` to `1`.
  Rationale: The shape hash exists to invalidate a snapshot when the *structure* of the
  folded state changes incompatibly. The structure of a workflow's accumulated state is
  always "a map from step-name strings to self-describing JSON values" — it never changes
  shape, regardless of which steps a particular workflow runs. Per-step schema evolution
  (a step's result type changing between deploys) is the concern of that *step's own*
  `ToJSON`/`FromJSON` round-trip, not of a register-file-shape discriminant: if a step's
  recorded JSON no longer decodes to its new result type, EP-38's replay surfaces that at
  the `step` hit-path decode, exactly as it would for a non-snapshotted journal. So a single
  fixed sentinel is the correct discriminant; bumping `stateCodecVersion` is reserved for a
  future change to the *map envelope* encoding itself (e.g. switching from a bare JSON object
  to a tagged container). This matches the MasterPlan Integration Point "Snapshot machinery
  (EP-41)".
  Date: 2026-06-03.

- Decision: Add a new authoring entry point `runWorkflowWith :: WorkflowRunOptions ->
  WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)` carrying
  a `WorkflowRunOptions` record whose first field is `snapshotPolicy :: SnapshotPolicy
  WorkflowState`, and redefine EP-38's `runWorkflow` as `runWorkflow = runWorkflowWith
  defaultWorkflowRunOptions` (default policy `Never`). This is an **addition to EP-38's
  surface**.
  Rationale: EP-38's `runWorkflow` has no place to carry a snapshot policy, and threading a
  bare policy argument into `runWorkflow` would be a breaking signature change that EP-39 /
  EP-40 / EP-42 would all have to absorb. An options record is the extension point the rest
  of the MasterPlan needs anyway: EP-44 (telemetry) will add `Maybe KeiroMetrics` / `Maybe
  Tracer` fields here, and EP-42 (resume worker) re-invokes workflows and will want to pass
  the same policy. Keeping `runWorkflow` as a thin alias preserves every existing call site.
  This addition is recorded in Surprises & Discoveries and in Interfaces so the MasterPlan
  and EP-38 note it as the canonical options home.
  Date: 2026-06-03.

- Decision: Reuse `lookupSnapshot` (from `Keiro.Snapshot.Schema`) and `writeSnapshot` (from
  `Keiro.Snapshot`) directly with our own `workflowStateCodec`, rather than the typed
  `hydrateWithSnapshot` helper.
  Rationale: `Keiro.Snapshot.hydrateWithSnapshot` is typed
  `StateCodec (s, RegFile rs) -> Eff es (Maybe (SnapshotSeed rs s))` — it decodes into a
  keiki `(state, RegFile rs)` pair and returns a `SnapshotSeed rs s` carrying a `RegFile rs`.
  A workflow has no `RegFile`; its state is a bare `Map Text Value`. The typed helper does
  not fit. `writeSnapshot :: StreamId -> StreamVersion -> StateCodec state -> state -> Eff es
  ()` is already polymorphic in `state`, so the write side fits with no change. For the read
  side, `lookupSnapshot streamId version shapeHash` returns a `SnapshotRow` whose `state ::
  Value` is the raw encoded snapshot; we decode it ourselves with `workflowStateCodec`. No
  generalization of `hydrateWithSnapshot` is required; a small local helper in
  `Keiro.Workflow.Snapshot` (`loadWorkflowSnapshot`) wraps `lookupStreamId` + `lookupSnapshot`
  + decode. If implementation reveals a cleaner shared generalization, propose it here and
  record it before adopting.
  Date: 2026-06-03.

- Decision: Take the snapshot WRITE inside the `step` hit/miss handler immediately after a
  successful journal append, using the `AppendResult` that append returns (which carries both
  `streamId` and the post-append `streamVersion`). Take the READ once on run entry, before the
  replay fold, using `lookupStreamId (workflowStreamName name wid)`.
  Rationale: The write needs the journal stream's `StreamId` and the version the just-appended
  step landed at; `Kiroku.Store.Types.AppendResult` carries both (`streamId :: StreamId`,
  `streamVersion :: StreamVersion`), so no extra `lookupStreamId` round-trip is needed on the
  hot write path. The read happens before any append, so there is no `AppendResult` yet and we
  resolve the id with `lookupStreamId`; a journal stream that does not exist yet (first ever
  run) simply yields `Nothing` and we replay from version 0. This mirrors EP-4's
  `Keiro.Command` reference pattern (`writeSnapshotIfNeeded` writes from the `AppendResult`;
  `hydrateWithSnapshot` resolves the id via `lookupStreamId`).
  Date: 2026-06-03.


## Outcomes & Retrospective


Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-03.** All five milestones landed and the full suite is green (119
examples, 0 failures, including 7 new snapshot examples). The plan's purpose — remove the
full-stream replay cost for long-lived workflows via advisory snapshots — is met:

- `keiro/src/Keiro/Workflow/Snapshot.hs` owns `workflowStateCodec` (sentinel shape hash
  `"keiro.workflow.stepmap.v1"`, codec version 1) plus `loadWorkflowSnapshot` /
  `writeWorkflowSnapshot`, reusing EP-4's `keiro_snapshots` table, `writeSnapshot`, and
  `lookupSnapshot` with no schema change and no new migration.
- `WorkflowRunOptions` carries `snapshotPolicy` (default `Never`, so EP-38 behaviour is
  byte-identical); `runWorkflowWith` evaluates the policy at the `step` miss path and at the
  completion site and writes through `workflowStateCodec`. `loadJournal` seeds from the latest
  compatible snapshot and tail-replays.
- All four observable validations hold: (a) the `Every 2` snapshot row lands at version 6 and
  decodes to the six-entry map; (b) re-hydration reads 1 tail event vs 7 and steps
  short-circuit; (c) `Never` and `Every 2` are result- and journal-identical and the seed
  equals a full replay; (d) a stale shape hash and corrupt JSON both fall back to full replay
  and still complete correctly.

**Cross-plan contracts delivered (for the MasterPlan / downstream waves):**

- `WorkflowRunOptions.snapshotPolicy` is the canonical per-run snapshot knob; EP-44 adds
  `metrics`/`tracer` to the *same* record and EP-42's resume worker passes its own options so
  resumed runs keep snapshotting.
- The workflow snapshot discriminant is `stateCodecVersion = 1` + shape hash
  `"keiro.workflow.stepmap.v1"`; EP-45's snapshot guidance should cite this sentinel.
- `appendJournalTx` now returns `(EventId, AppendResult)` and a new `appendCompletion` returns
  `Maybe AppendResult`; these are internal to `Keiro.Workflow` but note the change for EP-42.

**Gaps / deferred:** none for this plan's scope. The instrumented-read proof is realized by
re-reading the journal with the same `readStreamForward` the runtime uses (keyed off the exact
seed version `loadWorkflowSnapshot` returns) rather than by an in-runtime event counter, which
would have required exposing a test-only hook.


## Context and Orientation


The working tree is at `/Users/shinzui/Keikaku/bokuno/keiro`. The library packages are
`keiro-core` (pure contracts), `keiro` (the runtime), `keiro-migrations` (embedded SQL),
`keiro-test-support` (PostgreSQL test fixtures), and `jitsurei` (worked examples). This
plan adds **one** new module to the `keiro` package (`keiro/src/Keiro/Workflow/Snapshot.hs`)
and **edits** the existing `keiro/src/Keiro/Workflow.hs` produced by EP-38. It adds **no**
new database table and **no** new migration — it reuses the `keiro_snapshots` table EP-4
already shipped.

Read the following before starting. Line numbers are guides, not guarantees.

**What EP-38 hands you (the foundation this plan consumes).** EP-38
(`docs/plans/38-workflow-journal-and-named-step-replay-core.md`) defines, in
`keiro/src/Keiro/Workflow/Types.hs`:

```haskell
newtype WorkflowName = WorkflowName Text
newtype WorkflowId   = WorkflowId Text
newtype StepName     = StepName Text
data WorkflowJournalEvent = StepRecorded { stepName :: Text, result :: Value, recordedAt :: UTCTime }
                          | WorkflowCompleted { recordedAt :: UTCTime }
data WorkflowOutcome a    = Completed a | Suspended
type WorkflowState = Map Text Value                 -- accumulated step-name -> encoded result
workflowStreamName   :: WorkflowName -> WorkflowId -> StreamName   -- "wf:<name>-<id>"
workflowJournalCodec :: Codec WorkflowJournalEvent
```

and in `keiro/src/Keiro/Workflow.hs`:

```haskell
data Workflow :: Effect
step          :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a
awaitStep     :: (Workflow :> es, FromJSON a) => StepName -> Eff es () -> Eff es a
runWorkflow   :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
appendJournalEntry :: (Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()
```

EP-38's `runWorkflow` handler, per its Milestone 3, (1) pre-loads the journal by reading
`readStreamForwardStream (workflowStreamName name wid) (StreamVersion 0) pageSize`, decoding
each event with `workflowJournalCodec`, and folding `StepRecorded` entries into an `IORef
(Map Text Value)`; (2) interprets `Step name action` against that `IORef` (hit → decode and
return without running the action; miss → run the action, encode, append a `StepRecorded`
inside one `runTransaction`, and insert into the `IORef`); and (3) appends a
`WorkflowCompleted` on normal completion and returns `Completed a`. The two seams this plan
touches are the **pre-load read** (the version-0 full replay we want to shorten) and the
**miss-path append** (the place we evaluate the snapshot policy after a successful append).

If EP-38's actual function names or the exact shape of its handler differ slightly from the
above when you reach this plan, adapt the edits to its real structure; the contracts that
*must* hold are `WorkflowState = Map Text Value`, `workflowStreamName`, `runWorkflow`, and
the journal-stream-as-snapshot-subject. This plan was written against EP-38's plan text;
re-read EP-38's `Keiro.Workflow` source before editing.

**The EP-4 snapshot machinery you reuse.** Four pieces, all already in the tree:

`keiro-core/src/Keiro/EventStream.hs` defines the codec and policy types (re-exported from
`Keiro` and `Keiro.Snapshot`):

```haskell
data StateCodec state = StateCodec
  { stateCodecVersion :: !Int
  , shapeHash         :: !Text
  , encode            :: !(state -> Value)
  , decode            :: !(Value -> Either Text state)
  }

data SnapshotPolicy state
  = Never
  | Every !Int                                  -- fires when version `mod` n == 0 (n > 0)
  | OnTerminal
  | Custom !(state -> StreamVersion -> Bool)
```

`keiro-core/src/Keiro/Snapshot/Policy.hs` exposes the single decision procedure
(re-exported through `Keiro.Snapshot` and `Keiro`):

```haskell
shouldSnapshot :: SnapshotPolicy state -> Bool -> state -> StreamVersion -> Bool
-- args: policy, isTerminal, foldedState, postAppendStreamVersion
```

`keiro/src/Keiro/Snapshot.hs` exposes the write side, already polymorphic in `state`:

```haskell
writeSnapshot :: (Store :> es) => StreamId -> StreamVersion -> StateCodec state -> state -> Eff es ()
-- encodes `state` with the codec and upserts keiro_snapshots, keeping the highest stream_version per stream
```

`keiro/src/Keiro/Snapshot/Schema.hs` exposes the read side and the row type:

```haskell
data SnapshotRow = SnapshotRow
  { streamId          :: !StreamId
  , streamVersion     :: !StreamVersion
  , state             :: !Value          -- the raw encoded snapshot
  , stateCodecVersion :: !Int
  , regfileShapeHash  :: !Text
  , createdAt, updatedAt :: !UTCTime
  }

lookupSnapshot :: (Store :> es) => StreamId -> Int -> Text -> Eff es (Maybe SnapshotRow)
-- returns the newest row matching (stream_id, state_codec_version, regfile_shape_hash);
-- a non-matching discriminant simply returns Nothing -> the caller replays from version 0.
```

The `keiro_snapshots` table is keyed on `stream_id` with the two discriminant columns
`state_codec_version` and `regfile_shape_hash`. The upsert in `writeSnapshotRow`
(`Snapshot/Schema.hs`) keeps only the highest `stream_version` per stream
(`... WHERE keiro_snapshots.stream_version <= EXCLUDED.stream_version`), so an out-of-order
or stale write is ignored — meaning our write path is naturally idempotent and order-safe.

**Why `hydrateWithSnapshot` does not fit and `lookupSnapshot` does.**
`Keiro.Snapshot.hydrateWithSnapshot` is typed
`StreamName -> StateCodec (s, RegFile rs) -> Eff es (Maybe (SnapshotSeed rs s))` — it decodes
into a keiki `(state, RegFile rs)` pair and hands back a `SnapshotSeed rs s` carrying a
`RegFile rs`. Workflows have no register file; their state is a bare `Map Text Value`. So we
do not call `hydrateWithSnapshot`. We call the lower-level `lookupSnapshot` to get the raw
`SnapshotRow` and decode its `state :: Value` field ourselves with `workflowStateCodec`. The
`writeSnapshot` helper is already `state`-polymorphic, so the write side needs no
generalization. Per the Decision Log, no change to `hydrateWithSnapshot` is required.

**`lookupStreamId` (kiroku).** `Kiroku.Store.Read.lookupStreamId :: (Store :> es) =>
StreamName -> Eff es (Maybe StreamId)` resolves a stream name to its surrogate `StreamId`,
returning `Nothing` for a stream that has never been written. EP-4's `hydrateWithSnapshot`
uses it the same way; we use it on the workflow snapshot READ path. The kiroku source is at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (locate via `mori registry show
shinzui/kiroku --full`).

**`AppendResult` (kiroku).** `Kiroku.Store.Types.AppendResult` carries `streamId ::
StreamId` and `streamVersion :: StreamVersion` (the version of the last event in the append).
EP-38's `step` miss-path append returns an `AppendResult`; we read `streamId` and
`streamVersion` off it to drive the snapshot WRITE without a separate id lookup.

**The reference wiring pattern — `Keiro.Command`.** `keiro/src/Keiro/Command.hs` is the
canonical example of both halves. Its `writeSnapshotIfNeeded` (~lines 526–544) computes the
post-append folded state, asks `shouldSnapshot (snapshotPolicy) terminal finalState
finalVersion`, and on a fire calls `writeSnapshot (appendResult ^. #streamId) finalVersion
codec finalState`. Its `hydrate`/`hydrateWithSnapshot` path (~lines 187–222) loads a snapshot
seed and replays *forward from* `seed.streamVersion` rather than 0, falling back to
`hydrateFull` (version 0) on a miss or decode failure. Our workflow code mirrors both halves
with the `Map Text Value` codec.

**The test suite.** `keiro/test/Main.hs` is a single hspec `exitcode-stdio` suite run
against an ephemeral PostgreSQL database via `keiro-test-support`. It uses the *suite-level
template-database fixture* — `main = withMigratedSuite $ \fixture -> hspec $ ...` applies
`allKeiroMigrations` once to a template database, and `around (withFreshStore fixture)` hands
each example a freshly cloned database (per the project memory note on ephemeral-pg template
databases; do **not** migrate per-example). The existing `describe "Keiro.Snapshot"` block
(~lines 504–597) is the closest model: it runs commands, then queries `keiro_snapshots`
through small hasql statements such as `snapshotVersionForStreamStmt :: Statement Text (Maybe
StreamVersion)` (a `streams`-join on `stream_name`) and corrupts a snapshot discriminant with
`corruptSnapshotShapeStmt :: Statement (Text, Text) ()`. Reuse those exact statements
(already defined near the bottom of `Main.hs`, ~lines 2775+) for the workflow snapshot
assertions; they key on `stream_name`, so passing the workflow journal name
`"wf:<name>-<id>"` works unchanged.

Terms defined for this plan (define-on-first-use, per the plan spec):

- *snapshot* — one row in `keiro_snapshots` holding a folded state as JSON, tagged with the
  stream id, the version it was taken at, and two discriminants (codec version + shape hash)
  that gate reuse. *Advisory* means a non-matching or undecodable snapshot is silently
  ignored and the reader falls back to a full replay; it is never load-bearing.
- *accumulated state* / *`WorkflowState`* — the `Map Text Value` of step-name → encoded
  result that EP-38's handler folds the journal into and consults on each `step`.
- *tail replay* — reading only the journal events *after* a snapshot's `stream_version`
  instead of from version 0, seeding the in-memory map from the snapshot first.
- *snapshot policy* — a `SnapshotPolicy WorkflowState` (`Never | Every n | OnTerminal |
  Custom`) deciding, after each step append, whether to persist a snapshot.


## Plan of Work


Five milestones, each independently verifiable; commit after each with the trailers in
Interfaces and Dependencies.


### Milestone 1 — `workflowStateCodec :: StateCodec (Map Text Value)`


Create `keiro/src/Keiro/Workflow/Snapshot.hs`. It owns the workflow-specific state codec and
two small helpers the runtime uses; it depends only on EP-38's `Keiro.Workflow.Types`
(`WorkflowState`) and the EP-4 snapshot surface.

Define the codec:

```haskell
module Keiro.Workflow.Snapshot
  ( workflowStateCodec
  , workflowStateCodecVersion
  , workflowStateShapeHash
  , loadWorkflowSnapshot
  , writeWorkflowSnapshot
  ) where

import Data.Aeson (Result (..), fromJSON, toJSON)
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Keiro.EventStream (StateCodec (..))
import Keiro.Prelude
import Keiro.Snapshot (writeSnapshot)
import Keiro.Snapshot.Schema (SnapshotRow (..), lookupSnapshot)
import Keiro.Workflow.Types (WorkflowState)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (lookupStreamId)
import Kiroku.Store.Types (StreamId, StreamName, StreamVersion)

workflowStateCodecVersion :: Int
workflowStateCodecVersion = 1

-- A FIXED sentinel. The accumulated state is always "a JSON object of step-name strings
-- to self-describing JSON values"; its *shape* never varies with which steps ran, so the
-- shape hash is constant. Per-step result-type evolution is the step's own ToJSON/FromJSON
-- concern, surfaced at the step decode in Keiro.Workflow, not here. Bump
-- `workflowStateCodecVersion` only if the map *envelope* encoding itself changes.
workflowStateShapeHash :: Text
workflowStateShapeHash = "keiro.workflow.stepmap.v1"

workflowStateCodec :: StateCodec WorkflowState
workflowStateCodec = StateCodec
  { stateCodecVersion = workflowStateCodecVersion
  , shapeHash = workflowStateShapeHash
  , encode = toJSON
  , decode = \value -> case fromJSON value of
      Success m -> Right m
      Error msg -> Left (Text.pack msg)
  }
```

Then add the two runtime helpers, which the `Keiro.Workflow` edits in M3/M4 call:

```haskell
-- WRITE: encode the accumulated map and upsert keiro_snapshots for the journal stream.
-- Called from the step miss-path with the AppendResult's streamId and post-append version.
writeWorkflowSnapshot :: (Store :> es) => StreamId -> StreamVersion -> WorkflowState -> Eff es ()
writeWorkflowSnapshot streamId version state =
  writeSnapshot streamId version workflowStateCodec state

-- READ: resolve the journal stream id, look up the latest matching snapshot row, and decode
-- it to a (WorkflowState, StreamVersion) seed. Returns Nothing — meaning "replay from 0" —
-- when the stream has no id yet, no matching snapshot, or an undecodable snapshot (advisory
-- semantics). Mirrors Keiro.Snapshot.hydrateWithSnapshot's miss-is-benign contract.
loadWorkflowSnapshot :: (Store :> es) => StreamName -> Eff es (Maybe (WorkflowState, StreamVersion))
loadWorkflowSnapshot journalName = do
  mStreamId <- lookupStreamId journalName
  case mStreamId of
    Nothing -> pure Nothing
    Just streamId -> do
      mRow <- lookupSnapshot streamId workflowStateCodecVersion workflowStateShapeHash
      pure $ do
        row <- mRow
        state <- either (const Nothing) Just ((workflowStateCodec ^. #decode) (row ^. #state))
        pure (state, row ^. #streamVersion)
```

Add `Keiro.Workflow.Snapshot` to the `exposed-modules` stanza of `keiro/keiro.cabal` (the
list EP-38 extended, ~lines 34–56). Edit only your own line; do not reorder the list (the
MasterPlan's module-layout integration point asks each plan to keep diffs minimal).

Acceptance for M1: `cabal build keiro` succeeds, and a pure unit test (no database — add it
to a non-DB `describe` block in `keiro/test/Main.hs`) round-trips a non-trivial map through
the codec:

```haskell
let m = Map.fromList [ ("first", toJSON (1 :: Int))
                     , ("second", toJSON ["a","b"::Text])
                     , ("sleep:42", Aeson.Null) ]
(workflowStateCodec ^. #decode) ((workflowStateCodec ^. #encode) m) `shouldBe` Right m
workflowStateCodec ^. #shapeHash `shouldBe` "keiro.workflow.stepmap.v1"
```


### Milestone 2 — `WorkflowRunOptions` and `runWorkflowWith`


Edit `keiro/src/Keiro/Workflow.hs` (EP-38's module). Add an options record and the new entry
point, and reduce the existing `runWorkflow` to an alias. This milestone changes **no
behaviour** — the default policy is `Never`, so a default-options run replays exactly as
EP-38 did — but it establishes the extension point M3/M4 and downstream plans build on.

Add to `Keiro.Workflow`:

```haskell
import Keiro.EventStream (SnapshotPolicy (..))
import Keiro.Workflow.Types (WorkflowState)

-- | Knobs for one workflow run. The natural home for future cross-cutting run options:
-- EP-44 (telemetry) will add `Maybe KeiroMetrics` / `Maybe Tracer` fields here, and EP-42
-- (the resume worker) passes its own options when re-invoking a workflow. Extend this
-- record additively; never break the field set EP-38/EP-41 established.
data WorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy :: !(SnapshotPolicy WorkflowState)
  -- ^ When to persist a snapshot of the accumulated step-result map. Default 'Never'
  --   (EP-38 behaviour: every run/resume does a full version-0 replay).
  , pageSize :: !Int32
  -- ^ Journal read page size; mirror EP-38's hydration page size (default 256).
  }
  deriving stock (Generic)

defaultWorkflowRunOptions :: WorkflowRunOptions
defaultWorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy = Never
  , pageSize = 256
  }

-- | The full-control entry point. EP-38's `runWorkflow` becomes a thin alias.
runWorkflowWith ::
  (IOE :> es, Store :> es) =>
  WorkflowRunOptions ->
  WorkflowName ->
  WorkflowId ->
  Eff (Workflow : es) a ->
  Eff es (WorkflowOutcome a)
runWorkflowWith options name wid body = ...   -- EP-38's runWorkflow body, parameterised (M3/M4)

runWorkflow ::
  (IOE :> es, Store :> es) =>
  WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
runWorkflow = runWorkflowWith defaultWorkflowRunOptions
```

Mechanically: rename EP-38's existing `runWorkflow` body to `runWorkflowWith` with the extra
leading `options` argument, thread `options ^. #pageSize` into the journal read where EP-38
hard-coded a page size, and add the one-line `runWorkflow = runWorkflowWith
defaultWorkflowRunOptions`. Do not change behaviour yet; M3/M4 consume `options ^.
#snapshotPolicy`. Export `WorkflowRunOptions(..)`, `defaultWorkflowRunOptions`, and
`runWorkflowWith` from `Keiro.Workflow`'s export list (and from the `Keiro` umbrella if it
re-exports `Keiro.Workflow`).

Acceptance for M2: `cabal build keiro` green and **all existing EP-38 workflow tests still
pass unchanged** under `cabal test keiro` — proving the alias preserves EP-38's surface and
behaviour.


### Milestone 3 — Snapshot WRITE on policy fire


Still in `keiro/src/Keiro/Workflow.hs`. Find EP-38's `Step name action` **miss** branch: the
one that runs the action, encodes the result, and — in one `runTransaction` — appends a
`StepRecorded` to the journal and upserts the `keiro_workflow_steps` index. That append yields
a `Kiroku.Store.Types.AppendResult` carrying `streamId` and the post-append `streamVersion`.
After the `IORef` map has been updated to include the new step (so the map reflects the state
*as of* this append) and the transaction has committed, evaluate the snapshot policy and write
if it fires:

```haskell
-- after the successful step append, with `appendResult :: AppendResult` and `accMap` =
-- the IORef map *including* the just-recorded step:
let version   = appendResult ^. #streamVersion
    streamId  = appendResult ^. #streamId
    terminal  = False   -- a `step` is never the terminal WorkflowCompleted event
when (shouldSnapshot (options ^. #snapshotPolicy) terminal accMap version) $
  writeWorkflowSnapshot streamId version accMap
```

Notes:

- Import `shouldSnapshot` from `Keiro.Snapshot.Policy` (re-exported via `Keiro.Snapshot` /
  `Keiro`) and `writeWorkflowSnapshot` from `Keiro.Workflow.Snapshot`.
- `terminal = False` for a `step` because a step append is never the `WorkflowCompleted`
  marker. If you also want `OnTerminal` to snapshot the *final* accumulated state, add the
  same `shouldSnapshot ... True ...` check at EP-38's `WorkflowCompleted` append site, where
  the append also returns an `AppendResult` with the journal's final version. Wire both
  (step-site with `terminal = False`, completion-site with `terminal = True`) so `Every n`,
  `Custom`, and `OnTerminal` all behave; `Never` (the default) writes nothing at either site.
- The `writeWorkflowSnapshot` upsert keeps only the highest stream_version per stream, so a
  re-run that re-fires the policy at an already-snapshotted version is a harmless no-op
  (idempotent — see Idempotence and Recovery).
- Read the snapshot policy from the threaded `options` (M2), not a global.

Acceptance for M3 (Validation (a)): a new DB test under `describe "Keiro.Workflow snapshots"
$ around (withFreshStore fixture)` runs a 6-step workflow under `snapshotPolicy = Every 2`:

```haskell
let body = do
      mapM_ (\i -> step (StepName ("s" <> Text.pack (show i))) (pure (i :: Int))) [1..6]
result <- Store.runStoreIO storeHandle $
  runWorkflowWith (defaultWorkflowRunOptions { snapshotPolicy = Every 2 })
    (WorkflowName "snap") (WorkflowId "w1") body
-- a keiro_snapshots row exists for wf:snap-w1, at the latest Every-2 version (6),
-- and decodes to the full accumulated map of all six steps:
Right snapVersion <- Store.runStoreIO storeHandle $
  Store.runTransaction $ Tx.statement "wf:snap-w1" snapshotVersionForStreamStmt
snapVersion `shouldBe` Just (StreamVersion 6)
```

The journal version after six `StepRecorded` events is 6, and `Every 2` fired at versions 2,
4, and 6; the upsert keeps the highest (6). Then read the row's `state` JSON back (via
`lookupSnapshot` on the resolved id, or a small `SELECT state ...` statement) and assert it
decodes through `workflowStateCodec` to the six-entry map. Reuse `snapshotVersionForStreamStmt`
already defined in `Main.hs`.


### Milestone 4 — Snapshot READ and tail replay


Back in `runWorkflowWith` (`keiro/src/Keiro/Workflow.hs`), change the **pre-load** step. EP-38
unconditionally reads `readStreamForwardStream (workflowStreamName name wid) (StreamVersion 0)
pageSize` and folds from an empty map. Replace that with a snapshot-aware pre-load:

```haskell
let journalName = workflowStreamName name wid
mSeed <- loadWorkflowSnapshot journalName        -- Maybe (WorkflowState, StreamVersion)
let (seedMap, fromVersion) = case mSeed of
      Just (m, v) -> (m, v)            -- seed from snapshot, replay the tail after v
      Nothing     -> (Map.empty, StreamVersion 0)   -- advisory miss: full replay
-- fold the journal events AFTER fromVersion onto seedMap:
ref <- liftIO (newIORef seedMap)
foldJournalFrom journalName fromVersion (options ^. #pageSize) ref   -- decodes StepRecorded, inserts into ref
```

`readStreamForwardStream name v pageSize` reads events with `streamVersion > v` (forward from
`v`, exclusive of `v` itself — confirm this against kiroku's read semantics; EP-4's
`Keiro.Command` `replayFrom` replays "forward from `seed.streamVersion`" the same way). The
resulting `ref` holds exactly the accumulated map a full version-0 replay would have produced,
because every `StepRecorded` at or before `fromVersion` is already captured in `seedMap` (the
snapshot was taken *at* `fromVersion` after those steps were folded in). The rest of EP-38's
handler is unchanged: it reads and extends this `IORef`.

Advisory-fallback wiring (this is what makes a bad snapshot harmless): `loadWorkflowSnapshot`
already returns `Nothing` when the stream id is missing, the discriminant does not match, or
the JSON fails to decode — in all three cases we fall to `(Map.empty, StreamVersion 0)`, a
full replay. There is no separate error path to write; the `Nothing` collapses them.

Acceptance for M4 (Validation (b)): prove tail replay reads fewer events than the full count.
Two acceptable proofs; do at least one:

- *Instrumented read.* Wrap the journal read in a counter (e.g. a `Streamly` `Fold` that
  increments an `IORef Int` per event, or count in `foldJournalFrom`). Run a 6-step workflow
  under `Every 2` (so a snapshot exists at version 6), then re-hydrate with a second
  `runWorkflowWith` of a body whose steps all short-circuit (same step names). Assert the
  second run's journal-read count is `0` (everything ≤ 6 is in the seed; nothing after 6),
  whereas a `Never` re-hydration would read all 7 events (6 `StepRecorded` + 1
  `WorkflowCompleted`).
- *Seeded-version proof.* Assert `loadWorkflowSnapshot "wf:snap-w1"` returns `Just (m,
  StreamVersion 6)` with `Map.size m == 6`, so the documented pre-load starts the read at
  version 6, not 0. This is a weaker but simpler proof that replay starts after the snapshot.

Prefer the instrumented-read proof; it directly demonstrates the performance win the plan
exists to deliver.


### Milestone 5 — Correctness equality and advisory fallback


Two DB tests, both in the `describe "Keiro.Workflow snapshots"` block.

*Validation (c) — snapshot-seeded state equals full-replay state.* Run the same workflow
twice end to end: once with `snapshotPolicy = Never`, once with `snapshotPolicy = Every 2`,
each against its own fresh database (or distinct workflow ids in one database). Assert the two
runs return identical `WorkflowOutcome` results, and that the two journals contain identical
`StepRecorded` payloads in the same order (decode both with `workflowJournalCodec` and
compare). Then, for the `Every 2` workflow, re-hydrate it (a fresh `runWorkflowWith` whose
body short-circuits every step) and assert the accumulated map it ends with equals the map
obtained from a full version-0 replay of the same journal (decode the whole stream by hand and
fold). This is the load-bearing assertion the plan brief calls out: *the map seeded from a
snapshot must equal the map you'd get from full replay.*

*Validation (d) — advisory fallback on a corrupt/mismatched discriminant.* Run a 6-step
workflow under `Every 2`, then tamper with the snapshot so the runtime cannot use it, two
ways (one test each, or a single test exercising both):

1. *Discriminant mismatch.* Run `corruptSnapshotShapeStmt` against `"wf:snap-w1"` to set
   `regfile_shape_hash` to `"stale-shape"`. Now `lookupSnapshot` (which filters on
   `regfile_shape_hash = "keiro.workflow.stepmap.v1"`) returns no row, so
   `loadWorkflowSnapshot` returns `Nothing` and the workflow hydrates by full replay.
2. *Corrupt JSON.* Set the snapshot's `state` column to a JSON value that does not decode to
   a `Map Text Value` (e.g. `Aeson.String "bad"`, via a small `UPDATE keiro_snapshots ... SET
   state = $2`). Now `lookupSnapshot` returns the row but `workflowStateCodec`'s `decode`
   fails, so `loadWorkflowSnapshot` returns `Nothing` and the workflow hydrates by full
   replay.

In both cases, re-hydrate the workflow (a `runWorkflowWith` body that short-circuits every
step) and assert it still returns the correct `Completed` result with all six step values —
proving the snapshot is advisory and never load-bearing. Reuse `corruptSnapshotShapeStmt` from
`Main.hs`; add a tiny `corruptWorkflowSnapshotStateStmt :: Statement (Text, Value) ()` if the
existing `corruptSnapshotStateStmt` is not already general enough (it is — it takes
`(stream_name, Value)` and updates `state`).

Acceptance for M5: full `cabal test keiro` green; the four validations (a)–(d) all pass.


## Concrete Steps


Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted. The repo builds with
`cabal` under a Nix-provided GHC.

```bash
# M1 — codec + helpers module
$EDITOR keiro/src/Keiro/Workflow/Snapshot.hs       # workflowStateCodec + load/write helpers
$EDITOR keiro/keiro.cabal                           # add Keiro.Workflow.Snapshot to exposed-modules
$EDITOR keiro/test/Main.hs                           # add the pure codec round-trip unit test
cabal build keiro
cabal test keiro                                     # the M1 unit test passes

# M2 — options record + runWorkflowWith alias (behaviour-preserving)
$EDITOR keiro/src/Keiro/Workflow.hs                  # WorkflowRunOptions, defaultWorkflowRunOptions, runWorkflowWith, runWorkflow alias
cabal build keiro
cabal test keiro                                     # all existing EP-38 workflow tests still green

# M3 — snapshot WRITE on policy fire
$EDITOR keiro/src/Keiro/Workflow.hs                  # shouldSnapshot + writeWorkflowSnapshot at step (+ completion) append sites
$EDITOR keiro/test/Main.hs                           # Validation (a): Every 2 leaves a row at v6
cabal test keiro

# M4 — snapshot READ + tail replay
$EDITOR keiro/src/Keiro/Workflow.hs                  # loadWorkflowSnapshot pre-load; read from snapshot version
$EDITOR keiro/test/Main.hs                           # Validation (b): tail read count < full count
cabal test keiro

# M5 — correctness equality + advisory fallback
$EDITOR keiro/test/Main.hs                           # Validations (c) and (d)
cabal test keiro                                     # full suite green
```

This plan adds **no migration**, so the EP-34 `embedDir` recompilation gotcha does **not**
apply here (it bites only when adding a `.sql` file under `keiro-migrations/sql-migrations/`).
The `keiro_snapshots` table already exists from EP-4 and is part of `allKeiroMigrations`,
which the suite-level template database already applies.

Expected shape of a passing snapshot-write transcript fragment (illustrative):

```text
Keiro.Workflow snapshots
  writes a snapshot of the accumulated step map after Every 2 fires
    +++ OK
  reads only the tail after the snapshot version on re-hydration
    +++ OK
  snapshot-seeded accumulated state equals full-replay accumulated state
    +++ OK
  hydrates via full replay when the snapshot discriminant mismatches
    +++ OK
  hydrates via full replay when the snapshot JSON is corrupt
    +++ OK
```


## Validation and Acceptance


The plan is accepted when `cabal test keiro` is green and all four observable validations
hold:

- **(a) Snapshot exists and decodes.** After a 6-step workflow under `snapshotPolicy = Every
  2`, `keiro_snapshots` has a row for the journal stream `wf:<name>-<id>` at `stream_version =
  6` (the highest Every-2 multiple ≤ 6), and that row's `state` JSON decodes through
  `workflowStateCodec` to the six-entry accumulated map. Verified by
  `snapshotVersionForStreamStmt` and a `lookupSnapshot`-and-decode assertion.
- **(b) Tail replay reads fewer events.** Re-hydrating that workflow (a `runWorkflowWith` body
  that short-circuits all steps) reads `0` journal events under `Every 2` (everything ≤ 6 is
  in the seeded map) versus `7` events under `Never`. Verified by an instrumented journal-read
  counter; or, as a weaker proof, `loadWorkflowSnapshot` returns `Just (m, StreamVersion 6)`
  so replay starts at 6 not 0.
- **(c) Correctness.** A workflow run under `Never` and the same workflow run under `Every k`
  produce identical `WorkflowOutcome` results and identical journals (decoded with
  `workflowJournalCodec`), and the map seeded from the snapshot equals the map from a full
  version-0 replay.
- **(d) Advisory fallback.** Corrupting the snapshot's `regfile_shape_hash` (discriminant
  mismatch) or its `state` JSON (decode failure) leaves the workflow hydrating correctly via
  full replay, returning the right `Completed` result. Verified with `corruptSnapshotShapeStmt`
  and a state-corruption statement.

These prove the change is effective beyond compilation: a real `keiro_snapshots` row is
written, a real read is shortened, the result is provably unchanged, and a tampered snapshot
is provably harmless. Capture the green `describe "Keiro.Workflow snapshots"` transcript in
this section's final revision as evidence.


## Idempotence and Recovery


Every step here is safe to repeat. Source edits are idempotent. The plan adds no migration, so
there is nothing to apply or roll back at the schema level; the `keiro_snapshots` table is
EP-4's and is already in `allKeiroMigrations`.

The snapshot WRITE is idempotent and order-safe by construction: `writeSnapshotRow`'s upsert
(`Snapshot/Schema.hs`) only takes effect when the incoming `stream_version` is at least the
stored one (`... WHERE keiro_snapshots.stream_version <= EXCLUDED.stream_version`), so a re-run
that re-fires the policy at an already-snapshotted version is a no-op, and an out-of-order or
stale write can never regress the snapshot. A re-run of a workflow re-evaluates the policy on
each step but only ever advances or leaves the snapshot version unchanged.

The snapshot READ is advisory: a missing stream id, a non-matching discriminant, or
undecodable JSON all collapse to `Nothing` in `loadWorkflowSnapshot`, and the runtime falls
back to a full version-0 replay — never an error. So a corrupt snapshot degrades performance
at worst, never correctness. If a snapshot is ever suspected bad operationally, deleting its
row (`DELETE FROM keiro_snapshots WHERE stream_id = ...`) is safe and simply forces the next
run to full-replay and (if the policy fires) re-snapshot.

If a test leaves a workflow journal or snapshot behind, the suite-level template-database
fixture gives each example a fresh database, so there is nothing to clean up by hand.


## Interfaces and Dependencies


Libraries and modules used and why: `aeson` (`toJSON`/`fromJSON` for the `Map Text Value`
codec), `containers` (`Map`), `Keiro.EventStream` (`StateCodec`, `SnapshotPolicy`),
`Keiro.Snapshot` / `Keiro.Snapshot.Schema` (`writeSnapshot`, `lookupSnapshot`, `SnapshotRow`),
`Keiro.Snapshot.Policy` (`shouldSnapshot`), kiroku's `Store` effect with
`Kiroku.Store.Read.lookupStreamId` and `Kiroku.Store.Types.AppendResult`/`StreamId`/
`StreamVersion`/`StreamName`, and EP-38's `Keiro.Workflow` / `Keiro.Workflow.Types`.

Types, signatures, and modules that must exist at the end of this plan — the contracts
downstream plans and the MasterPlan consume:

```haskell
-- Keiro.Workflow.Snapshot  (NEW module this plan owns)
workflowStateCodec         :: StateCodec WorkflowState            -- WorkflowState = Map Text Value
workflowStateCodecVersion  :: Int                                 -- 1
workflowStateShapeHash     :: Text                                -- "keiro.workflow.stepmap.v1" (fixed sentinel)
writeWorkflowSnapshot      :: (Store :> es) => StreamId -> StreamVersion -> WorkflowState -> Eff es ()
loadWorkflowSnapshot       :: (Store :> es) => StreamName -> Eff es (Maybe (WorkflowState, StreamVersion))

-- Keiro.Workflow  (ADDED to EP-38's surface by this plan)
data WorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy :: SnapshotPolicy WorkflowState
  , pageSize       :: Int32
  }
defaultWorkflowRunOptions :: WorkflowRunOptions                   -- snapshotPolicy = Never
runWorkflowWith :: (IOE :> es, Store :> es)
                => WorkflowRunOptions -> WorkflowName -> WorkflowId
                -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
runWorkflow     = runWorkflowWith defaultWorkflowRunOptions       -- EP-38's surface, now an alias
```

**Cross-plan contracts this plan introduces — record these in the MasterPlan.**

- **`runWorkflowWith` / `WorkflowRunOptions` is an ADDITION to EP-38's surface and the
  canonical home for per-run options.** EP-38 shipped only `runWorkflow` with no options
  record; this plan introduces `WorkflowRunOptions` (first field `snapshotPolicy ::
  SnapshotPolicy WorkflowState`) and `runWorkflowWith`, and reduces `runWorkflow` to
  `runWorkflowWith defaultWorkflowRunOptions` so every existing call site is unchanged. The
  record is deliberately the extension point the rest of the MasterPlan needs: **EP-44
  (telemetry) should add its `Maybe KeiroMetrics` / `Maybe Tracer` fields here** rather than
  inventing a parallel options record, and **EP-42 (resume worker) passes its own
  `WorkflowRunOptions` when re-invoking a workflow** so a resumed workflow keeps snapshotting.
  Extend the record additively; do not break the field set. The MasterPlan's Surprises &
  Discoveries and the EP-38 plan text should both note this addition.
- **`workflowStateCodec` is the workflow snapshot discriminant.** Its `stateCodecVersion = 1`
  and the fixed sentinel `shapeHash = "keiro.workflow.stepmap.v1"` are the discriminant
  `keiro_snapshots` rows for workflow journals are tagged with. EP-45's snapshot guidance must
  cite this sentinel (the MasterPlan's "Snapshot machinery (EP-41)" integration point asks
  EP-41 to record the chosen discriminant). Per-step result-type evolution remains each step's
  own `ToJSON`/`FromJSON` concern, surfaced at EP-38's step decode, **not** by this shape hash.

This plan introduces **no** new database table and **no** new migration (it reuses EP-4's
`keiro_snapshots`), so it adds nothing to `Keiro.Migrations.allKeiroMigrations` and the EP-34
`embedDir` recompilation gotcha does not apply.

Every commit while implementing this plan must carry all three git trailers:

```text
MasterPlan: docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md
ExecPlan: docs/plans/41-workflow-journal-snapshots-and-step-result-compaction.md
Intention: intention_01kt6y4cb6eqz9mq48kf2xw8n1
```
