-- | Live conformance for generated declared-await bindings. The first workflow
-- run publishes the id returned by the generated allocation wrapper and
-- suspends. Signalling that exact id must transition the PostgreSQL row, and a
-- second run must complete with the delivered payload.
module Main (main) where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Effectful (Eff, IOE, liftIO, (:>))
import Generated.HospitalCapacity.HospitalTransferReservation.WorkflowRuntime
  ( allocateDeclaredAwait,
    awaitLabels,
    declaredPatchStepNames,
    declaredPatches,
    reservationConfirmationAwait,
    withDeclaredPatches,
    workflowName,
  )
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Keiro.Workflow
  ( Workflow,
    WorkflowOutcome (..),
    WorkflowRunOptions (activePatches),
    defaultWorkflowRunOptions,
    runWorkflow,
  )
import Keiro.Workflow.Awakeable (AwakeableId, signalAwakeable)
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Effect (Store)

main :: IO ()
main =
  withMigratedSuite $ \fixture ->
    withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
      allocatedId <- newIORef Nothing
      let workflowId = WorkflowId "opaque-await-1"

      first <- expectRight =<< runStore (runWorkflow workflowName workflowId (reservationWorkflow allocatedId))
      assert "generated await allocated an opaque id" (first == Suspended)

      awakeableId <- readRequiredId allocatedId
      signalled <- expectRight =<< runStore (signalAwakeable awakeableId ("confirmed" :: Text))
      assert "signal of allocated id transitioned the row" signalled

      second <- expectRight =<< runStore (runWorkflow workflowName workflowId (reservationWorkflow allocatedId))
      assert "workflow resumed with the payload" (second == Completed "confirmed")

      let labelsOk = "reservation-confirmation" `elem` awaitLabels
          patchKeysOk = declaredPatchStepNames == ["patch:fraud-check-v2"]
          activePatchesOk = activePatches (withDeclaredPatches defaultWorkflowRunOptions) == declaredPatches
      assert "workflow runtime conformance" (labelsOk && patchKeysOk && activePatchesOk)

reservationWorkflow ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  IORef (Maybe AwakeableId) ->
  Eff es Text
reservationWorkflow allocatedId = do
  (awakeableId, awaitConfirmation) <- allocateDeclaredAwait reservationConfirmationAwait
  liftIO (writeIORef allocatedId (Just awakeableId))
  awaitConfirmation

readRequiredId :: IORef (Maybe AwakeableId) -> IO AwakeableId
readRequiredId ref =
  readIORef ref >>= \case
    Just awakeableId -> pure awakeableId
    Nothing -> error "workflow suspended before publishing the generated allocation id"

expectRight :: (Show problem) => Either problem value -> IO value
expectRight = either (error . show) pure

assert :: String -> Bool -> IO ()
assert label condition
  | condition = putStrLn (label <> ": PASS")
  | otherwise = error ("workflow runtime conformance failed: " <> label)
