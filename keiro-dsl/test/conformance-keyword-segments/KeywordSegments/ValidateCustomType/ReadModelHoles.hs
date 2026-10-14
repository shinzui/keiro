-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module KeywordSegments.ValidateCustomType.ReadModelHoles
  ( validateCustomTypeQuery
  ) where

import Generated.KeywordSegments.ValidateCustomType.ReadModelTable (validateCustomTypeQualifiedTable)
import Generated.KeywordSegments.ValidateCustomType.QueryContract (ValidateCustomTypeQueryInput, ValidateCustomTypeQueryResult)
import Hasql.Transaction qualified as Tx

-- HOLE: query "billing"."validate_custom_type" via validateCustomTypeQualifiedTable; never rely on search_path.
-- The generated QueryContract owns query input/result type identity.
-- Declared columns:
validateCustomTypeQuery :: ValidateCustomTypeQueryInput -> Tx.Transaction ValidateCustomTypeQueryResult
validateCustomTypeQuery _input = validateCustomTypeQualifiedTable `seq` error "HOLE: fill validate_custom_type query"