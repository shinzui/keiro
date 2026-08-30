-- | The service evolution differ compares an /old/ and a /new/ checked graph
-- and classifies changes over the persisted decode and identity surfaces.
--
-- Changes are __ADDITIVE__ when they preserve stored data, __WARNING__ when they
-- change forward behaviour without invalidating persisted data, and __BREAKING__
-- when stored payloads may stop decoding or persisted identities may be re-keyed.
-- The @diff --since@ CLI exits non-zero only when a breaking change is present.
--
-- Every 'Node' constructor maps to a 'NodeFamily', and 'familyRegistry' contains
-- exactly one entry for each family.  A family is either handled by an explicit
-- differ or carries a non-empty out-of-scope rationale.  This makes omissions
-- visible when the grammar grows instead of silently treating new node kinds as
-- safe.
module Keiro.Dsl.Diff
  ( Change (..),
    ChangeKind (..),
    Label (..),
    CompatibilitySurface (..),
    SurfaceVerdict (..),
    RolloutConstraint (..),
    CompatibilityVector (..),
    MappedPersistedSurface (..),
    MappedPersistedImpact (..),
    ChangeContext,
    changeContextRoot,
    changeContextPaths,
    privateEventContext,
    privateEventAdditionContext,
    snapshotContext,
    queueContext,
    publicContractContext,
    persistedIdentityContext,
    consumerBuildContext,
    advisoryAt,
    classifyCompatibility,
    verdictFor,
    defaultGate,
    gateWith,
    deriveLabel,
    gatedBreaking,
    isBreaking,
    isAdvisory,
    diffSources,
    sourceLanguageChange,
    diffServices,
    mappedSemanticImpact,
    mappedSemanticImpactForServices,
    DiffEnv (..),
    NodeFamily (..),
    familyOf,
    FamilyDiff (..),
    familyRegistry,
    Paired (..),
    pairByName,
    readModelDiff,
    classifyWorkflowBody,
  )
where

import Data.Char (toUpper)
import Data.Foldable (traverse_)
import Data.List (find, sort, (\\))
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing, mapMaybe, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.AggregateType (typeExprCanonicalName)
import Keiro.Dsl.CanonicalEncoding (canonicalDomainOutcomeTypes, canonicalTransition, canonicalTransitionOutcome)
import Keiro.Dsl.FieldIdentity
  ( ResolvedFieldIdentity (..),
    resolveAggregateFieldIdentity,
    resolveContractFieldIdentity,
  )
import Keiro.Dsl.FoldFingerprint (FoldSurfaceError, aggregateFoldSurfaceForService)
import Keiro.Dsl.Grammar
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.IdDomain (IdDomainContract (..), contractIdDomainContractFor, idDomainContractFor)
import Keiro.Dsl.LanguageVersion (ParsedSource (..), SourceLanguage, declaredLanguageVersionMaybe, languageVersionText, sourceFormText)
import Keiro.Dsl.MappedDiff (MappedFinding (..), diffMapped, renderMappedSubject)
import Keiro.Dsl.PrettyPrint
  ( renderHandleSurface,
    renderResolveSurface,
    renderRouterDispatchSurface,
    renderTimerPayloadSurface,
    renderTransition,
    renderTypeExpr,
  )
import Keiro.Dsl.ProjectionMappedImpact qualified as ProjectionImpact
import Keiro.Dsl.ProjectionSupply
import Keiro.Dsl.ReadModelShape (registryNameFor, subscriptionNameFor)
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract, checkedLanguageContract, checkedSource, checkedSpec, effectiveLanguageContract, effectiveRuntimeSemantics, legacyCheckedService)
import Keiro.Dsl.SemanticImpact (MappedConsequence (..), MappedConsumer (..), MappedImpactDelta (..), MappedQueryPosition (..), diffSemanticImpact, mappedConsumerIdentity, mappedImpactForDeclarations, semanticImpact, semanticImpactForService, semanticImpactSnapshot)
import Keiro.Dsl.TypeGraph (DerivedMappedConsumer (..), MappedKey (..), UsePath (..), UseSite (..), renderUsePath, resolveTypeGraph)
import Keiro.Dsl.Validate (DiagnosticCode (..))

-- | A classified spec change.
data Change
  = Additive ChangeKind
  | Advisory ChangeKind
  | Breaking ChangeKind
  deriving stock (Eq, Show)

-- | The stable headline classification retained by the text interface.
data Label = LabelAdditive | LabelAdvisory | LabelBreaking
  deriving stock (Eq, Show)

-- | Independently gateable compatibility questions for one finding.
data CompatibilitySurface
  = PrivateHistoryRead
  | OldBinaryReadNewEvents
  | SnapshotHydration
  | PublicConsumer
  | PersistedIdentity
  | ConsumerBuild
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A verdict on one surface.  Constructor order is deliberately not policy.
data SurfaceVerdict = VCompatible | VAdvisory | VBreaking | VNotApplicable
  deriving stock (Eq, Show)

-- | Deployment ordering that remains after byte compatibility is classified.
data RolloutConstraint
  = RolloutStopTheWorld
  | RolloutWorkersFirst
  | RolloutDrainRequired
  | RolloutProducerLast
  | RolloutProducerFirst
  deriving stock (Eq, Ord, Show)

-- | The explicit, compile-forcing compatibility result for one finding.
data CompatibilityVector = CompatibilityVector
  { privateHistoryRead :: !SurfaceVerdict,
    oldBinaryReadNewEvents :: !SurfaceVerdict,
    snapshotHydration :: !SurfaceVerdict,
    publicConsumer :: !SurfaceVerdict,
    persistedIdentity :: !SurfaceVerdict,
    consumerBuild :: !SurfaceVerdict,
    rollout :: !(Set RolloutConstraint)
  }
  deriving stock (Eq, Show)

-- | Persisted mapped payloads that must not be conflated merely because the
-- compatibility vector predates first-class queue history.
data MappedPersistedSurface
  = PrivateEventHistory
  | SnapshotCache
  | WorkqueueHistory !Name
  deriving stock (Eq, Ord, Show)

data MappedPersistedImpact = MappedPersistedImpact
  { surface :: !MappedPersistedSurface,
    verdict :: !SurfaceVerdict
  }
  deriving stock (Eq, Show)

data ContextKind
  = ContextGeneral
  | ContextPrivateEvent
  | ContextPrivateEventAddition
  | ContextSnapshot
  | ContextQueue
  | ContextPublicContract
  | ContextPersistedIdentity
  | ContextConsumerBuild
  deriving stock (Eq, Show)

-- | Facts that select a compatibility row.  The constructor stays private so
-- callers cannot manufacture contradictory ownership and surface claims.
data ChangeContext = ChangeContext
  { root :: !Name,
    paths :: ![Text],
    contextKind :: !ContextKind,
    contextOriginalLabel :: !Label
  }
  deriving stock (Eq, Show)

changeContextRoot :: ChangeContext -> Name
changeContextRoot = (.root)

changeContextPaths :: ChangeContext -> [Text]
changeContextPaths = (.paths)

data ChangeKind = ChangeKind
  { node :: !Name,
    facet :: !Text,
    subject :: !Text,
    code :: !DiagnosticCode,
    context :: !ChangeContext,
    vector :: !CompatibilityVector,
    mappedPersistedImpact :: !(Maybe MappedPersistedImpact),
    mappedConsequences :: !(Set MappedConsequence),
    paths :: ![Text],
    detail :: !Text
  }
  deriving stock (Eq, Show)

privateEventContext :: Name -> [Text] -> ChangeContext
privateEventContext root paths = ChangeContext root paths ContextPrivateEvent LabelBreaking

privateEventAdditionContext :: Name -> [Text] -> ChangeContext
privateEventAdditionContext root paths = ChangeContext root paths ContextPrivateEventAddition LabelAdvisory

snapshotContext :: Name -> [Text] -> ChangeContext
snapshotContext root paths = ChangeContext root paths ContextSnapshot LabelAdvisory

queueContext :: Name -> [Text] -> ChangeContext
queueContext root paths = ChangeContext root paths ContextQueue LabelBreaking

publicContractContext :: Name -> [Text] -> ChangeContext
publicContractContext root paths = ChangeContext root paths ContextPublicContract LabelBreaking

persistedIdentityContext :: Name -> [Text] -> ChangeContext
persistedIdentityContext root paths = ChangeContext root paths ContextPersistedIdentity LabelBreaking

consumerBuildContext :: Name -> [Text] -> ChangeContext
consumerBuildContext root paths = ChangeContext root paths ContextConsumerBuild LabelAdvisory

compatibleVector :: CompatibilityVector
compatibleVector =
  CompatibilityVector
    VCompatible
    VCompatible
    VNotApplicable
    VNotApplicable
    VNotApplicable
    VNotApplicable
    Set.empty

sourceProvenanceVector :: CompatibilityVector
sourceProvenanceVector =
  CompatibilityVector
    VCompatible
    VCompatible
    VCompatible
    VCompatible
    VCompatible
    VCompatible
    Set.empty

privateDecodeBreakingVector :: CompatibilityVector
privateDecodeBreakingVector =
  CompatibilityVector
    VBreaking
    VBreaking
    VAdvisory
    VNotApplicable
    VNotApplicable
    VNotApplicable
    (Set.singleton RolloutStopTheWorld)

persistedIdentityBreakingVector :: CompatibilityVector
persistedIdentityBreakingVector =
  CompatibilityVector
    VNotApplicable
    VNotApplicable
    VNotApplicable
    VNotApplicable
    VBreaking
    VNotApplicable
    Set.empty

publicBreakingVector :: CompatibilityVector
publicBreakingVector =
  CompatibilityVector
    VNotApplicable
    VNotApplicable
    VNotApplicable
    VBreaking
    VNotApplicable
    VNotApplicable
    (Set.singleton RolloutProducerLast)

queueBreakingVector :: CompatibilityVector
queueBreakingVector =
  CompatibilityVector
    VNotApplicable
    VNotApplicable
    VNotApplicable
    VNotApplicable
    VNotApplicable
    VBreaking
    (Set.fromList [RolloutWorkersFirst, RolloutDrainRequired])

catalogCheckpointPolicyVector :: CompatibilityVector
catalogCheckpointPolicyVector =
  CompatibilityVector
    VCompatible
    VCompatible
    VNotApplicable
    VNotApplicable
    VCompatible
    VBreaking
    (Set.singleton RolloutStopTheWorld)

advisoryVector :: CompatibilitySurface -> Set RolloutConstraint -> CompatibilityVector
advisoryVector surface rollout =
  CompatibilityVector
    { privateHistoryRead = verdict PrivateHistoryRead,
      oldBinaryReadNewEvents = verdict OldBinaryReadNewEvents,
      snapshotHydration = verdict SnapshotHydration,
      publicConsumer = verdict PublicConsumer,
      persistedIdentity = verdict PersistedIdentity,
      consumerBuild = verdict ConsumerBuild,
      rollout
    }
  where
    verdict candidate
      | candidate == surface = VAdvisory
      | otherwise = verdictFor candidate compatibleVector

replaceConsumerBuild :: SurfaceVerdict -> CompatibilityVector -> CompatibilityVector
replaceConsumerBuild consumerBuild vector =
  CompatibilityVector
    vector.privateHistoryRead
    vector.oldBinaryReadNewEvents
    vector.snapshotHydration
    vector.publicConsumer
    vector.persistedIdentity
    consumerBuild
    vector.rollout

replaceSnapshotHydration :: SurfaceVerdict -> CompatibilityVector -> CompatibilityVector
replaceSnapshotHydration snapshotHydration vector =
  CompatibilityVector
    vector.privateHistoryRead
    vector.oldBinaryReadNewEvents
    snapshotHydration
    vector.publicConsumer
    vector.persistedIdentity
    vector.consumerBuild
    vector.rollout

replaceRollout :: Set RolloutConstraint -> CompatibilityVector -> CompatibilityVector
replaceRollout rollout vector =
  CompatibilityVector
    vector.privateHistoryRead
    vector.oldBinaryReadNewEvents
    vector.snapshotHydration
    vector.publicConsumer
    vector.persistedIdentity
    vector.consumerBuild
    rollout

replaceOldBinaryAndRollout :: SurfaceVerdict -> Set RolloutConstraint -> CompatibilityVector -> CompatibilityVector
replaceOldBinaryAndRollout oldBinaryReadNewEvents rollout vector =
  CompatibilityVector
    vector.privateHistoryRead
    oldBinaryReadNewEvents
    vector.snapshotHydration
    vector.publicConsumer
    vector.persistedIdentity
    vector.consumerBuild
    rollout

-- | Classify one code at an explicitly owned use site.  Codes emitted by the
-- differ are grouped by their actual persisted/public surface; the context is
-- load-bearing for codes such as 'EnumCtorAdded' that vary by use site.
classifyCompatibility :: ChangeContext -> DiagnosticCode -> CompatibilityVector
classifyCompatibility context code
  | code == SourceLanguageDeclarationChanged = sourceProvenanceVector
  | code == GeneratedHaskellNameChanged = replaceConsumerBuild VAdvisory sourceProvenanceVector
  | code `elem` [OwnershipMoved, WorkspaceAuthorityChanged] = mappedBuildVector
  | code `elem` [ReadModelQueryInputChanged, ReadModelQueryResultChanged] =
      replaceConsumerBuild VBreaking compatibleVector
  | code == MappedFieldAddedWithDefault = mappedFieldAdditionVector context
  | code `elem` [MappedArmAdded, MappedEnumValueAdded] = mappedDirectionalAdditionVector context
  | code `elem` mappedWireBreakingCodes = mappedWireBreakingVector context
  | code `elem` [MappedHaskellSourceChanged, MappedRecordConstructorChanged, MappedFixturesChanged] = mappedBuildVector
  | code == MappedBindingChanged = mappedBindingVector context
  | code `elem` [MappedInitialChanged, MappedCanonicalTypeChanged] = mappedSnapshotBuildVector context
  | code == NominalFixturesChanged = mappedBuildVector
  | code == NominalBindingChanged = mappedBindingVector context
  | code `elem` [NominalInitialChanged, NominalCanonicalTypeChanged] = mappedSnapshotBuildVector context
  | code == NominalRepresentationChanged = mappedWireBreakingVector context
  | code == NominalIdDecoderTightened =
      replaceConsumerBuild VAdvisory (advisoryVector PrivateHistoryRead Set.empty)
  | code == ContractTypeIdDomainChanged = contractTypeIdDomainVector
  | code == IdDomainContractChanged = idDomainContractVector
  | code == MappedDeclAdded = compatibleVector
  | code `elem` privateDecodeCodes = privateDecodeBreakingVector
  | code `elem` identityCodes = persistedIdentityBreakingVector
  | code `elem` publicBreakingCodes = publicBreakingVector
  | code `elem` queueBreakingCodes = queueBreakingVector
  | code `elem` readModelBreakingCodes = persistedIdentityBreakingVector
  | code `elem` catalogIdentityCodes = persistedIdentityBreakingVector
  | code `elem` catalogReplayCodes = privateDecodeBreakingVector
  | code == CatalogCheckpointPolicyChanged = catalogCheckpointPolicyVector
  | code `elem` [ProjectionDeliveryChanged, QueryFreshnessChanged] = persistedIdentityBreakingVector
  | code == CatalogHandlerOrderChanged =
      replaceConsumerBuild VAdvisory (advisoryVector PrivateHistoryRead Set.empty)
  | code == ContractSchemaVersionBumped = advisoryVector PublicConsumer (Set.singleton RolloutProducerLast)
  | code == AggFoldSurfaceChanged =
      replaceSnapshotHydration VAdvisory (advisoryVector PrivateHistoryRead Set.empty)
  | code == AggGuardTightened = advisoryVector PrivateHistoryRead Set.empty
  | code `elem` [RouterDecideSurfaceChanged, ProcessDecideSurfaceChanged] =
      replaceRollout (Set.singleton RolloutDrainRequired) compatibleVector
  | code == ProcessTimerPayloadChanged = advisoryVector PrivateHistoryRead (Set.singleton RolloutProducerLast)
  | code == TimerWindowChanged = advisoryVector PrivateHistoryRead Set.empty
  | code == ProjectionChanged = advisoryVector PersistedIdentity Set.empty
  | code == EmitMappingChanged = advisoryVector PublicConsumer (Set.singleton RolloutProducerLast)
  | code == DecodePostureChanged = advisoryVector PublicConsumer Set.empty
  | code == IntakePersistenceChanged = advisoryVector PrivateHistoryRead Set.empty
  | code `elem` [PublisherPolicyChanged, DispatchRetargeted] = advisoryVector PersistedIdentity Set.empty
  | code `elem` [DeprecatedEventReplayHazard, EventRetirementInProgress] = advisoryVector PrivateHistoryRead Set.empty
  | code == EventUndeprecated = advisoryVector OldBinaryReadNewEvents (Set.singleton RolloutProducerLast)
  | code == EnumCtorAdded = case (.contextKind) context of
      ContextPrivateEventAddition ->
        replaceOldBinaryAndRollout VBreaking (Set.singleton RolloutProducerLast) compatibleVector
      ContextSnapshot -> advisoryVector SnapshotHydration Set.empty
      _ -> compatibleVector
  | code `elem` additiveCodes = compatibleVector
  | otherwise = case (.contextOriginalLabel) context of
      LabelAdditive -> compatibleVector
      LabelAdvisory -> advisoryVector (surfaceForContext context) Set.empty
      LabelBreaking -> breakingVectorForContext context
  where
    privateDecodeCodes =
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

    identityCodes =
      [ DerivedIdentityChanged,
        IdPrefixChanged,
        DedupeIdentityChanged,
        QueueIdentityChanged,
        RouterStableNameChanged,
        WorkflowStableNameChanged
      ]
    publicBreakingCodes =
      [ ContractEventRemoved,
        ContractFieldChanged,
        ContractDiscriminatorChanged,
        ContractTopicChanged,
        ContractSchemaVersionDecreased
      ]
    queueBreakingCodes = [WqPayloadFieldChanged, WqOrderingChanged, WqProvisionChanged, WqGroupKeyChanged]
    readModelBreakingCodes =
      [ ReadModelVersionDecreased,
        ReadModelShapeChangedWithoutBump,
        ReadModelFeedChanged,
        ReadModelConsistencyWeakened
      ]
    catalogIdentityCodes =
      [ CatalogTargetRemoved,
        CatalogTargetLocationChanged,
        CatalogTargetDependencyChanged,
        CatalogGroupChanged,
        CatalogOwnerRemoved,
        CatalogFeedIdentityChanged,
        CatalogQueryBindingChanged,
        ProjectionDeliveryChanged,
        QueryFreshnessChanged
      ]
    catalogReplayCodes = [CatalogSourceChanged, CatalogReplayPolicyChanged]
    additiveCodes =
      [ DeclarationAdded,
        VersionBumped,
        CompatibilityStrengthened,
        EventRetirementAbandoned,
        ContractEventAdded,
        ContractTopicAdded,
        WorkflowEvolutionGuardAdded
      ]

