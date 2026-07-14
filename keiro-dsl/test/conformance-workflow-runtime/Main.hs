{-# LANGUAGE OverloadedStrings #-}

{- | EP-6 workflow runtime conformance: the scaffolded @WorkflowRuntime@ — the
WorkflowName and the awakeable-id derivation — compiled against the LIVE
@Keiro.Workflow@. The headline check: the id an `await` allocates equals the
id the partner `signal` operation derives from the same (name, id, label),
computed by the REAL deterministicAwakeableId. A label mismatch diverges.
-}
module Main (main) where

import Control.Monad (unless)
import Generated.HospitalCapacity.HospitalTransferReservation.WorkflowRuntime (
    awaitAwakeableId,
    awaitLabels,
    declaredPatchStepNames,
    declaredPatches,
    withDeclaredPatches,
    workflowName,
 )
import Keiro.Workflow (WorkflowRunOptions (activePatches), defaultWorkflowRunOptions)
import Keiro.Workflow.Awakeable (deterministicAwakeableId)
import Keiro.Workflow.Types (WorkflowId (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    let wid = WorkflowId "rsv-1"
        label = "reservation-confirmation"
        -- the signal operation derives the id the SAME way (same name, id, label).
        signalSide = deterministicAwakeableId workflowName wid label
        awaitSide = awaitAwakeableId wid label
        matchOk = awaitSide == signalSide
        -- a non-matching label must NOT collide.
        mismatchOk = awaitAwakeableId wid "reservation-confirmed" /= awaitSide
        labelsOk = label `elem` awaitLabels
        patchKeysOk = declaredPatchStepNames == ["patch:fraud-check-v2"]
        activePatchesOk = activePatches (withDeclaredPatches defaultWorkflowRunOptions) == declaredPatches
    putStrLn ("await<->signal awakeable id match (real deterministicAwakeableId): " <> show matchOk)
    putStrLn ("mismatched label diverges: " <> show mismatchOk)
    putStrLn ("await label declared: " <> show labelsOk)
    putStrLn ("declared patch journal key uses live patchStepName: " <> show patchKeysOk)
    putStrLn ("run options activate exactly declared patches: " <> show activePatchesOk)
    unless (matchOk && mismatchOk && labelsOk && patchKeysOk && activePatchesOk) exitFailure
