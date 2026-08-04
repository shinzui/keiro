-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module IncidentPaging.ServiceOncall.ReadModelHoles
  ( ServiceOncallQueryInput
  , ServiceOncallQueryResult
  , serviceOncallQuery
  , applyServiceOncall
  ) where

import Generated.IncidentPaging.ServiceOncall.ReadModelTable (serviceOncallQualifiedTable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Types (RecordedEvent(..))

-- HOLE: replace these aliases with the real query input and result types.
type ServiceOncallQueryInput = ()
type ServiceOncallQueryResult = ()

-- HOLE: query "incident_paging"."service_oncall" via serviceOncallQualifiedTable; never rely on search_path.
-- Declared columns:
--   responder_id text NOT NULL
--   service text NOT NULL
serviceOncallQuery :: ServiceOncallQueryInput -> Tx.Transaction ServiceOncallQueryResult
serviceOncallQuery _input = serviceOncallQualifiedTable `seq` error "HOLE: fill service_oncall query"

-- HOLE: apply one recorded event; runtime deduplication makes redelivery safe.
applyServiceOncall :: RecordedEvent -> Tx.Transaction ()
applyServiceOncall _recorded = error "HOLE: fill service_oncall async apply"