{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Conformance.MappedReadModel.Domain
  ( AccountLookup (..),
    AccountProfile (..),
    AccountSummary (..),
    TenantKey (..),
    UnusedFilter (..),
    fixtureAccountLookup,
    fixtureAccountSummary,
  )
where

import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

newtype TenantKey = TenantKey
  { tenantId :: Text
  }
  deriving stock (Eq, Show, Generic)

data AccountLookup = AccountLookup
  { lookupAccountId :: !Text,
    lookupTenant :: !TenantKey
  }
  deriving stock (Eq, Show, Generic)

newtype AccountProfile = AccountProfile
  { displayName :: Text
  }
  deriving stock (Eq, Show, Generic)

data AccountSummary = AccountSummary
  { summaryAccountId :: !Text,
    summaryTenant :: !TenantKey,
    summaryProfile :: !(Maybe AccountProfile)
  }
  deriving stock (Eq, Show, Generic)

newtype UnusedFilter = UnusedFilter
  { prefix :: Text
  }
  deriving stock (Eq, Show, Generic)

fixtureAccountLookup :: AccountLookup
fixtureAccountLookup = AccountLookup "account-7" (TenantKey "tenant-main")

fixtureAccountSummary :: AccountSummary
fixtureAccountSummary =
  AccountSummary
    "account-7"
    (TenantKey "tenant-main")
    (Just (AccountProfile "Ada"))

instance CanonicalTypeName TenantKey where
  canonicalTypeName :: Proxy TenantKey -> Text
  canonicalTypeName _ = "conformance.mapped-readmodel.TenantKey.v1"

instance CanonicalTypeName AccountLookup where
  canonicalTypeName :: Proxy AccountLookup -> Text
  canonicalTypeName _ = "conformance.mapped-readmodel.AccountLookup.v1"

instance CanonicalTypeName AccountProfile where
  canonicalTypeName :: Proxy AccountProfile -> Text
  canonicalTypeName _ = "conformance.mapped-readmodel.AccountProfile.v1"

instance CanonicalTypeName AccountSummary where
  canonicalTypeName :: Proxy AccountSummary -> Text
  canonicalTypeName _ = "conformance.mapped-readmodel.AccountSummary.v1"

instance CanonicalTypeName UnusedFilter where
  canonicalTypeName :: Proxy UnusedFilter -> Text
  canonicalTypeName _ = "conformance.mapped-readmodel.UnusedFilter.v1"
