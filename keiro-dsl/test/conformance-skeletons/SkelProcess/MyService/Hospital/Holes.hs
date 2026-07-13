{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module SkelProcess.MyService.Hospital.Holes (
    hospitalTransducer,
    -- (no projection)
) where

import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)
import SkelProcess.Generated.MyService.Hospital.Domain

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
    B.buildTransducer HospitalOperational initialHospitalRegs isTerminal do
        B.from HospitalOperational do
            B.onCmd inCtorActivateSurge $ \d -> B.do
                B.emit
                    wireSurgeActivated
                    SurgeActivatedTermFields
                        { hospitalId = d.hospitalId
                        }
                B.goto HospitalSurging
  where
    isTerminal = \case
        HospitalSurging -> True
        _ -> False
