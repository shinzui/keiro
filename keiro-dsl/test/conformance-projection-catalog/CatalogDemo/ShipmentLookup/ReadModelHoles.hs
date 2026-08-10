-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CatalogDemo.ShipmentLookup.ReadModelHoles
  ( ShipmentLookupQueryInput
  , ShipmentLookupQueryResult
  , shipmentLookupQuery
  ) where

import Generated.CatalogDemo.ShipmentLookup.ReadModelTable (shipmentLookupQualifiedTable)
import Hasql.Transaction qualified as Tx

-- HOLE: replace these aliases with the real query input and result types.
type ShipmentLookupQueryInput = ()
type ShipmentLookupQueryResult = ()

-- HOLE: query "sales"."shipment_summary" via shipmentLookupQualifiedTable; never rely on search_path.
-- Declared columns:
--   shipment_id text NOT NULL
shipmentLookupQuery :: ShipmentLookupQueryInput -> Tx.Transaction ShipmentLookupQueryResult
shipmentLookupQuery _input = shipmentLookupQualifiedTable `seq` pure ()
