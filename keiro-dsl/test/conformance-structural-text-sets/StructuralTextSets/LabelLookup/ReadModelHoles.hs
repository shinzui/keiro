-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module StructuralTextSets.LabelLookup.ReadModelHoles
  ( labelLookupQuery
  ) where

import Generated.StructuralTextSets.LabelLookup.ReadModelTable (labelLookupQualifiedTable)
import Generated.StructuralTextSets.LabelLookup.QueryContract (LabelLookupQueryInput, LabelLookupQueryResult)
import Hasql.Transaction qualified as Tx

-- HOLE: query "public"."label_values" via labelLookupQualifiedTable; never rely on search_path.
-- The generated QueryContract owns query input/result type identity.
-- Declared columns:
labelLookupQuery :: LabelLookupQueryInput -> Tx.Transaction LabelLookupQueryResult
labelLookupQuery _input = labelLookupQualifiedTable `seq` error "HOLE: fill label_lookup query"