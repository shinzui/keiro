-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module BareContainers.BareLookup.ReadModelHoles
  ( bareLookupQuery
  ) where

import Generated.BareContainers.BareLookup.ReadModelTable (bareLookupQualifiedTable)
import Generated.BareContainers.BareLookup.QueryContract (BareLookupQueryInput, BareLookupQueryResult)
import Hasql.Transaction qualified as Tx

-- HOLE: query "public"."bare_values" via bareLookupQualifiedTable; never rely on search_path.
-- The generated QueryContract owns query input/result type identity.
-- Declared columns:
bareLookupQuery :: BareLookupQueryInput -> Tx.Transaction BareLookupQueryResult
bareLookupQuery _input = bareLookupQualifiedTable `seq` error "HOLE: fill bare_lookup query"