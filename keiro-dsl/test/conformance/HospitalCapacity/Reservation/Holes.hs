-- This is a HAND-OWNED hole module. keiro-dsl creates it once and never
-- overwrites it. Stable generated code owns the aggregate transducer; this
-- module retains only the DB-coupled projection implementation boundary.
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
