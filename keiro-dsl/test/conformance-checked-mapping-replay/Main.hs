module Main (main) where

import Conformance.CheckedMappingReplay.Domain qualified as Domain
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Calendar (fromGregorian)
import Generated.CheckedMappingReplay.Nominals (RetainedId, parseRetainedId, retainedIdText)
import Generated.CheckedMappingReplay.ReplayEvents.Contract
import Generated.CheckedMappingReplay.ReplayJobs.Queue (ReplayJob (..), encodeReplayJob, parseReplayJob)
import Generated.CheckedMappingReplay.ReplayLedger.Codec
import Generated.CheckedMappingReplay.ReplayLedger.Domain
import Generated.CheckedMappingReplay.ReplayLedger.EventStream (replayLedgerSnapshotFixture)
import Generated.CheckedMappingReplay.ReplayLedger.Harness (harnessAssertions)
import Generated.CheckedMappingReplay.ReplayLedger.Transducer (replayLedgerTransducer)
import Generated.CheckedMappingReplay.ReplayLookup.QueryContract (ReplayLookupQueryInput, ReplayLookupQueryResult)
import Generated.CheckedMappingReplay.StructuralConformance (structuralConformanceAssertions)
import Keiki.Core (applyEventsEither, (!))
import Keiro.Codec (EventType (..))
import Keiro.Test.ReplayCompatibility
import System.Exit (exitFailure)

main :: IO ()
main = do
  retained <- Aeson.eitherDecodeFileStrict' retainedFixturePath
  let retainedReplay = either (const False) retainedHistoryReplays retained
      retainedNormalization = either (const False) retainedHistoryNormalizes retained
      assertions =
        [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
          <> harnessAssertions
          <> [ ("retained JSON fixture crosses the generated event parser and transducer", retainedReplay),
               ("admitted historical spellings normalize to canonical bytes and identical state", retainedNormalization),
               ("replay-only history preserves UUIDv5 and all checked mappings", replayOnlyHistory),
               ("serialized UUIDv5 and UUIDv7 event history retains exact identities", identifierHistory),
               ("queue, query, and contract surfaces preserve the integrated envelope", generatedSurfaceAgreement),
               ("application-owned workflow result codec preserves the integrated envelope", workflowCodecAgreement),
               ("snapshot discriminator remains explicit in the integrated evidence", replayLedgerSnapshotFixture == (1, "checked-mapping-replay-v1")),
               ("baseline and candidate replay evidence satisfy the release comparator", releaseReady integratedInventory baselineReport candidateReport),
               ("date semantic mutations are detected", mutationDetected "date" (mutateState "date" (String "2000-03-01"))),
               ("set semantic mutations are detected", mutationDetected "set" (mutateState "labels" (Aeson.toJSON (["a", "c"] :: [Text])))),
               ("base16 semantic mutations are detected", mutationDetected "base16" (mutateState "contentHash" (String "00bf"))),
               ("identifier mutations are detected", mutationDetected "identifier" (mutateIdentity "entity" retainedV7Text)),
               ("consumer binding mutations are detected", mutationDetected "binding" (mutateState "binding" (String "transposed"))),
               ("event-shape mutations are detected", mutationDetected "event-shape" (integratedObservation {continuations = [String "MappingReplaced"]})),
               ("process-manager identity mutations are detected", mutationDetected "process" (mutateIdentity "process" "replay-process-v2")),
               ("workflow journal-key mutations are detected", mutationDetected "workflow" (mutateIdentity "workflow" "workflow/replay/v2")),
               ("unverified consumer evidence prevents release readiness", not (releaseReady integratedInventory baselineReport unverifiedCandidateReport)),
               ("information-losing event changes fail before replay", informationLossRejected)
             ]
  forM_ assertions $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd assertions) exitFailure

retainedFixturePath :: FilePath
retainedFixturePath = "test/conformance-checked-mapping-replay/fixtures/retained/mapping-recorded-v1.json"

