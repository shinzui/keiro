-- Snapshot conformance retains only the DB-coupled projection boundary;
-- stable generated code owns the aggregate transducer.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module HospitalCapacity.Reservation.Holes
  ( transition2HeldConfirmReservationOutput1TransferReservationConfirmed,
    applyTransfer_decisions,
  )
where

import Generated.HospitalCapacity.Reservation.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)

transition2HeldConfirmReservationOutput1TransferReservationConfirmed :: B.PayloadProj ReservationRegs ReservationCommand (RegFieldsOf ConfirmReservationData) -> TransferReservationConfirmedTermFields ReservationRegs ReservationCommand (RegFieldsOf ConfirmReservationData)
transition2HeldConfirmReservationOutput1TransferReservationConfirmed command =
  TransferReservationConfirmedTermFields
    { reservationId = command.reservationId,
      hospitalId = command.hospitalId,
      commandId = command.commandId
    }

applyTransfer_decisions :: ReservationEvent -> recorded -> txn ()
applyTransfer_decisions _event _recorded = error "HOLE: fill transfer_decisions projection apply"
