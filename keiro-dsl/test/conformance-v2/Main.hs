{- | Conformance driver for the evolved (v2) HospitalCapacity/Reservation
aggregate (EP-2). Compiling this component proves the scaffolded v2 Generated
modules — a Codec with @schemaVersion = 2@ and
@upcasters = [(1, upcastTransferReservationCreatedV1)]@ — build against
keiki/keiro with the hand-filled upcaster hole. Running it proves the upcaster
chain actually migrates a v1-tagged payload forward (the "upcaster wired"
harness assertion is green only because the hole is filled).
-}
module Main (main) where

import Control.Monad (forM_, unless)
import Generated.HospitalCapacity.Reservation.Harness (harnessAssertions)
import System.Exit (exitFailure)

main :: IO ()
main = do
    forM_ harnessAssertions $ \(label, ok) ->
        putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)
    let failed = [label | (label, ok) <- harnessAssertions, not ok]
    unless (null failed) $ do
        putStrLn ("harness: " <> show (length failed) <> " assertion(s) failed")
        exitFailure
