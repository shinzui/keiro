{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- HAND-OWNED language-4 hook. The generated transducer owns the transition
-- lifecycle; this module supplies only the explicit event-field mapping.
module SkelAggregate.MyService.Thing.Holes
  ( transition1PendingDoThingOutput1ThingCompleted
  ) where

import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)
import SkelAggregate.Generated.MyService.Thing.Domain

transition1PendingDoThingOutput1ThingCompleted
  :: B.PayloadProj ThingRegs ThingCommand (RegFieldsOf DoThingData)
  -> ThingCompletedTermFields ThingRegs ThingCommand (RegFieldsOf DoThingData)
transition1PendingDoThingOutput1ThingCompleted d =
  ThingCompletedTermFields
    { thingId = d.thingId
    , attempt = d.attempt
    }