idDomainContractVector :: CompatibilityVector
idDomainContractVector =
  CompatibilityVector
    { privateHistoryRead = VCompatible,
      oldBinaryReadNewEvents = VCompatible,
      snapshotHydration = VAdvisory,
      publicConsumer = VBreaking,
      persistedIdentity = VCompatible,
      consumerBuild = VAdvisory,
      rollout = Set.singleton RolloutProducerLast
    }

contractTypeIdDomainVector :: CompatibilityVector
contractTypeIdDomainVector =
  CompatibilityVector
    { privateHistoryRead = VNotApplicable,
      oldBinaryReadNewEvents = VNotApplicable,
      snapshotHydration = VNotApplicable,
      publicConsumer = VBreaking,
      persistedIdentity = VNotApplicable,
      consumerBuild = VBreaking,
      rollout = Set.fromList [RolloutDrainRequired, RolloutProducerFirst]
    }

mappedWireBreakingCodes :: [DiagnosticCode]
mappedWireBreakingCodes =
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

mappedFieldAdditionVector :: ChangeContext -> CompatibilityVector
mappedFieldAdditionVector context = case (.contextKind) context of
  ContextPrivateEvent ->
    replaceOldBinaryAndRollout oldBinaryVerdict rollout compatibleVector
    where
      rejectsUnknown = (.contextOriginalLabel) context == LabelBreaking
      oldBinaryVerdict = if rejectsUnknown then VBreaking else VCompatible
      rollout = if rejectsUnknown then Set.singleton RolloutProducerLast else Set.empty
  ContextSnapshot -> mappedSnapshotVector
  ContextQueue -> queueBreakingVector
  ContextConsumerBuild -> mappedBuildVector
  _ -> compatibleVector

mappedDirectionalAdditionVector :: ChangeContext -> CompatibilityVector
mappedDirectionalAdditionVector context = case (.contextKind) context of
  ContextPrivateEvent ->
    replaceOldBinaryAndRollout VBreaking (Set.singleton RolloutProducerLast) compatibleVector
  ContextSnapshot -> mappedSnapshotVector
  ContextQueue -> queueBreakingVector
  ContextConsumerBuild -> mappedBuildVector
  _ -> compatibleVector

mappedWireBreakingVector :: ChangeContext -> CompatibilityVector
mappedWireBreakingVector context = case (.contextKind) context of
  ContextPrivateEvent ->
    CompatibilityVector
      VBreaking
      VBreaking
      VNotApplicable
      VNotApplicable
      VNotApplicable
      VNotApplicable
      (Set.singleton RolloutStopTheWorld)
  ContextSnapshot -> mappedSnapshotVector
  ContextQueue -> queueBreakingVector
  ContextConsumerBuild -> mappedBuildVector
  _ -> mappedBuildVector

mappedBuildVector :: CompatibilityVector
mappedBuildVector =
  CompatibilityVector
    VCompatible
    VCompatible
    VNotApplicable
    VNotApplicable
    VNotApplicable
    VAdvisory
    Set.empty

mappedSnapshotVector :: CompatibilityVector
mappedSnapshotVector =
  CompatibilityVector
    VCompatible
    VCompatible
    VAdvisory
    VNotApplicable
    VNotApplicable
    VNotApplicable
    Set.empty

mappedBindingVector :: ChangeContext -> CompatibilityVector
mappedBindingVector context = case (.contextKind) context of
  ContextPrivateEvent ->
    CompatibilityVector
      VAdvisory
      VAdvisory
      VNotApplicable
      VNotApplicable
      VNotApplicable
      VAdvisory
      Set.empty
  ContextSnapshot ->
    replaceConsumerBuild VAdvisory mappedSnapshotVector
  ContextQueue -> queueBreakingVector
  _ -> mappedBuildVector

mappedSnapshotBuildVector :: ChangeContext -> CompatibilityVector
mappedSnapshotBuildVector context = case (.contextKind) context of
  ContextSnapshot -> replaceConsumerBuild VAdvisory mappedSnapshotVector
  _ -> mappedBuildVector

surfaceForContext :: ChangeContext -> CompatibilitySurface
surfaceForContext context = case (.contextKind) context of
  ContextPrivateEvent -> PrivateHistoryRead
  ContextPrivateEventAddition -> OldBinaryReadNewEvents
  ContextSnapshot -> SnapshotHydration
  ContextQueue -> PrivateHistoryRead
  ContextPublicContract -> PublicConsumer
  ContextPersistedIdentity -> PersistedIdentity
  ContextConsumerBuild -> ConsumerBuild
  ContextGeneral -> PrivateHistoryRead

breakingVectorForContext :: ChangeContext -> CompatibilityVector
breakingVectorForContext context = case (.contextKind) context of
  ContextPublicContract -> publicBreakingVector
  ContextPersistedIdentity -> persistedIdentityBreakingVector
  ContextQueue -> queueBreakingVector
  ContextConsumerBuild -> (advisoryVector ConsumerBuild Set.empty) {consumerBuild = VBreaking}
  _ -> privateDecodeBreakingVector

verdictFor :: CompatibilitySurface -> CompatibilityVector -> SurfaceVerdict
verdictFor surface vector = case surface of
  PrivateHistoryRead -> (.privateHistoryRead) vector
  OldBinaryReadNewEvents -> (.oldBinaryReadNewEvents) vector
  SnapshotHydration -> (.snapshotHydration) vector
  PublicConsumer -> (.publicConsumer) vector
  PersistedIdentity -> (.persistedIdentity) vector
  ConsumerBuild -> (.consumerBuild) vector

defaultGate :: Set CompatibilitySurface
defaultGate = Set.delete OldBinaryReadNewEvents (Set.fromList [minBound .. maxBound])

gateWith :: [CompatibilitySurface] -> Set CompatibilitySurface
gateWith surfaces = defaultGate <> Set.fromList surfaces

deriveLabel :: Set CompatibilitySurface -> CompatibilityVector -> Label
deriveLabel gate vector
  | any ((== VBreaking) . (`verdictFor` vector)) (Set.toList gate) = LabelBreaking
  | any (`elem` [VAdvisory, VBreaking]) verdicts || not (Set.null ((.rollout) vector)) = LabelAdvisory
  | otherwise = LabelAdditive
  where
    verdicts = [verdictFor surface vector | surface <- [minBound .. maxBound]]

gatedBreaking :: Set CompatibilitySurface -> Change -> Bool
gatedBreaking gate change = deriveLabel gate ((.vector) (changeKind change)) == LabelBreaking

changeKind :: Change -> ChangeKind
changeKind (Additive kind) = kind
changeKind (Advisory kind) = kind
changeKind (Breaking kind) = kind

isBreaking :: Change -> Bool
isBreaking (Breaking _) = True
isBreaking (Additive _) = False
isBreaking (Advisory _) = False

isAdvisory :: Change -> Bool
isAdvisory (Advisory _) = True
isAdvisory (Additive _) = False
isAdvisory (Breaking _) = False

-- | Both specs supplied to a node-family differ, always old then new.
data DiffEnv = DiffEnv
  { old :: !Spec,
    new :: !Spec
  }
  deriving stock (Eq, Show)

-- | The closed set of node families currently present in 'Node'.
data NodeFamily
  = FamAggregate
  | FamProcess
  | FamRouter
  | FamContract
  | FamIntake
  | FamEmit
  | FamPublisher
  | FamWorkqueue
  | FamPgmqDispatch
  | FamReadModel
  | FamProjectionTarget
  | FamRebuildGroup
  | FamProjectionRevision
  | FamExternalRead
  | FamProjectionOwner
  | FamWorkflow
  | FamOperation
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Total by construction: one explicit arm per 'Node' constructor.
familyOf :: Node -> NodeFamily
familyOf (NAggregate _) = FamAggregate
familyOf (NProcess _) = FamProcess
familyOf (NRouter _) = FamRouter
familyOf (NContract _) = FamContract
familyOf (NIntake _) = FamIntake
familyOf (NEmit _) = FamEmit
familyOf (NPublisher _) = FamPublisher
familyOf (NWorkqueue _) = FamWorkqueue
familyOf (NPgmqDispatch _) = FamPgmqDispatch
familyOf (NReadModel _) = FamReadModel
familyOf (NProjectionTarget _) = FamProjectionTarget
familyOf (NRebuildGroup _) = FamRebuildGroup
familyOf (NProjectionRevision _) = FamProjectionRevision
familyOf (NExternalRead _) = FamExternalRead
familyOf (NProjectionOwner _) = FamProjectionOwner
familyOf (NWorkflow _) = FamWorkflow
familyOf (NOperation _) = FamOperation

-- | A family either has a differ or an explicit reason it is not compared.
data FamilyDiff
  = DiffFamily (DiffEnv -> [Change])
  | OutOfDiffScope Text

-- | Pair the old and new declarations of one node family by stable name.
data Paired n = Paired
  { matched :: ![(n, n)],
    added :: ![n],
    removed :: ![n]
  }
  deriving stock (Eq, Show)

pairByName :: (Node -> Maybe n) -> (n -> Name) -> DiffEnv -> Paired n
pairByName project nameOf env =
  Paired
    { matched =
        [ (oldNode, newNode)
        | newNode <- newNodes,
          Just oldNode <- [find ((== nameOf newNode) . nameOf) oldNodes]
        ],
      added =
        [ newNode
        | newNode <- newNodes,
          isNothing (find ((== nameOf newNode) . nameOf) oldNodes)
        ],
      removed =
        [ oldNode
        | oldNode <- oldNodes,
          isNothing (find ((== nameOf oldNode) . nameOf) newNodes)
        ]
    }
  where
    oldNodes = mapMaybe project ((.nodes) ((.old) env))
    newNodes = mapMaybe project ((.nodes) ((.new) env))

-- | Registry invariant: every 'Node' constructor maps to a family via the
-- total 'familyOf' case, and every family occurs exactly once here.  The unit
-- suite enforces registry coverage and non-empty out-of-scope rationales.
familyRegistry :: [(NodeFamily, FamilyDiff)]
familyRegistry =
  [ (FamAggregate, DiffFamily aggregateDiff),
    (FamProcess, DiffFamily processDiff),
    (FamRouter, DiffFamily routerDiff),
    (FamContract, DiffFamily contractDiff),
    (FamIntake, DiffFamily intakeDiff),
    (FamEmit, DiffFamily emitDiff),
    (FamPublisher, DiffFamily publisherDiff),
    (FamWorkqueue, DiffFamily workqueueDiff),
    (FamPgmqDispatch, DiffFamily pgmqDispatchDiff),
    (FamReadModel, DiffFamily readModelDiff),
    (FamProjectionTarget, DiffFamily projectionTargetDiff),
    (FamRebuildGroup, DiffFamily rebuildGroupDiff),
    (FamProjectionRevision, DiffFamily projectionRevisionDiff),
    (FamExternalRead, DiffFamily externalReadDiff),
    (FamProjectionOwner, DiffFamily projectionOwnerDiff),
    (FamWorkflow, DiffFamily workflowDiff),
    (FamOperation, OutOfDiffScope "operations own no persisted decode or identity surface; their references and workflow signal/await pairing are single-spec validation concerns")
  ]

-- | Compare two graphs under their effective semantic contracts. The ordinary
-- graph differ runs first; service-aware admission and fold findings then expose
-- semantic-profile changes that leave the normalized graph itself unchanged.
diffServices :: CheckedService -> CheckedService -> Either FoldSurfaceError [Change]
diffServices oldService newService = do
  traverse_ (aggregateFoldSurfaceForService oldService . snd) oldAggregates
  traverse_ (aggregateFoldSurfaceForService newService . snd) newAggregates
  semanticContractFoldChanges <- fmap concat (traverse semanticContractFoldChange oldAggregates)
  pure (diffCheckedSpecs oldSpec newSpec <> idDomainContractChanges <> contractTypeIdDomainChanges <> semanticContractFoldChanges)
  where
    oldSpec = checkedSpec oldService
    newSpec = checkedSpec newService
    oldAggregates = [((.name) aggregate, aggregate) | NAggregate aggregate <- (.nodes) oldSpec]
    newAggregates = [((.name) aggregate, aggregate) | NAggregate aggregate <- (.nodes) newSpec]
    idDomainContractChanges =
      [ breaking
          ((.name) newDeclaration)
          "id-domain-contract"
          ((.name) newDeclaration)
          IdDomainContractChanged
          ( "ID admission contract changed "
              <> renderIdDomainContract oldContract
              <> " -> "
              <> renderIdDomainContract newContract
              <> "; public construction, command decoding, current JSON codecs, and literals use the new contract; historical event replay retains its legacy decoder; old snapshots miss and rebuild from readable events, while rebuilt state that still contains legacy-invalid text remains intentionally uncacheable until overwritten or explicitly migrated"
          )
      | newDeclaration <- (.ids) newSpec,
        Just oldDeclaration <- [find ((== (.name) newDeclaration) . (.name)) ((.ids) oldSpec)],
        let oldContract = idDomainContractFor (checkedLanguageContract oldService) ((.prefix) oldDeclaration),
        let newContract = idDomainContractFor (checkedLanguageContract newService) ((.prefix) newDeclaration),
        oldContract /= newContract
      ]
    contractTypeIdDomainChanges =
      [ breaking
          ((.name) newContract)
          "contract-typeid-domain"
          ((.name) newEvent <> "." <> (.name) newField)
          ContractTypeIdDomainChanged
          ( renderContractIdDomainChange
              ((.valueType) newField)
              oldContract
              newContract'
          )
      | newContract <- [contract | NContract contract <- (.nodes) newSpec],
        Just oldContractNode <- [find ((== (.name) newContract) . (.name)) [contract | NContract contract <- (.nodes) oldSpec]],
        newEvent <- (.events) newContract,
        Just oldEvent <- [find ((== (.name) newEvent) . (.name)) ((.events) oldContractNode)],
        newField <- (.fields) newEvent,
        Just oldField <- [find ((== (.name) newField) . (.name)) ((.fields) oldEvent)],
        (.valueType) oldField == (.valueType) newField,
        let oldContract = contractFieldIdDomain (checkedLanguageContract oldService) oldField,
        let newContract' = contractFieldIdDomain (checkedLanguageContract newService) newField,
        oldContract /= newContract'
      ]
    semanticContractFoldChange (name, oldAggregate) = case lookup name newAggregates of
      Nothing -> pure []
      Just newAggregate -> do
        oldLegacySurface <- aggregateFoldSurfaceForService (legacyCheckedService oldSpec) oldAggregate
        newLegacySurface <- aggregateFoldSurfaceForService (legacyCheckedService newSpec) newAggregate
        oldSurface <- aggregateFoldSurfaceForService oldService oldAggregate
        newSurface <- aggregateFoldSurfaceForService newService newAggregate
        pure
          [ advisory
              name
              "semantic-contract"
              name
              AggFoldSurfaceChanged
              "effective runtime semantics changed the aggregate fold surface even though the normalized graph is unchanged; re-scaffold, redeploy, and audit replay under the candidate contract"
          | oldLegacySurface == newLegacySurface,
            oldSurface /= newSurface
          ]

renderIdDomainContract :: Maybe IdDomainContract -> Text
renderIdDomainContract Nothing = "legacy-unchecked"
renderIdDomainContract (Just contract) =
  idDomainVersion contract <> "(prefix=" <> idDomainPrefix contract <> ",json=" <> idDomainJsonRepresentation contract <> ")"

contractFieldIdDomain :: EffectiveLanguageContract -> ContractField -> Maybe IdDomainContract
contractFieldIdDomain languageContract field = case (.valueType) field of
  CTypeId prefix -> contractIdDomainContractFor languageContract prefix
  _ -> Nothing

renderContractIdDomainChange :: ContractType -> Maybe IdDomainContract -> Maybe IdDomainContract -> Text
renderContractIdDomainChange valueType oldContract newContract =
  "contract TypeID admission changed "
    <> renderIdDomainContract oldContract
    <> " -> "
    <> renderIdDomainContract newContract
    <> representationChange
  where
    prefix = case valueType of
      CTypeId value -> value
      _ -> ""
    representationChange = case (oldContract, newContract) of
      (Nothing, Just _) ->
        "; generated Haskell changes from Text to KindID \""
          <> prefix
          <> "\" while valid JSON stays canonical text; newly generated consumers reject malformed, wrong-prefix, non-canonical, and non-v7 values"
      (Just _, Nothing) ->
        "; generated Haskell changes from KindID \""
          <> prefix
          <> "\" to Text and the generated decoder no longer enforces the frozen TypeID-v7 domain"
      _ -> "; generated contract admission changed while the source field type remained unchanged"

diffCheckedSpecs :: Spec -> Spec -> [Change]
diffCheckedSpecs old new =
  sharedDeclarationDiff env
    ++ concatMap (runFamily env . snd) familyRegistry
  where
    env = DiffEnv old new

-- | Compare provenance first, then delegate semantic graphs to 'diffServices'.
diffSources :: ParsedSource -> ParsedSource -> Either FoldSurfaceError [Change]
diffSources old new = do
  semanticChanges <- diffServices (checkedSource old) (checkedSource new)
  pure
    ( sourceLanguageChange
        ((.context) ((.spec) new))
        "declaration"
        ((.sourceLanguage) old)
        ((.sourceLanguage) new)
        <> semanticChanges
    )

-- | One all-compatible source-provenance finding, reusable per workspace member.
sourceLanguageChange :: Name -> Text -> SourceLanguage -> SourceLanguage -> [Change]
sourceLanguageChange root subject old new
  | old == new = []
  | otherwise =
      [ mkChange
          LabelAdditive
          (ChangeContext root [] ContextGeneral LabelAdditive)
          root
          "source-language"
          subject
          SourceLanguageDeclarationChanged
          ( "source form changed "
              <> renderSourceLanguage old
              <> " -> "
              <> renderSourceLanguage new
              <> if oldRuntime == newRuntime
                then "; normalized runtime semantics are unchanged"
                else "; effective runtime semantics changed " <> oldRuntime <> " -> " <> newRuntime <> "; see the accompanying semantic-contract findings"
          )
      ]
  where
    oldRuntime = effectiveRuntimeSemantics (effectiveLanguageContract old)
    newRuntime = effectiveRuntimeSemantics (effectiveLanguageContract new)
    renderSourceLanguage sourceLanguage =
      sourceFormText sourceLanguage
        <> maybe "" ((" v" <>) . languageVersionText) (declaredLanguageVersionMaybe sourceLanguage)

runFamily :: DiffEnv -> FamilyDiff -> [Change]
runFamily env (DiffFamily f) = f env
runFamily _ (OutOfDiffScope _) = []

-- Rules are outside the decode and persisted-identity axes, but referenced
-- rule bodies are compared as part of each aggregate's replay fold surface.
sharedDeclarationDiff :: DiffEnv -> [Change]
sharedDeclarationDiff env = enumDiff env ++ idDiff env ++ nominalScalarDiff env ++ mappedDeclarationDiff env

mappedDeclarationDiff :: DiffEnv -> [Change]
mappedDeclarationDiff env =
  concatMap
    (\finding -> mappedFindingChanges finding <> mappedProjectionFindingChanges env finding)
    (diffMapped ((.old) env) ((.new) env))

