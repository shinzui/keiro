module Main (main) where

import Conformance.StructuralTextSets.Bindings (textLabelsFixtures)
import Conformance.StructuralTextSets.Domain
import Conformance.StructuralTextSets.Historical (historicalTextLabelsCodec)
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), parseJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Generated.StructuralTextSets.LabelJobs.Queue (LabelJob (..), encodeLabelJob, parseLabelJob)
import Generated.StructuralTextSets.LabelLookup.QueryContract (LabelLookupQueryInput, LabelLookupQueryResult)
import Generated.StructuralTextSets.LabelStore.Codec
import Generated.StructuralTextSets.LabelStore.Domain
import Generated.StructuralTextSets.LabelStore.Harness (harnessAssertions)
import Generated.StructuralTextSets.LabelStore.Transducer (labelStoreTransducer)
import Generated.StructuralTextSets.StructuralConformance (structuralConformanceAssertions)
import Keiki.Core (applyEventsEither, (!))
import Keiro.Codec (EventType (..), eventType)
import Keiro.Codec.Structural qualified
import Keiro.Dsl.CodecCompare (CompareObservation (..), DecodeOutcome (..), FixtureVerdict (..), HistoricalCodec (..), classifyObservation)
import Keiro.Test.ReplayCompatibility (NormalizationFailure (..), checkNormalizationLaw)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let assertions =
        [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
          <> harnessAssertions
          <> [ ("bare Set Text writes sorted unique arrays", canonicalTextLabelsWire),
               ("duplicate and permuted arrays normalize before binding", nonCanonicalInputsNormalize),
               ("normalization preserves actual transducer replay state", normalizationReplayLaw),
               ("replay-only history normalizes before reaching the transducer", replayOnlyNormalization),
               ("a first event that loses set information is rejected", headInformationLossRejected),
               ("a list-valued live mutation fails the replay law", listMutationRejected),
               ("a strict duplicate reader requires versioned compatibility work", strictDuplicateReaderRejected),
               ("historical Aeson Set writer and reader remain compatible", historicalCodecParity),
               ("invalid set elements fail at their array position", invalidElementRejected),
               ("root optional set fields treat omission and null alike", rootOptionalAbsenceEquivalence),
               ("non-optional set fields still reject omission", nonOptionalRootStrict),
               ("nested list and map sets round-trip", nestedRoundTrip),
               ("queue payloads preserve structural text sets", queueRoundTrip),
               ("query contracts preserve structural text-set domain types", queryAgreement),
               ("application-owned workflow codecs normalize through the same set domain", workflowCodecRoundTrip)
             ]
  forM_ assertions $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd assertions) exitFailure

canonicalTextLabelsWire :: Bool
canonicalTextLabelsWire =
  encodeTextLabelsMapped value == Aeson.toJSON (["A", "a", "a\x0308", "ä", "\xE000", "\x10000"] :: [Text])
  where
    value = TextLabels (Set.fromList ["\x10000", "\xE000", "ä", "a\x0308", "a", "A"])

nonCanonicalInputsNormalize :: Bool
nonCanonicalInputsNormalize =
  decodeTextLabelsMapped nonCanonical == Right expected
    && decodeTextLabelsMapped canonical == Right expected
    && fmap encodeTextLabelsMapped (decodeTextLabelsMapped nonCanonical) == Right canonical
  where
    nonCanonical = Aeson.toJSON (["b", "a", "a"] :: [Text])
    canonical = Aeson.toJSON (["a", "b"] :: [Text])
    expected = TextLabels (Set.fromList ["a", "b"])

normalizationReplayLaw :: Bool
normalizationReplayLaw =
  null
    ( checkNormalizationLaw
        decodeTextLabelsMapped
        encodeTextLabelsMapped
        replayRawSetChain
        []
        (Aeson.toJSON (["b", "a", "a"] :: [Text]))
        (Aeson.toJSON (["a", "b"] :: [Text]))
        []
    )

