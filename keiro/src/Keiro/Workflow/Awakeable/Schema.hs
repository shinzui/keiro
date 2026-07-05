{- | The @keiro_awakeables@ table: durable storage for awakeables (external
promises a workflow suspends on).

Mirrors the @Keiro.Timer@ \/ @Keiro.Timer.Schema@ split: this module owns the
row type, the 'AwakeableStatus' lifecycle, and the hasql statements;
"Keiro.Workflow.Awakeable" owns the effectful authoring\/completion surface.

* 'registerAwakeableTx' inserts a @pending@ row idempotently (the
  @ON CONFLICT DO NOTHING@ EP-38's @awaitStep@ arming contract requires).
* 'lookupAwakeable' reads a row back.
* 'completeAwakeableTx' transitions a @pending@ row to @completed@ (guarded so
  a double signal is a no-op), and 'cancelAwakeableTx' transitions it to
  @cancelled@.
* 'countPendingAwakeables' counts outstanding promises — the seam EP-44 reads
  for its @keiro.workflow.awakeables.pending@ gauge.

Callers normally use the re-exports / surface from "Keiro.Workflow.Awakeable"
rather than this module directly; EP-44 imports 'countPendingAwakeables' here
without pulling in the effect surface.
-}
module Keiro.Workflow.Awakeable.Schema (
    -- * Rows and status
    AwakeableStatus (..),
    AwakeableRow (..),
    statusToText,
    statusFromText,

    -- * Storage (run inside the caller's transaction)
    registerAwakeableTx,
    completeAwakeableTx,
    cancelAwakeableTx,

    -- * Read-only lookups
    lookupAwakeable,
    countPendingAwakeables,
)
where

import Contravariant.Extras (contrazip3)
import Data.UUID (UUID)
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

{- | An awakeable's lifecycle state.

* 'Pending' — allocated and waiting for an external signal; the workflow is
  suspended on it.
* 'Completed' — signalled with a payload; terminal.
* 'Cancelled' — abandoned before it was signalled; terminal; also the decode
  fallback for an unrecognized stored value (the same defensive choice
  "Keiro.Timer.Schema" makes).
-}
data AwakeableStatus
    = Pending
    | Completed
    | Cancelled
    deriving stock (Generic, Eq, Show)

{- | An awakeable row as stored: the deterministic id, the owning workflow's
name and instance id, the live 'status', the signalled 'payload' (JSON, set
only once 'Completed'), and the timestamps.
-}
data AwakeableRow = AwakeableRow
    { awakeableId :: !UUID
    , ownerWorkflowName :: !Text
    , ownerWorkflowId :: !Text
    , status :: !AwakeableStatus
    , payload :: !(Maybe Value)
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    , completedAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic, Eq, Show)

{- | Insert a @pending@ awakeable row inside the caller's transaction.
Idempotent by @ON CONFLICT (awakeable_id) DO NOTHING@ — exactly what EP-38's
"arm must be idempotent" contract needs, since a resumed workflow re-runs the
arming action on every resume until the awakeable resolves.
-}
registerAwakeableTx :: UUID -> Text -> Text -> Tx.Transaction ()
registerAwakeableTx aid name wid =
    Tx.statement (aid, name, wid) registerAwakeableStmt

{- | Transition a @pending@ awakeable to @completed@, storing @payload@ and the
completion time, inside the caller's transaction. The @status = 'pending'@
guard makes a double-signal a no-op; returns 'True' only when this call
performed the transition (so the caller knows whether it was the one that
resolved the promise).
-}
completeAwakeableTx :: UUID -> Value -> UTCTime -> Tx.Transaction Bool
completeAwakeableTx aid result now =
    Tx.statement (aid, result, now) completeAwakeableStmt

{- | Transition a @pending@ awakeable to @cancelled@ inside the caller's
transaction. Only @pending@ rows match, so an already-completed (or
already-cancelled) awakeable is left untouched and the call returns 'False'.
-}
cancelAwakeableTx :: UUID -> Tx.Transaction Bool
cancelAwakeableTx aid =
    Tx.statement aid cancelAwakeableStmt

-- | Read an awakeable row by id. 'Nothing' if no such awakeable exists.
lookupAwakeable :: (Store :> es) => UUID -> Eff es (Maybe AwakeableRow)
lookupAwakeable aid =
    runTransaction (Tx.statement aid lookupAwakeableStmt)

{- | Count awakeables currently @pending@. Read-only. EP-44 backs the
@keiro.workflow.awakeables.pending@ gauge with this.
-}
countPendingAwakeables :: (Store :> es) => Eff es Int
countPendingAwakeables =
    runTransaction (Tx.statement () countPendingAwakeablesStmt)

registerAwakeableStmt :: Statement (UUID, Text, Text) ()
registerAwakeableStmt =
    preparable
        """
        INSERT INTO keiro.keiro_awakeables
          (awakeable_id, owner_workflow_name, owner_workflow_id, status)
        VALUES ($1, $2, $3, 'pending')
        ON CONFLICT (awakeable_id) DO NOTHING
        """
        ( contrazip3
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

completeAwakeableStmt :: Statement (UUID, Value, UTCTime) Bool
completeAwakeableStmt =
    preparable
        """
        UPDATE keiro.keiro_awakeables
        SET status = 'completed',
            payload = $2,
            completed_at = $3,
            updated_at = now()
        WHERE awakeable_id = $1
          AND status = 'pending'
        """
        ( contrazip3
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.jsonb))
            (E.param (E.nonNullable E.timestamptz))
        )
        ((> 0) <$> D.rowsAffected)

cancelAwakeableStmt :: Statement UUID Bool
cancelAwakeableStmt =
    preparable
        """
        UPDATE keiro.keiro_awakeables
        SET status = 'cancelled',
            updated_at = now()
        WHERE awakeable_id = $1
          AND status = 'pending'
        """
        (E.param (E.nonNullable E.uuid))
        ((> 0) <$> D.rowsAffected)

lookupAwakeableStmt :: Statement UUID (Maybe AwakeableRow)
lookupAwakeableStmt =
    preparable
        """
        SELECT awakeable_id, owner_workflow_name, owner_workflow_id, status,
          payload, created_at, updated_at, completed_at
        FROM keiro.keiro_awakeables
        WHERE awakeable_id = $1
        """
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe awakeableRowDecoder)

countPendingAwakeablesStmt :: Statement () Int
countPendingAwakeablesStmt =
    preparable
        """
        SELECT count(*)
        FROM keiro.keiro_awakeables
        WHERE status = 'pending'
        """
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

awakeableRowDecoder :: D.Row AwakeableRow
awakeableRowDecoder =
    AwakeableRow
        <$> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> (statusFromText <$> D.column (D.nonNullable D.text))
        <*> D.column (D.nullable D.jsonb)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)

statusToText :: AwakeableStatus -> Text
statusToText = \case
    Pending -> "pending"
    Completed -> "completed"
    Cancelled -> "cancelled"

statusFromText :: Text -> AwakeableStatus
statusFromText = \case
    "pending" -> Pending
    "completed" -> Completed
    "cancelled" -> Cancelled
    _ -> Cancelled
