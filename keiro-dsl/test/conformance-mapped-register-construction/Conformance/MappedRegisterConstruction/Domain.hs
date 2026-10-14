{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Conformance.MappedRegisterConstruction.Domain (MaybeTime (..)) where

import Control.DeepSeq (NFData)
import Data.Aeson (FromJSON, ToJSON)
import Data.Proxy (Proxy)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

newtype MaybeTime = MaybeTime {timestamp :: Maybe UTCTime}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, NFData)

instance CanonicalTypeName MaybeTime where
  canonicalTypeName :: Proxy MaybeTime -> Text
  canonicalTypeName _ = "conformance.MaybeTime.v1"
