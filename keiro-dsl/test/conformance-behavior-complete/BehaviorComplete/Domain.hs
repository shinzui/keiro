{-# LANGUAGE DeriveGeneric #-}

module BehaviorComplete.Domain (StartPayload (..)) where

import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

data StartPayload = StartPayload
  { label :: !Text,
    note :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance CanonicalTypeName StartPayload where
  canonicalTypeName :: Proxy StartPayload -> Text
  canonicalTypeName _ = "behavior-complete.StartPayload.v1"
