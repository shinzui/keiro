{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}
-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Fill the transducer body (and any other holes) against the
-- generated signatures, then run the harness to confirm behaviour.
module HospitalCapacity.Hospital.Holes
  ( hospitalTransducer
  -- (no projection)

  ) where

import Generated.HospitalCapacity.Hospital.Domain
import Keiki.Builder ((=:))
import qualified Keiki.Builder as B
import Keiki.Core (HsPred, RegFile, SymTransducer, lit, (.==), (./=), (.||))


-- HOLE: the transducer body. Reproduce the structure below, replacing each
-- `-- HOLE` line with the keiki symbolic operators it describes.
hospitalTransducer
  :: SymTransducer
       (HsPred HospitalRegs HospitalCommand)
       HospitalRegs
       HospitalVertex
       HospitalCommand
       HospitalEvent
hospitalTransducer =
  B.buildTransducer HospitalOperational initialHospitalRegs isTerminal do

 where
  isTerminal = \case

    _ -> False

