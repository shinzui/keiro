{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Conformance.StructuralNominals.Bindings qualified as Bindings
import Conformance.StructuralNominals.Domain
import Conformance.StructuralNominals.Historical (historicalTemplateStateCodec)
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text qualified as T
import Generated.StructuralNominalLeaves.Nominals (TemplateId)
import Generated.StructuralNominalLeaves.StructuralConformance (structuralConformanceAssertions)
import Generated.StructuralNominalLeaves.Structural.CodecCompare.TemplateState (compareWithHistorical)
import Generated.StructuralNominalLeaves.TemplateCatalog.Codec
import Generated.StructuralNominalLeaves.TemplateCatalog.Codec qualified as GeneratedCodec
import Generated.StructuralNominalLeaves.TemplateCatalog.Domain
import Generated.StructuralNominalLeaves.TemplateCatalog.Harness (harnessAssertions)
import Generated.StructuralNominalLeaves.TemplateLookup.QueryContract
import Generated.StructuralNominalLeaves.TemplateWork.Queue
import Generated.MappedNominalQueryOnly.TemplateLookup.QueryContract qualified as QueryOnly
import Generated.MappedNominalQueryOnly.Nominals qualified as QueryOnlyNominals
import Generated.MappedNominalQueueOnly.Nominals qualified as QueueOnlyNominals
import Generated.MappedNominalQueueOnly.TemplateWork.Queue qualified as QueueOnly
import Keiki.Core ((!))
import Keiro.Codec (eventType)
import Keiro.Dsl.CodecCompare (HistoricalCodec (..), reportSucceeded)
import Keiro.EventStream qualified as EventStream
import Keiro.Snapshot.Codec (defaultStateCodec)
import System.Exit (exitFailure)

main :: IO ()
main = do
  comparison <- compareWithHistorical historicalTemplateStateCodec "test/conformance-structural-nominals/fixtures/codec-compare"
  malformed <-
    (Aeson.eitherDecodeFileStrict "test/conformance-structural-nominals/fixtures/codec-compare-malformed/template-state-wrong-prefix.json" :: IO (Either String Value))
  let assertions =
        [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
          <> harnessAssertions
          <> [ ("event payload nominal leaves round-trip canonically", eventRoundTrip),
               ("snapshot with nested nominal leaves round-trips", snapshotRoundTrip),
               ("generated TemplateId admission rejects wrong prefix at nested path", rejectedAt nestedPath (badBook (String Bindings.claimIdText))),
               ("generated TemplateId admission rejects non-canonical text at nested path", rejectedAt nestedPath (badBook (String "template_01H455VB4PEX5VSKNK084SN02Q"))),
               ("generated TemplateId admission rejects non-v7 UUID at nested path", rejectedAt nestedPath (badBook (String "template_01h455vb4p8x5vsknk084sn02q"))),
               ("generated TemplateId admission rejects null at nested path", rejectedAt nestedPath (badBook Null)),
               ("optional ClaimId distinguishes null from a present ID", optionalHolderRoundTrip),
               ("queue nominal leaves round-trip canonically", queueRoundTrip),
               ("queue generated ID rejection is located", rejectedAt "$['template_id']" badQueue),
               ("query aliases preserve nominal domain types", queryAliasAgreement),
               ("queue-only nominal scaffold compiles with its leaf helper", queueOnlyAgreement),
               ("query-only nominal scaffold compiles without a leaf helper", queryOnlyAgreement),
               ("historical opaque TemplateState codec has parity with the generated codec", reportSucceeded comparison),
               ("historical and generated TemplateState codecs both reject malformed IDs", malformedIdRejected malformed)
             ]
  forM_ assertions $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd assertions) exitFailure

malformedIdRejected :: Either String Value -> Bool
malformedIdRejected = \case
  Left _ -> False
  Right value ->
    isRejected (historicalTemplateStateCodec.decode value)
      && isRejected (GeneratedCodec.decodeTemplateStateMapped value)
  where
    isRejected = \case Left _ -> True; Right _ -> False

eventRoundTrip :: Bool
eventRoundTrip =
  parseTemplateCatalogEvent (eventType templateCatalogCodec sampleEvent) encoded == Right sampleEvent
    && containsString Bindings.templateIdText1 encoded
    && containsString Bindings.claimIdText encoded
    && containsString "account-007" encoded
  where
    encoded = encodeTemplateCatalogEvent sampleEvent

sampleEvent :: TemplateCatalogEvent
sampleEvent =
  TemplateRecorded
    ( TemplateRecordedData
        Bindings.stateWithHolder
        (ByAccount Bindings.accountNumber)
        Bindings.initialTemplateBook
    )

snapshotRoundTrip :: Bool
snapshotRoundTrip = case EventStream.decode codec encoded of
  Left _ -> False
  Right (vertex, registers) ->
    vertex == TemplateCatalogEmpty
      && registers ! #book == Bindings.initialTemplateBook
      && EventStream.encode codec (vertex, registers) == encoded
  where
    codec = defaultStateCodec @TemplateCatalogRegs @TemplateCatalogVertex 1
    encoded = EventStream.encode codec (TemplateCatalogEmpty, initialTemplateCatalogRegs)

nestedPath :: Text
nestedPath = "$.templates[1].templateId"

badBook :: Value -> Either Text TemplateBook
badBook replacement = decodeTemplateBookMapped value
  where
    value =
      object
        [ "templates"
            .= [ encodeTemplateStateMapped Bindings.stateWithoutHolder,
                 replaceObjectField "templateId" replacement (encodeTemplateStateMapped Bindings.stateWithHolder)
               ],
          "holders" .= [Null, String Bindings.claimIdText],
          "byKey"
            .= object
              [ "primary" .= String Bindings.templateIdText1,
                "secondary" .= String Bindings.templateIdText2
              ]
        ]

optionalHolderRoundTrip :: Bool
optionalHolderRoundTrip =
  decodeTemplateStateMapped (encodeTemplateStateMapped Bindings.stateWithoutHolder) == Right Bindings.stateWithoutHolder
    && decodeTemplateStateMapped (encodeTemplateStateMapped Bindings.stateWithHolder) == Right Bindings.stateWithHolder

queueRoundTrip :: Bool
queueRoundTrip =
  parseTemplateWork encoded == Right payload
    && containsString Bindings.templateIdText1 encoded
    && containsString Bindings.claimIdText encoded
  where
    payload = TemplateWork Bindings.templateId1 (Just Bindings.claimId)
    encoded = encodeTemplateWork payload

badQueue :: Either Text TemplateWork
badQueue =
  parseTemplateWork
    ( object
        [ "template_id" .= String Bindings.claimIdText,
          "holder" .= Null
        ]
    )

queryAliasAgreement :: Bool
queryAliasAgreement =
  queryInputIdentity Bindings.stateWithHolder == Bindings.stateWithHolder
    && queryResultIdentity [Bindings.templateId1] == [Bindings.templateId1]

queryInputIdentity :: TemplateLookupQueryInput -> TemplateState
queryInputIdentity = id

queryResultIdentity :: TemplateLookupQueryResult -> [TemplateId]
queryResultIdentity = id

queueOnlyAgreement :: Bool
queueOnlyAgreement = case QueueOnlyNominals.parseTemplateId Bindings.templateIdText1 of
  Left _ -> False
  Right templateId ->
    let payload = QueueOnly.TemplateWork (Just templateId)
     in QueueOnly.parseTemplateWork (QueueOnly.encodeTemplateWork payload) == Right payload

queryOnlyAgreement :: Bool
queryOnlyAgreement = case QueryOnlyNominals.parseTemplateId Bindings.templateIdText1 of
  Left _ -> False
  Right templateId ->
    queryOnlyInputIdentity templateId == templateId
      && queryOnlyResultIdentity [templateId] == [templateId]

queryOnlyInputIdentity :: QueryOnly.TemplateLookupQueryInput -> QueryOnly.TemplateLookupQueryInput
queryOnlyInputIdentity = id

queryOnlyResultIdentity :: QueryOnly.TemplateLookupQueryResult -> QueryOnly.TemplateLookupQueryResult
queryOnlyResultIdentity = id

rejectedAt :: Text -> Either Text value -> Bool
rejectedAt path result = case result of
  Left problem -> path `T.isInfixOf` problem
  Right _ -> False

replaceObjectField :: Text -> Value -> Value -> Value
replaceObjectField field replacement (Object fields) =
  Object (KeyMap.insert (Key.fromText field) replacement fields)
replaceObjectField _ _ value = value

containsString :: Text -> Value -> Bool
containsString expected = \case
  String value -> value == expected
  Array values -> any (containsString expected) values
  Object fields -> any (containsString expected) fields
  _ -> False