retainedHistoryReplays :: Value -> Bool
retainedHistoryReplays wire =
  case replayRawEnvelope wire of
    Right (vertex, current, currentId) ->
      vertex == ReplayLedgerRecorded
        && current == expectedEnvelope
        && retainedIdText currentId == retainedV5Text
    Left _ -> False

retainedHistoryNormalizes :: Value -> Bool
retainedHistoryNormalizes historical =
  decodeReplayEnvelopeMapped historical == Right expectedEnvelope
    && encodeReplayEnvelopeMapped expectedEnvelope == canonicalEnvelope
    && null
      ( checkNormalizationLaw
          decodeReplayEnvelopeMapped
          encodeReplayEnvelopeMapped
          replayRawEnvelopeChain
          []
          historical
          canonicalEnvelope
          []
      )

replayRawEnvelopeChain :: [Value] -> Either Text (ReplayLedgerVertex, Domain.ReplayEnvelope, RetainedId)
replayRawEnvelopeChain [wire] = replayRawEnvelope wire
replayRawEnvelopeChain _ = Left "the terminal integration aggregate expects exactly one retained transition"

replayRawEnvelope :: Value -> Either Text (ReplayLedgerVertex, Domain.ReplayEnvelope, RetainedId)
replayRawEnvelope wire = do
  let recorded = MappingRecorded (MappingRecordedData retainedV5 expectedEnvelope)
      audited = MappingAudited (MappingAuditedData retainedV5 expectedEnvelope)
  recordedEvent <- parseReplayLedgerEvent (EventType "MappingRecorded") (replaceObjectField "envelope" wire (encodeReplayLedgerEvent recorded))
  auditedEvent <- parseReplayLedgerEvent (EventType "MappingAudited") (replaceObjectField "envelope" wire (encodeReplayLedgerEvent audited))
  (vertex, registers) <- firstText (applyEventsEither replayLedgerTransducer (ReplayLedgerEmpty, initialReplayLedgerRegs) [recordedEvent, auditedEvent])
  pure (vertex, registers ! #current, registers ! #currentId)

replayOnlyHistory :: Bool
replayOnlyHistory =
  case parseReplayLedgerEvent (EventType "LegacyMappingImported") rawEvent of
    Left _ -> False
    Right parsed -> case applyEventsEither replayLedgerTransducer (ReplayLedgerEmpty, initialReplayLedgerRegs) [parsed] of
      Left _ -> False
      Right (vertex, registers) ->
        vertex == ReplayLedgerRecorded
          && registers ! #current == expectedEnvelope
          && registers ! #currentId == retainedV5
  where
    event = LegacyMappingImported (LegacyMappingImportedData retainedV5 expectedEnvelope)
    rawEvent = replaceObjectField "envelope" nonCanonicalEnvelope (encodeReplayLedgerEvent event)

identifierHistory :: Bool
identifierHistory =
  decodeReplayEnvelopeMapped nonCanonicalEnvelope == Right expectedEnvelope
    && Map.keys identityMap == [retainedV7, retainedV5]
    && retainedIdText retainedV5 == retainedV5Text
    && retainedIdText retainedV7 == retainedV7Text

generatedSurfaceAgreement :: Bool
generatedSurfaceAgreement =
  parseReplayJob (encodeReplayJob queuePayload) == Right queuePayload
    && queryInputIdentity expectedEnvelope == expectedEnvelope
    && queryResultIdentity [expectedEnvelope] == [expectedEnvelope]
    && parseReplayEventsPayload (encodeReplayEventsPayload contractPayload) == Right contractPayload
  where
    queuePayload = ReplayJob retainedV5 expectedEnvelope
    contractPayload = ReplayLinked (ReplayLinkedData retainedV5)

queryInputIdentity :: ReplayLookupQueryInput -> Domain.ReplayEnvelope
queryInputIdentity = id

queryResultIdentity :: ReplayLookupQueryResult -> [Domain.ReplayEnvelope]
queryResultIdentity = id

workflowCodecAgreement :: Bool
workflowCodecAgreement =
  decodeWorkflowResult (encodeWorkflowResult expectedEnvelope) == Right expectedEnvelope
    && decodeWorkflowResult nonCanonicalEnvelope == Right expectedEnvelope

encodeWorkflowResult :: Domain.ReplayEnvelope -> Value
encodeWorkflowResult = encodeReplayEnvelopeMapped

decodeWorkflowResult :: Value -> Either Text Domain.ReplayEnvelope
decodeWorkflowResult = decodeReplayEnvelopeMapped

informationLossRejected :: Bool
informationLossRejected =
  isLeft (parseReplayLedgerEvent (EventType "MappingRecorded") (deleteNestedEnvelopeField "contentHash" encoded))
  where
    encoded = encodeReplayLedgerEvent (MappingRecorded (MappingRecordedData retainedV5 expectedEnvelope))

expectedEnvelope :: Domain.ReplayEnvelope
expectedEnvelope =
  Domain.ReplayEnvelope
    (Domain.MaybeLabel (Just "retained"))
    (Domain.ImportantDays [fromGregorian 2000 2 29, fromGregorian 12345678901234567890 6 30])
    (Domain.TextLabels (Set.fromList ["a", "b"]))
    (Domain.MaybeContentHash (Just (Domain.ContentHash (BS.pack [0, 175]))))
    retainedV5
    identityMap
    (Just (Set.fromList ["a", "z"]))

identityMap :: Map RetainedId Text
identityMap = Map.fromList [(retainedV5, "historical-v5"), (retainedV7, "current-v7")]

canonicalEnvelope :: Value
canonicalEnvelope = encodeReplayEnvelopeMapped expectedEnvelope

nonCanonicalEnvelope :: Value
nonCanonicalEnvelope =
  object
    [ "label" .= String "retained",
      "days" .= (["+002000-02-29", "12345678901234567890-06-30"] :: [Text]),
      "labels" .= (["b", "a", "a"] :: [Text]),
      "contentHash" .= String "00AF",
      "primary" .= retainedV5Text,
      "identities" .= object [Key.fromText retainedV5Text .= String "historical-v5", Key.fromText retainedV7Text .= String "current-v7"],
      "optionalLabels" .= (["z", "a", "a"] :: [Text])
    ]

retainedV5Text, retainedV7Text :: Text
retainedV5Text = "retained_58kj0y515rbwebzaxwzzknjqnk"
retainedV7Text = "retained_01h455vb4pex5vsknk084sn02q"

retainedV5, retainedV7 :: RetainedId
retainedV5 = committedId retainedV5Text
retainedV7 = committedId retainedV7Text

committedId :: Text -> RetainedId
committedId value = case parseRetainedId value of
  Right parsed -> parsed
  Left reason -> error ("invalid committed RetainedId fixture: " <> show reason)

replaceObjectField :: Key.Key -> Value -> Value -> Value
replaceObjectField key inserted (Object value) = Object (KeyMap.insert key inserted value)
replaceObjectField _ _ value = value

deleteNestedEnvelopeField :: Key.Key -> Value -> Value
deleteNestedEnvelopeField key (Object outer) =
  case KeyMap.lookup "envelope" outer of
    Just (Object envelope) -> Object (KeyMap.insert "envelope" (Object (KeyMap.delete key envelope)) outer)
    _ -> Object outer
deleteNestedEnvelopeField _ value = value

firstText :: (Show problem) => Either problem value -> Either Text value
firstText = either (Left . Text.pack . show) Right

integratedInventory :: EvidenceInventory
integratedInventory =
  EvidenceInventory
    { inventoryVersion = inventoryVersionV1,
      inventoryId = "checked-mapping-replay/inventory/v1",
      buildPair = integratedBuildPair,
      contributions =
        [ InventoryContribution source Applicable integratedCases
        | source <- inventorySourcesV1
        ]
    }

integratedCases :: [RequiredCase]
integratedCases =
  [ RequiredCase "aggregate-history" HistoricalRead aggregateSurface,
    RequiredCase "semantic-equivalence" SemanticEquivalence aggregateSurface,
    RequiredCase "old-reader-new-writer" OldReaderNewWriter aggregateSurface,
    RequiredCase "snapshot-replay" SnapshotReplay snapshotSurface,
    RequiredCase "process-recovery" ProcessManagerReplay processSurface,
    RequiredCase "workflow-journal" WorkflowReplay workflowSurface
  ]

aggregateSurface, snapshotSurface, processSurface, workflowSurface :: PersistedSurface
aggregateSurface = PersistedSurface "event-stream" "ReplayLedger" "replayLedger/<retained-id>"
snapshotSurface = PersistedSurface "snapshot" "ReplayLedger" "checked-mapping-replay-v1"
processSurface = PersistedSurface "process-manager" "ReplayProjection" "replay-process-v1"
workflowSurface = PersistedSurface "workflow-journal" "ReplayWorkflow" "workflow/replay/v1"

integratedBuildPair :: BuildPair
integratedBuildPair =
  BuildPair
    (BuildIdentity "retained-v1" "keiro-dsl-6" "keiro-runtime-v1" "integrated-plan-v1")
    (BuildIdentity "candidate-v1" "keiro-dsl-6" "keiro-runtime-v1" "integrated-plan-v1")

baselineReport, candidateReport, unverifiedCandidateReport :: CaptureReport
baselineReport = capture BaselineCapture
candidateReport = capture CandidateCapture
unverifiedCandidateReport =
  candidateReport
    { results = case candidateReport.results of
        [] -> []
        row : remaining -> row {verdict = Unverified "consumer history was not captured"} : remaining
    }

capture :: CaptureRole -> CaptureReport
capture captureRole =
  CaptureReport
    { reportVersion = reportVersionV1,
      role = captureRole,
      buildPair = integratedBuildPair,
      inventoryId = "checked-mapping-replay/inventory/v1",
      corpusHash = "checked-mapping-replay-retained-v1",
      observationContractVersion = "checked-mapping-replay/observation/v1",
      highWaterMarks = [HighWaterMark "replayLedger/retained-v5" 2],
      selectedSurfaces = [aggregateSurface, snapshotSurface, processSurface, workflowSurface],
      determinismInputs = DeterminismInputs "frozen" "none" "none" "partial-success-after-first-target",
      results = [CaseResult required Passed (Just (observationFor required.caseKind)) | required <- integratedCases]
    }

observationFor :: CaseKind -> Observation
observationFor kind = case kind of
  ProcessManagerReplay -> processObservation
  WorkflowReplay -> workflowObservation
  _ -> integratedObservation

integratedObservation :: Observation
integratedObservation =
  Observation
    { durableState =
        Map.fromList
          [ ("date", String "2000-02-29"),
            ("labels", Aeson.toJSON (["a", "b"] :: [Text])),
            ("contentHash", String "00af"),
            ("binding", canonicalEnvelope),
            ("state", String "ReplayLedgerRecorded")
          ],
      continuations = [String "MappingRecorded", String "MappingAudited"],
      durableIdentities = Map.fromList [("entity", retainedV5Text), ("snapshot", "checked-mapping-replay-v1")],
      freshAllocations = []
    }

processObservation :: Observation
processObservation =
  integratedObservation
    { durableState = Map.insert "partialFanout" (String "resume-second-target") integratedObservation.durableState,
      continuations = integratedObservation.continuations <> [String "timer/retry-v1"],
      durableIdentities = Map.insert "process" "replay-process-v1" integratedObservation.durableIdentities
    }

workflowObservation :: Observation
workflowObservation =
  integratedObservation
    { durableState = Map.insert "workflowResult" canonicalEnvelope integratedObservation.durableState,
      continuations = integratedObservation.continuations <> [String "resume/checked-mapping"],
      durableIdentities = Map.insert "workflow" "workflow/replay/v1" integratedObservation.durableIdentities
    }

mutationDetected :: Text -> Observation -> Bool
mutationDetected label mutated = not (null (compareObservation label integratedObservation mutated))

mutateState :: Text -> Value -> Observation
mutateState key value = integratedObservation {durableState = Map.insert key value integratedObservation.durableState}

mutateIdentity :: Text -> Text -> Observation
mutateIdentity key value = integratedObservation {durableIdentities = Map.insert key value integratedObservation.durableIdentities}
