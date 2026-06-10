{- | Conformance driver for the EP-6 workflow facts harness. The scaffolded
WorkflowFacts module exports the workflow's deterministic decisions; this
driver asserts them against a HAND-WRITTEN expectation, so a spec change
(e.g. renaming the await label) diverges and reddens a specific assertion.
-}
module Main (main) where

import Control.Monad (forM_, unless)
import Generated.HospitalCapacity.HospitalTransferReservation.WorkflowFacts (workflowFacts)
import System.Exit (exitFailure)

expected :: [(String, String)]
expected =
    [ ("name", "hospital-transfer-reservation")
    , ("idVia", "idText")
    , ("idField", "reservationId")
    , ("body", "step:create-transfer-hold,await:reservation-confirmation,step:release-or-retain-capacity,step:summarize-reservation")
    , ("awaits", "reservation-confirmation") -- the signal operation's id must match this
    ]

main :: IO ()
main = do
    let results = [(label, lookup label workflowFacts == Just want) | (label, want) <- expected]
    forM_ results $ \(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    let failed = [label | (label, ok) <- results, not ok]
    unless (null failed) $ putStrLn ("workflow facts: failed " <> show failed) >> exitFailure
