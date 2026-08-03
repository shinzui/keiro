{-# LANGUAGE OverloadedStrings #-}

module ImportPlanning.Consumer.Order.Types (Status (..)) where

import Keiki.Shape (CanonicalTypeName (..))

data Status = OrderPending
  deriving stock (Eq, Ord, Show)

instance CanonicalTypeName Status where
  canonicalTypeName _ = "import-planning.OrderStatus.v1"
