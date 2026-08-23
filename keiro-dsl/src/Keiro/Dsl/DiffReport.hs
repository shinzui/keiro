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
    diffReportWithSemanticImpact,
    diffReportWithCoordinationImpact,
    diffReportWithImpacts,
    OwnedSite (..),
    WorkspaceChange (..),
    WorkspaceMeta (..),
    WorkspaceDiffReport,
    workspaceDiffReport,
    workspaceDiffReportWithSemanticImpact,
    workspaceDiffReportWithCoordinationImpact,
    workspaceDiffReportWithImpacts,
    remediationFor,
    renderRemedy,
    renderFinding,
    renderVectorLine,
    renderExplainBlock,
    renderSemanticImpact,
    renderCoordinationImpact,
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
import Keiro.Dsl.CoordinationImpact (CoordinationImpact (..), CoordinationSeverity (..), renderCoordinationImpact)
import Keiro.Dsl.Diff
import Keiro.Dsl.SemanticImpact (MappedImpactDelta (..), MappedRootEvidence (..), mappedConsequenceIdentity, mappedConsumerIdentity, mappedRootKindIdentity)
import Keiro.Dsl.TypeGraph (MappedKey (..))
import Keiro.Dsl.Validate (DiagnosticCode (..))

data Remedy
  = RemedyVersionBump
  | RemedyUpcaster
  | RemedyDeploymentOrder RolloutConstraint
  | RemedyContractRevision
  | RemedyReplayOnlyEdge
  | RemedyStateCodecBump
  | RemedyRecompileConsumers
  | RemedyRescaffoldGenerated
  | RemedyRescaffoldWorkspace
  | RemedyRunConformance
  | RemedyNoSemanticAction
  | RemedyDoNotDeploy Text
  | RemedyEmitContractTypeIdDomain
  | RemedyDrainLegacyInvalidContractMessages
  | RemedyRescaffoldContractConsumers
  | RemedyRunContractConformance
  | RemedyDrainWorkqueue
  | RemedyTransitionalQueueCodec
  deriving stock (Eq, Show)

data DiffReport = DiffReport
  { gate :: !(Set CompatibilitySurface),
    findings :: ![Change],
    semanticImpact :: !(Maybe [MappedImpactDelta]),
    coordinationImpact :: !(Maybe [CoordinationImpact])
  }
  deriving stock (Eq, Show)

diffReport :: Set CompatibilitySurface -> [Change] -> DiffReport
diffReport gate findings = DiffReport gate findings Nothing Nothing

-- | Add the append-only semantic-impact object used by current CLI reports.
-- The older smart constructor intentionally omits it for source compatibility.
diffReportWithSemanticImpact :: Set CompatibilitySurface -> [Change] -> [MappedImpactDelta] -> DiffReport
diffReportWithSemanticImpact gate findings impact = DiffReport gate findings (Just impact) Nothing

diffReportWithCoordinationImpact :: Set CompatibilitySurface -> [Change] -> [CoordinationImpact] -> DiffReport
diffReportWithCoordinationImpact gate findings impact = DiffReport gate findings Nothing (Just impact)

diffReportWithImpacts :: Set CompatibilitySurface -> [Change] -> [MappedImpactDelta] -> [CoordinationImpact] -> DiffReport
diffReportWithImpacts gate findings semantic coordination = DiffReport gate findings (Just semantic) (Just coordination)

-- | One source location from a composed workspace's ownership index.
data OwnedSite = OwnedSite
  { file :: !FilePath,
    line :: !Int
  }
  deriving stock (Eq, Show)

-- | A merged-graph finding enriched with declaration and use-site ownership.
data WorkspaceChange = WorkspaceChange
  { change :: !Change,
    declarationSite :: !(Maybe OwnedSite),
    useSites :: ![(Text, Maybe OwnedSite)]
  }
  deriving stock (Eq, Show)

-- | Provenance for the two workspace graphs compared by one command.
data WorkspaceMeta = WorkspaceMeta
  { identity :: !Text,
    manifest :: !FilePath,
    since :: !Text,
    membersOld :: ![FilePath],
    membersNew :: ![FilePath],
    adoptionBaseline :: !Bool
  }
  deriving stock (Eq, Show)

data WorkspaceDiffReport = WorkspaceDiffReport
  { meta :: !WorkspaceMeta,
    gate :: !(Set CompatibilitySurface),
    findings :: ![WorkspaceChange],
    semanticImpact :: !(Maybe [MappedImpactDelta]),
    coordinationImpact :: !(Maybe [CoordinationImpact])
  }
  deriving stock (Eq, Show)

