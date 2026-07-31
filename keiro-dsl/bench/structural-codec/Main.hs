{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Conformance.Structural.Bindings qualified as Bindings
import Conformance.Structural.Domain qualified as Domain
import Control.DeepSeq (NFData)
import Control.Monad (unless, (>=>))
import Data.Aeson (Value (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Generated.StructuralConformance.ArtifactCatalog.Codec (decodeArtifactInfoMapped, encodeArtifactInfoMapped)
import Keiro.Codec.Structural (FixtureCases (..))
import Test.Tasty.Bench (Benchmark, bcompareWithin, bench, bgroup, defaultMain, nf)

main :: IO ()
main = defaultMain benchmarks

benchmarks :: [Benchmark]
benchmarks =
  [ bgroup
      "encode"
      [ comparison "encode-small-record" baselineEncodeArtifact encodeArtifactInfoMapped smallArtifact,
        comparison "encode-nested-union" (map baselineEncodeArtifact) (map encodeArtifactInfoMapped) unionArtifacts,
        comparison "encode-large-list" (map baselineEncodeArtifact) (map encodeArtifactInfoMapped) largeArtifacts
      ],
    bgroup
      "decode"
      [ comparison "decode-small-record" baselineDecodeArtifact decodeArtifactInfoMapped smallEncoded,
        comparison "decode-nested-union" baselineDecodeArtifacts generatedDecodeArtifacts unionEncoded,
        comparison "decode-large-list" baselineDecodeArtifacts generatedDecodeArtifacts largeEncoded
      ]
  ]

comparison :: (NFData result) => String -> (input -> result) -> (input -> result) -> input -> Benchmark
comparison label baseline generated input =
  bgroup
    label
    [ bench ("baseline-" <> label) (nf baseline input),
      bcompareWithin 0 2 ("baseline-" <> label) $ bench ("generated-" <> label) (nf generated input)
    ]

allArtifacts :: [Domain.ArtifactInfo]
allArtifacts = map snd (NonEmpty.toList (fixtureCases Bindings.artifactInfoCases))

smallArtifact :: Domain.ArtifactInfo
smallArtifact = snd (NonEmpty.head (fixtureCases Bindings.artifactInfoCases))

unionArtifacts :: [Domain.ArtifactInfo]
unionArtifacts = allArtifacts

largeArtifacts :: [Domain.ArtifactInfo]
largeArtifacts = take 2000 (cycle allArtifacts)

smallEncoded :: Value
smallEncoded = encodeArtifactInfoMapped smallArtifact

unionEncoded :: Value
unionEncoded = Aeson.toJSON (map encodeArtifactInfoMapped unionArtifacts)

largeEncoded :: Value
largeEncoded = Aeson.toJSON (map encodeArtifactInfoMapped largeArtifacts)

generatedDecodeArtifacts :: Value -> Either Text [Domain.ArtifactInfo]
generatedDecodeArtifacts value = do
  values <- firstText (parseEither Aeson.parseJSON value)
  traverse decodeArtifactInfoMapped values

baselineDecodeArtifacts :: Value -> Either Text [Domain.ArtifactInfo]
baselineDecodeArtifacts = firstText . parseEither (Aeson.parseJSON >=> traverse baselineParseArtifact)

baselineDecodeArtifact :: Value -> Either Text Domain.ArtifactInfo
baselineDecodeArtifact = firstText . parseEither baselineParseArtifact

firstText :: Either String value -> Either Text value
firstText = either (Left . Text.pack) Right

baselineEncodeArtifact :: Domain.ArtifactInfo -> Value
baselineEncodeArtifact value =
  object
    [ "artifact_key" .= value.artifactKey,
      "display_name" .= value.displayName,
      "artifact_hash" .= value.artifactHash,
      "artifact_kind" .= encodeKind value.artifactKind,
      "location" .= encodeLocation value.location,
      "metadata" .= object ["note" .= value.metadata.note],
      "active" .= value.active,
      "tags" .= value.tags
    ]

baselineParseArtifact :: Value -> Parser Domain.ArtifactInfo
baselineParseArtifact = withObject "ArtifactInfo" $ \value -> do
  rejectUnknownFields "ArtifactInfo" ["artifact_key", "display_name", "artifact_hash", "artifact_kind", "location", "metadata", "active", "tags"] value
  Domain.ArtifactInfo
    <$> value .: "artifact_key"
    <*> value .: "display_name"
    <*> value .:? "artifact_hash"
    <*> (value .:? "artifact_kind" .!= String "guide" >>= parseKind)
    <*> (value .: "location" >>= parseLocation)
    <*> (value .: "metadata" >>= withObject "ArtifactMetadata" (\metadata -> Domain.ArtifactMetadata <$> metadata .: "note"))
    <*> (value .:? "active" .!= False)
    <*> (value .:? "tags" .!= [])

encodeKind :: Domain.ArtifactKind -> Value
encodeKind = \case
  Domain.Guide -> String "guide"
  Domain.Reference -> String "reference"

parseKind :: Value -> Parser Domain.ArtifactKind
parseKind = \case
  String "guide" -> pure Domain.Guide
  String "reference" -> pure Domain.Reference
  _ -> fail "unknown ArtifactKind"

encodeLocation :: Domain.ArtifactLocation -> Value
encodeLocation = \case
  Domain.LocalFile path -> tagged "local_file" (Just path)
  Domain.LocalDir path -> tagged "local_dir" (Just path)
  Domain.RepoPath path -> tagged "repo_path" (Just path)
  Domain.LocUrl url -> tagged "url" (Just url)
  Domain.Canonical -> tagged "canonical" Nothing
  where
    tagged :: Text -> Maybe Text -> Value
    tagged tag contents = object (["tag" .= tag] <> maybe [] (pure . ("contents" .=)) contents)

parseLocation :: Value -> Parser Domain.ArtifactLocation
parseLocation = withObject "ArtifactLocation" $ \value -> do
  tag <- value .: "tag" :: Parser Text
  case tag of
    "local_file" -> rejectUnknownFields "ArtifactLocation" ["tag", "contents"] value >> (Domain.LocalFile <$> value .: "contents")
    "local_dir" -> rejectUnknownFields "ArtifactLocation" ["tag", "contents"] value >> (Domain.LocalDir <$> value .: "contents")
    "repo_path" -> rejectUnknownFields "ArtifactLocation" ["tag", "contents"] value >> (Domain.RepoPath <$> value .: "contents")
    "url" -> rejectUnknownFields "ArtifactLocation" ["tag", "contents"] value >> (Domain.LocUrl <$> value .: "contents")
    "canonical" -> rejectUnknownFields "ArtifactLocation" ["tag"] value >> pure Domain.Canonical
    _ -> fail "unknown ArtifactLocation"

rejectUnknownFields :: String -> [Text] -> KeyMap.KeyMap Value -> Parser ()
rejectUnknownFields label allowed value =
  unless (null extras) (fail (label <> " contains unknown fields: " <> show extras))
  where
    extras = filter (`notElem` allowed) (map Key.toText (KeyMap.keys value))
