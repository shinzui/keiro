module Main (main) where

import Conformance.RefinedBase16.Bindings (contentHashBinding, contentHashFixtures)
import Conformance.RefinedBase16.Domain
import Conformance.RefinedBase16.Historical (historicalContentHashCodec)
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), parseJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Generated.RefinedBase16.HashJobs.Queue (HashJob (..), encodeHashJob, parseHashJob)
import Generated.RefinedBase16.HashLookup.QueryContract (HashLookupQueryInput, HashLookupQueryResult)
import Generated.RefinedBase16.HashStore.Codec
import Generated.RefinedBase16.HashStore.Domain
import Generated.RefinedBase16.HashStore.Harness (harnessAssertions)
import Generated.RefinedBase16.HashStore.Transducer (hashStoreTransducer)
import Generated.RefinedBase16.Structural.CodecCompare.ContentHash (compareWithHistorical)
import Generated.RefinedBase16.StructuralConformance (structuralConformanceAssertions)
import Keiki.Core (applyEventsEither, (!))
import Keiro.Codec (EventType (..), eventType)
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..), bindingDomainRoundTrip, bindingShapeRoundTrip)
import Keiro.Dsl.CodecCompare (CompareObservation (..), FixtureVerdict (..), HistoricalCodec (..), classifyObservation, reportSucceeded)
import Keiro.Test.ReplayCompatibility (checkNormalizationLaw)
import System.Exit (exitFailure)

main :: IO ()
main = do
  comparison <-
    compareWithHistorical
      historicalContentHashCodec
      "test/conformance-refined-base16/fixtures/codec-compare"
  let assertions =
        [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
          <> harnessAssertions
          <> [ ("lowercase output preserves empty and leading-zero bytes", canonicalWire),
               ("mixed-case and uppercase inputs normalize without changing bytes", historicalSpellingsNormalize),
               ("malformed spellings fail before the consumer binding", malformedRejected),
               ("arbitrary byte lengths remain admitted", unrestrictedLengths),
               ("normalization preserves serialized multi-event replay state", normalizationReplayLaw),
               ("replay-only history preserves the decoded hash", replayOnlyNormalization),
               ("a first event that loses the hash is rejected", headInformationLossRejected),
               ("a transposing consumer binding violates both total laws", transposingBindingRejected),
               ("historical repository codec remains byte-compatible", historicalCodecParity),
               ("generated historical codec comparison succeeds", reportSucceeded comparison),
               ("canonicalization preserves content-derived durable identity", durableIdentityStable),
               ("optional, list, and map compositions round-trip", nestedRoundTrip),
               ("queue payloads preserve refined hashes", queueRoundTrip),
               ("query contracts preserve refined domain types", queryAgreement),
               ("application-owned workflow codecs retain the same bytes", workflowCodecRoundTrip)
             ]
  forM_ assertions $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd assertions) exitFailure

canonicalWire :: Bool
canonicalWire =
  encodeContentHashMapped (hash [0, 175]) == String "00af"
    && encodeContentHashMapped (hash []) == String ""

historicalSpellingsNormalize :: Bool
historicalSpellingsNormalize =
  decodeContentHashMapped (String "00aF") == Right (hash [0, 175])
    && decodeContentHashMapped (String "00AF") == Right (hash [0, 175])
    && fmap encodeContentHashMapped (decodeContentHashMapped (String "00AF")) == Right (String "00af")

malformedRejected :: Bool
malformedRejected =
  all (isLeft . decodeContentHashMapped . String) ["0", "0x00", "gg", "00 af", " 00"]
    && isLeft (decodeContentHashMapped Null)

unrestrictedLengths :: Bool
unrestrictedLengths =
  all
    (\value -> decodeContentHashMapped (encodeContentHashMapped value) == Right value)
    [hash [], hash [0], hash [0, 17, 34, 51, 68], hash [0 .. 31], hash [0 .. 32]]

normalizationReplayLaw :: Bool
normalizationReplayLaw =
  null
    ( checkNormalizationLaw
        decodeContentHashMapped
        encodeContentHashMapped
        replayRawHashChain
        []
        (String "00AF")
        (String "00af")
        []
    )

