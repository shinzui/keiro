{- | The workflow resume / crash-recovery worker.

EP-38 makes a workflow replay-on-re-invocation: call 'runWorkflow' (or
'runWorkflowWith') with the same id and each already-journaled step
short-circuits, so only the un-journaled tail runs. But nothing in the runtime
/notices/ that a workflow exists, has steps, and lacks a terminal
'WorkflowCompleted' — i.e. that it crashed mid-run, or is parked on a
@sleep@\/@awakeable@ whose wake source has since resolved. This module is what
notices: a background worker that, on each pass, asks the database "which
workflows have steps but no completion?" ('findUnfinishedWorkflowIds') and
re-invokes each so it proceeds.

== Why a registry

A workflow's body is application Haskell code — only its /journal/ (the
recorded step results) lives in the database. To re-invoke a workflow the
worker must turn its stored name into a function
@'WorkflowId' -> 'Eff' ('Workflow' : es) a@. There is no way to materialize a
closure from a string, so the application supplies a 'WorkflowRegistry' mapping
each 'WorkflowName' to its 'WorkflowDef'. This is the resume-worker analogue of
the caller-supplied @fire@ action 'Keiro.Timer.runTimerWorker' takes: the
worker owns the discovery loop and the database access; the application owns
the domain behaviour.

== Contract recap for downstream plans (the v2 MasterPlan)

* __'WorkflowRegistry' \/ 'WorkflowDef'__ — the application-supplied
  name → definition map. EP-43 (child workflows) relies on this worker to wake
  a /parent/ once a child finishes: the child's completion journals the
  parent's awaited @child:\<id\>@ 'StepRecorded', and the next resume pass
  re-invokes the parent (registered here) so it proceeds past its child-wait.
* __'ResumeSummary'__ ('discovered', 'resumed', 'completed', 'stillSuspended',
  'unknownName') — the per-pass observability record. EP-44 reads it for the
  @keiro.workflow.resumed@ instrument (and may thread a @Maybe KeiroMetrics@
  into 'WorkflowResumeOptions' \/ 'resumeWorkflowsOnce' following the
  no-op-under-@Nothing@ idiom the timer and outbox workers use).
* __'resumeWorkflowsOnce'__ is the single-pass, testable unit (like
  'Keiro.Outbox.publishClaimedOutbox'); __'runWorkflowResumeWorker'__ \/
  __'runWorkflowResumeWorkerWith'__ are the poll-loop drivers (like the
  @runTimerWorker@ pair). Re-invocation goes through EP-41's 'runWorkflowWith'
  carrying 'runOptions', so a resumed run honours the same snapshot/telemetry
  options as its first run.

