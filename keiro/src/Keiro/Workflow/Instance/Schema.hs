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
    upsertSuspendedInstanceTx,
  )
where

import Contravariant.Extras (contrazip5, contrazip6)
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

-- | Suspension holds the awaited step lock before setting this advisory hint.
upsertSuspendedInstanceTx :: Text -> Text -> Int32 -> WorkflowStatus -> Maybe Text -> Tx.Transaction ()
upsertSuspendedInstanceTx wid name gen status hint =
  Tx.statement (wid, name, gen, statusToText status, Nothing, hint) $
    upsertStatement True $
      contrazip6 textParam textParam intParam textParam optionalText optionalText

upsertInstanceStmt :: Statement (Text, Text, Int32, Text, Maybe Text) ()
upsertInstanceStmt = upsertStatement False (contrazip5 textParam textParam intParam textParam optionalText)

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

intParam :: E.Params Int32
intParam = E.param (E.nonNullable E.int4)

optionalText :: E.Params (Maybe Text)
optionalText = E.param (E.nullable E.text)

upsertStatement :: Bool -> E.Params a -> Statement a ()
upsertStatement suspension encoder =
  preparable
    ( """
      INSERT INTO keiro.keiro_workflows
        (workflow_id, workflow_name, generation, status, last_error, completed_at, trace_awaited_step)
      VALUES ($1, $2, $3, $4, $5,
              CASE WHEN $4 IN ('completed', 'cancelled', 'failed') THEN now() ELSE NULL END,
      """
        <> " "
        <> (if suspension then "$6)" else "NULL)")
        <> " "
        <> """
           ON CONFLICT (workflow_id, workflow_name) DO UPDATE
           SET generation = GREATEST(keiro_workflows.generation, EXCLUDED.generation),
               status = EXCLUDED.status,
               last_error = EXCLUDED.last_error,
               trace_awaited_step = CASE
                 WHEN EXCLUDED.generation > keiro_workflows.generation
                   OR EXCLUDED.status IN ('completed', 'cancelled', 'failed') THEN NULL
           """
        <> " "
        <> (if suspension then "WHEN EXCLUDED.generation = keiro_workflows.generation THEN EXCLUDED.trace_awaited_step " else "")
        <> " "
        <> """
                 ELSE keiro_workflows.trace_awaited_step END,
               updated_at = now(),
               completed_at = CASE
                 WHEN EXCLUDED.status IN ('completed', 'cancelled', 'failed')
                   THEN COALESCE(keiro_workflows.completed_at, now())
                 ELSE keiro_workflows.completed_at
               END
           WHERE keiro_workflows.status NOT IN ('completed', 'cancelled', 'failed')
           """
    )
    encoder
    D.noResult
