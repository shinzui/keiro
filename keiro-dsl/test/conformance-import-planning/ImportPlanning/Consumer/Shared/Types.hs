{-# LANGUAGE OverloadedStrings #-}

module ImportPlanning.Consumer.Shared.Types (Details (..)) where

import Data.Text (Text)
import Keiki.Shape (CanonicalTypeName (..))

newtype Details = Details Text
  deriving stock (Eq, Ord, Show)

instance CanonicalTypeName Details where
  canonicalTypeName _ = "import-planning.Details.v1"
