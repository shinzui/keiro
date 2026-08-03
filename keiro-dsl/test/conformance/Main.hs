-- | Conformance driver for the captured HospitalCapacity/Reservation aggregate.
-- It runs the spec-derived harness emitted by 'Keiro.Dsl.Harness.harnessFor'
-- (the @Generated.…Harness@ module) over the hand-filled @Holes.hs@, printing
-- each labelled assertion and exiting non-zero if any is False. Compiling this
-- component at all proves the scaffolded Generated modules + filled holes build
-- against keiki/keiro; running it proves the filled transducer is valid, every
-- event round-trips, and the guarded transition behaves as specified.
--
-- The mutation check (flip @./=@ to @.==@ in Holes, rebuild) turns the
-- "accepts RequestTransferReservation …" assertion red, proving the harness —
-- not the scaffold — pins behaviour.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (encode, object)
import Data.ByteString.Lazy (ByteString)
import Generated.HospitalCapacity.Nominals (CommandId, DivertStatus (..), HospitalId, PatientAcuity (..), TransferReservationId, parseCommandId, parseHospitalId, parseTransferReservationId)
import Generated.HospitalCapacity.Reservation.Codec (encodeReservationEvent, parseReservationEvent)
import Generated.HospitalCapacity.Reservation.Domain (ReservationEvent (..), TransferReservationCreatedData (..))
import Generated.HospitalCapacity.Reservation.Harness (harnessAssertions)
import Keiro.Codec (EventType (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  forM_ harnessAssertions $ \(label, ok) ->
    putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
  let failed = [label | (label, ok) <- harnessAssertions, not ok]
      sample =
        TransferReservationCreated
          (TransferReservationCreatedData transferReservationIdValue hospitalIdValue commandIdValue RedTag Open False)
      expectedBytes :: ByteString
      expectedBytes = "{\"commandId\":\"cmd_01h455vb4pex5vsknk084sn02q\",\"divertStatus\":\"open\",\"hospitalId\":\"hosp_01h455vb4pex5vsknk084sn02q\",\"kind\":\"TransferReservationCreated\",\"lifeCriticalOverride\":false,\"patientAcuity\":\"red\",\"reservationId\":\"rsv_01h455vb4pex5vsknk084sn02q\"}"
      wireBytesOk = encode (encodeReservationEvent sample) == expectedBytes
      acceptedOutcomeOk = parseReservationEvent (EventType "TransferReservationCreated") (encodeReservationEvent sample) == Right sample
      rejectedOutcomeOk = case parseReservationEvent (EventType "UnknownEvent") (object []) of
        Left _ -> True
        Right _ -> False
  putStrLn ("event bytes pinned: " <> show wireBytesOk)
  putStrLn ("event decoder acceptance/rejection pinned: " <> show (acceptedOutcomeOk && rejectedOutcomeOk))
  unless (null failed && wireBytesOk && acceptedOutcomeOk && rejectedOutcomeOk) $ do
    putStrLn ("harness: " <> show (length failed) <> " assertion(s) failed")
    exitFailure

transferReservationIdValue :: TransferReservationId
transferReservationIdValue = either (error . show) id (parseTransferReservationId "rsv_01h455vb4pex5vsknk084sn02q")

hospitalIdValue :: HospitalId
hospitalIdValue = either (error . show) id (parseHospitalId "hosp_01h455vb4pex5vsknk084sn02q")

commandIdValue :: CommandId
commandIdValue = either (error . show) id (parseCommandId "cmd_01h455vb4pex5vsknk084sn02q")
