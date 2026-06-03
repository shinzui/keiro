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
  , deadLetterTimer

    -- * Worker
  , TimerWorkerOptions (..)
  , defaultTimerWorkerOptions
  , runTimerWorker
  , runTimerWorkerWith
  )
where

import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Keiro.Prelude
import Keiro.Timer.Schema
import Keiro.Timer.Types
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (EventId)

{- | Options controlling 'runTimerWorkerWith'. -}
newtype TimerWorkerOptions = TimerWorkerOptions
  { maxAttempts :: Maybe Int
  -- ^ When @Just n@, a claimed timer whose post-claim @attempts@ exceeds @n@ is
  -- moved to 'Dead' (via 'deadLetterTimer') instead of being fired. @Nothing@
  -- never auto-dead-letters (the historical behavior).
  }
  deriving stock (Generic, Eq, Show)

-- | The default worker policy: never auto-dead-letter.
defaultTimerWorkerOptions :: TimerWorkerOptions
defaultTimerWorkerOptions = TimerWorkerOptions {maxAttempts = Nothing}

{- | Claim and fire at most one timer due at @now@, applying the given
'TimerWorkerOptions'.

Atomically claims the earliest due timer (marking it @Firing@). If the options
set @maxAttempts = Just n@ and the timer's post-claim @attempts@ exceeds @n@, it
is dead-lettered ('Dead', with an explanatory @last_error@) instead of fired —
rather than ping-ponging forever on a timer that never completes. Otherwise the
caller's @fire@ action runs and — if it returns the id of the event it produced
— the timer is marked @Fired@. Returns the claimed 'TimerRow' (the row as
claimed, before any dead-letter or fire UPDATE), or 'Nothing' when nothing is
due. A @fire@ that returns 'Nothing' leaves the timer @Firing@ to be retried on
a later claim.

Note 'claimDueTimer' increments @attempts@ before this check, so the comparison
sees the post-claim count: with @maxAttempts = Just 0@ the very first claim
dead-letters; with @Just 2@ the third claim does.
-}
runTimerWorkerWith ::
  (Store :> es) =>
  TimerWorkerOptions ->
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
runTimerWorkerWith options now fire = do
  due <- claimDueTimer now
  case due of
    Nothing -> pure Nothing
    Just timer ->
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
          for_ fired (markTimerFired (timer ^. #timerId))
          pure (Just timer)

{- | Claim and fire at most one timer due at @now@ using
'defaultTimerWorkerOptions' (no attempt ceiling). Equivalent to
@'runTimerWorkerWith' 'defaultTimerWorkerOptions'@; see 'runTimerWorkerWith' for
the full semantics.
-}
runTimerWorker ::
  (Store :> es) =>
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
runTimerWorker = runTimerWorkerWith defaultTimerWorkerOptions
