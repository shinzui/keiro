{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module NominalConformance.Domain where

import Data.Aeson (FromJSON, ToJSON)
import Data.KindID (KindID)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Keiki.Shape (CanonicalTypeName (..))
import Numeric.Natural (Natural)

newtype OrderId = OrderId {unOrderId :: KindID "ord"}
    deriving stock (Eq, Generic, Show)
    deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName OrderId where
    canonicalTypeName _ = "nominal.OrderId.v1"

data OrderStatus = AwaitingApproval | Accepted
    deriving stock (Eq, Generic, Ord, Show)
    deriving anyclass (FromJSON, ToJSON)

instance CanonicalTypeName OrderStatus where
    canonicalTypeName _ = "nominal.OrderStatus.v1"

newtype AccountNumber = AccountNumber {unAccountNumber :: Text}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName AccountNumber where
    canonicalTypeName _ = "nominal.AccountNumber.v1"

newtype RiskScore = RiskScore {unRiskScore :: Int}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName RiskScore where
    canonicalTypeName _ = "nominal.RiskScore.v1"

newtype SequenceNumber = SequenceNumber {unSequenceNumber :: Natural}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName SequenceNumber where
    canonicalTypeName _ = "nominal.SequenceNumber.v1"

newtype FeatureFlag = FeatureFlag {unFeatureFlag :: Bool}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName FeatureFlag where
    canonicalTypeName _ = "nominal.FeatureFlag.v1"

newtype ObservedAt = ObservedAt {unObservedAt :: UTCTime}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

instance CanonicalTypeName ObservedAt where
    canonicalTypeName _ = "nominal.ObservedAt.v1"
