{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module ScalarExpressions.Domain (Limits (..)) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Proxy (Proxy)
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))
import Numeric.Natural (Natural)

data Limits = Limits
    { minimum :: !Integer
    , ceiling :: !Natural
    }
    deriving stock (Eq, Generic, Show)
    deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName Limits where
    canonicalTypeName :: Proxy Limits -> Text
    canonicalTypeName _ = "scalar-expressions.Limits.v1"
