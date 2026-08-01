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
module BehaviorComplete.Journey.Holes () where

import Generated.BehaviorComplete.Journey.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)

-- Deliberately retained migration sentinel: this is the pre-IR-13 identity-copy
-- hook name. The generated transducer neither imports nor calls it, and the
-- scaffold report names it as obsolete.
transition1EmptyStartOutput1Started :: B.PayloadProj JourneyRegs JourneyCommand (RegFieldsOf StartData) -> StartedTermFields JourneyRegs JourneyCommand (RegFieldsOf StartData)
transition1EmptyStartOutput1Started d =
  StartedTermFields
    { requestId = d.requestId,
      observedAt = d.observedAt,
      amount = d.amount,
      details = d.details
    }
