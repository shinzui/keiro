-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never overwrites it.
module CheckedMappingReplay.ReplayLookup.ReadModelHoles
  ( replayLookupQuery
  ) where

import Generated.CheckedMappingReplay.ReplayLookup.ReadModelTable (replayLookupQualifiedTable)
import Generated.CheckedMappingReplay.ReplayLookup.QueryContract (ReplayLookupQueryInput, ReplayLookupQueryResult)
import Hasql.Transaction qualified as Tx

-- HOLE: query "public"."checked_mapping_replay" via replayLookupQualifiedTable; never rely on search_path.
-- The generated QueryContract owns query input/result type identity.
-- Declared columns:
replayLookupQuery :: ReplayLookupQueryInput -> Tx.Transaction ReplayLookupQueryResult
replayLookupQuery _input = replayLookupQualifiedTable `seq` error "HOLE: fill replay_lookup query"