-- | A mapped event finding retains its existing private-history change and
-- gains one build/review finding per real inline/catalog aggregate consumer.
-- Category/all owners never appear because they have no single mapped event
-- authority. Operational targets and observers are evidence, not SQL claims.
mappedProjectionFindingChanges :: DiffEnv -> MappedFinding -> [Change]
mappedProjectionFindingChanges env finding = case (projectionImpactFor ((.old) env), projectionImpactFor ((.new) env)) of
  (Nothing, Nothing) -> []
  (oldImpact, newImpact) ->
    let derivedConsumers =
          maybe Set.empty (`ProjectionImpact.projectionConsumersFor` declarationKey) oldImpact
            <> maybe Set.empty (`ProjectionImpact.projectionConsumersFor` declarationKey) newImpact
     in [ withMappedConsequences (projectionConsequences derived oldOperation newOperation) $
            appendChangeDetail (operationDetail oldOperation newOperation) $
              mappedChange
                (consumerBuildContext root inheritedPaths)
                root
                "mapped-projection"
                subject
                finding
        | derived <- Set.toAscList derivedConsumers,
          let oldOperation = oldImpact >>= operationFor declarationKey derived,
          let newOperation = newImpact >>= operationFor declarationKey derived,
          let inheritedPaths =
                Set.toAscList . Set.fromList $
                  projectionPaths declarationKey derived oldImpact
                    <> projectionPaths declarationKey derived newImpact,
          let root = projectionConsumerRoot derived,
          let subject = mappedConsumerIdentity (DerivedProjectionConsumer derived) <> " inherits " <> (.unMappedKey) declarationKey
        ]
  where
    declarationKey = MappedKey ((.declaration) finding)
    projectionImpactFor spec = case resolveTypeGraph spec of
      Left _ -> Nothing
      Right graph -> Just (ProjectionImpact.projectionMappedImpact (legacyCheckedService spec) (semanticImpact graph))
    operationFor key derived impact =
      find
        (\(ProjectionImpact.ProjectionOperationalImpact candidate _ _ _ _ _) -> candidate == derived)
        (ProjectionImpact.projectionOperationsFor impact key)
    projectionPaths key derived = maybe [] $ \impact ->
      sort . Set.toList . Set.fromList $
        [ renderUsePath inheritedPath
        | ProjectionImpact.ProjectionMappedRoot candidate declaration inheritedPath <- (.roots) impact,
          candidate == derived,
          declaration == key
        ]
    operationDetail oldOperation newOperation =
      "; derived projection impact: "
        <> renderOperation "previous" oldOperation
        <> "; "
        <> renderOperation "current" newOperation
    renderOperation label Nothing = label <> "=(absent)"
    renderOperation label (Just (ProjectionImpact.ProjectionOperationalImpact _ groupName targetNames observerNames canReplay fingerprint)) =
      label
        <> "=(group="
        <> maybe "(inline)" id groupName
        <> ", targets=["
        <> T.intercalate "," (Set.toAscList targetNames)
        <> "], read-models=["
        <> T.intercalate "," (Set.toAscList observerNames)
        <> "], replayable="
        <> (if canReplay then "yes" else "no")
        <> ", source-fingerprint="
        <> fingerprint
        <> ")"
    appendChangeDetail suffix = \case
      Additive kind -> Additive (appendKindDetail suffix kind)
      Advisory kind -> Advisory (appendKindDetail suffix kind)
      Breaking kind -> Breaking (appendKindDetail suffix kind)
    appendKindDetail suffix ChangeKind {node, facet, subject, code, context, vector, mappedPersistedImpact, mappedConsequences, paths, detail} =
      ChangeKind {node, facet, subject, code, context, vector, mappedPersistedImpact, mappedConsequences, paths, detail = detail <> suffix}
    projectionConsequences derived oldOperation newOperation =
      Set.fromList
        ( [MappedConsumerBuild (DerivedProjectionConsumer derived), MappedProjectionHandlerReview derived]
            <> [ MappedProjectionRebuild derived groupName
               | ProjectionImpact.ProjectionOperationalImpact _ (Just groupName) _ _ True _ <- maybeToList oldOperation <> maybeToList newOperation
               ]
        )
    projectionConsumerRoot (AggregateInlineProjectionConsumer aggregate _) = aggregate
    projectionConsumerRoot (CatalogProjectionConsumer owner _) = owner

-- | Explain only declarations for which the authoritative mapped differ emits
-- a finding. The compatibility findings remain unchanged; this projection adds
-- the checked before/after aggregate consumer sets and service-conformance role.
mappedSemanticImpact :: Spec -> Spec -> [MappedImpactDelta]
mappedSemanticImpact oldSpec newSpec = mappedSemanticImpactForServices (legacyCheckedService oldSpec) (legacyCheckedService newSpec)

-- | Service-aware mapped impact adds checked declarative selection consumers;
-- the legacy Spec-only entry point retains its historical language contract.
mappedSemanticImpactForServices :: CheckedService -> CheckedService -> [MappedImpactDelta]
mappedSemanticImpactForServices oldService newService = case (resolveTypeGraph oldSpec, resolveTypeGraph newSpec) of
  (Right oldGraph, Right newGraph) ->
    let oldSnapshot = semanticImpactSnapshot (semanticImpactForService oldService oldGraph)
        newSnapshot = semanticImpactSnapshot (semanticImpactForService newService newGraph)
        declarationChanges = [MappedKey ((.declaration) finding) | finding <- diffMapped oldSpec newSpec]
        relationChanges = map (.declaration) (diffSemanticImpact oldSnapshot newSnapshot)
     in mappedImpactForDeclarations (declarationChanges <> relationChanges) oldSnapshot newSnapshot
  _ -> []
  where
    oldSpec = checkedSpec oldService
    newSpec = checkedSpec newService

mappedFindingChanges :: MappedFinding -> [Change]
mappedFindingChanges finding
  | (.code) finding == MappedDeclAdded = [mappedDeclarationChange LabelAdditive finding]
  | (.code) finding `elem` [MappedHaskellSourceChanged, MappedRecordConstructorChanged, MappedFixturesChanged, GeneratedHaskellNameChanged] =
      [mappedBuildChange finding]
  | (.code) finding `elem` [MappedInitialChanged, MappedCanonicalTypeChanged] =
      mappedBuildChange finding : map (mappedUseChange finding) registerPaths
  | null paths = [mappedBuildChange finding]
  | otherwise = map (mappedUseChange finding) paths
  where
    paths = (.usePaths) finding
    registerPaths = [path | path@UsePath {root = RootRegister {}} <- paths]

mappedBuildChange :: MappedFinding -> Change
mappedBuildChange finding =
  mappedChange context ((.declaration) finding) "mapped-build" subject finding
  where
    subject = declarationSubject finding
    renderedPaths = map (\path -> renderMappedSubject path ((.leaf) finding)) ((.usePaths) finding)
    context = (consumerBuildContext ((.declaration) finding) renderedPaths) {contextOriginalLabel = LabelAdvisory}

mappedDeclarationChange :: Label -> MappedFinding -> Change
mappedDeclarationChange label finding =
  mappedChange context ((.declaration) finding) "mapped-declaration" (declarationSubject finding) finding
  where
    context = ChangeContext ((.declaration) finding) [] ContextGeneral label

mappedUseChange :: MappedFinding -> UsePath -> Change
mappedUseChange finding path =
  withMappedConsequences (mappedUseConsequences path) (mappedChange context root facet subject finding)
  where
    subject = renderMappedSubject path ((.leaf) finding)
    (root, facet, kind) = case (.root) path of
      RootCommandField aggregate _ _ _ -> (aggregate, "mapped-command", ContextConsumerBuild)
      RootEventField aggregate _ _ _ -> (aggregate, "mapped-event", ContextPrivateEvent)
      RootRegister aggregate _ _ -> (aggregate, "mapped-register", ContextSnapshot)
      RootWorkqueueField workqueue _ _ -> (workqueue, "mapped-workqueue", ContextQueue)
      RootReadModelQueryInput readModel _ -> (readModel, "mapped-query-input", ContextConsumerBuild)
      RootReadModelQueryResult readModel _ -> (readModel, "mapped-query-result", ContextConsumerBuild)
    context = ChangeContext root [subject] kind (mappedContextHint finding kind)

mappedUseConsequences :: UsePath -> Set MappedConsequence
mappedUseConsequences path = Set.fromList $ case (.root) path of
  RootCommandField aggregate _ _ _ -> [MappedConsumerBuild (AggregateConsumer aggregate)]
  RootEventField aggregate _ _ _ -> [MappedConsumerBuild (AggregateConsumer aggregate), MappedPrivateEventHistory aggregate]
  RootRegister aggregate _ _ -> [MappedConsumerBuild (AggregateConsumer aggregate), MappedSnapshotHydration aggregate]
  RootWorkqueueField workqueue _ _ -> [MappedConsumerBuild (WorkqueueConsumer workqueue), MappedWorkqueueHistory workqueue]
  RootReadModelQueryInput readModel _ -> [MappedConsumerBuild (ReadModelQueryConsumer readModel MappedQueryInput), MappedQueryApi readModel MappedQueryInput]
  RootReadModelQueryResult readModel _ -> [MappedConsumerBuild (ReadModelQueryConsumer readModel MappedQueryResult), MappedQueryApi readModel MappedQueryResult]

withMappedConsequences :: Set MappedConsequence -> Change -> Change
withMappedConsequences consequences = \case
  Additive kind -> Additive (replaceMappedConsequences consequences kind)
  Advisory kind -> Advisory (replaceMappedConsequences consequences kind)
  Breaking kind -> Breaking (replaceMappedConsequences consequences kind)

replaceMappedConsequences :: Set MappedConsequence -> ChangeKind -> ChangeKind
replaceMappedConsequences mappedConsequences kind =
  ChangeKind
    { node = kind.node,
      facet = kind.facet,
      subject = kind.subject,
      code = kind.code,
      context = kind.context,
      vector = kind.vector,
      mappedPersistedImpact = kind.mappedPersistedImpact,
      mappedConsequences,
      paths = kind.paths,
      detail = kind.detail
    }

mappedContextHint :: MappedFinding -> ContextKind -> Label
mappedContextHint finding kind = case kind of
  ContextSnapshot -> LabelAdvisory
  ContextQueue -> LabelBreaking
  ContextConsumerBuild -> LabelAdvisory
  ContextPrivateEvent
    | (.code) finding == MappedFieldAddedWithDefault -> case (.oldUnknownFields) finding of
        Just IgnoreUnknown -> LabelAdditive
        _ -> LabelBreaking
    | (.code) finding `elem` [MappedArmAdded, MappedEnumValueAdded] -> LabelAdvisory
    | (.code) finding `elem` [MappedBindingChanged, MappedInitialChanged, MappedCanonicalTypeChanged] -> LabelAdvisory
    | otherwise -> LabelBreaking
  _ -> LabelAdvisory

mappedChange :: ChangeContext -> Name -> Text -> Text -> MappedFinding -> Change
mappedChange context node facet subject finding =
  mkChange label context node facet subject ((.code) finding) renderedDetail
  where
    label = deriveLabel defaultGate (classifyCompatibility context ((.code) finding))
    renderedDetail = case (.contextKind) context of
      ContextQueue ->
        (.detail) finding
          <> "; queued jobs remain schema-version-1 history; drain the queue or supply an application-owned transitional codec before deployment"
      _ -> (.detail) finding

declarationSubject :: MappedFinding -> Text
declarationSubject finding =
  (.declaration) finding <> if T.null ((.leaf) finding) then "" else " " <> (.leaf) finding

nodeAggregate :: Node -> Maybe Aggregate
nodeAggregate (NAggregate a) = Just a
nodeAggregate _ = Nothing

nodeProcess :: Node -> Maybe ProcessNode
nodeProcess (NProcess process) = Just process
nodeProcess _ = Nothing

nodeRouter :: Node -> Maybe RouterNode
nodeRouter (NRouter router) = Just router
nodeRouter _ = Nothing

nodeContract :: Node -> Maybe ContractNode
nodeContract (NContract contract) = Just contract
nodeContract _ = Nothing

nodeIntake :: Node -> Maybe IntakeNode
nodeIntake (NIntake intake) = Just intake
nodeIntake _ = Nothing

nodeEmit :: Node -> Maybe EmitNode
nodeEmit (NEmit emit) = Just emit
nodeEmit _ = Nothing

nodePublisher :: Node -> Maybe PublisherNode
nodePublisher (NPublisher publisher) = Just publisher
nodePublisher _ = Nothing

nodeWorkqueue :: Node -> Maybe WorkqueueNode
nodeWorkqueue (NWorkqueue workqueue) = Just workqueue
nodeWorkqueue _ = Nothing

nodePgmqDispatch :: Node -> Maybe PgmqDispatchNode
nodePgmqDispatch (NPgmqDispatch dispatch) = Just dispatch
nodePgmqDispatch _ = Nothing

nodeReadModel :: Node -> Maybe ReadModelNode
nodeReadModel (NReadModel readModel) = Just readModel
nodeReadModel _ = Nothing

nodeProjectionTarget :: Node -> Maybe ProjectionTargetNode
nodeProjectionTarget (NProjectionTarget target) = Just target
nodeProjectionTarget _ = Nothing

nodeRebuildGroup :: Node -> Maybe RebuildGroupNode
nodeRebuildGroup (NRebuildGroup groupNode) = Just groupNode
nodeRebuildGroup _ = Nothing

nodeProjectionRevision :: Node -> Maybe ProjectionRevisionNode
nodeProjectionRevision (NProjectionRevision revision) = Just revision
nodeProjectionRevision _ = Nothing

nodeExternalRead :: Node -> Maybe ExternalReadNode
nodeExternalRead (NExternalRead externalRead) = Just externalRead
nodeExternalRead _ = Nothing

nodeProjectionOwner :: Node -> Maybe ProjectionOwnerNode
nodeProjectionOwner (NProjectionOwner owner) = Just owner
nodeProjectionOwner _ = Nothing

nodeWorkflow :: Node -> Maybe WorkflowNode
nodeWorkflow (NWorkflow workflow) = Just workflow
nodeWorkflow _ = Nothing

-- | Router identity is replay-sensitive: the stable name and key feed every
-- target-keyed dispatch id, and the target selects the persisted stream family.
routerDiff :: DiffEnv -> [Change]
routerDiff env =
  concatMap (uncurry routerPairDiff) ((.matched) paired)
    ++ [additive ((.id) router) "router" ((.id) router) DeclarationAdded "new router declaration" | router <- (.added) paired]
    ++ [breaking ((.id) router) "router-identity" ((.id) router) RouterStableNameChanged "router removed while replayable source events may still derive target-keyed dispatch ids from its stable identity" | router <- (.removed) paired]
  where
    paired = pairByName nodeRouter (.id) env

routerPairDiff :: RouterNode -> RouterNode -> [Change]
routerPairDiff oldRouter newRouter =
  stableName
    ++ keyDerivation
    ++ target
    ++ routerDecideSurfaceDiff oldRouter newRouter
  where
    nodeName = (.id) newRouter
    stableName =
      [ breaking nodeName "router-stable-name" nodeName RouterStableNameChanged $
          "router stable name changed from '" <> (.name) oldRouter <> "' to '" <> (.name) newRouter <> "'; every deterministicRouterCommandId is re-keyed, so redelivery can duplicate the full resolved fan-out"
      | (.name) oldRouter /= (.name) newRouter
      ]
    keyDerivation =
      [ breaking nodeName "router-key" ((.field) ((.key) newRouter)) DerivedIdentityChanged "router key field or derivation changed; replay derives different target dispatch ids"
      | (.key) oldRouter /= (.key) newRouter
      ]
    target =
      [ breaking nodeName "router-target" ((.target) newRouter) DerivedIdentityChanged "router target aggregate changed; replay addresses a different persisted stream family"
      | (.target) oldRouter /= (.target) newRouter
      ]

routerDecideSurfaceDiff :: RouterNode -> RouterNode -> [Change]
routerDecideSurfaceDiff oldRouter newRouter =
  [ advisory
      ((.id) newRouter)
      "router-decide"
      ((.id) newRouter)
      RouterDecideSurfaceChanged
      "router dispatch surface changed: a source event redelivered across the deploy dispatches under the same deterministic ids, so half-old/half-new fan-out merges silently. Drain or pause the router's subscription and replay or discard dead letters before deploying; see docs/user/deploy-ordering.md. Hole-only decide changes are not visible to diff; the same drain rule applies to those too."
  | oldSurface /= newSurface
  ]
  where
    oldSurface =
      ( renderResolveSurface ((.resolve) oldRouter),
        renderRouterDispatchSurface ((.dispatch) oldRouter)
      )
    newSurface =
      ( renderResolveSurface ((.resolve) newRouter),
        renderRouterDispatchSurface ((.dispatch) newRouter)
      )

readModelDiff :: DiffEnv -> [Change]
readModelDiff env =
  concatMap (uncurry (readModelPairDiff env oldSupplies newSupplies)) ((.matched) paired)
    ++ concatMap addedReadModelDiff ((.added) paired)
    ++ concatMap removedReadModelDiff ((.removed) paired)
  where
    paired = pairByName nodeReadModel (.name) env
    oldSupplies = analyzeProjectionSupplies ((.old) env)
    newSupplies = analyzeProjectionSupplies ((.new) env)

