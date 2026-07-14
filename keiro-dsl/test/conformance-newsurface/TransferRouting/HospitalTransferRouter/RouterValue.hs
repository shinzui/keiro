{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module TransferRouting.HospitalTransferRouter.RouterValue (
    AcceptedHospitalTransferNeed (..),
    hospitalTransferRouter,
    resolveTargets,
) where

import Data.Text (Text)
import Effectful (Eff)
import Generated.TransferRouting.Hospital.Domain qualified as Hospital
import Generated.TransferRouting.Hospital.EventStream (
    hospitalCategory,
    hospitalEventStream,
 )
import Generated.TransferRouting.HospitalTransferRouter.Router (hospitalTransferRouterName)
import Generated.TransferRouting.Hospital_load.ReadModel (hospitalLoadReadModel)
import Keiki.Core (HsPred)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.Router (Router (..))
import Keiro.Stream (entityStream)

data AcceptedHospitalTransferNeed = AcceptedHospitalTransferNeed
    { transferNeedId :: !Text
    , region :: !Text
    }
    deriving stock (Eq, Show)

data HospitalLoadRow = HospitalLoadRow
    { hospitalId :: !Text
    , region :: !Text
    , availableBeds :: !Int
    }

resolveHospitalLoad :: AcceptedHospitalTransferNeed -> Eff '[] [HospitalLoadRow]
resolveHospitalLoad input =
    hospitalLoadReadModel `seq`
        pure
            [ HospitalLoadRow
                { hospitalId = input.region <> "-general"
                , region = input.region
                , availableBeds = 12
                }
            ]

resolveTargets :: AcceptedHospitalTransferNeed -> Eff '[] [PMCommand Hospital.HospitalCommand]
resolveTargets input = do
    rows <- resolveHospitalLoad input
    pure
        [ PMCommand
            { target = entityStream hospitalCategory row.hospitalId
            , command =
                Hospital.RouteAcceptedTransferNeed
                    (Hospital.RouteAcceptedTransferNeedData input.transferNeedId row.hospitalId)
            }
        | row <- rows
        , row.availableBeds > 0
        ]

hospitalTransferRouter ::
    Router
        AcceptedHospitalTransferNeed
        (HsPred Hospital.HospitalRegs Hospital.HospitalCommand)
        Hospital.HospitalRegs
        Hospital.HospitalVertex
        Hospital.HospitalCommand
        Hospital.HospitalEvent
        '[]
hospitalTransferRouter =
    Router
        { name = hospitalTransferRouterName
        , key = \input -> input.transferNeedId
        , resolve = resolveTargets
        , targetEventStream = hospitalEventStream
        , targetProjections = const []
        }
