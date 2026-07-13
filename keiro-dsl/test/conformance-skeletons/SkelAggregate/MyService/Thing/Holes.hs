{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module SkelAggregate.MyService.Thing.Holes (
    thingTransducer,
    -- (no projection)
) where

import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, lit)
import SkelAggregate.Generated.MyService.Thing.Domain

-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
thingTransducer ::
    SymTransducer
        (HsPred ThingRegs ThingCommand)
        ThingRegs
        ThingVertex
        ThingCommand
        ThingEvent
thingTransducer =
    B.buildTransducer ThingPending initialThingRegs isTerminal do
        B.from ThingPending do
            B.onCmd inCtorDoThing $ \d -> B.do
                B.slot @"state" =: lit ThingDone
                B.emit
                    wireThingCompleted
                    ThingCompletedTermFields
                        { thingId = d.thingId
                        , attempt = d.attempt
                        }
                B.goto ThingDone
  where
    isTerminal = \case
        ThingDone -> True
        _ -> False
