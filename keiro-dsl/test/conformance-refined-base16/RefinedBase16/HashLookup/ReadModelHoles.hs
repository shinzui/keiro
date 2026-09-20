-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module RefinedBase16.HashLookup.ReadModelHoles
  ( hashLookupQuery
  ) where

import Generated.RefinedBase16.HashLookup.ReadModelTable (hashLookupQualifiedTable)
import Generated.RefinedBase16.HashLookup.QueryContract (HashLookupQueryInput, HashLookupQueryResult)
import Hasql.Transaction qualified as Tx

-- HOLE: query "public"."hash_values" via hashLookupQualifiedTable; never rely on search_path.
-- The generated QueryContract owns query input/result type identity.
-- Declared columns:
hashLookupQuery :: HashLookupQueryInput -> Tx.Transaction HashLookupQueryResult
hashLookupQuery _input = hashLookupQualifiedTable `seq` error "HOLE: fill hash_lookup query"