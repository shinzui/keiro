{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module ReplayCompatibilitySpec
  ( spec,
  )
where

import Data.Aeson (Value, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Keiro.Codec
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Keiro.Test.ReplayCompatibility
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (ExpectedVersion (..), StreamName (..), StreamVersion (..))
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = do
  describe "serialized aggregate replay compatibility" $ around (withFreshStore fixture) do
    it "crosses the PostgreSQL event envelope before candidate decoding" $ \store -> do
      encoded <- shouldBeRight (encodeForAppend baselineCodec (WordHead 7))
      Right _ <- Store.runStoreIO store (Store.appendToStream (StreamName "replay-compatibility-aggregate") NoStream [encoded])
      Right stored <- Store.runStoreIO store (Store.readStreamForward (StreamName "replay-compatibility-aggregate") (StreamVersion 0) 10)
      case Vector.toList stored of
        [recorded] -> do
          decodeRecorded baselineCodec recorded `shouldBe` Right (WordHead 7)
          decodeRecorded refactoredCodec recorded `shouldBe` Right (WordHead 7)
        events -> expectationFailure ("expected one stored event, got " <> show (length events))

  describe "complete transition-prefix observations" do
    it "keeps a source-module refactor equivalent at every complete prefix" do
      let transitionWords = [[WordHead 2, WordTail 3], [WordHead 5, WordTail 7]]
      traverse observeCompletePrefix (completePrefixes transitionWords)
        `shouldBe` traverse observeRefactoredPrefix (completePrefixes transitionWords)

    it "rejects a truncated multi-event transition word" do
      observeCompletePrefix [WordHead 2] `shouldBe` Left "transition word ended after its head"

    it "reports changed writes, retired inverse edges, and lost head data" do
      let complete = [WordHead 2, WordTail 3]
      observeChangedWrite complete `shouldNotBe` observeCompletePrefix complete
      observeRetiredInverse complete `shouldBe` Left "WordHead inverse is unavailable"
      observeCompletePrefix [WordTail 3] `shouldBe` Left "transition word lost its head"

    it "turns a semantic prefix drift into a compatibility failure" do
      let baselineObservation = observationFor 5
          candidateObservation = observationFor 6
          oldReport = reportFor BaselineCapture baselineObservation
          newReport = reportFor CandidateCapture candidateObservation
      validateCompatibility prefixInventory oldReport newReport
        `shouldContain` [ObservationMismatch "aggregate/word/prefix-1"]

data WordEvent = WordHead Int | WordTail Int
  deriving stock (Eq, Show)

baselineCodec :: Codec WordEvent
baselineCodec =
  Codec
    { eventTypes = EventType "WordHead" :| [EventType "WordTail"],
      eventType = \case WordHead {} -> EventType "WordHead"; WordTail {} -> EventType "WordTail",
      schemaVersion = 1,
      encode = encodeWord,
      decode = decodeWord,
      upcasters = []
    }

-- A Haskell-only module/selector refactor retains the stable wire tags and keys.
refactoredCodec :: Codec WordEvent
refactoredCodec = baselineCodec {encode = refactoredEncode, decode = refactoredDecode}
  where
    refactoredEncode = encodeWord
    refactoredDecode = decodeWord

encodeWord :: WordEvent -> Value
encodeWord = \case
  WordHead amount -> object ["amount" Aeson..= amount]
  WordTail amount -> object ["amount" Aeson..= amount]

decodeWord :: EventType -> Value -> Either Text WordEvent
decodeWord (EventType tag) value = case tag of
  "WordHead" -> WordHead <$> parseAmount value
  "WordTail" -> WordTail <$> parseAmount value
  _ -> Left ("unknown word event: " <> tag)

parseAmount :: Value -> Either Text Int
parseAmount value = case parseEither (withObject "WordEvent" (.: "amount")) value of
  Left problem -> Left (Text.pack problem)
  Right amount -> Right amount

completePrefixes :: [[event]] -> [[event]]
completePrefixes = drop 1 . scanl (<>) []

observeCompletePrefix :: [WordEvent] -> Either Text Int
observeCompletePrefix = go 0
  where
    go total [] = Right total
    go _ [WordHead _] = Left "transition word ended after its head"
    go _ (WordTail _ : _) = Left "transition word lost its head"
    go _ (WordHead _ : WordHead _ : _) = Left "transition word contains consecutive heads"
    go total (WordHead headAmount : WordTail tailAmount : rest) = go (total + headAmount + tailAmount) rest

observeRefactoredPrefix :: [WordEvent] -> Either Text Int
observeRefactoredPrefix events = observeCompletePrefix events

observeChangedWrite :: [WordEvent] -> Either Text Int
observeChangedWrite = fmap (+ 1) . observeCompletePrefix

observeRetiredInverse :: [WordEvent] -> Either Text Int
observeRetiredInverse events
  | any isHead events = Left "WordHead inverse is unavailable"
  | otherwise = observeCompletePrefix events
  where
    isHead WordHead {} = True
    isHead WordTail {} = False

prefixCase :: RequiredCase
prefixCase = RequiredCase "aggregate/word/prefix-1" SemanticEquivalence prefixSurface

prefixSurface :: PersistedSurface
prefixSurface = PersistedSurface "aggregate-stream" "word" "WordHead+WordTail:v1"

prefixBuildPair :: BuildPair
prefixBuildPair =
  BuildPair
    { baseline = BuildIdentity "baseline" "language-v5" "runtime-v1" "plan-a",
      candidate = BuildIdentity "candidate" "language-v5" "runtime-v1" "plan-b"
    }

prefixInventory :: EvidenceInventory
prefixInventory =
  EvidenceInventory
    inventoryVersionV1
    "prefix-inventory"
    prefixBuildPair
    [ InventoryContribution source applicability cases
    | source <- inventorySourcesV1,
      let applicable = source == BaselinePersistedSurfaces,
      let applicability = if applicable then Applicable else NotApplicable "fixture does not exercise this source",
      let cases = if applicable then [prefixCase] else []
    ]

observationFor :: Int -> Observation
observationFor total = Observation (Map.fromList [("total", Aeson.toJSON total)]) [] Map.empty []

reportFor :: CaptureRole -> Observation -> CaptureReport
reportFor role observation =
  CaptureReport
    { reportVersion = reportVersionV1,
      role,
      buildPair = prefixBuildPair,
      inventoryId = "prefix-inventory",
      corpusHash = "prefix-corpus",
      observationContractVersion = "word-observation/v1",
      highWaterMarks = [HighWaterMark "word-1" 2],
      selectedSurfaces = [prefixSurface],
      determinismInputs = DeterminismInputs "fixed-clock" "fixed-randomness" "responses" "failures",
      results = [CaseResult prefixCase Passed (Just observation)]
    }

shouldBeRight :: (Show error) => Either error value -> IO value
shouldBeRight = either (\problem -> expectationFailure (show problem) >> fail "unreachable") pure
