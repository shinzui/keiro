{- | Conformance driver for the EP-6 workflow facts harness. The scaffolded
WorkflowFacts module exports the workflow's deterministic decisions; this
driver asserts them against a HAND-WRITTEN expectation, so a spec change
(e.g. renaming the await label) diverges and reddens a specific assertion.
-}
module Main (main) where

import Control.Monad (forM_, unless)
import Generated.HospitalCapacity.HospitalTransferReservation.WorkflowFacts (WorkflowFacts (..), workflowFacts)
import System.Exit (exitFailure)

expected :: WorkflowFacts
expected =
    WorkflowFacts
        { name = "hospital-transfer-reservation"
        , idVia = "idText"
        , idField = "reservationId"
        , body =
            [ "step:create-transfer-hold"
            , "patch:fraud-check-v2(step:fraud-check)"
            , "await:reservation-confirmation"
            , "step:release-or-retain-capacity"
            , "step:summarize-reservation"
            , "continueAsNew:RolloverSeed"
            ]
        , awaitLabels = ["reservation-confirmation"]
        , patchIds = ["fraud-check-v2"]
        }

main :: IO ()
main = do
    let results =
            [ ("name", workflowFacts.name == expected.name)
            , ("idVia", workflowFacts.idVia == expected.idVia)
            , ("idField", workflowFacts.idField == expected.idField)
            , ("body", workflowFacts.body == expected.body)
            , ("awaits", workflowFacts.awaitLabels == expected.awaitLabels)
            , ("patches", workflowFacts.patchIds == expected.patchIds)
            ]
    forM_ results $ \(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    let failed = [label | (label, ok) <- results, not ok]
    unless (null failed) $ putStrLn ("workflow facts: failed " <> show failed) >> exitFailure
