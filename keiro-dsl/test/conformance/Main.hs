{- | Conformance driver for the captured HospitalCapacity/Reservation aggregate.
It runs the spec-derived harness emitted by 'Keiro.Dsl.Harness.harnessFor'
(the @Generated.…Harness@ module) over the hand-filled @Holes.hs@, printing
each labelled assertion and exiting non-zero if any is False. Compiling this
component at all proves the scaffolded Generated modules + filled holes build
against keiki/keiro; running it proves the filled transducer is valid, every
event round-trips, and the guarded transition behaves as specified.

The mutation check (flip @./=@ to @.==@ in Holes, rebuild) turns the
"accepts RequestTransferReservation …" assertion red, proving the harness —
not the scaffold — pins behaviour.
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
