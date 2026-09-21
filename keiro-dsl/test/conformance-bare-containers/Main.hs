module Main (main) where

import Conformance.BareContainers.Domain
import Conformance.BareContainers.Historical (historicalMaybeTextCodec)
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Generated.BareContainers.BareJobs.Queue (BareJob (..), encodeBareJob, parseBareJob)
import Generated.BareContainers.BareLookup.QueryContract (BareLookupQueryInput, BareLookupQueryResult)
import Generated.BareContainers.BareStore.Codec
import Generated.BareContainers.BareStore.Domain
import Generated.BareContainers.BareStore.Harness (harnessAssertions)
import Generated.BareContainers.Structural.CodecCompare.MaybeText (compareWithHistorical)
import Generated.BareContainers.StructuralConformance (structuralConformanceAssertions)
import Keiro.Codec (eventType)
import Keiro.Dsl.CodecCompare (reportSucceeded)
import System.Exit (exitFailure)

main :: IO ()
main = do
  comparison <-
    compareWithHistorical
      historicalMaybeTextCodec
      "test/conformance-bare-containers/fixtures/codec-compare"
  let assertions =
        [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
          <> harnessAssertions
          <> [ ("bare optional encodes null and a present text directly", maybeTextWire),
               ("bare list preserves order and duplicates", textListWire),
               ("bare text map encodes as an object", textMapWire),
               ("missing optional alias fields apply their declared defaults", missingAliasDefaults),
               ("root optional mapped event fields treat omission and null alike", rootOptionalAbsenceEquivalence),
               ("non-optional mapped event fields still reject omission", nonOptionalRootStrict),
               ("queue payloads preserve bare aliases", queueRoundTrip),
               ("query aliases preserve bare domain types", queryAliasAgreement),
               ("historical opaque MaybeText codec has parity with the generated codec", reportSucceeded comparison)
             ]
  forM_ assertions $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd assertions) exitFailure

maybeTextWire :: Bool
maybeTextWire =
  encodeMaybeTextMapped (MaybeText Nothing) == Null
    && encodeMaybeTextMapped (MaybeText (Just "x")) == String "x"
    && decodeMaybeTextMapped Null == Right (MaybeText Nothing)
    && decodeMaybeTextMapped (String "x") == Right (MaybeText (Just "x"))

textListWire :: Bool
textListWire =
  encodeTextListMapped value == Aeson.toJSON (["b", "a", "a"] :: [Text])
    && decodeTextListMapped (encodeTextListMapped value) == Right value
  where
    value = TextList ["b", "a", "a"]

textMapWire :: Bool
textMapWire =
  encodeTextMapMapped value == object ["alpha" .= String "one", "beta" .= String "two"]
    && decodeTextMapMapped (encodeTextMapMapped value) == Right value
  where
    value = TextMap (Map.fromList [("alpha", "one"), ("beta", "two")])

missingAliasDefaults :: Bool
missingAliasDefaults =
  decodeBareEnvelopeMapped withoutDefaults
    == Right (BareEnvelope (MaybeText Nothing) (TextList []) (TextMap Map.empty) (NestedIds []))
  where
    withoutDefaults = object ["nestedIds" .= ([] :: [Value])]

-- | Plan 295 found both spellings of absence in retained history -- 28 omitted
-- keys and 39 explicit nulls -- which historical Aeson decoding had always read
-- as 'Nothing'. A root 'Optional' mapped event field must therefore accept an
-- omitted key and decode it exactly as an explicit null.
rootOptionalAbsenceEquivalence :: Bool
rootOptionalAbsenceEquivalence =
  parseBareStoreEvent kind (deleteObjectField "optionalLabel" encoded) == Right event
    && parseBareStoreEvent kind (insertObjectField "optionalLabel" Null encoded) == Right event
  where
    event =
      StoredValue
        ( StoredValueData
            (MaybeText Nothing)
            (TextList ["b", "a", "a"])
            (TextMap Map.empty)
            (BareEnvelope (MaybeText Nothing) (TextList []) (TextMap Map.empty) (NestedIds []))
        )
    kind = eventType bareStoreCodec event
    encoded = encodeBareStoreEvent event

-- | The equivalence above is scoped to root 'Optional' mapped fields. A
-- non-optional mapped root carries no absent spelling, so omitting it stays a
-- decode failure rather than defaulting.
nonOptionalRootStrict :: Bool
nonOptionalRootStrict =
  isLeft (parseBareStoreEvent kind (deleteObjectField "labels" encoded))
    && isLeft (parseBareStoreEvent kind (deleteObjectField "attributes" encoded))
  where
    event =
      StoredValue
        ( StoredValueData
            (MaybeText Nothing)
            (TextList ["b", "a", "a"])
            (TextMap Map.empty)
            (BareEnvelope (MaybeText Nothing) (TextList []) (TextMap Map.empty) (NestedIds []))
        )
    kind = eventType bareStoreCodec event
    encoded = encodeBareStoreEvent event

queueRoundTrip :: Bool
queueRoundTrip = parseBareJob (encodeBareJob payload) == Right payload
  where
    payload = BareJob (MaybeText Nothing) (TextList ["b", "a", "a"])

queryAliasAgreement :: Bool
queryAliasAgreement =
  queryInputIdentity (MaybeText (Just "query")) == MaybeText (Just "query")
    && queryResultIdentity [TextList ["b", "a", "a"]] == [TextList ["b", "a", "a"]]

queryInputIdentity :: BareLookupQueryInput -> MaybeText
queryInputIdentity = id

queryResultIdentity :: BareLookupQueryResult -> [TextList]
queryResultIdentity = id

deleteObjectField :: Key.Key -> Value -> Value
deleteObjectField key (Object value) = Object (KeyMap.delete key value)
deleteObjectField _ value = value

insertObjectField :: Key.Key -> Value -> Value -> Value
insertObjectField key inserted (Object value) = Object (KeyMap.insert key inserted value)
insertObjectField _ _ value = value
