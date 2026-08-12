-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CatalogDemo.OrderTotalsLookup.ReadModelHoles
  ( OrderTotalsLookupQueryInput
  , OrderTotalsLookupQueryResult
  , orderTotalsLookupQuery
  ) where

import Generated.CatalogDemo.OrderTotalsLookup.ReadModelTable (orderTotalsLookupQualifiedTable)
import Hasql.Transaction qualified as Tx

type OrderTotalsLookupQueryInput = ()
type OrderTotalsLookupQueryResult = ()

-- HOLE: query "sales"."order_totals" via orderTotalsLookupQualifiedTable; never rely on search_path.
-- Declared columns:
--   total bigint NOT NULL
orderTotalsLookupQuery :: OrderTotalsLookupQueryInput -> Tx.Transaction OrderTotalsLookupQueryResult
orderTotalsLookupQuery _input = orderTotalsLookupQualifiedTable `seq` pure ()
