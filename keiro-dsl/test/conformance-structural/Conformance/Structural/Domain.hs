{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Conformance.Structural.Domain (
    ArtifactInfo (..),
    ArtifactMetadata (..),
    ArtifactKind (..),
    ArtifactLocation (..),
    Geometry (..),
) where

import Control.DeepSeq (NFData)
import Data.Aeson (FromJSON, ToJSON)
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))

data ArtifactInfo = ArtifactInfo
    { artifactKey :: !Text
    , displayName :: !Text
    , artifactHash :: !(Maybe Text)
    , artifactKind :: !ArtifactKind
    , location :: !ArtifactLocation
    , metadata :: !ArtifactMetadata
    , active :: !Bool
    , tags :: ![Text]
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, NFData, ToJSON)

data ArtifactMetadata = ArtifactMetadata
    { note :: !(Maybe Text)
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, NFData, ToJSON)

data ArtifactKind = Guide | Reference
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, NFData, ToJSON)

data ArtifactLocation
    = LocalFile !Text
    | LocalDir !Text
    | RepoPath !Text
    | LocUrl !Text
    | Canonical
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, NFData, ToJSON)

newtype Geometry = Geometry {geometryWkt :: Text}
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, NFData, ToJSON)

instance CanonicalTypeName ArtifactInfo where
    canonicalTypeName :: Proxy ArtifactInfo -> Text
    canonicalTypeName _ = "conformance.structural.ArtifactInfo.v1"

instance CanonicalTypeName ArtifactMetadata where
    canonicalTypeName :: Proxy ArtifactMetadata -> Text
    canonicalTypeName _ = "conformance.structural.ArtifactMetadata.v1"

instance CanonicalTypeName ArtifactKind where
    canonicalTypeName :: Proxy ArtifactKind -> Text
    canonicalTypeName _ = "conformance.structural.ArtifactKind.v1"

instance CanonicalTypeName ArtifactLocation where
    canonicalTypeName :: Proxy ArtifactLocation -> Text
    canonicalTypeName _ = "conformance.structural.ArtifactLocation.v1"
