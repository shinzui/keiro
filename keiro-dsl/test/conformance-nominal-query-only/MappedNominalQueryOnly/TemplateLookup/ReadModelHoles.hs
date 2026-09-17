-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module MappedNominalQueryOnly.TemplateLookup.ReadModelHoles
  ( templateLookupQuery
  ) where

import Generated.MappedNominalQueryOnly.TemplateLookup.ReadModelTable (templateLookupQualifiedTable)
import Generated.MappedNominalQueryOnly.TemplateLookup.QueryContract (TemplateLookupQueryInput, TemplateLookupQueryResult)
import Hasql.Transaction qualified as Tx

-- HOLE: query "public"."templates" via templateLookupQualifiedTable; never rely on search_path.
-- The generated QueryContract owns query input/result type identity.
-- Declared columns:
templateLookupQuery :: TemplateLookupQueryInput -> Tx.Transaction TemplateLookupQueryResult
templateLookupQuery _input = templateLookupQualifiedTable `seq` error "HOLE: fill template_lookup query"