readModelPairDiff :: DiffEnv -> ProjectionSupplyAnalysis -> ProjectionSupplyAnalysis -> ReadModelNode -> ReadModelNode -> [Change]
readModelPairDiff env oldSupplies newSupplies oldReadModel newReadModel =
  versionChanges
    ++ shapeChanges
    ++ identityChanges
    ++ policyChanges
    ++ bindingChanges
    ++ queryContractChanges
  where
    nodeName = (.name) newReadModel
    versionChanges
      | (.version) newReadModel < (.version) oldReadModel =
          [ breaking nodeName "read-model-version" nodeName ReadModelVersionDecreased ("version decreased from " <> tInt ((.version) oldReadModel) <> " to " <> tInt ((.version) newReadModel))
          ]
      | (.version) newReadModel > (.version) oldReadModel =
          [ additive nodeName "read-model-version" nodeName VersionBumped ("version increased from " <> tInt ((.version) oldReadModel) <> " to " <> tInt ((.version) newReadModel) <> "; register and rebuild the new shape before serving it")
          ]
      | otherwise = []
    oldShape = ((.columns) oldReadModel, (.shape) oldReadModel)
    newShape = ((.columns) newReadModel, (.shape) newReadModel)
    shapeChanges =
      [ breaking nodeName "read-model-shape" nodeName ReadModelShapeChangedWithoutBump ("declared columns or captured shape hash changed at version " <> tInt ((.version) newReadModel) <> "; bump version and rebuild")
      | oldShape /= newShape,
        (.version) oldReadModel == (.version) newReadModel
      ]
    oldRegistry = registryNameFor ((.context) ((.old) env)) oldReadModel
    newRegistry = registryNameFor ((.context) ((.new) env)) newReadModel
    oldSubscription = subscriptionNameFor ((.context) ((.old) env)) oldReadModel
    newSubscription = subscriptionNameFor ((.context) ((.new) env)) newReadModel
    identityChanges =
      [ breaking nodeName "read-model-identity" nodeName DerivedIdentityChanged ("registry name changed '" <> oldRegistry <> "' -> '" <> newRegistry <> "'; the old registration row is orphaned")
      | oldRegistry /= newRegistry
      ]
        ++ [ breaking nodeName "read-model-table" nodeName DerivedIdentityChanged ("qualified table changed '" <> qualifiedIdentity oldReadModel <> "' -> '" <> qualifiedIdentity newReadModel <> "'; existing data remains under the old identity")
           | ((.schema) oldReadModel, (.table) oldReadModel) /= ((.schema) newReadModel, (.table) newReadModel)
           ]
        ++ [ breaking nodeName "read-model-subscription" nodeName DerivedIdentityChanged ("subscription changed '" <> oldSubscription <> "' -> '" <> newSubscription <> "'; the worker cursor remains under the old identity")
           | oldSubscription /= newSubscription
           ]
    -- There are three policy comparison shapes: catalog-owned on both sides,
    -- legacy on both sides, or a migration between them. The mixed case uses
    -- the normalized freshness matrix in docs/plans/250-report-legacy-strong-consistency-weakening-across-the-language-4-to-5-migration-in-diff.md;
    -- unlike two catalog-owned revisions, a migration strengthening is additive.
    policyChanges = case ((.supply) oldReadModel, (.supply) newReadModel) of
      (OwnerDerivedSupply, OwnerDerivedSupply) ->
        [ breaking nodeName "query-freshness" nodeName QueryFreshnessChanged ("query freshness changed " <> renderFreshness ((.freshness) oldReadModel) <> " -> " <> renderFreshness ((.freshness) newReadModel) <> "; catalog and owning-group query policy identity changed")
        | (.freshness) oldReadModel /= (.freshness) newReadModel
        ]
      (LegacyReadModelSupply {}, LegacyReadModelSupply {}) ->
        legacyFeedChanges <> legacyConsistencyChanges <> legacyScopeChanges
      _ -> migrationFreshnessChanges
    migrationFreshnessChanges = case ((.freshness) oldReadModel, (.freshness) newReadModel) of
      (oldFreshness, newFreshness)
        | oldFreshness == newFreshness -> []
      (FreshnessWaitForHead _, FreshnessImmediate) ->
        [ breaking nodeName "query-freshness" nodeName QueryFreshnessChanged ("query freshness weakened " <> renderFreshness ((.freshness) oldReadModel) <> " -> immediate across the legacy consistency migration; callers lose the cursor-wait guarantee")
        ]
      (FreshnessImmediate, FreshnessWaitForHead _) ->
        [ additive nodeName "query-freshness" nodeName CompatibilityStrengthened ("query freshness strengthened immediate -> " <> renderFreshness ((.freshness) newReadModel) <> " across the legacy consistency migration; callers gain a cursor-wait guarantee")
        ]
      (FreshnessWaitForHead oldWaitScope, FreshnessWaitForHead newWaitScope)
        | scopeStrengthened oldWaitScope newWaitScope ->
            [ additive nodeName "query-freshness" nodeName CompatibilityStrengthened ("query freshness head scope widened " <> renderScope oldWaitScope <> " -> " <> renderScope newWaitScope <> " across the legacy consistency migration")
            ]
        | otherwise ->
            [ breaking nodeName "query-freshness" nodeName QueryFreshnessChanged ("query freshness head scope changed " <> renderScope oldWaitScope <> " -> " <> renderScope newWaitScope <> " across the legacy consistency migration; callers no longer wait on the same event surface")
            ]
      (FreshnessImmediate, FreshnessImmediate) -> []
    legacyFeedChanges =
      [ breaking nodeName "read-model-feed" nodeName ReadModelFeedChanged ("feed changed " <> renderFeed oldFeed <> " -> " <> renderFeed newFeed <> "; projection wiring and rebuild identities changed")
      | Just oldFeed <- [legacyReadModelFeed oldReadModel],
        Just newFeed <- [legacyReadModelFeed newReadModel],
        oldFeed /= newFeed
      ]
    legacyConsistencyChanges = case (legacyReadModelConsistency oldReadModel, legacyReadModelConsistency newReadModel) of
      (Just Strong, Just Eventual) ->
        [breaking nodeName "read-model-consistency" nodeName ReadModelConsistencyWeakened "default consistency changed Strong -> Eventual; callers lose the cursor-wait guarantee"]
      (Just Eventual, Just Strong) ->
        [additive nodeName "read-model-consistency" nodeName CompatibilityStrengthened "default consistency changed Eventual -> Strong; callers gain a cursor-wait guarantee"]
      _ -> []
    oldScope = effectiveScope (legacyReadModelScope oldReadModel)
    newScope = effectiveScope (legacyReadModelScope newReadModel)
    legacyScopeChanges
      | oldScope == newScope = []
      | scopeStrengthened oldScope newScope =
          [additive nodeName "read-model-scope" nodeName CompatibilityStrengthened ("Strong scope widened " <> renderScope oldScope <> " -> " <> renderScope newScope)]
      | otherwise =
          [breaking nodeName "read-model-scope" nodeName ReadModelConsistencyWeakened ("Strong scope changed " <> renderScope oldScope <> " -> " <> renderScope newScope <> "; callers no longer wait on the same event surface")]
    bindingChanges =
      [ breaking nodeName "read-model-catalog-binding" nodeName CatalogQueryBindingChanged "query-model rebuild group, observed target set, resolved projection supplier, or backing target changed; persisted lifecycle identity and rebuild completeness changed"
      | bindingIdentity oldSupplies oldReadModel /= bindingIdentity newSupplies newReadModel
      ]
    bindingIdentity supplyAnalysis readModel =
      ( (.group) readModel,
        Set.fromList ((.observedTargets) readModel),
        resolvedSupplier supplyAnalysis readModel,
        effectiveBacking readModel
      )
    resolvedSupplier supplyAnalysis readModel =
      case [ (.projectionOwner) supply
           | supply <- (.resolvedProjectionSupplies) supplyAnalysis,
             (.queryModel) supply == (.name) readModel
           ] of
        [ownerName] -> Just ownerName
        _ -> Nothing
    effectiveBacking readModel = case (.backingTarget) readModel of
      Just target -> Just target
      Nothing -> case (.observedTargets) readModel of
        [single] -> Just single
        _ -> Nothing
    queryContractChanges =
      queryPositionChange
        "input"
        MappedQueryInput
        ReadModelQueryInputChanged
        ((.input) <$> (.queryTypes) oldReadModel)
        ((.input) <$> (.queryTypes) newReadModel)
        "callers"
        <> queryPositionChange
          "result"
          MappedQueryResult
          ReadModelQueryResultChanged
          ((.result) <$> (.queryTypes) oldReadModel)
          ((.result) <$> (.queryTypes) newReadModel)
          "result consumers"
    queryPositionChange position mappedPosition code oldExpression newExpression owner =
      [ withMappedConsequences
          (Set.fromList [MappedConsumerBuild consumer, MappedQueryApi nodeName mappedPosition])
          ( advisoryAt
              (consumerBuildContext nodeName [nodeName <> " query " <> position])
              nodeName
              ("read-model-query-" <> position)
              (nodeName <> " query " <> position)
              code
              ( "query "
                  <> position
                  <> " changed "
                  <> renderMaybeType oldExpression
                  <> " -> "
                  <> renderMaybeType newExpression
                  <> "; recompile "
                  <> owner
                  <> " against the generated QueryContract. SQL columns, projection replay, and persisted history are unaffected"
              )
          )
      | oldExpression /= newExpression
      ]
      where
        consumer = ReadModelQueryConsumer nodeName mappedPosition
    renderMaybeType = maybe "(absent)" renderTypeExpr

projectionTargetDiff :: DiffEnv -> [Change]
projectionTargetDiff env =
  concatMap (uncurry projectionTargetPairDiff) ((.matched) paired)
    <> [additive ((.name) target) "projection-target" ((.name) target) CatalogTargetAdded "new application-owned target; consumer DDL is still required" | target <- (.added) paired]
    <> [breaking ((.name) target) "projection-target" ((.name) target) CatalogTargetRemoved "target declaration removed while table data and rebuild evidence may remain" | target <- (.removed) paired]
  where
    paired = pairByName nodeProjectionTarget (.name) env

projectionTargetPairDiff :: ProjectionTargetNode -> ProjectionTargetNode -> [Change]
projectionTargetPairDiff oldTarget newTarget = locationChange <> resetChange <> dependencyChange
  where
    targetName = (.name) newTarget
    locationChange =
      [ breaking targetName "projection-target-location" targetName CatalogTargetLocationChanged $
          "qualified target changed " <> (.schema) oldTarget <> "." <> (.table) oldTarget <> " -> " <> (.schema) newTarget <> "." <> (.table) newTarget <> "; Keiro does not move application data"
      | ((.schema) oldTarget, (.table) oldTarget) /= ((.schema) newTarget, (.table) newTarget)
      ]
    resetChange = case ((.reset) oldTarget, (.reset) newTarget) of
      (TargetPreserve, TargetClear) -> [breaking targetName "projection-target-reset" targetName CatalogTargetResetPolicyChanged "reset changed preserve -> clear; a rebuild can now delete retained brownfield data"]
      (TargetClear, TargetPreserve) -> [advisory targetName "projection-target-reset" targetName CatalogTargetResetPolicyChanged "reset changed clear -> preserve; application reconciliation must now prove retained rows"]
      _ -> []
    dependencyChange =
      [ breaking targetName "projection-target-dependencies" targetName CatalogTargetDependencyChanged "target dependency order changed; abandon any active fingerprint and start a fresh group rebuild"
      | (.dependsOn) oldTarget /= (.dependsOn) newTarget
      ]

rebuildGroupDiff :: DiffEnv -> [Change]
rebuildGroupDiff env =
  concatMap (uncurry rebuildGroupPairDiff) ((.matched) paired)
    <> [additive ((.name) groupNode) "rebuild-group" ((.name) groupNode) DeclarationAdded "new rebuild group" | groupNode <- (.added) paired]
    <> [breaking ((.name) groupNode) "rebuild-group" ((.name) groupNode) CatalogGroupChanged "rebuild group removed while lifecycle and run evidence may remain" | groupNode <- (.removed) paired]
  where
    paired = pairByName nodeRebuildGroup (.name) env

rebuildGroupPairDiff :: RebuildGroupNode -> RebuildGroupNode -> [Change]
rebuildGroupPairDiff oldGroup newGroup =
  [ breaking ((.name) newGroup) "rebuild-group-membership-order" ((.name) newGroup) CatalogGroupChanged "target membership or deterministic preparation order changed; abandon any active fingerprint and start a fresh rebuild"
  | ((.targets) oldGroup, (.order) oldGroup) /= ((.targets) newGroup, (.order) newGroup)
  ]

projectionRevisionDiff :: DiffEnv -> [Change]
projectionRevisionDiff env =
  concatMap (uncurry projectionRevisionPairDiff) ((.matched) paired)
    <> [additive ((.name) revision) "projection-revision" ((.name) revision) DeclarationAdded "new projection revision and target-schema contract" | revision <- (.added) paired]
    <> [breaking ((.name) revision) "projection-revision" ((.name) revision) CatalogProjectionRevisionRemoved "projection revision removed while serving, rebuild, or read-contract evidence may still refer to it" | revision <- (.removed) paired]
  where
    paired = pairByName nodeProjectionRevision (.name) env

projectionRevisionPairDiff :: ProjectionRevisionNode -> ProjectionRevisionNode -> [Change]
projectionRevisionPairDiff oldRevision newRevision = groupChange <> schemaChanges <> contractChanges
  where
    revisionName = (.name) newRevision
    oldTargets = Map.fromList [((.target) target, target) | target <- (.targets) oldRevision]
    newTargets = Map.fromList [((.target) target, target) | target <- (.targets) newRevision]
    groupChange =
      [ breaking revisionName "projection-revision-group" revisionName CatalogProjectionRevisionChanged "revision rebuild group changed; persisted revision and generation identity no longer matches"
      | (.group) oldRevision /= (.group) newRevision
      ]
    schemaChanges =
      [ breaking revisionName "target-schema" targetName CatalogTargetSchemaChanged $
          "target schema version changed " <> (.schemaVersion) oldTarget <> " -> " <> (.schemaVersion) newTarget <> "; declare a new projection revision instead of mutating a registered one"
      | (targetName, oldTarget) <- Map.toAscList oldTargets,
        Just newTarget <- [Map.lookup targetName newTargets],
        (.schemaVersion) oldTarget /= (.schemaVersion) newTarget
      ]
    contractChanges =
      [ breaking revisionName "projection-revision-contract" revisionName CatalogProjectionRevisionChanged "target membership, provisioner, expected-shape, validator, or ordered promotion-name contract changed; declare a new revision identity"
      | Map.keysSet oldTargets /= Map.keysSet newTargets
          || any targetContractChanged (Map.toAscList oldTargets)
      ]
    targetContractChanged (targetName, oldTarget) = case Map.lookup targetName newTargets of
      Nothing -> True
      Just newTarget ->
        ( (.provisioner) oldTarget,
          (.provisionerVersion) oldTarget,
          (.expectedShape) oldTarget,
          (.validator) oldTarget,
          (.validatorVersion) oldTarget,
          (.promotionObjects) oldTarget
        )
          /= ( (.provisioner) newTarget,
               (.provisionerVersion) newTarget,
               (.expectedShape) newTarget,
               (.validator) newTarget,
               (.validatorVersion) newTarget,
               (.promotionObjects) newTarget
             )

externalReadDiff :: DiffEnv -> [Change]
externalReadDiff env =
  concatMap (uncurry (externalReadPairDiff env)) ((.matched) paired)
    <> [ additive
           (externalReadNodeIdentity externalRead)
           "external-read-version"
           ((.name) externalRead)
           CatalogExternalReadVersionAdded
           "new external read-contract version; grant execute only after its result type and wrapper are deployed"
       | externalRead <- (.added) paired
       ]
    <> [ breaking
           (externalReadNodeIdentity externalRead)
           "external-read-retirement"
           ((.name) externalRead)
           CatalogExternalReadRetired
           "external read-contract version removed; preview dependencies and retire it explicitly before removing the declaration"
       | externalRead <- (.removed) paired
       ]
  where
    paired = pairByName nodeExternalRead externalReadNodeIdentity env

externalReadPairDiff :: DiffEnv -> ExternalReadNode -> ExternalReadNode -> [Change]
externalReadPairDiff env oldExternalRead newExternalRead =
  immutableChanges <> compatibilityChanges <> shapeChanges <> generationChanges
  where
    subject = externalReadNodeIdentity newExternalRead
    immutableChanges =
      [ breaking subject "external-read-contract" ((.name) newExternalRead) CatalogExternalReadContractChanged "query binding or public result type changed for an existing contract version; publish a new version"
      | ( (.queryModel) oldExternalRead,
          (.resultSchema) oldExternalRead,
          (.resultType) oldExternalRead
        )
          /= ( (.queryModel) newExternalRead,
               (.resultSchema) newExternalRead,
               (.resultType) newExternalRead
             )
      ]
    oldCompatibility = Set.fromList ((.compatibleRevisions) oldExternalRead)
    newCompatibility = Set.fromList ((.compatibleRevisions) newExternalRead)
    compatibilityChanges
      | oldCompatibility == newCompatibility = []
      | oldCompatibility `Set.isSubsetOf` newCompatibility =
          [ additive subject "external-read-compatibility" ((.name) newExternalRead) CatalogExternalReadCompatibilityChanged "compatible projection-revision set widened; deploy the higher surface generation before promoting the added revision"
          ]
      | otherwise =
          [ breaking subject "external-read-compatibility" ((.name) newExternalRead) CatalogExternalReadCompatibilityChanged "compatible projection-revision set narrowed or replaced for an existing contract version"
          ]
    shapeChanges =
      [ breaking subject "external-read-result-shape" ((.name) newExternalRead) CatalogExternalReadResultShapeChanged "checked query result shape changed for an existing contract version; restore compatibility or publish a new version"
      | externalReadShape ((.old) env) oldExternalRead /= externalReadShape ((.new) env) newExternalRead
      ]
    generationChanges
      | (.surfaceGeneration) oldExternalRead == (.surfaceGeneration) newExternalRead = []
      | (.surfaceGeneration) oldExternalRead < (.surfaceGeneration) newExternalRead =
          [ advisory subject "external-read-surface-generation" ((.name) newExternalRead) CatalogExternalReadContractChanged "surface generation increased; roll out the newer declaration before older processes can reconcile"
          ]
      | otherwise =
          [ breaking subject "external-read-surface-generation" ((.name) newExternalRead) CatalogExternalReadContractChanged "surface generation decreased; runtime reconciliation refuses this downgrade"
          ]
    externalReadShape spec externalRead = case [(.shape) readModel | NReadModel readModel <- (.nodes) spec, (.name) readModel == (.queryModel) externalRead] of
      shape : _ -> Just shape
      [] -> Nothing

projectionOwnerDiff :: DiffEnv -> [Change]
projectionOwnerDiff env =
  concatMap (uncurry projectionOwnerPairDiff) ((.matched) paired)
    <> [additive ((.name) owner) "projection-owner" ((.name) owner) DeclarationAdded "new projection owner" | owner <- (.added) paired]
    <> [breaking ((.name) owner) "projection-owner" ((.name) owner) CatalogOwnerRemoved "projection owner removed while targets and replay evidence remain" | owner <- (.removed) paired]
  where
    paired = pairByName nodeProjectionOwner (.name) env

projectionOwnerPairDiff :: ProjectionOwnerNode -> ProjectionOwnerNode -> [Change]
projectionOwnerPairDiff oldOwner newOwner = groupAndTargets <> orderChange <> sourceChange <> feedIdentityChange <> checkpointPolicyChange <> replayChange
  where
    ownerName = (.name) newOwner
    groupAndTargets =
      [ breaking ownerName "projection-owner-group-targets" ownerName CatalogOwnerChanged "rebuild group or owned target set changed"
      | ((.group) oldOwner, Set.fromList ((.targets) oldOwner)) /= ((.group) newOwner, Set.fromList ((.targets) newOwner))
      ]
    orderChange =
      [ advisory ownerName "projection-owner-order" ownerName CatalogHandlerOrderChanged "handler order changed; replay materialization and resume fingerprint change"
      | (.order) oldOwner /= (.order) newOwner
      ]
    sourceChange =
      [ breaking ownerName "projection-owner-sources" ownerName CatalogSourceChanged "source selection changed; historical coverage and active resume fingerprint change"
      | (.sources) oldOwner /= (.sources) newOwner
      ]
    feedIdentityChange =
      [ breaking ownerName "projection-delivery" ownerName ProjectionDeliveryChanged "projection delivery changed; handler lifecycle, cursor, and dedup identity require coordinated review"
      | (.delivery) oldOwner /= (.delivery) newOwner
      ]
        <> [ breaking ownerName "projection-owner-delivery-identity" ownerName CatalogFeedIdentityChanged "subscription or dedup identity changed; cursors or dedup evidence remain under the old identity"
           | ((.subscription) oldOwner, (.dedup) oldOwner) /= ((.subscription) newOwner, (.dedup) newOwner)
           ]
    checkpointPolicyChange =
      [ breaking ownerName "projection-owner-checkpoint-on-missing" ownerName CatalogCheckpointPolicyChanged $
          "checkpoint-on-missing changed " <> renderCheckpointOnMissing oldPolicy <> " -> " <> renderCheckpointOnMissing newPolicy <> "; the generated catalog and next absent-row startup behavior change, while persisted subscription identity and existing checkpoint rows remain unchanged"
      | [oldPolicy] <- [(.checkpointOnMissing) oldOwner],
        [newPolicy] <- [(.checkpointOnMissing) newOwner],
        oldPolicy /= newPolicy
      ]
    replayChange =
      [ breaking ownerName "projection-owner-replay-policy" ownerName CatalogReplayPolicyChanged "replay policy changed; abandon any active run before rebuilding under the new contract"
      | (.replay) oldOwner /= (.replay) newOwner
      ]

