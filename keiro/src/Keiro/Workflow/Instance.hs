{- | Durable workflow instance summaries.

The journal stream and @keiro_workflow_steps@ index remain the source of truth
for replay. This module maintains one @keiro_workflows@ row per logical
workflow instance so the resume worker can track lifecycle, attempts, and
leases without scanning journal history.
-}
module Keiro.Workflow.Instance (
    WorkflowStatus (..),
    WorkflowInstanceRow (..),
    statusToText,
    statusFromText,
    upsertInstanceTx,
    markInstanceSuspended,
    lookupInstance,
)
where

import Contravariant.Extras (contrazip2, contrazip5)
import Data.Int (Int32)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Workflow.Schema (currentGeneration)
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

data WorkflowStatus
    = WfRunning
    | WfSuspended
    | WfCompleted
    | WfCancelled
    | WfFailed
    deriving stock (Generic, Eq, Show)

data WorkflowInstanceRow = WorkflowInstanceRow
    { workflowId :: !Text
    , workflowName :: !Text
    , generation :: !Int32
    , status :: !WorkflowStatus
    , attempts :: !Int32
    , lastError :: !(Maybe Text)
    , nextAttemptAt :: !(Maybe UTCTime)
    , leasedBy :: !(Maybe Text)
    , leaseExpiresAt :: !(Maybe UTCTime)
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    , completedAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic, Eq, Show)

upsertInstanceTx :: Text -> Text -> Int32 -> WorkflowStatus -> Maybe Text -> Tx.Transaction ()
upsertInstanceTx wid name gen status mLastError =
    Tx.statement (wid, name, gen, statusToText status, mLastError) upsertInstanceStmt

markInstanceSuspended :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es ()
markInstanceSuspended name@(WorkflowName nameText) wid@(WorkflowId widText) = do
    gen <- currentGeneration name wid
    runTransaction $
        upsertInstanceTx widText nameText (fromIntegral gen) WfSuspended Nothing

lookupInstance :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es (Maybe WorkflowInstanceRow)
lookupInstance (WorkflowName name) (WorkflowId wid) =
    runTransaction (Tx.statement (wid, name) lookupInstanceStmt)

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

upsertInstanceStmt :: Statement (Text, Text, Int32, Text, Maybe Text) ()
upsertInstanceStmt =
    preparable
        """
        INSERT INTO keiro_workflows
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

lookupInstanceStmt :: Statement (Text, Text) (Maybe WorkflowInstanceRow)
lookupInstanceStmt =
    preparable
        """
        SELECT workflow_id, workflow_name, generation, status, attempts,
               last_error, next_attempt_at, leased_by, lease_expires_at,
               created_at, updated_at, completed_at
        FROM keiro_workflows
        WHERE workflow_id = $1 AND workflow_name = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.rowMaybe instanceRowDecoder)

instanceRowDecoder :: D.Row WorkflowInstanceRow
instanceRowDecoder =
    WorkflowInstanceRow
        <$> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.int4)
        <*> (statusFromText <$> D.column (D.nonNullable D.text))
        <*> D.column (D.nonNullable D.int4)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)
