{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module ImportPlanning.Consumer.Domain (CollisionLedgerCommand (..)) where

import Data.Text (Text)
import Keiki.Shape (CanonicalTypeName (..))

newtype CollisionLedgerCommand = CollisionLedgerCommand Text
  deriving stock (Eq, Ord, Show)

instance CanonicalTypeName CollisionLedgerCommand where
  canonicalTypeName _ = "import-planning.LocalCollision.v1"
