{-# LANGUAGE TypeFamilies #-}

{- | The durable workflow runtime: the @Workflow@ effect, named-step
journaling, replay, and suspension.

== What this gives you

Write a long-running process as an ordinary @effectful@ computation and run
it with 'runWorkflow'. Each @'step' name action@ either runs @action@ and
records ("journals") its result, or — on a replay after a crash — returns the
previously recorded result /without/ re-running the side effect. The journal
is a kiroku stream named @wf:\<name\>-\<id\>@ ('workflowStreamName'); there is
no separate history table. Because a workflow can pause (waiting for a timer,
an external signal, or a child), 'runWorkflow' returns a 'WorkflowOutcome'
('Completed' or 'Suspended').

Step side effects are at-least-once across process crashes. If the process
crashes after @action@ runs but before the journal append commits, a later
resume has no record of that step and runs @action@ again. Step bodies that call
external systems must therefore be idempotent, typically by deriving an
idempotency key from the workflow identity and step name and passing it to the
external system.

Replay is keyed by step name, not by source position or code identity. Renaming
a step intentionally orphans the old journal entry and runs the renamed step as
new work; changing the meaning of a step while keeping the same name is the
author's responsibility. Use 'patch' for cross-cutting workflow-body changes
that need an explicit old/new branch.

== Contract recap for downstream plans (the v2 MasterPlan)

* The authoring surface is the @Workflow@ effect with 'step', 'awaitStep',
  'currentWorkflow', and 'freshOrdinal'. Add new primitives (sleep,
  awakeable, child) as functions that go /through/ this effect so a single
  import stays the workflow surface.
* 'awaitStep' is the suspension primitive every wake source builds on: it
  returns a journaled result if present, otherwise runs an idempotent
  /arming/ action once and suspends the run. The arming action MUST be
  idempotent — a suspended-then-resumed workflow re-enters 'awaitStep' from
  the top on every resume until the result is journaled, so it re-runs @arm@
  each time (e.g. schedule a timer with a deterministic id so repeats
  collapse to a no-op).
* A wake source's external completion path (a timer firing,
  @signalAwakeable@, a child finishing) calls 'appendJournalEntry' (or
  'appendJournalEntryReturningId') with a 'StepRecorded' whose @stepName@ is
  the awaited step name; the next 'runWorkflow' then takes the 'awaitStep'
  hit path and proceeds.
* The journal codec ('workflowJournalCodec') and the reserved step-name
  prefixes ('sleepStepPrefix' = @"sleep:"@, 'awakeableStepPrefix' = @"awk:"@,
  'childStepPrefix' = @"child:"@) are integration contracts: suspensions are
  journaled as ordinary 'StepRecorded' events with these prefixes, never as
  new event types, so the replay loop stays uniform.
* Per-run options live in one record, 'WorkflowRunOptions' (EP-41 adds a
  snapshot policy, EP-44 adds metrics/tracer); 'runWorkflowWith' is the
  single canonical entry EP-42's resume worker re-invokes through.
* The derived @keiro_workflows@ instance row is maintained by journal append
  transactions. Terminal markers ('WorkflowCompleted', 'WorkflowCancelled',
  'WorkflowFailed') freeze the instance as completed/cancelled/failed, and the
  resume worker uses its attempt/lease fields for crash recovery.
* Discovery (EP-42) is 'findUnfinishedWorkflowIds' plus 'completedStepName';
  it needs no kiroku prefix subscription.

> __Build gotcha__ (EP-38's migration adds @keiro_workflow_steps@): adding a
> new @.sql@ file under @keiro-migrations/sql-migrations/@ does not trigger
> recompilation of @Keiro.Migrations@ (cabal says "Up to date" even with
> @-fforce-recomp@, because @embedDir@ is a Template Haskell directory read
> GHC's recompilation checker does not track per-file). After adding a
> migration, edit a comment in @keiro-migrations/src/Keiro/Migrations.hs@ or
> run @cabal clean@ before building.
-}
module Keiro.Workflow (
    -- * The effect and authoring surface
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
    defaultWorkflowRunOptions,

    -- * Journal append helpers (used by wake-source plans)
    JournalAppendOutcome (..),
    prepareJournalAppend,
    appendJournalEntry,
    appendJournalEntryReturningId,

    -- * Errors thrown by the runtime
    WorkflowError (..),

    -- * Re-exported core contracts
    module Keiro.Workflow.Types,
    WorkflowStepRow (..),
    recordStepTx,
    loadStepIndex,
    stepExists,
    currentGeneration,
    findUnfinishedWorkflowIds,
    setWorkflowWakeAfterTx,
)
where

import Control.Exception (Exception)
import Data.Aeson qualified as Aeson
import Data.IORef (
    IORef,
    atomicModifyIORef',
    newIORef,
    readIORef,
 )
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (EffectHandler, interpret, localSeqUnlift, send)
import Effectful.Error.Static (Error, tryError)
import Effectful.Exception (bracket_, catch, throwIO)
import Keiro.Codec (decodeRecorded, encodeForAppendWithMetadata)
import Keiro.EventStream (SnapshotPolicy (..), Terminality (..))
import Keiro.Prelude
import Keiro.Snapshot (SnapshotMissReason (..))
import Keiro.Snapshot.Policy (shouldSnapshot)
import Keiro.Telemetry (
    KeiroMetrics,
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
import Keiro.Workflow.Instance (
    WorkflowStatus (..),
    markInstanceSuspended,
    upsertInstanceTx,
 )
import Keiro.Workflow.Schema (WorkflowStepRow (..), currentGeneration, findUnfinishedWorkflowIds, loadStepIndex, lockWorkflowStepTx, lookupStepResult, lookupStepResultTx, recordStepTx, setWorkflowWakeAfterTx, stepExists)
import Keiro.Workflow.Snapshot (lookupWorkflowSnapshot, writeWorkflowSnapshot)
import Keiro.Workflow.Types
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForwardStream)
import Kiroku.Store.Transaction (AppendConflict, appendToStreamTx, prepareEventsIO, runTransaction)
import Kiroku.Store.Types (AppendResult (..), EventData, EventId (..), ExpectedVersion (..), StreamId, StreamVersion (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly
import System.IO.Unsafe (unsafePerformIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- ---------------------------------------------------------------------------
-- The effect
-- ---------------------------------------------------------------------------

{- | The durable workflow effect. Its operations are interpreted by
'runWorkflow' / 'runWorkflowWith', which journal and replay them.
-}
data Workflow :: Effect where
    {- | Run a side-effecting action under a name, journaling its result; on
    replay, return the recorded result without re-running the action.
    -}
    Step :: (Aeson.ToJSON a, Aeson.FromJSON a) => StepName -> m a -> Workflow m a
    {- | Return the awaited step's journaled result, or run the (idempotent)
    arming action once and suspend the run.
    -}
    Await :: (Aeson.FromJSON a) => StepName -> m () -> Workflow m a
    -- | The running workflow's identity (for keying wake sources).
    CurrentWorkflow :: Workflow m (WorkflowName, WorkflowId)
    -- | The journal generation this run is operating on.
    CurrentRunGeneration :: Workflow m Int
    -- | A per-run, per-namespace counter for deterministic ordinal step names.
    FreshOrdinal :: Text -> Workflow m Int
    {- | EP-48: snapshot the carried seed, rotate onto a fresh journal generation,
    and unwind this run; the next run/resume continues from the seed. Never
    returns to the caller within this run (result type is fully polymorphic).
    -}
    ContinueAsNew :: (Aeson.ToJSON s) => s -> Workflow m a
    {- | EP-49: decide and journal a cross-cutting branch — returns the stable
    'Bool' branch decision for the given patch. Fresh instances get 'True'
    (new branch); instances already in flight when the patch shipped get
    'False' (old branch). The decision is journaled on first encounter and
    replayed verbatim thereafter.
    -}
    Patch :: PatchId -> Workflow m Bool

type instance DispatchOf Workflow = Dynamic

{- | Run @action@ under @name@, journaling its encoded result. On a replay where
@name@ is already journaled, the recorded result is returned and @action@ is
not run. If the process crashed after @action@ ran but before the journal
commit, the action runs again on resume: workflow step side effects are
at-least-once at the step boundary.

The returned value is always the JSON round-trip of the recorded result,
including on the first run. A lossy or rejecting @ToJSON@\/@FromJSON@ pair is
therefore observed immediately rather than only after a crash and replay.

Requires @'Aeson.ToJSON' a@ (to journal the result) and @'Aeson.FromJSON' a@
(to decode it on replay).
-}
step :: (Workflow :> es, Aeson.ToJSON a, Aeson.FromJSON a) => StepName -> Eff es a -> Eff es a
step name action = send (Step name action)

{- | Look up @name@ in the journal. If a wake source has already recorded its
completion (a 'StepRecorded' whose @stepName@ is @name@, carrying the
resolved result), decode and return it. Otherwise run @arm@ exactly once
(the wake source's idempotent job — schedule a timer, register an awakeable,
spawn a child) and __suspend__ this run, so 'runWorkflow' returns 'Suspended'.

@arm@ must be idempotent: every resume re-runs it until the result is
journaled.
-}
awaitStep :: (Workflow :> es, Aeson.FromJSON a) => StepName -> Eff es () -> Eff es a
awaitStep name arm = send (Await name arm)

-- | The identity of the workflow currently running.
currentWorkflow :: (Workflow :> es) => Eff es (WorkflowName, WorkflowId)
currentWorkflow = send CurrentWorkflow

{- | The journal generation this run is operating on. Wake sources include it
in their durable identities so a generation opened by 'continueAsNew' never
collides with prior-generation rows.
-}
currentRunGeneration :: (Workflow :> es) => Eff es Int
currentRunGeneration = send CurrentRunGeneration

{- | A per-run, per-namespace counter (starting at 0). Used by convenience
forms of wake sources (e.g. @sleep@ → @"sleep:0"@) to derive a deterministic,
replay-stable ordinal name. Note: ordinal names are only stable if the order
of @awaitStep@-style calls does not change across deploys; the named forms
are the stable primitives.
-}
freshOrdinal :: (Workflow :> es) => Text -> Eff es Int
freshOrdinal namespace = send (FreshOrdinal namespace)

{- | Continue this workflow /as new/ (EP-48): snapshot the carried @seed@ onto a
fresh journal generation, journal a terminal rotation marker on the current
generation, and unwind this run. The next run or resume of the same logical
@('WorkflowName', 'WorkflowId')@ starts against the fresh generation, hydrated
from the seed, with an empty (bounded) journal.

This is how a workflow that runs an /unbounded/ number of steps — a poller, a
per-day rolling process — keeps its per-generation journal bounded so replay
and hydration stay fast forever. The result type is fully polymorphic (@a@)
because control never returns to the caller within /this/ run: the rotated
continuation runs in the next run/resume. Read the carried seed back at the top
of the workflow body with 'restoreSeed'.
-}
continueAsNew :: (Workflow :> es, Aeson.ToJSON s) => s -> Eff es a
continueAsNew seed = send (ContinueAsNew seed)

{- | Restore the seed carried by the previous generation's 'continueAsNew', or
return @def@ on the first generation (EP-48). Implemented as an ordinary
journaled @step@ under the reserved 'continueSeedStepName': on a generation that
was rotated into, the seed step was journaled (and snapshotted) by the rotation,
so this @step@ hits it and returns the carried value without re-running; on the
very first generation it misses and records @def@. Call it once at the top of a
workflow body that uses 'continueAsNew'.
-}
restoreSeed :: (Workflow :> es, Aeson.ToJSON s, Aeson.FromJSON s) => s -> Eff es s
restoreSeed def = step (StepName continueSeedStepName) (pure def)

{- | Decide a cross-cutting branch for an in-flight-vs-fresh code change, and
journal the decision so every later replay observes the same branch (EP-49).

@patch (PatchId "fraud-check-v2")@ returns 'True' only when that id was present
in 'activePatches' when this workflow generation first started. The generation
records its active set under 'patchSetStepName' exactly once; on the first
encounter each individual patch decision is journaled under @patch:\<patchId\>@,
and every replay returns the recorded 'Bool'. Add a patch id to 'activePatches'
in the deploy that introduces the corresponding 'patch' call; remove it only
after deleting that call from the workflow body.

This is an /escape hatch/ for changes that cross-cut multiple steps. For the
common case — one step changed — do __not__ use 'patch': rename the step's
'StepName' instead. A renamed step has no journaled history under its new name,
so its action runs fresh on the next replay, which is exactly the right
behaviour for a single-step change. Reach for 'patch' only when an in-flight
instance would be left incoherent by the new code (e.g. the change adds, removes,
or reorders steps, or changes the meaning of an already-journaled step result).
-}
patch :: (Workflow :> es) => PatchId -> Eff es Bool
patch pid = send (Patch pid)

-- ---------------------------------------------------------------------------
-- Per-run options
-- ---------------------------------------------------------------------------

{- | Options for a single workflow run. This is the canonical home for
per-run options across the v2 initiative — EP-41 adds the snapshot policy,
EP-44 adds metrics/tracer fields, all additive. Extend it additively; never
break the field set EP-38/EP-41 established.
-}
data WorkflowRunOptions = WorkflowRunOptions
    { snapshotPolicy :: !(SnapshotPolicy WorkflowState)
    {- ^ When to persist a snapshot of the accumulated step-result map after a
    step append (and at completion, for 'OnTerminal'). Default 'Never'
    (EP-38 behaviour: every run/resume does a full version-0 replay).
    -}
    , pageSize :: !Int32
    -- ^ Page size for the journal pre-load read.
    , metrics :: !(Maybe KeiroMetrics)
    {- ^ EP-44: when 'Just', the runtime records the @keiro.workflow.*@ instruments
    (steps executed/replayed, active count, journal length). 'Nothing' is the
    no-op default, so a run with 'defaultWorkflowRunOptions' records nothing.
    -}
    , tracer :: !(Maybe Tracer)
    {- ^ EP-44: when 'Just', the runtime opens a @workflow \<name\>@ 'Internal' span
    around the run. 'Nothing' runs the body unwrapped.
    -}
    , activePatches :: !(Set PatchId)
    {- ^ Patch ids currently active in this deployed workflow code. A fresh
    workflow generation records this set once under 'patchSetStepName', and
    each 'patch' call returns 'True' iff its id was in that recorded set.
    -}
    }
    deriving stock (Generic)

{- | Sensible defaults: no snapshotting, a journal pre-load page size of 100,
and no telemetry (metrics/tracer 'Nothing'). A default-options run replays
and behaves exactly as EP-38 did.
-}
defaultWorkflowRunOptions :: WorkflowRunOptions
defaultWorkflowRunOptions =
    WorkflowRunOptions
        { snapshotPolicy = Never
        , pageSize = 100
        , metrics = Nothing
        , tracer = Nothing
        , activePatches = Set.empty
        }

-- ---------------------------------------------------------------------------
-- Errors and the suspension sentinel
-- ---------------------------------------------------------------------------

{- | Errors the workflow runtime raises (via 'throwIO', so they surface
through the surrounding store/IO error channel).
-}
data WorkflowError
    = {- | A journaled step result could not be decoded into the type the
      replaying @step@/@awaitStep@ expects (step name, decode message). The
      result type changed incompatibly — a programmer error.
      -}
      WorkflowStepDecodeError !Text !Text
    | -- | A journal event could not be decoded during pre-load.
      WorkflowJournalDecodeError !Text
    | -- | A journal event could not be encoded for append.
      WorkflowJournalEncodeError !Text
    | -- | Appending a journal entry failed for a non-conflict reason.
      WorkflowJournalAppendError !Text
    deriving stock (Eq, Show)

instance Exception WorkflowError

-- | Internal sentinel thrown to unwind a suspended run up to 'runWorkflowWith'.
data WorkflowSuspend = WorkflowSuspend
    deriving stock (Show)

instance Exception WorkflowSuspend

-- | Internal sentinel thrown when a cancellation marker appears mid-run.
data WorkflowCancelPending = WorkflowCancelPending
    deriving stock (Show)

instance Exception WorkflowCancelPending

{- | Internal sentinel thrown by the 'ContinueAsNew' handler to unwind a
rotating run up to 'runWorkflowWith' (EP-48), carrying the JSON-encoded seed for
the next generation. Mirrors 'WorkflowSuspend': a non-returning unwind the run
entry point catches and turns into an outcome ('ContinuedAsNew').
-}
newtype WorkflowRotate = WorkflowRotate Aeson.Value
    deriving stock (Show)

instance Exception WorkflowRotate

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

{- | Process-wide count of workflow runs currently in flight, backing the
@keiro.workflow.active@ gauge (EP-44). 'runWorkflowWith' brackets each run with
@+1@/@-1@ and samples the gauge on both edges, so the exported last-value
reflects the true live count whether a run is mid-flight or finished. A
process-global 'IORef' is the lightest faithful implementation (the gauge is a
last-value-wins level, not a per-run delta), mirroring how the other keiro
backlog/level gauges are recorded with a value the runtime already holds.
-}
{-# NOINLINE activeCountRef #-}
activeCountRef :: IORef Int64
activeCountRef = unsafePerformIO (newIORef 0)

{- | Run a workflow computation, journaling each 'step' and replaying any
already-journaled steps. Returns 'Completed' when the computation finishes
(a 'WorkflowCompleted' marker is journaled) or 'Suspended' when it pauses at
an unresolved 'awaitStep'.

Equivalent to @'runWorkflowWith' 'defaultWorkflowRunOptions'@.
-}
runWorkflow ::
    (IOE :> es, Store :> es, Error StoreError :> es) =>
    WorkflowName ->
    WorkflowId ->
    Eff (Workflow : es) a ->
    Eff es (WorkflowOutcome a)
runWorkflow = runWorkflowWith defaultWorkflowRunOptions

{- | 'runWorkflow' with explicit 'WorkflowRunOptions'. This is the single
canonical run entry point; EP-42's resume worker re-invokes through it so
resumed runs honor the same options.

If the workflow's journal already carries a 'WorkflowCancelled' marker (a child
cancelled by its parent, EP-43), the run short-circuits immediately and returns
'Cancelled' without executing any step. The handler also re-checks that marker
on step/await/patch miss paths and after a fresh step action returns, so a
mid-run cancellation stops at the next workflow boundary. A cancellation that
lands after the check but before/during the user action may still let that one
action run; durable workflow steps remain at-least-once at boundaries. If the
journal carries a 'WorkflowFailed' marker, the run likewise short-circuits to
'Failed'. To /propagate/ a finished child's result to its parent, drive the
child through 'Keiro.Workflow.Child.runChildWorkflow' rather than this function
directly.
-}
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
    -- Cancellation short-circuit (EP-43): a workflow whose journal carries a
    -- WorkflowCancelled marker makes no further progress. The index row for that
    -- marker is keyed under 'cancelledStepName' on the current generation, so a
    -- single existence check is enough and we never run the user action.
    cancelled <- stepExists name wid gen cancelledStepName
    failed <- stepExists name wid gen failedStepName
    case (cancelled, failed) of
        (True, _) -> pure Cancelled
        (_, True) -> pure Failed
        _ -> runActive gen
  where
    -- EP-44 telemetry handles, pulled from the run options once. Both default
    -- to 'Nothing' (see 'defaultWorkflowRunOptions'), so a default-options run
    -- records nothing and opens no span — the no-op idiom holds end to end.
    mMetrics = options ^. #metrics
    mTracer = options ^. #tracer
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
            outcome <-
                (Completed <$> runHandler)
                    `catch` (\WorkflowSuspend -> pure Suspended)
                    `catch` (\WorkflowCancelPending -> pure Cancelled)
                    `catch` (\(WorkflowRotate seedJson) -> rotateGeneration mMetrics name wid gen seedJson)
            case outcome of
                Completed result -> do
                    now <- liftIO getCurrentTime
                    finalMap <- liftIO (readIORef journalRef)
                    -- Idempotent: only appends (and so only snapshots) when the completion
                    -- marker is not already journaled. On a replay of an already-completed
                    -- workflow this is 'Nothing' and no terminal snapshot is taken (one was
                    -- already taken on the original completing run, if the policy fired).
                    mAppend <- appendCompletion name wid gen now
                    for_ mAppend $ \appendResult ->
                        when
                            ( shouldSnapshot
                                (options ^. #snapshotPolicy)
                                Terminal
                                finalMap
                                (appendResult ^. #streamVersion)
                            )
                            (writeWorkflowSnapshotAdvisory mMetrics (appendResult ^. #streamId) (appendResult ^. #streamVersion) finalMap)
                    -- EP-44: record one @keiro.workflow.journal.length@ observation per
                    -- completing run (the 'Completed' path only, never 'Suspended'),
                    -- including a replay that completes again. Length is the recorded
                    -- step map plus the WorkflowCompleted marker.
                    recordWorkflowJournalLength mMetrics (fromIntegral (Map.size finalMap + 1))
                    pure (Completed result)
                Suspended -> markInstanceSuspended name wid >> pure Suspended
                Cancelled -> pure Cancelled
                Failed -> pure Failed
                -- EP-48: the run unwound via 'WorkflowRotate'; 'rotateGeneration'
                -- already journaled the seed step on the next generation and the
                -- rotation marker on this one, so there is nothing more to do here.
                ContinuedAsNew -> pure ContinuedAsNew
        recordPatchSetIfFresh runGen initial = do
            let patches = options ^. #activePatches
                freshStart = Map.keysSet initial `Set.isSubsetOf` Set.singleton continueSeedStepName
            if freshStart && not (Set.null patches)
                then do
                    let encoded = Aeson.toJSON (map unPatchId (Set.toList patches))
                    now <- liftIO getCurrentTime
                    appendJournal name wid runGen (StepRecorded patchSetStepName encoded now) >>= \case
                        JournalAppended{} -> pure (Map.insert patchSetStepName encoded initial)
                        JournalAlreadyPresent stored -> pure (Map.insert patchSetStepName stored initial)
                        JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))
                else pure initial
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
                    checkCancellationPending name wid gen
                    a <- localSeqUnlift env (\unlift -> unlift act)
                    checkCancellationPending name wid gen
                    let encoded = Aeson.toJSON a
                    now <- liftIO getCurrentTime
                    appendOutcome <- appendJournal name wid gen (StepRecorded key encoded now)
                    case appendOutcome of
                        JournalAppended appendResult -> do
                            -- Miss: @act@ ran and was journaled — a fresh execution.
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
                            checkCancellationPending name wid gen
                            localSeqUnlift env (\unlift -> unlift arm)
                            throwIO WorkflowSuspend
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
                    checkCancellationPending name wid gen
                    recordedSet <- case Map.lookup patchSetStepName journal of
                        Nothing -> pure []
                        Just stored -> decodeStored patchSetStepName stored
                    let decision = unPatchId pid `elem` (recordedSet :: [Text])
                        encoded = Aeson.toJSON decision
                    now <- liftIO getCurrentTime
                    appendOutcome <- appendJournal name wid gen (StepRecorded key encoded now)
                    case appendOutcome of
                        JournalAppended{} -> do
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
                        JournalAppendConflict err ->
                            throwIO (WorkflowJournalAppendError (Text.pack (show err)))

-- | Decode a stored journal result into the type the caller expects.
decodeStored :: (Aeson.FromJSON a) => Text -> Aeson.Value -> Eff es a
decodeStored key stored = case Aeson.fromJSON stored of
    Aeson.Success a -> pure a
    Aeson.Error message -> throwIO (WorkflowStepDecodeError key (Text.pack message))

checkCancellationPending :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Eff es ()
checkCancellationPending name wid gen = do
    cancelled <- stepExists name wid gen cancelledStepName
    when cancelled (throwIO WorkflowCancelPending)

{- | Pre-load a workflow's journal stream into a @step name -> result@ map.

If a compatible snapshot exists ('loadWorkflowSnapshot'), seed the map from it
and read only the journal events /after/ the snapshot's version ("tail
replay"). The reconstructed map is the journal state as the snapshotting run
saw it. A wake completion journaled concurrently with that run can fall at or
before the snapshot version yet be absent from the seed, so the map may
under-approximate the journal. The @Await@ handler compensates by consulting
the authoritative @keiro_workflow_steps@ index on a map miss; that index is
written transactionally with every journal append.

A missing, mismatched, or undecodable snapshot is recorded as a miss (and, for
undecodable bytes, a decode failure) before the read falls back to a full
replay from version 0.
'WorkflowCompleted' contributes nothing to the map.
-}
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
    let
        events = readStreamForwardStream journalName fromVersion (options ^. #pageSize)
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

data JournalAppendOutcome
    = JournalAppended !AppendResult
    | JournalAlreadyPresent !Aeson.Value
    | JournalAppendConflict !AppendConflict
    deriving stock (Eq, Show)

prepareJournalAppend ::
    (IOE :> es) =>
    WorkflowName ->
    WorkflowId ->
    Int ->
    WorkflowJournalEvent ->
    Eff es (Tx.Transaction JournalAppendOutcome)
prepareJournalAppend name wid gen event = do
    let key = journalKey event
        entryId = deterministicJournalId name wid gen key
        row = journalRow name wid gen event
        (status, mLastError) = instanceStatusForEvent event
        journalName = workflowGenerationStreamName name wid gen
        lockKey =
            Text.intercalate
                "/"
                [unWorkflowId wid, unWorkflowName name, Text.pack (show gen), key]
    base <- case encodeForAppendWithMetadata workflowJournalCodec Nothing event of
        Right encoded -> pure encoded
        Left err -> throwIO (WorkflowJournalEncodeError (Text.pack (show err)))
    let entry = base & #eventId .~ Just entryId :: EventData
    prepared <- prepareEventsIO [entry]
    now <- liftIO getCurrentTime
    pure $ do
        lockWorkflowStepTx lockKey
        lookupStepResultTx (unWorkflowId wid) (unWorkflowName name) gen key >>= \case
            Just stored -> pure (JournalAlreadyPresent stored)
            Nothing ->
                appendToStreamTx journalName AnyVersion prepared now >>= \case
                    Left err -> pure (JournalAppendConflict err)
                    Right appendResult ->
                        JournalAppended appendResult
                            <$ recordStepTx row
                            <* upsertInstanceTx
                                (unWorkflowId wid)
                                (unWorkflowName name)
                                (fromIntegral gen)
                                status
                                mLastError

appendJournal :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Int -> WorkflowJournalEvent -> Eff es JournalAppendOutcome
appendJournal name wid gen event =
    prepareJournalAppend name wid gen event >>= runTransaction

{- | Append a journal event to a workflow's journal stream (and keep its
index row consistent), idempotently. If the entry already exists this is a
no-op returning the would-be event id.

This is the integration helper a wake source's external-completion path uses
to record an awaited step's resolution. The append uses a deterministic event
id derived from @("keiro" : "workflow" : name : id : stepName)@ so concurrent
or retried writes collapse to one row.
-}
appendJournalEntry :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()
appendJournalEntry name wid event = void (appendJournalEntryReturningId name wid event)

{- | Like 'appendJournalEntry' but returns the (deterministic) 'EventId' of
the entry. EP-39's fired timer needs this for @markTimerFired@.
-}
appendJournalEntryReturningId :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es EventId
appendJournalEntryReturningId name wid event = do
    -- EP-48: a wake source (timer fired, signalAwakeable, child completion)
    -- resolves the awaited step on whichever generation the suspended run is
    -- parked on — always the current (highest) one, since runs only ever operate
    -- on the current generation. Resolve it here so the append and its
    -- deterministic id are namespaced by that generation.
    gen <- currentGeneration name wid
    let key = journalKey event
        entryId = deterministicJournalId name wid gen key
    appendJournal name wid gen event >>= \case
        JournalAppended{} -> pure entryId
        JournalAlreadyPresent{} -> pure entryId
        JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))

{- | Append a journal entry only if it is not already journaled, returning the
'AppendResult' of the fresh append (or 'Nothing' if it already existed). Used
on the completion path so a terminal ('OnTerminal') snapshot can be taken from
the completing run's 'AppendResult', while a replay of an already-completed
workflow is a no-op.
-}
appendCompletion :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Int -> UTCTime -> Eff es (Maybe AppendResult)
appendCompletion name wid gen now = do
    appendJournal name wid gen (WorkflowCompleted now) >>= \case
        JournalAppended appendResult -> pure (Just appendResult)
        JournalAlreadyPresent{} -> pure Nothing
        JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))

{- | Perform a continue-as-new rotation (EP-48): close generation @gen@ and open
generation @gen + 1@, seeded with @seedJson@. Returns 'ContinuedAsNew'.

The two appends are ordered for crash-safety. We append the next generation's
seed step __first__ (a single @StepRecorded continueSeedStepName seedJson@),
which advances @MAX(generation)@ — and therefore 'currentGeneration' — to
@gen + 1@. After that commits, any re-run resolves the current generation to
@gen + 1@, hydrates from the seed, and never re-enters generation @gen@; so even
a crash between the two appends converges to "continue from the seed", never
re-running generation @gen@'s work. We then append the terminal
'WorkflowContinuedAsNew' marker on generation @gen@. Both appends are guarded by
an existence check and use deterministic, generation-namespaced ids, so the
whole rotation is idempotent.

The seed step alone carries the state forward (the next run's 'loadJournal'
reads it and 'restoreSeed' hits it); we additionally snapshot the one-entry seed
map at the seed step's version so the next generation hydrates in O(1) rather
than re-reading even that one event. The snapshot is advisory (a miss only costs
a single event read), so it is written unconditionally on rotation regardless of
the run's 'snapshotPolicy' — rotation is exactly when a fresh snapshot earns its
keep.
-}
rotateGeneration ::
    forall a es.
    (IOE :> es, Store :> es, Error StoreError :> es) =>
    Maybe KeiroMetrics ->
    WorkflowName ->
    WorkflowId ->
    Int ->
    Aeson.Value ->
    Eff es (WorkflowOutcome a)
rotateGeneration mMetrics name wid gen seedJson = do
    let nextGen = gen + 1
    now <- liftIO getCurrentTime
    -- 1. Seed step on the NEXT generation first (advances the current generation).
    appendJournal name wid nextGen (StepRecorded continueSeedStepName seedJson now) >>= \case
        JournalAppended appendResult ->
            writeWorkflowSnapshotAdvisory
                mMetrics
                (appendResult ^. #streamId)
                (appendResult ^. #streamVersion)
                (Map.singleton continueSeedStepName seedJson)
        JournalAlreadyPresent{} -> pure ()
        JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))
    -- 2. Terminal rotation marker on the CURRENT generation (audit + closes it).
    appendJournal name wid gen (WorkflowContinuedAsNew nextGen now) >>= \case
        JournalAppended{} -> pure ()
        JournalAlreadyPresent{} -> pure ()
        JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))
    pure ContinuedAsNew

{- | Snapshot a workflow state after its journal append has committed. The
snapshot is advisory: a store failure is counted and cannot turn the
already-durable workflow transition into a failed run.
-}
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

instanceStatusForEvent :: WorkflowJournalEvent -> (WorkflowStatus, Maybe Text)
instanceStatusForEvent = \case
    StepRecorded{} -> (WfRunning, Nothing)
    WorkflowCompleted{} -> (WfCompleted, Nothing)
    WorkflowCancelled{} -> (WfCancelled, Nothing)
    WorkflowFailed reason _ -> (WfFailed, Just reason)
    WorkflowContinuedAsNew{} -> (WfRunning, Nothing)

-- | The reserved step-name key a journal event indexes under.
journalKey :: WorkflowJournalEvent -> Text
journalKey = \case
    StepRecorded{stepName = key} -> key
    WorkflowCompleted{} -> completedStepName
    WorkflowCancelled{} -> cancelledStepName
    WorkflowFailed{} -> failedStepName
    WorkflowContinuedAsNew{} -> continuedAsNewStepName

-- | The index row corresponding to a journal event, on the given generation.
journalRow :: WorkflowName -> WorkflowId -> Int -> WorkflowJournalEvent -> WorkflowStepRow
journalRow name wid gen = \case
    StepRecorded key value t ->
        WorkflowStepRow
            { workflowId = unWorkflowId wid
            , workflowName = unWorkflowName name
            , generation = gen
            , stepName = key
            , result = value
            , recordedAt = t
            }
    WorkflowCompleted t ->
        WorkflowStepRow
            { workflowId = unWorkflowId wid
            , workflowName = unWorkflowName name
            , generation = gen
            , stepName = completedStepName
            , result = Aeson.Null
            , recordedAt = t
            }
    WorkflowCancelled t ->
        WorkflowStepRow
            { workflowId = unWorkflowId wid
            , workflowName = unWorkflowName name
            , generation = gen
            , stepName = cancelledStepName
            , result = Aeson.Null
            , recordedAt = t
            }
    WorkflowFailed r t ->
        WorkflowStepRow
            { workflowId = unWorkflowId wid
            , workflowName = unWorkflowName name
            , generation = gen
            , stepName = failedStepName
            , result = Aeson.toJSON r
            , recordedAt = t
            }
    WorkflowContinuedAsNew g t ->
        WorkflowStepRow
            { workflowId = unWorkflowId wid
            , workflowName = unWorkflowName name
            , generation = gen
            , stepName = continuedAsNewStepName
            , result = Aeson.toJSON g -- the NEXT generation this rotation opens
            , recordedAt = t
            }

{- | A stable, collision-resistant journal-event id from
@("keiro" : "workflow" : name : id : generation : stepName)@ via a v5 UUID.
Mirrors 'Keiro.ProcessManager.deterministicCommandId': the same inputs always
yield the same id, so a re-append of the same step collapses to the same row.

The /generation/ (EP-48) is part of the id so a step named @"s1"@ in
generation 0 and the same name in generation 1 produce __different__ kiroku
event ids — they live on different physical streams, but the event id is
global, so namespacing it by generation keeps rotated generations from
colliding on the deterministic id.
-}
deterministicJournalId :: WorkflowName -> WorkflowId -> Int -> Text -> EventId
deterministicJournalId (WorkflowName name) (WorkflowId wid) gen key =
    EventId $
        UUID.V5.generateNamed UUID.V5.namespaceURL $
            fmap (fromIntegral . fromEnum) $
                Text.unpack $
                    Text.intercalate ":" ["keiro", "workflow", name, wid, Text.pack (show gen), key]
