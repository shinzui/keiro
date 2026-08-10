{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module CatalogDemo.MappedDomain
  ( OrderPayload (..),
    QualificationPayload (..),
    QualificationResult (..),
    QueryCriteria (..),
    QueueMetadata (..),
    RegisterState (..),
    SharedReference (..),
    UnusedQualification (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Proxy (Proxy)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

newtype OrderPayload = OrderPayload {orderPayloadText :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype SharedReference = SharedReference {sharedReferenceText :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data QualificationPayload = QualificationPayload
  { qualificationId :: !Text,
    note :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype QueueMetadata = QueueMetadata {queueMetadataText :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype QueryCriteria = QueryCriteria {queryCriteriaText :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype QualificationResult = QualificationResult {qualificationResultText :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype RegisterState = RegisterState {registerStateText :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype UnusedQualification = UnusedQualification {unusedQualificationText :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName QualificationPayload where
  canonicalTypeName :: Proxy QualificationPayload -> Text
  canonicalTypeName _ = "catalog-demo.QualificationPayload.v1"
