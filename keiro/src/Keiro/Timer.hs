-- | Durable timers for process managers.
--
-- A process manager schedules a timer ('scheduleTimerTx', in its own append
-- transaction) to be woken at a future time — a saga timeout, a retry delay, a
-- deadline. The 'runTimerWorker' loop claims one due timer at a time with
-- @FOR UPDATE SKIP LOCKED@ (so multiple workers can run safely), hands it to a
-- caller-supplied @fire@ action that typically dispatches a command back into
-- the manager, and marks it fired once the resulting event id is known. A
-- timer left @Firing@ by a crash becomes claimable again after the worker's
-- configured stale-claim timeout, giving at-least-once firing.
--
-- The wire types live in "Keiro.Timer.Types" and the SQL storage in
-- "Keiro.Timer.Schema"; both are re-exported here so most callers need only
-- import @Keiro.Timer@.
module Keiro.Timer
  ( -- * Timer types
    TimerId (..),
    TimerRequest (..),
    TimerRow (..),
    TimerStatus (..),

    -- * Storage
    scheduleTimerTx,
    scheduleTimerOnceTx,
    claimDueTimer,
    markTimerFired,
    countDueTimers,
    countStuckTimers,

    -- * Recovery
    StuckTimerFilter (..),
    anyStuckTimer,
    findStuckTimers,
    requeueStuckTimers,
    requeueStuckTimer,
    cancelTimer,
    deadLetterTimer,

    -- * Worker
    TimerWorkerOptions (..),
    TimerWorkerConfigError (..),
    defaultTimerWorkerOptions,
    mkTimerWorkerOptions,
    runTimerWorker,
    runTimerWorkerWith,
    drainDueTimers,
    drainDueTimersWith,
  )
where

import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
import Effectful (Eff, IOE, (:>))
import Keiro.Prelude
import Keiro.Telemetry
  ( KeiroMetrics,
    recordTimerAttempts,
    recordTimerBacklog,
    recordTimerFireLag,
    recordTimerRequeued,
    recordTimerStuck,
  )
import Keiro.Timer.Schema
import Keiro.Timer.Types
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (EventId)

-- | Options controlling 'runTimerWorkerWith'.
data TimerWorkerOptions = TimerWorkerOptions
  { -- | When @Just n@, a claimed timer whose post-claim @attempts@ exceeds @n@ is
    --     moved to 'Dead' (via 'deadLetterTimer') instead of being fired. @Nothing@
    --     never auto-dead-letters (the historical behavior).
    maxAttempts :: Maybe Int,
    -- | When @Just ttl@, each worker pass first moves @Firing@ timers whose
    --     @updated_at@ is at least @ttl@ old back to 'Scheduled'. A fire action that
    --     runs longer than this timeout may be fired again; timer handlers must be
    --     idempotent under keiro's at-least-once timer contract. @Nothing@ disables
    --     automatic requeue for callers that run their own recovery.
    requeueStuckAfter :: !(Maybe NominalDiffTime)
  }
  deriving stock (Generic, Eq, Show)

data TimerWorkerConfigError
  = InvalidTimerMaxAttempts !Int
  | InvalidTimerRequeueStuckAfter !NominalDiffTime
  deriving stock (Generic, Eq, Show)

-- | The default worker policy: never auto-dead-letter; requeue stale firings after five minutes.
defaultTimerWorkerOptions :: TimerWorkerOptions
defaultTimerWorkerOptions = TimerWorkerOptions {maxAttempts = Nothing, requeueStuckAfter = Just 300}

