{-# LANGUAGE DeriveAnyClass #-}
module Conformance.MappedStructuralEnumEquality.Domain where

import Data.Aeson (ToJSON (..), FromJSON (..), Value (..), withText)
import Control.DeepSeq (NFData)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

data RequiredScope = PipelineScope | DiagnosticScope
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

newtype Request = Request { requiredScope :: RequiredScope }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance ToJSON RequiredScope where
  toJSON PipelineScope = String "pipeline"
  toJSON DiagnosticScope = String "diagnostic"
instance FromJSON RequiredScope where
  parseJSON = withText "RequiredScope" $ \case
    "pipeline" -> pure PipelineScope
    "diagnostic" -> pure DiagnosticScope
    _ -> fail "unknown scope"

instance CanonicalTypeName RequiredScope where
  canonicalTypeName _ = "conformance.RequiredScope.v1"
instance CanonicalTypeName Request where
  canonicalTypeName _ = "conformance.Request.v1"
