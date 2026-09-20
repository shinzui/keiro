{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Conformance.RefinedBase16.Domain where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))
import Keiro.Codec.Refined (encodeBase16Bytes, parseBase16Bytes)

newtype ContentHash = ContentHash {unContentHash :: ByteString}
  deriving stock (Eq, Generic, Show)

instance ToJSON ContentHash where
  toJSON (ContentHash bytes) = encodeBase16Bytes bytes

instance FromJSON ContentHash where
  parseJSON value = ContentHash <$> parseBase16Bytes value

instance CanonicalTypeName ContentHash where
  canonicalTypeName :: Proxy ContentHash -> Text
  canonicalTypeName _ = "conformance.refined-base16.ContentHash.v1"

newtype MaybeContentHash = MaybeContentHash {unMaybeContentHash :: Maybe ContentHash}
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName MaybeContentHash where
  canonicalTypeName :: Proxy MaybeContentHash -> Text
  canonicalTypeName _ = "conformance.refined-base16.MaybeContentHash.v1"

data HashEnvelope = HashEnvelope
  { primary :: !ContentHash,
    optionalHash :: !(Maybe ContentHash),
    namedOptional :: !MaybeContentHash,
    sequence :: ![ContentHash],
    labelled :: !(Map Text ContentHash)
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName HashEnvelope where
  canonicalTypeName :: Proxy HashEnvelope -> Text
  canonicalTypeName _ = "conformance.refined-base16.HashEnvelope.v1"
