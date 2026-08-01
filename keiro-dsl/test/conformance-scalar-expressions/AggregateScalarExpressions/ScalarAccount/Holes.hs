{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}
-- This is a HAND-OWNED version-2 hook module. keiro-dsl creates it once
-- and never overwrites it. Generated code owns every transition envelope
-- and every declared guard/write. This module supplies explicit event-field
-- mappings and explicitly selected Hole behavior only; fields(Command)
-- identity mappings are generated directly and have no hook.
module AggregateScalarExpressions.ScalarAccount.Holes
  ( transition2ReviewedCloseHole
  , transition2ReviewedCloseHoleFoldVersion
  ) where

import Generated.AggregateScalarExpressions.ScalarAccount.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)


import Keiki.Core qualified as K
import Keiro.Snapshot.Codec (FoldVersion (..))

-- HOLE: add the predicate and ordered register updates for this transition.
-- The generated transducer still owns command matching, mode, emits, and goto.
transition2ReviewedCloseHole d =
  B.requireGuard (K.PEq (K.TApp1 id d.balance) d.balance)

-- Bump this token whenever the Hole predicate or updates change.
transition2ReviewedCloseHoleFoldVersion :: FoldVersion
transition2ReviewedCloseHoleFoldVersion = FoldVersion "transition2ReviewedClose-fold-v1"
