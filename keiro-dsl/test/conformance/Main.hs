{-# LANGUAGE OverloadedStrings #-}

{- | Conformance harness for the captured HospitalCapacity/Reservation aggregate.
This component exists to prove that the scaffolded @Generated@ modules plus a
hand-filled @Holes.hs@ actually compile against keiki/keiro, and that the
filled transducer passes keiki's validator and the codec round-trips. EP-1
milestone 4 replaces this hand-written driver with the spec-derived harness
emitted by 'Keiro.Dsl.Harness.harnessFor'.
-}
module Main (main) where

import Generated.HospitalCapacity.Reservation.Codec (encodeReservationEvent, parseReservationEvent)
import Generated.HospitalCapacity.Reservation.Domain
import HospitalCapacity.Reservation.Holes (reservationTransducer)
import Keiki.Core (defaultValidationOptions, validateTransducer)
import System.Exit (exitFailure)

main :: IO ()
main = do
    let warnings = validateTransducer defaultValidationOptions reservationTransducer
    ok1 <-
        if null warnings
            then putStrLn "conformance: validateTransducer == [] OK" >> pure True
            else putStrLn ("conformance: validateTransducer warnings: " <> show warnings) >> pure False
    let sample =
            TransferReservationConfirmed
                (TransferReservationConfirmedData (TransferReservationId "r1") (HospitalId "h1") (CommandId "c1"))
    ok2 <- case parseReservationEvent (encodeReservationEvent sample) of
        Right ev | ev == sample -> putStrLn "conformance: codec round-trip OK" >> pure True
        other -> putStrLn ("conformance: codec round-trip FAIL: " <> show other) >> pure False
    if ok1 && ok2 then pure () else exitFailure
