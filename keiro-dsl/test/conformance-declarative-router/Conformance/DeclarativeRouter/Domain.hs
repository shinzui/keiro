{-# LANGUAGE DuplicateRecordFields #-}

module Conformance.DeclarativeRouter.Domain
  ( TransferRouteInput (..),
    HospitalLoadRow (..),
  )
where

import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

data TransferRouteInput = TransferRouteInput
  { transferNeedId :: !Text,
    region :: !Text
  }
  deriving stock (Eq, Show, Generic)

data HospitalLoadRow = HospitalLoadRow
  { hospitalId :: !Text,
    region :: !Text,
    availableBeds :: !Int
  }
  deriving stock (Eq, Show, Generic)

instance CanonicalTypeName TransferRouteInput where
  canonicalTypeName :: Proxy TransferRouteInput -> Text
  canonicalTypeName _ = "conformance.declarative-router.TransferRouteInput.v1"

instance CanonicalTypeName HospitalLoadRow where
  canonicalTypeName :: Proxy HospitalLoadRow -> Text
  canonicalTypeName _ = "conformance.declarative-router.HospitalLoadRow.v1"
