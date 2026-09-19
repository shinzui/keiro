{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Stable, application-neutral evidence for comparing retained history across
-- two independently built versions of a service.
--
-- Capture programs should link only one application version. They emit a
-- 'CaptureReport'; a separate comparator loads the baseline report, candidate
-- report, and independently generated 'EvidenceInventory'. This avoids making
-- old and new domain types coexist in one executable.
module Keiro.Test.ReplayCompatibility
  ( BuildIdentity (..),
    BuildPair (..),
    CaptureRole (..),
    CaseKind (..),
    PersistedSurface (..),
    RequiredCase (..),
    InventorySource (..),
    SourceApplicability (..),
    InventoryContribution (..),
    EvidenceInventory (..),
    HighWaterMark (..),
    DeterminismInputs (..),
    Observation (..),
    EvidenceVerdict (..),
    CaseResult (..),
    CaptureReport (..),
    CompatibilityFailure (..),
    inventorySourcesV1,
    inventoryVersionV1,
    reportVersionV1,
    requiredCases,
    validateCompatibility,
    releaseReady,
    renderCompatibilityFailure,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.List (group, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

reportVersionV1 :: Text
reportVersionV1 = "keiro.replay-compatibility/report/v1"

inventoryVersionV1 :: Text
inventoryVersionV1 = "keiro.replay-compatibility/inventory/v1"

data BuildIdentity = BuildIdentity
  { sourceRevision :: Text,
    languageProfile :: Text,
    runtimeProfile :: Text,
    dependencyPlanHash :: Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON BuildIdentity

instance FromJSON BuildIdentity

data BuildPair = BuildPair
  { baseline :: BuildIdentity,
    candidate :: BuildIdentity
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON BuildPair

instance FromJSON BuildPair

data CaptureRole = BaselineCapture | CandidateCapture
  deriving stock (Eq, Ord, Show)

instance ToJSON CaptureRole where
  toJSON = Aeson.String . captureRoleToken

instance FromJSON CaptureRole where
  parseJSON = Aeson.withText "CaptureRole" $ parseToken "capture role" captureRoles

captureRoleToken :: CaptureRole -> Text
captureRoleToken = \case
  BaselineCapture -> "baseline"
  CandidateCapture -> "candidate"

captureRoles :: [(Text, CaptureRole)]
captureRoles = [(captureRoleToken role, role) | role <- [BaselineCapture, CandidateCapture]]

data CaseKind
  = HistoricalRead
  | SemanticEquivalence
  | OldReaderNewWriter
  | SnapshotReplay
  | ProcessManagerReplay
  | WorkflowReplay
  deriving stock (Eq, Ord, Show, Enum, Bounded)

instance ToJSON CaseKind where
  toJSON = Aeson.String . caseKindToken

instance FromJSON CaseKind where
  parseJSON = Aeson.withText "CaseKind" $ parseToken "case kind" caseKinds

caseKindToken :: CaseKind -> Text
caseKindToken = \case
  HistoricalRead -> "historical-read"
  SemanticEquivalence -> "semantic-equivalence"
  OldReaderNewWriter -> "old-reader-new-writer"
  SnapshotReplay -> "snapshot"
  ProcessManagerReplay -> "process-manager"
  WorkflowReplay -> "workflow"

caseKinds :: [(Text, CaseKind)]
caseKinds = [(caseKindToken kind, kind) | kind <- [minBound .. maxBound]]

data PersistedSurface = PersistedSurface
  { kind :: Text,
    owner :: Text,
    identity :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON PersistedSurface

instance FromJSON PersistedSurface

data RequiredCase = RequiredCase
  { caseId :: Text,
    caseKind :: CaseKind,
    surface :: PersistedSurface
  }
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON RequiredCase

instance FromJSON RequiredCase

-- | Every v1 inventory names all of these inputs. An input may explicitly be
-- not applicable, but it may not disappear merely because a candidate report
-- omitted its cases.
data InventorySource
  = BaselinePersistedSurfaces
  | CandidatePersistedSurfaces
  | OrdinaryCompatibilityFindings
  | AggregateReplayImpacts
  | MappedConsequences
  | CheckedProcessReactions
  | ApplicationOwnedObligations
  deriving stock (Eq, Ord, Show, Enum, Bounded)

inventorySourcesV1 :: [InventorySource]
inventorySourcesV1 = [minBound .. maxBound]

instance ToJSON InventorySource where
  toJSON = Aeson.String . inventorySourceToken

instance FromJSON InventorySource where
  parseJSON = Aeson.withText "InventorySource" $ parseToken "inventory source" inventorySources

inventorySourceToken :: InventorySource -> Text
inventorySourceToken = \case
  BaselinePersistedSurfaces -> "baseline-persisted-surfaces"
  CandidatePersistedSurfaces -> "candidate-persisted-surfaces"
  OrdinaryCompatibilityFindings -> "ordinary-compatibility-findings"
  AggregateReplayImpacts -> "aggregate-replay-impacts"
  MappedConsequences -> "mapped-consequences"
  CheckedProcessReactions -> "checked-process-reactions"
  ApplicationOwnedObligations -> "application-owned-obligations"

inventorySources :: [(Text, InventorySource)]
inventorySources = [(inventorySourceToken source, source) | source <- inventorySourcesV1]

data SourceApplicability
  = Applicable
  | NotApplicable Text
  | SourceUnverified Text
  deriving stock (Eq, Show)

instance ToJSON SourceApplicability where
  toJSON = \case
    Applicable -> Aeson.object ["status" Aeson..= ("applicable" :: Text)]
    NotApplicable reason -> Aeson.object ["status" Aeson..= ("not-applicable" :: Text), "reason" Aeson..= reason]
    SourceUnverified reason -> Aeson.object ["status" Aeson..= ("unverified" :: Text), "reason" Aeson..= reason]

instance FromJSON SourceApplicability where
  parseJSON = Aeson.withObject "SourceApplicability" $ \object -> do
    status <- object Aeson..: "status"
    case status :: Text of
      "applicable" -> pure Applicable
      "not-applicable" -> NotApplicable <$> object Aeson..: "reason"
      "unverified" -> SourceUnverified <$> object Aeson..: "reason"
      other -> fail ("unsupported inventory applicability: " <> Text.unpack other)

data InventoryContribution = InventoryContribution
  { source :: InventorySource,
    applicability :: SourceApplicability,
    cases :: [RequiredCase]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON InventoryContribution

instance FromJSON InventoryContribution

data EvidenceInventory = EvidenceInventory
  { inventoryVersion :: Text,
    inventoryId :: Text,
    buildPair :: BuildPair,
    contributions :: [InventoryContribution]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceInventory

instance FromJSON EvidenceInventory

data HighWaterMark = HighWaterMark
  { stream :: Text,
    revision :: Integer
  }
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON HighWaterMark

instance FromJSON HighWaterMark

data DeterminismInputs = DeterminismInputs
  { clock :: Text,
    randomness :: Text,
    externalResponsesHash :: Text,
    failureScheduleHash :: Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DeterminismInputs

instance FromJSON DeterminismInputs

-- | An observation is deliberately semantic. Artifact hashes may be included
-- as values, but they do not replace the durable state, continuation, or
-- identity coordinates which establish equivalence.
data Observation = Observation
  { durableState :: Map Text Value,
    continuations :: [Value],
    durableIdentities :: Map Text Text,
    freshAllocations :: [Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Observation

instance FromJSON Observation

data EvidenceVerdict
  = Passed
  | Failed Text
  | Unverified Text
  deriving stock (Eq, Show)

instance ToJSON EvidenceVerdict where
  toJSON = \case
    Passed -> Aeson.object ["status" Aeson..= ("passed" :: Text)]
    Failed reason -> Aeson.object ["status" Aeson..= ("failed" :: Text), "reason" Aeson..= reason]
    Unverified reason -> Aeson.object ["status" Aeson..= ("unverified" :: Text), "reason" Aeson..= reason]

instance FromJSON EvidenceVerdict where
  parseJSON = Aeson.withObject "EvidenceVerdict" $ \object -> do
    status <- object Aeson..: "status"
    case status :: Text of
      "passed" -> pure Passed
      "failed" -> Failed <$> object Aeson..: "reason"
      "unverified" -> Unverified <$> object Aeson..: "reason"
      other -> fail ("unsupported evidence verdict: " <> Text.unpack other)

data CaseResult = CaseResult
  { requiredCase :: RequiredCase,
    verdict :: EvidenceVerdict,
    observation :: Maybe Observation
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CaseResult

instance FromJSON CaseResult

data CaptureReport = CaptureReport
  { reportVersion :: Text,
    role :: CaptureRole,
    buildPair :: BuildPair,
    inventoryId :: Text,
    corpusHash :: Text,
    observationContractVersion :: Text,
    highWaterMarks :: [HighWaterMark],
    selectedSurfaces :: [PersistedSurface],
    determinismInputs :: DeterminismInputs,
    results :: [CaseResult]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CaptureReport

instance FromJSON CaptureReport

data CompatibilityFailure
  = UnsupportedInventoryVersion Text
  | UnsupportedReportVersion CaptureRole Text
  | WrongCaptureRole CaptureRole CaptureRole
  | BuildPairMismatch Text
  | InventoryIdentityMismatch CaptureRole
  | CorpusIdentityMismatch
  | ObservationContractMismatch
  | DeterminismInputMismatch
  | MissingInventorySource InventorySource
  | DuplicateInventorySource InventorySource
  | InvalidInventoryContribution InventorySource Text
  | ConflictingRequiredCase Text
  | MissingRequiredCase CaptureRole Text
  | DuplicateCaseResult CaptureRole Text
  | CaseDefinitionMismatch CaptureRole Text
  | RequiredCaseFailed CaptureRole Text Text
  | RequiredCaseUnverified CaptureRole Text Text
  | EmptyPassedObservation CaptureRole Text
  | ObservationMismatch Text
  | MissingSelectedSurface CaptureRole PersistedSurface
  | EmptyHighWaterMarks CaptureRole
  | DuplicateHighWaterMark CaptureRole Text
  | HighWaterMarkMismatch
  deriving stock (Eq, Show)

-- | Union the independently supplied inventory contributions. Identical cases
-- may be required by more than one source. Conflicting definitions are reported
-- by 'validateCompatibility'.
requiredCases :: EvidenceInventory -> Map Text RequiredCase
requiredCases inventory =
  Map.fromList
    [ (required.caseId, required)
    | contribution <- inventory.contributions,
      required <- contribution.cases
    ]

validateCompatibility :: EvidenceInventory -> CaptureReport -> CaptureReport -> [CompatibilityFailure]
validateCompatibility inventory baselineReport candidateReport =
  concat
    [ inventoryFailures inventory,
      reportMetadataFailures inventory BaselineCapture baselineReport,
      reportMetadataFailures inventory CandidateCapture candidateReport,
      pairedMetadataFailures baselineReport candidateReport,
      reportCaseFailures inventory baselineReport,
      reportCaseFailures inventory candidateReport,
      observationFailures inventory baselineReport candidateReport
    ]

releaseReady :: EvidenceInventory -> CaptureReport -> CaptureReport -> Bool
releaseReady inventory baselineReport candidateReport =
  null (validateCompatibility inventory baselineReport candidateReport)

inventoryFailures :: EvidenceInventory -> [CompatibilityFailure]
inventoryFailures inventory =
  versionFailure <> sourceFailures <> contributionFailures <> conflictFailures
  where
    versionFailure =
      [UnsupportedInventoryVersion inventory.inventoryVersion | inventory.inventoryVersion /= inventoryVersionV1]
    groupedSources = group (sort (map (.source) inventory.contributions))
    presentSources = Set.fromList (map (.source) inventory.contributions)
    sourceFailures =
      [MissingInventorySource source | source <- inventorySourcesV1, source `Set.notMember` presentSources]
        <> [DuplicateInventorySource source | source : remaining <- groupedSources, not (null remaining)]
    contributionFailures = concatMap validateContribution inventory.contributions
    byId =
      Map.fromListWith
        (++)
        [ (required.caseId, [required])
        | contribution <- inventory.contributions,
          required <- contribution.cases
        ]
    conflictFailures =
      [ ConflictingRequiredCase caseId
      | (caseId, definitions) <- Map.toList byId,
        Set.size (Set.fromList definitions) > 1
      ]

validateContribution :: InventoryContribution -> [CompatibilityFailure]
validateContribution contribution = case contribution.applicability of
  Applicable
    | null contribution.cases -> [InvalidInventoryContribution contribution.source "applicable source has no required cases"]
    | otherwise -> []
  NotApplicable reason
    | Text.null reason -> [InvalidInventoryContribution contribution.source "not-applicable source has no reason"]
    | not (null contribution.cases) -> [InvalidInventoryContribution contribution.source "not-applicable source supplies cases"]
    | otherwise -> []
  SourceUnverified reason ->
    [InvalidInventoryContribution contribution.source ("source is unverified: " <> reason)]

reportMetadataFailures :: EvidenceInventory -> CaptureRole -> CaptureReport -> [CompatibilityFailure]
reportMetadataFailures inventory expectedRole report =
  concat
    [ [UnsupportedReportVersion expectedRole report.reportVersion | report.reportVersion /= reportVersionV1],
      [WrongCaptureRole expectedRole report.role | report.role /= expectedRole],
      [BuildPairMismatch (captureRoleToken expectedRole) | report.buildPair /= inventory.buildPair],
      [InventoryIdentityMismatch expectedRole | report.inventoryId /= inventory.inventoryId],
      [EmptyHighWaterMarks expectedRole | null report.highWaterMarks],
      [DuplicateHighWaterMark expectedRole stream | stream <- duplicates (map (.stream) report.highWaterMarks)]
    ]

pairedMetadataFailures :: CaptureReport -> CaptureReport -> [CompatibilityFailure]
pairedMetadataFailures baselineReport candidateReport =
  concat
    [ [CorpusIdentityMismatch | baselineReport.corpusHash /= candidateReport.corpusHash],
      [ObservationContractMismatch | baselineReport.observationContractVersion /= candidateReport.observationContractVersion],
      [DeterminismInputMismatch | baselineReport.determinismInputs /= candidateReport.determinismInputs],
      [HighWaterMarkMismatch | Set.fromList baselineReport.highWaterMarks /= Set.fromList candidateReport.highWaterMarks]
    ]

reportCaseFailures :: EvidenceInventory -> CaptureReport -> [CompatibilityFailure]
reportCaseFailures inventory report =
  duplicateFailures <> concatMap checkRequired (Map.elems expected)
  where
    expected = requiredCases inventory
    role = report.role
    rowsById = Map.fromListWith (++) [(row.requiredCase.caseId, [row]) | row <- report.results]
    duplicateFailures = [DuplicateCaseResult role caseId | caseId <- duplicates (map (.requiredCase.caseId) report.results)]
    selected = Set.fromList report.selectedSurfaces
    checkRequired required = case Map.lookup required.caseId rowsById of
      Nothing -> [MissingRequiredCase role required.caseId]
      Just [] -> [MissingRequiredCase role required.caseId]
      Just (row : _) ->
        [CaseDefinitionMismatch role required.caseId | row.requiredCase /= required]
          <> [MissingSelectedSurface role required.surface | required.surface `Set.notMember` selected]
          <> verdictFailures role row

verdictFailures :: CaptureRole -> CaseResult -> [CompatibilityFailure]
verdictFailures role row = case row.verdict of
  Failed reason -> [RequiredCaseFailed role row.requiredCase.caseId reason]
  Unverified reason -> [RequiredCaseUnverified role row.requiredCase.caseId reason]
  Passed ->
    [ EmptyPassedObservation role row.requiredCase.caseId
    | maybe True observationIsEmpty row.observation
    ]

observationFailures :: EvidenceInventory -> CaptureReport -> CaptureReport -> [CompatibilityFailure]
observationFailures inventory baselineReport candidateReport =
  [ ObservationMismatch caseId
  | caseId <- Map.keys (requiredCases inventory),
    passedObservation caseId baselineReport /= passedObservation caseId candidateReport
  ]

passedObservation :: Text -> CaptureReport -> Maybe Observation
passedObservation caseId report = do
  row <- Map.lookup caseId (Map.fromList [(result.requiredCase.caseId, result) | result <- report.results])
  case row.verdict of
    Passed -> row.observation
    Failed _ -> Nothing
    Unverified _ -> Nothing

observationIsEmpty :: Observation -> Bool
observationIsEmpty observation =
  Map.null observation.durableState
    && null observation.continuations
    && Map.null observation.durableIdentities

duplicates :: (Ord a) => [a] -> [a]
duplicates values = [value | value : remaining <- group (sort values), not (null remaining)]

parseToken :: String -> [(Text, a)] -> Text -> Parser a
parseToken label tokens token =
  case lookup token tokens of
    Just value -> pure value
    Nothing -> fail ("unsupported " <> label <> ": " <> Text.unpack token)

renderCompatibilityFailure :: CompatibilityFailure -> Text
renderCompatibilityFailure = \case
  UnsupportedInventoryVersion version -> "unsupported inventory version: " <> version
  UnsupportedReportVersion role version -> captureRoleToken role <> " report has unsupported version: " <> version
  WrongCaptureRole expected actual -> "expected " <> captureRoleToken expected <> " capture, got " <> captureRoleToken actual
  BuildPairMismatch role -> role <> " report is not bound to the inventory build pair"
  InventoryIdentityMismatch role -> captureRoleToken role <> " report names a different inventory"
  CorpusIdentityMismatch -> "baseline and candidate corpus hashes differ"
  ObservationContractMismatch -> "baseline and candidate observation contracts differ"
  DeterminismInputMismatch -> "baseline and candidate determinism inputs differ"
  MissingInventorySource source -> "inventory omits source: " <> inventorySourceToken source
  DuplicateInventorySource source -> "inventory repeats source: " <> inventorySourceToken source
  InvalidInventoryContribution source reason -> inventorySourceToken source <> ": " <> reason
  ConflictingRequiredCase caseId -> "inventory gives conflicting definitions for case: " <> caseId
  MissingRequiredCase role caseId -> captureRoleToken role <> " report omits required case: " <> caseId
  DuplicateCaseResult role caseId -> captureRoleToken role <> " report repeats case: " <> caseId
  CaseDefinitionMismatch role caseId -> captureRoleToken role <> " report changes required case definition: " <> caseId
  RequiredCaseFailed role caseId reason -> captureRoleToken role <> " case failed (" <> caseId <> "): " <> reason
  RequiredCaseUnverified role caseId reason -> captureRoleToken role <> " case is unverified (" <> caseId <> "): " <> reason
  EmptyPassedObservation role caseId -> captureRoleToken role <> " case passed with an empty observation: " <> caseId
  ObservationMismatch caseId -> "baseline and candidate observations differ for case: " <> caseId
  MissingSelectedSurface role surface -> captureRoleToken role <> " report omits selected surface: " <> surface.owner <> "/" <> surface.identity
  EmptyHighWaterMarks role -> captureRoleToken role <> " report has no stream high-water marks"
  DuplicateHighWaterMark role stream -> captureRoleToken role <> " report repeats stream high-water mark: " <> stream
  HighWaterMarkMismatch -> "baseline and candidate high-water marks differ"
