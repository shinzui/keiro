{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (forM_, unless)
import Data.Aeson (Result (..), Value (..), object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Proxy (Proxy (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), picosecondsToDiffTime)
import Generated.AggregateScalars.ScalarLedger.Codec (encodeScalarLedgerEvent, parseScalarLedgerEvent, scalarLedgerCodec)
import Generated.AggregateScalars.ScalarLedger.Domain
import Generated.AggregateScalars.ScalarLedger.EventStream (scalarLedgerEventStream, scalarLedgerEventStreamDef)
import Generated.AggregateScalars.ScalarLedger.Harness (harnessAssertions)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, TransducerValidationWarning (..), ValidationOptions (..), defaultValidationOptions, lit, tadd, validateTransducer, (!), (.>=))
import Keiki.Shape (CanonicalTypeName (..))
import Keiro.Codec (eventType)
import Keiro.EventStream (EventStream (..), StateCodec (..))
import Numeric.Natural (Natural)
import System.Exit (exitFailure)

main :: IO ()
main = do
    _ <- evaluate scalarLedgerEventStream
    let checks =
            harnessAssertions
                <> [ ("event codec preserves picosecond Time and positive Natural", eventRoundTrip)
                   , ("event JSON is exact at picosecond precision", exactEventJson)
                   , ("snapshot codec preserves initial Time and Natural zero", snapshotRoundTrip)
                   , ("Natural JSON accepts zero", naturalJsonAccepts 0)
                   , ("Natural JSON accepts a positive integer", naturalJsonAccepts 7)
                   , ("Natural JSON rejects a negative integer", naturalJsonRejects (Number (-1)))
                   , ("Natural JSON rejects a fractional number", naturalJsonRejects (Number 1.5))
                   , ("Natural canonical type name is stable", canonicalTypeName (Proxy @Natural) == "Natural")
                   , ("Natural arithmetic is structural in Keiki", naturalArithmeticIsStructural)
                   ]
    forM_ checks $ \(label, passed) ->
        putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
    unless (all snd checks) exitFailure

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 1 2) (picosecondsToDiffTime 11045123456789012)

sampleEvent :: ScalarLedgerEvent
sampleEvent = ScalarsRecorded ScalarsRecordedData{observedAt = sampleTime, revision = 7}

eventRoundTrip :: Bool
eventRoundTrip =
    parseScalarLedgerEvent
        (eventType scalarLedgerCodec sampleEvent)
        (encodeScalarLedgerEvent sampleEvent)
        == Right sampleEvent

exactEventJson :: Bool
exactEventJson =
    encodeScalarLedgerEvent sampleEvent
        == object
            [ "kind" .= ("ScalarsRecorded" :: String)
            , "observedAt" .= sampleTime
            , "revision" .= (7 :: Natural)
            ]

snapshotRoundTrip :: Bool
snapshotRoundTrip = case stateCodec scalarLedgerEventStreamDef of
    Nothing -> False
    Just codec ->
        let encoded = encode codec (initialState scalarLedgerEventStreamDef, initialRegisters scalarLedgerEventStreamDef)
         in case decode codec encoded of
                Left _ -> False
                Right (vertex, registers) ->
                    vertex == ScalarLedgerEmpty
                        && registers ! #observedAt == sampleTime
                        && registers ! #revision == 0
                        && encode codec (vertex, registers) == encoded

naturalJsonAccepts :: Natural -> Bool
naturalJsonAccepts expected = Aeson.fromJSON (toJSON expected) == Success expected

naturalJsonRejects :: Value -> Bool
naturalJsonRejects value = case Aeson.fromJSON value :: Result Natural of
    Error _ -> True
    Success _ -> False

naturalArithmeticIsStructural :: Bool
naturalArithmeticIsStructural = not (any isOpaque warnings)
  where
    warnings =
        validateTransducer
            defaultValidationOptions{warnOpaqueGuards = True}
            naturalArithmeticTransducer
    isOpaque OpaqueGuard{} = True
    isOpaque _ = False

naturalArithmeticTransducer ::
    SymTransducer
        (HsPred ScalarLedgerRegs ScalarLedgerCommand)
        ScalarLedgerRegs
        ScalarLedgerVertex
        ScalarLedgerCommand
        ScalarLedgerEvent
naturalArithmeticTransducer =
    B.buildTransducer ScalarLedgerEmpty initialScalarLedgerRegs (const False) do
        B.from ScalarLedgerEmpty do
            B.onCmd inCtorRecord $ \command -> B.do
                B.requireGuard (tadd command.revision (lit 1) .>= command.revision)
                B.noEmit
                B.goto ScalarLedgerEmpty
