-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module Proof.WorkspaceProof.BetaView.ReadModelHoles
  ( BetaViewQueryInput
  , BetaViewQueryResult
  , betaViewQuery
  , applyBetaView
  ) where

import Proof.WorkspaceProof.BetaView.Generated.ReadModelTable (betaViewQualifiedTable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent(..))

-- HOLE: replace these aliases with the real query input and result types.
type BetaViewQueryInput = ()
type BetaViewQueryResult = ()

-- HOLE: query "workspace_proof"."beta_view" via betaViewQualifiedTable; never rely on search_path.
-- Declared columns:
--   proof_id text NOT NULL
--   status text NOT NULL
betaViewQuery :: BetaViewQueryInput -> Tx.Transaction BetaViewQueryResult
betaViewQuery _input = betaViewQualifiedTable `seq` error "HOLE: fill beta_view query"

-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.
applyBetaView :: RecordedEvent -> Tx.Transaction ()
applyBetaView _recorded = error "HOLE: fill beta_view async apply"