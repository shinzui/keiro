{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

module Conformance.IdAdmissionDomains.Domain where

import Data.Map.Strict (Map)
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Generated.IdAdmissionDomains.Nominals (LegacyId)
import Keiki.Shape (CanonicalTypeName (..))

data IdentityEnvelope = IdentityEnvelope
  { legacyId :: !LegacyId,
    previousId :: !(Maybe LegacyId),
    labelsById :: !(Map LegacyId Text)
  }
  deriving stock (Eq, Generic, Show)

instance CanonicalTypeName IdentityEnvelope where
  canonicalTypeName :: Proxy IdentityEnvelope -> Text
  canonicalTypeName _ = "conformance.id-admission-domains.IdentityEnvelope.v1"
