-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module HospitalCapacity.Accepted_transfer_needs.ReadModelHoles
  ( AcceptedTransferNeedsQueryInput
  , AcceptedTransferNeedsQueryResult
  , acceptedTransferNeedsQuery
  , applyAcceptedTransferNeeds
  ) where

import Generated.HospitalCapacity.Accepted_transfer_needs.ReadModelTable (acceptedTransferNeedsQualifiedTable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent(..))

-- HOLE: replace these aliases with the real query input and result types.
type AcceptedTransferNeedsQueryInput = ()
type AcceptedTransferNeedsQueryResult = ()

-- HOLE: query "hospital_capacity"."accepted_transfer_needs" via acceptedTransferNeedsQualifiedTable; never rely on search_path.
-- Declared columns:
--   reservation_id text NOT NULL
--   hospital_id text NOT NULL
acceptedTransferNeedsQuery :: AcceptedTransferNeedsQueryInput -> Tx.Transaction AcceptedTransferNeedsQueryResult
acceptedTransferNeedsQuery _input = acceptedTransferNeedsQualifiedTable `seq` error "HOLE: fill accepted_transfer_needs query"

-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.
applyAcceptedTransferNeeds :: RecordedEvent -> Tx.Transaction ()
applyAcceptedTransferNeeds _recorded = error "HOLE: fill accepted_transfer_needs async apply"