-- The replay function receives the raw set array, inserts it into both events
-- of the generated transition, crosses the generated event parser, and then
-- applies the real generated transducer. Its observation includes control state
-- and the durable register, not merely the decoded set.
replayRawSetChain :: [Value] -> Either Text (LabelStoreVertex, TextLabels)
replayRawSetChain wires = do
  events <- concat <$> traverse rawTransition wires
  (vertex, registers) <- firstText (applyEventsEither labelStoreTransducer (LabelStoreEmpty, initialLabelStoreRegs) events)
  pure (vertex, registers ! #current)
  where
    rawTransition wire = do
      let labels = TextLabels Set.empty
          optional = MaybeTextLabels Nothing
          envelope = sampleEnvelope
          stored = LabelsStored (LabelsStoredData labels optional envelope)
          audited = LabelsAudited (LabelsAuditedData labels optional envelope)
      storedEvent <- parseLabelStoreEvent (EventType "LabelsStored") (replaceObjectField "labels" wire (encodeLabelStoreEvent stored))
      auditedEvent <- parseLabelStoreEvent (EventType "LabelsAudited") (replaceObjectField "labels" wire (encodeLabelStoreEvent audited))
      pure [storedEvent, auditedEvent]

replayOnlyNormalization :: Bool
replayOnlyNormalization =
  case parseLabelStoreEvent (EventType "LegacyLabelsImported") rawEvent of
    Left _ -> False
    Right parsedEvent ->
      case applyEventsEither labelStoreTransducer (LabelStoreEmpty, initialLabelStoreRegs) [parsedEvent] of
        Left _ -> False
        Right (vertex, registers) ->
          vertex == LabelStoreStored
            && registers ! #current == TextLabels (Set.fromList ["a", "b"])
  where
    emptyLabels = TextLabels Set.empty
    sampleEvent = LegacyLabelsImported (LegacyLabelsImportedData emptyLabels (MaybeTextLabels Nothing) sampleEnvelope)
    rawEvent = replaceObjectField "labels" (Aeson.toJSON (["b", "a", "a"] :: [Text])) (encodeLabelStoreEvent sampleEvent)

headInformationLossRejected :: Bool
headInformationLossRejected =
  isLeft (parseLabelStoreEvent (EventType "LabelsStored") (deleteObjectField "labels" (encodeLabelStoreEvent event)))
  where
    event = LabelsStored (LabelsStoredData (TextLabels (Set.fromList ["a", "b"])) (MaybeTextLabels Nothing) sampleEnvelope)

listMutationRejected :: Bool
listMutationRejected =
  let failures =
        checkNormalizationLaw
          decodeTextList
          encodeDeduplicatedList
          replayTextList
          []
          (Aeson.toJSON (["b", "a", "a"] :: [Text]))
          (Aeson.toJSON (["a", "b"] :: [Text]))
          []
   in DomainRoundTripFailed `elem` failures
        && NormalizedReplayDiverged `elem` failures
  where
    decodeTextList :: Value -> Either Text [Text]
    decodeTextList = firstText . parseEither parseJSON
    encodeDeduplicatedList :: [Text] -> Value
    encodeDeduplicatedList = Aeson.toJSON . Set.toAscList . Set.fromList
    replayTextList :: [Value] -> Either Text [Text]
    replayTextList values = case traverse decodeTextList values of
      Left problem -> Left problem
      Right [] -> Left "empty mutation trace"
      Right decoded -> Right (last decoded)

strictDuplicateReaderRejected :: Bool
strictDuplicateReaderRejected =
  case
      classifyObservation
        ( DecodeObservation
            "duplicate-text-set.json"
            (Aeson.toJSON (["b", "a", "a"] :: [Text]))
            (DecodedShape (Aeson.toJSON (["a", "b"] :: [Text])))
            (DecodeFailed "candidate reader rejected a duplicate accepted by v1")
        )
    of
    Right (RequiresVersionWork _) -> True
    _ -> False

historicalCodecParity :: Bool
historicalCodecParity =
  all
    ( \(label, value) ->
        classifyObservation (EncodeObservation label (historicalTextLabelsCodec.encode value) (encodeTextLabelsMapped value)) == Right JsonParity
    )
    (NonEmpty.toList (Keiro.Codec.Structural.fixtureCases textLabelsFixtures))
    && historicalTextLabelsCodec.decode (Aeson.toJSON (["b", "a", "a"] :: [Text]))
      == Right (TextLabels (Set.fromList ["a", "b"]))

invalidElementRejected :: Bool
invalidElementRejected =
  case decodeTextLabelsMapped (Aeson.toJSON ([String "a", Number 1] :: [Value])) of
    Left problem -> "[1]" `T.isInfixOf` problem
    Right _ -> False

-- | Plan 295 found both spellings of absence in retained history -- omitted keys
-- and explicit nulls -- which historical Aeson decoding had always read as
-- 'Nothing'. A root 'Optional' mapped set field must therefore accept an omitted
-- key and decode it exactly as an explicit null.
rootOptionalAbsenceEquivalence :: Bool
rootOptionalAbsenceEquivalence =
  parseLabelStoreEvent kind (deleteObjectField "optionalLabels" encoded) == Right event
    && parseLabelStoreEvent kind (replaceObjectField "optionalLabels" Null encoded) == Right event
  where
    event = LabelsStored (LabelsStoredData labels (MaybeTextLabels Nothing) sampleEnvelope)
    kind = eventType labelStoreCodec event
    encoded = encodeLabelStoreEvent event
    labels = TextLabels (Set.fromList ["a", "b"])

-- | The equivalence above is scoped to root 'Optional' mapped fields. A
-- non-optional mapped root carries no absent spelling, so omitting it stays a
-- decode failure rather than defaulting.
nonOptionalRootStrict :: Bool
nonOptionalRootStrict =
  isLeft (parseLabelStoreEvent kind (deleteObjectField "labels" encoded))
    && isLeft (parseLabelStoreEvent kind (deleteObjectField "envelope" encoded))
  where
    event = LabelsStored (LabelsStoredData labels (MaybeTextLabels Nothing) sampleEnvelope)
    kind = eventType labelStoreCodec event
    encoded = encodeLabelStoreEvent event
    labels = TextLabels (Set.fromList ["a", "b"])

nestedRoundTrip :: Bool
nestedRoundTrip = decodeLabelEnvelopeMapped (encodeLabelEnvelopeMapped sampleEnvelope) == Right sampleEnvelope

queueRoundTrip :: Bool
queueRoundTrip = parseLabelJob (encodeLabelJob payload) == Right payload
  where
    payload = LabelJob (TextLabels (Set.fromList ["a", "b"])) (MaybeTextLabels Nothing) sampleEnvelope

queryAgreement :: Bool
queryAgreement =
  queryInputIdentity (MaybeTextLabels (Just (Set.fromList ["a", "b"]))) == MaybeTextLabels (Just (Set.fromList ["a", "b"]))
    && queryResultIdentity sampleEnvelope == sampleEnvelope

queryInputIdentity :: LabelLookupQueryInput -> MaybeTextLabels
queryInputIdentity = id

queryResultIdentity :: LabelLookupQueryResult -> LabelEnvelope
queryResultIdentity = id

-- Workflows remain application-owned. This explicit example demonstrates the
-- required codec property without implying that the DSL owns workflow journals.
workflowCodecRoundTrip :: Bool
workflowCodecRoundTrip =
  parseEither parseJSON (Aeson.toJSON value) == Right value
    && parseEither parseJSON (Aeson.toJSON (["b", "a", "a"] :: [Text])) == Right value
  where
    value = TextLabels (Set.fromList ["a", "b"])

sampleEnvelope :: LabelEnvelope
sampleEnvelope =
  LabelEnvelope
    (Set.fromList ["b", "a"])
    (Just (Set.fromList ["z", "y"]))
    (MaybeTextLabels (Just (Set.fromList ["named", "optional"])))
    [Set.fromList ["second", "first"], Set.empty]
    (Map.fromList [("unicode", Set.fromList ["\x10000", "\xE000", "a\x0308", "ä"])])

firstText :: (Show problem) => Either problem value -> Either Text value
firstText = either (Left . T.pack . show) Right

deleteObjectField :: Key.Key -> Value -> Value
deleteObjectField key (Object value) = Object (KeyMap.delete key value)
deleteObjectField _ value = value

replaceObjectField :: Key.Key -> Value -> Value -> Value
replaceObjectField key inserted (Object value) = Object (KeyMap.insert key inserted value)
replaceObjectField _ _ value = value
