{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}
-- This is a HAND-OWNED version-2 hook module. keiro-dsl creates it once
-- and never overwrites it. Generated code owns every transition envelope
-- and every declared guard/write; this module supplies event fields and
-- explicitly selected Hole behavior only.
module AggregateScalarExpressions.ScalarAccount.Holes
  ( transition1OpenAdjustOutput1Adjusted
  , transition2ReviewedCloseOutput1ClosedEvent
  , transition2ReviewedCloseHole
  , transition2ReviewedCloseHoleFoldVersion
  ) where

import Generated.AggregateScalarExpressions.ScalarAccount.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)


import Keiki.Core qualified as K
import Keiro.Snapshot.Codec (FoldVersion (..))

-- Hand-owned event-field hook inside the generated transition envelope.
transition1OpenAdjustOutput1Adjusted :: B.PayloadProj ScalarAccountRegs ScalarAccountCommand (RegFieldsOf AdjustData) -> AdjustedTermFields ScalarAccountRegs ScalarAccountCommand (RegFieldsOf AdjustData)
transition1OpenAdjustOutput1Adjusted d = AdjustedTermFields
  { balance = d.balance
  , requested = d.requested
  , machine = d.machine
  , label = d.label
  , active = d.active
  , mode = d.mode
  , requestId = d.requestId
  , observedAt = d.observedAt
  , limits = d.limits
  }

-- Hand-owned event-field hook inside the generated transition envelope.
transition2ReviewedCloseOutput1ClosedEvent :: B.PayloadProj ScalarAccountRegs ScalarAccountCommand (RegFieldsOf CloseData) -> ClosedEventTermFields ScalarAccountRegs ScalarAccountCommand (RegFieldsOf CloseData)
transition2ReviewedCloseOutput1ClosedEvent d = ClosedEventTermFields
  { balance = d.balance
  }

-- HOLE: add the predicate and ordered register updates for this transition.
-- The generated transducer still owns command matching, mode, emits, and goto.
transition2ReviewedCloseHole d =
  B.requireGuard (K.PEq (K.TApp1 id d.balance) d.balance)

-- Bump this token whenever the Hole predicate or updates change.
transition2ReviewedCloseHoleFoldVersion :: FoldVersion
transition2ReviewedCloseHoleFoldVersion = FoldVersion "transition2ReviewedClose-fold-v1"
