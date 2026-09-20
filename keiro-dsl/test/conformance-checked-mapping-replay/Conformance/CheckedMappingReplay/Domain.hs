{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Conformance.CheckedMappingReplay.Domain where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time.Calendar (Day)
import GHC.Generics (Generic)
import Generated.CheckedMappingReplay.Nominals (RetainedId, parseRetainedId, retainedIdText)
import Keiki.Shape (CanonicalTypeName (..))
import Keiro.Codec.Refined (encodeBase16Bytes, parseBase16Bytes)

newtype MaybeLabel = MaybeLabel {unMaybeLabel :: Maybe Text}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName MaybeLabel where
  canonicalTypeName :: Proxy MaybeLabel -> Text
  canonicalTypeName _ = "conformance.checked-mapping-replay.MaybeLabel.v1"

newtype ImportantDays = ImportantDays {unImportantDays :: [Day]}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName ImportantDays where
  canonicalTypeName :: Proxy ImportantDays -> Text
  canonicalTypeName _ = "conformance.checked-mapping-replay.ImportantDays.v1"

newtype TextLabels = TextLabels {unTextLabels :: Set Text}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName TextLabels where
  canonicalTypeName :: Proxy TextLabels -> Text
  canonicalTypeName _ = "conformance.checked-mapping-replay.TextLabels.v1"

newtype ContentHash = ContentHash {unContentHash :: ByteString}
  deriving stock (Eq, Generic, Show)

instance ToJSON ContentHash where
  toJSON (ContentHash bytes) = encodeBase16Bytes bytes

instance FromJSON ContentHash where
  parseJSON value = ContentHash <$> parseBase16Bytes value

instance CanonicalTypeName ContentHash where
  canonicalTypeName :: Proxy ContentHash -> Text
  canonicalTypeName _ = "conformance.checked-mapping-replay.ContentHash.v1"

newtype MaybeContentHash = MaybeContentHash {unMaybeContentHash :: Maybe ContentHash}
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName MaybeContentHash where
  canonicalTypeName :: Proxy MaybeContentHash -> Text
  canonicalTypeName _ = "conformance.checked-mapping-replay.MaybeContentHash.v1"

data ReplayEnvelope = ReplayEnvelope
  { label :: !MaybeLabel,
    days :: !ImportantDays,
    labels :: !TextLabels,
    contentHash :: !MaybeContentHash,
    primary :: !RetainedId,
    identities :: !(Map RetainedId Text),
    optionalLabels :: !(Maybe (Set Text))
  }
  deriving stock (Eq, Generic, Show)

instance ToJSON ReplayEnvelope where
  toJSON (ReplayEnvelope labelValue daysValue labelsValue contentHashValue primaryValue identitiesValue optionalLabelsValue) =
    object
      [ "label" .= labelValue,
        "days" .= daysValue,
        "labels" .= labelsValue,
        "contentHash" .= contentHashValue,
        "primary" .= retainedIdText primaryValue,
        "identities" .= Object (KeyMap.fromList [(Key.fromText (retainedIdText key), toJSON value) | (key, value) <- Map.toList identitiesValue]),
        "optionalLabels" .= optionalLabelsValue
      ]

instance FromJSON ReplayEnvelope where
  parseJSON = withObject "ReplayEnvelope" $ \value ->
    ReplayEnvelope
      <$> value .: "label"
      <*> value .: "days"
      <*> value .: "labels"
      <*> value .: "contentHash"
      <*> (value .: "primary" >>= either (fail . show) pure . parseRetainedId)
      <*> (value .: "identities" >>= parseIdentityMap)
      <*> value .: "optionalLabels"

parseIdentityMap :: Value -> Parser (Map RetainedId Text)
parseIdentityMap = withObject "Map RetainedId Text" $ \value ->
  Map.fromList <$> traverse parseEntry (KeyMap.toList value)
  where
    parseEntry (rawKey, rawValue) = do
      key <- either (fail . show) pure (parseRetainedId (Key.toText rawKey))
      item <- parseJSON rawValue
      pure (key, item)

instance CanonicalTypeName ReplayEnvelope where
  canonicalTypeName :: Proxy ReplayEnvelope -> Text
  canonicalTypeName _ = "conformance.checked-mapping-replay.ReplayEnvelope.v1"