workspaceDiffReport :: WorkspaceMeta -> Set CompatibilitySurface -> [WorkspaceChange] -> WorkspaceDiffReport
workspaceDiffReport meta gate findings = WorkspaceDiffReport meta gate findings Nothing Nothing

workspaceDiffReportWithSemanticImpact :: WorkspaceMeta -> Set CompatibilitySurface -> [WorkspaceChange] -> [MappedImpactDelta] -> WorkspaceDiffReport
workspaceDiffReportWithSemanticImpact meta gate findings impact = WorkspaceDiffReport meta gate findings (Just impact) Nothing

workspaceDiffReportWithCoordinationImpact :: WorkspaceMeta -> Set CompatibilitySurface -> [WorkspaceChange] -> [CoordinationImpact] -> WorkspaceDiffReport
workspaceDiffReportWithCoordinationImpact meta gate findings impact = WorkspaceDiffReport meta gate findings Nothing (Just impact)

workspaceDiffReportWithImpacts :: WorkspaceMeta -> Set CompatibilitySurface -> [WorkspaceChange] -> [MappedImpactDelta] -> [CoordinationImpact] -> WorkspaceDiffReport
workspaceDiffReportWithImpacts meta gate findings semantic coordination = WorkspaceDiffReport meta gate findings (Just semantic) (Just coordination)

instance ToJSON DiffReport where
  toJSON report =
    object $
      [ "schema" .= ("keiro-dsl/diff-report/1" :: Text),
        "gate" .= map surfaceName (Set.toAscList ((.gate) report)),
        "breaking" .= (any (gatedBreaking ((.gate) report)) ((.findings) report) || coordinationBreaking ((.coordinationImpact) report)),
        "findings" .= map (findingValue ((.gate) report)) ((.findings) report)
      ]
        <> ["semanticImpact" .= semanticImpactValue impact | Just impact <- [(.semanticImpact) report]]
        <> ["coordinationImpact" .= impact | Just impact <- [(.coordinationImpact) report]]

instance ToJSON WorkspaceDiffReport where
  toJSON report =
    object $
      [ "schema" .= ("keiro-dsl/diff-report/1" :: Text),
        "gate" .= map surfaceName (Set.toAscList ((.gate) report)),
        "breaking" .= (any (gatedBreaking ((.gate) report) . (.change)) ((.findings) report) || coordinationBreaking ((.coordinationImpact) report)),
        "findings" .= map (workspaceFindingValue ((.gate) report)) ((.findings) report),
        "workspace" .= workspaceMetaValue ((.meta) report)
      ]
        <> ["semanticImpact" .= semanticImpactValue impact | Just impact <- [(.semanticImpact) report]]
        <> ["coordinationImpact" .= impact | Just impact <- [(.coordinationImpact) report]]

semanticImpactValue :: [MappedImpactDelta] -> Value
semanticImpactValue impact = object ["declarations" .= impact]

coordinationBreaking :: Maybe [CoordinationImpact] -> Bool
coordinationBreaking = maybe False (any ((== CoordinationBreaking) . (.severity)))

-- | Human-facing semantic dependency summary, kept separate from ordinary
-- compatibility findings and generated-file evidence.
renderSemanticImpact :: [MappedImpactDelta] -> [Text]
renderSemanticImpact [] = []
renderSemanticImpact impact = "semantic impact:" : concatMap renderDelta impact
  where
    renderDelta delta =
      [ "  " <> (.unMappedKey) ((.declaration) delta),
        "    previous aggregate consumers: " <> renderBaseline ((.previousEvidence) delta) (renderConsumers ((.previousConsumers) delta)),
        "    current aggregate consumers:  " <> renderConsumers ((.currentConsumers) delta),
        "    previous roots: " <> maybe "baseline unavailable" renderEvidence ((.previousEvidence) delta),
        "    current roots:  " <> maybe "baseline unavailable" renderEvidence ((.currentEvidence) delta),
        "    previous consequences: " <> maybe "baseline unavailable" renderConsequences ((.previousConsequences) delta),
        "    current consequences:  " <> maybe "baseline unavailable" renderConsequences ((.currentConsequences) delta),
        "    service-conformance: " <> if (.serviceConformance) delta then "impacted" else "unchanged"
      ]
    renderConsumers aggregateConsumers = case map consumerName (Set.toAscList aggregateConsumers) of
      [] -> "(none)"
      names -> T.intercalate ", " names
    consumerName = mappedConsumerIdentity
    renderBaseline Nothing _ = "baseline unavailable"
    renderBaseline (Just _) value = value
    renderEvidence values = renderSet renderRoot values
    renderRoot evidence =
      T.intercalate "|" [mappedRootKindIdentity ((.rootKind) evidence), mappedConsumerIdentity ((.consumer) evidence), (.path) evidence]
        <> maybe "" ("|" <>) ((.operation) evidence)
    renderConsequences = renderSet mappedConsequenceIdentity
    renderSet render values = case map render (Set.toAscList values) of
      [] -> "(none)"
      rendered -> T.intercalate ", " rendered

