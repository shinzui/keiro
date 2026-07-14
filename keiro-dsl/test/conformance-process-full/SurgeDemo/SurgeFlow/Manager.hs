{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

-- HAND-FILLED process-manager value (EP-3 M5 full-service integration): the
-- @handle@ hole filled against the live Keiro.ProcessManager API, wiring the
-- scaffolded Surge (saga) and Hospital (target) EventStreams plus the
-- scaffolded timer-request builder. This is the behaviour-bearing body the
-- scaffolder deliberately leaves as a hole (the firewall); here it is written
-- and type-checked against the runtime to prove the full service compiles.
--
-- The runtime dispatch worker may acknowledge @on-duplicate AckOk@ only after
-- @confirmBenignDuplicate@ proves the attempted event id exists in this
-- command's target stream. A hand-written dispatch path must preserve that
-- target-stream check; a bare global @DuplicateEvent@ is not sufficient.
module SurgeDemo.SurgeFlow.Manager (
    surgeManager,
    SurgeInput (..),
) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Generated.SurgeDemo.Hospital.Domain qualified as H
import Generated.SurgeDemo.Hospital.EventStream (hospitalCategory, hospitalEventStream)
import Generated.SurgeDemo.Surge.Domain qualified as S
import Generated.SurgeDemo.Surge.EventStream (surgeEventStream)
import Generated.SurgeDemo.SurgeFlow.Process (surgeFlowCategory, surgeFlowTimerRequest)
import Keiki.Core (HsPred)
import Keiro.ProcessManager (PMCommand (..), ProcessManager (..), ProcessManagerAction (..))
import Keiro.Stream (entityStream)

data SurgeInput = SurgeInput
    { hospitalId :: Text
    , observedAt :: UTCTime
    }

surgeManager ::
    ProcessManager
        SurgeInput
        (HsPred S.SurgeRegs S.SurgeCommand)
        S.SurgeRegs
        S.SurgeVertex
        S.SurgeCommand
        S.SurgeEvent
        (HsPred H.HospitalRegs H.HospitalCommand)
        H.HospitalRegs
        H.HospitalVertex
        H.HospitalCommand
        H.HospitalEvent
surgeManager =
    ProcessManager
        { name = "surge-demo"
        , correlate = \i -> hospitalId (i :: SurgeInput)
        , eventStream = surgeEventStream
        , streamFor = entityStream surgeFlowCategory
        , targetEventStream = hospitalEventStream
        , targetProjections = const []
        , handle = \i ->
            ProcessManagerAction
                { command = S.NoteSurgeThreshold (S.NoteSurgeThresholdData (S.HospitalId (hospitalId i)))
                , commands =
                    [ PMCommand
                        { target = entityStream hospitalCategory (hospitalId i)
                        , command = H.ActivateSurge (H.ActivateSurgeData (H.HospitalId (hospitalId i)))
                        }
                    ]
                , timers = [surgeFlowTimerRequest (hospitalId i) (observedAt i)]
                }
        }
