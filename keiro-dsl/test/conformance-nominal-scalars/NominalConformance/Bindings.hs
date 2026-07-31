{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module NominalConformance.Bindings where

import Data.Aeson (Value (..), toJSON)
import Data.KindID (KindID)
import qualified Data.KindID as KindID
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import qualified Generated.NominalScalars.Nominal.Shape.OrderStatus as Representation
import Keiro.Codec.Nominal
import NominalConformance.Domain
import Numeric.Natural (Natural)

orderIdBinding :: NominalBinding OrderId (KindID "ord")
orderIdBinding = NominalBinding unOrderId OrderId

orderStatusBinding :: NominalBinding OrderStatus Representation.OrderStatusRepresentation
orderStatusBinding =
    NominalBinding
        { nominalToRepresentation = \case
            AwaitingApproval -> Representation.Draft
            Accepted -> Representation.Submitted
        , nominalFromRepresentation = \case
            Representation.Draft -> AwaitingApproval
            Representation.Submitted -> Accepted
        }

accountNumberBinding :: NominalBinding AccountNumber Text
accountNumberBinding = NominalBinding unAccountNumber AccountNumber

riskScoreBinding :: NominalBinding RiskScore Int
riskScoreBinding = NominalBinding unRiskScore RiskScore

sequenceNumberBinding :: NominalBinding SequenceNumber Natural
sequenceNumberBinding = NominalBinding unSequenceNumber SequenceNumber

featureFlagBinding :: NominalBinding FeatureFlag Bool
featureFlagBinding = NominalBinding unFeatureFlag FeatureFlag

observedAtBinding :: NominalBinding ObservedAt UTCTime
observedAtBinding = NominalBinding unObservedAt ObservedAt

validOrderIdText :: Text
validOrderIdText = "ord_00041061050r3gg28a1c60t3gf"

sampleOrderId :: OrderId
sampleOrderId = case KindID.parseText @"ord" validOrderIdText of
    Left reason -> error ("invalid committed conformance TypeID: " <> show reason)
    Right value -> OrderId value

sampleTime :: UTCTime
sampleTime = case iso8601ParseM "2026-07-31T12:34:56Z" of
    Nothing -> error "invalid committed conformance timestamp"
    Just value -> value

orderIdFixtures :: NominalFixtureCases OrderId
orderIdFixtures = cases [NominalFixture "order-id" (String validOrderIdText) sampleOrderId]

orderStatusFixtures :: NominalFixtureCases OrderStatus
orderStatusFixtures =
    cases
        [ NominalFixture "draft" (String "draft") AwaitingApproval
        , NominalFixture "submitted" (String "submitted") Accepted
        ]

accountNumberFixtures :: NominalFixtureCases AccountNumber
accountNumberFixtures = cases [NominalFixture "account" (String "acct-007") (AccountNumber "acct-007")]

riskScoreFixtures :: NominalFixtureCases RiskScore
riskScoreFixtures = cases [NominalFixture "risk" (toJSON (7 :: Int)) (RiskScore 7)]

sequenceNumberFixtures :: NominalFixtureCases SequenceNumber
sequenceNumberFixtures = cases [NominalFixture "sequence" (toJSON (11 :: Natural)) (SequenceNumber 11)]

featureFlagFixtures :: NominalFixtureCases FeatureFlag
featureFlagFixtures = cases [NominalFixture "feature" (Bool True) (FeatureFlag True)]

observedAtFixtures :: NominalFixtureCases ObservedAt
observedAtFixtures = cases [NominalFixture "observed-at" (toJSON sampleTime) (ObservedAt sampleTime)]

initialOrderId :: OrderId
initialOrderId = sampleOrderId

initialOrderStatus :: OrderStatus
initialOrderStatus = AwaitingApproval

initialAccountNumber :: AccountNumber
initialAccountNumber = AccountNumber "acct-initial"

initialRiskScore :: RiskScore
initialRiskScore = RiskScore 0

initialSequenceNumber :: SequenceNumber
initialSequenceNumber = SequenceNumber 0

initialFeatureFlag :: FeatureFlag
initialFeatureFlag = FeatureFlag False

initialObservedAt :: ObservedAt
initialObservedAt = ObservedAt sampleTime

cases :: [NominalFixture domain] -> NominalFixtureCases domain
cases (firstFixture : rest) = NominalFixtureCases (firstFixture :| rest)
cases [] = error "conformance fixtures must be non-empty"
