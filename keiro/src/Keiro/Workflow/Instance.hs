{- | Durable workflow instance summaries.

The journal stream and @keiro_workflow_steps@ index remain the source of truth
for replay. This module maintains one @keiro_workflows@ row per logical
workflow instance so the resume worker can track lifecycle, attempts, and
leases without scanning journal history.
-}
module Keiro.Workflow.Instance (
    WorkflowStatus (..),
    WorkflowInstanceRow (..),
    ResurrectOutcome (..),
    statusToText,
    statusFromText,
    upsertInstanceTx,
    markInstanceSuspended,
    lookupInstance,
    claimInstance,
    renewInstanceLeaseTx,
    renewInstanceLease,
    releaseInstance,
    recordCrashTx,
    resetInstanceAttempts,
    reviveFailedInstanceTx,
    resurrectFailedWorkflow,
)
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Data.Int (Int32)
import Data.Time (NominalDiffTime, addUTCTime)
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Workflow.Child.Schema (reviveFailedChildTx)
import Keiro.Workflow.Schema (currentGeneration, deleteStepRowTx)
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..), failedStepName)
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

data ResurrectOutcome
    = WorkflowResurrected
    | WorkflowNotFailed
    | WorkflowNotFound
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

claimInstance :: (IOE :> es, Store :> es) => Text -> NominalDiffTime -> WorkflowName -> WorkflowId -> Eff es Bool
claimInstance owner ttl name@(WorkflowName nameText) wid@(WorkflowId widText) = do
    now <- liftIO getCurrentTime
    gen <- currentGeneration name wid
    runTransaction $ do
        Tx.statement (widText, nameText, fromIntegral gen :: Int32) ensureInstanceStmt
        fromMaybe False
            <$> Tx.statement
                (widText, nameText, owner, now, addUTCTime ttl now)
                claimInstanceStmt

{- | Extend an instance lease only when @owner@ still holds it.

The caller supplies one clock reading so @updated_at@ and the new expiry share
the same boundary. Returns 'False' after ownership is lost or the row vanishes.
-}
renewInstanceLeaseTx ::
    Text ->
    NominalDiffTime ->
    UTCTime ->
    Text ->
    Text ->
    Tx.Transaction Bool
renewInstanceLeaseTx owner ttl now wid name =
    Tx.statement
        (wid, name, owner, now, addUTCTime ttl now)
        renewInstanceLeaseStmt

-- | Effect-level wrapper around 'renewInstanceLeaseTx' using the current time.
renewInstanceLease ::
    (IOE :> es, Store :> es) =>
    Text ->
    NominalDiffTime ->
    WorkflowName ->
    WorkflowId ->
    Eff es Bool
renewInstanceLease owner ttl (WorkflowName name) (WorkflowId wid) = do
    now <- liftIO getCurrentTime
    runTransaction (renewInstanceLeaseTx owner ttl now wid name)

releaseInstance :: (Store :> es) => Text -> Bool -> WorkflowName -> WorkflowId -> Eff es ()
releaseInstance owner progressed (WorkflowName name) (WorkflowId wid) =
    runTransaction $
        Tx.statement (wid, name, owner, progressed) releaseInstanceStmt

recordCrashTx :: Text -> Text -> Text -> Tx.Transaction Int32
recordCrashTx wid name err =
    Tx.statement (wid, name, err) recordCrashStmt

resetInstanceAttempts :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es ()
resetInstanceAttempts (WorkflowName name) (WorkflowId wid) =
    runTransaction (Tx.statement (wid, name) resetInstanceAttemptsStmt)

reviveFailedInstanceTx :: Text -> Text -> Tx.Transaction Bool
reviveFailedInstanceTx wid name =
    Tx.statement (wid, name) reviveFailedInstanceStmt

{- | Return a terminally failed workflow to the runnable pool.

The operation removes only the current generation's derived failed-marker index
row; the append-only 'Keiro.Workflow.WorkflowFailed' journal event remains as
history. A failed child link is revived in the same transaction. Parent failure
sentinels already delivered to another journal are not retracted.
-}
resurrectFailedWorkflow ::
    (Store :> es) =>
    WorkflowName ->
    WorkflowId ->
    Eff es ResurrectOutcome
resurrectFailedWorkflow name@(WorkflowName nameText) wid@(WorkflowId widText) =
    lookupInstance name wid >>= \case
        Nothing -> pure WorkflowNotFound
        Just row
            | row ^. #status /= WfFailed -> pure WorkflowNotFailed
            | otherwise -> do
                gen <- currentGeneration name wid
                revived <-
                    runTransaction $ do
                        instanceRevived <- reviveFailedInstanceTx widText nameText
                        when instanceRevived $ do
                            deleteStepRowTx widText nameText gen failedStepName
                            void (reviveFailedChildTx widText nameText)
                        pure instanceRevived
                pure $
                    if revived
                        then WorkflowResurrected
                        else WorkflowNotFailed

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