findingValue :: Set CompatibilitySurface -> Change -> Value
findingValue gate change = object (findingPairs gate change)

workspaceFindingValue :: Set CompatibilitySurface -> WorkspaceChange -> Value
workspaceFindingValue gate workspaceChange =
  object
    ( findingPairs gate ((.change) workspaceChange)
        <> maybe [] (\site -> ["declaration" .= ownedSiteValue site]) ((.declarationSite) workspaceChange)
        <> ["useSites" .= map useSiteValue ((.useSites) workspaceChange) | not (null ((.useSites) workspaceChange))]
    )

findingPairs :: Set CompatibilitySurface -> Change -> [Pair]
findingPairs gate change =
  [ "label" .= labelName (deriveLabel gate ((.vector) kind)),
    "node" .= (.node) kind,
    "facet" .= (.facet) kind,
    "subject" .= (.subject) kind,
    "code" .= T.pack (show ((.code) kind)),
    "paths" .= (.paths) kind,
    "vector" .= vectorValue ((.vector) kind),
    "detail" .= (.detail) kind,
    "remedies" .= map renderRemedy (NonEmpty.toList (remediationFor ((.context) kind) ((.code) kind)))
  ]
    <> ["mappedPersistedSurface" .= mappedPersistedImpactValue impact | Just impact <- [(.mappedPersistedImpact) kind]]
    <> ["mappedConsequences" .= map mappedConsequenceIdentity (Set.toAscList ((.mappedConsequences) kind)) | not (Set.null ((.mappedConsequences) kind))]
  where
    kind = changeKind change

ownedSiteValue :: OwnedSite -> Value
ownedSiteValue site = object ["file" .= (.file) site, "line" .= (.line) site]

useSiteValue :: (Text, Maybe OwnedSite) -> Value
useSiteValue (path, site) =
  object
    ( ["path" .= path]
        <> maybe [] (\owned -> ["file" .= (.file) owned, "line" .= (.line) owned]) site
    )

mappedPersistedImpactValue :: MappedPersistedImpact -> Value
mappedPersistedImpactValue impact =
  object
    [ "surface" .= persistedSurfaceName ((.surface) impact),
      "verdict" .= verdictName ((.verdict) impact)
    ]

persistedSurfaceName :: MappedPersistedSurface -> Text
persistedSurfaceName PrivateEventHistory = "private-event-history"
persistedSurfaceName SnapshotCache = "snapshot-cache"
persistedSurfaceName (WorkqueueHistory name) = "workqueue-history:" <> name

workspaceMetaValue :: WorkspaceMeta -> Value
workspaceMetaValue meta =
  object
    [ "identity" .= (.identity) meta,
      "manifest" .= (.manifest) meta,
      "since" .= (.since) meta,
      "membersOld" .= (.membersOld) meta,
      "membersNew" .= (.membersNew) meta,
      "adoptionBaseline" .= (.adoptionBaseline) meta
    ]

vectorValue :: CompatibilityVector -> Value
vectorValue vector =
  object
    [ "private-history-read" .= verdictName ((.privateHistoryRead) vector),
      "old-binary-read-new-events" .= verdictName ((.oldBinaryReadNewEvents) vector),
      "snapshot-hydration" .= verdictName ((.snapshotHydration) vector),
      "public-consumer" .= verdictName ((.publicConsumer) vector),
      "persisted-identity" .= verdictName ((.persistedIdentity) vector),
      "consumer-build" .= verdictName ((.consumerBuild) vector),
      "rollout" .= map rolloutName (Set.toAscList ((.rollout) vector))
    ]

remediationFor :: ChangeContext -> DiagnosticCode -> NonEmpty Remedy
remediationFor context code
  | code == SourceLanguageDeclarationChanged = RemedyNoSemanticAction :| []
  | code == GeneratedHaskellNameChanged = RemedyRescaffoldGenerated :| [RemedyRecompileConsumers, RemedyRunConformance]
  | code == OwnershipMoved = RemedyRescaffoldWorkspace :| []
  | code == WorkspaceAuthorityChanged = RemedyRescaffoldWorkspace :| [RemedyRecompileConsumers]
  | code == AggGuardTightened = RemedyReplayOnlyEdge :| [RemedyRunConformance]
  | code == AggFoldSurfaceChanged = RemedyStateCodecBump :| [RemedyRunConformance]
  | code == IdDomainContractChanged =
      RemedyDeploymentOrder RolloutProducerLast :| [RemedyStateCodecBump, RemedyRecompileConsumers, RemedyRunConformance]
  | code == ContractTypeIdDomainChanged =
      RemedyEmitContractTypeIdDomain
        :| [ RemedyDrainLegacyInvalidContractMessages,
             RemedyRescaffoldContractConsumers,
             RemedyRunContractConformance
           ]
  | code == CatalogCheckpointPolicyChanged =
      RemedyDeploymentOrder RolloutStopTheWorld
        :| [RemedyRescaffoldGenerated, RemedyRecompileConsumers, RemedyRunConformance]
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
      RemedyDeploymentOrder RolloutWorkersFirst :| [RemedyDrainWorkqueue, RemedyTransitionalQueueCodec, RemedyRunConformance]
  | code `elem` identityCodes =
      RemedyDoNotDeploy "revert the re-keying change or perform an explicit operational identity migration" :| []
  | code == EnumCtorAdded = case Set.toAscList ((.rollout) vector) of
      rollout : _ -> RemedyDeploymentOrder rollout :| [snapshotRemedy]
      [] -> snapshotRemedy :| []
  | (.consumerBuild) vector `elem` [VAdvisory, VBreaking] =
      RemedyRecompileConsumers :| [RemedyRunConformance]
  | Just rollout <- firstRollout = RemedyDeploymentOrder rollout :| [RemedyRunConformance]
  | (.snapshotHydration) vector == VAdvisory = RemedyStateCodecBump :| [RemedyRunConformance]
  | otherwise = RemedyRunConformance :| []
  where
    vector = classifyCompatibility context code
    firstRollout = case Set.toAscList ((.rollout) vector) of
      rollout : _ -> Just rollout
      [] -> Nothing
    snapshotRemedy
      | (.snapshotHydration) vector == VAdvisory = RemedyStateCodecBump
      | otherwise = RemedyRunConformance
    mappedWireRemedy
      | Set.member RolloutDrainRequired ((.rollout) vector) = queueMappedRemedy
      | (.privateHistoryRead) vector == VBreaking =
          RemedyVersionBump :| [RemedyUpcaster, RemedyDeploymentOrder RolloutStopTheWorld]
      | (.snapshotHydration) vector == VAdvisory = RemedyStateCodecBump :| [RemedyRunConformance]
      | otherwise = RemedyRecompileConsumers :| [RemedyRunConformance]
    mappedAdditionRemedy
      | (.snapshotHydration) vector == VAdvisory = RemedyStateCodecBump :| [RemedyRunConformance]
      | Set.member RolloutDrainRequired ((.rollout) vector) = queueMappedRemedy
      | Just rollout <- firstRollout = RemedyDeploymentOrder rollout :| [RemedyRunConformance]
      | otherwise = RemedyRunConformance :| []
    mappedConformanceRemedy
      | (.snapshotHydration) vector == VAdvisory = RemedyRunConformance :| [RemedyStateCodecBump]
      | Set.member RolloutDrainRequired ((.rollout) vector) = queueMappedRemedy
      | otherwise = RemedyRunConformance :| []
    queueMappedRemedy =
      RemedyDeploymentOrder RolloutWorkersFirst
        :| [RemedyDrainWorkqueue, RemedyTransitionalQueueCodec, RemedyRecompileConsumers, RemedyRunConformance]
    mappedSnapshotConformanceRemedy
      | (.snapshotHydration) vector == VAdvisory = RemedyStateCodecBump :| [RemedyRunConformance]
      | otherwise = RemedyRunConformance :| []
    mappedCanonicalRemedy
      | (.snapshotHydration) vector == VAdvisory = RemedyStateCodecBump :| [RemedyRecompileConsumers, RemedyRunConformance]
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
        EvtFieldWireKeyChanged,
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
  RemedyRescaffoldGenerated -> "re-run the scaffold so generated modules and create-once imports use the candidate Haskell names"
  RemedyRescaffoldWorkspace -> "re-run the whole-workspace scaffold so the record's ownership and golden roots follow the change"
  RemedyRunConformance -> "run the generated conformance and historical fixture suites"
  RemedyNoSemanticAction -> "no semantic action is required; only source-language provenance changed"
  RemedyDoNotDeploy detail -> detail
  RemedyEmitContractTypeIdDomain -> "make all producers emit the frozen TypeID-v7 domain"
  RemedyDrainLegacyInvalidContractMessages -> "drain or remediate legacy-invalid in-flight messages"
  RemedyRescaffoldContractConsumers -> "re-scaffold and recompile every affected consumer against the generated interface"
  RemedyRunContractConformance -> "run contract conformance"
  RemedyDrainWorkqueue -> "drain incompatible queued jobs before deployment"
  RemedyTransitionalQueueCodec -> "supply an application-owned transitional queue codec when draining is impossible"

