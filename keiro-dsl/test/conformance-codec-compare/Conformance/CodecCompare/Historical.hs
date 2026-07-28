{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Conformance.CodecCompare.Historical (
    historicalArtifactInfoCodec,
)
where

import Conformance.Structural.Domain qualified as Domain
import Data.Aeson (Value (..), object, withObject, withText, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.CodecCompare (HistoricalCodec (..))

historicalArtifactInfoCodec :: HistoricalCodec Domain.ArtifactInfo
historicalArtifactInfoCodec =
    HistoricalCodec
        { hcIdentity = "conformance.structural.ArtifactInfo.aeson"
        , hcVersion = "legacy-v3"
        , hcEncode = encodeArtifactInfo
        , hcDecode = either (Left . T.pack) Right . parseEither parseArtifactInfo
        }

encodeArtifactInfo :: Domain.ArtifactInfo -> Value
encodeArtifactInfo value =
    object
        ( [ "artifact_key" .= value.artifactKey
          , "display_name" .= value.displayName
          , "artifact_kind" .= encodeArtifactKind value.artifactKind
          , "location" .= encodeLocation value.location
          , "metadata" .= object ["note" .= value.metadata.note]
          , "active" .= value.active
          , "tags" .= value.tags
          ]
            <> maybe [] (pure . ("artifact_hash" .=)) value.artifactHash
        )

encodeArtifactKind :: Domain.ArtifactKind -> Value
encodeArtifactKind Domain.Guide = String "guide"
encodeArtifactKind Domain.Reference = String "reference"

encodeLocation :: Domain.ArtifactLocation -> Value
encodeLocation location = case location of
    Domain.LocalFile payload -> tagged "local_file" (Just payload)
    Domain.LocalDir payload -> tagged "local_dir" (Just payload)
    Domain.RepoPath payload -> tagged "repo_path" (Just payload)
    Domain.LocUrl payload -> tagged "url" (Just payload)
    Domain.Canonical -> tagged "Canonical" Nothing
  where
    tagged :: Text -> Maybe Text -> Value
    tagged tag payload = object (["tag" .= tag] <> maybe [] (pure . ("contents" .=)) payload)

parseArtifactInfo :: Value -> Parser Domain.ArtifactInfo
parseArtifactInfo = withObject "historical ArtifactInfo" $ \value ->
    Domain.ArtifactInfo
        <$> value .: "artifact_key"
        <*> value .: "display_name"
        <*> value .:? "artifact_hash"
        <*> (value .:? "artifact_kind" >>= maybe (pure Domain.Guide) parseArtifactKind)
        <*> (value .: "location" >>= parseLocation)
        <*> (value .: "metadata" >>= parseMetadata)
        <*> value .:? "active" .!= False
        <*> value .:? "tags" .!= []

parseArtifactKind :: Value -> Parser Domain.ArtifactKind
parseArtifactKind = withText "historical ArtifactKind" $ \value -> case value of
    "guide" -> pure Domain.Guide
    "reference" -> pure Domain.Reference
    _ -> fail "unknown historical artifact kind"

parseLocation :: Value -> Parser Domain.ArtifactLocation
parseLocation = withObject "historical ArtifactLocation" $ \value -> do
    tag <- value .: "tag" :: Parser Text
    case tag of
        "local_file" -> Domain.LocalFile <$> value .: "contents"
        "local_dir" -> Domain.LocalDir <$> value .: "contents"
        "repo_path" -> Domain.RepoPath <$> value .: "contents"
        "url" -> Domain.LocUrl <$> value .: "contents"
        "Canonical" -> pure Domain.Canonical
        _ -> fail "unknown historical artifact location"

parseMetadata :: Value -> Parser Domain.ArtifactMetadata
parseMetadata = withObject "historical ArtifactMetadata" $ \value ->
    Domain.ArtifactMetadata <$> value .:? "note"