lookupInstanceStmt :: Statement (Text, Text) (Maybe WorkflowInstanceRow)
lookupInstanceStmt =
    preparable
        """
        SELECT workflow_id, workflow_name, generation, status, attempts,
               last_error, next_attempt_at, leased_by, lease_expires_at,
               created_at, updated_at, completed_at
        FROM keiro.keiro_workflows
        WHERE workflow_id = $1 AND workflow_name = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.rowMaybe instanceRowDecoder)

ensureInstanceStmt :: Statement (Text, Text, Int32) ()
ensureInstanceStmt =
    preparable
        """
        INSERT INTO keiro.keiro_workflows
          (workflow_id, workflow_name, generation, status)
        VALUES ($1, $2, $3, 'running')
        ON CONFLICT (workflow_id, workflow_name) DO NOTHING
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
        )
        D.noResult

claimInstanceStmt :: Statement (Text, Text, Text, UTCTime, UTCTime) (Maybe Bool)
claimInstanceStmt =
    preparable
        """
        UPDATE keiro.keiro_workflows
        SET leased_by = $3,
            lease_expires_at = $5,
            updated_at = $4
        WHERE workflow_id = $1
          AND workflow_name = $2
          AND status IN ('running', 'suspended')
          AND (lease_expires_at IS NULL OR lease_expires_at < $4)
          AND (next_attempt_at IS NULL OR next_attempt_at <= $4)
        RETURNING TRUE
        """
        ( contrazip5
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
        )
        (D.rowMaybe (D.column (D.nonNullable D.bool)))

renewInstanceLeaseStmt :: Statement (Text, Text, Text, UTCTime, UTCTime) Bool
renewInstanceLeaseStmt =
    preparable
        """
        UPDATE keiro.keiro_workflows
        SET lease_expires_at = $5,
            updated_at = $4
        WHERE workflow_id = $1
          AND workflow_name = $2
          AND leased_by = $3
        """
        ( contrazip5
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
        )
        ((> 0) <$> D.rowsAffected)

releaseInstanceStmt :: Statement (Text, Text, Text, Bool) ()
releaseInstanceStmt =
    preparable
        """
        UPDATE keiro.keiro_workflows
        SET leased_by = NULL,
            lease_expires_at = NULL,
            attempts = CASE WHEN $4 THEN 0 ELSE attempts END,
            last_error = CASE WHEN $4 THEN NULL ELSE last_error END,
            next_attempt_at = CASE WHEN $4 THEN NULL ELSE next_attempt_at END,
            updated_at = now()
        WHERE workflow_id = $1
          AND workflow_name = $2
          AND leased_by = $3
        """
        ( contrazip4
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.bool))
        )
        D.noResult

recordCrashStmt :: Statement (Text, Text, Text) Int32
recordCrashStmt =
    preparable
        """
        UPDATE keiro.keiro_workflows
        SET attempts = attempts + 1,
            last_error = $3,
            next_attempt_at = now() + (LEAST(power(2, attempts + 1), 64) * interval '1 second'),
            updated_at = now()
        WHERE workflow_id = $1
          AND workflow_name = $2
          AND status NOT IN ('completed', 'cancelled', 'failed')
        RETURNING attempts
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.singleRow (D.column (D.nonNullable D.int4)))

resetInstanceAttemptsStmt :: Statement (Text, Text) ()
resetInstanceAttemptsStmt =
    preparable
        """
        UPDATE keiro.keiro_workflows
        SET attempts = 0,
            last_error = NULL,
            next_attempt_at = NULL,
            updated_at = now()
        WHERE workflow_id = $1
          AND workflow_name = $2
          AND status NOT IN ('completed', 'cancelled', 'failed')
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

reviveFailedInstanceStmt :: Statement (Text, Text) Bool
reviveFailedInstanceStmt =
    preparable
        """
        UPDATE keiro.keiro_workflows
        SET status = 'running',
            attempts = 0,
            last_error = NULL,
            next_attempt_at = NULL,
            leased_by = NULL,
            lease_expires_at = NULL,
            completed_at = NULL,
            updated_at = now()
        WHERE workflow_id = $1
          AND workflow_name = $2
          AND status = 'failed'
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        ((> 0) <$> D.rowsAffected)

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