renderCheckpointOnMissing :: CheckpointOnMissingNode -> Text
renderCheckpointOnMissing CheckpointFromBeginning = "from-beginning"
renderCheckpointOnMissing CheckpointFromCurrentHead = "from-current-head"
renderCheckpointOnMissing CheckpointFail = "fail"

addedReadModelDiff :: ReadModelNode -> [Change]
addedReadModelDiff readModel =
  [additive ((.name) readModel) "read-model" ((.name) readModel) DeclarationAdded "new read model"]

removedReadModelDiff :: ReadModelNode -> [Change]
removedReadModelDiff readModel =
  [breaking ((.name) readModel) "read-model-identity" ((.name) readModel) DerivedIdentityChanged "read model removed while registered metadata, data, subscription cursors, and callers may remain"]

qualifiedIdentity :: ReadModelNode -> Text
qualifiedIdentity readModel = (.schema) readModel <> "." <> (.table) readModel

renderFeed :: RmFeed -> Text
renderFeed RmInline = "inline"
renderFeed RmSubscription = "subscription"

renderFreshness :: QueryFreshnessNode -> Text
renderFreshness FreshnessImmediate = "immediate"
renderFreshness (FreshnessWaitForHead scope) = "wait-for-head " <> renderScope scope

effectiveScope :: Maybe RmScope -> RmScope
effectiveScope Nothing = RmEntireLog
effectiveScope (Just scope) = scope

scopeStrengthened :: RmScope -> RmScope -> Bool
scopeStrengthened (RmCategory _) RmEntireLog = True
scopeStrengthened _ _ = False

renderScope :: RmScope -> Text
renderScope RmEntireLog = "entire-log"
renderScope (RmCategory categoryName) = "category '" <> categoryName <> "'"

aggregateDiff :: DiffEnv -> [Change]
aggregateDiff env =
  concatMap
    (\(oldAggregate, newAggregate) -> aggregatePairDiff ((.old) env) ((.new) env) oldAggregate newAggregate)
    ((.matched) paired)
    ++ concatMap addedAggregateDiff ((.added) paired)
    ++ concatMap removedAggregateDiff ((.removed) paired)
  where
    paired = pairByName nodeAggregate (.name) env

aggregatePairDiff :: Spec -> Spec -> Aggregate -> Aggregate -> [Change]
aggregatePairDiff oldSpec newSpec oldAgg newAgg =
  commandFieldIdentityDiff oldAgg newAgg
    ++ concatMap (eventDiff oldAgg newAgg) ((.events) newAgg)
    ++ removedEvents oldAgg newAgg
    ++ wireDiff oldAgg newAgg
    ++ projectionDiff oldAgg newAgg
    ++ guardTighteningDiff oldAgg newAgg
    ++ domainOutcomeDiff oldAgg newAgg
    ++ transitionSurfaceDiff oldSpec newSpec oldAgg newAgg

-- | Typed outcomes are forward command behavior, not persisted fold behavior.
-- Pair transitions by their frozen fold canonical form so a reason-only change
-- reports precisely without also claiming replay or snapshot impact.
domainOutcomeDiff :: Aggregate -> Aggregate -> [Change]
domainOutcomeDiff oldAggregate newAggregate = declarationChange ++ transitionChanges
  where
    declarationChange =
      [ advisory
          ((.name) newAggregate)
          "domain-outcome-types"
          ((.name) newAggregate)
          DomainOutcomeTypesChanged
          ( "domain outcome types changed from '"
              <> renderDeclaration ((.domainOutcomeTypes) oldAggregate)
              <> "' to '"
              <> renderDeclaration ((.domainOutcomeTypes) newAggregate)
              <> "'; generated command result types and callers must be updated, while event history and snapshots remain compatible"
          )
      | canonicalDomainOutcomeTypes ((.domainOutcomeTypes) oldAggregate)
          /= canonicalDomainOutcomeTypes ((.domainOutcomeTypes) newAggregate)
      ]
    transitionChanges =
      [ advisory
          ((.name) newAggregate)
          "transition-domain-outcome"
          (transitionSubject ordinal newTransition)
          DomainTransitionOutcomeChanged
          ( "domain outcome changed from '"
              <> canonicalTransitionOutcome ((.outcome) oldTransition)
              <> "' to '"
              <> canonicalTransitionOutcome ((.outcome) newTransition)
              <> "'; forward command behavior changes, while the selected edge, emitted events, fold, replay, and snapshots remain unchanged"
          )
      | (ordinal, newTransition) <- zip [0 :: Int ..] ((.transitions) newAggregate),
        Just oldTransition <- [find ((== canonicalTransition newTransition) . canonicalTransition) ((.transitions) oldAggregate)],
        canonicalTransitionOutcome ((.outcome) oldTransition) /= canonicalTransitionOutcome ((.outcome) newTransition)
      ]
    renderDeclaration declaration = case canonicalDomainOutcomeTypes declaration of
      "" -> "(disabled)"
      value -> value
    transitionSubject ordinal transition =
      (.source) transition <> " -- " <> (.command) transition <> " [edge " <> T.pack (show ordinal) <> "]"

-- | Report replay-fold evolution. Regenerated scaffold code carries the new
-- fingerprint and invalidates old snapshots, so this remains advisory.
transitionSurfaceDiff :: Spec -> Spec -> Aggregate -> Aggregate -> [Change]
transitionSurfaceDiff oldSpec newSpec oldAgg newAgg
  | aggregateFoldSurfaceForService (legacyCheckedService oldSpec) oldAgg == aggregateFoldSurfaceForService (legacyCheckedService newSpec) newAgg = []
  | otherwise =
      [ advisory
          ((.name) newAgg)
          "transitions"
          ((.name) newAgg)
          AggFoldSurfaceChanged
          "aggregate fold surface changed: replay now interprets the existing log under the new fold. Old snapshots are invalidated automatically once the regenerated fold fingerprint deploys; if the change is fold-neutral confirm it, otherwise re-scaffold and redeploy, and bump `state-codec version=` for any accompanying Holes-only change."
      ]

-- | Plan 143: guard changes are replay-relevant. Hydration re-inverts each
-- stored event and re-checks the edge guard, so a stored event legally appended
-- under the old guard may no longer satisfy the new one — the next command on
-- any stream containing such an event fails hydration with no inverting edge.
-- The remedy is mechanical, so the tool computes it: the removed region is
-- @old-guard ∧ ¬new-guard@ ('complementExpr' eliminates the negation inside the
-- existing grammar), and the advisory prints a paste-ready replay-only twin
-- carrying that region with the OLD transition's writes\/emits\/goto. Whether
-- history should stay replayable (paste the twin) or be truncated instead is a
-- business decision, so the twin is never auto-applied.
--
-- Detection is conservative: any guard change on a paired live (source,
-- command) transition where the new spec declares a guard and does not already
-- contain a replay-only twin for the pair. A pure loosening also matches; the
-- advisory says how to confirm no stored data is affected (the replay audit,
-- docs/plans/142) rather than guessing.
guardTighteningDiff :: Aggregate -> Aggregate -> [Change]
guardTighteningDiff oldAgg newAgg =
  [ advisory ((.name) newAgg) "transition" subject AggGuardTightened detail
  | newT <- (.transitions) newAgg,
    (.mode) newT == TmLive,
    Just oldT <-
      [ find
          (\o -> (.source) o == (.source) newT && (.command) o == (.command) newT && (.mode) o == TmLive)
          ((.transitions) oldAgg)
      ],
    (.guard) newT /= (.guard) oldT,
    Just newGuard <- [(.guard) newT],
    not (hasReplayOnlyTwin newT),
    let subject = (.source) newT <> " -- " <> (.command) newT,
    let removedRegion =
          maybe (complementExpr newGuard) (\o -> EAnd o (complementExpr newGuard)) ((.guard) oldT),
    let twin = replaceTransitionGuardAndMode (Just removedRegion) TmReplayOnly oldT,
    let detail =
          "guard changed on "
            <> subject
            <> ". Stored events appended under the old guard may no longer invert: "
            <> "the next command on any stream containing one fails hydration with "
            <> "no inverting edge. Either confirm via the replay audit that no stored "
            <> "stream exercises the removed region, or keep history replayable by "
            <> "adding the computed replay-only twin (the removed region with the old "
            <> "transition's writes/emits/goto):\n\n"
            <> renderTransition twin
  ]
  where
    hasReplayOnlyTwin newT =
      any
        (\t -> (.mode) t == TmReplayOnly && (.source) t == (.source) newT && (.command) t == (.command) newT)
        ((.transitions) newAgg)

replaceTransitionGuardAndMode :: Maybe Expr -> TransitionMode -> Transition -> Transition
replaceTransitionGuardAndMode guard mode transition =
  Transition
    { source = transition.source,
      command = transition.command,
      implementation = transition.implementation,
      guard,
      writes = transition.writes,
      emits = transition.emits,
      outcome = transition.outcome,
      outcomeDuplicateLocs = transition.outcomeDuplicateLocs,
      goto = transition.goto,
      mode,
      loc = transition.loc
    }

addedAggregateDiff :: Aggregate -> [Change]
addedAggregateDiff newAgg =
  [ additive ((.name) newAgg) "event" ((.name) e) DeclarationAdded "new event type (new aggregate)"
  | e <- (.events) newAgg
  ]

removedAggregateDiff :: Aggregate -> [Change]
removedAggregateDiff oldAgg =
  [ breaking ((.name) oldAgg) "event" ((.name) e) EvtRemovedNotDeprecated "aggregate removed; its event tags are no longer decodable"
  | e <- (.events) oldAgg
  ]

-- | Per-event classification for an event present in the new aggregate.
eventDiff :: Aggregate -> Aggregate -> Event -> [Change]
eventDiff oldAgg newAgg e =
  case find ((== (.name) e) . (.name)) ((.events) oldAgg) of
    Nothing ->
      [additive ((.name) newAgg) "event" ((.name) e) DeclarationAdded "new event type"]
    Just oldE
      | (.version) e > (.version) oldE ->
          selectorChanges oldE
            ++ if (.version) e == (.version) oldE + 1 && (.upcastFrom) e `hasSource` (.version) oldE
              then
                [additive ((.name) newAgg) "event" ((.name) e) VersionBumped ("new version v" <> tInt ((.version) e) <> " with upcaster from v" <> tInt ((.version) oldE))]
                  ++ [ breaking
                         ((.name) newAgg)
                         "event"
                         ((.name) e)
                         UpcasterChainGap
                         ( "bumping v"
                             <> tInt ((.version) oldE)
                             <> " to v"
                             <> tInt ((.version) e)
                             <> " replaced the 'upcast from v"
                             <> tInt vanishedSource
                             <> "' rung; stored v"
                             <> tInt vanishedSource
                             <> " payloads can no longer decode"
                         )
                     | Just (vanishedSource, _) <- [(.upcastFrom) oldE],
                       not (aggregateHasUpcasterSource newAgg vanishedSource)
                     ]
              else
                [ breaking
                    ((.name) newAgg)
                    "event"
                    ((.name) e)
                    EvtVersionMissingUpcaster
                    ( "version changed from v"
                        <> tInt ((.version) oldE)
                        <> " to v"
                        <> tInt ((.version) e)
                        <> " without the required contiguous upcaster from v"
                        <> tInt ((.version) oldE)
                    )
                ]
      | (.version) e < (.version) oldE ->
          selectorChanges oldE
            ++ [breaking ((.name) newAgg) "event" ((.name) e) EvtVersionDecreased ("version decreased from v" <> tInt ((.version) oldE) <> " to v" <> tInt ((.version) e))]
      | otherwise ->
          selectorChanges oldE ++ sameVersionEventDiff oldAgg newAgg oldE e
  where
    selectorChanges oldEvent = eventFieldSelectorChanges oldAgg newAgg oldEvent e

-- | Events present in the old aggregate but absent in the new one. Removing a
-- tag entirely is breaking; deprecation preserves decoding but needs a retained
-- replay-only emitter to preserve replay.
removedEvents :: Aggregate -> Aggregate -> [Change]
removedEvents oldAgg newAgg =
  [ breaking ((.name) newAgg) "event" ((.name) oldE) EvtRemovedNotDeprecated "event removed entirely; its stored payloads can neither decode nor replay. Deprecating instead restores decode-ability only — replay still fails on live streams unless an equivalent replay-only emitting transition is retained; truncate or terminalize affected streams before deleting it"
  | oldE <- (.events) oldAgg,
    isNothing (find ((== (.name) oldE) . (.name)) ((.events) newAgg))
  ]

hasSource :: Maybe (Int, Hole) -> Int -> Bool
hasSource (Just (m, _)) n = m == n
hasSource Nothing _ = False

aggregateHasUpcasterSource :: Aggregate -> Int -> Bool
aggregateHasUpcasterSource aggregate source =
  any ((== Just source) . fmap fst . (.upcastFrom)) ((.events) aggregate)

hasReplayOnlyEmitter :: Aggregate -> Name -> Bool
hasReplayOnlyEmitter aggregate eventName =
  any
    (\transition -> (.mode) transition == TmReplayOnly && eventName `elem` (.emits) transition)
    ((.transitions) aggregate)

data EventFieldSig = EventFieldSig
  { dslName :: !Name,
    selector :: !Name,
    wireKey :: !Text,
    valueType :: !(Maybe TypeExpr)
  }
  deriving stock (Eq, Show)

eventFieldSigs :: Aggregate -> Event -> [EventFieldSig]
eventFieldSigs agg e = case (.body) e of
  EventFields fs -> map fieldSig fs
  EventFromCommand cn ->
    maybe [] (map fieldSig . (.fields)) (find ((== cn) . (.name)) ((.commands) agg))
  where
    fieldSig field =
      let identity = resolveAggregateFieldIdentity field
       in EventFieldSig
            { dslName = (.dslName) identity,
              selector = (.selector) identity,
              wireKey = (.wireKey) identity,
              valueType = (.valueType) field
            }

eventFieldSelectorChanges :: Aggregate -> Aggregate -> Event -> Event -> [Change]
eventFieldSelectorChanges oldAggregate newAggregate oldEvent newEvent =
  [ fieldSelectorChange
      ((.name) newAggregate)
      "event-field-selector"
      ((.name) newEvent <> "." <> (.dslName) newField)
      ((.selector) oldField)
      ((.selector) newField)
      "event field selector"
  | newField <- eventFieldSigs newAggregate newEvent,
    Just oldField <- [find ((== (.dslName) newField) . (.dslName)) (eventFieldSigs oldAggregate oldEvent)],
    (.selector) oldField /= (.selector) newField
  ]

commandFieldIdentityDiff :: Aggregate -> Aggregate -> [Change]
commandFieldIdentityDiff oldAggregate newAggregate =
  [ fieldSelectorChange
      ((.name) newAggregate)
      "command-field-selector"
      ((.name) newCommand <> "." <> (.name) newField)
      ((.selector) (resolveAggregateFieldIdentity oldField))
      ((.selector) (resolveAggregateFieldIdentity newField))
      "command field selector"
  | newCommand <- (.commands) newAggregate,
    Just oldCommand <- [find ((== (.name) newCommand) . (.name)) ((.commands) oldAggregate)],
    newField <- (.fields) newCommand,
    Just oldField <- [find ((== (.name) newField) . (.name)) ((.fields) oldCommand)],
    (.selector) (resolveAggregateFieldIdentity oldField)
      /= (.selector) (resolveAggregateFieldIdentity newField)
  ]

sameVersionEventDiff :: Aggregate -> Aggregate -> Event -> Event -> [Change]
sameVersionEventDiff oldAgg newAgg oldE newE =
  addedChanges
    ++ removedChanges
    ++ typeChanges
    ++ wireKeyChanges
    ++ deprecationChanges
    ++ retirementChanges
  where
    oldFields = eventFieldSigs oldAgg oldE
    newFields = eventFieldSigs newAgg newE
    oldNames = map (.dslName) oldFields
    newNames = map (.dslName) newFields
    added = newNames \\ oldNames
    removed = oldNames \\ newNames
    changed =
      [ ((.dslName) oldField, (.valueType) oldField, (.valueType) newField)
      | oldField <- oldFields,
        Just newField <- [find ((== (.dslName) oldField) . (.dslName)) newFields],
        (.valueType) oldField /= (.valueType) newField
      ]
    addedChanges =
      [ breaking ((.name) newAgg) "event" ((.name) newE) EvtFieldAddedWithoutBump ("field(s) " <> commas added <> " added at the same version v" <> tInt ((.version) newE) <> " without a version bump or upcaster")
      | not (null added)
      ]
    removedChanges =
      [ breaking ((.name) newAgg) "event" ((.name) newE) EvtFieldRemovedSameVersion ("field(s) " <> commas removed <> " removed at the same version v" <> tInt ((.version) newE))
      | not (null removed)
      ]
    typeChanges =
      [ breaking
          ((.name) newAgg)
          "event-field"
          ((.name) newE <> "." <> field)
          EvtFieldTypeChanged
          ("type changed " <> renderAggregateFieldType oldType <> " -> " <> renderAggregateFieldType newType <> " at the same version v" <> tInt ((.version) newE))
      | (field, oldType, newType) <- changed
      ]
    wireKeyChanges =
      [ breaking
          ((.name) newAgg)
          "event-field-wire-key"
          ((.name) newE <> "." <> (.dslName) newField)
          EvtFieldWireKeyChanged
          ( "wire key changed '"
              <> (.wireKey) oldField
              <> "' -> '"
              <> (.wireKey) newField
              <> "'; restore the old key, or version the event and retain an upcaster"
          )
      | newField <- newFields,
        Just oldField <- [find ((== (.dslName) newField) . (.dslName)) oldFields],
        (.wireKey) oldField /= (.wireKey) newField
      ]
    deprecationChanges
      | not ((.deprecated) oldE) && (.deprecated) newE =
          [ if hasReplayOnlyEmitter newAgg ((.name) newE)
              then
                advisory
                  ((.name) newAgg)
                  "event"
                  ((.name) newE)
                  EventRetirementInProgress
                  "event deprecated and removed from the live write path, while an equivalent replay-only transition preserves hydration. Retain that transition until every affected stream is terminal, truncated, or passes the replay audit"
              else
                advisory
                  ((.name) newAgg)
                  "event"
                  ((.name) newE)
                  DeprecatedEventReplayHazard
                  ( "event deprecated: old payloads remain decodable but are no longer replayable — hydration of live streams containing them fails at the first command (HydrationNoInvertingEdge). Add an equivalent replay-only emitting transition or confirm every affected stream is terminal or truncated before deploying"
                      <> if (.retiring) oldE then "" else "; consider a 'retiring event' stage first"
                  )
          ]
      | (.deprecated) oldE && not ((.deprecated) newE) && not ((.retiring) newE) =
          [advisory ((.name) newAgg) "event" ((.name) newE) EventUndeprecated "event returned to the write surface; old payloads remain decodable but new writes resume"]
      | otherwise = []
    retirementChanges
      | not ((.retiring) oldE) && (.retiring) newE =
          [advisory ((.name) newAgg) "event" ((.name) newE) EventRetirementInProgress "retirement started; keep the live emitting transition until affected streams are terminal or truncated, then cut over to deprecated plus an equivalent replay-only emitting transition"]
      | (.retiring) oldE && not ((.retiring) newE) && not ((.deprecated) newE) =
          [additive ((.name) newAgg) "event" ((.name) newE) EventRetirementAbandoned "event retirement abandoned; ordinary live writes continue"]
      | otherwise = []

