{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- Stable generated code owns the aggregate transducer. This hand-owned module
-- retains the projection boundary and the historical schema-v1 upcaster.
module HospitalCapacity.Reservation.Holes
  ( transition1UnrequestedRequestTransferReservationOutput1TransferReservationCreated,
    transition2HeldConfirmReservationOutput1TransferReservationConfirmed,
    applyTransfer_decisions,
    upcastTransferReservationCreatedV1,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Generated.HospitalCapacity.Reservation.Domain
import Keiki.Builder qualified as B
import Keiki.Core (lit)
import Keiki.Generics (RegFieldsOf)

transition1UnrequestedRequestTransferReservationOutput1TransferReservationCreated :: B.PayloadProj ReservationRegs ReservationCommand (RegFieldsOf RequestTransferReservationData) -> TransferReservationCreatedTermFields ReservationRegs ReservationCommand (RegFieldsOf RequestTransferReservationData)
transition1UnrequestedRequestTransferReservationOutput1TransferReservationCreated command =
  TransferReservationCreatedTermFields
    { reservationId = command.reservationId,
      hospitalId = command.hospitalId,
      commandId = command.commandId,
      patientAcuity = command.patientAcuity,
      divertStatus = command.divertStatus,
      lifeCriticalOverride = command.lifeCriticalOverride,
      triageNote = lit ""
    }

transition2HeldConfirmReservationOutput1TransferReservationConfirmed :: B.PayloadProj ReservationRegs ReservationCommand (RegFieldsOf ConfirmReservationData) -> TransferReservationConfirmedTermFields ReservationRegs ReservationCommand (RegFieldsOf ConfirmReservationData)
transition2HeldConfirmReservationOutput1TransferReservationConfirmed command =
  TransferReservationConfirmedTermFields
    { reservationId = command.reservationId,
      hospitalId = command.hospitalId,
      commandId = command.commandId
    }

applyTransfer_decisions :: ReservationEvent -> recorded -> txn ()
applyTransfer_decisions _event _recorded = error "HOLE: fill transfer_decisions projection apply"

upcastTransferReservationCreatedV1 :: Value -> Either Text Value
upcastTransferReservationCreatedV1 value = case value of
  Object fields -> Right (Object (KM.insertWith (\_new old -> old) "triageNote" (String "") fields))
  _ -> Left "upcastTransferReservationCreatedV1: expected a JSON object"
