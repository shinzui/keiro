-- | Shared child-cancellation transaction used by parent-facing and
-- operator-facing APIs.
module Keiro.Workflow.Child.Cancel
  ( ensureChildCancelled,
  )
where

import Data.Aeson qualified as Aeson
import Effectful (Eff, IOE, (:>))
import Keiro.Prelude
import Keiro.Workflow.Child.Schema
  ( ChildRow,
    ChildStatus (..),
    markChildCancelledTx,
  )
import Keiro.Workflow.Journal
  ( JournalAppendOutcome (..),
    prepareJournalAppend,
  )
import Keiro.Workflow.Schema (currentGeneration)
import Keiro.Workflow.Types
  ( WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowName (..),
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | Ensure both durable consequences of cancelling a linked child: the child
-- journal's terminal marker and the parent's cancelled await sentinel.
--
-- The child-row transition and both appends share one transaction. Retrying a
-- historically row-only cancellation repairs the markers without reporting a
-- fresh lifecycle transition.
ensureChildCancelled ::
  (IOE :> es, Store :> es) =>
  ChildRow ->
  Eff es (Bool, JournalAppendOutcome, JournalAppendOutcome)
ensureChildCancelled row = do
  now <- liftIO getCurrentTime
  let childNm = WorkflowName (row ^. #childName)
      childWid = WorkflowId (row ^. #childId)
      parentNm = WorkflowName (row ^. #parentName)
      parentWid = WorkflowId (row ^. #parentId)
  childGen <- currentGeneration childNm childWid
  parentGen <- currentGeneration parentNm parentWid
  childAppendTx <-
    prepareJournalAppend
      childNm
      childWid
      childGen
      WorkflowCancelled {recordedAt = now}
  parentAppendTx <-
    prepareJournalAppend
      parentNm
      parentWid
      parentGen
      StepRecorded
        { stepName = row ^. #awaitStep,
          result = Aeson.object ["cancelled" Aeson..= True],
          recordedAt = now
        }
  runTransaction $ do
    childOutcome <- childAppendTx
    case childOutcome of
      -- Another lifecycle marker won. Do not flip the child row or wake the
      -- parent as cancelled when the child journal says completed/failed.
      JournalRefusedTerminal {} ->
        pure
          ( False,
            childOutcome,
            JournalAlreadyPresent Aeson.Null
          )
      JournalAppendConflict {} -> do
        Tx.condemn
        pure
          ( False,
            childOutcome,
            JournalAlreadyPresent Aeson.Null
          )
      _ -> do
        transitioned <-
          if row ^. #status == Running
            then markChildCancelledTx (row ^. #childId) (row ^. #childName)
            else pure False
        parentOutcome <- parentAppendTx
        condemnOnAppendConflict parentOutcome
        pure (transitioned, childOutcome, parentOutcome)

condemnOnAppendConflict :: JournalAppendOutcome -> Tx.Transaction ()
condemnOnAppendConflict = \case
  JournalAppendConflict {} -> Tx.condemn
  JournalRefusedTerminal {} -> pure ()
  _ -> pure ()
