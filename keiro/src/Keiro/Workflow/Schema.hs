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
  , currentGeneration
  , findUnfinishedWorkflowIds
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip6)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Prelude
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
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
  , generation :: !Int
  -- ^ EP-48: the journal /generation/ this step belongs to. Generation 0 is
  --   the pre-rotation default; @continueAsNew@ rotates onto higher generations.
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
    , fromIntegral (row ^. #generation) :: Int32
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
loadStepIndex :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Eff es (Map Text Value)
loadStepIndex (WorkflowName name) (WorkflowId wid) gen =
  Map.fromList <$> runTransaction (Tx.statement (wid, name, fromIntegral gen :: Int32) loadStepIndexStmt)

{- | Whether a workflow instance already has an index row for the given step
name. Used to make journal re-appends idempotent without relying on the event
store's duplicate-id rejection.
-}
stepExists :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Text -> Eff es Bool
stepExists (WorkflowName name) (WorkflowId wid) gen key =
  runTransaction (Tx.statement (wid, name, fromIntegral gen :: Int32, key) stepExistsStmt)

{- | The current (highest) generation recorded for a logical workflow, or 0 if
it has no step rows yet (EP-48). Index-supported by the
@(workflow_id, workflow_name, generation)@ lookup index. A workflow that never
rotates stays at generation 0 and behaves byte-for-byte as it did before EP-48.
A rotation commits the next generation's seed step under generation @g+1@ in
the same logical-id key space, so @MAX(generation)@ is unambiguously the
current generation. -}
currentGeneration :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es Int
currentGeneration (WorkflowName name) (WorkflowId wid) =
  fromIntegral <$> runTransaction (Tx.statement (wid, name) currentGenerationStmt)

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

recordStepStmt :: Statement (Text, Text, Int32, Text, Value, UTCTime) ()
recordStepStmt =
  preparable
    """
    INSERT INTO keiro_workflow_steps
      (workflow_id, workflow_name, generation, step_name, result, recorded_at)
    VALUES ($1, $2, $3, $4, $5, $6)
    ON CONFLICT (workflow_id, workflow_name, generation, step_name) DO NOTHING
    """
    ( contrazip6
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.jsonb))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

loadStepIndexStmt :: Statement (Text, Text, Int32) [(Text, Value)]
loadStepIndexStmt =
  preparable
    """
    SELECT step_name, result
    FROM keiro_workflow_steps
    WHERE workflow_id = $1 AND workflow_name = $2 AND generation = $3
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.jsonb)))

stepExistsStmt :: Statement (Text, Text, Int32, Text) Bool
stepExistsStmt =
  preparable
    """
    SELECT EXISTS (
      SELECT 1 FROM keiro_workflow_steps
      WHERE workflow_id = $1 AND workflow_name = $2 AND generation = $3 AND step_name = $4
    )
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.text))
    )
    (D.singleRow (D.column (D.nonNullable D.bool)))

-- The current generation is MAX(generation) for the logical id+name, or 0 when
-- the workflow has no rows. Index-supported by keiro_workflow_steps_workflow_idx.
currentGenerationStmt :: Statement (Text, Text) Int32
currentGenerationStmt =
  preparable
    """
    SELECT COALESCE(MAX(generation), 0)::int4
    FROM keiro_workflow_steps
    WHERE workflow_id = $1 AND workflow_name = $2
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.singleRow (D.column (D.nonNullable D.int4)))

-- The literals '__workflow_completed__' / '__workflow_cancelled__' must match
-- 'Keiro.Workflow.Types.completedStepName' / '.cancelledStepName'.
--
-- EP-48: the terminal-marker check is scoped to the CURRENT (MAX) generation.
-- A logical workflow (workflow_id, workflow_name) is unfinished when its newest
-- generation lacks a completed/cancelled row. '__workflow_continued_as_new__'
-- is deliberately NOT in the terminal set, and because we only look at the
-- newest generation a rotated-away (lower) generation's rotation marker is never
-- even considered — so a rotated, still-running workflow is correctly reported
-- as unfinished rather than masked as finished. The CTE computes one
-- current-generation row per logical id, so each unfinished workflow is returned
-- exactly once (this form is used in preference to a HAVING/correlated-MAX
-- subquery for clarity on PostgreSQL 18+).
findUnfinishedWorkflowIdsStmt :: Statement () [(Text, Text)]
findUnfinishedWorkflowIdsStmt =
  preparable
    """
    WITH current_gen AS (
      SELECT workflow_id, workflow_name, MAX(generation) AS gen
      FROM keiro_workflow_steps
      GROUP BY workflow_id, workflow_name
    )
    SELECT cg.workflow_id, cg.workflow_name
    FROM current_gen cg
    WHERE NOT EXISTS (
      SELECT 1 FROM keiro_workflow_steps c
      WHERE c.workflow_id = cg.workflow_id
        AND c.workflow_name = cg.workflow_name
        AND c.generation = cg.gen
        AND c.step_name IN ('__workflow_completed__', '__workflow_cancelled__')
    )
    """
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))
