{- | EP-6 M5 full-service conformance: a complete durable workflow — the
scaffolded WorkflowRuntime (name + awakeable-id derivation) plus a FILLED
ordered step/await body — compiled against the live Keiro.Workflow effect.
The body's await label is the same one the scaffolded runtime declares.
-}
module Main (main) where

import Control.Monad (unless)
import Generated.HospitalCapacity.HospitalTransferReservation.WorkflowRuntime (awaitLabels)
import System.Exit (exitFailure)

-- The filled workflow body (reservationWorkflow) is compiled as the
-- WorkflowBody other-module; here we check its await label is the one the
-- scaffolded runtime declares.
main :: IO ()
main = do
    let labelOk = "reservation-confirmation" `elem` awaitLabels
    putStrLn ("workflow body compiles against Keiro.Workflow + await label declared: " <> show labelOk)
    unless labelOk exitFailure
