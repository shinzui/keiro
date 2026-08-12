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
    privateEventContext,
    privateEventAdditionContext,
    snapshotContext,
    queueContext,
    publicContractContext,
    persistedIdentityContext,
    consumerBuildContext,
    advisoryAt,
    changeContextRoot,
    changeContextPaths,
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
import Keiro.Dsl.ReadModelShape (registryNameFor, subscriptionNameFor)
import Keiro.Dsl.SemanticContract (CheckedService (..), EffectiveLanguageContract, checkedSource, effectiveLanguageContract, effectiveRuntimeSemantics, legacyCheckedService)
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
  { cvPrivateHistoryRead :: !SurfaceVerdict,
    cvOldBinaryReadNewEvents :: !SurfaceVerdict,
    cvSnapshotHydration :: !SurfaceVerdict,
    cvPublicConsumer :: !SurfaceVerdict,
    cvPersistedIdentity :: !SurfaceVerdict,
    cvConsumerBuild :: !SurfaceVerdict,
    cvRollout :: !(Set RolloutConstraint)
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
  { mappedPersistedSurface :: !MappedPersistedSurface,
    mappedPersistedVerdict :: !SurfaceVerdict
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
  { changeContextRoot :: !Name,
    changeContextPaths :: ![Text],
    contextKind :: !ContextKind,
    contextOriginalLabel :: !Label
  }
  deriving stock (Eq, Show)

data ChangeKind = ChangeKind
  { ckNode :: !Name,
    ckFacet :: !Text,
    ckSubject :: !Text,
    ckCode :: !DiagnosticCode,
    ckContext :: !ChangeContext,
    ckVector :: !CompatibilityVector,
    ckMappedPersistedImpact :: !(Maybe MappedPersistedImpact),
    ckMappedConsequences :: !(Set MappedConsequence),
    ckPaths :: ![Text],
    ckDetail :: !Text
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
  compatibleVector
    { cvPrivateHistoryRead = verdict PrivateHistoryRead,
      cvOldBinaryReadNewEvents = verdict OldBinaryReadNewEvents,
      cvSnapshotHydration = verdict SnapshotHydration,
      cvPublicConsumer = verdict PublicConsumer,
      cvPersistedIdentity = verdict PersistedIdentity,
      cvConsumerBuild = verdict ConsumerBuild,
      cvRollout = rollout
    }
  where
    verdict candidate
      | candidate == surface = VAdvisory
      | otherwise = verdictFor candidate compatibleVector

-- | Classify one code at an explicitly owned use site.  Codes emitted by the
-- differ are grouped by their actual persisted/public surface; the context is
-- load-bearing for codes such as 'EnumCtorAdded' that vary by use site.
classifyCompatibility :: ChangeContext -> DiagnosticCode -> CompatibilityVector
classifyCompatibility context code
  | code == SourceLanguageDeclarationChanged = sourceProvenanceVector
  | code == GeneratedHaskellNameChanged = sourceProvenanceVector {cvConsumerBuild = VAdvisory}
  | code `elem` [OwnershipMoved, WorkspaceAuthorityChanged] = mappedBuildVector
  | code `elem` [ReadModelQueryInputChanged, ReadModelQueryResultChanged] =
      compatibleVector {cvConsumerBuild = VBreaking}
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
      (advisoryVector PrivateHistoryRead Set.empty) {cvConsumerBuild = VAdvisory}
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
  | code == CatalogHandlerOrderChanged =
      (advisoryVector PrivateHistoryRead Set.empty) {cvConsumerBuild = VAdvisory}
  | code == ContractSchemaVersionBumped = advisoryVector PublicConsumer (Set.singleton RolloutProducerLast)
  | code == AggFoldSurfaceChanged =
      (advisoryVector PrivateHistoryRead Set.empty) {cvSnapshotHydration = VAdvisory}
  | code == AggGuardTightened = advisoryVector PrivateHistoryRead Set.empty
  | code `elem` [RouterDecideSurfaceChanged, ProcessDecideSurfaceChanged] =
      compatibleVector {cvRollout = Set.singleton RolloutDrainRequired}
  | code == ProcessTimerPayloadChanged = advisoryVector PrivateHistoryRead (Set.singleton RolloutProducerLast)
  | code == TimerWindowChanged = advisoryVector PrivateHistoryRead Set.empty
  | code == ProjectionChanged = advisoryVector PersistedIdentity Set.empty
  | code == EmitMappingChanged = advisoryVector PublicConsumer (Set.singleton RolloutProducerLast)
  | code == DecodePostureChanged = advisoryVector PublicConsumer Set.empty
  | code == IntakePersistenceChanged = advisoryVector PrivateHistoryRead Set.empty
  | code `elem` [PublisherPolicyChanged, DispatchRetargeted] = advisoryVector PersistedIdentity Set.empty
  | code `elem` [DeprecatedEventReplayHazard, EventRetirementInProgress] = advisoryVector PrivateHistoryRead Set.empty
  | code == EventUndeprecated = advisoryVector OldBinaryReadNewEvents (Set.singleton RolloutProducerLast)
  | code == EnumCtorAdded = case contextKind context of
      ContextPrivateEventAddition ->
        compatibleVector
          { cvOldBinaryReadNewEvents = VBreaking,
            cvRollout = Set.singleton RolloutProducerLast
          }
      ContextSnapshot -> advisoryVector SnapshotHydration Set.empty
      _ -> compatibleVector
  | code `elem` additiveCodes = compatibleVector
  | otherwise = case contextOriginalLabel context of
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
        CatalogQueryBindingChanged
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
    { cvPrivateHistoryRead = VCompatible,
      cvOldBinaryReadNewEvents = VCompatible,
      cvSnapshotHydration = VAdvisory,
      cvPublicConsumer = VBreaking,
      cvPersistedIdentity = VCompatible,
      cvConsumerBuild = VAdvisory,
      cvRollout = Set.singleton RolloutProducerLast
    }

contractTypeIdDomainVector :: CompatibilityVector
contractTypeIdDomainVector =
  CompatibilityVector
    { cvPrivateHistoryRead = VNotApplicable,
      cvOldBinaryReadNewEvents = VNotApplicable,
      cvSnapshotHydration = VNotApplicable,
      cvPublicConsumer = VBreaking,
      cvPersistedIdentity = VNotApplicable,
      cvConsumerBuild = VBreaking,
      cvRollout = Set.fromList [RolloutDrainRequired, RolloutProducerFirst]
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
mappedFieldAdditionVector context = case contextKind context of
  ContextPrivateEvent ->
    compatibleVector
      { cvOldBinaryReadNewEvents = oldBinaryVerdict,
        cvRollout = rollout
      }
    where
      rejectsUnknown = contextOriginalLabel context == LabelBreaking
      oldBinaryVerdict = if rejectsUnknown then VBreaking else VCompatible
      rollout = if rejectsUnknown then Set.singleton RolloutProducerLast else Set.empty
  ContextSnapshot -> mappedSnapshotVector
  ContextQueue -> queueBreakingVector
  ContextConsumerBuild -> mappedBuildVector
  _ -> compatibleVector

mappedDirectionalAdditionVector :: ChangeContext -> CompatibilityVector
mappedDirectionalAdditionVector context = case contextKind context of
  ContextPrivateEvent ->
    compatibleVector
      { cvOldBinaryReadNewEvents = VBreaking,
        cvRollout = Set.singleton RolloutProducerLast
      }
  ContextSnapshot -> mappedSnapshotVector
  ContextQueue -> queueBreakingVector
  ContextConsumerBuild -> mappedBuildVector
  _ -> compatibleVector

mappedWireBreakingVector :: ChangeContext -> CompatibilityVector
mappedWireBreakingVector context = case contextKind context of
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
mappedBindingVector context = case contextKind context of
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
    mappedSnapshotVector {cvConsumerBuild = VAdvisory}
  ContextQueue -> queueBreakingVector
  _ -> mappedBuildVector

mappedSnapshotBuildVector :: ChangeContext -> CompatibilityVector
mappedSnapshotBuildVector context = case contextKind context of
  ContextSnapshot -> mappedSnapshotVector {cvConsumerBuild = VAdvisory}
  _ -> mappedBuildVector

surfaceForContext :: ChangeContext -> CompatibilitySurface
surfaceForContext context = case contextKind context of
  ContextPrivateEvent -> PrivateHistoryRead
  ContextPrivateEventAddition -> OldBinaryReadNewEvents
  ContextSnapshot -> SnapshotHydration
  ContextQueue -> PrivateHistoryRead
  ContextPublicContract -> PublicConsumer
  ContextPersistedIdentity -> PersistedIdentity
  ContextConsumerBuild -> ConsumerBuild
  ContextGeneral -> PrivateHistoryRead

breakingVectorForContext :: ChangeContext -> CompatibilityVector
breakingVectorForContext context = case contextKind context of
  ContextPublicContract -> publicBreakingVector
  ContextPersistedIdentity -> persistedIdentityBreakingVector
  ContextQueue -> queueBreakingVector
  ContextConsumerBuild -> (advisoryVector ConsumerBuild Set.empty) {cvConsumerBuild = VBreaking}
  _ -> privateDecodeBreakingVector

verdictFor :: CompatibilitySurface -> CompatibilityVector -> SurfaceVerdict
verdictFor surface vector = case surface of
  PrivateHistoryRead -> cvPrivateHistoryRead vector
  OldBinaryReadNewEvents -> cvOldBinaryReadNewEvents vector
  SnapshotHydration -> cvSnapshotHydration vector
  PublicConsumer -> cvPublicConsumer vector
  PersistedIdentity -> cvPersistedIdentity vector
  ConsumerBuild -> cvConsumerBuild vector

defaultGate :: Set CompatibilitySurface
defaultGate = Set.delete OldBinaryReadNewEvents (Set.fromList [minBound .. maxBound])

gateWith :: [CompatibilitySurface] -> Set CompatibilitySurface
gateWith surfaces = defaultGate <> Set.fromList surfaces

deriveLabel :: Set CompatibilitySurface -> CompatibilityVector -> Label
deriveLabel gate vector
  | any ((== VBreaking) . (`verdictFor` vector)) (Set.toList gate) = LabelBreaking
  | any (`elem` [VAdvisory, VBreaking]) verdicts || not (Set.null (cvRollout vector)) = LabelAdvisory
  | otherwise = LabelAdditive
  where
    verdicts = [verdictFor surface vector | surface <- [minBound .. maxBound]]

gatedBreaking :: Set CompatibilitySurface -> Change -> Bool
gatedBreaking gate change = deriveLabel gate (ckVector (changeKind change)) == LabelBreaking

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
  { deOld :: !Spec,
    deNew :: !Spec
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
familyOf (NProjectionOwner _) = FamProjectionOwner
familyOf (NWorkflow _) = FamWorkflow
familyOf (NOperation _) = FamOperation

-- | A family either has a differ or an explicit reason it is not compared.
data FamilyDiff
  = DiffFamily (DiffEnv -> [Change])
  | OutOfDiffScope Text

-- | Pair the old and new declarations of one node family by stable name.
data Paired n = Paired
  { prMatched :: ![(n, n)],
    prAdded :: ![n],
    prRemoved :: ![n]
  }
  deriving stock (Eq, Show)

pairByName :: (Node -> Maybe n) -> (n -> Name) -> DiffEnv -> Paired n
pairByName project nameOf env =
  Paired
    { prMatched =
        [ (oldNode, newNode)
        | newNode <- newNodes,
          Just oldNode <- [find ((== nameOf newNode) . nameOf) oldNodes]
        ],
      prAdded =
        [ newNode
        | newNode <- newNodes,
          isNothing (find ((== nameOf newNode) . nameOf) oldNodes)
        ],
      prRemoved =
        [ oldNode
        | oldNode <- oldNodes,
          isNothing (find ((== nameOf oldNode) . nameOf) newNodes)
        ]
    }
  where
    oldNodes = mapMaybe project (specNodes (deOld env))
    newNodes = mapMaybe project (specNodes (deNew env))

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
    oldAggregates = [(aggName aggregate, aggregate) | NAggregate aggregate <- specNodes oldSpec]
    newAggregates = [(aggName aggregate, aggregate) | NAggregate aggregate <- specNodes newSpec]
    idDomainContractChanges =
      [ breaking
          (idName newDeclaration)
          "id-domain-contract"
          (idName newDeclaration)
          IdDomainContractChanged
          ( "ID admission contract changed "
              <> renderIdDomainContract oldContract
              <> " -> "
              <> renderIdDomainContract newContract
              <> "; public construction, command decoding, current JSON codecs, and literals use the new contract; historical event replay retains its legacy decoder; old snapshots miss and rebuild from readable events, while rebuilt state that still contains legacy-invalid text remains intentionally uncacheable until overwritten or explicitly migrated"
          )
      | newDeclaration <- specIds newSpec,
        Just oldDeclaration <- [find ((== idName newDeclaration) . idName) (specIds oldSpec)],
        let oldContract = idDomainContractFor (checkedLanguageContract oldService) (idPrefix oldDeclaration),
        let newContract = idDomainContractFor (checkedLanguageContract newService) (idPrefix newDeclaration),
        oldContract /= newContract
      ]
    contractTypeIdDomainChanges =
      [ breaking
          (ctrName newContract)
          "contract-typeid-domain"
          (ceName newEvent <> "." <> cfName newField)
          ContractTypeIdDomainChanged
          ( renderContractIdDomainChange
              (cfType newField)
              oldContract
              newContract'
          )
      | newContract <- [contract | NContract contract <- specNodes newSpec],
        Just oldContractNode <- [find ((== ctrName newContract) . ctrName) [contract | NContract contract <- specNodes oldSpec]],
        newEvent <- ctrEvents newContract,
        Just oldEvent <- [find ((== ceName newEvent) . ceName) (ctrEvents oldContractNode)],
        newField <- ceFields newEvent,
        Just oldField <- [find ((== cfName newField) . cfName) (ceFields oldEvent)],
        cfType oldField == cfType newField,
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
contractFieldIdDomain languageContract field = case cfType field of
  CTypeId prefix -> contractIdDomainContractFor languageContract prefix
  _ -> Nothing

renderContractIdDomainChange :: ContractType -> Maybe IdDomainContract -> Maybe IdDomainContract -> Text
renderContractIdDomainChange fieldType oldContract newContract =
  "contract TypeID admission changed "
    <> renderIdDomainContract oldContract
    <> " -> "
    <> renderIdDomainContract newContract
    <> representationChange
  where
    prefix = case fieldType of
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
        (specContext (parsedSpec new))
        "declaration"
        (parsedSourceLanguage old)
        (parsedSourceLanguage new)
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
    (diffMapped (deOld env) (deNew env))

-- | A mapped event finding retains its existing private-history change and
-- gains one build/review finding per real inline/catalog aggregate consumer.
-- Category/all owners never appear because they have no single mapped event
-- authority. Operational targets and observers are evidence, not SQL claims.
mappedProjectionFindingChanges :: DiffEnv -> MappedFinding -> [Change]
mappedProjectionFindingChanges env finding = case (projectionImpactFor (deOld env), projectionImpactFor (deNew env)) of
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
          let subject = mappedConsumerIdentity (DerivedProjectionConsumer derived) <> " inherits " <> unMappedKey declarationKey
        ]
  where
    declarationKey = MappedKey (mfDeclaration finding)
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
        | ProjectionImpact.ProjectionMappedRoot candidate declaration inheritedPath <- ProjectionImpact.roots impact,
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
      Additive kind -> Additive kind {ckDetail = ckDetail kind <> suffix}
      Advisory kind -> Advisory kind {ckDetail = ckDetail kind <> suffix}
      Breaking kind -> Breaking kind {ckDetail = ckDetail kind <> suffix}
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
        declarationChanges = [MappedKey (mfDeclaration finding) | finding <- diffMapped oldSpec newSpec]
        relationChanges = map impactDeclaration (diffSemanticImpact oldSnapshot newSnapshot)
     in mappedImpactForDeclarations (declarationChanges <> relationChanges) oldSnapshot newSnapshot
  _ -> []
  where
    oldSpec = checkedSpec oldService
    newSpec = checkedSpec newService

mappedFindingChanges :: MappedFinding -> [Change]
mappedFindingChanges finding
  | mfCode finding == MappedDeclAdded = [mappedDeclarationChange LabelAdditive finding]
  | mfCode finding `elem` [MappedHaskellSourceChanged, MappedRecordConstructorChanged, MappedFixturesChanged, GeneratedHaskellNameChanged] =
      [mappedBuildChange finding]
  | mfCode finding `elem` [MappedInitialChanged, MappedCanonicalTypeChanged] =
      mappedBuildChange finding : map (mappedUseChange finding) registerPaths
  | null paths = [mappedBuildChange finding]
  | otherwise = map (mappedUseChange finding) paths
  where
    paths = mfUsePaths finding
    registerPaths = [path | path@UsePath {upRoot = RootRegister {}} <- paths]

mappedBuildChange :: MappedFinding -> Change
mappedBuildChange finding =
  mappedChange context (mfDeclaration finding) "mapped-build" subject finding
  where
    subject = declarationSubject finding
    renderedPaths = map (\path -> renderMappedSubject path (mfLeaf finding)) (mfUsePaths finding)
    context = (consumerBuildContext (mfDeclaration finding) renderedPaths) {contextOriginalLabel = LabelAdvisory}

mappedDeclarationChange :: Label -> MappedFinding -> Change
mappedDeclarationChange label finding =
  mappedChange context (mfDeclaration finding) "mapped-declaration" (declarationSubject finding) finding
  where
    context = ChangeContext (mfDeclaration finding) [] ContextGeneral label

mappedUseChange :: MappedFinding -> UsePath -> Change
mappedUseChange finding path =
  withMappedConsequences (mappedUseConsequences path) (mappedChange context root facet subject finding)
  where
    subject = renderMappedSubject path (mfLeaf finding)
    (root, facet, kind) = case upRoot path of
      RootCommandField aggregate _ _ _ -> (aggregate, "mapped-command", ContextConsumerBuild)
      RootEventField aggregate _ _ _ -> (aggregate, "mapped-event", ContextPrivateEvent)
      RootRegister aggregate _ _ -> (aggregate, "mapped-register", ContextSnapshot)
      RootWorkqueueField workqueue _ _ -> (workqueue, "mapped-workqueue", ContextQueue)
      RootReadModelQueryInput readModel _ -> (readModel, "mapped-query-input", ContextConsumerBuild)
      RootReadModelQueryResult readModel _ -> (readModel, "mapped-query-result", ContextConsumerBuild)
    context = ChangeContext root [subject] kind (mappedContextHint finding kind)

mappedUseConsequences :: UsePath -> Set MappedConsequence
mappedUseConsequences path = Set.fromList $ case upRoot path of
  RootCommandField aggregate _ _ _ -> [MappedConsumerBuild (AggregateConsumer aggregate)]
  RootEventField aggregate _ _ _ -> [MappedConsumerBuild (AggregateConsumer aggregate), MappedPrivateEventHistory aggregate]
  RootRegister aggregate _ _ -> [MappedConsumerBuild (AggregateConsumer aggregate), MappedSnapshotHydration aggregate]
  RootWorkqueueField workqueue _ _ -> [MappedConsumerBuild (WorkqueueConsumer workqueue), MappedWorkqueueHistory workqueue]
  RootReadModelQueryInput readModel _ -> [MappedConsumerBuild (ReadModelQueryConsumer readModel MappedQueryInput), MappedQueryApi readModel MappedQueryInput]
  RootReadModelQueryResult readModel _ -> [MappedConsumerBuild (ReadModelQueryConsumer readModel MappedQueryResult), MappedQueryApi readModel MappedQueryResult]

withMappedConsequences :: Set MappedConsequence -> Change -> Change
withMappedConsequences consequences = \case
  Additive kind -> Additive kind {ckMappedConsequences = consequences}
  Advisory kind -> Advisory kind {ckMappedConsequences = consequences}
  Breaking kind -> Breaking kind {ckMappedConsequences = consequences}

mappedContextHint :: MappedFinding -> ContextKind -> Label
mappedContextHint finding kind = case kind of
  ContextSnapshot -> LabelAdvisory
  ContextQueue -> LabelBreaking
  ContextConsumerBuild -> LabelAdvisory
  ContextPrivateEvent
    | mfCode finding == MappedFieldAddedWithDefault -> case mfOldUnknownFields finding of
        Just IgnoreUnknown -> LabelAdditive
        _ -> LabelBreaking
    | mfCode finding `elem` [MappedArmAdded, MappedEnumValueAdded] -> LabelAdvisory
    | mfCode finding `elem` [MappedBindingChanged, MappedInitialChanged, MappedCanonicalTypeChanged] -> LabelAdvisory
    | otherwise -> LabelBreaking
  _ -> LabelAdvisory

mappedChange :: ChangeContext -> Name -> Text -> Text -> MappedFinding -> Change
mappedChange context node facet subject finding =
  mkChange label context node facet subject (mfCode finding) detail
  where
    label = deriveLabel defaultGate (classifyCompatibility context (mfCode finding))
    detail = case contextKind context of
      ContextQueue ->
        mfDetail finding
          <> "; queued jobs remain schema-version-1 history; drain the queue or supply an application-owned transitional codec before deployment"
      _ -> mfDetail finding

declarationSubject :: MappedFinding -> Text
declarationSubject finding =
  mfDeclaration finding <> if T.null (mfLeaf finding) then "" else " " <> mfLeaf finding

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
  concatMap (uncurry routerPairDiff) (prMatched paired)
    ++ [additive (rtId router) "router" (rtId router) DeclarationAdded "new router declaration" | router <- prAdded paired]
    ++ [breaking (rtId router) "router-identity" (rtId router) RouterStableNameChanged "router removed while replayable source events may still derive target-keyed dispatch ids from its stable identity" | router <- prRemoved paired]
  where
    paired = pairByName nodeRouter rtId env

routerPairDiff :: RouterNode -> RouterNode -> [Change]
routerPairDiff oldRouter newRouter =
  stableName
    ++ keyDerivation
    ++ target
    ++ routerDecideSurfaceDiff oldRouter newRouter
  where
    nodeName = rtId newRouter
    stableName =
      [ breaking nodeName "router-stable-name" nodeName RouterStableNameChanged $
          "router stable name changed from '" <> rtName oldRouter <> "' to '" <> rtName newRouter <> "'; every deterministicRouterCommandId is re-keyed, so redelivery can duplicate the full resolved fan-out"
      | rtName oldRouter /= rtName newRouter
      ]
    keyDerivation =
      [ breaking nodeName "router-key" (corrField (rtKey newRouter)) DerivedIdentityChanged "router key field or derivation changed; replay derives different target dispatch ids"
      | rtKey oldRouter /= rtKey newRouter
      ]
    target =
      [ breaking nodeName "router-target" (rtTarget newRouter) DerivedIdentityChanged "router target aggregate changed; replay addresses a different persisted stream family"
      | rtTarget oldRouter /= rtTarget newRouter
      ]

routerDecideSurfaceDiff :: RouterNode -> RouterNode -> [Change]
routerDecideSurfaceDiff oldRouter newRouter =
  [ advisory
      (rtId newRouter)
      "router-decide"
      (rtId newRouter)
      RouterDecideSurfaceChanged
      "router dispatch surface changed: a source event redelivered across the deploy dispatches under the same deterministic ids, so half-old/half-new fan-out merges silently. Drain or pause the router's subscription and replay or discard dead letters before deploying; see docs/user/deploy-ordering.md. Hole-only decide changes are not visible to diff; the same drain rule applies to those too."
  | oldSurface /= newSurface
  ]
  where
    oldSurface =
      ( renderResolveSurface (rtResolve oldRouter),
        renderRouterDispatchSurface (rtDispatch oldRouter)
      )
    newSurface =
      ( renderResolveSurface (rtResolve newRouter),
        renderRouterDispatchSurface (rtDispatch newRouter)
      )

readModelDiff :: DiffEnv -> [Change]
readModelDiff env =
  concatMap (uncurry (readModelPairDiff env)) (prMatched paired)
    ++ concatMap addedReadModelDiff (prAdded paired)
    ++ concatMap removedReadModelDiff (prRemoved paired)
  where
    paired = pairByName nodeReadModel rmName env

readModelPairDiff :: DiffEnv -> ReadModelNode -> ReadModelNode -> [Change]
readModelPairDiff env oldReadModel newReadModel =
  versionChanges
    ++ shapeChanges
    ++ identityChanges
    ++ feedChanges
    ++ consistencyChanges
    ++ scopeChanges
    ++ bindingChanges
    ++ queryContractChanges
  where
    nodeName = rmName newReadModel
    versionChanges
      | rmVersion newReadModel < rmVersion oldReadModel =
          [ breaking nodeName "read-model-version" nodeName ReadModelVersionDecreased ("version decreased from " <> tInt (rmVersion oldReadModel) <> " to " <> tInt (rmVersion newReadModel))
          ]
      | rmVersion newReadModel > rmVersion oldReadModel =
          [ additive nodeName "read-model-version" nodeName VersionBumped ("version increased from " <> tInt (rmVersion oldReadModel) <> " to " <> tInt (rmVersion newReadModel) <> "; register and rebuild the new shape before serving it")
          ]
      | otherwise = []
    oldShape = (rmColumns oldReadModel, rmShape oldReadModel)
    newShape = (rmColumns newReadModel, rmShape newReadModel)
    shapeChanges =
      [ breaking nodeName "read-model-shape" nodeName ReadModelShapeChangedWithoutBump ("declared columns or captured shape hash changed at version " <> tInt (rmVersion newReadModel) <> "; bump version and rebuild")
      | oldShape /= newShape,
        rmVersion oldReadModel == rmVersion newReadModel
      ]
    oldRegistry = registryNameFor (specContext (deOld env)) oldReadModel
    newRegistry = registryNameFor (specContext (deNew env)) newReadModel
    oldSubscription = subscriptionNameFor (specContext (deOld env)) oldReadModel
    newSubscription = subscriptionNameFor (specContext (deNew env)) newReadModel
    identityChanges =
      [ breaking nodeName "read-model-identity" nodeName DerivedIdentityChanged ("registry name changed '" <> oldRegistry <> "' -> '" <> newRegistry <> "'; the old registration row is orphaned")
      | oldRegistry /= newRegistry
      ]
        ++ [ breaking nodeName "read-model-table" nodeName DerivedIdentityChanged ("qualified table changed '" <> qualifiedIdentity oldReadModel <> "' -> '" <> qualifiedIdentity newReadModel <> "'; existing data remains under the old identity")
           | (rmSchema oldReadModel, rmTable oldReadModel) /= (rmSchema newReadModel, rmTable newReadModel)
           ]
        ++ [ breaking nodeName "read-model-subscription" nodeName DerivedIdentityChanged ("subscription changed '" <> oldSubscription <> "' -> '" <> newSubscription <> "'; the worker cursor remains under the old identity")
           | oldSubscription /= newSubscription
           ]
    feedChanges =
      [ breaking nodeName "read-model-feed" nodeName ReadModelFeedChanged ("feed changed " <> renderFeed (rmFeed oldReadModel) <> " -> " <> renderFeed (rmFeed newReadModel) <> "; projection wiring and rebuild identities changed")
      | rmFeed oldReadModel /= rmFeed newReadModel
      ]
    consistencyChanges = case (rmConsistency oldReadModel, rmConsistency newReadModel) of
      (Strong, Eventual) ->
        [breaking nodeName "read-model-consistency" nodeName ReadModelConsistencyWeakened "default consistency changed Strong -> Eventual; callers lose the cursor-wait guarantee"]
      (Eventual, Strong) ->
        [additive nodeName "read-model-consistency" nodeName CompatibilityStrengthened "default consistency changed Eventual -> Strong; callers gain a cursor-wait guarantee"]
      _ -> []
    oldScope = effectiveScope (rmScope oldReadModel)
    newScope = effectiveScope (rmScope newReadModel)
    scopeChanges
      | oldScope == newScope = []
      | scopeStrengthened oldScope newScope =
          [additive nodeName "read-model-scope" nodeName CompatibilityStrengthened ("Strong scope widened " <> renderScope oldScope <> " -> " <> renderScope newScope)]
      | otherwise =
          [breaking nodeName "read-model-scope" nodeName ReadModelConsistencyWeakened ("Strong scope changed " <> renderScope oldScope <> " -> " <> renderScope newScope <> "; callers no longer wait on the same event surface")]
    bindingChanges =
      [ breaking nodeName "read-model-catalog-binding" nodeName CatalogQueryBindingChanged "query-model rebuild group, observed target set, or backing target changed; persisted lifecycle identity and rebuild completeness changed"
      | bindingIdentity oldReadModel /= bindingIdentity newReadModel
      ]
    bindingIdentity readModel =
      ( rmGroup readModel,
        Set.fromList (rmObservedTargets readModel),
        effectiveBacking readModel
      )
    effectiveBacking readModel = case rmBackingTarget readModel of
      Just target -> Just target
      Nothing -> case rmObservedTargets readModel of
        [single] -> Just single
        _ -> Nothing
    queryContractChanges =
      queryPositionChange
        "input"
        MappedQueryInput
        ReadModelQueryInputChanged
        (input <$> queryTypes oldReadModel)
        (input <$> queryTypes newReadModel)
        "callers"
        <> queryPositionChange
          "result"
          MappedQueryResult
          ReadModelQueryResultChanged
          (result <$> queryTypes oldReadModel)
          (result <$> queryTypes newReadModel)
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
  concatMap (uncurry projectionTargetPairDiff) (prMatched paired)
    <> [additive (ptName target) "projection-target" (ptName target) CatalogTargetAdded "new application-owned target; consumer DDL is still required" | target <- prAdded paired]
    <> [breaking (ptName target) "projection-target" (ptName target) CatalogTargetRemoved "target declaration removed while table data and rebuild evidence may remain" | target <- prRemoved paired]
  where
    paired = pairByName nodeProjectionTarget ptName env

projectionTargetPairDiff :: ProjectionTargetNode -> ProjectionTargetNode -> [Change]
projectionTargetPairDiff oldTarget newTarget = locationChange <> resetChange <> dependencyChange
  where
    targetName = ptName newTarget
    locationChange =
      [ breaking targetName "projection-target-location" targetName CatalogTargetLocationChanged $
          "qualified target changed " <> ptSchema oldTarget <> "." <> ptTable oldTarget <> " -> " <> ptSchema newTarget <> "." <> ptTable newTarget <> "; Keiro does not move application data"
      | (ptSchema oldTarget, ptTable oldTarget) /= (ptSchema newTarget, ptTable newTarget)
      ]
    resetChange = case (ptReset oldTarget, ptReset newTarget) of
      (TargetPreserve, TargetClear) -> [breaking targetName "projection-target-reset" targetName CatalogTargetResetPolicyChanged "reset changed preserve -> clear; a rebuild can now delete retained brownfield data"]
      (TargetClear, TargetPreserve) -> [advisory targetName "projection-target-reset" targetName CatalogTargetResetPolicyChanged "reset changed clear -> preserve; application reconciliation must now prove retained rows"]
      _ -> []
    dependencyChange =
      [ breaking targetName "projection-target-dependencies" targetName CatalogTargetDependencyChanged "target dependency order changed; abandon any active fingerprint and start a fresh group rebuild"
      | ptDependsOn oldTarget /= ptDependsOn newTarget
      ]

rebuildGroupDiff :: DiffEnv -> [Change]
rebuildGroupDiff env =
  concatMap (uncurry rebuildGroupPairDiff) (prMatched paired)
    <> [additive (rgName groupNode) "rebuild-group" (rgName groupNode) DeclarationAdded "new rebuild group" | groupNode <- prAdded paired]
    <> [breaking (rgName groupNode) "rebuild-group" (rgName groupNode) CatalogGroupChanged "rebuild group removed while lifecycle and run evidence may remain" | groupNode <- prRemoved paired]
  where
    paired = pairByName nodeRebuildGroup rgName env

rebuildGroupPairDiff :: RebuildGroupNode -> RebuildGroupNode -> [Change]
rebuildGroupPairDiff oldGroup newGroup =
  [ breaking (rgName newGroup) "rebuild-group-membership-order" (rgName newGroup) CatalogGroupChanged "target membership or deterministic preparation order changed; abandon any active fingerprint and start a fresh rebuild"
  | (rgTargets oldGroup, rgOrder oldGroup) /= (rgTargets newGroup, rgOrder newGroup)
  ]

projectionOwnerDiff :: DiffEnv -> [Change]
projectionOwnerDiff env =
  concatMap (uncurry projectionOwnerPairDiff) (prMatched paired)
    <> [additive (poName owner) "projection-owner" (poName owner) DeclarationAdded "new projection owner" | owner <- prAdded paired]
    <> [breaking (poName owner) "projection-owner" (poName owner) CatalogOwnerRemoved "projection owner removed while targets and replay evidence remain" | owner <- prRemoved paired]
  where
    paired = pairByName nodeProjectionOwner poName env

projectionOwnerPairDiff :: ProjectionOwnerNode -> ProjectionOwnerNode -> [Change]
projectionOwnerPairDiff oldOwner newOwner = groupAndTargets <> orderChange <> sourceChange <> feedIdentityChange <> checkpointPolicyChange <> replayChange
  where
    ownerName = poName newOwner
    groupAndTargets =
      [ breaking ownerName "projection-owner-group-targets" ownerName CatalogOwnerChanged "rebuild group or owned target set changed"
      | (poGroup oldOwner, poTargets oldOwner) /= (poGroup newOwner, poTargets newOwner)
      ]
    orderChange =
      [ advisory ownerName "projection-owner-order" ownerName CatalogHandlerOrderChanged "handler order changed; replay materialization and resume fingerprint change"
      | poOrder oldOwner /= poOrder newOwner
      ]
    sourceChange =
      [ breaking ownerName "projection-owner-sources" ownerName CatalogSourceChanged "source selection changed; historical coverage and active resume fingerprint change"
      | poSources oldOwner /= poSources newOwner
      ]
    feedIdentityChange =
      [ breaking ownerName "projection-owner-feed-identity" ownerName CatalogFeedIdentityChanged "feed, subscription, or dedup identity changed; cursors or dedup evidence remain under the old identity"
      | (poFeed oldOwner, poSubscription oldOwner, poDedup oldOwner) /= (poFeed newOwner, poSubscription newOwner, poDedup newOwner)
      ]
    checkpointPolicyChange =
      [ breaking ownerName "projection-owner-checkpoint-on-missing" ownerName CatalogCheckpointPolicyChanged $
          "checkpoint-on-missing changed " <> renderCheckpointOnMissing oldPolicy <> " -> " <> renderCheckpointOnMissing newPolicy <> "; the generated catalog and next absent-row startup behavior change, while persisted subscription identity and existing checkpoint rows remain unchanged"
      | [oldPolicy] <- [poCheckpointOnMissing oldOwner],
        [newPolicy] <- [poCheckpointOnMissing newOwner],
        oldPolicy /= newPolicy
      ]
    replayChange =
      [ breaking ownerName "projection-owner-replay-policy" ownerName CatalogReplayPolicyChanged "replay policy changed; abandon any active run before rebuilding under the new contract"
      | poReplay oldOwner /= poReplay newOwner
      ]

renderCheckpointOnMissing :: CheckpointOnMissingNode -> Text
renderCheckpointOnMissing CheckpointFromBeginning = "from-beginning"
renderCheckpointOnMissing CheckpointFromCurrentHead = "from-current-head"
renderCheckpointOnMissing CheckpointFail = "fail"

addedReadModelDiff :: ReadModelNode -> [Change]
addedReadModelDiff readModel =
  [additive (rmName readModel) "read-model" (rmName readModel) DeclarationAdded "new read model"]

removedReadModelDiff :: ReadModelNode -> [Change]
removedReadModelDiff readModel =
  [breaking (rmName readModel) "read-model-identity" (rmName readModel) DerivedIdentityChanged "read model removed while registered metadata, data, subscription cursors, and callers may remain"]

qualifiedIdentity :: ReadModelNode -> Text
qualifiedIdentity readModel = rmSchema readModel <> "." <> rmTable readModel

renderFeed :: RmFeed -> Text
renderFeed RmInline = "inline"
renderFeed RmSubscription = "subscription"

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
    (\(oldAggregate, newAggregate) -> aggregatePairDiff (deOld env) (deNew env) oldAggregate newAggregate)
    (prMatched paired)
    ++ concatMap addedAggregateDiff (prAdded paired)
    ++ concatMap removedAggregateDiff (prRemoved paired)
  where
    paired = pairByName nodeAggregate aggName env

aggregatePairDiff :: Spec -> Spec -> Aggregate -> Aggregate -> [Change]
aggregatePairDiff oldSpec newSpec oldAgg newAgg =
  commandFieldIdentityDiff oldAgg newAgg
    ++ concatMap (eventDiff oldAgg newAgg) (aggEvents newAgg)
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
          (aggName newAggregate)
          "domain-outcome-types"
          (aggName newAggregate)
          DomainOutcomeTypesChanged
          ( "domain outcome types changed from '"
              <> renderDeclaration (aggDomainOutcomeTypes oldAggregate)
              <> "' to '"
              <> renderDeclaration (aggDomainOutcomeTypes newAggregate)
              <> "'; generated command result types and callers must be updated, while event history and snapshots remain compatible"
          )
      | canonicalDomainOutcomeTypes (aggDomainOutcomeTypes oldAggregate)
          /= canonicalDomainOutcomeTypes (aggDomainOutcomeTypes newAggregate)
      ]
    transitionChanges =
      [ advisory
          (aggName newAggregate)
          "transition-domain-outcome"
          (transitionSubject ordinal newTransition)
          DomainTransitionOutcomeChanged
          ( "domain outcome changed from '"
              <> canonicalTransitionOutcome (tOutcome oldTransition)
              <> "' to '"
              <> canonicalTransitionOutcome (tOutcome newTransition)
              <> "'; forward command behavior changes, while the selected edge, emitted events, fold, replay, and snapshots remain unchanged"
          )
      | (ordinal, newTransition) <- zip [0 :: Int ..] (aggTransitions newAggregate),
        Just oldTransition <- [find ((== canonicalTransition newTransition) . canonicalTransition) (aggTransitions oldAggregate)],
        canonicalTransitionOutcome (tOutcome oldTransition) /= canonicalTransitionOutcome (tOutcome newTransition)
      ]
    renderDeclaration declaration = case canonicalDomainOutcomeTypes declaration of
      "" -> "(disabled)"
      value -> value
    transitionSubject ordinal transition =
      tSource transition <> " -- " <> tCommand transition <> " [edge " <> T.pack (show ordinal) <> "]"

-- | Report replay-fold evolution. Regenerated scaffold code carries the new
-- fingerprint and invalidates old snapshots, so this remains advisory.
transitionSurfaceDiff :: Spec -> Spec -> Aggregate -> Aggregate -> [Change]
transitionSurfaceDiff oldSpec newSpec oldAgg newAgg
  | aggregateFoldSurfaceForService (legacyCheckedService oldSpec) oldAgg == aggregateFoldSurfaceForService (legacyCheckedService newSpec) newAgg = []
  | otherwise =
      [ advisory
          (aggName newAgg)
          "transitions"
          (aggName newAgg)
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
  [ advisory (aggName newAgg) "transition" subject AggGuardTightened detail
  | newT <- aggTransitions newAgg,
    tMode newT == TmLive,
    Just oldT <-
      [ find
          (\o -> tSource o == tSource newT && tCommand o == tCommand newT && tMode o == TmLive)
          (aggTransitions oldAgg)
      ],
    tGuard newT /= tGuard oldT,
    Just newGuard <- [tGuard newT],
    not (hasReplayOnlyTwin newT),
    let subject = tSource newT <> " -- " <> tCommand newT,
    let removedRegion =
          maybe (complementExpr newGuard) (\o -> EAnd o (complementExpr newGuard)) (tGuard oldT),
    let twin = oldT {tGuard = Just removedRegion, tMode = TmReplayOnly},
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
        (\t -> tMode t == TmReplayOnly && tSource t == tSource newT && tCommand t == tCommand newT)
        (aggTransitions newAgg)

addedAggregateDiff :: Aggregate -> [Change]
addedAggregateDiff newAgg =
  [ additive (aggName newAgg) "event" (evName e) DeclarationAdded "new event type (new aggregate)"
  | e <- aggEvents newAgg
  ]

removedAggregateDiff :: Aggregate -> [Change]
removedAggregateDiff oldAgg =
  [ breaking (aggName oldAgg) "event" (evName e) EvtRemovedNotDeprecated "aggregate removed; its event tags are no longer decodable"
  | e <- aggEvents oldAgg
  ]

-- | Per-event classification for an event present in the new aggregate.
eventDiff :: Aggregate -> Aggregate -> Event -> [Change]
eventDiff oldAgg newAgg e =
  case find ((== evName e) . evName) (aggEvents oldAgg) of
    Nothing ->
      [additive (aggName newAgg) "event" (evName e) DeclarationAdded "new event type"]
    Just oldE
      | evVersion e > evVersion oldE ->
          selectorChanges oldE
            ++ if evVersion e == evVersion oldE + 1 && evUpcastFrom e `hasSource` evVersion oldE
              then
                [additive (aggName newAgg) "event" (evName e) VersionBumped ("new version v" <> tInt (evVersion e) <> " with upcaster from v" <> tInt (evVersion oldE))]
                  ++ [ breaking
                         (aggName newAgg)
                         "event"
                         (evName e)
                         UpcasterChainGap
                         ( "bumping v"
                             <> tInt (evVersion oldE)
                             <> " to v"
                             <> tInt (evVersion e)
                             <> " replaced the 'upcast from v"
                             <> tInt vanishedSource
                             <> "' rung; stored v"
                             <> tInt vanishedSource
                             <> " payloads can no longer decode"
                         )
                     | Just (vanishedSource, _) <- [evUpcastFrom oldE],
                       not (aggregateHasUpcasterSource newAgg vanishedSource)
                     ]
              else
                [ breaking
                    (aggName newAgg)
                    "event"
                    (evName e)
                    EvtVersionMissingUpcaster
                    ( "version changed from v"
                        <> tInt (evVersion oldE)
                        <> " to v"
                        <> tInt (evVersion e)
                        <> " without the required contiguous upcaster from v"
                        <> tInt (evVersion oldE)
                    )
                ]
      | evVersion e < evVersion oldE ->
          selectorChanges oldE
            ++ [breaking (aggName newAgg) "event" (evName e) EvtVersionDecreased ("version decreased from v" <> tInt (evVersion oldE) <> " to v" <> tInt (evVersion e))]
      | otherwise ->
          selectorChanges oldE ++ sameVersionEventDiff oldAgg newAgg oldE e
  where
    selectorChanges oldEvent = eventFieldSelectorChanges oldAgg newAgg oldEvent e

-- | Events present in the old aggregate but absent in the new one. Removing a
-- tag entirely is breaking; deprecation preserves decoding but needs a retained
-- replay-only emitter to preserve replay.
removedEvents :: Aggregate -> Aggregate -> [Change]
removedEvents oldAgg newAgg =
  [ breaking (aggName newAgg) "event" (evName oldE) EvtRemovedNotDeprecated "event removed entirely; its stored payloads can neither decode nor replay. Deprecating instead restores decode-ability only — replay still fails on live streams unless an equivalent replay-only emitting transition is retained; truncate or terminalize affected streams before deleting it"
  | oldE <- aggEvents oldAgg,
    isNothing (find ((== evName oldE) . evName) (aggEvents newAgg))
  ]

hasSource :: Maybe (Int, Hole) -> Int -> Bool
hasSource (Just (m, _)) n = m == n
hasSource Nothing _ = False

aggregateHasUpcasterSource :: Aggregate -> Int -> Bool
aggregateHasUpcasterSource aggregate source =
  any ((== Just source) . fmap fst . evUpcastFrom) (aggEvents aggregate)

hasReplayOnlyEmitter :: Aggregate -> Name -> Bool
hasReplayOnlyEmitter aggregate eventName =
  any
    (\transition -> tMode transition == TmReplayOnly && eventName `elem` tEmits transition)
    (aggTransitions aggregate)

data EventFieldSig = EventFieldSig
  { eventFieldDslName :: !Name,
    eventFieldSelector :: !Name,
    eventFieldWireKey :: !Text,
    eventFieldType :: !(Maybe TypeExpr)
  }
  deriving stock (Eq, Show)

eventFieldSigs :: Aggregate -> Event -> [EventFieldSig]
eventFieldSigs agg e = case evBody e of
  EventFields fs -> map fieldSig fs
  EventFromCommand cn ->
    maybe [] (map fieldSig . cmdFields) (find ((== cn) . cmdName) (aggCommands agg))
  where
    fieldSig field =
      let identity = resolveAggregateFieldIdentity field
       in EventFieldSig
            { eventFieldDslName = fieldDslName identity,
              eventFieldSelector = fieldSelector identity,
              eventFieldWireKey = fieldWireKey identity,
              eventFieldType = aggregateFieldType field
            }

eventFieldSelectorChanges :: Aggregate -> Aggregate -> Event -> Event -> [Change]
eventFieldSelectorChanges oldAggregate newAggregate oldEvent newEvent =
  [ fieldSelectorChange
      (aggName newAggregate)
      "event-field-selector"
      (evName newEvent <> "." <> eventFieldDslName newField)
      (eventFieldSelector oldField)
      (eventFieldSelector newField)
      "event field selector"
  | newField <- eventFieldSigs newAggregate newEvent,
    Just oldField <- [find ((== eventFieldDslName newField) . eventFieldDslName) (eventFieldSigs oldAggregate oldEvent)],
    eventFieldSelector oldField /= eventFieldSelector newField
  ]

commandFieldIdentityDiff :: Aggregate -> Aggregate -> [Change]
commandFieldIdentityDiff oldAggregate newAggregate =
  [ fieldSelectorChange
      (aggName newAggregate)
      "command-field-selector"
      (cmdName newCommand <> "." <> aggregateFieldName newField)
      (fieldSelector (resolveAggregateFieldIdentity oldField))
      (fieldSelector (resolveAggregateFieldIdentity newField))
      "command field selector"
  | newCommand <- aggCommands newAggregate,
    Just oldCommand <- [find ((== cmdName newCommand) . cmdName) (aggCommands oldAggregate)],
    newField <- cmdFields newCommand,
    Just oldField <- [find ((== aggregateFieldName newField) . aggregateFieldName) (cmdFields oldCommand)],
    fieldSelector (resolveAggregateFieldIdentity oldField)
      /= fieldSelector (resolveAggregateFieldIdentity newField)
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
    oldNames = map eventFieldDslName oldFields
    newNames = map eventFieldDslName newFields
    added = newNames \\ oldNames
    removed = oldNames \\ newNames
    changed =
      [ (eventFieldDslName oldField, eventFieldType oldField, eventFieldType newField)
      | oldField <- oldFields,
        Just newField <- [find ((== eventFieldDslName oldField) . eventFieldDslName) newFields],
        eventFieldType oldField /= eventFieldType newField
      ]
    addedChanges =
      [ breaking (aggName newAgg) "event" (evName newE) EvtFieldAddedWithoutBump ("field(s) " <> commas added <> " added at the same version v" <> tInt (evVersion newE) <> " without a version bump or upcaster")
      | not (null added)
      ]
    removedChanges =
      [ breaking (aggName newAgg) "event" (evName newE) EvtFieldRemovedSameVersion ("field(s) " <> commas removed <> " removed at the same version v" <> tInt (evVersion newE))
      | not (null removed)
      ]
    typeChanges =
      [ breaking
          (aggName newAgg)
          "event-field"
          (evName newE <> "." <> field)
          EvtFieldTypeChanged
          ("type changed " <> renderAggregateFieldType oldType <> " -> " <> renderAggregateFieldType newType <> " at the same version v" <> tInt (evVersion newE))
      | (field, oldType, newType) <- changed
      ]
    wireKeyChanges =
      [ breaking
          (aggName newAgg)
          "event-field-wire-key"
          (evName newE <> "." <> eventFieldDslName newField)
          EvtFieldWireKeyChanged
          ( "wire key changed '"
              <> eventFieldWireKey oldField
              <> "' -> '"
              <> eventFieldWireKey newField
              <> "'; restore the old key, or version the event and retain an upcaster"
          )
      | newField <- newFields,
        Just oldField <- [find ((== eventFieldDslName newField) . eventFieldDslName) oldFields],
        eventFieldWireKey oldField /= eventFieldWireKey newField
      ]
    deprecationChanges
      | not (evDeprecated oldE) && evDeprecated newE =
          [ if hasReplayOnlyEmitter newAgg (evName newE)
              then
                advisory
                  (aggName newAgg)
                  "event"
                  (evName newE)
                  EventRetirementInProgress
                  "event deprecated and removed from the live write path, while an equivalent replay-only transition preserves hydration. Retain that transition until every affected stream is terminal, truncated, or passes the replay audit"
              else
                advisory
                  (aggName newAgg)
                  "event"
                  (evName newE)
                  DeprecatedEventReplayHazard
                  ( "event deprecated: old payloads remain decodable but are no longer replayable — hydration of live streams containing them fails at the first command (HydrationNoInvertingEdge). Add an equivalent replay-only emitting transition or confirm every affected stream is terminal or truncated before deploying"
                      <> if evRetiring oldE then "" else "; consider a 'retiring event' stage first"
                  )
          ]
      | evDeprecated oldE && not (evDeprecated newE) && not (evRetiring newE) =
          [advisory (aggName newAgg) "event" (evName newE) EventUndeprecated "event returned to the write surface; old payloads remain decodable but new writes resume"]
      | otherwise = []
    retirementChanges
      | not (evRetiring oldE) && evRetiring newE =
          [advisory (aggName newAgg) "event" (evName newE) EventRetirementInProgress "retirement started; keep the live emitting transition until affected streams are terminal or truncated, then cut over to deprecated plus an equivalent replay-only emitting transition"]
      | evRetiring oldE && not (evRetiring newE) && not (evDeprecated newE) =
          [additive (aggName newAgg) "event" (evName newE) EventRetirementAbandoned "event retirement abandoned; ordinary live writes continue"]
      | otherwise = []

renderAggregateFieldType :: Maybe TypeExpr -> Text
renderAggregateFieldType Nothing = "(declared)"
renderAggregateFieldType (Just expression) = typeExprCanonicalName expression

renderFieldType :: Maybe Name -> Text
renderFieldType Nothing = "(declared)"
renderFieldType (Just name) = name

wireDiff :: Aggregate -> Aggregate -> [Change]
wireDiff oldAgg newAgg
  | effectiveWire (aggWire oldAgg) == effectiveWire (aggWire newAgg) = []
  | otherwise =
      [ breaking
          (aggName newAgg)
          "wire"
          (aggName newAgg)
          WireSpecChanged
          ("effective wire convention changed " <> renderWire (effectiveWire (aggWire oldAgg)) <> " -> " <> renderWire (effectiveWire (aggWire newAgg)))
      ]

effectiveWire :: Maybe WireSpec -> (Text, Text)
effectiveWire Nothing = ("ctorName", "camelCase")
effectiveWire (Just w) = (wireKind w, wireFields w)

renderWire :: (Text, Text) -> Text
renderWire (kindName, fieldNames) = "kind=" <> kindName <> ", fields=" <> fieldNames

projectionDiff :: Aggregate -> Aggregate -> [Change]
projectionDiff oldAggregate newAggregate
  | projectionSurface (aggProjection oldAggregate) == projectionSurface (aggProjection newAggregate) = []
  | otherwise =
      [ advisory
          (aggName newAggregate)
          "projection"
          (aggName newAggregate)
          ProjectionChanged
          "projection table, consistency, key, or status mapping changed; coordinate the read-model migration"
      ]

projectionSurface :: Maybe ProjectionSpec -> Maybe (Name, Maybe Consistency, Name, Maybe Mapping)
projectionSurface projection = do
  value <- projection
  pure (projTable value, projConsistency value, projKey value, projStatusMap value)

idDiff :: DiffEnv -> [Change]
idDiff env =
  concatMap (uncurry (idPairDiff (deOld env))) (prMatched paired)
    ++ concatMap addedIdDiff (prAdded paired)
    ++ concatMap removedIdDiff (prRemoved paired)
  where
    paired = pairDeclarations idName (specIds (deOld env)) (specIds (deNew env))

idPairDiff :: Spec -> IdDecl -> IdDecl -> [Change]
idPairDiff oldSpec oldId newId =
  [ breaking (idName newId) "id-prefix" (idName newId) IdPrefixChanged ("prefix changed '" <> idPrefix oldId <> "' -> '" <> idPrefix newId <> "'; stored and newly minted ids no longer share an identity domain")
  | idPrefix oldId /= idPrefix newId
  ]
    <> nominalBindingDeclDiff oldSpec "id" (idName newId) (idBinding oldId) (idBinding newId)
    <> [ nominalUseChange
           use
           NominalIdDecoderTightened
           "adopting a checked KindID binding tightens historical decoding; keep a committed valid old-payload fixture and run the targeted real-log audit for this event"
       | idBinding oldId == Nothing,
         isJust (idBinding newId),
         use@NominalEventUse {} <- nominalUses oldSpec (idName oldId)
       ]

addedIdDiff :: IdDecl -> [Change]
addedIdDiff declaration = [additive (idName declaration) "id-prefix" (idName declaration) DeclarationAdded "new id declaration"]

removedIdDiff :: IdDecl -> [Change]
removedIdDiff declaration = [breaking (idName declaration) "id-prefix" (idName declaration) IdPrefixChanged "id declaration removed; persisted ids still use its prefix"]

enumDiff :: DiffEnv -> [Change]
enumDiff env =
  concatMap (uncurry (enumPairDiff (deOld env))) (prMatched paired)
    ++ concatMap addedEnumDiff (prAdded paired)
    ++ concatMap (removedEnumDiff (deOld env)) (prRemoved paired)
  where
    paired = pairDeclarations enumName (specEnums (deOld env)) (specEnums (deNew env))

enumPairDiff :: Spec -> EnumDecl -> EnumDecl -> [Change]
enumPairDiff oldSpec oldEnum newEnum =
  [ breaking (enumName newEnum) "enum-constructor" ctor EnumCtorRemoved ("constructor removed; stored wire value '" <> wire <> "' no longer decodes" <> enumUsageSuffix oldSpec (enumName oldEnum))
  | (ctor, wire) <- enumCtors oldEnum,
    isNothing (lookup ctor (enumCtors newEnum))
  ]
    ++ [ breaking (enumName newEnum) "enum-constructor" ctor EnumWireSpellingChanged ("wire spelling changed '" <> oldWire <> "' -> '" <> newWire <> "'; stored values using the old spelling no longer decode" <> enumUsageSuffix oldSpec (enumName oldEnum))
       | (ctor, oldWire) <- enumCtors oldEnum,
         Just newWire <- [lookup ctor (enumCtors newEnum)],
         oldWire /= newWire
       ]
    ++ concat
      [ enumAdditionDiff oldSpec newEnum ctor wire
      | (ctor, wire) <- enumCtors newEnum,
        isNothing (lookup ctor (enumCtors oldEnum))
      ]
      <> nominalBindingDeclDiff oldSpec "enum" (enumName newEnum) (enumBinding oldEnum) (enumBinding newEnum)

nominalScalarDiff :: DiffEnv -> [Change]
nominalScalarDiff env =
  concatMap (uncurry scalarPairDiff) (prMatched paired)
    <> [nominalDeclarationChange (nominalScalarName declaration) DeclarationAdded "new nominal scalar declaration" | declaration <- prAdded paired]
    <> [nominalDeclarationChange (nominalScalarName declaration) NominalRepresentationChanged "nominal scalar declaration removed while persisted uses may remain" | declaration <- prRemoved paired]
  where
    paired = pairDeclarations nominalScalarName (specNominalScalars (deOld env)) (specNominalScalars (deNew env))
    scalarPairDiff oldDeclaration newDeclaration =
      [ nominalDeclarationChange
          (nominalScalarName newDeclaration)
          NominalRepresentationChanged
          ( "nominal scalar representation changed '"
              <> nominalScalarRepresentation oldDeclaration
              <> "' -> '"
              <> nominalScalarRepresentation newDeclaration
              <> "'"
          )
      | nominalScalarRepresentation oldDeclaration /= nominalScalarRepresentation newDeclaration
      ]
        <> nominalBindingDeclDiff
          (deOld env)
          "scalar"
          (nominalScalarName newDeclaration)
          (Just (nominalScalarBinding oldDeclaration))
          (Just (nominalScalarBinding newDeclaration))

data NominalUse
  = NominalCommandUse !Name !Name !Name
  | NominalEventUse !Name !Name !Name
  | NominalRegisterUse !Name !Name

nominalUses :: Spec -> Name -> [NominalUse]
nominalUses spec target = concatMap usesInAggregate [aggregate | NAggregate aggregate <- specNodes spec]
  where
    usesInAggregate aggregate =
      [ NominalCommandUse (aggName aggregate) (cmdName command) (aggregateFieldName field)
      | command <- aggCommands aggregate,
        field <- cmdFields command,
        fieldReferences target field
      ]
        <> [ NominalEventUse (aggName aggregate) (evName event) (aggregateFieldName field)
           | event <- aggEvents aggregate,
             field <- eventFields aggregate event,
             fieldReferences target field
           ]
        <> [ NominalRegisterUse (aggName aggregate) (regName register)
           | register <- aggRegs aggregate,
             regType register == TRef target
           ]
    eventFields aggregate event = case evBody event of
      EventFields fields -> fields
      EventFromCommand commandName -> concat [cmdFields command | command <- aggCommands aggregate, cmdName command == commandName]
    fieldReferences targetName field = case aggregateFieldType field of
      Just (TRef typeName) -> typeName == targetName
      Just _ -> False
      Nothing -> pascalName (aggregateFieldName field) == targetName
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
      | (nominalFixtures =<< oldBinding) /= (nominalFixtures =<< newBinding)
      ]
    <> concat
      [ nominalFinding NominalCanonicalTypeChanged "canonical nominal identity changed; rebuild consumers and invalidate snapshot caches at register uses"
      | (nominalCanonicalType =<< oldBinding) /= (nominalCanonicalType =<< newBinding)
      ]
    <> concat
      [ nominalFinding NominalInitialChanged "consumer-owned initial value symbol changed; rebuild and invalidate snapshot-bearing register streams"
      | (nominalInitial =<< oldBinding) /= (nominalInitial =<< newBinding)
      ]
  where
    bindingRuntimeFacts declaration =
      ( nominalHaskell =<< declaration,
        nominalBinding =<< declaration,
        nominalBindingVersion =<< declaration
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
  [additive (enumName enumDecl) "enum-constructor" ctor EnumCtorAdded ("new enum constructor with wire spelling '" <> wire <> "'") | (ctor, wire) <- enumCtors enumDecl]

enumAdditionDiff :: Spec -> EnumDecl -> Name -> Text -> [Change]
enumAdditionDiff oldSpec enumDecl ctor wire = case enumUsages oldSpec (enumName enumDecl) of
  [] ->
    [ additive
        (enumName enumDecl)
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
            (snapshotContext (enumName enumDecl) [usage])
            (enumName enumDecl)
            "enum-constructor"
            ctor
            EnumCtorAdded
            ("new constructor with wire spelling '" <> wire <> "' is used by " <> usage <> "; invalidate or rebuild snapshots before values using the new arm hydrate")
      | otherwise =
          advisoryAt
            (privateEventAdditionContext (enumName enumDecl) [usage])
            (enumName enumDecl)
            "enum-constructor"
            ctor
            EnumCtorAdded
            ("new constructor with wire spelling '" <> wire <> "' is used by " <> usage <> "; deploy consumers before producers emit the new arm")

removedEnumDiff :: Spec -> EnumDecl -> [Change]
removedEnumDiff oldSpec enumDecl =
  [ breaking (enumName enumDecl) "enum-constructor" ctor EnumCtorRemoved ("enum removed; stored wire value '" <> wire <> "' no longer decodes" <> enumUsageSuffix oldSpec (enumName enumDecl))
  | (ctor, wire) <- enumCtors enumDecl
  ]

enumUsageSuffix :: Spec -> Name -> Text
enumUsageSuffix spec enumType = case enumUsages spec enumType of
  [] -> ""
  usages -> "; used by " <> commas usages

enumUsages :: Spec -> Name -> [Text]
enumUsages spec enumType =
  [aggName agg <> ".reg." <> regName reg | agg <- aggregates, reg <- aggRegs agg, regType reg == TRef enumType]
    ++ [ aggName agg <> ".event." <> evName event <> "." <> eventFieldDslName field
       | agg <- aggregates,
         event <- aggEvents agg,
         field <- eventFieldSigs agg event,
         Just fieldTypeName <- [eventFieldType field],
         fieldTypeName == TRef enumType
       ]
  where
    aggregates = [agg | NAggregate agg <- specNodes spec]

pairDeclarations :: (n -> Name) -> [n] -> [n] -> Paired n
pairDeclarations nameOf oldNodes newNodes =
  Paired
    { prMatched =
        [ (oldNode, newNode)
        | newNode <- newNodes,
          Just oldNode <- [find ((== nameOf newNode) . nameOf) oldNodes]
        ],
      prAdded = [newNode | newNode <- newNodes, isNothing (find ((== nameOf newNode) . nameOf) oldNodes)],
      prRemoved = [oldNode | oldNode <- oldNodes, isNothing (find ((== nameOf oldNode) . nameOf) newNodes)]
    }

contractDiff :: DiffEnv -> [Change]
contractDiff env =
  concatMap (uncurry contractPairDiff) (prMatched paired)
    ++ concatMap addedContractDiff (prAdded paired)
    ++ concatMap removedContractDiff (prRemoved paired)
  where
    paired = pairByName nodeContract ctrName env

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
          (ctrName newContract)
          "schema-version"
          (ctrName newContract)
          ContractSchemaVersionDecreased
          ("schemaVersion decreased from " <> tInt (ctrSchemaVersion oldContract) <> " to " <> tInt (ctrSchemaVersion newContract))
      | ctrSchemaVersion newContract < ctrSchemaVersion oldContract
      ]
    discriminatorChanges =
      [ breaking
          (ctrName newContract)
          "discriminator"
          (ctrName newContract)
          ContractDiscriminatorChanged
          ("discriminator changed " <> ctrDiscriminator oldContract <> " -> " <> ctrDiscriminator newContract)
      | ctrDiscriminator oldContract /= ctrDiscriminator newContract
      ]
    topicChanges = contractTopicDiff oldContract newContract
    eventPairs = pairDeclarations ceName (ctrEvents oldContract) (ctrEvents newContract)
    matchedEvents = prMatched eventPairs
    addedEvents = prAdded eventPairs
    removedEvents' = prRemoved eventPairs
    eventPairChanges (oldEvent, newEvent) = contractEventDiff oldContract newContract oldEvent newEvent
    addedEventChanges event =
      [additive (ctrName newContract) "contract-event" (ceName event) ContractEventAdded "new contract event"]
    removedEventChanges event =
      [breaking (ctrName newContract) "contract-event" (ceName event) ContractEventRemoved "contract event removed; existing cross-service payloads no longer have a declared decoder"]

addedContractDiff :: ContractNode -> [Change]
addedContractDiff contract =
  [additive (ctrName contract) "contract-event" (ceName event) ContractEventAdded "new event in a new contract" | event <- ctrEvents contract]

removedContractDiff :: ContractNode -> [Change]
removedContractDiff contract =
  [breaking (ctrName contract) "contract-event" (ceName event) ContractEventRemoved "contract removed; its cross-service event decoder is no longer declared" | event <- ctrEvents contract]

contractTopicDiff :: ContractNode -> ContractNode -> [Change]
contractTopicDiff oldContract newContract =
  [ breaking
      (ctrName newContract)
      "contract-topic"
      alias
      ContractTopicChanged
      ("topic alias removed; previous topic was '" <> oldTopic <> "'")
  | (alias, oldTopic) <- ctrTopics oldContract,
    isNothing (lookup alias (ctrTopics newContract))
  ]
    ++ [ breaking
           (ctrName newContract)
           "contract-topic"
           alias
           ContractTopicChanged
           ("real topic changed '" <> oldTopic <> "' -> '" <> newTopic <> "'")
       | (alias, oldTopic) <- ctrTopics oldContract,
         Just newTopic <- [lookup alias (ctrTopics newContract)],
         oldTopic /= newTopic
       ]
    ++ [ additive (ctrName newContract) "contract-topic" alias ContractTopicAdded ("new topic alias for '" <> topic <> "'")
       | (alias, topic) <- ctrTopics newContract,
         isNothing (lookup alias (ctrTopics oldContract))
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
    fieldPairs = pairDeclarations cfName (ceFields oldEvent) (ceFields newEvent)
    topicAliasChange =
      [ breaking
          (ctrName newContract)
          "contract-topic"
          (ceName newEvent)
          ContractTopicChanged
          ("event topic alias changed " <> ceTopic oldEvent <> " -> " <> ceTopic newEvent)
      | ceTopic oldEvent /= ceTopic newEvent
      ]
    removedFieldChanges =
      [ breaking (ctrName newContract) "contract-field" (ceName newEvent <> "." <> cfName field) ContractFieldChanged "field removed; existing messages still carry the old contract shape"
      | field <- prRemoved fieldPairs
      ]
    changedFieldChanges =
      [ breaking
          (ctrName newContract)
          "contract-field"
          (ceName newEvent <> "." <> cfName newField)
          ContractFieldChanged
          ("field type changed " <> renderContractType (cfType oldField) <> " -> " <> renderContractType (cfType newField))
      | (oldField, newField) <- prMatched fieldPairs,
        cfType oldField /= cfType newField
      ]
    selectorFieldChanges =
      [ fieldSelectorChange
          (ctrName newContract)
          "contract-field-selector"
          (ceName newEvent <> "." <> cfName newField)
          (fieldSelector (resolveContractFieldIdentity oldField))
          (fieldSelector (resolveContractFieldIdentity newField))
          "contract field selector"
      | (oldField, newField) <- prMatched fieldPairs,
        fieldSelector (resolveContractFieldIdentity oldField)
          /= fieldSelector (resolveContractFieldIdentity newField)
      ]
    wireKeyFieldChanges =
      [ breaking
          (ctrName newContract)
          "contract-field"
          (ceName newEvent <> "." <> cfName newField)
          ContractFieldChanged
          ( "wire key changed '"
              <> fieldWireKey (resolveContractFieldIdentity oldField)
              <> "' -> '"
              <> fieldWireKey (resolveContractFieldIdentity newField)
              <> "'; restore the old key or revise the public contract with a consumer-first rollout"
          )
      | (oldField, newField) <- prMatched fieldPairs,
        fieldWireKey (resolveContractFieldIdentity oldField)
          /= fieldWireKey (resolveContractFieldIdentity newField)
      ]
    addedFieldChanges =
      [ if ctrSchemaVersion newContract > ctrSchemaVersion oldContract
          then advisory (ctrName newContract) "contract-field" subject ContractSchemaVersionBumped ("field added with schemaVersion bump " <> tInt (ctrSchemaVersion oldContract) <> " -> " <> tInt (ctrSchemaVersion newContract) <> "; coordinate the cross-service rollout")
          else breaking (ctrName newContract) "contract-field" subject ContractFieldChanged "field added without a schemaVersion bump; older in-flight messages do not contain it"
      | field <- prAdded fieldPairs,
        let subject = ceName newEvent <> "." <> cfName field
      ]

renderContractType :: ContractType -> Text
renderContractType (CTypeId prefix) = "typeid '" <> prefix <> "'"
renderContractType CText = "text"
renderContractType CInt = "int"

workqueueDiff :: DiffEnv -> [Change]
workqueueDiff env =
  concatMap (uncurry workqueuePairDiff) (prMatched paired)
    ++ concatMap addedWorkqueueDiff (prAdded paired)
    ++ concatMap removedWorkqueueDiff (prRemoved paired)
  where
    paired = pairWorkqueues env

-- | Prefer source identity, then pair a uniquely renamed queue by its complete
-- explicit runtime identity. This permits a generated module-segment rename to
-- remain a build-only finding without guessing when an external identity is
-- ambiguous.
pairWorkqueues :: DiffEnv -> Paired WorkqueueNode
pairWorkqueues env =
  Paired
    { prMatched = exact <> fallback,
      prAdded = [queue | queue <- unmatchedNew, queue `notElem` map snd fallback],
      prRemoved = [queue | queue <- unmatchedOld, queue `notElem` map fst fallback]
    }
  where
    oldQueues = mapMaybe nodeWorkqueue (specNodes (deOld env))
    newQueues = mapMaybe nodeWorkqueue (specNodes (deNew env))
    exact =
      [ (oldQueue, newQueue)
      | newQueue <- newQueues,
        Just oldQueue <- [find ((== wqName newQueue) . wqName) oldQueues]
      ]
    exactOldNames = map (wqName . fst) exact
    exactNewNames = map (wqName . snd) exact
    unmatchedOld = [queue | queue <- oldQueues, wqName queue `notElem` exactOldNames]
    unmatchedNew = [queue | queue <- newQueues, wqName queue `notElem` exactNewNames]
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
    ++ concatMap pairedFieldDiff (prMatched fields)
    ++ concatMap addedFieldDiff (prAdded fields)
    ++ concatMap removedFieldDiff (prRemoved fields)
    ++ queueIdentityDiff oldQueue newQueue
    ++ queuePolicyDiff oldQueue newQueue
  where
    generatedNameChanges =
      [ generatedNameChange
          (wqName newQueue)
          "workqueue-module"
          (wqName newQueue)
          (wqName oldQueue)
          (wqName newQueue)
          "workqueue module segment"
      | wqName oldQueue /= wqName newQueue,
        normalizedGeneratedUpper (wqName oldQueue) /= normalizedGeneratedUpper (wqName newQueue)
      ]
        ++ [ generatedNameChange
               (wqName newQueue)
               "workqueue-payload-type"
               (wqPayloadName newQueue)
               (wqPayloadName oldQueue)
               (wqPayloadName newQueue)
               "workqueue payload type"
           | wqPayloadName oldQueue /= wqPayloadName newQueue,
             normalizedGeneratedUpper (wqPayloadName oldQueue) /= normalizedGeneratedUpper (wqPayloadName newQueue)
           ]
    fields = pairDeclarations wqfName (wqPayload oldQueue) (wqPayload newQueue)
    pairedFieldDiff (oldField, newField)
      | wqfWire oldField /= wqfWire newField = [payloadBreaking newField ("wire name changed '" <> wqfWire oldField <> "' -> '" <> wqfWire newField <> "'")]
      | wqfType oldField /= wqfType newField = [payloadBreaking newField ("type changed " <> renderQueuePayloadType (wqfType oldField) <> " -> " <> renderQueuePayloadType (wqfType newField))]
      | otherwise = []
    renderQueuePayloadType (LegacyQueueScalar scalar) = queueScalarName scalar
    renderQueuePayloadType (TypedQueueExpression expression) = typeExprCanonicalName expression
    -- Every payload field is required, so adding one always breaks jobs already
    -- queued under the old shape; there is no optional variant to strengthen.
    addedFieldDiff field = [payloadBreaking field "new required field; queued jobs do not contain it"]
    removedFieldDiff field = [payloadBreaking field "field removed; queued jobs still contain the old payload shape"]
    payloadBreaking field detail =
      withMappedConsequences
        (Set.fromList [MappedConsumerBuild consumer, MappedWorkqueueHistory (wqName newQueue)])
        (breaking (wqName newQueue) "payload-field" (wqfName field) WqPayloadFieldChanged detail)
      where
        consumer = WorkqueueConsumer (wqName newQueue)

addedWorkqueueDiff :: WorkqueueNode -> [Change]
addedWorkqueueDiff queue =
  [additive (wqName queue) "payload-field" (wqfName field) DeclarationAdded "field belongs to a new workqueue payload" | field <- wqPayload queue]

removedWorkqueueDiff :: WorkqueueNode -> [Change]
removedWorkqueueDiff queue =
  [breaking (wqName queue) "payload-field" (wqfName field) WqPayloadFieldChanged "workqueue removed while persisted jobs may still carry this payload" | field <- wqPayload queue]
    ++ [breaking (wqName queue) "queue-identity" (wqName queue) QueueIdentityChanged "workqueue removed; its physical queue, DLQ, and pgmq table may still hold state"]

queueIdentityDiff :: WorkqueueNode -> WorkqueueNode -> [Change]
queueIdentityDiff oldQueue newQueue =
  [ breaking
      (wqName newQueue)
      "queue-identity"
      (wqName newQueue)
      QueueIdentityChanged
      "logical, physical, DLQ, or table name changed; queued jobs and dispatch dedupe records remain under the old identity"
  | queueIdentity oldQueue /= queueIdentity newQueue
  ]

queueIdentity :: WorkqueueNode -> (Text, Text, Text, Text)
queueIdentity queue = (wqLogical queue, wqPhysical queue, wqDlq queue, wqTable queue)

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
    Right derived -> HaskellName.renderUpperCamelName (HaskellName.upperCamel derived)
    Left _ -> logicalName
  where
    site =
      HaskellName.NameSite
        { HaskellName.siteKind = HaskellName.GeneratedTypeSite,
          HaskellName.siteLogicalName = logicalName,
          HaskellName.siteOwner = "diff",
          HaskellName.siteLine = 0
        }

queuePolicyDiff :: WorkqueueNode -> WorkqueueNode -> [Change]
queuePolicyDiff oldQueue newQueue = ordering ++ provision ++ groupKey
  where
    nodeName = wqName newQueue
    ordering =
      [ breaking nodeName "queue-ordering" nodeName WqOrderingChanged $
          "ordering changed " <> renderWqOrdering (wqOrdering oldQueue) <> " -> " <> renderWqOrdering (wqOrdering newQueue) <> "; consumers were written against the old delivery-order contract"
      | wqOrdering oldQueue /= wqOrdering newQueue
      ]
    provision =
      [ breaking nodeName "queue-provision" nodeName WqProvisionChanged $
          "provision changed " <> renderWqProvision (wqProvision oldQueue) <> " -> " <> renderWqProvision (wqProvision newQueue) <> "; provisioning is create-time only, so migrate the existing queue operationally before changing the spec"
      | wqProvision oldQueue /= wqProvision newQueue
      ]
    groupKey =
      [ breaking nodeName "queue-group-key" nodeName WqGroupKeyChanged $
          "group key derivation changed " <> renderWqGroupKey (wqGroupKey oldQueue) <> " -> " <> renderWqGroupKey (wqGroupKey newQueue) <> "; FIFO messages are re-partitioned across durable ordering groups"
      | wqGroupKey oldQueue /= wqGroupKey newQueue
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
  gkField groupKey
    <> " via "
    <> gkVia groupKey
    <> maybe "" (" fixture " <>) (gkFixture groupKey)

processDiff :: DiffEnv -> [Change]
processDiff env =
  concatMap (uncurry processPairDiff) (prMatched paired)
    ++ concatMap addedProcessDiff (prAdded paired)
    ++ concatMap removedProcessDiff (prRemoved paired)
  where
    paired = pairByName nodeProcess procId env

processPairDiff :: ProcessNode -> ProcessNode -> [Change]
processPairDiff oldProcess newProcess =
  concatMap pairedFieldDiff (prMatched fields)
    ++ map (fieldChange "field added; source events at the old shape cannot populate it") (prAdded fields)
    ++ map (fieldChange "field removed; the generated process input decoder changed") (prRemoved fields)
    ++ processIdentityDiff oldProcess newProcess
    ++ processTimerWindowDiff oldProcess newProcess
    ++ processDecideSurfaceDiff oldProcess newProcess
    ++ processTimerPayloadDiff oldProcess newProcess
  where
    -- inName is a generated Haskell type name; the wire shape is inFields.
    fields = pairDeclarations fieldName (inFields (procInput oldProcess)) (inFields (procInput newProcess))
    pairedFieldDiff (oldField, newField)
      | fieldType oldField /= fieldType newField = [fieldChange ("type changed " <> renderFieldType (fieldType oldField) <> " -> " <> renderFieldType (fieldType newField)) newField]
      | otherwise = []
    fieldChange detail field = breaking (procId newProcess) "input-field" (fieldName field) ProcessInputChanged (detail <> "; version the source event before changing process input")

addedProcessDiff :: ProcessNode -> [Change]
addedProcessDiff process =
  [additive (procId process) "input-field" (fieldName field) DeclarationAdded "field belongs to a new process input" | field <- inFields (procInput process)]

removedProcessDiff :: ProcessNode -> [Change]
removedProcessDiff process =
  [breaking (procId process) "input-field" (fieldName field) ProcessInputChanged "process removed while persisted source events may still require this input decoder" | field <- inFields (procInput process)]
    ++ [breaking (procId process) "derived-identity" (procId process) DerivedIdentityChanged "process removed while persisted saga, dispatch, and timer identities may still exist"]

processIdentityDiff :: ProcessNode -> ProcessNode -> [Change]
processIdentityDiff oldProcess newProcess =
  [ breaking
      (procId newProcess)
      "derived-identity"
      (procId newProcess)
      DerivedIdentityChanged
      "process name, correlation derivation, saga stream category, timer id expression, or fired-event-id expression changed; replays and retries no longer derive the persisted identity"
  | processIdentity oldProcess /= processIdentity newProcess
  ]

processIdentity :: ProcessNode -> (Text, Name, Name, Text, Text, Name, Text, Name)
processIdentity process =
  ( procName process,
    corrField (procCorrelate process),
    corrVia (procCorrelate process),
    sagaCategory (procSaga process),
    idePrefix (tmId (procTimer process)),
    ideField (tmId (procTimer process)),
    idePrefix (fireFiredEventId (tmFire (procTimer process))),
    ideField (fireFiredEventId (tmFire (procTimer process)))
  )

processTimerWindowDiff :: ProcessNode -> ProcessNode -> [Change]
processTimerWindowDiff oldProcess newProcess =
  [ advisory
      (procId newProcess)
      "timer"
      (tmName (procTimer newProcess))
      TimerWindowChanged
      ( "fireAt source/window changed "
          <> renderFireAt (tmFireAt (procTimer oldProcess))
          <> " -> "
          <> renderFireAt (tmFireAt (procTimer newProcess))
          <> "; already-scheduled timers keep their persisted deadline"
      )
  | tmFireAt (procTimer oldProcess) /= tmFireAt (procTimer newProcess)
  ]

processDecideSurfaceDiff :: ProcessNode -> ProcessNode -> [Change]
processDecideSurfaceDiff oldProcess newProcess =
  [ advisory
      (procId newProcess)
      "process-decide"
      (procId newProcess)
      ProcessDecideSurfaceChanged
      "process dispatch surface changed: a source event redelivered across the deploy dispatches under the same deterministic ids, so half-old/half-new fan-out merges silently. Drain or pause the process subscription and replay or discard dead letters before deploying; see docs/user/deploy-ordering.md. Hole-only decide changes are not visible to diff; the same drain rule applies to those too."
  | renderHandleSurface (procHandle oldProcess)
      /= renderHandleSurface (procHandle newProcess)
  ]

processTimerPayloadDiff :: ProcessNode -> ProcessNode -> [Change]
processTimerPayloadDiff oldProcess newProcess =
  [ advisory
      (procId newProcess)
      "timer-payload"
      (tmName (procTimer newProcess))
      ProcessTimerPayloadChanged
      "timer payload shape changed: rows scheduled before the deploy carry the old shape, unversioned, and fire under new code — the fire decoder must accept every historically scheduled shape or the timer dead-letters after maxAttempts. Hole-only timer-decoder changes are not visible to diff; the same drain rule applies to those too."
  | renderTimerPayloadSurface (procTimer oldProcess)
      /= renderTimerPayloadSurface (procTimer newProcess)
  ]

renderFireAt :: FireAtExpr -> Text
renderFireAt expression = "input." <> faField expression <> " + " <> faWindow expression

workflowDiff :: DiffEnv -> [Change]
workflowDiff env =
  concatMap (uncurry workflowPairDiff) (prMatched paired)
    ++ concatMap addedWorkflowDiff (prAdded paired)
    ++ concatMap removedWorkflowDiff (prRemoved paired)
  where
    paired = pairByName nodeWorkflow wfId env

workflowPairDiff :: WorkflowNode -> WorkflowNode -> [Change]
workflowPairDiff oldWorkflow newWorkflow =
  inputChanges
    ++ outputChanges
    ++ classifyWorkflowBody oldWorkflow newWorkflow
    ++ workflowIdentityDiff oldWorkflow newWorkflow
  where
    fields = pairDeclarations fieldName (wfInputFields oldWorkflow) (wfInputFields newWorkflow)
    inputChanges =
      [workflowShape field "input field added; journaled inputs at the old shape do not contain it" | field <- prAdded fields]
        ++ [workflowShape field "input field removed; journaled inputs still contain the old shape" | field <- prRemoved fields]
        ++ [ workflowShape newField ("input field type changed " <> renderFieldType (fieldType oldField) <> " -> " <> renderFieldType (fieldType newField))
           | (oldField, newField) <- prMatched fields,
             fieldType oldField /= fieldType newField
           ]
    outputChanges =
      [ breaking (wfId newWorkflow) "workflow-output" (wfOutput newWorkflow) WorkflowShapeChanged ("output type changed " <> wfOutput oldWorkflow <> " -> " <> wfOutput newWorkflow <> "; persisted outcomes may no longer decode")
      | wfOutput oldWorkflow /= wfOutput newWorkflow
      ]
    workflowShape field detail = breaking (wfId newWorkflow) "workflow-input" (fieldName field) WorkflowShapeChanged detail

addedWorkflowDiff :: WorkflowNode -> [Change]
addedWorkflowDiff workflow = [additive (wfId workflow) "workflow" (wfId workflow) DeclarationAdded "new workflow"]

removedWorkflowDiff :: WorkflowNode -> [Change]
removedWorkflowDiff workflow = [breaking (wfId workflow) "workflow" (wfId workflow) WorkflowShapeChanged "workflow removed while in-flight journals and outcomes may still require its decoder"]

workflowIdentityDiff :: WorkflowNode -> WorkflowNode -> [Change]
workflowIdentityDiff oldWorkflow newWorkflow =
  [ breaking
      (wfId newWorkflow)
      "workflow-name"
      (wfId newWorkflow)
      WorkflowStableNameChanged
      ("stable name changed '" <> wfStable oldWorkflow <> "' -> '" <> wfStable newWorkflow <> "'; in-flight journals remain under the old stream name")
  | wfStable oldWorkflow /= wfStable newWorkflow
  ]
    ++ [ breaking
           (wfId newWorkflow)
           "derived-identity"
           (wfId newWorkflow)
           DerivedIdentityChanged
           "workflow id source field or derivation changed; journal and deterministic child/step identities no longer coalesce with persisted executions"
       | (wfIdField oldWorkflow, wfIdVia oldWorkflow) /= (wfIdField newWorkflow, wfIdVia newWorkflow)
       ]

intakeDiff :: DiffEnv -> [Change]
intakeDiff env =
  concatMap (uncurry intakePairDiff) (prMatched paired)
    ++ concatMap addedIntakeDiff (prAdded paired)
    ++ concatMap removedIntakeDiff (prRemoved paired)
  where
    paired = pairByName nodeIntake inkName env

intakePairDiff :: IntakeNode -> IntakeNode -> [Change]
intakePairDiff oldIntake newIntake =
  [ breaking
      (inkName newIntake)
      "dedupe-identity"
      (inkName newIntake)
      DedupeIdentityChanged
      "dedupe key or policy changed; redelivered messages no longer match their persisted dedupe record"
  | (inkDedupeKey oldIntake, inkDedupePolicy oldIntake) /= (inkDedupeKey newIntake, inkDedupePolicy newIntake)
  ]
    ++ [ advisory
           (inkName newIntake)
           "decode-posture"
           (inkName newIntake)
           DecodePostureChanged
           "envelope/body decode posture changed; future messages are accepted or rejected differently"
       | inkDecode oldIntake /= inkDecode newIntake
       ]
    ++ [ advisory
           (inkName newIntake)
           "inbox-persistence"
           (inkName newIntake)
           IntakePersistenceChanged
           ("success-path envelope persistence changed " <> renderInkPersist (inkPersist oldIntake) <> " -> " <> renderInkPersist (inkPersist newIntake) <> "; existing rows are unchanged while future successful rows retain a different envelope shape")
       | inkPersist oldIntake /= inkPersist newIntake
       ]

renderInkPersist :: InkPersist -> Text
renderInkPersist InkPersistFull = "full-envelope"
renderInkPersist InkPersistDedupeOnly = "dedupe-only"

addedIntakeDiff :: IntakeNode -> [Change]
addedIntakeDiff intake = [additive (inkName intake) "intake" (inkName intake) DeclarationAdded "new intake"]

removedIntakeDiff :: IntakeNode -> [Change]
removedIntakeDiff intake = [breaking (inkName intake) "dedupe-identity" (inkName intake) DedupeIdentityChanged "intake removed while persisted dedupe records and redeliveries may remain"]

emitDiff :: DiffEnv -> [Change]
emitDiff env =
  concatMap (uncurry emitPairDiff) (prMatched paired)
    ++ concatMap addedEmitDiff (prAdded paired)
    ++ concatMap removedEmitDiff (prRemoved paired)
  where
    paired = pairByName nodeEmit emName env

emitPairDiff :: EmitNode -> EmitNode -> [Change]
emitPairDiff oldEmit newEmit =
  [ breaking
      (emName newEmit)
      "derived-identity"
      "messageId"
      DerivedIdentityChanged
      "messageId derive prefix changed; outbox retries no longer coalesce with persisted messages"
  | emMessageId oldEmit /= emMessageId newEmit
  ]
    ++ [ breaking
           (emName newEmit)
           "derived-identity"
           "idempotencyKey"
           DerivedIdentityChanged
           "idempotencyKey derive prefix changed; downstream dedupe no longer matches persisted messages"
       | emIdempotencyKey oldEmit /= emIdempotencyKey newEmit
       ]
    ++ [ advisory
           (emName newEmit)
           "emit-mapping"
           (emName newEmit)
           EmitMappingChanged
           "emit key, status discriminant, mapping rows, or explicit skip posture changed"
       | emitMapping oldEmit /= emitMapping newEmit
       ]

emitMapping :: EmitNode -> (Name, Name, [EmitMapRow], Bool)
emitMapping emit = (emKey emit, emDiscriminant emit, emMap emit, emSkip emit)

addedEmitDiff :: EmitNode -> [Change]
addedEmitDiff emit = [additive (emName emit) "emit" (emName emit) DeclarationAdded "new emit mapping"]

removedEmitDiff :: EmitNode -> [Change]
removedEmitDiff emit = [breaking (emName emit) "derived-identity" (emName emit) DerivedIdentityChanged "emit removed while persisted outbox identities may still retry"]

publisherDiff :: DiffEnv -> [Change]
publisherDiff env =
  concatMap (uncurry publisherPairDiff) (prMatched paired)
    ++ concatMap addedPublisherDiff (prAdded paired)
    ++ concatMap removedPublisherDiff (prRemoved paired)
  where
    paired = pairByName nodePublisher pubName env

publisherPairDiff :: PublisherNode -> PublisherNode -> [Change]
publisherPairDiff oldPublisher newPublisher =
  -- maxAttempts/backoff are retry tuning, not persisted decode or identity.
  [ breaking
      (pubName newPublisher)
      "derived-identity"
      "outboxId"
      DerivedIdentityChanged
      "stable outbox-id source field changed; retries no longer coalesce with persisted outbox rows"
  | pubOutboxField oldPublisher /= pubOutboxField newPublisher
  ]
    ++ [ advisory
           (pubName newPublisher)
           "publisher-policy"
           (pubName newPublisher)
           PublisherPolicyChanged
           ("ordering changed " <> pubOrdering oldPublisher <> " -> " <> pubOrdering newPublisher)
       | pubOrdering oldPublisher /= pubOrdering newPublisher
       ]

addedPublisherDiff :: PublisherNode -> [Change]
addedPublisherDiff publisher = [additive (pubName publisher) "publisher" (pubName publisher) DeclarationAdded "new publisher"]

removedPublisherDiff :: PublisherNode -> [Change]
removedPublisherDiff publisher = [breaking (pubName publisher) "derived-identity" (pubName publisher) DerivedIdentityChanged "publisher removed while persisted outbox rows may still require its stable identity"]

pgmqDispatchDiff :: DiffEnv -> [Change]
pgmqDispatchDiff env =
  concatMap (uncurry pgmqDispatchPairDiff) (prMatched paired)
    ++ concatMap addedPgmqDispatchDiff (prAdded paired)
    ++ concatMap removedPgmqDispatchDiff (prRemoved paired)
  where
    paired = pairByName nodePgmqDispatch pdName env

pgmqDispatchPairDiff :: PgmqDispatchNode -> PgmqDispatchNode -> [Change]
pgmqDispatchPairDiff oldDispatch newDispatch =
  [ breaking
      (pdName newDispatch)
      "dedupe-identity"
      (pdName newDispatch)
      DedupeIdentityChanged
      "dispatch dedupe key/read-model/queue surface changed; prior enqueue records no longer match"
  | dispatchDedupe oldDispatch /= dispatchDedupe newDispatch
  ]
    ++ [ advisory
           (pdName newDispatch)
           "retarget"
           (pdName newDispatch)
           DispatchRetargeted
           "source read model or target queue changed; future fan-out is routed differently"
       | dispatchTargets oldDispatch /= dispatchTargets newDispatch
       ]

dispatchDedupe :: PgmqDispatchNode -> (Name, Name, Text, Name, Text)
dispatchDedupe dispatch =
  ( pdDedupKey dispatch,
    pdDedupReadModel dispatch,
    pdDedupReadModelField dispatch,
    pdDedupQueue dispatch,
    pdDedupQueueField dispatch
  )

dispatchTargets :: PgmqDispatchNode -> (Name, Name)
dispatchTargets dispatch = (pdSourceReadModel dispatch, pdEnqueueTo dispatch)

addedPgmqDispatchDiff :: PgmqDispatchNode -> [Change]
addedPgmqDispatchDiff dispatch = [additive (pdName dispatch) "dispatch" (pdName dispatch) DeclarationAdded "new pgmq dispatch"]

removedPgmqDispatchDiff :: PgmqDispatchNode -> [Change]
removedPgmqDispatchDiff dispatch = [breaking (pdName dispatch) "dedupe-identity" (pdName dispatch) DedupeIdentityChanged "dispatch removed while persisted queue and read-model dedupe records may remain"]

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
    nodeName = wfId newWorkflow
    oldBody = normaliseWorkflowBody (wfBody oldWorkflow)
    newBody = normaliseWorkflowBody (wfBody newWorkflow)
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
      { ckNode = n,
        ckFacet = facet,
        ckSubject = subj,
        ckCode = code,
        ckContext = context,
        ckVector = classifyCompatibility context code,
        ckMappedPersistedImpact = case contextKind context of
          ContextQueue -> Just (MappedPersistedImpact (WorkqueueHistory (changeContextRoot context)) VBreaking)
          _ -> Nothing,
        ckMappedConsequences = Set.empty,
        ckPaths = changeContextPaths context,
        ckDetail = detail
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
    setLabel context = context {contextOriginalLabel = label}
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
        ReadModelConsistencyWeakened
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
