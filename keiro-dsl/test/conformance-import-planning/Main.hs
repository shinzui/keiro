module Main (main) where

import Control.Monad (forM_, unless)
import Generated.ImportPlanningCollisions.CollisionLedger.Harness (harnessAssertions)
import System.Exit (exitFailure)

main :: IO ()
main = do
  forM_ harnessAssertions $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd harnessAssertions) exitFailure
