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

unOrderId :: OrderId -> KindID "ord"
unOrderId (OrderId value) = value

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

unAccountNumber :: AccountNumber -> Text
unAccountNumber (AccountNumber value) = value

instance CanonicalTypeName AccountNumber where
    canonicalTypeName _ = "nominal.AccountNumber.v1"

newtype RiskScore = RiskScore {unRiskScore :: Int}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

unRiskScore :: RiskScore -> Int
unRiskScore (RiskScore value) = value

instance CanonicalTypeName RiskScore where
    canonicalTypeName _ = "nominal.RiskScore.v1"

newtype SequenceNumber = SequenceNumber {unSequenceNumber :: Natural}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

unSequenceNumber :: SequenceNumber -> Natural
unSequenceNumber (SequenceNumber value) = value

instance CanonicalTypeName SequenceNumber where
    canonicalTypeName _ = "nominal.SequenceNumber.v1"

newtype FeatureFlag = FeatureFlag {unFeatureFlag :: Bool}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

unFeatureFlag :: FeatureFlag -> Bool
unFeatureFlag (FeatureFlag value) = value

instance CanonicalTypeName FeatureFlag where
    canonicalTypeName _ = "nominal.FeatureFlag.v1"

newtype ObservedAt = ObservedAt {unObservedAt :: UTCTime}
    deriving stock (Eq, Generic, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

unObservedAt :: ObservedAt -> UTCTime
unObservedAt (ObservedAt value) = value

instance CanonicalTypeName ObservedAt where
    canonicalTypeName _ = "nominal.ObservedAt.v1"
