module Main (main) where

import Conformance.IdAdmissionDomains.Bindings qualified as Bindings
import Conformance.IdAdmissionDomains.Domain (IdentityEnvelope (..))
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Generated.IdAdmissionDomains.Identities.Contract
import Generated.IdAdmissionDomains.IdentityLedger.Codec
import Generated.IdAdmissionDomains.IdentityLedger.Domain
import Generated.IdAdmissionDomains.IdentityLedger.Harness (harnessAssertions)
import Generated.IdAdmissionDomains.IdentityLedger.Transducer (identityLedgerTransducer)
import Generated.IdAdmissionDomains.IdentityWork.Queue
import Generated.IdAdmissionDomains.Nominals (LegacyId, legacyIdText, parseLegacyId)
import Generated.IdAdmissionDomains.Structural.NominalLeaves (parseLegacyIdLeafKey, renderLegacyIdLeafKey)
import Generated.IdAdmissionDomains.StructuralConformance (structuralConformanceAssertions)
import Keiki.Core (applyEventsEither, (!))
import Keiro.Codec (EventType (..), eventType)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let event = IdentityRecorded (IdentityRecordedData Bindings.uuidV5 Bindings.mixedEnvelope)
      encodedEvent = encodeIdentityLedgerEvent event
      contractPayload = IdentityLinked (IdentityLinkedData Bindings.uuidV5)
      queuePayload = IdentityWork Bindings.uuidV7 Bindings.mixedEnvelope
      assertions =
        structuralConformanceAssertions
          <> harnessAssertions
          <> [ ("generated admission accepts committed UUIDv5", (legacyIdText <$> parseLegacyId Bindings.uuidV5Text) == Right Bindings.uuidV5Text),
               ("generated admission accepts committed UUIDv7", (legacyIdText <$> parseLegacyId Bindings.uuidV7Text) == Right Bindings.uuidV7Text),
               ("generated aggregate codec preserves mixed UUID history", parseIdentityLedgerEvent (eventType identityLedgerCodec event) encodedEvent == Right event),
               ("serialized UUIDv5 and UUIDv7 multi-event history replays", serializedMultiEventReplay),
               ("replay-only UUIDv5 history preserves the admitted ID", replayOnlyAdmission),
               ("a first event that loses its admitted ID is rejected", headInformationLossRejected),
               ("identifier map keys reconstruct their exact owners", keyRoundTrip),
               ("public contract preserves UUIDv5", parseIdentitiesPayload (encodeIdentitiesPayload contractPayload) == Right contractPayload),
               ("queue payload preserves nested and direct IDs", parseIdentityWork (encodeIdentityWork queuePayload) == Right queuePayload),
               ("implicit wrong versions remain rejected", isRejected (parseLegacyId "legacy_00041061050r3gg28a1c60t3gf")),
               ("wrong prefixes remain rejected", isRejected (parseLegacyId "other_58kj0y515rbwebzaxwzzknjqnk"))
             ]
  forM_ assertions $ \(label, passed) -> putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd assertions) exitFailure

keyRoundTrip :: Bool
keyRoundTrip =
  renderLegacyIdLeafKey Bindings.uuidV5 == Bindings.uuidV5Text
    && parseEither (const (parseLegacyIdLeafKey Bindings.uuidV5Text)) () == Right Bindings.uuidV5
    && Map.lookup Bindings.uuidV5 (Bindings.mixedEnvelope.labelsById) == Just "historical-v5"

isRejected :: Either problem value -> Bool
isRejected = either (const True) (const False)

serializedMultiEventReplay :: Bool
serializedMultiEventReplay =
  case replayRawIdentityChain [Bindings.uuidV5Text, Bindings.uuidV7Text] of
    Left _ -> False
    Right (vertex, current) -> vertex == IdentityLedgerOpen && current == Bindings.uuidV7

replayRawIdentityChain :: [Text] -> Either Text (IdentityLedgerVertex, LegacyId)
replayRawIdentityChain wires = do
  events <- concat <$> traverse rawTransition wires
  (vertex, registers) <- firstText (applyEventsEither identityLedgerTransducer (IdentityLedgerOpen, initialIdentityLedgerRegs) events)
  pure (vertex, registers ! #current)
  where
    rawTransition wire = do
      let recorded = IdentityRecorded (IdentityRecordedData Bindings.uuidV5 Bindings.mixedEnvelope)
          audited = IdentityAudited (IdentityAuditedData Bindings.uuidV5 Bindings.mixedEnvelope)
      recordedEvent <- parseIdentityLedgerEvent (EventType "IdentityRecorded") (replaceObjectField "legacyId" (String wire) (encodeIdentityLedgerEvent recorded))
      auditedEvent <- parseIdentityLedgerEvent (EventType "IdentityAudited") (replaceObjectField "legacyId" (String wire) (encodeIdentityLedgerEvent audited))
      pure [recordedEvent, auditedEvent]

replayOnlyAdmission :: Bool
replayOnlyAdmission =
  case parseIdentityLedgerEvent (EventType "LegacyIdentityImported") rawEvent of
    Left _ -> False
    Right parsedEvent ->
      case applyEventsEither identityLedgerTransducer (IdentityLedgerOpen, initialIdentityLedgerRegs) [parsedEvent] of
        Left _ -> False
        Right (vertex, registers) ->
          vertex == IdentityLedgerOpen && registers ! #current == Bindings.uuidV5
  where
    event = LegacyIdentityImported (LegacyIdentityImportedData Bindings.uuidV7 Bindings.mixedEnvelope)
    rawEvent = replaceObjectField "legacyId" (String Bindings.uuidV5Text) (encodeIdentityLedgerEvent event)

headInformationLossRejected :: Bool
headInformationLossRejected =
  isLeft (parseIdentityLedgerEvent kind (deleteObjectField "legacyId" encoded))
  where
    event = IdentityRecorded (IdentityRecordedData Bindings.uuidV5 Bindings.mixedEnvelope)
    kind = eventType identityLedgerCodec event
    encoded = encodeIdentityLedgerEvent event

firstText :: (Show problem) => Either problem value -> Either Text value
firstText = either (Left . T.pack . show) Right

deleteObjectField :: Key.Key -> Value -> Value
deleteObjectField key (Object value) = Object (KeyMap.delete key value)
deleteObjectField _ value = value

replaceObjectField :: Key.Key -> Value -> Value -> Value
replaceObjectField key inserted (Object value) = Object (KeyMap.insert key inserted value)
replaceObjectField _ _ value = value
