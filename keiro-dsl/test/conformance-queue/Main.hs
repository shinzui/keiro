{- | Conformance driver for the scaffolded EP-5 pgmq Job codec. Compiling this
component proves the scaffolded @Generated.…Reservation_work.Queue@ module
(the Job payload record + field->wire JSON codec + physical/dlq/table
constants) is real, self-contained Haskell; running it proves the payload
round-trips through encode/decode and the captured physical name is exposed.
-}
module Main (main) where

import Control.Monad (unless)
import Generated.HospitalCapacity.Reservation_work.Queue
import System.Exit (exitFailure)

main :: IO ()
main = do
    let sample = ReservationWorkItem "rsv-1" "hsp-1" "cmd-1" True
        roundTrips = parseReservationWorkItem (encodeReservationWorkItem sample) == Right sample
        physicalOk = queuePhysical == "hospital_capacity_reservation_work"
    putStrLn ((if roundTrips then "PASS  " else "FAIL  ") <> "Job codec round-trip")
    putStrLn ((if physicalOk then "PASS  " else "FAIL  ") <> "captured physical name")
    unless (roundTrips && physicalOk) exitFailure
