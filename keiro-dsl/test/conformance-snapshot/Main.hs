{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.Proxy (Proxy (..))
import Generated.HospitalCapacity.Reservation.Domain (ReservationRegs, ReservationVertex)
import Generated.HospitalCapacity.Reservation.EventStream (reservationEventStream, reservationEventStreamDef, reservationSnapshotFixture)
import Keiki.Shape qualified as Shape
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..), StateCodec (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    _ <- evaluate reservationEventStream
    case stateCodec reservationEventStreamDef of
        Nothing -> do
            putStrLn "snapshot codec present: False"
            exitFailure
        Just liveCodec -> do
            let (fixtureVersion, fixtureHash) = reservationSnapshotFixture
                versionOk = stateCodecVersion liveCodec == fixtureVersion
                hashOk = shapeHash liveCodec == fixtureHash
                hashDerived = shapeHash liveCodec == Shape.regFileShapeHash (Proxy @ReservationRegs)
                stateShapeDerived =
                    stateShapeHash liveCodec
                        == Shape.stateShapeHash (Proxy @ReservationVertex) <> ";fold=2367ef6fadf0e751"
                policyOk = case snapshotPolicy reservationEventStreamDef of
                    Every interval -> interval == 100
                    _ -> False
                encoded = encode liveCodec (initialState reservationEventStreamDef, initialRegisters reservationEventStreamDef)
                roundTripOk = case decode liveCodec encoded of
                    Left _ -> False
                    Right decoded -> encode liveCodec decoded == encoded
                checks = [versionOk, hashOk, hashDerived, stateShapeDerived, policyOk, roundTripOk]
            putStrLn ("live snapshot shape hash: " <> show (shapeHash liveCodec))
            putStrLn ("codec version matches captured fixture: " <> show versionOk)
            putStrLn ("shape hash matches captured fixture: " <> show hashOk)
            putStrLn ("shape hash matches live regFileShapeHash: " <> show hashDerived)
            putStrLn ("state shape and fold fingerprint match live derivation: " <> show stateShapeDerived)
            putStrLn ("snapshot policy is Every 100: " <> show policyOk)
            putStrLn ("initial snapshot JSON round-trips: " <> show roundTripOk)
            unless (and checks) exitFailure