renderFinding :: Change -> Text
renderFinding change =
  headline
    <> vectorDetail
    <> persistedDetail
    <> consequenceDetail
  where
    kind = changeKind change
    headline =
      headlineName change
        <> ": "
        <> (.node) kind
        <> " "
        <> (.facet) kind
        <> " "
        <> (.subject) kind
        <> ": "
        <> (.detail) kind
        <> codeSuffix change kind
    vectorDetail
      | vectorIsUniform ((.vector) kind) = ""
      | otherwise = "\n" <> renderVectorLine ((.vector) kind)
    persistedDetail = case (.mappedPersistedImpact) kind of
      Nothing -> ""
      Just impact ->
        "\n    mapped-persisted-surface: "
          <> persistedSurfaceName ((.surface) impact)
          <> "="
          <> verdictName ((.verdict) impact)
    consequenceDetail
      | Set.null ((.mappedConsequences) kind) = ""
      | otherwise =
          "\n    mapped-consequences: "
            <> T.intercalate ", " (map mappedConsequenceIdentity (Set.toAscList ((.mappedConsequences) kind)))

renderVectorLine :: CompatibilityVector -> Text
renderVectorLine vector =
  "    vector: "
    <> T.unwords
      ( [ surfaceName surface <> "=" <> verdictName verdict
        | surface <- [minBound .. maxBound],
          let verdict = verdictFor surface vector,
          verdict /= VNotApplicable
        ]
          <> ["rollout=" <> T.intercalate "," (map rolloutName (Set.toAscList ((.rollout) vector))) | not (Set.null ((.rollout) vector))]
      )

renderExplainBlock :: Change -> Text
renderExplainBlock change =
  "explain ["
    <> T.pack (show ((.code) kind))
    <> "]\n"
    <> T.unlines ["  path: " <> path | path <- (.paths) kind]
    <> T.unlines (map ("  direction: " <>) directions)
    <> T.unlines ["  remedy: " <> renderRemedy remedy | remedy <- NonEmpty.toList remedies]
  where
    kind = changeKind change
    vector = (.vector) kind
    directions =
      [ surfaceName surface <> " is " <> verdictName verdict <> "; " <> directionMeaning surface verdict
      | surface <- [minBound .. maxBound],
        let verdict = verdictFor surface vector,
        verdict `elem` [VAdvisory, VBreaking]
      ]
    remedies = remediationFor ((.context) kind) ((.code) kind)

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
  RolloutProducerFirst -> "producer-first"

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
codeSuffix _ kind = " [" <> T.pack (show ((.code) kind)) <> "]"

changeKind :: Change -> ChangeKind
changeKind (Additive kind) = kind
changeKind (Advisory kind) = kind
changeKind (Breaking kind) = kind

vectorIsUniform :: CompatibilityVector -> Bool
vectorIsUniform vector =
  Set.null ((.rollout) vector)
    && all (`elem` [VCompatible, VNotApplicable]) [verdictFor surface vector | surface <- [minBound .. maxBound]]

directionMeaning :: CompatibilitySurface -> SurfaceVerdict -> Text
directionMeaning surface verdict = case (surface, verdict) of
  (PrivateHistoryRead, _) -> "the candidate binary may reinterpret or fail to read stored private history"
  (OldBinaryReadNewEvents, _) -> "a still-running old binary may reject events emitted by the candidate"
  (SnapshotHydration, _) -> "persisted snapshot seeds require invalidation or rebuild"
  (PublicConsumer, _) -> "an independently deployed consumer may reject the candidate contract"
  (PersistedIdentity, _) -> "replay or retry may derive a different persisted identity"
  (ConsumerBuild, _) -> "consumer or generated source must be rebuilt"