renderAggregateFieldType :: Maybe TypeExpr -> Text
renderAggregateFieldType Nothing = "(declared)"
renderAggregateFieldType (Just expression) = typeExprCanonicalName expression

renderFieldType :: Maybe Name -> Text
renderFieldType Nothing = "(declared)"
renderFieldType (Just name) = name

wireDiff :: Aggregate -> Aggregate -> [Change]
wireDiff oldAgg newAgg
  | effectiveWire ((.wire) oldAgg) == effectiveWire ((.wire) newAgg) = []
  | otherwise =
      [ breaking
          ((.name) newAgg)
          "wire"
          ((.name) newAgg)
          WireSpecChanged
          ("effective wire convention changed " <> renderWire (effectiveWire ((.wire) oldAgg)) <> " -> " <> renderWire (effectiveWire ((.wire) newAgg)))
      ]

effectiveWire :: Maybe WireSpec -> (Text, Text)
effectiveWire Nothing = ("ctorName", "camelCase")
effectiveWire (Just w) = ((.kind) w, (.fields) w)

renderWire :: (Text, Text) -> Text
renderWire (kindName, fieldNames) = "kind=" <> kindName <> ", fields=" <> fieldNames

projectionDiff :: Aggregate -> Aggregate -> [Change]
projectionDiff oldAggregate newAggregate
  | projectionSurface ((.projection) oldAggregate) == projectionSurface ((.projection) newAggregate) = []
  | otherwise =
      [ advisory
          ((.name) newAggregate)
          "projection"
          ((.name) newAggregate)
          ProjectionChanged
          "projection table, consistency, key, or status mapping changed; coordinate the read-model migration"
      ]

projectionSurface :: Maybe ProjectionSpec -> Maybe (Name, Maybe Consistency, Name, Maybe Mapping)
projectionSurface projection = do
  value <- projection
  pure ((.table) value, (.consistency) value, (.key) value, (.statusMap) value)

idDiff :: DiffEnv -> [Change]
idDiff env =
  concatMap (uncurry (idPairDiff ((.old) env))) ((.matched) paired)
    ++ concatMap addedIdDiff ((.added) paired)
    ++ concatMap removedIdDiff ((.removed) paired)
  where
    paired = pairDeclarations (.name) ((.ids) ((.old) env)) ((.ids) ((.new) env))

idPairDiff :: Spec -> IdDecl -> IdDecl -> [Change]
idPairDiff oldSpec oldId newId =
  [ breaking ((.name) newId) "id-prefix" ((.name) newId) IdPrefixChanged ("prefix changed '" <> (.prefix) oldId <> "' -> '" <> (.prefix) newId <> "'; stored and newly minted ids no longer share an identity domain")
  | (.prefix) oldId /= (.prefix) newId
  ]
    <> nominalBindingDeclDiff oldSpec "id" ((.name) newId) ((.binding) oldId) ((.binding) newId)
    <> [ nominalUseChange
           use
           NominalIdDecoderTightened
           "adopting a checked KindID binding tightens historical decoding; keep a committed valid old-payload fixture and run the targeted real-log audit for this event"
       | (.binding) oldId == Nothing,
         isJust ((.binding) newId),
         use@NominalEventUse {} <- nominalUses oldSpec ((.name) oldId)
       ]

addedIdDiff :: IdDecl -> [Change]
addedIdDiff declaration = [additive ((.name) declaration) "id-prefix" ((.name) declaration) DeclarationAdded "new id declaration"]

removedIdDiff :: IdDecl -> [Change]
removedIdDiff declaration = [breaking ((.name) declaration) "id-prefix" ((.name) declaration) IdPrefixChanged "id declaration removed; persisted ids still use its prefix"]

enumDiff :: DiffEnv -> [Change]
enumDiff env =
  concatMap (uncurry (enumPairDiff ((.old) env))) ((.matched) paired)
    ++ concatMap addedEnumDiff ((.added) paired)
    ++ concatMap (removedEnumDiff ((.old) env)) ((.removed) paired)
  where
    paired = pairDeclarations (.name) ((.enums) ((.old) env)) ((.enums) ((.new) env))

enumPairDiff :: Spec -> EnumDecl -> EnumDecl -> [Change]
enumPairDiff oldSpec oldEnum newEnum =
  [ breaking ((.name) newEnum) "enum-constructor" ctor EnumCtorRemoved ("constructor removed; stored wire value '" <> wire <> "' no longer decodes" <> enumUsageSuffix oldSpec ((.name) oldEnum))
  | (ctor, wire) <- (.ctors) oldEnum,
    isNothing (lookup ctor ((.ctors) newEnum))
  ]
    ++ [ breaking ((.name) newEnum) "enum-constructor" ctor EnumWireSpellingChanged ("wire spelling changed '" <> oldWire <> "' -> '" <> newWire <> "'; stored values using the old spelling no longer decode" <> enumUsageSuffix oldSpec ((.name) oldEnum))
       | (ctor, oldWire) <- (.ctors) oldEnum,
         Just newWire <- [lookup ctor ((.ctors) newEnum)],
         oldWire /= newWire
       ]
    ++ concat
      [ enumAdditionDiff oldSpec newEnum ctor wire
      | (ctor, wire) <- (.ctors) newEnum,
        isNothing (lookup ctor ((.ctors) oldEnum))
      ]
      <> nominalBindingDeclDiff oldSpec "enum" ((.name) newEnum) ((.binding) oldEnum) ((.binding) newEnum)

nominalScalarDiff :: DiffEnv -> [Change]
nominalScalarDiff env =
  concatMap (uncurry scalarPairDiff) ((.matched) paired)
    <> [nominalDeclarationChange ((.name) declaration) DeclarationAdded "new nominal scalar declaration" | declaration <- (.added) paired]
    <> [nominalDeclarationChange ((.name) declaration) NominalRepresentationChanged "nominal scalar declaration removed while persisted uses may remain" | declaration <- (.removed) paired]
  where
    paired = pairDeclarations (.name) ((.nominalScalars) ((.old) env)) ((.nominalScalars) ((.new) env))
    scalarPairDiff oldDeclaration newDeclaration =
      [ nominalDeclarationChange
          ((.name) newDeclaration)
          NominalRepresentationChanged
          ( "nominal scalar representation changed '"
              <> (.representation) oldDeclaration
              <> "' -> '"
              <> (.representation) newDeclaration
              <> "'"
          )
      | (.representation) oldDeclaration /= (.representation) newDeclaration
      ]
        <> nominalBindingDeclDiff
          ((.old) env)
          "scalar"
          ((.name) newDeclaration)
          (Just ((.binding) oldDeclaration))
          (Just ((.binding) newDeclaration))

data NominalUse
  = NominalCommandUse !Name !Name !Name
  | NominalEventUse !Name !Name !Name
  | NominalRegisterUse !Name !Name

nominalUses :: Spec -> Name -> [NominalUse]
nominalUses spec target = concatMap usesInAggregate [aggregate | NAggregate aggregate <- (.nodes) spec]
  where
    usesInAggregate aggregate =
      [ NominalCommandUse ((.name) aggregate) ((.name) command) ((.name) field)
      | command <- (.commands) aggregate,
        field <- (.fields) command,
        fieldReferences target field
      ]
        <> [ NominalEventUse ((.name) aggregate) ((.name) event) ((.name) field)
           | event <- (.events) aggregate,
             field <- eventFields aggregate event,
             fieldReferences target field
           ]
        <> [ NominalRegisterUse ((.name) aggregate) ((.name) register)
           | register <- (.regs) aggregate,
             (.valueType) register == TRef target
           ]
    eventFields aggregate event = case (.body) event of
      EventFields fields -> fields
      EventFromCommand commandName -> concat [(.fields) command | command <- (.commands) aggregate, (.name) command == commandName]
    fieldReferences targetName field = case (.valueType) field of
      Just (TRef typeName) -> typeName == targetName
      Just _ -> False
      Nothing -> pascalName ((.name) field) == targetName
    pascalName value = case T.uncons value of
      Nothing -> value
      Just (initialChar, rest) -> T.cons (toUpper initialChar) rest

nominalBindingDeclDiff :: Spec -> Text -> Name -> Maybe NominalBindingDecl -> Maybe NominalBindingDecl -> [Change]
nominalBindingDeclDiff oldSpec category name oldBinding newBinding =
  concat
    [ nominalFinding NominalBindingChanged "binding source, symbol, or version changed; rebuild every consumer use and audit persisted event uses because hand-written conversion behavior is opaque"
    | bindingRuntimeFacts oldBinding /= bindingRuntimeFacts newBinding
    ]
    <> concat
      [ nominalFinding NominalFixturesChanged "fixture symbol changed; rerun nominal conformance without claiming runtime wire behavior changed"
      | ((\binding -> binding.fixtures) =<< oldBinding) /= ((\binding -> binding.fixtures) =<< newBinding)
      ]
    <> concat
      [ nominalFinding NominalCanonicalTypeChanged "canonical nominal identity changed; rebuild consumers and invalidate snapshot caches at register uses"
      | ((\binding -> binding.canonicalType) =<< oldBinding) /= ((\binding -> binding.canonicalType) =<< newBinding)
      ]
    <> concat
      [ nominalFinding NominalInitialChanged "consumer-owned initial value symbol changed; rebuild and invalidate snapshot-bearing register streams"
      | ((\binding -> binding.initial) =<< oldBinding) /= ((\binding -> binding.initial) =<< newBinding)
      ]
  where
    bindingRuntimeFacts declaration =
      ( (\binding -> binding.haskell) =<< declaration,
        (\binding -> binding.binding) =<< declaration,
        (\binding -> binding.bindingVersion) =<< declaration
      )
    nominalFinding code detail =
      nominalDeclarationChange name code (category <> " " <> detail)
        : [nominalUseChange use code detail | use <- nominalUses oldSpec name, includeUse code use]
    includeUse NominalFixturesChanged _ = False
    includeUse NominalCanonicalTypeChanged NominalRegisterUse {} = True
    includeUse NominalCanonicalTypeChanged _ = False
    includeUse NominalInitialChanged NominalRegisterUse {} = True
    includeUse NominalInitialChanged _ = False
    includeUse _ NominalCommandUse {} = False
    includeUse _ _ = True

nominalDeclarationChange :: Name -> DiagnosticCode -> Text -> Change
nominalDeclarationChange name code detail =
  mkChange
    (deriveLabel defaultGate vector)
    context
    name
    "nominal-build"
    name
    code
    detail
  where
    context = (consumerBuildContext name [name]) {contextOriginalLabel = LabelAdvisory}
    vector = classifyCompatibility context code

nominalUseChange :: NominalUse -> DiagnosticCode -> Text -> Change
nominalUseChange use code detail =
  mkChange (deriveLabel defaultGate vector) context root facet subject code detail
  where
    (root, facet, subject, kind) = case use of
      NominalCommandUse aggregate command field -> (aggregate, "nominal-command", aggregate <> " command " <> command <> " ." <> field, ContextConsumerBuild)
      NominalEventUse aggregate event field -> (aggregate, "nominal-event", aggregate <> " event " <> event <> " ." <> field, ContextPrivateEvent)
      NominalRegisterUse aggregate register -> (aggregate, "nominal-register", aggregate <> " register " <> register, ContextSnapshot)
    context = ChangeContext root [subject] kind LabelAdvisory
    vector = classifyCompatibility context code

addedEnumDiff :: EnumDecl -> [Change]
addedEnumDiff enumDecl =
  [additive ((.name) enumDecl) "enum-constructor" ctor EnumCtorAdded ("new enum constructor with wire spelling '" <> wire <> "'") | (ctor, wire) <- (.ctors) enumDecl]

enumAdditionDiff :: Spec -> EnumDecl -> Name -> Text -> [Change]
enumAdditionDiff oldSpec enumDecl ctor wire = case enumUsages oldSpec ((.name) enumDecl) of
  [] ->
    [ additive
        ((.name) enumDecl)
        "enum-constructor"
        ctor
        EnumCtorAdded
        ("new constructor with wire spelling '" <> wire <> "'")
    ]
  usages -> map finding usages
  where
    finding usage
      | ".reg." `T.isInfixOf` usage =
          advisoryAt
            (snapshotContext ((.name) enumDecl) [usage])
            ((.name) enumDecl)
            "enum-constructor"
            ctor
            EnumCtorAdded
            ("new constructor with wire spelling '" <> wire <> "' is used by " <> usage <> "; invalidate or rebuild snapshots before values using the new arm hydrate")
      | otherwise =
          advisoryAt
            (privateEventAdditionContext ((.name) enumDecl) [usage])
            ((.name) enumDecl)
            "enum-constructor"
            ctor
            EnumCtorAdded
            ("new constructor with wire spelling '" <> wire <> "' is used by " <> usage <> "; deploy consumers before producers emit the new arm")

removedEnumDiff :: Spec -> EnumDecl -> [Change]
removedEnumDiff oldSpec enumDecl =
  [ breaking ((.name) enumDecl) "enum-constructor" ctor EnumCtorRemoved ("enum removed; stored wire value '" <> wire <> "' no longer decodes" <> enumUsageSuffix oldSpec ((.name) enumDecl))
  | (ctor, wire) <- (.ctors) enumDecl
  ]

enumUsageSuffix :: Spec -> Name -> Text
enumUsageSuffix spec enumType = case enumUsages spec enumType of
  [] -> ""
  usages -> "; used by " <> commas usages

enumUsages :: Spec -> Name -> [Text]
enumUsages spec enumType =
  [(.name) agg <> ".reg." <> (.name) reg | agg <- aggregates, reg <- (.regs) agg, (.valueType) reg == TRef enumType]
    ++ [ (.name) agg <> ".event." <> (.name) event <> "." <> (.dslName) field
       | agg <- aggregates,
         event <- (.events) agg,
         field <- eventFieldSigs agg event,
         Just fieldTypeName <- [(.valueType) field],
         fieldTypeName == TRef enumType
       ]
  where
    aggregates = [agg | NAggregate agg <- (.nodes) spec]

pairDeclarations :: (n -> Name) -> [n] -> [n] -> Paired n
pairDeclarations nameOf oldNodes newNodes =
  Paired
    { matched =
        [ (oldNode, newNode)
        | newNode <- newNodes,
          Just oldNode <- [find ((== nameOf newNode) . nameOf) oldNodes]
        ],
      added = [newNode | newNode <- newNodes, isNothing (find ((== nameOf newNode) . nameOf) oldNodes)],
      removed = [oldNode | oldNode <- oldNodes, isNothing (find ((== nameOf oldNode) . nameOf) newNodes)]
    }

contractDiff :: DiffEnv -> [Change]
contractDiff env =
  concatMap (uncurry contractPairDiff) ((.matched) paired)
    ++ concatMap addedContractDiff ((.added) paired)
    ++ concatMap removedContractDiff ((.removed) paired)
  where
    paired = pairByName nodeContract (.name) env

contractPairDiff :: ContractNode -> ContractNode -> [Change]
contractPairDiff oldContract newContract =
  schemaChanges
    ++ discriminatorChanges
    ++ topicChanges
    ++ concatMap eventPairChanges matchedEvents
    ++ concatMap addedEventChanges addedEvents
    ++ concatMap removedEventChanges removedEvents'
  where
    schemaChanges =
      [ breaking
          ((.name) newContract)
          "schema-version"
          ((.name) newContract)
          ContractSchemaVersionDecreased
          ("schemaVersion decreased from " <> tInt ((.schemaVersion) oldContract) <> " to " <> tInt ((.schemaVersion) newContract))
      | (.schemaVersion) newContract < (.schemaVersion) oldContract
      ]
    discriminatorChanges =
      [ breaking
          ((.name) newContract)
          "discriminator"
          ((.name) newContract)
          ContractDiscriminatorChanged
          ("discriminator changed " <> (.discriminator) oldContract <> " -> " <> (.discriminator) newContract)
      | (.discriminator) oldContract /= (.discriminator) newContract
      ]
    topicChanges = contractTopicDiff oldContract newContract
    eventPairs = pairDeclarations (.name) ((.events) oldContract) ((.events) newContract)
    matchedEvents = (.matched) eventPairs
    addedEvents = (.added) eventPairs
    removedEvents' = (.removed) eventPairs
    eventPairChanges (oldEvent, newEvent) = contractEventDiff oldContract newContract oldEvent newEvent
    addedEventChanges event =
      [additive ((.name) newContract) "contract-event" ((.name) event) ContractEventAdded "new contract event"]
    removedEventChanges event =
      [breaking ((.name) newContract) "contract-event" ((.name) event) ContractEventRemoved "contract event removed; existing cross-service payloads no longer have a declared decoder"]

addedContractDiff :: ContractNode -> [Change]
addedContractDiff contract =
  [additive ((.name) contract) "contract-event" ((.name) event) ContractEventAdded "new event in a new contract" | event <- (.events) contract]

removedContractDiff :: ContractNode -> [Change]
removedContractDiff contract =
  [breaking ((.name) contract) "contract-event" ((.name) event) ContractEventRemoved "contract removed; its cross-service event decoder is no longer declared" | event <- (.events) contract]

