{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- HAND-FILLED hole module (EP-3 M5 full-service integration): the saga
-- aggregate's transducer, filled against the generated signatures.
module SurgeDemo.Surge.Holes (
    surgeTransducer,
    applySurge,
) where

import Generated.SurgeDemo.Surge.Domain
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)

surgeTransducer ::
    SymTransducer
        (HsPred SurgeRegs SurgeCommand)
        SurgeRegs
        SurgeVertex
        SurgeCommand
        SurgeEvent
surgeTransducer =
    B.buildTransducer SurgeWatching initialSurgeRegs isTerminal do
        B.from SurgeWatching do
            B.onCmd inCtorNoteSurgeThreshold $ \d -> B.do
                B.emit wireSurgeThresholdNoted SurgeThresholdNotedTermFields{hospitalId = d.hospitalId}
                B.goto SurgeNoted
        B.from SurgeNoted do
            B.onCmd inCtorMarkSurgeTimerFired $ \d -> B.do
                B.emit wireSurgeTimerFired SurgeTimerFiredTermFields{hospitalId = d.hospitalId}
                B.goto SurgeFired
  where
    isTerminal = \case
        SurgeFired -> True
        _ -> False

applySurge :: SurgeEvent -> recorded -> txn ()
applySurge _event _recorded = error "HOLE: fill surge projection apply"
