{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (sort)
import Data.Proxy (Proxy (..))
import Data.Text qualified as Text
import Generated.HospitalCapacity.Inspection (aggregateInspectorCatalog, aggregateInspectors, inspectionProjectionCatalog)
import Generated.HospitalCapacity.Reservation.Domain (ReservationRegs, ReservationVertex)
import Generated.HospitalCapacity.Reservation.EventStream (reservationEventStream, reservationEventStreamDef, reservationSnapshotFixture)
import Generated.HospitalCapacity.Reservation.Transducer (reservationFoldFingerprint)
import Keiki.Shape qualified as Shape
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..), StateCodec (..))
import Keiro.EventStream.Validate (unvalidated)
import Keiro.Inspection.Aggregate (AggregateInspector (..), AggregateTypeSummary (AggregateTypeSummary), SomeAggregateInspector (..), listAggregateTypes)
import Keiro.Projection.Catalog (Validation (..), catalogFingerprint, catalogFingerprintText, emptyProjectionCatalog, validateProjectionCatalog)
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
                        == Shape.stateShapeHash (Proxy @ReservationVertex) <> ";fold=" <> reservationFoldFingerprint
                policyOk = case snapshotPolicy reservationEventStreamDef of
                    Every interval -> interval == 100
                    _ -> False
                encoded = encode liveCodec (initialState reservationEventStreamDef, initialRegisters reservationEventStreamDef)
                roundTripOk = case decode liveCodec encoded of
                    Left _ -> False
                    Right decoded -> encode liveCodec decoded == encoded
                inspection = inspectionChecks encoded
                checks = [versionOk, hashOk, hashDerived, stateShapeDerived, policyOk, roundTripOk] <> map snd inspection
            putStrLn ("live snapshot shape hash: " <> show (shapeHash liveCodec))
            putStrLn ("codec version matches captured fixture: " <> show versionOk)
            putStrLn ("shape hash matches captured fixture: " <> show hashOk)
            putStrLn ("shape hash matches live regFileShapeHash: " <> show hashDerived)
            putStrLn ("state shape and fold fingerprint match live derivation: " <> show stateShapeDerived)
            putStrLn ("snapshot policy is Every 100: " <> show policyOk)
            putStrLn ("initial snapshot JSON round-trips: " <> show roundTripOk)
            mapM_ (\(line, _) -> putStrLn line) inspection
            unless (and checks) exitFailure

-- The generated Inspection module for a snapshot aggregate: its display is the
-- aggregate's own state codec, it reports the configured snapshot policy, and
-- an aggregates-only context mounts the validated empty projection catalog.
inspectionChecks :: Value -> [(String, Bool)]
inspectionChecks codecEncoded =
    [ ("reservation display uses the state codec: " <> show usesCodec, usesCodec)
    , ("reservation display keys: " <> show displayKeys, displayKeys == ["registers", "state"])
    , ("reservation snapshot policy: " <> unwords [Text.unpack policy <> (if configured then "" else " (unconfigured)") | (configured, policy) <- summaries], summaries == [(True, "every:100")])
    , ("inspection projection catalog is empty: " <> show catalogEmpty, catalogEmpty)
    ]
  where
    display = case aggregateInspectorCatalog of
        [SomeAggregateInspector inspector] ->
            let definition = unvalidated inspector.eventStream
             in Just (inspector.displayState (initialState definition) (initialRegisters definition))
        _ -> Nothing
    usesCodec = display == Just codecEncoded
    displayKeys = case display of
        Just (Object fields) -> sort (map Key.toString (KeyMap.keys fields))
        _ -> []
    summaries = [(configured, policy) | AggregateTypeSummary _ _ configured policy <- listAggregateTypes aggregateInspectors]
    fingerprint = catalogFingerprintText . catalogFingerprint
    catalogEmpty = case validateProjectionCatalog emptyProjectionCatalog of
        Success empty -> fingerprint inspectionProjectionCatalog == fingerprint empty
        Failure _ -> False
