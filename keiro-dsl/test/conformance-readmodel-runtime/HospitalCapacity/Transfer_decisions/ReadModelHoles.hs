-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module HospitalCapacity.Transfer_decisions.ReadModelHoles (
    TransferDecisionsQueryInput,
    TransferDecisionsQueryResult,
    transferDecisionsQuery,
    applyTransferDecisions,
) where

import Data.Text.Encoding qualified as Text
import Generated.HospitalCapacity.Transfer_decisions.ReadModelTable (transferDecisionsQualifiedTable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent)

-- HOLE: replace these aliases with the real query input and result types.
type TransferDecisionsQueryInput = ()
type TransferDecisionsQueryResult = ()

-- HOLE: query "hospital_capacity"."transfer_decisions" via transferDecisionsQualifiedTable; never rely on search_path.
-- Declared columns:
--   reservation_id text NOT NULL
--   hospital_id text NOT NULL
--   status text NOT NULL
--   decided_at timestamptz
transferDecisionsQuery :: TransferDecisionsQueryInput -> Tx.Transaction TransferDecisionsQueryResult
transferDecisionsQuery _input =
    Tx.sql (Text.encodeUtf8 ("SELECT count(*) FROM " <> transferDecisionsQualifiedTable))

-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.
applyTransferDecisions :: RecordedEvent -> Tx.Transaction ()
applyTransferDecisions _recorded = pure ()
