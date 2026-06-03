{- | The @keiro_workflow_steps@ table: the derived index of journaled
workflow steps.

The journal stream (@wf:\<name\>-\<id\>@) is the source of truth for replay;
this table is a fast-lookup view kept in sync inside the same transaction as
each journal append (see "Keiro.Workflow"). 'recordStepTx' upserts a row;
'loadStepIndex' reads an instance's recorded steps; 'stepExists' checks for
one step; 'findUnfinishedWorkflowIds' discovers workflows that have steps but
no terminal completion marker — the seam EP-42's resume worker builds on.

Callers normally use the re-exports from "Keiro.Workflow" rather than this
module directly.
-}
module Keiro.Workflow.Schema
  ( -- * Rows
    WorkflowStepRow (..)

    -- * Storage
  , recordStepTx

    -- * Read-only lookups
  , loadStepIndex
  , stepExists
  , findUnfinishedWorkflowIds
  )
where

import Contravariant.Extras (contrazip2, contrazip5)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Prelude
import Keiro.Workflow.Types (WorkflowId (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

{- | A row of the @keiro_workflow_steps@ index: the workflow instance and
name, the step name, the step's JSON result, and when it was recorded. The
terminal completion marker is stored as a row whose 'stepName' is
'Keiro.Workflow.Types.completedStepName' and whose 'result' is JSON @null@.
-}
data WorkflowStepRow = WorkflowStepRow
  { workflowId :: !Text
  , workflowName :: !Text
  , stepName :: !Text
  , result :: !Value
  , recordedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

{- | Upsert a step row inside the caller's transaction — an
@INSERT ... ON CONFLICT (workflow_id, step_name) DO NOTHING@, so a replayed
or raced write is a no-op. Called in the same transaction as the journal
append so the index and the journal stay consistent.
-}
recordStepTx :: WorkflowStepRow -> Tx.Transaction ()
recordStepTx row =
  Tx.statement
    ( row ^. #workflowId
    , row ^. #workflowName
    , row ^. #stepName
    , row ^. #result
    , row ^. #recordedAt
    )
    recordStepStmt

{- | Load every recorded step for a workflow instance as a @step name ->
result@ map (includes the terminal completion marker row if present). Exposed
for EP-42's resume worker; the replay handler in "Keiro.Workflow" pre-loads
from the journal stream instead.
-}
loadStepIndex :: (Store :> es) => WorkflowId -> Eff es (Map Text Value)
loadStepIndex (WorkflowId wid) =
  Map.fromList <$> runTransaction (Tx.statement wid loadStepIndexStmt)

{- | Whether a workflow instance already has an index row for the given step
name. Used to make journal re-appends idempotent without relying on the event
store's duplicate-id rejection.
-}
stepExists :: (Store :> es) => WorkflowId -> Text -> Eff es Bool
stepExists (WorkflowId wid) key =
  runTransaction (Tx.statement (wid, key) stepExistsStmt)

{- | Return the @(workflow_id, workflow_name)@ of every workflow that has at
least one step row but no terminal marker row — i.e. workflows that are
unfinished. A terminal marker is a @__workflow_completed__@ row or (EP-43) a
@__workflow_cancelled__@ row, so a cancelled workflow is treated as finished
and drops out of resume discovery. EP-42's resume worker consumes this to
discover what to re-invoke.
-}
findUnfinishedWorkflowIds :: (Store :> es) => Eff es [(Text, Text)]
findUnfinishedWorkflowIds =
  runTransaction (Tx.statement () findUnfinishedWorkflowIdsStmt)

recordStepStmt :: Statement (Text, Text, Text, Value, UTCTime) ()
recordStepStmt =
  preparable
    """
    INSERT INTO keiro_workflow_steps
      (workflow_id, workflow_name, step_name, result, recorded_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (workflow_id, step_name) DO NOTHING
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.jsonb))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

loadStepIndexStmt :: Statement Text [(Text, Value)]
loadStepIndexStmt =
  preparable
    """
    SELECT step_name, result
    FROM keiro_workflow_steps
    WHERE workflow_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))

stepExistsStmt :: Statement (Text, Text) Bool
stepExistsStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1 FROM keiro_workflow_steps
      WHERE workflow_id = $1 AND step_name = $2
    )
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.singleRow (D.column (D.nonNullable D.bool)))

-- The literals '__workflow_completed__' / '__workflow_cancelled__' must match
-- 'Keiro.Workflow.Types.completedStepName' / '.cancelledStepName'.
findUnfinishedWorkflowIdsStmt :: Statement () [(Text, Text)]
findUnfinishedWorkflowIdsStmt =
  preparable
    """
    SELECT DISTINCT s.workflow_id, s.workflow_name
    FROM keiro_workflow_steps s
    WHERE NOT EXISTS (
      SELECT 1 FROM keiro_workflow_steps c
      WHERE c.workflow_id = s.workflow_id
        AND c.step_name IN ('__workflow_completed__', '__workflow_cancelled__')
    )
    """
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))
