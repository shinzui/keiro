{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module SkelProcess.MyService.Surge.Holes (
    surgeTransducer,
    -- (no projection)
) where

import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)
import SkelProcess.Generated.MyService.Surge.Domain

-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
surgeTransducer ::
    SymTransducer
        (HsPred SurgeRegs SurgeCommand)
        SurgeRegs
        SurgeVertex
        SurgeCommand
        SurgeEvent
surgeTransducer =
    B.buildTransducer SurgeIdle initialSurgeRegs isTerminal do
        B.from SurgeIdle do
            B.onCmd inCtorNoteSurgeThreshold $ \d -> B.do
                B.emit
                    wireSurgeThresholdNoted
                    SurgeThresholdNotedTermFields
                        { hospitalId = d.hospitalId
                        , availableIcuBeds = d.availableIcuBeds
                        , redDemand = d.redDemand
                        , timerId = d.timerId
                        }
                B.goto SurgeIdle
            B.onCmd inCtorMarkSurgeTimerFired $ \d -> B.do
                B.emit
                    wireSurgeTimerMarked
                    SurgeTimerMarkedTermFields
                        { hospitalId = d.hospitalId
                        , timerId = d.timerId
                        }
                B.goto SurgeFired
  where
    isTerminal = \case
        SurgeFired -> True
        _ -> False
