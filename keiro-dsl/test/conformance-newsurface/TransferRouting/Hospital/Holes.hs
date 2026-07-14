{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module TransferRouting.Hospital.Holes (
    hospitalTransducer,
    -- (no projection)
) where

import Generated.TransferRouting.Hospital.Domain
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)

-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
hospitalTransducer ::
    SymTransducer
        (HsPred HospitalRegs HospitalCommand)
        HospitalRegs
        HospitalVertex
        HospitalCommand
        HospitalEvent
hospitalTransducer =
    B.buildTransducer HospitalAccepting initialHospitalRegs isTerminal do
        B.from HospitalAccepting do
            B.onCmd inCtorRouteAcceptedTransferNeed $ \d -> B.do
                B.emit
                    wireAcceptedTransferNeedRouted
                    AcceptedTransferNeedRoutedTermFields
                        { transferNeedId = d.transferNeedId
                        , hospitalId = d.hospitalId
                        }
                B.goto HospitalAccepting
  where
    isTerminal = \case
        _ -> False
