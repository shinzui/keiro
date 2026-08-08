-- | Shared workflow-instance row state used by both the public instance API and
-- the journal append implementation.
--
-- Keeping this storage layer below both modules avoids a module cycle: journal
-- appends maintain instance summaries, while operator cancellation in
-- "Keiro.Workflow.Instance" must itself append a journal marker.
module Keiro.Workflow.Instance.Schema
  ( WorkflowStatus (..),
    statusToText,
    statusFromText,
    upsertInstanceTx,
  )
where

import Contravariant.Extras (contrazip5)
import Data.Int (Int32)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import "hasql-transaction" Hasql.Transaction qualified as Tx

data WorkflowStatus
  = WfRunning
  | WfSuspended
  | WfCompleted
  | WfCancelled
  | WfFailed
  deriving stock (Generic, Eq, Show)

statusToText :: WorkflowStatus -> Text
statusToText = \case
  WfRunning -> "running"
  WfSuspended -> "suspended"
  WfCompleted -> "completed"
  WfCancelled -> "cancelled"
  WfFailed -> "failed"

statusFromText :: Text -> WorkflowStatus
statusFromText = \case
  "running" -> WfRunning
  "suspended" -> WfSuspended
  "completed" -> WfCompleted
  "cancelled" -> WfCancelled
  "failed" -> WfFailed
  _ -> WfFailed

upsertInstanceTx :: Text -> Text -> Int32 -> WorkflowStatus -> Maybe Text -> Tx.Transaction ()
upsertInstanceTx wid name gen status mLastError =
  Tx.statement (wid, name, gen, statusToText status, mLastError) upsertInstanceStmt

upsertInstanceStmt :: Statement (Text, Text, Int32, Text, Maybe Text) ()
upsertInstanceStmt =
  preparable
    """
    INSERT INTO keiro.keiro_workflows
      (workflow_id, workflow_name, generation, status, last_error, completed_at)
    VALUES ($1, $2, $3, $4, $5,
            CASE WHEN $4 IN ('completed', 'cancelled', 'failed') THEN now() ELSE NULL END)
    ON CONFLICT (workflow_id, workflow_name) DO UPDATE
    SET generation = GREATEST(keiro_workflows.generation, EXCLUDED.generation),
        status = EXCLUDED.status,
        last_error = EXCLUDED.last_error,
        updated_at = now(),
        completed_at = CASE
          WHEN EXCLUDED.status IN ('completed', 'cancelled', 'failed')
            THEN COALESCE(keiro_workflows.completed_at, now())
          ELSE keiro_workflows.completed_at
        END
    WHERE keiro_workflows.status NOT IN ('completed', 'cancelled', 'failed')
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
    )
    D.noResult