-- | Validate timer worker options before starting a worker loop.
mkTimerWorkerOptions :: TimerWorkerOptions -> Either TimerWorkerConfigError TimerWorkerOptions
mkTimerWorkerOptions opts =
  case (opts ^. #maxAttempts, opts ^. #requeueStuckAfter) of
    (Just attempts, _) | attempts < 0 -> Left (InvalidTimerMaxAttempts attempts)
    (_, Just ttl) | ttl <= 0 -> Left (InvalidTimerRequeueStuckAfter ttl)
    _ -> Right opts

-- | Claim and fire at most one timer due at @now@, applying the given
-- 'TimerWorkerOptions'.
--
-- Atomically claims the earliest due timer (marking it @Firing@). If the options
-- set @maxAttempts = Just n@ and the timer's post-claim @attempts@ exceeds @n@, it
-- is dead-lettered ('Dead', with an explanatory @last_error@) instead of fired —
-- rather than ping-ponging forever on a timer that never completes. Before
-- claiming, the worker requeues stale @Firing@ rows according to
-- 'requeueStuckAfter'. Otherwise the caller's @fire@ action runs and — if it
-- returns the id of the event it produced — the timer is marked @Fired@. Returns
-- the claimed 'TimerRow' (the row as claimed, before any dead-letter or fire
-- UPDATE), or 'Nothing' when nothing is due. A @fire@ that returns 'Nothing'
-- leaves the timer @Firing@ until it becomes stale and is requeued on a later
-- worker pass.
--
-- A timer may fire more than once if a worker crashes after the external action
-- but before 'markTimerFired', or if @fire@ takes longer than 'requeueStuckAfter'.
-- Handlers must therefore be idempotent.
--
-- Note 'claimDueTimer' increments @attempts@ before this check, so the comparison
-- sees the post-claim count: with @maxAttempts = Just 0@ the very first claim
-- dead-letters; with @Just 2@ the third claim does.
runTimerWorkerWith ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  TimerWorkerOptions ->
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
runTimerWorkerWith metrics options now fire = do
  timerPassPreamble metrics options now
  claimAndFireOne metrics options now fire

-- | The once-per-pass work: requeue stale @Firing@ rows per 'requeueStuckAfter',
-- then record the backlog and stuck gauges. Shared by 'runTimerWorkerWith' and
-- 'drainDueTimersWith' so a batched drain pays for it once rather than once per
-- claimed timer. Each gauge is a no-op under a 'Nothing' handle.
timerPassPreamble ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  TimerWorkerOptions ->
  UTCTime ->
  Eff es ()
timerPassPreamble metrics options now = do
  for_ (options ^. #requeueStuckAfter) $ \ttl -> do
    requeued <- requeueStuckTimers ttl now
    recordTimerRequeued metrics (fromIntegral requeued)
  -- The backlog as the worker sees it at the start of the pass (including the
  -- rows it is about to claim), and the number of rows stranded in 'Firing' by
  -- earlier passes that never completed.
  backlog <- countDueTimers now
  recordTimerBacklog metrics (fromIntegral backlog)
  stuck <- countStuckTimers now anyStuckTimer
  recordTimerStuck metrics (fromIntegral stuck)

-- | Claim the earliest due timer and either dead-letter or fire it. Returns the
-- row as claimed, or 'Nothing' when nothing is due. The per-claim histograms are
-- recorded here, so they stay one-per-claimed-timer in a batched drain.
claimAndFireOne ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  TimerWorkerOptions ->
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
claimAndFireOne metrics options now fire = do
  due <- claimDueTimer now
  case due of
    Nothing -> pure Nothing
    Just timer -> do
      -- Histograms for the claimed timer: how late it fired and how many
      -- attempts it has now taken. EP-33 declared 'keiro.timer.fire.lag' in
      -- milliseconds, so the seconds 'diffUTCTime' yields are scaled by 1000.
      -- The lag is non-negative because only fire_at <= now rows are claimable.
      recordTimerFireLag metrics (realToFrac (now `diffUTCTime` (timer ^. #fireAt)) * 1000)
      recordTimerAttempts metrics (fromIntegral (timer ^. #attempts))
      case options ^. #maxAttempts of
        Just attemptCeiling
          | (timer ^. #attempts) > attemptCeiling -> do
              _ <-
                deadLetterTimer
                  (timer ^. #timerId)
                  ("timer exceeded attempt ceiling of " <> Text.pack (show attemptCeiling))
              pure (Just timer)
        _ -> do
          fired <- fire timer
          for_ fired (\eventId -> void (markTimerFired (timer ^. #timerId) eventId))
          pure (Just timer)

-- | Claim and fire up to @limit@ timers due at @now@ in one pass, returning how
-- many were processed.
--
-- Every per-timer semantic is 'runTimerWorkerWith'’s, unchanged: earliest
-- @fire_at@ first, @FOR UPDATE SKIP LOCKED@ so concurrent workers never claim
-- the same row, the same attempt-ceiling dead-lettering, the same at-least-once
-- contract. What differs is the accounting: the requeue-and-gauge preamble runs
-- once for the whole batch instead of once per timer, so draining a backlog of
-- @K@ due timers costs one preamble rather than @K@ of them.
--
-- The loop stops early when nothing is due, so an idle pass costs exactly what
-- 'runTimerWorkerWith' costs. It also stops when a @fire@ action returns
-- 'Nothing' for every remaining row, because such a timer stays @Firing@ and is
-- no longer claimable — the drain cannot spin. A @limit@ of zero or less
-- processes nothing (but still runs the preamble).
--
-- @now@ is read once by the caller and used for every claim in the batch, so a
-- drain fires exactly the timers that were due at the instant the pass began.
drainDueTimersWith ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  TimerWorkerOptions ->
  UTCTime ->
  -- | Maximum timers to process in this pass.
  Int ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es Int
drainDueTimersWith metrics options now limit fire = do
  timerPassPreamble metrics options now
  go 0
  where
    go processed
      | processed >= limit = pure processed
      | otherwise =
          claimAndFireOne metrics options now fire >>= \case
            Nothing -> pure processed
            Just _ -> go (processed + 1)

-- | 'drainDueTimersWith' using 'defaultTimerWorkerOptions'. The batched sibling
-- of 'runTimerWorker'.
drainDueTimers ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  UTCTime ->
  Int ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es Int
drainDueTimers metrics = drainDueTimersWith metrics defaultTimerWorkerOptions

-- | Claim and fire at most one timer due at @now@ using
-- 'defaultTimerWorkerOptions' (no attempt ceiling). Equivalent to
-- @'runTimerWorkerWith' 'defaultTimerWorkerOptions'@; the default has no attempt
-- ceiling and requeues claims left @Firing@ for five minutes. See
-- 'runTimerWorkerWith' for the full semantics.
runTimerWorker ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
runTimerWorker metrics = runTimerWorkerWith metrics defaultTimerWorkerOptions