Discovery is the 'findUnfinishedWorkflowIds' index query only — __no kiroku
@wf:@ prefix subscription__ is used or needed, so this surface has zero
upstream dependency.
-}
module Keiro.Workflow.Resume
  ( -- * Registry
    WorkflowDef (..)
  , WorkflowRegistry

    -- * Options
  , WorkflowResumeOptions (..)
  , defaultWorkflowResumeOptions

    -- * Per-pass summary
  , ResumeSummary (..)
  , emptyResumeSummary

    -- * Running (fixed-poll baseline)
  , resumeWorkflowsOnce
  , runWorkflowResumeWorker
  , runWorkflowResumeWorkerWith

    -- * Running (push-aware, EP-50)
  , runPollLoopWith
  , runWorkflowResumeWorkerPush
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (foldM, forever)
import Data.Aeson qualified as Aeson
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Prelude
import Keiro.Telemetry (recordWorkflowAwakeablesPending, recordWorkflowResumed)
import Keiro.Wake (WakeSignal (..), wakeSignalFromStore)
import Keiro.Workflow
  ( Workflow
  , WorkflowId (..)
  , WorkflowName (..)
  , WorkflowOutcome (..)
  , WorkflowRunOptions
  , defaultWorkflowRunOptions
  , findUnfinishedWorkflowIds
  , runWorkflowWith
  )
import Keiro.Workflow.Awakeable.Schema (countPendingAwakeables)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Child.Schema (findRunningChildIds, lookupChild)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

{- | How to re-build a workflow's body from its id, for one workflow name.

The result type @a@ is existential: the worker discards it (it cares only
whether a re-invocation reached 'Completed' or 'Suspended'), so one registry
can hold workflows of different return types.
-}
data WorkflowDef es = forall a. (Aeson.ToJSON a) => WorkflowDef
  { runDef :: WorkflowId -> Eff (Workflow : es) a
  }

{- | The application-supplied map from workflow name to its definition. The
worker looks up each discovered workflow's name here; an absent name is
skipped and counted as 'unknownName' (a deploy that dropped a workflow while
instances were still in flight — surfaced, not silently lost).
-}
type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

{- | Options for the resume worker. Mirrors the @TimerWorkerOptions@ shape:
'runOptions' threads EP-41's snapshot/telemetry options into 'runWorkflowWith',
and 'pollInterval' is the loop driver's gap between passes.
-}
data WorkflowResumeOptions = WorkflowResumeOptions
  { runOptions :: !WorkflowRunOptions
  -- ^ Threaded into 'runWorkflowWith' (or 'runChildWorkflow' for a child) so a
  --   resumed run honours the same snapshot (EP-41) and telemetry (EP-44)
  --   options as its first run.
  , pollInterval :: !Int
  -- ^ Microseconds the loop driver sleeps between passes.
  , useAdvisoryLock :: !Bool
  -- ^ __Reserved (default 'False').__ The original design proposed a
  --   per-workflow @pg_try_advisory_xact_lock@ to let multiple worker
  --   processes claim disjoint workflows. That is __not wired__: the kiroku
  --   'Store' is connection-/pooled/, and a re-invocation spans several
  --   transactions (one per step append), so a transaction-scoped advisory
  --   lock cannot be held across a whole 'runWorkflowWith' run, and a
  --   session-scoped lock has no connection affinity through the pool.
  --   Concurrency is instead safe by construction (see the module docs):
  --   EP-38 journals each step under a deterministic id and short-circuits
  --   already-journaled steps, so two workers racing the same workflow
  --   converge to the same journal with each side effect run at most once.
  --   The field is kept for forward compatibility; setting it has no effect.
  }
  deriving stock (Generic)

-- | Defaults: EP-41's 'defaultWorkflowRunOptions', a 1-second poll, no lock.
defaultWorkflowResumeOptions :: WorkflowResumeOptions
defaultWorkflowResumeOptions =
  WorkflowResumeOptions
    { runOptions = defaultWorkflowRunOptions
    , pollInterval = 1_000_000
    , useAdvisoryLock = False
    }

-- ---------------------------------------------------------------------------
-- Per-pass summary
-- ---------------------------------------------------------------------------

{- | What one 'resumeWorkflowsOnce' pass did. EP-44 instruments this for
@keiro.workflow.resumed@.
-}
data ResumeSummary = ResumeSummary
  { discovered :: !Int
  -- ^ Unfinished workflows 'findUnfinishedWorkflowIds' returned this pass.
  , resumed :: !Int
  -- ^ Workflows re-invoked (found in the registry and run).
  , completed :: !Int
  -- ^ Re-invocations that reached 'Completed' this pass.
  , stillSuspended :: !Int
  -- ^ Re-invocations that returned 'Suspended' (wake source not yet resolved).
  , unknownName :: !Int
  -- ^ Discovered workflows whose name was absent from the registry (skipped + logged).
  }
  deriving stock (Generic, Eq, Show)

-- | A zeroed 'ResumeSummary'.
emptyResumeSummary :: ResumeSummary
emptyResumeSummary = ResumeSummary 0 0 0 0 0

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

{- | Run one discover-and-reinvoke pass.

Discovers every unfinished workflow via 'findUnfinishedWorkflowIds', and for
each looks its name up in @registry@:

* __present__ — re-invoke through 'runWorkflowWith' (the journal pre-load
  short-circuits already-journaled steps, so only the un-journaled tail runs);
  the outcome bumps 'completed' or 'stillSuspended'.
* __absent__ — log a warning and bump 'unknownName' (a workflow whose code was
  removed while instances were in flight must be visible, not silently lost).

Idempotent: a completed workflow has a @__workflow_completed__@ index row and
so drops out of discovery; re-invoking an unfinished one twice converges to the
same journal (EP-38 deterministic ids + step short-circuit).
-}
resumeWorkflowsOnce ::
  forall es.
  (IOE :> es, Store :> es) =>
  WorkflowResumeOptions ->
  WorkflowRegistry es ->
  Eff es ResumeSummary
resumeWorkflowsOnce opts registry = do
  -- EP-44: sample the @keiro.workflow.awakeables.pending@ gauge once per pass,
  -- on the same Store the discovery query uses. The metrics handle rides on the
  -- run options (EP-44 threads telemetry through 'WorkflowRunOptions'), so it is
  -- already forwarded into 'runWorkflowWith' for every re-invocation.
  pending <- countPendingAwakeables
  recordWorkflowAwakeablesPending mMetrics (fromIntegral pending)
  -- Discovery unions two sources: workflows with steps but no terminal marker
  -- ('findUnfinishedWorkflowIds') and freshly-spawned children that have no
  -- step rows yet ('findRunningChildIds', EP-43) — so a zero-step child is
  -- still driven. The dedup collapses a child that appears in both.
  unfinished <- findUnfinishedWorkflowIds
  runningChildren <- findRunningChildIds
  let pairs = nub (unfinished <> runningChildren)
      seed = emptyResumeSummary{discovered = length pairs}
  foldM advance seed pairs
  where
    mMetrics = runOptions opts ^. #metrics
    advance :: ResumeSummary -> (Text, Text) -> Eff es ResumeSummary
    advance acc (widText, wnameText) =
      case Map.lookup (WorkflowName wnameText) registry of
        Nothing -> do
          liftIO $
            hPutStrLn
              stderr
              ( "keiro resume worker: no registry entry for workflow "
                  <> Text.unpack wnameText
                  <> " (id "
                  <> Text.unpack widText
                  <> "); skipping"
              )
          pure acc{unknownName = unknownName acc + 1}
        Just (WorkflowDef runDef) -> do
          let wid = WorkflowId widText
              name = WorkflowName wnameText
          -- A workflow that is some parent's child is driven through
          -- 'runChildWorkflow' so its result propagates to the parent on
          -- completion (EP-43); any other workflow uses bare 'runWorkflowWith'.
          mChild <- lookupChild widText wnameText
          outcome <- case mChild of
            Just _ -> runChildWorkflow (runOptions opts) name wid (runDef wid)
            Nothing -> runWorkflowWith (runOptions opts) name wid (runDef wid)
          -- EP-44: one @keiro.workflow.resumed@ increment per re-invocation of a
          -- registered workflow (the unknown-name branch above is not a
          -- re-invocation, so it does not count).
          recordWorkflowResumed mMetrics 1
          pure (bumpForOutcome outcome acc)

-- | Fold one re-invocation's outcome into the running summary. The existential
-- result @a@ is discarded here, so it never escapes the registry.
bumpForOutcome :: WorkflowOutcome a -> ResumeSummary -> ResumeSummary
bumpForOutcome outcome acc = case outcome of
  Completed _ -> acc{resumed = resumed acc + 1, completed = completed acc + 1}
  Suspended -> acc{resumed = resumed acc + 1, stillSuspended = stillSuspended acc + 1}
  -- A workflow cancelled between discovery and re-invocation short-circuits to
  -- 'Cancelled' (EP-43); count it as re-invoked but neither completed nor
  -- suspended. (A cancelled workflow also drops out of discovery, so this is a
  -- rare race, not the steady state.)
  Cancelled -> acc{resumed = resumed acc + 1}
  -- A workflow that rotated via continueAsNew (EP-48) returns 'ContinuedAsNew':
  -- it is re-invoked but neither completed nor suspended this pass. Its new
  -- generation has no terminal marker, so 'findUnfinishedWorkflowIds' still
  -- reports it and the next pass drives the rotated generation forward.
  ContinuedAsNew -> acc{resumed = resumed acc + 1}

{- | Poll-and-resume loop: run 'resumeWorkflowsOnce' on the configured
'pollInterval' forever. Mirrors how an application schedules
'Keiro.Outbox.publishClaimedOutbox' \/ @runTimerWorker@ per tick; the
single-pass 'resumeWorkflowsOnce' remains the testable unit.
-}
runWorkflowResumeWorkerWith ::
  (IOE :> es, Store :> es) =>
  WorkflowResumeOptions ->
  WorkflowRegistry es ->
  Eff es ()
runWorkflowResumeWorkerWith opts registry = forever $ do
  _summary <- resumeWorkflowsOnce opts registry
  liftIO (threadDelay (pollInterval opts))

-- | 'runWorkflowResumeWorkerWith' with 'defaultWorkflowResumeOptions'.
runWorkflowResumeWorker ::
  (IOE :> es, Store :> es) =>
  WorkflowRegistry es ->
  Eff es ()
runWorkflowResumeWorker = runWorkflowResumeWorkerWith defaultWorkflowResumeOptions

-- ---------------------------------------------------------------------------
-- Push-aware loop (EP-50)
-- ---------------------------------------------------------------------------

{- | Generic push-aware poll loop: run one pass, then block on the 'WakeSignal'
with the given fallback timeout (microseconds), forever. The pass is the durable
unit; the wake only shortens the gap between passes. Both wake reasons (a
notification or the fallback elapsing) mean "run another pass", so the returned
'Keiro.Wake.WakeReason' is ignored for control flow. A missed @NOTIFY@ costs at
most one fallback interval of latency, never lost work — correctness rests on the
pass (e.g. 'resumeWorkflowsOnce'), which is idempotent, not on a notification
arriving. The same pattern applies mechanically to 'Keiro.Timer.runTimerWorker'
and 'Keiro.Outbox.publishClaimedOutbox' (documented, not implemented here; the
resume worker carries the acceptance via parent/child cascades).
-}
runPollLoopWith ::
  -- | the wake signal to block on between passes
  WakeSignal ->
  -- | fallback timeout in microseconds (the maximum gap when no notification arrives)
  Int ->
  -- | one pass, already wrapped to run in 'IO'
  IO () ->
  IO ()
runPollLoopWith wake fallbackMicros pass =
  forever (pass >> void (waitForWake wake fallbackMicros))

{- | The workflow resume worker, push-aware (EP-50). Runs 'resumeWorkflowsOnce'
on each pass; between passes it waits on the store's notifier (sub-second wake on
any append) and falls back to 'pollInterval' so a dropped notification still
drains the backlog.

This is the push-aware sibling of 'runWorkflowResumeWorker' /
'runWorkflowResumeWorkerWith', which remain unchanged as the durable fixed-poll
baseline. The 'pollInterval' field is __repurposed__ as the /fallback/ timeout:
its meaning shifts from "fixed gap between passes" to "maximum gap when no
notification arrives" — strictly better for latency, identical in the
no-notification worst case.

It opens __no__ new database connection (the 'WakeSignal' rides kiroku's existing
single per-store listener; see "Keiro.Wake"). It takes the 'KirokuStore' handle
directly to reach that notifier, and runs each pass through
'Kiroku.Store.Effect.runStoreIO', which pins the registry's effect row to the
concrete @'[Store, Error StoreError, IOE]@ that @runStoreIO@ eliminates. A caller
needing a richer effect row can use 'runPollLoopWith' directly with their own
@runStoreIO@-equivalent pass.
-}
runWorkflowResumeWorkerPush ::
  KirokuStore ->
  WorkflowResumeOptions ->
  WorkflowRegistry '[Store, Error StoreError, IOE] ->
  IO ()
runWorkflowResumeWorkerPush store opts registry = do
  wake <- wakeSignalFromStore store
  runPollLoopWith wake (pollInterval opts) onePass
 where
  onePass = void (runStoreIO store (resumeWorkflowsOnce opts registry))