replayRawHashChain :: [Value] -> Either Text (HashStoreVertex, ContentHash)
replayRawHashChain wires = do
  events <- concat <$> traverse rawTransition wires
  (vertex, registers) <- firstText (applyEventsEither hashStoreTransducer (HashStoreEmpty, initialHashStoreRegs) events)
  pure (vertex, registers ! #current)
  where
    rawTransition wire = do
      let value = hash []
          optional = MaybeContentHash Nothing
          envelope = sampleEnvelope
          stored = HashStored (HashStoredData value optional envelope)
          audited = HashAudited (HashAuditedData value optional envelope)
      storedEvent <- parseHashStoreEvent (EventType "HashStored") (replaceObjectField "hash" wire (encodeHashStoreEvent stored))
      auditedEvent <- parseHashStoreEvent (EventType "HashAudited") (replaceObjectField "hash" wire (encodeHashStoreEvent audited))
      pure [storedEvent, auditedEvent]

replayOnlyNormalization :: Bool
replayOnlyNormalization =
  case parseHashStoreEvent (EventType "LegacyHashImported") rawEvent of
    Left _ -> False
    Right parsedEvent ->
      case applyEventsEither hashStoreTransducer (HashStoreEmpty, initialHashStoreRegs) [parsedEvent] of
        Left _ -> False
        Right (vertex, registers) ->
          vertex == HashStoreStored && registers ! #current == hash [0, 175]
  where
    event = LegacyHashImported (LegacyHashImportedData (hash []) (MaybeContentHash Nothing) sampleEnvelope)
    rawEvent = replaceObjectField "hash" (String "00AF") (encodeHashStoreEvent event)

headInformationLossRejected :: Bool
headInformationLossRejected =
  isLeft (parseHashStoreEvent kind (deleteObjectField "hash" encoded))
  where
    event = HashStored (HashStoredData (hash [0, 175]) (MaybeContentHash Nothing) sampleEnvelope)
    kind = eventType hashStoreCodec event
    encoded = encodeHashStoreEvent event

transposingBindingRejected :: Bool
transposingBindingRejected =
  bindingDomainRoundTrip contentHashBinding value
    && bindingShapeRoundTrip contentHashBinding (BS.pack [0, 175])
    && not (bindingDomainRoundTrip brokenBinding value)
    && not (bindingShapeRoundTrip brokenBinding (BS.pack [0, 175]))
  where
    value = hash [0, 175]
    brokenBinding =
      StructuralBinding
        { bindingToShape = \(ContentHash bytes) -> BS.reverse bytes,
          bindingFromShape = ContentHash
        }

historicalCodecParity :: Bool
historicalCodecParity =
  all
    ( \(label, value) ->
        classifyObservation
          (EncodeObservation label (historicalContentHashCodec.encode value) (encodeContentHashMapped value))
          == Right JsonParity
    )
    (NonEmpty.toList (fixtureCases contentHashFixtures))
    && historicalContentHashCodec.decode (String "00AF") == Right (hash [0, 175])

durableIdentityStable :: Bool
durableIdentityStable =
  case historicalContentHashCodec.decode (String "00AF") of
    Left _ -> False
    Right historical ->
      case decodeContentHashMapped (String "00af") of
        Left _ -> False
        Right candidate -> durableIdentity historical == durableIdentity candidate

durableIdentity :: ContentHash -> Word
durableIdentity (ContentHash bytes) = BS.foldl' (\acc byte -> acc * 16777619 + fromIntegral byte) 2166136261 bytes

nestedRoundTrip :: Bool
nestedRoundTrip = decodeHashEnvelopeMapped (encodeHashEnvelopeMapped sampleEnvelope) == Right sampleEnvelope

queueRoundTrip :: Bool
queueRoundTrip = parseHashJob (encodeHashJob payload) == Right payload
  where
    payload = HashJob (hash [0, 175]) (MaybeContentHash Nothing) sampleEnvelope

queryAgreement :: Bool
queryAgreement =
  queryInputIdentity (MaybeContentHash (Just (hash [0, 175]))) == MaybeContentHash (Just (hash [0, 175]))
    && queryResultIdentity sampleEnvelope == sampleEnvelope

queryInputIdentity :: HashLookupQueryInput -> MaybeContentHash
queryInputIdentity = id

queryResultIdentity :: HashLookupQueryResult -> HashEnvelope
queryResultIdentity = id

workflowCodecRoundTrip :: Bool
workflowCodecRoundTrip =
  parseEither parseJSON (Aeson.toJSON value) == Right value
    && parseEither parseJSON (String "00AF") == Right value
  where
    value = hash [0, 175]

sampleEnvelope :: HashEnvelope
sampleEnvelope =
  HashEnvelope
    (hash [0, 175])
    (Just (hash [255]))
    (MaybeContentHash (Just (hash [0, 17, 34, 51, 68])))
    [hash [], hash [1], hash [2, 3, 4]]
    (Map.fromList [("short", hash [0]), ("longer", hash [0 .. 7])])

hash :: [Word] -> ContentHash
hash = ContentHash . BS.pack . map fromIntegral

firstText :: (Show problem) => Either problem value -> Either Text value
firstText = either (Left . T.pack . show) Right

deleteObjectField :: Key.Key -> Value -> Value
deleteObjectField key (Object value) = Object (KeyMap.delete key value)
deleteObjectField _ value = value

replaceObjectField :: Key.Key -> Value -> Value -> Value
replaceObjectField key inserted (Object value) = Object (KeyMap.insert key inserted value)
replaceObjectField _ _ value = value
