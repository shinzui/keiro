{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Conformance.MappedQueue.Domain
  ( Geometry (..),
    JobMetadata (..),
    JobPayload (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

newtype Geometry = Geometry {geometryText :: Text}
  deriving stock (Eq, Show, Generic)

instance ToJSON Geometry where
  toJSON (Geometry value) = toJSON value

instance FromJSON Geometry where
  parseJSON = withText "Geometry" (pure . Geometry)

data JobMetadata = JobMetadata
  { note :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data JobPayload = JobPayload
  { jobId :: !Text,
    label :: !Text,
    metadata :: !(Maybe JobMetadata),
    geometry :: !Geometry
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName JobMetadata where
  canonicalTypeName :: Proxy JobMetadata -> Text
  canonicalTypeName _ = "conformance.mapped-queue.JobMetadata.v1"

instance CanonicalTypeName JobPayload where
  canonicalTypeName :: Proxy JobPayload -> Text
  canonicalTypeName _ = "conformance.mapped-queue.JobPayload.v1"
