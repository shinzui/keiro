{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Conformance.ContractListFields.Domain where

import Data.KindID (KindID)
import Data.Proxy (Proxy)
import Data.Text (Text)
import Keiki.Shape (CanonicalTypeName (..))

newtype ClaimId = ClaimId (KindID "claim")
  deriving newtype (Eq, Ord, Show)

unClaimId :: ClaimId -> KindID "claim"
unClaimId (ClaimId value) = value

instance CanonicalTypeName ClaimId where
  canonicalTypeName :: Proxy ClaimId -> Text
  canonicalTypeName _ = "conformance.contract-list-fields.ClaimId.v1"
