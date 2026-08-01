{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}
-- This is a HAND-OWNED version-2 hook module. keiro-dsl creates it once
-- and never overwrites it. Generated code owns every transition envelope
-- and every declared guard/write. This module supplies explicit event-field
-- mappings and explicitly selected Hole behavior only; fields(Command)
-- identity mappings are generated directly and have no hook.
module NominalScalars.NominalLedger.Holes
  ( transition1EmptyRecordNominalsOutput1NominalsRecorded
  , transition1EmptyRecordNominalsHole
  , transition1EmptyRecordNominalsHoleFoldVersion
  ) where

import Generated.NominalScalars.NominalLedger.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)


import Keiki.Core qualified as K
import Keiro.Snapshot.Codec (FoldVersion (..))

-- Hand-owned event-field hook inside the generated transition envelope.
transition1EmptyRecordNominalsOutput1NominalsRecorded :: B.PayloadProj NominalLedgerRegs NominalLedgerCommand (RegFieldsOf RecordNominalsData) -> NominalsRecordedTermFields NominalLedgerRegs NominalLedgerCommand (RegFieldsOf RecordNominalsData)
transition1EmptyRecordNominalsOutput1NominalsRecorded d = NominalsRecordedTermFields
  { orderId = d.orderId
  , status = d.status
  , accountNumber = d.accountNumber
  , riskScore = d.riskScore
  , sequenceNumber = d.sequenceNumber
  , featureFlag = d.featureFlag
  , observedAt = d.observedAt
  }

-- HOLE: add the predicate and ordered register updates for this transition.
-- The generated transducer still owns command matching, mode, emits, and goto.
transition1EmptyRecordNominalsHole _d = B.requireGuard K.PTop

-- Bump this token whenever the Hole predicate or updates change.
transition1EmptyRecordNominalsHoleFoldVersion :: FoldVersion
transition1EmptyRecordNominalsHoleFoldVersion = FoldVersion "transition1EmptyRecordNominals-fold-v1"
