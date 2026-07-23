{- | The @keiro_workflow_children@ table: durable parent↔child workflow links.

Mirrors the @Keiro.Timer@ \/ @Keiro.Timer.Schema@ and
@Keiro.Workflow.Awakeable.Schema@ split: this module owns the row type, the
'ChildStatus' lifecycle, and the hasql statements; "Keiro.Workflow.Child" owns
the effectful spawn\/await\/cancel surface.

* 'registerChildTx' inserts a @running@ row idempotently (the
  @ON CONFLICT (child_id, child_name) DO NOTHING@ EP-38's @awaitStep@ arming
  contract requires — a resumed parent re-runs the arm on every resume).
* 'lookupChild' \/ 'lookupChildrenOfParent' read rows back (operator
  inspection and the @awaitChild@ arm's cancellation check).
* 'markChildResultTx' transitions a @running@ row to @completed@ (storing the
  child's result), 'markChildCancelledTx' transitions it to @cancelled@, and
  'markChildFailedTx' transitions it to @failed@ while preserving the reason;
  all guard on @status = 'running'@ so a double-resolve is a no-op.
* 'findRunningChildIds' is the resume worker's discovery seed for a zero-step
  child (one that has been spawned but not yet driven, so has no
  @keiro_workflow_steps@ rows for 'findUnfinishedWorkflowIds' to find).
* 'countActiveChildren' counts outstanding children — the seam EP-44 may read
  for a @keiro.workflow.children.active@ gauge.

Callers normally use the surface from "Keiro.Workflow.Child" rather than this
module directly.
-}
module Keiro.Workflow.Child.Schema (
    -- * Rows and status
    ChildStatus (..),
    ChildRow (..),
    statusToText,
    statusFromText,

    -- * Storage (run inside the caller's transaction)
    registerChildTx,
    markChildResultTx,
    markChildCancelledTx,
    markChildFailedTx,

    -- * Read-only lookups
    lookupChild,
    lookupChildrenOfParent,
    childStatus,
    countActiveChildren,
    findRunningChildIds,
)
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

{- | A child workflow's lifecycle, as seen from its parent.

* 'Running' — spawned and not yet finished; the resume worker drives it.
* 'ChildCompleted' — the child reached its own 'Keiro.Workflow.WorkflowCompleted'
  and its result was propagated to the parent journal; terminal.
* 'ChildCancelled' — the parent 'Keiro.Workflow.Child.cancelChild'led it;
  terminal; also the decode fallback for an unrecognized stored value (the same
  defensive choice "Keiro.Timer.Schema" makes).

The constructors are prefixed @Child@ to avoid clashing with
'Keiro.Workflow.WorkflowOutcome''s @Completed@ and the awakeable\/timer
@Cancelled@ constructors.
-}
data ChildStatus
    = Running
    | ChildCompleted
    | ChildCancelled
    | ChildFailed
    deriving stock (Generic, Eq, Show)

{- | A child link row as stored: the child's (id, name), the parent's (id,
name), the parent-journal step the parent awaits ('awaitStep' =
@child:\<childId\>:result@), the live 'status', the child's 'result' (set only
once 'ChildCompleted'), the terminal 'failureReason' (set only once
'ChildFailed'), and the timestamps.
-}
data ChildRow = ChildRow
    { childId :: !Text
    , childName :: !Text
    , parentId :: !Text
    , parentName :: !Text
    , awaitStep :: !Text
    , status :: !ChildStatus
    , result :: !(Maybe Value)
    , failureReason :: !(Maybe Text)
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    , completedAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic, Eq, Show)

{- | Insert a @running@ child link row inside the caller's transaction, given
the child's @(id, name)@, the parent's @(id, name)@, and the parent-journal
step the parent awaits (@await_step@). Idempotent by
@ON CONFLICT (child_id, child_name) DO NOTHING@ — exactly what EP-38's "arm
must be idempotent" contract needs, since the spawn step and every resume's arm
re-run it. @status@, @result@, and the timestamps take their table defaults, so
no clock read is needed at the spawn site (mirrors
'Keiro.Workflow.Awakeable.Schema.registerAwakeableTx').
-}
registerChildTx :: Text -> Text -> Text -> Text -> Text -> Tx.Transaction ()
registerChildTx cid cname pid pname awaitStep =
    Tx.statement (cid, cname, pid, pname, awaitStep) registerChildStmt

{- | Transition a @running@ child to @completed@, storing @result@ and the
completion time, inside the caller's transaction. The @status = 'running'@
guard makes a double-complete a no-op; returns 'True' only when this call
performed the transition.
-}
markChildResultTx :: Text -> Text -> Value -> UTCTime -> Tx.Transaction Bool
markChildResultTx cid cname result now =
    Tx.statement (cid, cname, result, now) markChildResultStmt

{- | Transition a @running@ child to @cancelled@ inside the caller's
transaction. Only @running@ rows match, so an already-completed (or
already-cancelled) child is left untouched and the call returns 'False'.
-}
markChildCancelledTx :: Text -> Text -> Tx.Transaction Bool
markChildCancelledTx cid cname =
    Tx.statement (cid, cname) markChildCancelledStmt

{- | Transition a @running@ child to @failed@, preserving the terminal reason.
The guarded transition and the parent's failure journal append are performed
in one caller-owned transaction by the resume worker.
-}
markChildFailedTx :: Text -> Text -> Text -> Tx.Transaction Bool
markChildFailedTx cid cname reason =
    Tx.statement (cid, cname, reason) markChildFailedStmt

-- | Read a child link row by @(child_id, child_name)@. 'Nothing' if absent.
lookupChild :: (Store :> es) => Text -> Text -> Eff es (Maybe ChildRow)
lookupChild cid cname =
    runTransaction (Tx.statement (cid, cname) lookupChildStmt)

-- | Read every child link of a parent @(parent_id, parent_name)@.
lookupChildrenOfParent :: (Store :> es) => Text -> Text -> Eff es [ChildRow]
lookupChildrenOfParent pid pname =
    runTransaction (Tx.statement (pid, pname) lookupChildrenOfParentStmt)

-- | The 'ChildStatus' of a child by @(child_id, child_name)@, if it exists.
childStatus :: (Store :> es) => Text -> Text -> Eff es (Maybe ChildStatus)
childStatus cid cname = fmap (^. #status) <$> lookupChild cid cname

{- | Count children currently @running@. Read-only. EP-44 may back a
@keiro.workflow.children.active@ gauge with this.
-}
countActiveChildren :: (Store :> es) => Eff es Int
countActiveChildren =
    runTransaction (Tx.statement () countActiveChildrenStmt)

{- | The @(child_id, child_name)@ of every @running@ child. The resume worker
unions this with 'Keiro.Workflow.findUnfinishedWorkflowIds' so a freshly
spawned child that has no @keiro_workflow_steps@ rows yet is still discovered
and driven. The tuple order matches 'findUnfinishedWorkflowIds' — @(id, name)@.
-}
findRunningChildIds :: (Store :> es) => Eff es [(Text, Text)]
findRunningChildIds =
    runTransaction (Tx.statement () findRunningChildIdsStmt)

registerChildStmt :: Statement (Text, Text, Text, Text, Text) ()
registerChildStmt =
    preparable
        """
        INSERT INTO keiro.keiro_workflow_children
          (child_id, child_name, parent_id, parent_name, await_step, status)
        VALUES ($1, $2, $3, $4, $5, 'running')
        ON CONFLICT (child_id, child_name) DO NOTHING
        """
        ( contrazip5
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

markChildResultStmt :: Statement (Text, Text, Value, UTCTime) Bool
markChildResultStmt =
    preparable
        """
        UPDATE keiro.keiro_workflow_children
        SET status = 'completed',
            result = $3,
            completed_at = $4,
            updated_at = now()
        WHERE child_id = $1
          AND child_name = $2
          AND status = 'running'
        """
        ( contrazip4
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.jsonb))
            (E.param (E.nonNullable E.timestamptz))
        )
        ((> 0) <$> D.rowsAffected)

markChildCancelledStmt :: Statement (Text, Text) Bool
markChildCancelledStmt =
    preparable
        """
        UPDATE keiro.keiro_workflow_children
        SET status = 'cancelled',
            updated_at = now()
        WHERE child_id = $1
          AND child_name = $2
          AND status = 'running'
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        ((> 0) <$> D.rowsAffected)

markChildFailedStmt :: Statement (Text, Text, Text) Bool
markChildFailedStmt =
    preparable
        """
        UPDATE keiro.keiro_workflow_children
        SET status = 'failed',
            failure_reason = $3,
            updated_at = now()
        WHERE child_id = $1
          AND child_name = $2
          AND status = 'running'
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        ((> 0) <$> D.rowsAffected)

lookupChildStmt :: Statement (Text, Text) (Maybe ChildRow)
lookupChildStmt =
    preparable
        """
        SELECT child_id, child_name, parent_id, parent_name, await_step,
          status, result, failure_reason, created_at, updated_at, completed_at
        FROM keiro.keiro_workflow_children
        WHERE child_id = $1
          AND child_name = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.rowMaybe childRowDecoder)

lookupChildrenOfParentStmt :: Statement (Text, Text) [ChildRow]
lookupChildrenOfParentStmt =
    preparable
        """
        SELECT child_id, child_name, parent_id, parent_name, await_step,
          status, result, failure_reason, created_at, updated_at, completed_at
        FROM keiro.keiro_workflow_children
        WHERE parent_id = $1
          AND parent_name = $2
        ORDER BY created_at, child_id
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        (D.rowList childRowDecoder)

countActiveChildrenStmt :: Statement () Int
countActiveChildrenStmt =
    preparable
        """
        SELECT count(*)
        FROM keiro.keiro_workflow_children
        WHERE status = 'running'
        """
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

findRunningChildIdsStmt :: Statement () [(Text, Text)]
findRunningChildIdsStmt =
    preparable
        """
        SELECT child_id, child_name
        FROM keiro.keiro_workflow_children
        WHERE status = 'running'
        """
        E.noParams
        (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

childRowDecoder :: D.Row ChildRow
childRowDecoder =
    ChildRow
        <$> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> (statusFromText <$> D.column (D.nonNullable D.text))
        <*> D.column (D.nullable D.jsonb)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)

statusToText :: ChildStatus -> Text
statusToText = \case
    Running -> "running"
    ChildCompleted -> "completed"
    ChildCancelled -> "cancelled"
    ChildFailed -> "failed"

statusFromText :: Text -> ChildStatus
statusFromText = \case
    "running" -> Running
    "completed" -> ChildCompleted
    "cancelled" -> ChildCancelled
    "failed" -> ChildFailed
    _ -> ChildCancelled
