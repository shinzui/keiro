{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Conformance.StructuralNominals.Domain where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.KindID (KindID)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Generated.StructuralNominalLeaves.Nominals (TemplateId, TemplateKind)
import Keiki.Shape (CanonicalTypeName (..))

newtype ClaimId = ClaimId {unClaimId :: KindID "claim"}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance Ord ClaimId where
  compare (ClaimId left) (ClaimId right) = compare left right

unClaimId :: ClaimId -> KindID "claim"
unClaimId (ClaimId value) = value

instance CanonicalTypeName ClaimId where
  canonicalTypeName :: Proxy ClaimId -> Text
  canonicalTypeName _ = "conformance.structural-nominals.ClaimId.v1"

newtype AccountNumber = AccountNumber {unAccountNumber :: Text}
  deriving stock (Eq, Generic, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

unAccountNumber :: AccountNumber -> Text
unAccountNumber (AccountNumber value) = value

instance CanonicalTypeName AccountNumber where
  canonicalTypeName :: Proxy AccountNumber -> Text
  canonicalTypeName _ = "conformance.structural-nominals.AccountNumber.v1"

data Channel = EmailChannel | SmsChannel
  deriving stock (Eq, Generic, Ord, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName Channel where
  canonicalTypeName :: Proxy Channel -> Text
  canonicalTypeName _ = "conformance.structural-nominals.Channel.v1"

data TemplateState = TemplateState
  { templateId :: !TemplateId,
    holder :: !(Maybe ClaimId),
    account :: !AccountNumber,
    channel :: !Channel,
    kind :: !TemplateKind,
    fallbackChannel :: !Channel
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName TemplateState where
  canonicalTypeName :: Proxy TemplateState -> Text
  canonicalTypeName _ = "conformance.structural-nominals.TemplateState.v1"

data TemplateRef
  = ById !TemplateId
  | ByAccount !AccountNumber
  | ByChannel !Channel
  | Unknown
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName TemplateRef where
  canonicalTypeName :: Proxy TemplateRef -> Text
  canonicalTypeName _ = "conformance.structural-nominals.TemplateRef.v1"

data TemplateBook = TemplateBook
  { templates :: ![TemplateState],
    holders :: ![Maybe ClaimId],
    byKey :: !(Map Text TemplateId),
    byTemplate :: !(Map Text Text),
    claims :: !(Map ClaimId TemplateState)
  }
  deriving stock (Eq, Generic, Show)

instance ToJSON TemplateBook where
  toJSON (TemplateBook templates holders byKey byTemplate claims) =
    object
      [ "templates" .= templates,
        "holders" .= holders,
        "byKey" .= byKey,
        "byTemplate" .= byTemplate,
        "claims" .= Map.toList claims
      ]

instance FromJSON TemplateBook where
  parseJSON = withObject "TemplateBook" $ \value ->
    TemplateBook
      <$> value .: "templates"
      <*> value .: "holders"
      <*> value .: "byKey"
      <*> value .: "byTemplate"
      <*> (Map.fromList <$> value .: "claims")

instance CanonicalTypeName TemplateBook where
  canonicalTypeName :: Proxy TemplateBook -> Text
  canonicalTypeName _ = "conformance.structural-nominals.TemplateBook.v1"

newtype TemplateLookupInput = TemplateLookupInput
  { lookupClaimId :: ClaimId
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName TemplateLookupInput where
  canonicalTypeName :: Proxy TemplateLookupInput -> Text
  canonicalTypeName _ = "conformance.structural-nominals.TemplateLookupInput.v1"

data TemplateLookupRow = TemplateLookupRow
  { lookupTemplateId :: !TemplateId,
    rowClaimId :: !ClaimId
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName TemplateLookupRow where
  canonicalTypeName :: Proxy TemplateLookupRow -> Text
  canonicalTypeName _ = "conformance.structural-nominals.TemplateLookupRow.v1"
