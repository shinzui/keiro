{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
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

import Control.Monad (void, when)
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Effectful (Eff, (:>))
import GHC.Generics (Generic)
import Keiro.Workflow (Workflow, awaitStep, continueAsNew, patch, restoreSeed, step)
import Keiro.Workflow.Types (PatchId (..), StepName (..))

newtype RolloverSeed = RolloverSeed Text
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

reservationWorkflow :: (Workflow :> es) => Eff es Text
reservationWorkflow = do
    restored <- restoreSeed (RolloverSeed "first-generation")
    _hold <- step (StepName "create-transfer-hold") (pure ("hold" :: Text))
    fraudCheckActive <- patch (PatchId "fraud-check-v2")
    when fraudCheckActive $
        void (step (StepName "fraud-check") (pure ("clear" :: Text)))
    confirmed <- awaitStep (StepName "reservation-confirmation") (pure ())
    _released <- step (StepName "release-or-retain-capacity") (pure ("released" :: Text))
    summary <- step (StepName "summarize-reservation") (pure (confirmed <> " summary"))
    continueAsNew (RolloverSeed (summary <> " after " <> seedText restored))
  where
    seedText (RolloverSeed seed) = seed
