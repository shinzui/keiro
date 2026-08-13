{-# LANGUAGE TypeFamilies #-}

-- | The durable workflow runtime: the @Workflow@ effect, named-step
-- journaling, replay, and suspension.
--
-- == What this gives you
--
-- Write a long-running process as an ordinary @effectful@ computation and run
-- it with 'runWorkflow'. Each @'step' name action@ either runs @action@ and
-- records ("journals") its result, or — on a replay after a crash — returns the
-- previously recorded result /without/ re-running the side effect. The journal
-- is a kiroku stream named @wf:\<name\>-\<id\>@ ('workflowStreamName'); there is
-- no separate history table. Because a workflow can pause (waiting for a timer,
-- an external signal, or a child), 'runWorkflow' returns a 'WorkflowOutcome'
-- ('Completed' or 'Suspended').
--
-- Step side effects are at-least-once across process crashes. If the process
-- crashes after @action@ runs but before the journal append commits, a later
-- resume has no record of that step and runs @action@ again. Step bodies that call
-- external systems must therefore be idempotent, typically by deriving an
-- idempotency key from the workflow identity and step name and passing it to the
-- external system.
--
-- Replay is keyed by step name, not by source position or code identity. Renaming
-- a step intentionally orphans the old journal entry and runs the renamed step as
-- new work; changing the meaning of a step while keeping the same name is the
-- author's responsibility. Use 'patch' for cross-cutting workflow-body changes
-- that need an explicit old/new branch.
--
-- == Contract recap for downstream plans (the v2 MasterPlan)
--
-- * The authoring surface is the @Workflow@ effect with 'step', 'awaitStep',
--   'currentWorkflow', and 'freshOrdinal'. Add new primitives (sleep,
--   awakeable, child) as functions that go /through/ this effect so a single
--   import stays the workflow surface.
-- * 'awaitStep' is the suspension primitive every wake source builds on: it
--   returns a journaled result if present, otherwise runs an idempotent
--   /arming/ action once and suspends the run. The arming action MUST be
--   idempotent — a suspended-then-resumed workflow re-enters 'awaitStep' from
--   the top on every resume until the result is journaled, so it re-runs @arm@
--   each time (e.g. schedule a timer with a deterministic id so repeats
--   collapse to a no-op).
-- * A wake source's external completion path (a timer firing,
--   @signalAwakeable@, a child finishing) calls 'appendJournalEntry' (or
--   'appendJournalEntryReturningId') with a 'StepRecorded' whose @stepName@ is
--   the awaited step name; the next 'runWorkflow' then takes the 'awaitStep'
--   hit path and proceeds.
-- * The journal codec ('workflowJournalCodec') and the reserved step-name
--   prefixes ('sleepStepPrefix' = @"sleep:"@, 'awakeableStepPrefix' = @"awk:"@,
--   'childStepPrefix' = @"child:"@) are integration contracts: suspensions are
--   journaled as ordinary 'StepRecorded' events with these prefixes, never as
--   new event types, so the replay loop stays uniform.
-- * Per-run options live in one record, 'WorkflowRunOptions' (EP-41 adds a
--   snapshot policy, EP-44 adds metrics/tracer); 'runWorkflowWith' is the
--   single canonical entry EP-42's resume worker re-invokes through.
-- * The derived @keiro_workflows@ instance row is maintained by journal append
--   transactions. Terminal markers ('WorkflowCompleted', 'WorkflowCancelled',
--   'WorkflowFailed') freeze the instance as completed/cancelled/failed, and the
--   resume worker uses its attempt/lease fields for crash recovery.
-- * Discovery (EP-42) is 'findUnfinishedWorkflowIds' plus 'completedStepName';
--   it needs no kiroku prefix subscription.
--
-- == Writing a custom wake source
--
-- The three built-in wake sources — sleep timers ("Keiro.Workflow.Sleep"),
-- awakeables ("Keiro.Workflow.Awakeable"), and child workflows
-- ("Keiro.Workflow.Child") — are not privileged. Anything can resolve an
-- 'awaitStep' by appending a 'StepRecorded' under the awaited step name. What
-- makes the built-ins /correct/ is a property the append helper cannot give
-- you, so a source built on 'appendJournalEntry' alone is not safe. Three
-- obligations:
--
-- 1. __Keep a durable row keyed by the logical workflow, not by a generation.__
--    Each built-in has one: the @keiro_timers@ row, the @keiro_awakeables@ row,
--    the @keiro_workflow_children@ row. The row — not the journal — is the
--    authority on whether the wake is pending, resolved, or abandoned, and it
--    must outlive a 'continueAsNew' rotation. See
--    @docs\/adr\/0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md@.
--
-- 2. __Deliver by appending under the awaited step name, and expect to lose a
--    rotation race.__ 'appendJournalEntry' resolves the current generation with
--    its own query and then appends in a separate transaction. A 'continueAsNew'
--    committing between the two strands your completion on the closed
--    generation, and the step-index fallback deliberately does not let a closed
--    generation resolve a live one
--    (@docs\/adr\/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md@).
--    An append may also be declined outright as 'JournalRefusedTerminal' when
--    the workflow has gone terminal; that is not an error — settle your own
--    durable row and deliver nothing.
--
-- 3. __Re-check the row from the arm, and re-deliver.__ This is what makes (2)
--    harmless. The arming action runs again on every resume until the awaited
--    result is journaled, so an arm that reads its durable row and re-appends an
--    already-resolved result repairs a stranded delivery onto whatever
--    generation is now current. An arm that only ever /schedules/ leaves the
--    rotation race unrepaired.
--
-- Since exact discovery
-- (@docs\/adr\/0023-workflow-discovery-is-exact-and-the-instance-row-is-the-complete-wake-ledger.md@)
-- there is a fourth obligation, and it is the one that strands a workflow
-- permanently if you skip it: __every lifecycle transition of your durable row
-- must leave the owning @keiro_workflows@ instance row discoverable, in the same
-- transaction that performs the transition.__ Delivering through
-- 'appendJournalEntry' satisfies this for free (the append transaction upserts
-- the row to @running@). A transition that appends nothing — abandoning a
-- pending wake, say, the way 'Keiro.Workflow.Awakeable.cancelAwakeable' does —
-- must write the instance row itself, or the workflow will never be re-examined
-- and will never observe the abandonment.
--
-- > __Build gotcha__ (EP-38's migration adds @keiro_workflow_steps@): adding a
-- > new @.sql@ file under @keiro-migrations/sql-migrations/@ does not trigger
-- > recompilation of @Keiro.Migrations@ (cabal says "Up to date" even with
-- > @-fforce-recomp@, because @embedDir@ is a Template Haskell directory read
-- > GHC's recompilation checker does not track per-file). After adding a
-- > migration, edit a comment in @keiro-migrations/src/Keiro/Migrations.hs@ or
-- > run @cabal clean@ before building.
module Keiro.Workflow
  ( -- * The effect and authoring surface
    Workflow,
    step,
    awaitStep,
    currentWorkflow,
    currentRunGeneration,
    freshOrdinal,
    continueAsNew,
    restoreSeed,
    patch,

    -- * Running a workflow
    runWorkflow,
    runWorkflowWith,
    WorkflowRunOptions (..),
    LeaseHeartbeat (..),
    defaultWorkflowRunOptions,

    -- * Journal append helpers (used by wake-source plans)
    JournalAppendOutcome (..),
    prepareJournalAppend,
    appendJournalEntry,
    appendJournalEntryReturningId,
    deterministicJournalId,

    -- * Errors thrown by the runtime
    WorkflowLeaseLost (..),

    -- * Re-exported core contracts
    module Keiro.Workflow.Types,
    WorkflowStepRow (..),
    recordStepTx,
    loadStepIndex,
    stepExists,
    currentGeneration,
    findUnfinishedWorkflowIds,
    WorkflowStatus (..),
    WorkflowInstanceRow (..),
    WorkflowInstanceFilter (..),
    defaultWorkflowInstanceFilter,
    listWorkflowInstances,
    CancelWorkflowOutcome (..),
    cancelWorkflow,
    forceReleaseInstanceLease,
    setWorkflowWakeAfterTx,
    clearWorkflowWakeAfterTx,
  )
where

import Control.Exception (Exception)
import Data.Aeson qualified as Aeson
import Data.IORef
  ( IORef,
    atomicModifyIORef',
    newIORef,
    readIORef,
  )
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (EffectHandler, interpret, localSeqUnlift, send)
import Effectful.Error.Static (Error, tryError)
import Effectful.Exception (bracket_, catch, throwIO)
import Keiro.Codec (decodeRecorded)
import Keiro.EventStream (SnapshotPolicy (..), Terminality (..))
import Keiro.Prelude
import Keiro.Snapshot (SnapshotMissReason (..))
import Keiro.Snapshot.Policy (shouldSnapshot)
import Keiro.Telemetry
  ( KeiroMetrics,
    Tracer,
    recordSnapshotDecodeFailures,
    recordSnapshotReadHits,
    recordSnapshotReadMisses,
    recordSnapshotWriteFailures,
    recordWorkflowActive,
    recordWorkflowJournalLength,
    recordWorkflowStepExecuted,
    recordWorkflowStepReplayed,
    withWorkflowSpan,
  )
import Keiro.Workflow.Instance
  ( CancelWorkflowOutcome (..),
    WorkflowInstanceFilter (..),
    WorkflowInstanceRow (..),
    WorkflowStatus (..),
    cancelWorkflow,
    defaultWorkflowInstanceFilter,
    forceReleaseInstanceLease,
    listWorkflowInstances,
    markInstanceSuspendedAwaiting,
    renewInstanceLease,
  )
import Keiro.Workflow.Journal
  ( JournalAppendOutcome (..),
    appendJournal,
    appendJournalEntry,
    appendJournalEntryReturningId,
    deterministicJournalId,
    prepareJournalAppend,
  )
import Keiro.Workflow.Schema (WorkflowStepRow (..), clearWorkflowWakeAfterTx, currentGeneration, findUnfinishedWorkflowIds, loadStepIndex, lookupStepResult, recordStepTx, setWorkflowWakeAfterTx, stepExists, terminalMarkers)
import Keiro.Workflow.Snapshot (lookupWorkflowSnapshot, writeWorkflowSnapshot)
import Keiro.Workflow.Types
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForwardStream)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (StreamId, StreamVersion (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly
import System.IO.Unsafe (unsafePerformIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- ---------------------------------------------------------------------------
-- The effect
-- ---------------------------------------------------------------------------

-- | The durable workflow effect. Its operations are interpreted by
-- 'runWorkflow' / 'runWorkflowWith', which journal and replay them.
data Workflow :: Effect where
  -- | Run a side-effecting action under a name, journaling its result; on
  --     replay, return the recorded result without re-running the action.
  Step :: (Aeson.ToJSON a, Aeson.FromJSON a) => StepName -> m a -> Workflow m a
  -- | Return the awaited step's journaled result, or run the (idempotent)
  --     arming action once and suspend the run.
  Await :: (Aeson.FromJSON a) => StepName -> m () -> Workflow m a
  -- | The running workflow's identity (for keying wake sources).
  CurrentWorkflow :: Workflow m (WorkflowName, WorkflowId)
  -- | The journal generation this run is operating on.
  CurrentRunGeneration :: Workflow m Int
  -- | A per-run, per-namespace counter for deterministic ordinal step names.
  FreshOrdinal :: Text -> Workflow m Int
  -- | EP-48: snapshot the carried seed, rotate onto a fresh journal generation,
  --     and unwind this run; the next run/resume continues from the seed. Never
  --     returns to the caller within this run (result type is fully polymorphic).
  ContinueAsNew :: (Aeson.ToJSON s) => s -> Workflow m a
  -- | EP-49: decide and journal a cross-cutting branch — returns the stable
  --     'Bool' branch decision for the given patch. Fresh instances get 'True'
  --     (new branch); instances already in flight when the patch shipped get
  --     'False' (old branch). The decision is journaled on first encounter and
  --     replayed verbatim thereafter.
  Patch :: PatchId -> Workflow m Bool

type instance DispatchOf Workflow = Dynamic

-- | Run @action@ under @name@, journaling its encoded result. On a replay where
-- @name@ is already journaled, the recorded result is returned and @action@ is
-- not run. If the process crashed after @action@ ran but before the journal
-- commit, the action runs again on resume: workflow step side effects are
-- at-least-once at the step boundary.
--
-- The returned value is always the JSON round-trip of the recorded result,
-- including on the first run. A lossy or rejecting @ToJSON@\/@FromJSON@ pair is
-- therefore observed immediately rather than only after a crash and replay.
--
-- Requires @'Aeson.ToJSON' a@ (to journal the result) and @'Aeson.FromJSON' a@
-- (to decode it on replay).
step :: (Workflow :> es, Aeson.ToJSON a, Aeson.FromJSON a) => StepName -> Eff es a -> Eff es a
step name action = send (Step name action)

-- | Look up @name@ in the journal. If a wake source has already recorded its
-- completion (a 'StepRecorded' whose @stepName@ is @name@, carrying the
-- resolved result), decode and return it. Otherwise run @arm@ exactly once
-- (the wake source's idempotent job — schedule a timer, register an awakeable,
-- spawn a child) and __suspend__ this run, so 'runWorkflow' returns 'Suspended'.
--
-- @arm@ must be idempotent: every resume re-runs it until the result is
-- journaled.
awaitStep :: (Workflow :> es, Aeson.FromJSON a) => StepName -> Eff es () -> Eff es a
awaitStep name arm = send (Await name arm)

-- | The identity of the workflow currently running.
currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)
currentWorkflow = send CurrentWorkflow

-- | The journal generation this run is operating on. Wake sources include it
-- in their durable identities so a generation opened by 'continueAsNew' never
-- collides with prior-generation rows.
currentRunGeneration :: (Workflow :> es) => Eff es Int
currentRunGeneration = send CurrentRunGeneration

-- | A per-run, per-namespace counter (starting at 0). Used by convenience
-- forms of wake sources (e.g. @sleep@ → @"sleep:0"@) to derive a deterministic,
-- replay-stable ordinal name. Note: ordinal names are only stable if the order
-- of @awaitStep@-style calls does not change across deploys; the named forms
-- are the stable primitives.
freshOrdinal :: (Workflow :> es) => Text -> Eff es Int
freshOrdinal namespace = send (FreshOrdinal namespace)

-- | Continue this workflow /as new/ (EP-48): snapshot the carried @seed@ onto a
-- fresh journal generation, journal a terminal rotation marker on the current
-- generation, and unwind this run. The next run or resume of the same logical
-- @('WorkflowName', 'WorkflowId')@ starts against the fresh generation, hydrated
-- from the seed, with an empty (bounded) journal.
--
-- This is how a workflow that runs an /unbounded/ number of steps — a poller, a
-- per-day rolling process — keeps its per-generation journal bounded so replay
-- and hydration stay fast forever. The result type is fully polymorphic (@a@)
-- because control never returns to the caller within /this/ run: the rotated
-- continuation runs in the next run/resume. Read the carried seed back at the top
-- of the workflow body with 'restoreSeed'.
--
-- __Rotating abandons outstanding awakeables.__
-- 'Keiro.Workflow.Awakeable.awakeableNamed' journals a freshly allocated id
-- under an @awkid:\<label\>@ step and then awaits @awk:\<uuid\>@. The next
-- generation's journal has neither step, so the body re-runs the allocation and
-- hands out a __different__ id; a signal against the id you handed out before
-- rotating settles that awakeable's own row and resolves nothing the new
-- generation is waiting for. Re-notify whoever holds the promise from the
-- re-run allocation step — that step is the natural hook, and it runs exactly
-- once per generation. This mirrors 'Keiro.Workflow.Child.spawnChild', where a
-- fresh child after rotation needs a child id derived from the carried seed.
continueAsNew :: (Workflow :> es, Aeson.ToJSON s) => s -> Eff es a
continueAsNew seed = send (ContinueAsNew seed)

-- | Restore the seed carried by the previous generation's 'continueAsNew', or
-- return @def@ on the first generation (EP-48). Implemented as an ordinary
-- journaled @step@ under the reserved 'continueSeedStepName': on a generation that
-- was rotated into, the seed step was journaled (and snapshotted) by the rotation,
-- so this @step@ hits it and returns the carried value without re-running; on the
-- very first generation it misses and records @def@. Call it once at the top of a
-- workflow body that uses 'continueAsNew'.
restoreSeed :: (Workflow :> es, Aeson.ToJSON s, Aeson.FromJSON s) => s -> Eff es s
restoreSeed def = step (StepName continueSeedStepName) (pure def)

-- | Decide a cross-cutting branch for an in-flight-vs-fresh code change, and
-- journal the decision so every later replay observes the same branch (EP-49).
--
-- @patch (PatchId "fraud-check-v2")@ returns 'True' only when that id was present
-- in 'activePatches' when this workflow generation first started. The generation
-- records its active set under 'patchSetStepName' exactly once; on the first
-- encounter each individual patch decision is journaled under @patch:\<patchId\>@,
-- and every replay returns the recorded 'Bool'. Add a patch id to 'activePatches'
-- in the deploy that introduces the corresponding 'patch' call; remove it only
-- after deleting that call from the workflow body.
--
-- This is an /escape hatch/ for changes that cross-cut multiple steps. For the
-- common case — one step changed — do __not__ use 'patch': rename the step's
-- 'StepName' instead. A renamed step has no journaled history under its new name,
-- so its action runs fresh on the next replay, which is exactly the right
-- behaviour for a single-step change. Reach for 'patch' only when an in-flight
-- instance would be left incoherent by the new code (e.g. the change adds, removes,
-- or reorders steps, or changes the meaning of an already-journaled step result).
patch :: (Workflow :> es) => PatchId -> Eff es Bool
patch pid = send (Patch pid)

-- ---------------------------------------------------------------------------
-- Per-run options
-- ---------------------------------------------------------------------------

-- | Lease renewal coordinates for a resume-worker-owned workflow run.
--
-- The runtime renews this lease immediately before each fresh step action and
-- unresolved await arm. Direct 'runWorkflow' calls leave it 'Nothing'.
data LeaseHeartbeat = LeaseHeartbeat
  { owner :: !Text,
    ttl :: !NominalDiffTime
  }
  deriving stock (Generic, Eq, Show)

-- | Options for a single workflow run. This is the canonical home for
-- per-run options across the v2 initiative — EP-41 adds the snapshot policy,
-- EP-44 adds metrics/tracer fields, all additive. Extend it additively; never
-- break the field set EP-38/EP-41 established.
data WorkflowRunOptions = WorkflowRunOptions
  { -- | When to persist a snapshot of the accumulated step-result map after a
    --     step append (and at completion, for 'OnTerminal'). Default 'Never'
    --     (EP-38 behaviour: every run/resume does a full version-0 replay).
    snapshotPolicy :: !(SnapshotPolicy WorkflowState),
    -- | Page size for the journal pre-load read.
    pageSize :: !Int32,
    -- | EP-44: when 'Just', the runtime records the @keiro.workflow.*@ instruments
    --     (steps executed/replayed, active count, journal length). 'Nothing' is the
    --     no-op default, so a run with 'defaultWorkflowRunOptions' records nothing.
    metrics :: !(Maybe KeiroMetrics),
    -- | EP-44: when 'Just', the runtime opens a @workflow \<name\>@ 'Internal' span
    --     around the run. 'Nothing' runs the body unwrapped.
    tracer :: !(Maybe Tracer),
    -- | Patch ids currently active in this deployed workflow code. A fresh
    --     workflow generation records this set once under 'patchSetStepName', and
    --     each 'patch' call returns 'True' iff its id was in that recorded set.
    activePatches :: !(Set PatchId),
    -- | Resume-worker lease coordinates. When present, fresh workflow
    --     boundaries renew the lease and throw 'WorkflowLeaseLost' if another owner
    --     has taken it. 'Nothing' keeps direct runs free of lease traffic.
    leaseHeartbeat :: !(Maybe LeaseHeartbeat),
    -- | When 'Just', invoked for every fresh journal-append boundary this run
    --     commits: an executed step, a patch decision, the patch-set record, the
    --     completion marker, or a generation rotation. Replays, idempotent
    --     re-appends, refused appends, and wake-source writes that touch no
    --     journal do not fire it. The resume worker uses this witness to count
    --     durable movement per candidate. 'Nothing' observes nothing.
    onJournalAppend :: !(Maybe (IO ()))
  }
  deriving stock (Generic)

-- | Sensible defaults: no snapshotting, a journal pre-load page size of 100,
-- and no telemetry (metrics/tracer 'Nothing'). A default-options run replays
-- and behaves exactly as EP-38 did.
defaultWorkflowRunOptions :: WorkflowRunOptions
defaultWorkflowRunOptions =
  WorkflowRunOptions
    { snapshotPolicy = Never,
      pageSize = 100,
      metrics = Nothing,
      tracer = Nothing,
      activePatches = Set.empty,
      leaseHeartbeat = Nothing,
      onJournalAppend = Nothing
    }

-- ---------------------------------------------------------------------------
-- Errors and the suspension sentinel
-- ---------------------------------------------------------------------------

-- | The resume worker no longer owns the workflow instance lease.
--
-- Thrown before a fresh step action or unresolved await arm, so the run stops
-- before performing further side effects. Resume workers classify this as a
-- lease skip rather than a workflow crash.
data WorkflowLeaseLost = WorkflowLeaseLost
  deriving stock (Eq, Show)

instance Exception WorkflowLeaseLost

-- | Internal sentinel thrown to unwind a suspended run up to 'runWorkflowWith',
-- carrying the step name the run parked on. The run entry point needs that name
-- to arbitrate its suspended-status write against a wake delivery for the same
-- step (see 'Keiro.Workflow.Instance.markInstanceSuspendedAwaiting').
newtype WorkflowSuspend = WorkflowSuspend Text
  deriving stock (Show)

instance Exception WorkflowSuspend

-- | How one interpreted run finished, before its outcome is finalized.
--
-- A suspension is kept distinct from the other outcomes because it carries the
-- awaited step name the suspended-status write needs; every other unwinding
-- already resolves to a 'WorkflowOutcome'.
data RunUnwind a
  = RunOutcome !(WorkflowOutcome a)
  | RunSuspendedOn !Text

-- | Internal sentinel thrown when a cancellation marker appears mid-run.
data WorkflowCancelPending = WorkflowCancelPending
  deriving stock (Show)

instance Exception WorkflowCancelPending

-- | Internal sentinel thrown when a terminal failure marker appears mid-run.
--
-- The failure counterpart of 'WorkflowCancelPending'. The resume worker writes
-- 'WorkflowFailed' when a workflow exhausts its crash attempts, and that can
-- land while another runner — typically a direct 'runWorkflow' call, which takes
-- no lease — is between steps. Without this the run would keep executing fresh
-- side effects past its own terminal failure.
data WorkflowFailPending = WorkflowFailPending
  deriving stock (Show)

instance Exception WorkflowFailPending

-- | Internal sentinel thrown by the 'ContinueAsNew' handler to unwind a
-- rotating run up to 'runWorkflowWith' (EP-48), carrying the JSON-encoded seed for
-- the next generation. Mirrors 'WorkflowSuspend': a non-returning unwind the run
-- entry point catches and turns into an outcome ('ContinuedAsNew').
newtype WorkflowRotate = WorkflowRotate Aeson.Value
  deriving stock (Show)

instance Exception WorkflowRotate

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

-- | Process-wide count of workflow runs currently in flight, backing the
-- @keiro.workflow.active@ gauge (EP-44). 'runWorkflowWith' brackets each run with
-- @+1@/@-1@ and samples the gauge on both edges, so the exported last-value
-- reflects the true live count whether a run is mid-flight or finished. A
-- process-global 'IORef' is the lightest faithful implementation (the gauge is a
-- last-value-wins level, not a per-run delta), mirroring how the other keiro
-- backlog/level gauges are recorded with a value the runtime already holds.
{-# NOINLINE activeCountRef #-}
activeCountRef :: IORef Int64
activeCountRef = unsafePerformIO (newIORef 0)

-- | Run a workflow computation, journaling each 'step' and replaying any
-- already-journaled steps. Returns 'Completed' when the computation finishes
-- (a 'WorkflowCompleted' marker is journaled) or 'Suspended' when it pauses at
-- an unresolved 'awaitStep'.
--
-- Equivalent to @'runWorkflowWith' 'defaultWorkflowRunOptions'@.
runWorkflow ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowName ->
  WorkflowId ->
  Eff (Workflow : es) a ->
  Eff es (WorkflowOutcome a)
runWorkflow = runWorkflowWith defaultWorkflowRunOptions

-- | 'runWorkflow' with explicit 'WorkflowRunOptions'. This is the single
-- canonical run entry point; EP-42's resume worker re-invokes through it so
-- resumed runs honor the same options.
--
-- If the workflow's journal already carries a 'WorkflowCancelled' marker (a child
-- cancelled by its parent, EP-43), the run short-circuits immediately and returns
-- 'Cancelled' without executing any step. The handler also re-checks that marker
-- on step/await/patch miss paths and after a fresh step action returns, so a
-- mid-run cancellation stops at the next workflow boundary. A cancellation that
-- lands after the check but before/during the user action may still let that one
-- action run; durable workflow steps remain at-least-once at boundaries. If the
-- journal carries a 'WorkflowFailed' marker, the run likewise short-circuits to
-- 'Failed'. To /propagate/ a finished child's result to its parent, drive the
-- child through 'Keiro.Workflow.Child.runChildWorkflow' rather than this function
-- directly.
runWorkflowWith ::
  forall a es.
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowRunOptions ->
  WorkflowName ->
  WorkflowId ->
  Eff (Workflow : es) a ->
  Eff es (WorkflowOutcome a)
runWorkflowWith options name wid action = do
  -- EP-48: resolve the CURRENT (highest) generation once per run and operate
  -- only on it. A never-rotating workflow stays at generation 0, so naming,
  -- load, and append are byte-for-byte as before. A rotated workflow resolves
  -- to its newest generation, so discovery/resume transparently continue there.
  gen <- currentGeneration name wid
  -- Terminal short-circuit (EP-43): a workflow whose journal carries a
  -- WorkflowCancelled or WorkflowFailed marker makes no further progress. Both
  -- markers are index rows on the current generation, so one query answers for
  -- both and we never run the user action. Cancellation takes precedence when
  -- somehow both are present.
  markers <- terminalMarkers name wid gen
  case (cancelledStepName `elem` markers, failedStepName `elem` markers) of
    (True, _) -> pure Cancelled
    (_, True) -> pure Failed
    _ -> runActive gen
  where
    -- EP-44 telemetry handles, pulled from the run options once. Both default
    -- to 'Nothing' (see 'defaultWorkflowRunOptions'), so a default-options run
    -- records nothing and opens no span — the no-op idiom holds end to end.
    mMetrics = options ^. #metrics
    mTracer = options ^. #tracer
    fireAppendWitness = for_ (options ^. #onJournalAppend) liftIO
    runActive :: Int -> Eff es (WorkflowOutcome a)
    runActive gen =
      -- EP-44: maintain the process-wide live-run count and sample the
      -- @keiro.workflow.active@ gauge on both entry and exit, and open the
      -- whole-run @workflow \<name\>@ span (step 'Nothing'). The body is
      -- unchanged from EP-41 except for the journal-length recording below.
      bracket_
        (liftIO (atomicModifyIORef' activeCountRef (\n -> (n + 1, ()))) >> sampleActive)
        (liftIO (atomicModifyIORef' activeCountRef (\n -> (n - 1, ()))) >> sampleActive)
        (withWorkflowSpan mTracer name wid Nothing (\_sp -> interpreted))
      where
        sampleActive = liftIO (readIORef activeCountRef) >>= recordWorkflowActive mMetrics
        interpreted = do
          initial <- loadJournal options name wid gen
          initial' <- recordPatchSetIfFresh gen initial
          journalRef <- liftIO (newIORef initial')
          ordinalRef <- liftIO (newIORef Map.empty)
          let runHandler = interpret (handler gen journalRef ordinalRef) action
          unwound <-
            (RunOutcome . Completed <$> runHandler)
              `catch` (\(WorkflowSuspend awaitedStep) -> pure (RunSuspendedOn awaitedStep))
              `catch` (\WorkflowCancelPending -> pure (RunOutcome Cancelled))
              `catch` (\WorkflowFailPending -> pure (RunOutcome Failed))
              `catch` ( \(WorkflowRotate seedJson) ->
                          RunOutcome
                            <$> rotateGeneration
                              options
                              name
                              wid
                              gen
                              seedJson
                      )
          case unwound of
            -- The run parked on an unresolved await. The status write arbitrates
            -- against a wake delivery for that same step under the append path's
            -- advisory lock, so a wake landing in this gap cannot be masked by a
            -- 'suspended' status that exact discovery would never return.
            RunSuspendedOn awaitedStep -> do
              markInstanceSuspendedAwaiting name wid gen awaitedStep
              pure Suspended
            RunOutcome outcome -> case outcome of
              Completed result -> do
                now <- liftIO getCurrentTime
                finalMap <- liftIO (readIORef journalRef)
                -- Idempotent: only appends (and so only snapshots) when the completion
                -- marker is not already journaled. On a replay of an already-completed
                -- workflow this is 'JournalAlreadyPresent' and no terminal snapshot is
                -- taken (one was already taken on the original completing run, if the
                -- policy fired).
                appendCompletion name wid gen now >>= \case
                  JournalAppended appendResult -> do
                    fireAppendWitness
                    when
                      ( shouldSnapshot
                          (options ^. #snapshotPolicy)
                          Terminal
                          finalMap
                          (appendResult ^. #streamVersion)
                      )
                      (writeWorkflowSnapshotAdvisory mMetrics (appendResult ^. #streamId) (appendResult ^. #streamVersion) finalMap)
                    recordCompletedLength finalMap
                    pure (Completed result)
                  JournalAlreadyPresent {} -> do
                    recordCompletedLength finalMap
                    pure (Completed result)
                  JournalRefusedTerminal marker
                    | marker == cancelledStepName -> pure Cancelled
                    | marker == failedStepName -> pure Failed
                    | marker == continuedAsNewStepName -> pure ContinuedAsNew
                    | otherwise ->
                        throwIO
                          (WorkflowJournalAppendError ("completion refused by terminal marker " <> marker))
                  JournalAppendConflict err ->
                    throwIO (WorkflowJournalAppendError (Text.pack (show err)))
              -- Only 'RunSuspendedOn' produces a suspension, so this arm is
              -- unreachable; it keeps the case total without a partial match.
              Suspended -> pure Suspended
              Cancelled -> pure Cancelled
              Failed -> pure Failed
              -- EP-48: the run unwound via 'WorkflowRotate'; 'rotateGeneration'
              -- already journaled the seed step on the next generation and the
              -- rotation marker on this one, so there is nothing more to do here.
              ContinuedAsNew -> pure ContinuedAsNew
        -- Generation 0 has no rotation moment at which to record the patch set,
        -- so it retains the fresh-journal path. Rotated generations receive the
        -- set atomically with their seed in 'rotateGeneration'; this fallback
        -- also keeps generations produced by a pre-change worker compatible.
        recordPatchSetIfFresh runGen initial = do
          let patches = options ^. #activePatches
              freshStart = Map.keysSet initial `Set.isSubsetOf` Set.singleton continueSeedStepName
          if freshStart && not (Set.null patches)
            then do
              let encoded = Aeson.toJSON (map unPatchId (Set.toList patches))
              now <- liftIO getCurrentTime
              appendJournal name wid runGen (StepRecorded patchSetStepName encoded now) >>= \case
                JournalAppended {} -> do
                  fireAppendWitness
                  pure (Map.insert patchSetStepName encoded initial)
                JournalAlreadyPresent stored -> pure (Map.insert patchSetStepName stored initial)
                -- This runs only on a fresh journal, which by definition carries
                -- no terminal marker, so a refusal is an invariant violation
                -- rather than a state the caller should absorb.
                JournalRefusedTerminal marker ->
                  throwIO (WorkflowJournalAppendError ("patch set refused by terminal marker " <> marker))
                JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))
            else pure initial
        -- EP-44: one journal-length observation per genuinely completed run,
        -- including an idempotent replay. A run that loses the lifecycle race
        -- to cancellation/failure/rotation reports that winner instead.
        recordCompletedLength finalMap =
          recordWorkflowJournalLength
            mMetrics
            (fromIntegral (Map.size finalMap + 1))
    handler ::
      Int ->
      IORef (Map Text Aeson.Value) ->
      IORef (Map Text Int) ->
      EffectHandler Workflow es
    handler gen journalRef ordinalRef env operation = case operation of
      Step (StepName key) act -> do
        journal <- liftIO (readIORef journalRef)
        case Map.lookup key journal of
          Just stored -> do
            -- Hit: the step is already journaled, so its recorded result is
            -- returned without re-running @act@ — a replay.
            recordWorkflowStepReplayed mMetrics 1
            decodeStored key stored
          Nothing -> do
            renewLease
            -- One probe before the side effect; the append transaction re-checks
            -- both markers at commit, so no separate post-action query is needed.
            checkTerminalPending name wid gen
            a <- localSeqUnlift env (\unlift -> unlift act)
            let encoded = Aeson.toJSON a
            now <- liftIO getCurrentTime
            appendOutcome <- appendJournal name wid gen (StepRecorded key encoded now)
            case appendOutcome of
              JournalAppended appendResult -> do
                -- Miss: @act@ ran and was journaled — a fresh execution.
                fireAppendWitness
                recordWorkflowStepExecuted mMetrics 1
                newMap <-
                  liftIO
                    ( atomicModifyIORef' journalRef $ \m ->
                        let m' = Map.insert key encoded m in (m', m')
                    )
                -- Evaluate the snapshot policy on the post-append map and version;
                -- a step is never the terminal marker, hence @False@.
                when
                  ( shouldSnapshot
                      (options ^. #snapshotPolicy)
                      NotTerminal
                      newMap
                      (appendResult ^. #streamVersion)
                  )
                  (writeWorkflowSnapshotAdvisory mMetrics (appendResult ^. #streamId) (appendResult ^. #streamVersion) newMap)
                decodeStored key encoded
              JournalAlreadyPresent stored -> do
                liftIO
                  ( atomicModifyIORef' journalRef $ \m ->
                      (Map.insert key stored m, ())
                  )
                decodeStored key stored
              -- The workflow went terminal while @act@ was running: the append
              -- declined, so the step's result is not journaled and the run
              -- unwinds to Cancelled/Failed at this boundary. The action itself
              -- already ran — step side effects are at-least-once at boundaries.
              JournalRefusedTerminal marker -> throwForMarker marker
              JournalAppendConflict err ->
                throwIO (WorkflowJournalAppendError (Text.pack (show err)))
      Await (StepName key) arm -> do
        journal <- liftIO (readIORef journalRef)
        case Map.lookup key journal of
          Just stored -> do
            -- An awaitStep hit means the wake source already resolved this step;
            -- the recorded result is returned without arming — a replay. An
            -- awaitStep miss arms and suspends: no user @action@ ran, so it is
            -- not a step execution and records nothing here.
            recordWorkflowStepReplayed mMetrics 1
            decodeStored key stored
          Nothing ->
            -- The in-memory map can omit a wake completion journaled
            -- while a snapshotting run was mid-flight. The step index
            -- is written transactionally with every append, so consult
            -- it before arming and suspending.
            lookupStepResult name wid gen key >>= \case
              Just stored -> do
                liftIO
                  ( atomicModifyIORef' journalRef $ \m ->
                      (Map.insert key stored m, ())
                  )
                recordWorkflowStepReplayed mMetrics 1
                decodeStored key stored
              Nothing -> do
                renewLease
                checkTerminalPending name wid gen
                localSeqUnlift env (\unlift -> unlift arm)
                throwIO (WorkflowSuspend key)
      CurrentWorkflow -> pure (name, wid)
      CurrentRunGeneration -> pure gen
      FreshOrdinal namespace ->
        liftIO . atomicModifyIORef' ordinalRef $ \counters ->
          let n = Map.findWithDefault 0 namespace counters
           in (Map.insert namespace (n + 1) counters, n)
      -- EP-48: encode the carried seed and throw the rotation sentinel, which
      -- 'runWorkflowWith' catches and turns into 'rotateGeneration'. Never
      -- returns to the caller within this run (result type is polymorphic).
      ContinueAsNew seed -> throwIO (WorkflowRotate (Aeson.toJSON seed))
      -- EP-49: decide and journal a cross-cutting branch. Mirrors the 'Step'
      -- hit/miss shape, but the miss path computes the decision from the
      -- patch set recorded when this workflow generation first started.
      Patch pid -> do
        let key = patchStepName pid
        journal <- liftIO (readIORef journalRef)
        case Map.lookup key journal of
          Just stored ->
            -- Hit: the decision was made on an earlier run; replay it verbatim.
            decodeStored key stored
          Nothing -> do
            checkTerminalPending name wid gen
            recordedSet <- case Map.lookup patchSetStepName journal of
              Nothing -> pure []
              Just stored -> decodeStored patchSetStepName stored
            let decision = unPatchId pid `elem` (recordedSet :: [Text])
                encoded = Aeson.toJSON decision
            now <- liftIO getCurrentTime
            appendOutcome <- appendJournal name wid gen (StepRecorded key encoded now)
            case appendOutcome of
              JournalAppended {} -> do
                fireAppendWitness
                liftIO
                  ( atomicModifyIORef' journalRef $ \m ->
                      (Map.insert key encoded m, ())
                  )
                pure decision
              JournalAlreadyPresent stored -> do
                liftIO
                  ( atomicModifyIORef' journalRef $ \m ->
                      (Map.insert key stored m, ())
                  )
                decodeStored key stored
              JournalRefusedTerminal marker -> throwForMarker marker
              JournalAppendConflict err ->
                throwIO (WorkflowJournalAppendError (Text.pack (show err)))
      where
        renewLease =
          for_ (options ^. #leaseHeartbeat) $ \heartbeat -> do
            renewed <-
              renewInstanceLease
                (heartbeat ^. #owner)
                (heartbeat ^. #ttl)
                name
                wid
            unless renewed (throwIO WorkflowLeaseLost)

-- | Decode a stored journal result into the type the caller expects.
decodeStored :: (Aeson.FromJSON a) => Text -> Aeson.Value -> Eff es a
decodeStored key stored = case Aeson.fromJSON stored of
  Aeson.Success a -> pure a
  Aeson.Error message -> throwIO (WorkflowStepDecodeError key (Text.pack message))

-- | Stop the run at this boundary if the workflow has already been cancelled or
-- terminally failed.
--
-- One query for both markers, run /before/ a fresh step action or an unresolved
-- await's arm. The append transaction enforces the same rule again at commit
-- time, so this probe is not what makes the boundary safe — it is what stops the
-- user's side effect from running at all in the common already-terminal case.
checkTerminalPending :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Eff es ()
checkTerminalPending name wid gen =
  terminalMarkers name wid gen >>= traverse_ throwForMarker . listToMaybe

-- | Map a stopping marker's reserved step name to the sentinel that unwinds the
-- run into the matching outcome. Never returns.
throwForMarker :: Text -> Eff es a
throwForMarker marker
  | marker == cancelledStepName = throwIO WorkflowCancelPending
  | otherwise = throwIO WorkflowFailPending

-- | Pre-load a workflow's journal stream into a @step name -> result@ map.
--
-- If a compatible snapshot exists ('loadWorkflowSnapshot'), seed the map from it
-- and read only the journal events /after/ the snapshot's version ("tail
-- replay"). The reconstructed map is the journal state as the snapshotting run
-- saw it. A wake completion journaled concurrently with that run can fall at or
-- before the snapshot version yet be absent from the seed, so the map may
-- under-approximate the journal. The @Await@ handler compensates by consulting
-- the authoritative @keiro_workflow_steps@ index on a map miss; that index is
-- written transactionally with every journal append.
--
-- A missing, mismatched, or undecodable snapshot is recorded as a miss (and, for
-- undecodable bytes, a decode failure) before the read falls back to a full
-- replay from version 0.
-- 'WorkflowCompleted' contributes nothing to the map.
loadJournal ::
  (IOE :> es, Store :> es) =>
  WorkflowRunOptions ->
  WorkflowName ->
  WorkflowId ->
  Int ->
  Eff es (Map Text Aeson.Value)
loadJournal options name wid gen = do
  let journalName = workflowGenerationStreamName name wid gen
  snapshot <- lookupWorkflowSnapshot journalName
  (seedMap, fromVersion) <- case snapshot of
    Right (m, v) -> do
      recordSnapshotReadHits (options ^. #metrics) 1
      pure (m, v)
    Left reason -> do
      recordSnapshotReadMisses (options ^. #metrics) 1
      case reason of
        SnapshotDecodeFailed _ -> recordSnapshotDecodeFailures (options ^. #metrics) 1
        _ -> pure ()
      pure (Map.empty, StreamVersion 0)
  let events = readStreamForwardStream journalName fromVersion (options ^. #pageSize)
  Streamly.fold (Fold.foldlM' accumulate (pure seedMap)) events
  where
    accumulate journal recorded =
      case decodeRecorded workflowJournalCodec recorded of
        Right (StepRecorded key value _) -> pure (Map.insert key value journal)
        Right (WorkflowCompleted _) -> pure journal
        Right (WorkflowCancelled _) -> pure journal
        Right (WorkflowFailed _ _) -> pure journal
        Right (WorkflowContinuedAsNew _ _) -> pure journal -- a rotation marker carries no step result
        Left err -> throwIO (WorkflowJournalDecodeError (Text.pack (show err)))

-- ---------------------------------------------------------------------------
-- Journal append helpers
-- ---------------------------------------------------------------------------

-- | Attempt the completion marker append. The caller maps a lifecycle refusal
-- to the winning workflow outcome instead of reporting a spurious append error.
appendCompletion :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Int -> UTCTime -> Eff es JournalAppendOutcome
appendCompletion name wid gen now =
  appendJournal name wid gen (WorkflowCompleted now)

-- | Perform a continue-as-new rotation (EP-48): close generation @gen@ and open
-- generation @gen + 1@, seeded with @seedJson@ and the deployed patch set. Returns
-- 'ContinuedAsNew'.
--
-- The old generation's rotation marker, the next generation's seed, and its
-- non-empty patch set are appended in one transaction. The lifecycle marker is
-- attempted first under the shared generation lock, so cancellation/failure
-- either wins without exposing a new generation or loses before the seed makes
-- @currentGeneration@ advance. Every append is guarded by an existence check
-- and uses a deterministic, generation-namespaced id, so the whole rotation is
-- idempotent.
--
-- The seed carries state forward and the patch-set entry freezes code-evolution
-- decisions. We snapshot their map at the newest fresh append's version so the
-- next generation hydrates in O(1). The snapshot is advisory, so it is written
-- unconditionally on rotation regardless of the run's 'snapshotPolicy' — rotation
-- is exactly when a fresh snapshot earns its keep.
rotateGeneration ::
  forall a es.
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowRunOptions ->
  WorkflowName ->
  WorkflowId ->
  Int ->
  Aeson.Value ->
  Eff es (WorkflowOutcome a)
rotateGeneration options name wid gen seedJson = do
  let nextGen = gen + 1
      mMetrics = options ^. #metrics
      patches = options ^. #activePatches
      encodedPatches = Aeson.toJSON (map unPatchId (Set.toList patches))
      patchEvent =
        StepRecorded patchSetStepName encodedPatches
  now <- liftIO getCurrentTime
  seedTx <-
    prepareJournalAppend
      name
      wid
      nextGen
      (StepRecorded continueSeedStepName seedJson now)
  patchTx <-
    if Set.null patches
      then pure Nothing
      else
        Just
          <$> prepareJournalAppend
            name
            wid
            nextGen
            (patchEvent now)
  rotationTx <-
    prepareJournalAppend
      name
      wid
      gen
      (WorkflowContinuedAsNew nextGen now)
  -- The CURRENT generation's lifecycle winner and the NEXT generation's seed
  -- are one commit. If another lifecycle marker won, no new-generation row can
  -- leak; if rotation won, a cancellation prepared against the old generation
  -- observes the marker, retries, and follows the now-current generation.
  (rotationOutcome, maybeSeedOutcome, patchOutcome) <-
    runTransaction $ do
      rotationResult <- rotationTx
      let seedNextGeneration = do
            seedResult <- seedTx
            condemnOnConflict seedResult
            patchResult <- traverse id patchTx
            traverse_ condemnOnConflict patchResult
            pure (rotationResult, Just seedResult, patchResult)
      case rotationResult of
        JournalAppended {} -> seedNextGeneration
        JournalAlreadyPresent {} -> seedNextGeneration
        JournalRefusedTerminal {} -> pure (rotationResult, Nothing, Nothing)
        JournalAppendConflict {} -> do
          Tx.condemn
          pure (rotationResult, Nothing, Nothing)
  case rotationOutcome of
    JournalRefusedTerminal marker
      | marker == cancelledStepName -> pure Cancelled
      | marker == failedStepName -> pure Failed
      | otherwise ->
          throwIO (WorkflowJournalAppendError ("rotation refused by terminal marker " <> marker))
    JournalAppendConflict err ->
      throwIO (WorkflowJournalAppendError (Text.pack (show err)))
    _ -> case maybeSeedOutcome of
      Nothing ->
        throwIO (WorkflowJournalAppendError "rotation committed without a next-generation seed outcome")
      Just seedOutcome -> do
        throwOnConflict seedOutcome
        traverse_ throwOnConflict patchOutcome
        when
          ( journalAppended rotationOutcome
              || journalAppended seedOutcome
              || maybe False journalAppended patchOutcome
          )
          (for_ (options ^. #onJournalAppend) liftIO)
        let seedValue = recordedValue seedJson seedOutcome
            snapshotState =
              maybe
                (Map.singleton continueSeedStepName seedValue)
                ( \outcome ->
                    Map.fromList
                      [ (continueSeedStepName, seedValue),
                        (patchSetStepName, recordedValue encodedPatches outcome)
                      ]
                )
                patchOutcome
            snapshotAppend =
              case patchOutcome of
                Just (JournalAppended appendResult) -> Just appendResult
                _ -> case seedOutcome of
                  JournalAppended appendResult -> Just appendResult
                  _ -> Nothing
        for_ snapshotAppend $ \appendResult ->
          writeWorkflowSnapshotAdvisory
            mMetrics
            (appendResult ^. #streamId)
            (appendResult ^. #streamVersion)
            snapshotState
        pure ContinuedAsNew
  where
    -- The seed and patch-set appends target the NEXT generation, which is fresh
    -- and cannot carry a terminal marker, so a refusal there is an invariant
    -- violation and is treated exactly like a conflict rather than absorbed.
    condemnOnConflict = \case
      JournalAppendConflict {} -> Tx.condemn
      JournalRefusedTerminal {} -> Tx.condemn
      _ -> pure ()
    throwOnConflict = \case
      JournalAppendConflict err ->
        throwIO (WorkflowJournalAppendError (Text.pack (show err)))
      JournalRefusedTerminal marker ->
        throwIO (WorkflowJournalAppendError ("rotation seed refused by terminal marker " <> marker))
      _ -> pure ()
    recordedValue fallback = \case
      JournalAlreadyPresent stored -> stored
      _ -> fallback
    journalAppended = \case
      JournalAppended {} -> True
      _ -> False

-- | Snapshot a workflow state after its journal append has committed. The
-- snapshot is advisory: a store failure is counted and cannot turn the
-- already-durable workflow transition into a failed run.
writeWorkflowSnapshotAdvisory ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Maybe KeiroMetrics ->
  StreamId ->
  StreamVersion ->
  WorkflowState ->
  Eff es ()
writeWorkflowSnapshotAdvisory mMetrics streamId version state = do
  -- WorkflowState is already a Map Text Value assembled from journaled step
  -- results, so this path has no aggregate RegFile/uninit encode to guard.
  outcome <- tryError @StoreError (writeWorkflowSnapshot streamId version state)
  case outcome of
    Right () -> pure ()
    Left _ -> recordSnapshotWriteFailures mMetrics 1
