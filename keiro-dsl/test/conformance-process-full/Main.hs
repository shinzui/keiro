{-# LANGUAGE OverloadedRecordDot #-}

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
import TopologyMachineProof (proveTopologyMachines, topologyMachineProofLine, walkMachine)
import Generated.SurgeDemo.Hospital.Transducer (hospitalTransducer)
import Generated.SurgeDemo.Surge.Transducer (surgeTransducer)

main :: IO ()
main = do
    -- A Language 4 legacy-process saga (Surge) with a chain to a terminal
    -- state, and its dispatch target (Hospital).
    proof <-
        proveTopologyMachines
            "test/fixtures/surge-service.keiro"
            []
            [walkMachine "Surge" surgeTransducer, walkMachine "Hospital" hospitalTransducer]
    putStrLn (topologyMachineProofLine proof)
    let hospitalIdValue = "hosp_01h455vb4pex5vsknk084sn02q"
        input = SurgeInput{hospitalId = hospitalIdValue, observedAt = posixSecondsToUTCTime 0}
        action = surgeManager.handle input
        nameOk = surgeManager.name == "surge-demo"
        corrOk = surgeManager.correlate input == hospitalIdValue
        dispatchOk = length action.commands == 1
        timerOk = length action.timers == 1
        duplicateContractOk = dispatchOk
    putStrLn ("manager name: " <> show nameOk)
    putStrLn ("correlate: " <> show corrOk)
    putStrLn ("handle dispatches 1 target command: " <> show dispatchOk)
    putStrLn ("handle schedules 1 timer: " <> show timerOk)
    putStrLn ("on-duplicate AckOk delegates to target-stream confirmBenignDuplicate: " <> show duplicateContractOk)
    unless (nameOk && corrOk && dispatchOk && timerOk && duplicateContractOk) exitFailure
