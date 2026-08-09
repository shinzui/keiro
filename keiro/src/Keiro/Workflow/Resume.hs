-- | The workflow resume / crash-recovery worker.
--
-- EP-38 makes a workflow replay-on-re-invocation: call 'runWorkflow' (or
-- 'runWorkflowWith') with the same id and each already-journaled step
-- short-circuits, so only the un-journaled tail runs. But nothing in the runtime
-- /notices/ that a workflow exists, has steps, and lacks a terminal
-- 'WorkflowCompleted' — i.e. that it crashed mid-run, or is parked on a
-- @sleep@\/@awakeable@ whose wake source has since resolved. This module is what
-- notices: a background worker that, on each pass, asks the database "which
-- workflows have steps but no completion?" ('findUnfinishedWorkflowIds') and
-- re-invokes each so it proceeds.
--
-- Synchronous exceptions are retried with database-backed exponential backoff.
-- Once 'maxAttempts' is reached, the worker appends 'WorkflowFailed' and stops
-- discovering that instance. The operator-facing counterpart lives in
-- "Keiro.Workflow.Instance": 'Keiro.Workflow.Instance.resurrectFailedWorkflow'
-- transactionally returns a terminally failed instance to the runnable pool
-- without deleting its append-only failure history.
--
-- == Why a registry
--
-- A workflow's body is application Haskell code — only its /journal/ (the
-- recorded step results) lives in the database. To re-invoke a workflow the
-- worker must turn its stored name into a function
-- @'WorkflowId' -> 'Eff' ('Workflow' : es) a@. There is no way to materialize a
-- closure from a string, so the application supplies a 'WorkflowRegistry' mapping
-- each 'WorkflowName' to its 'WorkflowDef'. This is the resume-worker analogue of
-- the caller-supplied @fire@ action 'Keiro.Timer.runTimerWorker' takes: the
-- worker owns the discovery loop and the database access; the application owns
-- the domain behaviour.
--
-- == Contract recap for downstream plans (the v2 MasterPlan)
--
-- * __'WorkflowRegistry' \/ 'WorkflowDef'__ — the application-supplied
--   name → definition map. EP-43 (child workflows) relies on this worker to wake
--   a /parent/ once a child finishes: the child's completion journals the
--   parent's awaited @child:\<id\>@ 'StepRecorded', and the next resume pass
--   re-invokes the parent (registered here) so it proceeds past its child-wait.
-- * __'ResumeSummary'__ ('discovered', 'resumed', 'completed', 'stillSuspended',
--   'unknownName', 'failed', 'transientErrors', 'leaseSkipped') — the per-pass
--   observability record. EP-44 reads it for the @keiro.workflow.resumed@
--   instrument (and may thread a @Maybe KeiroMetrics@ into
--   'WorkflowResumeOptions' \/ 'resumeWorkflowsOnce' following the
--   no-op-under-@Nothing@ idiom the timer and outbox workers use).
-- * __'resumeWorkflowsOnce'__ is the single-pass, testable unit (like
--   'Keiro.Outbox.publishClaimedOutbox'); __'runWorkflowResumeWorker'__ \/
--   __'runWorkflowResumeWorkerWith'__ are the poll-loop drivers (like the
--   @runTimerWorker@ pair). Re-invocation goes through EP-41's 'runWorkflowWith'
--   carrying 'runOptions', so a resumed run honours the same snapshot/telemetry
--   options as its first run.
--
-- Discovery is the single 'findUnfinishedWorkflowIds' index query, and it is
-- exact: a workflow parked on an unresolved wake source is /not/ returned, so a
-- pass over a thousand parked approval flows costs one query. Every path that
-- resolves or abandons a wake (a journal append, an awakeable cancellation)
-- writes the instance row in the same transaction, which is what makes the
-- workflow visible again. Each candidate is claimed through an expiry-based row lease in
-- @keiro_workflows@ before it is advanced. A live foreign lease skips only that
-- instance and increments 'leaseSkipped'; a dead worker's lease becomes claimable
-- after 'leaseTtl'. Each fresh workflow boundary renews the lease before running
-- side effects. The lease prevents duplicate steady-state work, while the journal
-- append path still serializes same-step writers so lease expiry races converge
-- on one recorded result. There is __no kiroku @wf:@ prefix subscription__ and no
-- session-level advisory lock.
module Keiro.Workflow.Resume
  ( -- * Registry
    WorkflowDef (..),
    WorkflowRegistry,

    -- * Options
    WorkflowResumeOptions (..),
    ResumeLogEvent (..),
    defaultWorkflowResumeOptions,

    -- * Per-pass summary
    ResumeSummary (..),
    emptyResumeSummary,

    -- * Running (fixed-poll baseline)
    resumeWorkflowsOnce,
    resumeWorkflowsOnceUpTo,
    runWorkflowResumeWorker,
    runWorkflowResumeWorkerWith,

    -- * Running (push-aware, EP-50)
    runPollLoopWith,
    runWorkflowResumeWorkerPush,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception qualified as Exception
import Control.Monad (forever)
import Data.Aeson qualified as Aeson
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4
import Effectful (Eff, IOE, raise, (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async (pooledMapConcurrentlyN)
import Effectful.Error.Static (Error)
import Effectful.Error.Static qualified as Error
import Effectful.Exception (catch, catchSync, finally, throwIO)
import Keiro.Prelude
import Keiro.Telemetry
  ( recordWorkflowAwakeablesPending,
    recordWorkflowFailed,
    recordWorkflowLeaseSkipped,
    recordWorkflowResumeErrors,
    recordWorkflowResumed,
  )
import Keiro.Wake (WakeSignal (..), wakeSignalFromStore)
import Keiro.Workflow
  ( JournalAppendOutcome (..),
    LeaseHeartbeat (..),
    Workflow,
    WorkflowError (..),
    WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowLeaseLost (..),
    WorkflowName (..),
    WorkflowOutcome (..),
    WorkflowRunOptions,
    appendJournalEntry,
    currentGeneration,
    defaultWorkflowRunOptions,
    findUnfinishedWorkflowIds,
    prepareJournalAppend,
    runWorkflowWith,
  )
import Keiro.Workflow.Awakeable.Schema (countPendingAwakeables)
import Keiro.Workflow.Child (runChildWorkflow)
import Keiro.Workflow.Child.Schema (ChildRow, lookupChild, markChildFailedTx)
import Keiro.Workflow.Instance (claimInstance, recordCrashTx, releaseInstance)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (Store, runStoreIO)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import System.IO (hPutStrLn, stderr)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

-- | How to re-build a workflow's body from its id, for one workflow name.
--
-- The result type @a@ is existential: the worker discards it (it cares only
-- whether a re-invocation reached 'Completed' or 'Suspended'), so one registry
-- can hold workflows of different return types.
data WorkflowDef es = forall a. (Aeson.ToJSON a) => WorkflowDef
  { runDef :: WorkflowId -> Eff (Workflow : es) a
  }

-- | The application-supplied map from workflow name to its definition. The
-- worker looks up each discovered workflow's name here; an absent name is
-- skipped and counted as 'unknownName' (a deploy that dropped a workflow while
-- instances were still in flight — surfaced, not silently lost).
type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

-- | Options for the resume worker. Mirrors the @TimerWorkerOptions@ shape:
-- 'runOptions' threads EP-41's snapshot/telemetry options into 'runWorkflowWith',
-- and 'pollInterval' is the loop driver's gap between passes.
data WorkflowResumeOptions = WorkflowResumeOptions
  { -- | Threaded into 'runWorkflowWith' (or 'runChildWorkflow' for a child) so a
    --     resumed run honours the same snapshot (EP-41) and telemetry (EP-44)
    --     options as its first run.
    runOptions :: !WorkflowRunOptions,
    -- | Microseconds the loop driver sleeps between passes.
    pollInterval :: !Int,
    -- | Workflow-level synchronous exceptions before terminal failure.
    maxAttempts :: !Int,
    -- | How long a claimed workflow instance stays leased without reaching
    --     another fresh workflow boundary. It bounds dead-worker recovery time and
    --     must exceed the longest single step action or await arm.
    leaseTtl :: !NominalDiffTime,
    -- | How many discovered workflows one pass may advance at the same time.
    --
    --     The default is 1: strictly sequential, which is what every release
    --     before this option did. Raising it is safe by construction — a pass
    --     never advances one instance twice (discovery returns one row per
    --     instance), each advance holds its own lease, and the per-step advisory
    --     lock already serializes same-step writers across processes — but it
    --     multiplies the database traffic a pass can have in flight, so it should
    --     be set against the store's connection-pool headroom rather than the
    --     candidate count. Values below 1 are treated as 1.
    maxConcurrentAdvances :: !Int,
    -- | Per-worker logging hook. Defaults to a compact stderr renderer.
    --
    --     Called from every thread a pass advances on, so a hook must be
    --     thread-safe when 'maxConcurrentAdvances' exceeds 1. The default
    --     @hPutStrLn stderr@ renderer qualifies: lines may interleave with other
    --     output but are not corrupted.
    logEvent :: !(ResumeLogEvent -> IO ())
  }
  deriving stock (Generic)

data ResumeLogEvent
  = ResumeUnknownName !Text !Text
  | ResumeTransientError !Text !Text !Text
  | ResumeWorkflowCrashed !Text !Text !Int !Int !Text
  | -- | @name@, @id@: the workflow reached a terminal status between crashing
    -- and having that crash recorded, so no attempt was counted against it.
    ResumeCrashRecordSkipped !Text !Text
  | ResumeWorkflowMarkedFailed !Text !Text !Text
  | ResumePassFailed !Text
  deriving stock (Eq, Show)

-- | Defaults: EP-41's 'defaultWorkflowRunOptions', a 1-second poll, a 60-second
-- lease, and sequential advancement.
defaultWorkflowResumeOptions :: WorkflowResumeOptions
defaultWorkflowResumeOptions =
  WorkflowResumeOptions
    { runOptions = defaultWorkflowRunOptions,
      pollInterval = 1_000_000,
      maxAttempts = 5,
      leaseTtl = 60,
      maxConcurrentAdvances = 1,
      logEvent = defaultResumeLogEvent
    }

defaultResumeLogEvent :: ResumeLogEvent -> IO ()
defaultResumeLogEvent event =
  hPutStrLn stderr $ case event of
    ResumeUnknownName name wid ->
      "keiro resume worker: no registry entry for workflow "
        <> Text.unpack name
        <> " (id "
        <> Text.unpack wid
        <> "); skipping"
    ResumeTransientError name wid err ->
      "keiro resume worker: transient store error while advancing "
        <> Text.unpack name
        <> " (id "
        <> Text.unpack wid
        <> "): "
        <> Text.unpack err
    ResumeWorkflowCrashed name wid attempt maxAttempt err ->
      "keiro resume worker: workflow "
        <> Text.unpack name
        <> " (id "
        <> Text.unpack wid
        <> ") crashed on attempt "
        <> show attempt
        <> "/"
        <> show maxAttempt
        <> ": "
        <> Text.unpack err
    ResumeCrashRecordSkipped name wid ->
      "keiro resume worker: workflow "
        <> Text.unpack name
        <> " (id "
        <> Text.unpack wid
        <> ") went terminal while its crash was being recorded; skipping"
    ResumeWorkflowMarkedFailed name wid err ->
      "keiro resume worker: marked workflow "
        <> Text.unpack name
        <> " (id "
        <> Text.unpack wid
        <> ") failed: "
        <> Text.unpack err
    ResumePassFailed err ->
      "keiro resume worker: pass failed: " <> Text.unpack err

-- ---------------------------------------------------------------------------
-- Per-pass summary
-- ---------------------------------------------------------------------------

-- | What one 'resumeWorkflowsOnce' pass did. EP-44 instruments this for
-- @keiro.workflow.resumed@.
data ResumeSummary = ResumeSummary
  { -- | Unfinished workflows 'findUnfinishedWorkflowIds' returned this pass.
    discovered :: !Int,
    -- | Workflows re-invoked (found in the registry and run).
    resumed :: !Int,
    -- | Re-invocations that reached 'Completed' this pass.
    completed :: !Int,
    -- | Re-invocations that returned 'Suspended' (wake source not yet resolved).
    stillSuspended :: !Int,
    -- | Discovered workflows whose name was absent from the registry (skipped + logged).
    unknownName :: !Int,
    -- | Workflows marked terminally failed this pass.
    failed :: !Int,
    -- | Store errors observed while advancing individual workflows.
    transientErrors :: !Int,
    -- | Candidates skipped because another worker holds a live lease.
    leaseSkipped :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | A zeroed 'ResumeSummary'.
emptyResumeSummary :: ResumeSummary
emptyResumeSummary = ResumeSummary 0 0 0 0 0 0 0 0

-- | Field-wise addition. A pass builds its summary by combining one
-- single-instance delta per advanced candidate with a seed carrying
-- 'discovered', so the result is the same whether the candidates were advanced
-- sequentially or concurrently.
instance Semigroup ResumeSummary where
  a <> b =
    ResumeSummary
      { discovered = discovered a + discovered b,
        resumed = resumed a + resumed b,
        completed = completed a + completed b,
        stillSuspended = stillSuspended a + stillSuspended b,
        unknownName = unknownName a + unknownName b,
        failed = failed a + failed b,
        transientErrors = transientErrors a + transientErrors b,
        leaseSkipped = leaseSkipped a + leaseSkipped b
      }

instance Monoid ResumeSummary where
  mempty = emptyResumeSummary

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

-- | Run one discover-and-reinvoke pass.
--
-- Discovers every workflow with progress to make via
-- 'findUnfinishedWorkflowIds' (a workflow suspended on an unresolved wake
-- source is deliberately not discovered), and for each looks its name up in
-- @registry@:
--
-- * __present__ — re-invoke through 'runWorkflowWith' (the journal pre-load
--   short-circuits already-journaled steps, so only the un-journaled tail runs);
--   the outcome bumps 'completed' or 'stillSuspended'.
-- * __absent__ — log a warning and bump 'unknownName' (a workflow whose code was
--   removed while instances were in flight must be visible, not silently lost).
--
-- Candidates are advanced one at a time by default. Raising
-- 'maxConcurrentAdvances' advances that many at once, which is what a pass
-- wants when step bodies are slow; the reported summary is unchanged either
-- way, because each candidate contributes its own delta and the deltas are
-- added at the end.
--
-- Idempotent: a completed workflow has a @__workflow_completed__@ index row and
-- so drops out of discovery; re-invoking an unfinished one twice converges to the
-- same journal (EP-38 deterministic ids + step short-circuit).
resumeWorkflowsOnce ::
  forall es.
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowResumeOptions ->
  WorkflowRegistry es ->
  Eff es ResumeSummary
resumeWorkflowsOnce = resumeWorkflowsOnceUpTo maxBound

-- | Run one discover-and-reinvoke pass over at most the supplied number of
-- candidates. This is the bounded operator-facing sibling of
-- 'resumeWorkflowsOnce'; a non-positive limit performs the discovery query but
-- advances no workflow. The summary's 'discovered' count is the number admitted
-- to this pass, so a caller can safely repeat bounded passes until it reaches
-- zero.
resumeWorkflowsOnceUpTo ::
  forall es.
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Int ->
  WorkflowResumeOptions ->
  WorkflowRegistry es ->
  Eff es ResumeSummary
resumeWorkflowsOnceUpTo limit opts registry = do
  -- EP-44: sample the @keiro.workflow.awakeables.pending@ gauge once per pass,
  -- on the same Store the discovery query uses. The metrics handle rides on the
  -- run options (EP-44 threads telemetry through 'WorkflowRunOptions'), so it is
  -- already forwarded into 'runWorkflowWith' for every re-invocation.
  pending <- countPendingAwakeables
  recordWorkflowAwakeablesPending mMetrics (fromIntegral pending)
  -- Discovery is the single 'findUnfinishedWorkflowIds' query over the instance
  -- table, and it is exact: an instance is returned only when its row says it
  -- has progress to make. A freshly-spawned child needs no separate seed —
  -- 'Keiro.Workflow.Child.spawnChild' upserts the child's instance row as
  -- 'running' inside the spawn step's transaction (and migration 0011
  -- backfilled the running children that predate the instance table), so a
  -- zero-step child is already visible here.
  now <- liftIO getCurrentTime
  pairs <- take (max 0 limit) <$> findUnfinishedWorkflowIds now
  let seed = emptyResumeSummary {discovered = length pairs}
  owner <- UUID.toText <$> liftIO UUIDv4.nextRandom
  deltas <- advanceAll owner pairs
  pure (mconcat (seed : deltas))
  where
    mMetrics = runOptions opts ^. #metrics
    -- Every candidate produces a summary delta for itself, and the deltas are
    -- added at the end, so the pass's summary does not depend on the order the
    -- candidates finish in. Concurrency is safe here for the same reason it is
    -- safe across processes: discovery returns one row per instance, so no two
    -- candidates address the same workflow, each advance holds its own lease,
    -- and the append path's per-step advisory lock still serializes same-step
    -- writers. It is opt-in because it multiplies in-flight database traffic.
    advanceAll :: Text -> [(Text, Text)] -> Eff es [ResumeSummary]
    advanceAll owner pairs
      | maxConcurrentAdvances opts <= 1 = traverse (advance owner) pairs
      | otherwise =
          runConcurrent $
            pooledMapConcurrentlyN
              (maxConcurrentAdvances opts)
              (raise . advance owner)
              pairs
    advance :: Text -> (Text, Text) -> Eff es ResumeSummary
    advance owner (widText, wnameText) =
      case Map.lookup (WorkflowName wnameText) registry of
        Nothing -> do
          liftIO $ logEvent opts (ResumeUnknownName wnameText widText)
          pure emptyResumeSummary {unknownName = 1}
        Just (WorkflowDef runDef) -> do
          let wid = WorkflowId widText
              name = WorkflowName wnameText
          claimed <- claimInstance owner (leaseTtl opts) name wid
          if not claimed
            then do
              recordWorkflowLeaseSkipped mMetrics 1
              pure emptyResumeSummary {leaseSkipped = 1}
            else do
              progressedRef <- liftIO (newIORef False)
              ( do
                  attempt <-
                    Error.catchError
                      @StoreError
                      (AdvOk <$> driveInstance owner name wid runDef)
                      (\_ e -> pure (AdvTransient e))
                      `catch` (\WorkflowLeaseLost -> pure AdvLeaseLost)
                      `catchSync` (pure . AdvCrashed)
                  recordWorkflowResumed mMetrics 1
                  (delta, progressed) <- handleAttempt emptyResumeSummary name wid attempt
                  liftIO (writeIORef progressedRef progressed)
                  pure delta
                )
                `finally` do
                  progressed <- liftIO (readIORef progressedRef)
                  releaseInstance owner progressed name wid
    driveInstance :: (Aeson.ToJSON a) => Text -> WorkflowName -> WorkflowId -> (WorkflowId -> Eff (Workflow : es) a) -> Eff es (WorkflowOutcome a)
    driveInstance owner name@(WorkflowName wnameText) wid@(WorkflowId widText) runDef = do
      mChild <- lookupChild widText wnameText
      let runOpts =
            runOptions opts
              & #leaseHeartbeat
              .~ Just LeaseHeartbeat {owner, ttl = leaseTtl opts}
      case mChild of
        Just _ -> runChildWorkflow runOpts name wid (runDef wid)
        Nothing -> runWorkflowWith runOpts name wid (runDef wid)
    handleAttempt :: ResumeSummary -> WorkflowName -> WorkflowId -> AdvanceResult a -> Eff es (ResumeSummary, Bool)
    handleAttempt acc name@(WorkflowName wnameText) wid@(WorkflowId widText) = \case
      AdvOk outcome -> do
        pure (bumpForOutcome outcome acc, True)
      AdvTransient err -> do
        let rendered = Text.pack (show err)
        liftIO $ logEvent opts (ResumeTransientError wnameText widText rendered)
        recordWorkflowResumeErrors mMetrics 1
        pure (acc {resumed = resumed acc + 1, transientErrors = transientErrors acc + 1}, False)
      AdvLeaseLost -> do
        recordWorkflowLeaseSkipped mMetrics 1
        pure (acc {leaseSkipped = leaseSkipped acc + 1}, False)
      AdvCrashed err -> do
        let rendered = Text.pack (show err)
        mAttempt <- runTransaction (recordCrashTx widText wnameText rendered)
        case mAttempt of
          -- The instance went terminal between the crash and the crash record,
          -- so the update matched no row. There is nothing left to pace and
          -- nothing to fail: log it, count it with the other things that went
          -- wrong while advancing this instance, and leave the rest of the pass
          -- alone. Before this arm existed the zero-row result failed a
          -- single-row decoder and aborted every remaining candidate.
          Nothing -> do
            liftIO $ logEvent opts (ResumeCrashRecordSkipped wnameText widText)
            recordWorkflowResumeErrors mMetrics 1
            pure (acc {resumed = resumed acc + 1, transientErrors = transientErrors acc + 1}, False)
          Just attempt -> do
            liftIO $ logEvent opts (ResumeWorkflowCrashed wnameText widText (fromIntegral attempt) (maxAttempts opts) rendered)
            if attempt >= fromIntegral (maxAttempts opts :: Int)
              then do
                now <- liftIO getCurrentTime
                mChild <- lookupChild widText wnameText
                case mChild of
                  Nothing ->
                    appendJournalEntry name wid (WorkflowFailed rendered now)
                  Just childRow ->
                    appendFailedChildAndWakeParent name wid rendered now childRow
                liftIO $ logEvent opts (ResumeWorkflowMarkedFailed wnameText widText rendered)
                recordWorkflowFailed mMetrics 1
                pure (acc {resumed = resumed acc + 1, failed = failed acc + 1}, False)
              else pure (acc {resumed = resumed acc + 1}, False)

data AdvanceResult a
  = AdvOk !(WorkflowOutcome a)
  | AdvTransient !StoreError
  | AdvLeaseLost
  | AdvCrashed !Exception.SomeException

appendFailedChildAndWakeParent ::
  (IOE :> es, Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  Text ->
  UTCTime ->
  ChildRow ->
  Eff es ()
appendFailedChildAndWakeParent childNm childWid reason now childRow = do
  childGen <- currentGeneration childNm childWid
  let parentNm = WorkflowName (childRow ^. #parentName)
      parentWid = WorkflowId (childRow ^. #parentId)
  parentGen <- currentGeneration parentNm parentWid
  childFailTx <- prepareJournalAppend childNm childWid childGen (WorkflowFailed reason now)
  parentWakeTx <-
    prepareJournalAppend
      parentNm
      parentWid
      parentGen
      StepRecorded
        { stepName = childRow ^. #awaitStep,
          result = Aeson.object ["failed" Aeson..= reason],
          recordedAt = now
        }
  (childOutcome, parentOutcome) <-
    runTransaction $ do
      childOutcome <- childFailTx
      _transitioned <- markChildFailedTx (unWorkflowId childWid) (unWorkflowName childNm) reason
      parentOutcome <- parentWakeTx
      condemnOnAppendConflict childOutcome
      condemnOnAppendConflict parentOutcome
      pure (childOutcome, parentOutcome)
  throwOnAppendConflict childOutcome
  throwOnAppendConflict parentOutcome

-- A refusal is deliberately not condemned: the child's own failure marker and
-- its child-row transition must commit even when the parent is already terminal
-- and cannot receive the failure sentinel.
condemnOnAppendConflict :: JournalAppendOutcome -> Tx.Transaction ()
condemnOnAppendConflict = \case
  JournalAppendConflict {} -> Tx.condemn
  JournalRefusedTerminal {} -> pure ()
  _ -> pure ()

throwOnAppendConflict :: JournalAppendOutcome -> Eff es ()
throwOnAppendConflict = \case
  JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))
  -- Not an error: a terminal parent simply receives nothing.
  JournalRefusedTerminal {} -> pure ()
  _ -> pure ()

-- | Fold one re-invocation's outcome into the running summary. The existential
-- result @a@ is discarded here, so it never escapes the registry.
bumpForOutcome :: WorkflowOutcome a -> ResumeSummary -> ResumeSummary
bumpForOutcome outcome acc = case outcome of
  Completed _ -> acc {resumed = resumed acc + 1, completed = completed acc + 1}
  Suspended -> acc {resumed = resumed acc + 1, stillSuspended = stillSuspended acc + 1}
  -- A workflow cancelled between discovery and re-invocation short-circuits to
  -- 'Cancelled' (EP-43); count it as re-invoked but neither completed nor
  -- suspended. (A cancelled workflow also drops out of discovery, so this is a
  -- rare race, not the steady state.)
  Cancelled -> acc {resumed = resumed acc + 1}
  Failed -> acc {resumed = resumed acc + 1}
  -- A workflow that rotated via continueAsNew (EP-48) returns 'ContinuedAsNew':
  -- it is re-invoked but neither completed nor suspended this pass. Its new
  -- generation has no terminal marker, so 'findUnfinishedWorkflowIds' still
  -- reports it and the next pass drives the rotated generation forward.
  ContinuedAsNew -> acc {resumed = resumed acc + 1}

-- | Poll-and-resume loop: run 'resumeWorkflowsOnce' on the configured
-- 'pollInterval' forever. Mirrors how an application schedules
-- 'Keiro.Outbox.publishClaimedOutbox' \/ @runTimerWorker@ per tick; the
-- single-pass 'resumeWorkflowsOnce' remains the testable unit.
runWorkflowResumeWorkerWith ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowResumeOptions ->
  WorkflowRegistry es ->
  Eff es ()
runWorkflowResumeWorkerWith opts registry = forever $ do
  _summary <-
    (Just <$> resumeWorkflowsOnce opts registry)
      `Error.catchError` (\_ (e :: StoreError) -> logPass (Text.pack (show e)))
      `catchSync` (logPass . Text.pack . show)
  liftIO (threadDelay (pollInterval opts))
  where
    logPass msg = do
      liftIO $ logEvent opts (ResumePassFailed msg)
      pure Nothing

-- | 'runWorkflowResumeWorkerWith' with 'defaultWorkflowResumeOptions'.
runWorkflowResumeWorker ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  WorkflowRegistry es ->
  Eff es ()
runWorkflowResumeWorker = runWorkflowResumeWorkerWith defaultWorkflowResumeOptions

-- ---------------------------------------------------------------------------
-- Push-aware loop (EP-50)
-- ---------------------------------------------------------------------------

-- | Generic push-aware poll loop: run one pass, then block on the 'WakeSignal'
-- with the given fallback timeout (microseconds), forever. The pass is the durable
-- unit; the wake only shortens the gap between passes. Both wake reasons (a
-- notification or the fallback elapsing) mean "run another pass", so the returned
-- 'Keiro.Wake.WakeReason' is ignored for control flow. A missed @NOTIFY@ costs at
-- most one fallback interval of latency, never lost work — correctness rests on the
-- pass (e.g. 'resumeWorkflowsOnce'), which is idempotent, not on a notification
-- arriving. The same pattern applies mechanically to 'Keiro.Timer.runTimerWorker'
-- and 'Keiro.Outbox.publishClaimedOutbox' (documented, not implemented here; the
-- resume worker carries the acceptance via parent/child cascades).
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

-- | The workflow resume worker, push-aware (EP-50). Runs 'resumeWorkflowsOnce'
-- on each pass; between passes it waits on the store's notifier (sub-second wake on
-- any append) and falls back to 'pollInterval' so a dropped notification still
-- drains the backlog.
--
-- This is the push-aware sibling of 'runWorkflowResumeWorker' /
-- 'runWorkflowResumeWorkerWith', which remain unchanged as the durable fixed-poll
-- baseline. The 'pollInterval' field is __repurposed__ as the /fallback/ timeout:
-- its meaning shifts from "fixed gap between passes" to "maximum gap when no
-- notification arrives" — strictly better for latency, identical in the
-- no-notification worst case.
--
-- It opens __no__ new database connection (the 'WakeSignal' rides kiroku's existing
-- single per-store listener; see "Keiro.Wake"). It takes the 'KirokuStore' handle
-- directly to reach that notifier, and runs each pass through
-- 'Kiroku.Store.Effect.runStoreIO', which pins the registry's effect row to the
-- concrete @'[Store, Error StoreError, IOE]@ that @runStoreIO@ eliminates. A caller
-- needing a richer effect row can use 'runPollLoopWith' directly with their own
-- @runStoreIO@-equivalent pass.
runWorkflowResumeWorkerPush ::
  KirokuStore ->
  WorkflowResumeOptions ->
  WorkflowRegistry '[Store, Error StoreError, IOE] ->
  IO ()
runWorkflowResumeWorkerPush store opts registry = do
  wake <- wakeSignalFromStore store
  runPollLoopWith wake (pollInterval opts) onePass
  where
    onePass =
      handleSyncIO $
        runStoreIO store (resumeWorkflowsOnce opts registry) >>= \case
          Left err -> logEvent opts (ResumePassFailed (Text.pack (show err)))
          Right _ -> pure ()
    handleSyncIO action =
      action `Exception.catch` \err ->
        case Exception.fromException err of
          Just (async :: Exception.SomeAsyncException) -> Exception.throwIO async
          Nothing -> logEvent opts (ResumePassFailed (Text.pack (show (err :: Exception.SomeException))))
