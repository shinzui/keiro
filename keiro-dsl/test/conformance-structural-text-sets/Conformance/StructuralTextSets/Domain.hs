{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Conformance.StructuralTextSets.Domain where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Proxy (Proxy)
import Data.Set (Set)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

newtype TextLabels = TextLabels {unTextLabels :: Set Text}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName TextLabels where
  canonicalTypeName :: Proxy TextLabels -> Text
  canonicalTypeName _ = "conformance.structural-text-sets.TextLabels.v1"

newtype MaybeTextLabels = MaybeTextLabels {unMaybeTextLabels :: Maybe (Set Text)}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName MaybeTextLabels where
  canonicalTypeName :: Proxy MaybeTextLabels -> Text
  canonicalTypeName _ = "conformance.structural-text-sets.MaybeTextLabels.v1"

data LabelEnvelope = LabelEnvelope
  { primary :: !(Set Text),
    optionalLabels :: !(Maybe (Set Text)),
    namedOptional :: !MaybeTextLabels,
    sequence :: ![Set Text],
    labelled :: !(Map Text (Set Text))
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName LabelEnvelope where
  canonicalTypeName :: Proxy LabelEnvelope -> Text
  canonicalTypeName _ = "conformance.structural-text-sets.LabelEnvelope.v1"
