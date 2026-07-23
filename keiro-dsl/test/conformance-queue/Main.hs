{- | Conformance driver for the scaffolded EP-5 pgmq Job codec. Compiling this
component proves the scaffolded @Generated.…Reservation_work.Queue@ module
(the Job payload record + field->wire JSON codec + physical/dlq/table
constants) is real, self-contained Haskell; running it proves the payload
round-trips through encode/decode and the captured physical name is exposed.
-}
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Generated.HospitalCapacity.Reservation_work.Queue
import Generated.HospitalCapacity.Reservation_work.QueueCodec (reservationWorkJobCodec)
import Keiro.PGMQ.Codec (JobCodec (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    let sample = ReservationWorkItem "rsv-1" "hsp-1" "cmd-1" True
        roundTrips = parseReservationWorkItem (encodeReservationWorkItem sample) == Right sample
        envelope =
            object
                [ "v" .= (1 :: Int)
                , "t" .= ("ReservationWorkItem" :: String)
                , "data" .= encodeReservationWorkItem sample
                ]
        envelopeOk =
            encodeJob reservationWorkJobCodec sample == envelope
                && decodeJob reservationWorkJobCodec envelope == Right sample
        physicalOk = queuePhysical == "hospital_capacity_reservation_work"
        groupKeyOk = groupKeyFor sample == "rsv-1"
    putStrLn ((if roundTrips then "PASS  " else "FAIL  ") <> "Job codec round-trip")
    putStrLn ((if envelopeOk then "PASS  " else "FAIL  ") <> "versioned {v,t,data} job envelope")
    putStrLn ((if physicalOk then "PASS  " else "FAIL  ") <> "captured physical name")
    putStrLn ((if groupKeyOk then "PASS  " else "FAIL  ") <> "raw FIFO group-key projection")
    unless (roundTrips && envelopeOk && physicalOk && groupKeyOk) exitFailure