contractTopicDiff :: ContractNode -> ContractNode -> [Change]
contractTopicDiff oldContract newContract =
  [ breaking
      ((.name) newContract)
      "contract-topic"
      alias
      ContractTopicChanged
      ("topic alias removed; previous topic was '" <> oldTopic <> "'")
  | (alias, oldTopic) <- (.topics) oldContract,
    isNothing (lookup alias ((.topics) newContract))
  ]
    ++ [ breaking
           ((.name) newContract)
           "contract-topic"
           alias
           ContractTopicChanged
           ("real topic changed '" <> oldTopic <> "' -> '" <> newTopic <> "'")
       | (alias, oldTopic) <- (.topics) oldContract,
         Just newTopic <- [lookup alias ((.topics) newContract)],
         oldTopic /= newTopic
       ]
    ++ [ additive ((.name) newContract) "contract-topic" alias ContractTopicAdded ("new topic alias for '" <> topic <> "'")
       | (alias, topic) <- (.topics) newContract,
         isNothing (lookup alias ((.topics) oldContract))
       ]

contractEventDiff :: ContractNode -> ContractNode -> ContractEvent -> ContractEvent -> [Change]
contractEventDiff oldContract newContract oldEvent newEvent =
  topicAliasChange
    ++ removedFieldChanges
    ++ changedFieldChanges
    ++ selectorFieldChanges
    ++ wireKeyFieldChanges
    ++ addedFieldChanges
  where
    fieldPairs = pairDeclarations (.name) ((.fields) oldEvent) ((.fields) newEvent)
    topicAliasChange =
      [ breaking
          ((.name) newContract)
          "contract-topic"
          ((.name) newEvent)
          ContractTopicChanged
          ("event topic alias changed " <> (.topic) oldEvent <> " -> " <> (.topic) newEvent)
      | (.topic) oldEvent /= (.topic) newEvent
      ]
    removedFieldChanges =
      [ breaking ((.name) newContract) "contract-field" ((.name) newEvent <> "." <> (.name) field) ContractFieldChanged "field removed; existing messages still carry the old contract shape"
      | field <- (.removed) fieldPairs
      ]
    changedFieldChanges =
      [ breaking
          ((.name) newContract)
          "contract-field"
          ((.name) newEvent <> "." <> (.name) newField)
          ContractFieldChanged
          ("field type changed " <> renderContractType ((.valueType) oldField) <> " -> " <> renderContractType ((.valueType) newField))
      | (oldField, newField) <- (.matched) fieldPairs,
        (.valueType) oldField /= (.valueType) newField
      ]
    selectorFieldChanges =
      [ fieldSelectorChange
          ((.name) newContract)
          "contract-field-selector"
          ((.name) newEvent <> "." <> (.name) newField)
          ((.selector) (resolveContractFieldIdentity oldField))
          ((.selector) (resolveContractFieldIdentity newField))
          "contract field selector"
      | (oldField, newField) <- (.matched) fieldPairs,
        (.selector) (resolveContractFieldIdentity oldField)
          /= (.selector) (resolveContractFieldIdentity newField)
      ]
    wireKeyFieldChanges =
      [ breaking
          ((.name) newContract)
          "contract-field"
          ((.name) newEvent <> "." <> (.name) newField)
          ContractFieldChanged
          ( "wire key changed '"
              <> (.wireKey) (resolveContractFieldIdentity oldField)
              <> "' -> '"
              <> (.wireKey) (resolveContractFieldIdentity newField)
              <> "'; restore the old key or revise the public contract with a consumer-first rollout"
          )
      | (oldField, newField) <- (.matched) fieldPairs,
        (.wireKey) (resolveContractFieldIdentity oldField)
          /= (.wireKey) (resolveContractFieldIdentity newField)
      ]
    addedFieldChanges =
      [ if (.schemaVersion) newContract > (.schemaVersion) oldContract
          then advisory ((.name) newContract) "contract-field" subject ContractSchemaVersionBumped ("field added with schemaVersion bump " <> tInt ((.schemaVersion) oldContract) <> " -> " <> tInt ((.schemaVersion) newContract) <> "; coordinate the cross-service rollout")
          else breaking ((.name) newContract) "contract-field" subject ContractFieldChanged "field added without a schemaVersion bump; older in-flight messages do not contain it"
      | field <- (.added) fieldPairs,
        let subject = (.name) newEvent <> "." <> (.name) field
      ]

renderContractType :: ContractType -> Text
renderContractType (CTypeId prefix) = "typeid '" <> prefix <> "'"
renderContractType CText = "text"
renderContractType CInt = "int"

workqueueDiff :: DiffEnv -> [Change]
workqueueDiff env =
  concatMap (uncurry workqueuePairDiff) ((.matched) paired)
    ++ concatMap addedWorkqueueDiff ((.added) paired)
    ++ concatMap removedWorkqueueDiff ((.removed) paired)
  where
    paired = pairWorkqueues env

-- | Prefer source identity, then pair a uniquely renamed queue by its complete
-- explicit runtime identity. This permits a generated module-segment rename to
-- remain a build-only finding without guessing when an external identity is
-- ambiguous.
pairWorkqueues :: DiffEnv -> Paired WorkqueueNode
pairWorkqueues env =
  Paired
    { matched = exact <> fallback,
      added = [queue | queue <- unmatchedNew, queue `notElem` map snd fallback],
      removed = [queue | queue <- unmatchedOld, queue `notElem` map fst fallback]
    }
  where
    oldQueues = mapMaybe nodeWorkqueue ((.nodes) ((.old) env))
    newQueues = mapMaybe nodeWorkqueue ((.nodes) ((.new) env))
    exact =
      [ (oldQueue, newQueue)
      | newQueue <- newQueues,
        Just oldQueue <- [find ((== (.name) newQueue) . (.name)) oldQueues]
      ]
    exactOldNames = map ((.name) . fst) exact
    exactNewNames = map ((.name) . snd) exact
    unmatchedOld = [queue | queue <- oldQueues, (.name) queue `notElem` exactOldNames]
    unmatchedNew = [queue | queue <- newQueues, (.name) queue `notElem` exactNewNames]
    fallback =
      [ (oldQueue, newQueue)
      | newQueue <- unmatchedNew,
        let matchingOld = [queue | queue <- unmatchedOld, queueIdentity queue == queueIdentity newQueue],
        [oldQueue] <- [matchingOld],
        length [queue | queue <- unmatchedNew, queueIdentity queue == queueIdentity newQueue] == 1
      ]

workqueuePairDiff :: WorkqueueNode -> WorkqueueNode -> [Change]
workqueuePairDiff oldQueue newQueue =
  generatedNameChanges
    ++ concatMap pairedFieldDiff ((.matched) fields)
    ++ concatMap addedFieldDiff ((.added) fields)
    ++ concatMap removedFieldDiff ((.removed) fields)
    ++ queueIdentityDiff oldQueue newQueue
    ++ queuePolicyDiff oldQueue newQueue
  where
    generatedNameChanges =
      [ generatedNameChange
          ((.name) newQueue)
          "workqueue-module"
          ((.name) newQueue)
          ((.name) oldQueue)
          ((.name) newQueue)
          "workqueue module segment"
      | (.name) oldQueue /= (.name) newQueue,
        normalizedGeneratedUpper ((.name) oldQueue) /= normalizedGeneratedUpper ((.name) newQueue)
      ]
        ++ [ generatedNameChange
               ((.name) newQueue)
               "workqueue-payload-type"
               ((.payloadName) newQueue)
               ((.payloadName) oldQueue)
               ((.payloadName) newQueue)
               "workqueue payload type"
           | (.payloadName) oldQueue /= (.payloadName) newQueue,
             normalizedGeneratedUpper ((.payloadName) oldQueue) /= normalizedGeneratedUpper ((.payloadName) newQueue)
           ]
    fields = pairDeclarations (.name) ((.payload) oldQueue) ((.payload) newQueue)
    pairedFieldDiff (oldField, newField)
      | (.wire) oldField /= (.wire) newField = [payloadBreaking newField ("wire name changed '" <> (.wire) oldField <> "' -> '" <> (.wire) newField <> "'")]
      | (.valueType) oldField /= (.valueType) newField = [payloadBreaking newField ("type changed " <> renderQueuePayloadType ((.valueType) oldField) <> " -> " <> renderQueuePayloadType ((.valueType) newField))]
      | otherwise = []
    renderQueuePayloadType (LegacyQueueScalar scalar) = queueScalarName scalar
    renderQueuePayloadType (TypedQueueExpression expression) = typeExprCanonicalName expression
    -- Every payload field is required, so adding one always breaks jobs already
    -- queued under the old shape; there is no optional variant to strengthen.
    addedFieldDiff field = [payloadBreaking field "new required field; queued jobs do not contain it"]
    removedFieldDiff field = [payloadBreaking field "field removed; queued jobs still contain the old payload shape"]
    payloadBreaking field detail =
      withMappedConsequences
        (Set.fromList [MappedConsumerBuild consumer, MappedWorkqueueHistory ((.name) newQueue)])
        (breaking ((.name) newQueue) "payload-field" ((.name) field) WqPayloadFieldChanged detail)
      where
        consumer = WorkqueueConsumer ((.name) newQueue)

addedWorkqueueDiff :: WorkqueueNode -> [Change]
addedWorkqueueDiff queue =
  [additive ((.name) queue) "payload-field" ((.name) field) DeclarationAdded "field belongs to a new workqueue payload" | field <- (.payload) queue]

removedWorkqueueDiff :: WorkqueueNode -> [Change]
removedWorkqueueDiff queue =
  [breaking ((.name) queue) "payload-field" ((.name) field) WqPayloadFieldChanged "workqueue removed while persisted jobs may still carry this payload" | field <- (.payload) queue]
    ++ [breaking ((.name) queue) "queue-identity" ((.name) queue) QueueIdentityChanged "workqueue removed; its physical queue, DLQ, and pgmq table may still hold state"]

queueIdentityDiff :: WorkqueueNode -> WorkqueueNode -> [Change]
queueIdentityDiff oldQueue newQueue =
  [ breaking
      ((.name) newQueue)
      "queue-identity"
      ((.name) newQueue)
      QueueIdentityChanged
      "logical, physical, DLQ, or table name changed; queued jobs and dispatch dedupe records remain under the old identity"
  | queueIdentity oldQueue /= queueIdentity newQueue
  ]

queueIdentity :: WorkqueueNode -> (Text, Text, Text, Text)
queueIdentity queue = ((.logical) queue, (.physical) queue, (.dlq) queue, (.table) queue)

generatedNameChange :: Name -> Text -> Text -> Text -> Text -> Text -> Change
generatedNameChange node facet subject oldLogical newLogical occurrenceKind =
  advisory
    node
    facet
    subject
    GeneratedHaskellNameChanged
    ( occurrenceKind
        <> " changed '"
        <> normalizedGeneratedUpper oldLogical
        <> "' -> '"
        <> normalizedGeneratedUpper newLogical
        <> "' while wire, SQL, queue, registry, subscription, and persisted runtime identities remain unchanged; re-scaffold and recompile consumers"
    )

fieldSelectorChange :: Name -> Text -> Text -> Text -> Text -> Text -> Change
fieldSelectorChange node facet subject oldSelector newSelector occurrenceKind =
  advisory
    node
    facet
    subject
    GeneratedHaskellNameChanged
    ( occurrenceKind
        <> " changed '"
        <> oldSelector
        <> "' -> '"
        <> newSelector
        <> "' while DSL and wire identities remain unchanged; re-scaffold and recompile consumers"
    )

normalizedGeneratedUpper :: Text -> Text
normalizedGeneratedUpper logicalName =
  case HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site of
    Right derived -> HaskellName.renderUpperCamelName ((.upperCamel) derived)
    Left _ -> logicalName
  where
    site =
      HaskellName.NameSite
        { HaskellName.kind = HaskellName.GeneratedTypeSite,
          HaskellName.logicalName = logicalName,
          HaskellName.owner = "diff",
          HaskellName.line = 0
        }

queuePolicyDiff :: WorkqueueNode -> WorkqueueNode -> [Change]
queuePolicyDiff oldQueue newQueue = ordering ++ provision ++ groupKey
  where
    nodeName = (.name) newQueue
    ordering =
      [ breaking nodeName "queue-ordering" nodeName WqOrderingChanged $
          "ordering changed " <> renderWqOrdering ((.ordering) oldQueue) <> " -> " <> renderWqOrdering ((.ordering) newQueue) <> "; consumers were written against the old delivery-order contract"
      | (.ordering) oldQueue /= (.ordering) newQueue
      ]
    provision =
      [ breaking nodeName "queue-provision" nodeName WqProvisionChanged $
          "provision changed " <> renderWqProvision ((.provision) oldQueue) <> " -> " <> renderWqProvision ((.provision) newQueue) <> "; provisioning is create-time only, so migrate the existing queue operationally before changing the spec"
      | (.provision) oldQueue /= (.provision) newQueue
      ]
    groupKey =
      [ breaking nodeName "queue-group-key" nodeName WqGroupKeyChanged $
          "group key derivation changed " <> renderWqGroupKey ((.groupKey) oldQueue) <> " -> " <> renderWqGroupKey ((.groupKey) newQueue) <> "; FIFO messages are re-partitioned across durable ordering groups"
      | (.groupKey) oldQueue /= (.groupKey) newQueue
      ]

renderWqOrdering :: WqOrdering -> Text
renderWqOrdering WqUnordered = "unordered"
renderWqOrdering WqFifoThroughput = "fifo-throughput"
renderWqOrdering WqFifoRoundRobin = "fifo-roundrobin"

renderWqProvision :: WqProvision -> Text
renderWqProvision WqStandard = "standard"
renderWqProvision WqUnlogged = "unlogged"
renderWqProvision (WqPartitioned interval duration) = "partitioned(interval=" <> interval <> ", retention=" <> duration <> ")"

renderWqGroupKey :: Maybe WqGroupKey -> Text
renderWqGroupKey Nothing = "none"
renderWqGroupKey (Just groupKey) =
  (.field) groupKey
    <> " via "
    <> (.via) groupKey
    <> maybe "" (" fixture " <>) ((.fixture) groupKey)

processDiff :: DiffEnv -> [Change]
processDiff env =
  concatMap (uncurry processPairDiff) ((.matched) paired)
    ++ concatMap addedProcessDiff ((.added) paired)
    ++ concatMap removedProcessDiff ((.removed) paired)
  where
    paired = pairByName nodeProcess (.id) env

processPairDiff :: ProcessNode -> ProcessNode -> [Change]
processPairDiff oldProcess newProcess =
  concatMap pairedFieldDiff ((.matched) fields)
    ++ map (fieldChange "field added; source events at the old shape cannot populate it") ((.added) fields)
    ++ map (fieldChange "field removed; the generated process input decoder changed") ((.removed) fields)
    ++ processIdentityDiff oldProcess newProcess
    ++ processTimerWindowDiff oldProcess newProcess
    ++ processDecideSurfaceDiff oldProcess newProcess
    ++ processTimerPayloadDiff oldProcess newProcess
  where
    -- inName is a generated Haskell type name; the wire shape is inFields.
    fields = pairDeclarations (.name) ((.fields) ((.input) oldProcess)) ((.fields) ((.input) newProcess))
    pairedFieldDiff (oldField, newField)
      | (.valueType) oldField /= (.valueType) newField = [fieldChange ("type changed " <> renderFieldType ((.valueType) oldField) <> " -> " <> renderFieldType ((.valueType) newField)) newField]
      | otherwise = []
    fieldChange detail field = breaking ((.id) newProcess) "input-field" ((.name) field) ProcessInputChanged (detail <> "; version the source event before changing process input")

addedProcessDiff :: ProcessNode -> [Change]
addedProcessDiff process =
  [additive ((.id) process) "input-field" ((.name) field) DeclarationAdded "field belongs to a new process input" | field <- (.fields) ((.input) process)]

removedProcessDiff :: ProcessNode -> [Change]
removedProcessDiff process =
  [breaking ((.id) process) "input-field" ((.name) field) ProcessInputChanged "process removed while persisted source events may still require this input decoder" | field <- (.fields) ((.input) process)]
    ++ [breaking ((.id) process) "derived-identity" ((.id) process) DerivedIdentityChanged "process removed while persisted saga, dispatch, and timer identities may still exist"]

processIdentityDiff :: ProcessNode -> ProcessNode -> [Change]
processIdentityDiff oldProcess newProcess =
  [ breaking
      ((.id) newProcess)
      "derived-identity"
      ((.id) newProcess)
      DerivedIdentityChanged
      "process name, correlation derivation, saga stream category, timer id expression, or fired-event-id expression changed; replays and retries no longer derive the persisted identity"
  | processIdentity oldProcess /= processIdentity newProcess
  ]

processIdentity :: ProcessNode -> (Text, Name, Name, Text, Text, Name, Text, Name)
processIdentity process =
  ( (.name) process,
    (.field) ((.correlate) process),
    (.via) ((.correlate) process),
    (.category) ((.saga) process),
    (.prefix) ((.id) ((.timer) process)),
    (.field) ((.id) ((.timer) process)),
    (.prefix) ((.firedEventId) ((.fire) ((.timer) process))),
    (.field) ((.firedEventId) ((.fire) ((.timer) process)))
  )

processTimerWindowDiff :: ProcessNode -> ProcessNode -> [Change]
processTimerWindowDiff oldProcess newProcess =
  [ advisory
      ((.id) newProcess)
      "timer"
      ((.name) ((.timer) newProcess))
      TimerWindowChanged
      ( "fireAt source/window changed "
          <> renderFireAt ((.fireAt) ((.timer) oldProcess))
          <> " -> "
          <> renderFireAt ((.fireAt) ((.timer) newProcess))
          <> "; already-scheduled timers keep their persisted deadline"
      )
  | (.fireAt) ((.timer) oldProcess) /= (.fireAt) ((.timer) newProcess)
  ]

processDecideSurfaceDiff :: ProcessNode -> ProcessNode -> [Change]
processDecideSurfaceDiff oldProcess newProcess =
  [ advisory
      ((.id) newProcess)
      "process-decide"
      ((.id) newProcess)
      ProcessDecideSurfaceChanged
      "process dispatch surface changed: a source event redelivered across the deploy dispatches under the same deterministic ids, so half-old/half-new fan-out merges silently. Drain or pause the process subscription and replay or discard dead letters before deploying; see docs/user/deploy-ordering.md. Hole-only decide changes are not visible to diff; the same drain rule applies to those too."
  | renderHandleSurface ((.handle) oldProcess)
      /= renderHandleSurface ((.handle) newProcess)
  ]

processTimerPayloadDiff :: ProcessNode -> ProcessNode -> [Change]
processTimerPayloadDiff oldProcess newProcess =
  [ advisory
      ((.id) newProcess)
      "timer-payload"
      ((.name) ((.timer) newProcess))
      ProcessTimerPayloadChanged
      "timer payload shape changed: rows scheduled before the deploy carry the old shape, unversioned, and fire under new code — the fire decoder must accept every historically scheduled shape or the timer dead-letters after maxAttempts. Hole-only timer-decoder changes are not visible to diff; the same drain rule applies to those too."
  | renderTimerPayloadSurface ((.timer) oldProcess)
      /= renderTimerPayloadSurface ((.timer) newProcess)
  ]

renderFireAt :: FireAtExpr -> Text
renderFireAt expression = "input." <> (.field) expression <> " + " <> (.window) expression

