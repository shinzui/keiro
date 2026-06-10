{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

{- | EP-3 M5 full-service conformance: a complete process service — the
scaffolded Surge (saga) + Hospital (target) aggregates with FILLED
transducers, plus a FILLED ProcessManager @handle@ — compiled against the live
keiro/keiki runtime. Compiling this component proves the whole multi-aggregate
service builds; running it exercises the pure @handle@: one input yields the
manager-advance command, one dispatched target command, and one timer.
-}
module Main (main) where

import Control.Monad (unless)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Keiro.ProcessManager (ProcessManager (..), ProcessManagerAction (..))
import SurgeDemo.SurgeFlow.Manager (SurgeInput (..), surgeManager)
import System.Exit (exitFailure)

main :: IO ()
main = do
    let input = SurgeInput{hospitalId = "hosp-1", observedAt = posixSecondsToUTCTime 0}
        action = surgeManager.handle input
        nameOk = surgeManager.name == "surge-demo"
        corrOk = surgeManager.correlate input == "hosp-1"
        dispatchOk = length action.commands == 1
        timerOk = length action.timers == 1
    putStrLn ("manager name: " <> show nameOk)
    putStrLn ("correlate: " <> show corrOk)
    putStrLn ("handle dispatches 1 target command: " <> show dispatchOk)
    putStrLn ("handle schedules 1 timer: " <> show timerOk)
    unless (nameOk && corrOk && dispatchOk && timerOk) exitFailure
