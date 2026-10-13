module Main (main) where

import Data.Text.IO qualified as TIO
import Generated.HistoryDependentHoles.Assignment.BehaviorContract
import Generated.HistoryDependentHoles.Assignment.Domain
import Generated.HistoryDependentHoles.Assignment.Harness (harnessAssertions)
import Generated.HistoryDependentHoles.Assignment.Transducer (assignmentTransducer)
import HistoryDependentHoles.Assignment.BehaviorHoles (behaviorWitnesses)
import Keiki.Core qualified as K
import System.Exit (exitFailure)
import Control.Monad (unless)

main :: IO ()
main = do
  mapM_ printRow harnessAssertions
  TIO.putStr (renderBehaviorConformanceText report)
  mapM_ printRow directAssertions
  unless (all snd (harnessAssertions <> directAssertions)) exitFailure
  where
    printRow (label, passed) = putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)

report :: BehaviorConformanceReport
report = behaviorCoverageReport behaviorWitnesses

directAssertions :: [(String, Bool)]
directAssertions =
  [ ("live clear from empty registers refuses", case K.step assignmentTransducer seed clear of Nothing -> True; Just _ -> False)
  , ("forward stepping never selects the replay-only clear", case K.stepDetailedEither assignmentTransducer seed clear of Left K.NoMatchingEdge {} -> True; _ -> False)
  , ("historical empty clear replays through the replay-only edge", case K.applyEventsDetailedEither assignmentTransducer seed [PropertyCleared (PropertyClearedData "colour")] of
       Right result -> case result.replaySuccessTrace of
         [attribution] -> attribution.replayAttributionMode == K.ReplayOnly && attribution.replayAttributionEdge == K.EdgeRef AssignmentActive 3
         _ -> False
       Left _ -> False)
  , ("behavior conformance passes", behaviorConformancePassed report)
  ]
  where
    seed = (AssignmentActive, initialAssignmentRegs)
    clear = ClearProperty (ClearPropertyData "colour")
