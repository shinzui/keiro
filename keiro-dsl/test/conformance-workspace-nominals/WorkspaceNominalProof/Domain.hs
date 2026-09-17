{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module WorkspaceNominalProof.Domain where

import Data.Aeson (FromJSON, ToJSON)
import Data.KindID (KindID)
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

newtype ClaimId = ClaimId {unClaimId :: KindID "claim"}
  deriving stock (Eq, Generic, Show)
  deriving newtype (FromJSON, ToJSON)

unClaimId :: ClaimId -> KindID "claim"
unClaimId (ClaimId value) = value

instance CanonicalTypeName ClaimId where
  canonicalTypeName :: Proxy ClaimId -> Text
  canonicalTypeName _ = "workspace-nominal-proof.ClaimId.v1"

data ProjectClaim = ProjectClaim
  { claimId :: !ClaimId
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName ProjectClaim where
  canonicalTypeName :: Proxy ProjectClaim -> Text
  canonicalTypeName _ = "workspace-nominal-proof.ProjectClaim.v1"

data ArtifactClaim = ArtifactClaim
  { claimId :: !ClaimId
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName ArtifactClaim where
  canonicalTypeName :: Proxy ArtifactClaim -> Text
  canonicalTypeName _ = "workspace-nominal-proof.ArtifactClaim.v1"
