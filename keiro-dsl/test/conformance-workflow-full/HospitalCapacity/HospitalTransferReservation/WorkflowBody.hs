{-# LANGUAGE OverloadedStrings #-}

-- HAND-FILLED workflow body (EP-6 M5 full-service integration): the ordered
-- step/await body — the behaviour-bearing hole — written against the live
-- Keiro.Workflow effect (step / awaitStep), with the journal step names matching
-- the scaffolded WorkflowFacts/WorkflowRuntime labels. The step bodies here are
-- trivial (the agent fills real domain effects); the structure is what the
-- scaffold pins.
module HospitalCapacity.HospitalTransferReservation.WorkflowBody (
    reservationWorkflow,
) where

import Data.Text (Text)
import Effectful (Eff, (:>))
import Keiro.Workflow (Workflow, awaitStep, step)
import Keiro.Workflow.Types (StepName (..))

reservationWorkflow :: (Workflow :> es) => Eff es Text
reservationWorkflow = do
    _hold <- step (StepName "create-transfer-hold") (pure ("hold" :: Text))
    confirmed <- awaitStep (StepName "reservation-confirmation") (pure ())
    _released <- step (StepName "release-or-retain-capacity") (pure ("released" :: Text))
    step (StepName "summarize-reservation") (pure (confirmed <> " summary"))
