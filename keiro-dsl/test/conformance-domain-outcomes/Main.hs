module Main (main) where

import DomainOutcomes.Reservation.BehaviorHoles (behaviorWitnesses)
import Generated.DomainOutcomes.Reservation.BehaviorContract
import System.Exit (exitFailure)

main :: IO ()
main = do
  let report = behaviorCoverageReport behaviorWitnesses
  if behaviorConformancePassedWith True report
    then pure ()
    else do
      putStrLn (show report)
      exitFailure
