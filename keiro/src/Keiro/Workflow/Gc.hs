{- | Optional garbage collection for terminal workflow instances.

The hot-path schema modules keep lifecycle writes and lookup statements. This
module owns only cleanup statements used by an operator-scheduled GC pass.
Eligibility is based on the derived @keiro_workflows@ row: terminal instances
older than the retention cutoff are deleted, except completed children whose
parent is still non-terminal and may still attach to their result.
-}
module Keiro.Workflow.Gc (
    WorkflowGcPolicy (..),
    WorkflowGcSummary (..),
    gcWorkflowsOnce,
    runWorkflowGcWorker,
)
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4)
import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Int (Int32)
import Data.Time (NominalDiffTime, addUTCTime)
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Workflow.Schema (currentGeneration)
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..), workflowGenerationStreamName)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Lifecycle (hardDeleteStream)
import Kiroku.Store.Read (lookupStreamId)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (StreamId (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

data WorkflowGcPolicy = WorkflowGcPolicy
    { retention :: !NominalDiffTime
    , batchSize :: !Int
    }
    deriving stock (Generic, Eq, Show)

data WorkflowGcSummary = WorkflowGcSummary
    { scanned :: !Int
    , deleted :: !Int
    }
    deriving stock (Generic, Eq, Show)

gcWorkflowsOnce :: (Store :> es) => UTCTime -> WorkflowGcPolicy -> Eff es WorkflowGcSummary
gcWorkflowsOnce now policy = do
    let cutoff = addUTCTime (negate (policy ^. #retention)) now
        limit = max 0 (policy ^. #batchSize)
    eligible <- runTransaction (Tx.statement (cutoff, fromIntegral limit :: Int32) eligibleWorkflowsStmt)
    deletedCount <- length <$> traverse deleteWorkflow eligible
    pure WorkflowGcSummary{scanned = length eligible, deleted = deletedCount}

runWorkflowGcWorker :: (IOE :> es, Store :> es) => WorkflowGcPolicy -> Int -> Eff es ()
runWorkflowGcWorker policy pollMicros =
    forever $ do
        now <- liftIO getCurrentTime
        void (gcWorkflowsOnce now policy)
        liftIO (threadDelay pollMicros)

deleteWorkflow :: (Store :> es) => (Text, Text) -> Eff es ()
deleteWorkflow (widText, nameText) = do
    let name = WorkflowName nameText
        wid = WorkflowId widText
    gen <- currentGeneration name wid
    for_ [0 .. gen] $ \generation -> do
        let streamName = workflowGenerationStreamName name wid generation
        mStreamId <- lookupStreamId streamName
        for_ mStreamId $ \(StreamId sid) ->
            runTransaction (Tx.statement sid deleteSnapshotStmt)
        void (hardDeleteStream streamName)
    runTransaction $ do
        Tx.statement (widText, nameText) deleteStepsStmt
        Tx.statement (nameText, widText) deleteAwakeablesStmt
        Tx.statement (widText, nameText, widText, nameText) deleteChildrenStmt
        -- Keep this literal in sync with Keiro.Workflow.Sleep.workflowSleepKind.
        Tx.statement (widText, nameText, workflowSleepKindLiteral) deleteTerminalSleepTimersStmt
        Tx.statement (widText, nameText) deleteWorkflowStmt

workflowSleepKindLiteral :: Text
workflowSleepKindLiteral = "keiro.workflow.sleep"

eligibleWorkflowsStmt :: Statement (UTCTime, Int32) [(Text, Text)]
eligibleWorkflowsStmt =
    preparable
        """
        SELECT w.workflow_id, w.workflow_name
        FROM keiro.keiro_workflows w
        WHERE w.status IN ('completed', 'cancelled', 'failed')
          AND w.completed_at IS NOT NULL
          AND w.completed_at <= $1
          AND NOT EXISTS (
            SELECT 1
            FROM keiro.keiro_workflow_children c
            JOIN keiro.keiro_workflows p
              ON p.workflow_id = c.parent_id
             AND p.workflow_name = c.parent_name
            WHERE c.child_id = w.workflow_id
              AND c.child_name = w.workflow_name
              AND p.status NOT IN ('completed', 'cancelled', 'failed')
          )
        ORDER BY w.completed_at
        LIMIT $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.int4))
        )
        (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

deleteSnapshotStmt :: Statement Int64 ()
deleteSnapshotStmt =
    preparable
        """
        DELETE FROM keiro.keiro_snapshots
        WHERE stream_id = $1
        """
        (E.param (E.nonNullable E.int8))
        D.noResult

deleteStepsStmt :: Statement (Text, Text) ()
deleteStepsStmt =
    preparable
        """
        DELETE FROM keiro.keiro_workflow_steps
        WHERE workflow_id = $1 AND workflow_name = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

deleteAwakeablesStmt :: Statement (Text, Text) ()
deleteAwakeablesStmt =
    preparable
        """
        DELETE FROM keiro.keiro_awakeables
        WHERE owner_workflow_name = $1 AND owner_workflow_id = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

deleteChildrenStmt :: Statement (Text, Text, Text, Text) ()
deleteChildrenStmt =
    preparable
        """
        DELETE FROM keiro.keiro_workflow_children
        WHERE (parent_id = $1 AND parent_name = $2)
           OR (child_id = $3 AND child_name = $4)
        """
        ( contrazip4
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

deleteTerminalSleepTimersStmt :: Statement (Text, Text, Text) ()
deleteTerminalSleepTimersStmt =
    preparable
        """
        DELETE FROM keiro.keiro_timers
        WHERE correlation_id = $1
          AND process_manager_name = $2
          AND payload->>'kind' = $3
          AND status IN ('fired', 'cancelled', 'dead')
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

deleteWorkflowStmt :: Statement (Text, Text) ()
deleteWorkflowStmt =
    preparable
        """
        DELETE FROM keiro.keiro_workflows
        WHERE workflow_id = $1 AND workflow_name = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult
