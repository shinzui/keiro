-- | Pure rendering and JSON encoding for compatibility-vector diff reports.
--
-- The JSON schema identifier is @keiro-dsl/diff-report/1@.  Consumers must
-- ignore unknown object keys.  Vector keys and entries in the @paths@ array are
-- append-only so later nested type-expression work can refine findings without
-- invalidating version-1 readers. Workspace inputs add a top-level @workspace@
-- object and optional per-finding @declaration@ and @useSites@ keys; single-file
-- reports keep their original bytes.
module Keiro.Dsl.DiffReport
  ( Remedy (..),
    DiffReport,
    diffReport,
    OwnedSite (..),
    WorkspaceChange (..),
    WorkspaceMeta (..),
    WorkspaceDiffReport,
    workspaceDiffReport,
    remediationFor,
    renderRemedy,
    renderFinding,
    renderVectorLine,
    renderExplainBlock,
    surfaceName,
    parseSurfaceName,
    verdictName,
    rolloutName,
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson.Types (Pair)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Diff
import Keiro.Dsl.Validate (DiagnosticCode (..))

data Remedy
  = RemedyVersionBump
  | RemedyUpcaster
  | RemedyDeploymentOrder RolloutConstraint
  | RemedyContractRevision
  | RemedyReplayOnlyEdge
  | RemedyStateCodecBump
  | RemedyRecompileConsumers
  | RemedyRescaffoldWorkspace
  | RemedyRunConformance
  | RemedyNoSemanticAction
  | RemedyDoNotDeploy Text
  deriving stock (Eq, Show)

data DiffReport = DiffReport
  { reportGate :: !(Set CompatibilitySurface),
    reportFindings :: ![Change]
  }
  deriving stock (Eq, Show)

diffReport :: Set CompatibilitySurface -> [Change] -> DiffReport
diffReport = DiffReport

-- | One source location from a composed workspace's ownership index.
data OwnedSite = OwnedSite
  { osFile :: !FilePath,
    osLine :: !Int
  }
  deriving stock (Eq, Show)

-- | A merged-graph finding enriched with declaration and use-site ownership.
data WorkspaceChange = WorkspaceChange
  { wcChange :: !Change,
    wcDeclarationSite :: !(Maybe OwnedSite),
    wcUseSites :: ![(Text, Maybe OwnedSite)]
  }
  deriving stock (Eq, Show)

-- | Provenance for the two workspace graphs compared by one command.
data WorkspaceMeta = WorkspaceMeta
  { wmIdentity :: !Text,
    wmManifest :: !FilePath,
    wmSince :: !Text,
    wmMembersOld :: ![FilePath],
    wmMembersNew :: ![FilePath],
    wmAdoptionBaseline :: !Bool
  }
  deriving stock (Eq, Show)

data WorkspaceDiffReport = WorkspaceDiffReport
  { workspaceReportMeta :: !WorkspaceMeta,
    workspaceReportGate :: !(Set CompatibilitySurface),
    workspaceReportFindings :: ![WorkspaceChange]
  }
  deriving stock (Eq, Show)

workspaceDiffReport :: WorkspaceMeta -> Set CompatibilitySurface -> [WorkspaceChange] -> WorkspaceDiffReport
workspaceDiffReport = WorkspaceDiffReport

instance ToJSON DiffReport where
  toJSON report =
    object
      [ "schema" .= ("keiro-dsl/diff-report/1" :: Text),
        "gate" .= map surfaceName (Set.toAscList (reportGate report)),
        "breaking" .= any (gatedBreaking (reportGate report)) (reportFindings report),
        "findings" .= map (findingValue (reportGate report)) (reportFindings report)
      ]

instance ToJSON WorkspaceDiffReport where
  toJSON report =
    object
      [ "schema" .= ("keiro-dsl/diff-report/1" :: Text),
        "gate" .= map surfaceName (Set.toAscList (workspaceReportGate report)),
        "breaking" .= any (gatedBreaking (workspaceReportGate report) . wcChange) (workspaceReportFindings report),
        "findings" .= map (workspaceFindingValue (workspaceReportGate report)) (workspaceReportFindings report),
        "workspace" .= workspaceMetaValue (workspaceReportMeta report)
      ]

findingValue :: Set CompatibilitySurface -> Change -> Value
findingValue gate change = object (findingPairs gate change)

workspaceFindingValue :: Set CompatibilitySurface -> WorkspaceChange -> Value
workspaceFindingValue gate workspaceChange =
  object
    ( findingPairs gate (wcChange workspaceChange)
        <> maybe [] (\site -> ["declaration" .= ownedSiteValue site]) (wcDeclarationSite workspaceChange)
        <> ["useSites" .= map useSiteValue (wcUseSites workspaceChange) | not (null (wcUseSites workspaceChange))]
    )

findingPairs :: Set CompatibilitySurface -> Change -> [Pair]
findingPairs gate change =
  [ "label" .= labelName (deriveLabel gate (ckVector kind)),
    "node" .= ckNode kind,
    "facet" .= ckFacet kind,
    "subject" .= ckSubject kind,
    "code" .= T.pack (show (ckCode kind)),
    "paths" .= ckPaths kind,
    "vector" .= vectorValue (ckVector kind),
    "detail" .= ckDetail kind,
    "remedies" .= map renderRemedy (NonEmpty.toList (remediationFor (ckContext kind) (ckCode kind)))
  ]
  where
    kind = changeKind change

ownedSiteValue :: OwnedSite -> Value
ownedSiteValue site = object ["file" .= osFile site, "line" .= osLine site]

useSiteValue :: (Text, Maybe OwnedSite) -> Value
useSiteValue (path, site) =
  object
    ( ["path" .= path]
        <> maybe [] (\owned -> ["file" .= osFile owned, "line" .= osLine owned]) site
    )

workspaceMetaValue :: WorkspaceMeta -> Value
workspaceMetaValue meta =
  object
    [ "identity" .= wmIdentity meta,
      "manifest" .= wmManifest meta,
      "since" .= wmSince meta,
      "membersOld" .= wmMembersOld meta,
      "membersNew" .= wmMembersNew meta,
      "adoptionBaseline" .= wmAdoptionBaseline meta
    ]

vectorValue :: CompatibilityVector -> Value
vectorValue vector =
  object
    [ "private-history-read" .= verdictName (cvPrivateHistoryRead vector),
      "old-binary-read-new-events" .= verdictName (cvOldBinaryReadNewEvents vector),
      "snapshot-hydration" .= verdictName (cvSnapshotHydration vector),
      "public-consumer" .= verdictName (cvPublicConsumer vector),
      "persisted-identity" .= verdictName (cvPersistedIdentity vector),
      "consumer-build" .= verdictName (cvConsumerBuild vector),
      "rollout" .= map rolloutName (Set.toAscList (cvRollout vector))
    ]

remediationFor :: ChangeContext -> DiagnosticCode -> NonEmpty Remedy
remediationFor context code
  | code == SourceLanguageDeclarationChanged = RemedyNoSemanticAction :| []
  | code == OwnershipMoved = RemedyRescaffoldWorkspace :| []
  | code == WorkspaceAuthorityChanged = RemedyRescaffoldWorkspace :| [RemedyRecompileConsumers]
  | code == AggGuardTightened = RemedyReplayOnlyEdge :| [RemedyRunConformance]
  | code == AggFoldSurfaceChanged = RemedyStateCodecBump :| [RemedyRunConformance]
  | code `elem` mappedWireCodes = mappedWireRemedy
  | code `elem` [MappedFieldAddedWithDefault, MappedArmAdded, MappedEnumValueAdded] = mappedAdditionRemedy
  | code `elem` [MappedHaskellSourceChanged, MappedRecordConstructorChanged] =
      RemedyRecompileConsumers :| [RemedyRunConformance]
  | code == MappedBindingChanged = mappedConformanceRemedy
  | code == MappedFixturesChanged = RemedyRunConformance :| []
  | code == MappedInitialChanged = mappedSnapshotConformanceRemedy
  | code == MappedCanonicalTypeChanged = mappedCanonicalRemedy
  | code == MappedDeclAdded = RemedyRunConformance :| []
  | code `elem` eventDecodeCodes =
      RemedyVersionBump :| [RemedyUpcaster, RemedyDeploymentOrder RolloutStopTheWorld]
  | code `elem` contractCodes =
      RemedyContractRevision :| [RemedyDeploymentOrder RolloutProducerLast]
  | code `elem` queueCodes =
      RemedyDeploymentOrder RolloutWorkersFirst :| [RemedyRunConformance]
  | code `elem` identityCodes =
      RemedyDoNotDeploy "revert the re-keying change or perform an explicit operational identity migration" :| []
  | code == EnumCtorAdded = case Set.toAscList (cvRollout vector) of
      rollout : _ -> RemedyDeploymentOrder rollout :| [snapshotRemedy]
      [] -> snapshotRemedy :| []
  | cvConsumerBuild vector `elem` [VAdvisory, VBreaking] =
      RemedyRecompileConsumers :| [RemedyRunConformance]
  | Just rollout <- firstRollout = RemedyDeploymentOrder rollout :| [RemedyRunConformance]
  | cvSnapshotHydration vector == VAdvisory = RemedyStateCodecBump :| [RemedyRunConformance]
  | otherwise = RemedyRunConformance :| []
  where
    vector = classifyCompatibility context code
    firstRollout = case Set.toAscList (cvRollout vector) of
      rollout : _ -> Just rollout
      [] -> Nothing
    snapshotRemedy
      | cvSnapshotHydration vector == VAdvisory = RemedyStateCodecBump
      | otherwise = RemedyRunConformance
    mappedWireRemedy
      | cvPrivateHistoryRead vector == VBreaking =
          RemedyVersionBump :| [RemedyUpcaster, RemedyDeploymentOrder RolloutStopTheWorld]
      | cvSnapshotHydration vector == VAdvisory = RemedyStateCodecBump :| [RemedyRunConformance]
      | otherwise = RemedyRecompileConsumers :| [RemedyRunConformance]
    mappedAdditionRemedy
      | cvSnapshotHydration vector == VAdvisory = RemedyStateCodecBump :| [RemedyRunConformance]
      | Just rollout <- firstRollout = RemedyDeploymentOrder rollout :| [RemedyRunConformance]
      | otherwise = RemedyRunConformance :| []
    mappedConformanceRemedy
      | cvSnapshotHydration vector == VAdvisory = RemedyRunConformance :| [RemedyStateCodecBump]
      | otherwise = RemedyRunConformance :| []
    mappedSnapshotConformanceRemedy
      | cvSnapshotHydration vector == VAdvisory = RemedyStateCodecBump :| [RemedyRunConformance]
      | otherwise = RemedyRunConformance :| []
    mappedCanonicalRemedy
      | cvSnapshotHydration vector == VAdvisory = RemedyStateCodecBump :| [RemedyRecompileConsumers, RemedyRunConformance]
      | otherwise = RemedyRecompileConsumers :| [RemedyRunConformance]
    mappedWireCodes =
      [ MappedFieldAddedNoDefault,
        MappedFieldRemoved,
        MappedFieldTypeChanged,
        MappedPresenceChanged,
        MappedNullabilityChanged,
        MappedDefaultRemoved,
        MappedDefaultChanged,
        MappedWireKeyChanged,
        MappedUnionEncodingChanged,
        MappedArmRemoved,
        MappedArmTagChanged,
        MappedEnumValueRemoved,
        MappedEnumSpellingChanged,
        MappedOpaqueCodecChanged,
        MappedModeCrossed,
        MappedDeclRemoved
      ]
    eventDecodeCodes =
      [ EvtFieldAddedWithoutBump,
        EvtFieldRemovedSameVersion,
        EvtFieldTypeChanged,
        EvtVersionDecreased,
        EvtVersionMissingUpcaster,
        UpcasterChainGap,
        EvtRemovedNotDeprecated,
        EnumCtorRemoved,
        EnumWireSpellingChanged,
        WireSpecChanged,
        ProcessInputChanged,
        WorkflowShapeChanged,
        WorkflowBodyChanged,
        WorkflowPatchRemoved,
        WorkflowContinueSeedChanged
      ]
    contractCodes =
      [ ContractEventRemoved,
        ContractFieldChanged,
        ContractDiscriminatorChanged,
        ContractTopicChanged,
        ContractSchemaVersionDecreased,
        ContractSchemaVersionBumped
      ]
    queueCodes = [WqPayloadFieldChanged, WqOrderingChanged, WqProvisionChanged, WqGroupKeyChanged, QueueIdentityChanged]
    identityCodes =
      [ DerivedIdentityChanged,
        IdPrefixChanged,
        DedupeIdentityChanged,
        RouterStableNameChanged,
        WorkflowStableNameChanged,
        ReadModelVersionDecreased,
        ReadModelShapeChangedWithoutBump,
        ReadModelFeedChanged,
        ReadModelConsistencyWeakened
      ]

renderRemedy :: Remedy -> Text
renderRemedy remedy = case remedy of
  RemedyVersionBump -> "bump the owning schema or event version"
  RemedyUpcaster -> "add and retain a contiguous upcaster for every historical version"
  RemedyDeploymentOrder rollout -> "deploy in " <> rolloutName rollout <> " order"
  RemedyContractRevision -> "revise the independently owned public contract"
  RemedyReplayOnlyEdge -> "add the computed replay-only edge described by docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md"
  RemedyStateCodecBump -> "invalidate and rebuild snapshots by bumping state-codec version when automatic fingerprinting cannot see the change"
  RemedyRecompileConsumers -> "recompile every affected consumer against the generated interface"
  RemedyRescaffoldWorkspace -> "re-run the whole-workspace scaffold so the record's ownership and golden roots follow the change"
  RemedyRunConformance -> "run the generated conformance and historical fixture suites"
  RemedyNoSemanticAction -> "no semantic action is required; only source-language provenance changed"
  RemedyDoNotDeploy detail -> detail

renderFinding :: Change -> Text
renderFinding change =
  headline
    <> if vectorIsUniform (ckVector kind)
      then ""
      else "\n" <> renderVectorLine (ckVector kind)
  where
    kind = changeKind change
    headline =
      headlineName change
        <> ": "
        <> ckNode kind
        <> " "
        <> ckFacet kind
        <> " "
        <> ckSubject kind
        <> ": "
        <> ckDetail kind
        <> codeSuffix change kind

renderVectorLine :: CompatibilityVector -> Text
renderVectorLine vector =
  "    vector: "
    <> T.unwords
      ( [ surfaceName surface <> "=" <> verdictName verdict
        | surface <- [minBound .. maxBound],
          let verdict = verdictFor surface vector,
          verdict /= VNotApplicable
        ]
          <> ["rollout=" <> T.intercalate "," (map rolloutName (Set.toAscList (cvRollout vector))) | not (Set.null (cvRollout vector))]
      )

renderExplainBlock :: Change -> Text
renderExplainBlock change =
  "explain ["
    <> T.pack (show (ckCode kind))
    <> "]\n"
    <> T.unlines ["  path: " <> path | path <- ckPaths kind]
    <> T.unlines (map ("  direction: " <>) directions)
    <> T.unlines ["  remedy: " <> renderRemedy remedy | remedy <- NonEmpty.toList remedies]
  where
    kind = changeKind change
    vector = ckVector kind
    directions =
      [ surfaceName surface <> " is " <> verdictName verdict <> "; " <> directionMeaning surface verdict
      | surface <- [minBound .. maxBound],
        let verdict = verdictFor surface vector,
        verdict `elem` [VAdvisory, VBreaking]
      ]
    remedies = remediationFor (ckContext kind) (ckCode kind)

surfaceName :: CompatibilitySurface -> Text
surfaceName surface = case surface of
  PrivateHistoryRead -> "private-history-read"
  OldBinaryReadNewEvents -> "old-binary-read-new-events"
  SnapshotHydration -> "snapshot-hydration"
  PublicConsumer -> "public-consumer"
  PersistedIdentity -> "persisted-identity"
  ConsumerBuild -> "consumer-build"

parseSurfaceName :: String -> Either String CompatibilitySurface
parseSurfaceName raw = case lookup (T.pack raw) [(surfaceName surface, surface) | surface <- [minBound .. maxBound]] of
  Just surface -> Right surface
  Nothing ->
    Left
      ( "unknown compatibility surface '"
          <> raw
          <> "'; expected one of: "
          <> T.unpack (T.intercalate ", " (map surfaceName [minBound .. maxBound]))
      )

verdictName :: SurfaceVerdict -> Text
verdictName verdict = case verdict of
  VCompatible -> "compatible"
  VAdvisory -> "advisory"
  VBreaking -> "breaking"
  VNotApplicable -> "n/a"

rolloutName :: RolloutConstraint -> Text
rolloutName rollout = case rollout of
  RolloutStopTheWorld -> "stop-the-world"
  RolloutWorkersFirst -> "workers-first"
  RolloutDrainRequired -> "drain-required"
  RolloutProducerLast -> "producer-last"

labelName :: Label -> Text
labelName label = case label of
  LabelAdditive -> "additive"
  LabelAdvisory -> "warning"
  LabelBreaking -> "breaking"

headlineName :: Change -> Text
headlineName Additive {} = "ADDITIVE"
headlineName Advisory {} = "WARNING"
headlineName Breaking {} = "BREAKING"

codeSuffix :: Change -> ChangeKind -> Text
codeSuffix Additive {} _ = ""
codeSuffix _ kind = " [" <> T.pack (show (ckCode kind)) <> "]"

changeKind :: Change -> ChangeKind
changeKind (Additive kind) = kind
changeKind (Advisory kind) = kind
changeKind (Breaking kind) = kind

vectorIsUniform :: CompatibilityVector -> Bool
vectorIsUniform vector =
  Set.null (cvRollout vector)
    && all (`elem` [VCompatible, VNotApplicable]) [verdictFor surface vector | surface <- [minBound .. maxBound]]

directionMeaning :: CompatibilitySurface -> SurfaceVerdict -> Text
directionMeaning surface verdict = case (surface, verdict) of
  (PrivateHistoryRead, _) -> "the candidate binary may reinterpret or fail to read stored private history"
  (OldBinaryReadNewEvents, _) -> "a still-running old binary may reject events emitted by the candidate"
  (SnapshotHydration, _) -> "persisted snapshot seeds require invalidation or rebuild"
  (PublicConsumer, _) -> "an independently deployed consumer may reject the candidate contract"
  (PersistedIdentity, _) -> "replay or retry may derive a different persisted identity"
  (ConsumerBuild, _) -> "consumer or generated source must be rebuilt"
