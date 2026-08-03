{-# LANGUAGE OverloadedStrings #-}

module ImportPlanning.Consumer.Invoice.Types (Status (..)) where

import Keiki.Shape (CanonicalTypeName (..))

data Status = InvoiceOpen
  deriving stock (Eq, Ord, Show)

instance CanonicalTypeName Status where
  canonicalTypeName _ = "import-planning.InvoiceStatus.v1"