workflowDiff :: DiffEnv -> [Change]
workflowDiff env =
  concatMap (uncurry workflowPairDiff) ((.matched) paired)
    ++ concatMap addedWorkflowDiff ((.added) paired)
    ++ concatMap removedWorkflowDiff ((.removed) paired)
  where
    paired = pairByName nodeWorkflow (.id) env

workflowPairDiff :: WorkflowNode -> WorkflowNode -> [Change]
workflowPairDiff oldWorkflow newWorkflow =
  inputChanges
    ++ outputChanges
    ++ classifyWorkflowBody oldWorkflow newWorkflow
    ++ workflowIdentityDiff oldWorkflow newWorkflow
  where
    fields = pairDeclarations (.name) ((.inputFields) oldWorkflow) ((.inputFields) newWorkflow)
    inputChanges =
      [workflowShape field "input field added; journaled inputs at the old shape do not contain it" | field <- (.added) fields]
        ++ [workflowShape field "input field removed; journaled inputs still contain the old shape" | field <- (.removed) fields]
        ++ [ workflowShape newField ("input field type changed " <> renderFieldType ((.valueType) oldField) <> " -> " <> renderFieldType ((.valueType) newField))
           | (oldField, newField) <- (.matched) fields,
             (.valueType) oldField /= (.valueType) newField
           ]
    outputChanges =
      [ breaking ((.id) newWorkflow) "workflow-output" ((.output) newWorkflow) WorkflowShapeChanged ("output type changed " <> (.output) oldWorkflow <> " -> " <> (.output) newWorkflow <> "; persisted outcomes may no longer decode")
      | (.output) oldWorkflow /= (.output) newWorkflow
      ]
    workflowShape field detail = breaking ((.id) newWorkflow) "workflow-input" ((.name) field) WorkflowShapeChanged detail

addedWorkflowDiff :: WorkflowNode -> [Change]
addedWorkflowDiff workflow = [additive ((.id) workflow) "workflow" ((.id) workflow) DeclarationAdded "new workflow"]

removedWorkflowDiff :: WorkflowNode -> [Change]
removedWorkflowDiff workflow = [breaking ((.id) workflow) "workflow" ((.id) workflow) WorkflowShapeChanged "workflow removed while in-flight journals and outcomes may still require its decoder"]

workflowIdentityDiff :: WorkflowNode -> WorkflowNode -> [Change]
workflowIdentityDiff oldWorkflow newWorkflow =
  [ breaking
      ((.id) newWorkflow)
      "workflow-name"
      ((.id) newWorkflow)
      WorkflowStableNameChanged
      ("stable name changed '" <> (.stable) oldWorkflow <> "' -> '" <> (.stable) newWorkflow <> "'; in-flight journals remain under the old stream name")
  | (.stable) oldWorkflow /= (.stable) newWorkflow
  ]
    ++ [ breaking
           ((.id) newWorkflow)
           "derived-identity"
           ((.id) newWorkflow)
           DerivedIdentityChanged
           "workflow id source field or derivation changed; journal and deterministic child/step identities no longer coalesce with persisted executions"
       | ((.idField) oldWorkflow, (.idVia) oldWorkflow) /= ((.idField) newWorkflow, (.idVia) newWorkflow)
       ]

intakeDiff :: DiffEnv -> [Change]
intakeDiff env =
  concatMap (uncurry intakePairDiff) ((.matched) paired)
    ++ concatMap addedIntakeDiff ((.added) paired)
    ++ concatMap removedIntakeDiff ((.removed) paired)
  where
    paired = pairByName nodeIntake (.name) env

intakePairDiff :: IntakeNode -> IntakeNode -> [Change]
intakePairDiff oldIntake newIntake =
  [ breaking
      ((.name) newIntake)
      "dedupe-identity"
      ((.name) newIntake)
      DedupeIdentityChanged
      "dedupe key or policy changed; redelivered messages no longer match their persisted dedupe record"
  | ((.dedupeKey) oldIntake, (.dedupePolicy) oldIntake) /= ((.dedupeKey) newIntake, (.dedupePolicy) newIntake)
  ]
    ++ [ advisory
           ((.name) newIntake)
           "decode-posture"
           ((.name) newIntake)
           DecodePostureChanged
           "envelope/body decode posture changed; future messages are accepted or rejected differently"
       | (.decode) oldIntake /= (.decode) newIntake
       ]
    ++ [ advisory
           ((.name) newIntake)
           "inbox-persistence"
           ((.name) newIntake)
           IntakePersistenceChanged
           ("success-path envelope persistence changed " <> renderInkPersist ((.persist) oldIntake) <> " -> " <> renderInkPersist ((.persist) newIntake) <> "; existing rows are unchanged while future successful rows retain a different envelope shape")
       | (.persist) oldIntake /= (.persist) newIntake
       ]

renderInkPersist :: InkPersist -> Text
renderInkPersist InkPersistFull = "full-envelope"
renderInkPersist InkPersistDedupeOnly = "dedupe-only"

addedIntakeDiff :: IntakeNode -> [Change]
addedIntakeDiff intake = [additive ((.name) intake) "intake" ((.name) intake) DeclarationAdded "new intake"]

removedIntakeDiff :: IntakeNode -> [Change]
removedIntakeDiff intake = [breaking ((.name) intake) "dedupe-identity" ((.name) intake) DedupeIdentityChanged "intake removed while persisted dedupe records and redeliveries may remain"]

emitDiff :: DiffEnv -> [Change]
emitDiff env =
  concatMap (uncurry emitPairDiff) ((.matched) paired)
    ++ concatMap addedEmitDiff ((.added) paired)
    ++ concatMap removedEmitDiff ((.removed) paired)
  where
    paired = pairByName nodeEmit (.name) env

emitPairDiff :: EmitNode -> EmitNode -> [Change]
emitPairDiff oldEmit newEmit =
  [ breaking
      ((.name) newEmit)
      "derived-identity"
      "messageId"
      DerivedIdentityChanged
      "messageId derive prefix changed; outbox retries no longer coalesce with persisted messages"
  | (.messageId) oldEmit /= (.messageId) newEmit
  ]
    ++ [ breaking
           ((.name) newEmit)
           "derived-identity"
           "idempotencyKey"
           DerivedIdentityChanged
           "idempotencyKey derive prefix changed; downstream dedupe no longer matches persisted messages"
       | (.idempotencyKey) oldEmit /= (.idempotencyKey) newEmit
       ]
    ++ [ advisory
           ((.name) newEmit)
           "emit-mapping"
           ((.name) newEmit)
           EmitMappingChanged
           "emit key, status discriminant, mapping rows, or explicit skip posture changed"
       | emitMapping oldEmit /= emitMapping newEmit
       ]

emitMapping :: EmitNode -> (Name, Name, [EmitMapRow], Bool)
emitMapping emit = ((.key) emit, (.discriminant) emit, (.map) emit, (.skip) emit)

addedEmitDiff :: EmitNode -> [Change]
addedEmitDiff emit = [additive ((.name) emit) "emit" ((.name) emit) DeclarationAdded "new emit mapping"]

removedEmitDiff :: EmitNode -> [Change]
removedEmitDiff emit = [breaking ((.name) emit) "derived-identity" ((.name) emit) DerivedIdentityChanged "emit removed while persisted outbox identities may still retry"]

publisherDiff :: DiffEnv -> [Change]
publisherDiff env =
  concatMap (uncurry publisherPairDiff) ((.matched) paired)
    ++ concatMap addedPublisherDiff ((.added) paired)
    ++ concatMap removedPublisherDiff ((.removed) paired)
  where
    paired = pairByName nodePublisher (.name) env

publisherPairDiff :: PublisherNode -> PublisherNode -> [Change]
publisherPairDiff oldPublisher newPublisher =
  -- maxAttempts/backoff are retry tuning, not persisted decode or identity.
  [ breaking
      ((.name) newPublisher)
      "derived-identity"
      "outboxId"
      DerivedIdentityChanged
      "stable outbox-id source field changed; retries no longer coalesce with persisted outbox rows"
  | (.outboxField) oldPublisher /= (.outboxField) newPublisher
  ]
    ++ [ advisory
           ((.name) newPublisher)
           "publisher-policy"
           ((.name) newPublisher)
           PublisherPolicyChanged
           ("ordering changed " <> (.ordering) oldPublisher <> " -> " <> (.ordering) newPublisher)
       | (.ordering) oldPublisher /= (.ordering) newPublisher
       ]

addedPublisherDiff :: PublisherNode -> [Change]
addedPublisherDiff publisher = [additive ((.name) publisher) "publisher" ((.name) publisher) DeclarationAdded "new publisher"]

removedPublisherDiff :: PublisherNode -> [Change]
removedPublisherDiff publisher = [breaking ((.name) publisher) "derived-identity" ((.name) publisher) DerivedIdentityChanged "publisher removed while persisted outbox rows may still require its stable identity"]

pgmqDispatchDiff :: DiffEnv -> [Change]
pgmqDispatchDiff env =
  concatMap (uncurry pgmqDispatchPairDiff) ((.matched) paired)
    ++ concatMap addedPgmqDispatchDiff ((.added) paired)
    ++ concatMap removedPgmqDispatchDiff ((.removed) paired)
  where
    paired = pairByName nodePgmqDispatch (.name) env

pgmqDispatchPairDiff :: PgmqDispatchNode -> PgmqDispatchNode -> [Change]
pgmqDispatchPairDiff oldDispatch newDispatch =
  [ breaking
      ((.name) newDispatch)
      "dedupe-identity"
      ((.name) newDispatch)
      DedupeIdentityChanged
      "dispatch dedupe key/read-model/queue surface changed; prior enqueue records no longer match"
  | dispatchDedupe oldDispatch /= dispatchDedupe newDispatch
  ]
    ++ [ advisory
           ((.name) newDispatch)
           "retarget"
           ((.name) newDispatch)
           DispatchRetargeted
           "source read model or target queue changed; future fan-out is routed differently"
       | dispatchTargets oldDispatch /= dispatchTargets newDispatch
       ]

dispatchDedupe :: PgmqDispatchNode -> (Name, Name, Text, Name, Text)
dispatchDedupe dispatch =
  ( (.dedupKey) dispatch,
    (.dedupReadModel) dispatch,
    (.dedupReadModelField) dispatch,
    (.dedupQueue) dispatch,
    (.dedupQueueField) dispatch
  )

dispatchTargets :: PgmqDispatchNode -> (Name, Name)
dispatchTargets dispatch = ((.sourceReadModel) dispatch, (.enqueueTo) dispatch)

addedPgmqDispatchDiff :: PgmqDispatchNode -> [Change]
addedPgmqDispatchDiff dispatch = [additive ((.name) dispatch) "dispatch" ((.name) dispatch) DeclarationAdded "new pgmq dispatch"]

removedPgmqDispatchDiff :: PgmqDispatchNode -> [Change]
removedPgmqDispatchDiff dispatch = [breaking ((.name) dispatch) "dedupe-identity" ((.name) dispatch) DedupeIdentityChanged "dispatch removed while persisted queue and read-model dedupe records may remain"]

-- | Classify the runtime's sanctioned workflow-evolution mechanisms before
-- falling back to the conservative unguarded-body rule.
classifyWorkflowBody :: WorkflowNode -> WorkflowNode -> [Change]
classifyWorkflowBody oldWorkflow newWorkflow
  | oldBody == newBody = []
  | not (null removedPatchIds) = map removedPatch removedPatchIds
  | Just (oldSeedType, newSeedType) <- changedSeed =
      [ breaking nodeName "workflow-continue-as-new" nodeName WorkflowContinueSeedChanged $
          "continueAsNew seed type changed " <> oldSeedType <> " -> " <> newSeedType <> "; the next generation's restoreSeed must decode the seed written by the previous generation"
      ]
  | safeAdditions =
      map addedPatch newPatchIds
        ++ [ additive nodeName "workflow-continue-as-new" seedType WorkflowEvolutionGuardAdded "terminal continueAsNew is additive; old generations carry no rotation marker"
           | Just seedType <- [appendedSeed]
           ]
  | otherwise =
      [ breaking
          nodeName
          "workflow-body"
          nodeName
          WorkflowBodyChanged
          "workflow body labels, kinds, result types, or order changed without a new patch guard; wrap a cross-cutting change in patch, or rename the replay label for one changed step"
      ]
  where
    nodeName = (.id) newWorkflow
    oldBody = normaliseWorkflowBody ((.body) oldWorkflow)
    newBody = normaliseWorkflowBody ((.body) newWorkflow)
    oldPatchIds = workflowBodyPatchIds oldBody
    newPatchIdsAll = workflowBodyPatchIds newBody
    newPatchIds = newPatchIdsAll \\ oldPatchIds
    removedPatchIds = oldPatchIds \\ newPatchIdsAll
    oldSeed = terminalContinueSeed oldBody
    newSeed = terminalContinueSeed newBody
    changedSeed = case (oldSeed, newSeed) of
      (Just oldSeedType, Just newSeedType)
        | oldSeedType /= newSeedType -> Just (oldSeedType, newSeedType)
      _ -> Nothing
    appendedSeed = case (oldSeed, newSeed) of
      (Nothing, Just seedType) -> Just seedType
      _ -> Nothing
    strippedNewBody = stripNewPatches newPatchIds newBody
    comparableNewBody = case appendedSeed of
      Just _ -> dropTerminalContinue strippedNewBody
      Nothing -> strippedNewBody
    safeAdditions =
      (not (null newPatchIds) || isJust appendedSeed)
        && comparableNewBody == oldBody
    removedPatch patchId =
      breaking nodeName "workflow-patch" patchId WorkflowPatchRemoved "patch id existed in the old spec but was removed; the differ cannot prove that no workflow generation still replays its journaled branch"
    addedPatch patchId =
      additive nodeName "workflow-patch" patchId WorkflowEvolutionGuardAdded "new patch guard contains the entire body change, so in-flight generations retain their journaled branch"

normaliseWorkflowBody :: [WfBodyItem] -> [WfBodyItem]
normaliseWorkflowBody = map go
  where
    go (WfStep label result _) = WfStep label result noLoc
    go (WfAwait label result _) = WfAwait label result noLoc
    go (WfSleep label delay _) = WfSleep label delay noLoc
    go (WfChild label via result _) = WfChild label via result noLoc
    go (WfPatch patchId items _) = WfPatch patchId (normaliseWorkflowBody items) noLoc
    go (WfContinueAsNew seedType _) = WfContinueAsNew seedType noLoc

workflowBodyPatchIds :: [WfBodyItem] -> [Name]
workflowBodyPatchIds = concatMap go
  where
    go (WfPatch patchId items _) = patchId : workflowBodyPatchIds items
    go _ = []

stripNewPatches :: [Name] -> [WfBodyItem] -> [WfBodyItem]
stripNewPatches newPatchIds = concatMap go
  where
    go (WfPatch patchId _ _) | patchId `elem` newPatchIds = []
    go (WfPatch patchId items loc) = [WfPatch patchId (stripNewPatches newPatchIds items) loc]
    go item = [item]

terminalContinueSeed :: [WfBodyItem] -> Maybe Name
terminalContinueSeed items = case reverse items of
  WfContinueAsNew seedType _ : _ -> Just seedType
  _ -> Nothing

dropTerminalContinue :: [WfBodyItem] -> [WfBodyItem]
dropTerminalContinue items = case reverse items of
  WfContinueAsNew {} : rest -> reverse rest
  _ -> items

additive :: Name -> Text -> Text -> DiagnosticCode -> Text -> Change
additive n facet subj code detail =
  mkChange LabelAdditive (contextFor LabelAdditive n facet subj code) n facet subj code detail

breaking :: Name -> Text -> Text -> DiagnosticCode -> Text -> Change
breaking n facet subj code detail =
  mkChange LabelBreaking (contextFor LabelBreaking n facet subj code) n facet subj code detail

advisory :: Name -> Text -> Text -> DiagnosticCode -> Text -> Change
advisory n facet subj code detail =
  mkChange LabelAdvisory (contextFor LabelAdvisory n facet subj code) n facet subj code detail

advisoryAt :: ChangeContext -> Name -> Text -> Text -> DiagnosticCode -> Text -> Change
advisoryAt context n facet subj code detail =
  mkChange LabelAdvisory context n facet subj code detail

mkChange :: Label -> ChangeContext -> Name -> Text -> Text -> DiagnosticCode -> Text -> Change
mkChange label context n facet subj code detail =
  wrap
    ChangeKind
      { node = n,
        facet = facet,
        subject = subj,
        code = code,
        context = context,
        vector = classifyCompatibility context code,
        mappedPersistedImpact = case (.contextKind) context of
          ContextQueue -> Just (MappedPersistedImpact (WorkqueueHistory ((.root) context)) VBreaking)
          _ -> Nothing,
        mappedConsequences = Set.empty,
        paths = (.paths) context,
        detail = detail
      }
  where
    wrap = case label of
      LabelAdditive -> Additive
      LabelAdvisory -> Advisory
      LabelBreaking -> Breaking

contextFor :: Label -> Name -> Text -> Text -> DiagnosticCode -> ChangeContext
contextFor label root facet subject code =
  setLabel $ case () of
    _
      | code `elem` publicCodes -> publicContractContext root paths
      | code `elem` queueCodes -> queueContext root paths
      | code `elem` identityCodes -> persistedIdentityContext root paths
      | code `elem` [OwnershipMoved, WorkspaceAuthorityChanged, GeneratedHaskellNameChanged] -> consumerBuildContext root paths
      | code == AggFoldSurfaceChanged -> snapshotContext root paths
      | code == EnumCtorAdded -> ChangeContext root paths ContextGeneral label
      | code `elem` privateCodes -> privateEventContext root paths
      | otherwise -> ChangeContext root paths ContextGeneral label
  where
    paths = [pathFor root facet subject]
    setLabel context = ChangeContext context.root context.paths context.contextKind label
    publicCodes =
      [ ContractEventRemoved,
        ContractFieldChanged,
        ContractTypeIdDomainChanged,
        ContractDiscriminatorChanged,
        ContractTopicChanged,
        ContractSchemaVersionDecreased,
        ContractSchemaVersionBumped,
        ContractEventAdded,
        ContractTopicAdded
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
        ReadModelConsistencyWeakened,
        ProjectionDeliveryChanged,
        QueryFreshnessChanged
      ]
    privateCodes =
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
        WorkflowContinueSeedChanged,
        AggGuardTightened,
        DeprecatedEventReplayHazard,
        EventRetirementInProgress,
        EventUndeprecated,
        ProcessTimerPayloadChanged
      ]

pathFor :: Name -> Text -> Text -> Text
pathFor root facet subject
  | facet `elem` ["event", "event-field"] = root <> ".event." <> subject
  | facet `elem` ["contract-event", "contract-field"] = root <> ".event." <> subject
  | root == subject = root <> "." <> facet
  | otherwise = root <> "." <> facet <> "." <> subject

commas :: [Text] -> Text
commas = T.intercalate ", "

tInt :: Int -> Text
tInt = T.pack . show
