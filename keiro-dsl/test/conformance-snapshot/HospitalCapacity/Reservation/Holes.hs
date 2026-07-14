{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Its transducer body has been filled by hand to match the
-- captured HospitalCapacity/Reservation reference, against the generated
-- signatures. The harness pins this behaviour.
module HospitalCapacity.Reservation.Holes (
    reservationTransducer,
    applyTransfer_decisions,
) where

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

-- HOLE (DB-coupled, out of scope for EP-1): the read-model SQL for the
-- transfer_decisions projection. The pure event->status mapping is generated as
-- transfer_decisionsStatusFor. Left as a typed hole; the harness does not pin it.
applyTransfer_decisions :: ReservationEvent -> recorded -> txn ()
applyTransfer_decisions _event _recorded = error "HOLE: fill transfer_decisions projection apply"
