module Keiro.Timer
  ( TimerId (..)
  , TimerRequest (..)
  , TimerRow (..)
  , TimerStatus (..)
  , initializeTimerSchema
  , scheduleTimerTx
  , claimDueTimer
  , markTimerFired
  , runTimerWorker
  )
where

import Effectful (Eff, (:>))
import Keiro.Prelude
import Keiro.Timer.Schema
import Keiro.Timer.Types
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (EventId)

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
