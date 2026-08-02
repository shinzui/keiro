module Main (main) where

import Control.Monad (unless)
import SkelAggregate.Generated.MyService.Thing.Harness (harnessAssertions)
import SkelWorkflow.Generated.MyService.HospitalTransferReservation.WorkflowFacts (WorkflowFacts (workflowFactBody), workflowFacts)

main :: IO ()
main = do
    mapM_ assertHarness harnessAssertions
    unless (not (null (workflowFactBody workflowFacts))) (fail "workflow skeleton emitted no facts")
    putStrLn "PASS  every committed skeleton scaffold compiles"
    putStrLn "PASS  aggregate skeleton harness"
    putStrLn "PASS  workflow skeleton facts"
  where
    assertHarness (label, passed) = unless passed (fail label)
