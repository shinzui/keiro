{- | Durable timers for process managers.

A process manager schedules a timer ('scheduleTimerTx', in its own append
transaction) to be woken at a future time — a saga timeout, a retry delay, a
deadline. The 'runTimerWorker' loop claims one due timer at a time with
@FOR UPDATE SKIP LOCKED@ (so multiple workers can run safely), hands it to a
caller-supplied @fire@ action that typically dispatches a command back into
the manager, and marks it fired once the resulting event id is known. A
timer left @Firing@ by a crash becomes claimable again, giving
at-least-once firing.

The wire types live in "Keiro.Timer.Types" and the SQL storage in
"Keiro.Timer.Schema"; both are re-exported here so most callers need only
import @Keiro.Timer@.
-}
module Keiro.Timer
  ( -- * Timer types
    TimerId (..)
  , TimerRequest (..)
  , TimerRow (..)
  , TimerStatus (..)

    -- * Storage
  , scheduleTimerTx
  , claimDueTimer
  , markTimerFired

    -- * Recovery
  , StuckTimerFilter (..)
  , anyStuckTimer
  , findStuckTimers
  , requeueStuckTimer
  , cancelTimer

    -- * Worker
  , runTimerWorker
  )
where

import Effectful (Eff, (:>))
import Keiro.Prelude
import Keiro.Timer.Schema
import Keiro.Timer.Types
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (EventId)

{- | Claim and fire at most one timer due at @now@.

Atomically claims the earliest due timer (marking it @Firing@), runs @fire@
on it, and — if @fire@ returns the id of the event it produced — marks the
timer @Fired@. Returns the claimed 'TimerRow', or 'Nothing' when nothing is
due. A worker drives this on a schedule (e.g. once per tick); a @fire@ that
returns 'Nothing' leaves the timer @Firing@ to be retried on a later claim.
-}
runTimerWorker ::
  (Store :> es) =>
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
runTimerWorker now fire = do
  due <- claimDueTimer now
  case due of
    Nothing -> pure Nothing
    Just timer -> do
      fired <- fire timer
      for_ fired (markTimerFired (timer ^. #timerId))
      pure (Just timer)
