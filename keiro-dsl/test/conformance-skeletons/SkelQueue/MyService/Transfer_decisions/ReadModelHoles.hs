-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module SkelQueue.MyService.Transfer_decisions.ReadModelHoles (
    TransferDecisionsQueryInput,
    TransferDecisionsQueryResult,
    transferDecisionsQuery,
    applyTransferDecisions,
) where

import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent)
import SkelQueue.Generated.MyService.Transfer_decisions.ReadModelTable (transferDecisionsQualifiedTable)

-- HOLE: replace these aliases with the real query input and result types.
type TransferDecisionsQueryInput = ()
type TransferDecisionsQueryResult = ()

-- HOLE: query "my_service"."transfer_decisions" via transferDecisionsQualifiedTable; never rely on search_path.
-- Declared columns:
--   reservation_id text NOT NULL
transferDecisionsQuery :: TransferDecisionsQueryInput -> Tx.Transaction TransferDecisionsQueryResult
transferDecisionsQuery _input = transferDecisionsQualifiedTable `seq` error "HOLE: fill transfer_decisions query"

-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.
applyTransferDecisions :: RecordedEvent -> Tx.Transaction ()
applyTransferDecisions _recorded = error "HOLE: fill transfer_decisions async apply"
