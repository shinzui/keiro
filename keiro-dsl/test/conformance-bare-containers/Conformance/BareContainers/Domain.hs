{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Conformance.BareContainers.Domain where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Generated.BareContainers.Nominals (ItemId)
import Keiki.Shape (CanonicalTypeName (..))

newtype MaybeText = MaybeText {unMaybeText :: Maybe Text}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName MaybeText where
  canonicalTypeName :: Proxy MaybeText -> Text
  canonicalTypeName _ = "conformance.bare-containers.MaybeText.v1"

newtype TextList = TextList {unTextList :: [Text]}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName TextList where
  canonicalTypeName :: Proxy TextList -> Text
  canonicalTypeName _ = "conformance.bare-containers.TextList.v1"

newtype TextMap = TextMap {unTextMap :: Map Text Text}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName TextMap where
  canonicalTypeName :: Proxy TextMap -> Text
  canonicalTypeName _ = "conformance.bare-containers.TextMap.v1"

newtype NestedIds = NestedIds {unNestedIds :: [Maybe ItemId]}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName NestedIds where
  canonicalTypeName :: Proxy NestedIds -> Text
  canonicalTypeName _ = "conformance.bare-containers.NestedIds.v1"

data BareEnvelope = BareEnvelope
  { optionalLabel :: !MaybeText,
    labels :: !TextList,
    attributes :: !TextMap,
    nestedIds :: !NestedIds
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName BareEnvelope where
  canonicalTypeName :: Proxy BareEnvelope -> Text
  canonicalTypeName _ = "conformance.bare-containers.BareEnvelope.v1"
