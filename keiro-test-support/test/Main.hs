{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Aeson (Value (String))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Keiro.Test.ReplayCompatibility
import Test.Hspec

main :: IO ()
main = hspec do
  describe "Replay compatibility evidence" do
    it "accepts complete, build-bound, equal semantic observations" do
      releaseReady inventory baselineReport candidateReport `shouldBe` True

    it "round-trips the versioned JSON contracts" do
      Aeson.eitherDecode (Aeson.encode inventory) `shouldBe` Right inventory
      Aeson.eitherDecode (Aeson.encode baselineReport) `shouldBe` Right baselineReport

    it "rejects an empty report" do
      let empty = baselineReport {results = [], selectedSurfaces = []}
      validateCompatibility inventory empty candidateReport
        `shouldContain` [MissingRequiredCase BaselineCapture "orders/placed"]

    it "rejects unequal corpus identities" do
      let changed = candidateReport {corpusHash = "sha256:candidate-corpus"}
      validateCompatibility inventory baselineReport changed `shouldContain` [CorpusIdentityMismatch]

    it "rejects unverified required evidence" do
      let changed = candidateReport {results = [result {verdict = Unverified "random source cannot be pinned", observation = Nothing}]}
      validateCompatibility inventory baselineReport changed
        `shouldContain` [RequiredCaseUnverified CandidateCapture "orders/placed" "random source cannot be pinned"]

    it "rejects two empty observations" do
      let emptyObservation = Observation Map.empty [] Map.empty []
          old = baselineReport {results = [result {observation = Just emptyObservation}]}
          new = candidateReport {results = [result {observation = Just emptyObservation}]}
      validateCompatibility inventory old new
        `shouldContain` [EmptyPassedObservation BaselineCapture "orders/placed"]

    it "rejects an omitted old-only surface even when remaining rows pass" do
      let oldOnly = RequiredCase "orders/retired" HistoricalRead (PersistedSurface "aggregate-stream" "orders" "OrderRetired:v1")
          changedInventory =
            inventory
              { contributions =
                  map
                    ( \contribution ->
                        if contribution.source == BaselinePersistedSurfaces
                          then contribution {cases = contribution.cases <> [oldOnly]}
                          else contribution
                    )
                    inventory.contributions
              }
      validateCompatibility changedInventory baselineReport candidateReport
        `shouldContain` [MissingRequiredCase BaselineCapture "orders/retired"]

    it "rejects direct-ID, transition, process, and Hole omissions independently of mapped consequences" do
      let omittedCases =
            [ (AggregateReplayImpacts, RequiredCase "orders/direct-id" SemanticEquivalence (PersistedSurface "direct-nominal" "orders" "OrderId")),
              (AggregateReplayImpacts, RequiredCase "orders/transition" SemanticEquivalence (PersistedSurface "transition" "orders" "PlaceOrder")),
              (CheckedProcessReactions, RequiredCase "billing/process" ProcessManagerReplay (PersistedSurface "process-reaction" "billing" "InvoiceAccepted")),
              (ApplicationOwnedObligations, RequiredCase "orders/hole" SemanticEquivalence (PersistedSurface "application-hole" "orders" "PlaceOrder/Hole"))
            ]
          changedInventory = inventory {contributions = map (addCases omittedCases) inventory.contributions}
          failures = validateCompatibility changedInventory baselineReport candidateReport
      failures `shouldContain` [MissingRequiredCase BaselineCapture "orders/direct-id"]
      failures `shouldContain` [MissingRequiredCase CandidateCapture "orders/transition"]
      failures `shouldContain` [MissingRequiredCase CandidateCapture "billing/process"]
      failures `shouldContain` [MissingRequiredCase CandidateCapture "orders/hole"]

    it "rejects an unchanged-name application source as unverified" do
      let changedInventory =
            inventory
              { contributions =
                  map
                    ( \contribution ->
                        if contribution.source == ApplicationOwnedObligations
                          then contribution {applicability = SourceUnverified "Hole source hash changed without a capture"}
                          else contribution
                    )
                    inventory.contributions
              }
      validateCompatibility changedInventory baselineReport candidateReport
        `shouldContain` [ InvalidInventoryContribution
                            ApplicationOwnedObligations
                            "source is unverified: Hole source hash changed without a capture"
                        ]

addCases :: [(InventorySource, RequiredCase)] -> InventoryContribution -> InventoryContribution
addCases additions contribution =
  contribution
    { applicability = if null selected then contribution.applicability else Applicable,
      cases = contribution.cases <> selected
    }
  where
    selected = [addedCase | (source, addedCase) <- additions, source == contribution.source]

buildPair :: BuildPair
buildPair =
  BuildPair
    { baseline = BuildIdentity "baseline-revision" "language-v5" "runtime-v1" "sha256:baseline-plan",
      candidate = BuildIdentity "candidate-revision" "language-v6" "runtime-v1" "sha256:candidate-plan"
    }

fixtureSurface :: PersistedSurface
fixtureSurface = PersistedSurface "aggregate-stream" "orders" "OrderPlaced:v1"

required :: RequiredCase
required = RequiredCase "orders/placed" SemanticEquivalence fixtureSurface

inventory :: EvidenceInventory
inventory =
  EvidenceInventory
    { inventoryVersion = inventoryVersionV1,
      inventoryId = "sha256:inventory",
      buildPair = Main.buildPair,
      contributions =
        [ InventoryContribution
            { source,
              applicability = if source == BaselinePersistedSurfaces then Applicable else NotApplicable "fixture has no obligations from this source",
              cases = if source == BaselinePersistedSurfaces then [required] else []
            }
        | source <- inventorySourcesV1
        ]
    }

fixtureObservation :: Observation
fixtureObservation =
  Observation
    { durableState = Map.fromList [("status", String "placed")],
      continuations = [String "ReserveInventory"],
      durableIdentities = Map.fromList [("event", "event_01")],
      freshAllocations = ["trace-id"]
    }

result :: CaseResult
result = CaseResult required Passed (Just fixtureObservation)

report :: CaptureRole -> CaptureReport
report role =
  CaptureReport
    { reportVersion = reportVersionV1,
      role,
      buildPair = Main.buildPair,
      inventoryId = "sha256:inventory",
      corpusHash = "sha256:corpus",
      observationContractVersion = "orders-observation/v1",
      highWaterMarks = [HighWaterMark "orders-1" 42],
      selectedSurfaces = [fixtureSurface],
      determinismInputs = DeterminismInputs "2026-09-19T00:00:00Z" "seed:v1" "sha256:responses" "sha256:schedule",
      results = [result]
    }

baselineReport :: CaptureReport
baselineReport = report BaselineCapture

candidateReport :: CaptureReport
candidateReport = report CandidateCapture
