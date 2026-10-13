{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Conformance.HistoryDependentHoles.Domain (PropertyValues (..)) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.Generics (Generic)

newtype PropertyValues = PropertyValues (Map Text Text)
  deriving stock (Eq, Show, Generic)
  deriving newtype (FromJSON, ToJSON)
