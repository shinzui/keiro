{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module SurgeDemo.Hospital.Holes (
    hospitalTransducer,
    applyHospital,
) where

import Generated.SurgeDemo.Hospital.Domain
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)

hospitalTransducer ::
    SymTransducer
        (HsPred HospitalRegs HospitalCommand)
        HospitalRegs
        HospitalVertex
        HospitalCommand
        HospitalEvent
hospitalTransducer =
    B.buildTransducer HospitalIdle initialHospitalRegs isTerminal do
        B.from HospitalIdle do
            B.onCmd inCtorActivateSurge $ \d -> B.do
                B.emit wireSurgeActivated SurgeActivatedTermFields{hospitalId = d.hospitalId}
                B.goto HospitalSurging
  where
    isTerminal = \case
        HospitalSurging -> True
        _ -> False

-- HOLE: the read-model SQL for the projection (a DB-coupled hole; the
-- pure event->status mapping is generated as hospitalStatusFor).
-- Fill against your codd-managed read-model table.
applyHospital :: HospitalEvent -> recorded -> txn ()
applyHospital _event _recorded = error "HOLE: fill hospital projection apply"
