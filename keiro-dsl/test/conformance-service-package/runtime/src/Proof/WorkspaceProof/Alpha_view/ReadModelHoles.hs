-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module Proof.WorkspaceProof.Alpha_view.ReadModelHoles
  ( AlphaViewQueryInput
  , AlphaViewQueryResult
  , alphaViewQuery
  , applyAlphaView
  ) where

import Proof.WorkspaceProof.Alpha_view.Generated.ReadModelTable (alphaViewQualifiedTable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent(..))

-- HOLE: replace these aliases with the real query input and result types.
type AlphaViewQueryInput = ()
type AlphaViewQueryResult = ()

-- HOLE: query "workspace_proof"."alpha_view" via alphaViewQualifiedTable; never rely on search_path.
-- Declared columns:
--   proof_id text NOT NULL
--   status text NOT NULL
alphaViewQuery :: AlphaViewQueryInput -> Tx.Transaction AlphaViewQueryResult
alphaViewQuery _input = alphaViewQualifiedTable `seq` error "HOLE: fill alpha_view query"

-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.
applyAlphaView :: RecordedEvent -> Tx.Transaction ()
applyAlphaView _recorded = error "HOLE: fill alpha_view async apply"