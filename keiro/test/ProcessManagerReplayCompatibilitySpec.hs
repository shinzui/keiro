{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module ProcessManagerReplayCompatibilitySpec
  ( spec,
  )
where

import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Keiro.Test.ReplayCompatibility
import Test.Hspec

spec :: Spec
spec = describe "process-manager replay observation contract" do
  it "accepts an unchanged target-keyed continuation trace" do
    compareObservation processCase baselineObservation baselineObservation `shouldBe` []

  it "rejects a migration from positional to target-keyed command identity" do
    mismatch (changeIdentity "identity-family" "positional")

  it "rejects manager, correlation, source interpretation, timer, and witness drift independently" do
    traverse_
      mismatch
      [ changeIdentity "manager" "billing-v2",
        changeIdentity "correlation" "account-42-v2",
        changeState "source-meaning" (Aeson.String "amount=13"),
        changeState "timer-decoder" (Aeson.String "narrow-v2"),
        changeState "accepted-witness" (Aeson.String "undecodable")
      ]

  it "rejects same-target reorder and payload changes" do
    mismatch (baselineObservation {continuations = reverse baselineObservation.continuations})
    mismatch
      ( baselineObservation
          { continuations =
              Aeson.object ["target" Aeson..= ("account-42" :: Text), "occurrence" Aeson..= (0 :: Int), "amount" Aeson..= (99 :: Int)]
                : drop 1 baselineObservation.continuations
          }
      )
  where
    mismatch candidate =
      compareObservation processCase baselineObservation candidate
        `shouldBe` [ObservationMismatch processCase]

processCase :: Text
processCase = "process/billing/partial-recovery"

baselineObservation :: Observation
baselineObservation =
  Observation
    { durableState =
        Map.fromList
          [ ("accepted-witness", Aeson.String "source-event-9"),
            ("source-meaning", Aeson.String "amount=12"),
            ("saga-state", Aeson.String "accepted"),
            ("timer-decoder", Aeson.String "timer-v1"),
            ("timer-payload", Aeson.object ["attempt" Aeson..= (1 :: Int)]),
            ("timer-status", Aeson.String "scheduled")
          ],
      continuations =
        [ Aeson.object ["target" Aeson..= ("account-42" :: Text), "occurrence" Aeson..= (0 :: Int), "amount" Aeson..= (12 :: Int)],
          Aeson.object ["target" Aeson..= ("account-42" :: Text), "occurrence" Aeson..= (1 :: Int), "amount" Aeson..= (7 :: Int)]
        ],
      durableIdentities =
        Map.fromList
          [ ("manager", "billing"),
            ("correlation", "account-42"),
            ("source-event", "source-event-9"),
            ("identity-family", "target-keyed")
          ],
      freshAllocations = []
    }

changeIdentity :: Text -> Text -> Observation
changeIdentity key value =
  baselineObservation {durableIdentities = Map.insert key value baselineObservation.durableIdentities}

changeState :: Text -> Aeson.Value -> Observation
changeState key value =
  baselineObservation {durableState = Map.insert key value baselineObservation.durableState}
