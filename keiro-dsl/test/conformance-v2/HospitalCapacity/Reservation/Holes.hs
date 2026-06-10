{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- HAND-OWNED hole module, filled by hand for the v2 (evolved) conformance
-- aggregate. The transducer body matches the v1 reference; the v2 event carries
-- a new `triageNote` field sourced as a literal here, and the upcaster defaults
-- `triageNote` on v1-on-disk payloads that lack it.
module HospitalCapacity.Reservation.Holes (
    reservationTransducer,
    applyTransfer_decisions,
    upcastTransferReservationCreatedV1,
) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Generated.HospitalCapacity.Reservation.Domain
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, lit, (./=), (.==), (.||))

reservationTransducer ::
    SymTransducer
        (HsPred ReservationRegs ReservationCommand)
        ReservationRegs
        ReservationVertex
        ReservationCommand
        ReservationEvent
reservationTransducer =
    B.buildTransducer ReservationUnrequested initialReservationRegs isTerminal do
        B.from ReservationUnrequested do
            B.onCmd inCtorRequestTransferReservation $ \d -> B.do
                B.requireGuard (d.divertStatus ./= lit TotalDivert .|| d.lifeCriticalOverride .== lit True)
                B.slot @"reservationState" =: lit ReservationHeld
                B.emit
                    wireTransferReservationCreated
                    TransferReservationCreatedTermFields
                        { reservationId = d.reservationId
                        , hospitalId = d.hospitalId
                        , commandId = d.commandId
                        , patientAcuity = d.patientAcuity
                        , divertStatus = d.divertStatus
                        , lifeCriticalOverride = d.lifeCriticalOverride
                        , triageNote = lit ""
                        }
                B.goto ReservationHeld
        B.from ReservationHeld do
            B.onCmd inCtorConfirmReservation $ \d -> B.do
                B.slot @"reservationState" =: lit ReservationConfirmed
                B.emit
                    wireTransferReservationConfirmed
                    TransferReservationConfirmedTermFields
                        { reservationId = d.reservationId
                        , hospitalId = d.hospitalId
                        , commandId = d.commandId
                        }
                B.goto ReservationConfirmed
  where
    isTerminal = \case
        ReservationExpired -> True
        ReservationAdmitted -> True
        ReservationReleased -> True
        _ -> False

applyTransfer_decisions :: ReservationEvent -> recorded -> txn ()
applyTransfer_decisions _event _recorded = error "HOLE: fill transfer_decisions projection apply"

-- Bring a v1 TransferReservationCreated payload up to v2 by defaulting the new
-- `triageNote` field when it is absent (a v1-on-disk payload lacks it).
upcastTransferReservationCreatedV1 :: Value -> Either Text Value
upcastTransferReservationCreatedV1 v = case v of
    Object o -> Right (Object (KM.insertWith (\_new old -> old) "triageNote" (String "") o))
    _ -> Left "upcastTransferReservationCreatedV1: expected a JSON object"
