-- | The keiro DSL validator. A parsed 'Spec' is /valid/ only if it passes the
-- cross-cutting structural and hole-kind rules below. The point is to reject a
-- dangerous-by-omission spec — a deleted status-map, an undeclared command, a
-- guard atom that resolves to nothing, a wall-clock read inside a guard — /before
-- any Haskell is written/.
--
-- EP-1 defines the 'Diagnostic' framework and the cross-cutting rules; each later
-- vertical (EP-3…EP-6) appends its node-specific rules (e.g. EP-4's inbox
-- disposition inversions) reusing this same 'Diagnostic' type.
module Keiro.Dsl.Validate
  ( Severity (..),
    DiagnosticCode (..),
    DiagnosticOrigin (..),
    Diagnostic (..),
    diagnosticCodeText,
    diagnosticOrigin,
    parseDiagnosticCode,
    renderDiagnostic,
    minimumLanguageDiagnostics,
    runtimeTimerStatuses,
    canonicalEnvelopeHeaders,
    validateService,
    validateSpec,
    derivedQueueTrio,
    sagaCategoryError,
    nodeIdentity,
  )
where

import Data.Bits (xor)
import Data.Char (isControl, isSpace, ord, toLower)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.TypeID qualified as TypeID
import Data.Word (Word64)
import Keiro.Dsl.AggregateType
import Keiro.Dsl.EventOutput
import Keiro.Dsl.Expression
import Keiro.Dsl.FieldIdentity
import Keiro.Dsl.Grammar
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.IdDomain (contractIdDomainContractFor, idDomainContractFor)
import Keiro.Dsl.LanguageVersion (LanguageVersion, RuntimeCapability (..), SourceLanguage (..), effectiveLanguageVersion, languageVersionText, runtimeProfileHasCapability, sourceFormText)
import Keiro.Dsl.NominalType qualified as Nominal
import Keiro.Dsl.ProjectionSupply
import Keiro.Dsl.ReadModelShape (deriveShapeHash)
import Keiro.Dsl.RouterSelection qualified as RouterSelection
import Keiro.Dsl.RuntimePackage (isCabalPackageName)
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract (..), checkedLanguageContract, checkedProjectionSupplies, checkedSpec, checkedTypeGraph, legacyCheckedService)
import Keiro.Dsl.TypeGraph
import Keiro.Integration.Event qualified as Event
import Numeric (showHex)
import Text.Read (readMaybe)

data Severity = Error | Warning
  deriving stock (Eq, Show)

diagnosticCodeText :: DiagnosticCode -> Text
diagnosticCodeText = T.pack . show

parseDiagnosticCode :: Text -> Maybe DiagnosticCode
parseDiagnosticCode raw =
  case [diagnosticCode | diagnosticCode <- [minBound .. maxBound], diagnosticCodeText diagnosticCode == raw] of
    diagnosticCode : _ -> Just diagnosticCode
    [] -> Nothing

-- | A machine-checkable code per rule, so tests match on the code, not prose.
data DiagnosticCode
  = UndeclaredCommand
  | UndeclaredEvent
  | UndeclaredState
  | UnreachableState
  | TerminalHasOutgoing
  | GuardAtomOutOfScope
  | StatusMapNotTotal
  | ClockSampled
  | -- EP-2 (evolution). These codes are shared by single-spec validation and
    -- the cross-spec diff path, so the enum remains the single registry of
    -- evolution rules.
    EvtVersionMissingUpcaster
  | UpcasterChainGap
  | DeprecatedEventReplayHazard
  | EventRetirementInProgress
  | DeprecatedEventStillEmitted
  | WireSchemaVersionMismatch
  | EvtFieldAddedWithoutBump
  | EvtRemovedNotDeprecated
  | -- EP-3 (process manager + durable timer).
    ProcessFireAtNotInjected
  | ProcessDispatchIdSupplied
  | ProcessUnresolvedRef
  | ProcessBenignInversion
  | SagaCategoryIllegal
  | -- EP-4 (integration intake / inbox disposition).
    DispositionIncomplete
  | DispositionDuplicateRetry
  | DispositionPreviouslyFailedRetry
  | DispositionDecodeUnboundedRetry
  | -- EP-4 (integration coupling).
    EmitSkipMissing
  | EmitUnresolvedContract
  | PublisherUnresolvedEmit
  | IntakeUnresolvedContract
  | -- EP-5 (pgmq workqueue/dispatch).
    WqPhysicalDivergence
  | WqStoreFailureNotRetry
  | WqDecodeFailureNotDeadLetter
  | WqDlqWithoutCeiling
  | WqGroupKeyMissing
  | WqGroupKeyWithoutFifo
  | WqGroupKeyUnresolved
  | WqUnloggedDurability
  | WqPartitionSpecEmpty
  | SnapshotIntervalInvalid
  | SnapshotCodecFixtureInvalid
  | DispatchEnqueueUnresolved
  | -- EP-6 (workflow/operation).
    AwaitSignalMismatch
  | RunWorkflowUnresolved
  | WorkflowPatchDuplicate
  | WorkflowPatchIdInvalid
  | WorkflowContinueAsNewNotTerminal
  | -- Diff-only (cross-spec) decode and identity evolution rules.
    EvtFieldTypeChanged
  | EvtFieldRemovedSameVersion
  | EvtVersionDecreased
  | EnumCtorRemoved
  | EnumWireSpellingChanged
  | WireSpecChanged
  | ContractEventRemoved
  | ContractFieldChanged
  | ContractDiscriminatorChanged
  | ContractTopicChanged
  | ContractSchemaVersionDecreased
  | WqPayloadFieldChanged
  | ProcessInputChanged
  | WorkflowShapeChanged
  | WorkflowBodyChanged
  | WorkflowStableNameChanged
  | WorkflowPatchRemoved
  | WorkflowContinueSeedChanged
  | WqOrderingChanged
  | WqProvisionChanged
  | WqGroupKeyChanged
  | IdPrefixChanged
  | DedupeIdentityChanged
  | DerivedIdentityChanged
  | QueueIdentityChanged
  | TimerWindowChanged
  | EmitMappingChanged
  | DecodePostureChanged
  | IntakePersistenceChanged
  | ProjectionChanged
  | PublisherPolicyChanged
  | DispatchRetargeted
  | ContractSchemaVersionBumped
  | EventUndeprecated
  | -- EP-104 (validator soundness).
    WorkflowDuplicateLabel
  | WorkflowSleepDelayUnresolved
  | WorkflowIdFieldUnresolved
  | RuleDomainUnresolved
  | RuleNotTotal
  | RuleCaseUnknownCtor
  | ProcessFieldBindingUnresolved
  | ProcessTimerCeilingInvalid
  | OperationUnresolvedRef
  | AwaitSignalValueMismatch
  | WqDispositionIncomplete
  | DispositionDuplicateOutcome
  | TopicAffinityMismatch
  | StatusMapDanglingKey
  | StatusMapDuplicateKey
  | WriteTargetNotRegister
  | RegisterInitialOutOfScope
  | DuplicateNodeName
  | DuplicateEnumCtor
  | DuplicateEnumWire
  | DuplicateIdPrefix
  | DuplicateCommandName
  | DuplicateEventName
  | WqDlqDivergence
  | WqTableDivergence
  | DispatchDedupQueueUnresolved
  | DispatchDedupFieldUnresolved
  | -- EP-105 (notation integrity and scaffold-safe names).
    VertexCtorCollision
  | IdentUnsafeNormalization
  | GeneratedOccurrenceReserved
  | GeneratedOccurrenceCollision
  | -- EP-107 (first-class read models).
    RmShapeHashDrift
  | RmStrongInlineOnly
  | RmScopeWithoutStrong
  | RmUnknownColumnType
  | RmInlineFeedUnreferenced
  | RmConsistencyConflict
  | RmProjectionWithoutNode
  | QueryUnresolvedReadModel
  | QueryConsistencyInvalid
  | DispatchReadModelUnresolved
  | DispatchReadModelFieldUnknown
  | -- MasterPlan 32 / EP-4 projection catalogs.
    CatalogTargetUnknown
  | CatalogGroupUnknown
  | CatalogGroupEmpty
  | CatalogGroupOrderMismatch
  | CatalogTargetUnowned
  | CatalogTargetMultiplyOwned
  | CatalogPhysicalTargetDuplicate
  | CatalogTargetDependencyUnknown
  | CatalogTargetDependencyOutsideGroup
  | CatalogTargetDependencyCycle
  | CatalogProjectionNoSource
  | CatalogProjectionNoTarget
  | CatalogProjectionTargetOutsideGroup
  | CatalogSourceUnresolved
  | CatalogSourceOverlap
  | CatalogAmbiguousSourceOrdering
  | CatalogAsyncIdentityMissing
  | CatalogAsyncQueryBindingMissing
  | CatalogInlineIdentityUnexpected
  | CatalogCheckpointPolicyMissing
  | CatalogCheckpointPolicyDuplicate
  | CatalogCheckpointPolicyUnexpected
  | CatalogCheckpointPolicyReplayUnsafe
  | CatalogClearTargetLiveOnly
  | CatalogDuplicateHandlerOrder
  | CatalogReadModelBindingMissing
  | CatalogReadModelTargetOutsideGroup
  | CatalogReadModelPhysicalOverride
  | CatalogReadModelBackingRequired
  | CatalogReadModelBackingUnobserved
  | CatalogReadModelSupplierMissing
  | CatalogReadModelMultipleSuppliers
  | CatalogReadModelLegacyProjectionConflict
  | CatalogQueryWaitWithoutCompatibleCursor
  | CatalogQueryWaitWithAmbiguousCursor
  | CatalogTargetAdded
  | CatalogTargetRemoved
  | CatalogTargetLocationChanged
  | CatalogTargetResetPolicyChanged
  | CatalogTargetDependencyChanged
  | CatalogGroupChanged
  | CatalogRevisionNoTarget
  | CatalogRevisionGroupUnknown
  | CatalogRevisionTargetUnknown
  | CatalogRevisionTargetSetMismatch
  | CatalogRevisionIdentityInvalid
  | CatalogRevisionDuplicateTarget
  | CatalogRevisionPromotionNameInvalid
  | CatalogProjectionRevisionChanged
  | CatalogProjectionRevisionRemoved
  | CatalogTargetSchemaChanged
  | CatalogExternalReadIdentityInvalid
  | CatalogExternalReadVersionInvalid
  | CatalogExternalReadQueryUnknown
  | CatalogExternalReadTargetCardinalityInvalid
  | CatalogExternalReadCompatibilityInvalid
  | CatalogExternalReadRevisionUnknown
  | CatalogExternalReadRevisionGroupMismatch
  | CatalogExternalReadSurfaceGenerationInvalid
  | CatalogExternalReadRetired
  | CatalogExternalReadVersionAdded
  | CatalogExternalReadCompatibilityChanged
  | CatalogExternalReadResultShapeChanged
  | CatalogExternalReadContractChanged
  | CatalogOwnerChanged
  | CatalogOwnerRemoved
  | CatalogHandlerOrderChanged
  | CatalogSourceChanged
  | CatalogFeedIdentityChanged
  | CatalogCheckpointPolicyChanged
  | CatalogReplayPolicyChanged
  | CatalogQueryBindingChanged
  | ProjectionDeliveryChanged
  | QueryFreshnessChanged
  | -- EP-107 diff-only read-model evolution rules.
    ReadModelVersionDecreased
  | ReadModelShapeChangedWithoutBump
  | ReadModelFeedChanged
  | ReadModelConsistencyWeakened
  | ReadModelQueryInputChanged
  | ReadModelQueryResultChanged
  | -- EP-108 (router and worker-policy surfaces).
    RouterUnresolvedRef
  | RouterKeyFieldUnknown
  | RouterBindingUnscoped
  | RouterCommandUnknown
  | RouterReadModelUnverified
  | PolicyContradiction
  | PolicyDeadLetterUnused
  | AmbiguousMarkedBenign
  | AmbiguousFollowsRejectedPolicy
  | RouterStableNameChanged
  | -- Plan 143 (first-class replay-only transitions for guard evolution).
    -- The first two fire in single-spec @validateSpec@; the third is the
    -- diff-path guard-tightening advisory that prints the computed
    -- replay-only twin.
    ReplayOnlyEmitsNothing
  | ReplayOnlyCommandStillLive
  | AggGuardTightened
  | AggFoldSurfaceChanged
  | RouterDecideSurfaceChanged
  | ProcessDecideSurfaceChanged
  | ProcessTimerPayloadChanged
  | -- MasterPlan 25 / EP-5: append-only codes for findings that were
    -- formerly additive but uncoded.
    DeclarationAdded
  | VersionBumped
  | CompatibilityStrengthened
  | EnumCtorAdded
  | EventRetirementAbandoned
  | ContractEventAdded
  | ContractTopicAdded
  | WorkflowEvolutionGuardAdded
  | -- MasterPlan 25 / EP-149 (consumer-owned mapped types).
    MappedUnresolvedName
  | MappedAmbiguousName
  | MappedDuplicateFieldName
  | MappedDuplicateWireKey
  | MappedDuplicateArmName
  | MappedDuplicateWireTag
  | MappedNonInjectiveNullability
  | MappedRecursiveType
  | MappedUnsupportedEncoding
  | MappedMissingIngredient
  | MappedMissingInitialValue
  | MappedInvalidHaskellName
  | MappedInvalidIdentity
  | MappedImportConflict
  | MappedDefaultIllTyped
  | -- MasterPlan 25 / EP-149 mapped evolution codes.
    MappedFieldAddedWithDefault
  | MappedFieldAddedNoDefault
  | MappedFieldRemoved
  | MappedFieldTypeChanged
  | MappedPresenceChanged
  | MappedNullabilityChanged
  | MappedDefaultRemoved
  | MappedDefaultChanged
  | MappedWireKeyChanged
  | MappedUnionEncodingChanged
  | MappedArmAdded
  | MappedArmRemoved
  | MappedArmTagChanged
  | MappedEnumValueAdded
  | MappedEnumValueRemoved
  | MappedEnumSpellingChanged
  | MappedHaskellSourceChanged
  | MappedRecordConstructorChanged
  | MappedBindingChanged
  | MappedFixturesChanged
  | MappedInitialChanged
  | MappedCanonicalTypeChanged
  | MappedOpaqueCodecChanged
  | MappedModeCrossed
  | MappedDeclAdded
  | MappedDeclRemoved
  | -- MasterPlan 25 / EP-152 reporting and migration-evidence codes.
    CoverageOpaqueSurface
  | CoverageOpaqueBoundaryAdded
  | CoverageOpaqueGateExceeded
  | CodecCompareDifference
  | CodecCompareCoverageGap
  | CodecCompareInvalidInput
  | -- MasterPlan 26 / EP-153: whole-service composition refusals, emitted by
    -- "Keiro.Dsl.Workspace" when several @.keiro@ members are composed into
    -- one service graph. They live in this registry, not a parallel enum, so
    -- every gate stays correlatable by code (ADR 0004). Manifest syntax and
    -- structure errors deliberately have no code here: like a @.keiro@ parse
    -- error, they are refused before any graph exists to diagnose.
    WorkspaceMemberUnreadable
  | WorkspaceMemberParseFailed
  | WorkspaceContextMismatch
  | WorkspaceAuthorityConflict
  | WorkspaceDuplicateDeclaration
  | WorkspaceDuplicateNodeName
  | WorkspacePathCollision
  | WorkspaceSourceIndexInvalid
  | -- MasterPlan 26 / EP-155: whole-workspace diff facts. These are
    -- advisory consumer-build obligations, distinct from wire evolution.
    OwnershipMoved
  | WorkspaceAuthorityChanged
  | -- EP-157: canonical aggregate type resolution and capabilities.
    AggregateTypeUnknown
  | AggregateTypeUnsupportedAtUse
  | AggregateRegisterInitialInvalid
  | AggregateGuardTypeMismatch
  | AggregateGuardCapabilityUnsupported
  | AggregateExpressionRootUnknown
  | AggregateExpressionRootAmbiguous
  | AggregateExpressionPathInvalid
  | AggregateExpressionPathUnsupported
  | AggregateExpressionLiteralNeedsType
  | AggregateExpressionLiteralInvalid
  | AggregateExpressionOperandTypeMismatch
  | AggregateExpressionOperatorUnsupported
  | AggregateExpressionBooleanRequired
  | AggregateExpressionGuardBoolRequired
  | AggregateExpressionWriteTargetUnknown
  | AggregateExpressionWriteTypeMismatch
  | AggregateTransitionOwnershipConflict
  | DomainOutcomeDeclarationMissing
  | DomainOutcomeDeclarationDuplicate
  | DomainOutcomeTypeUnresolved
  | DomainOutcomeClauseMissing
  | DomainOutcomeClauseDuplicate
  | DomainOutcomeReasonTypeMismatch
  | DomainOutcomeAcceptedWithoutEvents
  | DomainOutcomeSilentEmits
  | DomainOutcomeSilentWrites
  | DomainOutcomeSilentStateChange
  | DomainOutcomeReplayOnlyClause
  | DomainOutcomeTypesChanged
  | DomainTransitionOutcomeChanged
  | CollectionExpressionUnsupported
  | -- EP-160: append-only source-language composition and diff facts.
    WorkspaceLanguageVersionMismatch
  | SourceLanguageDeclarationChanged
  | -- EP-158: checked consumer-owned nominal IDs, enums, and scalars.
    NominalMissingIngredient
  | NominalInvalidHaskellSource
  | NominalInvalidQualifiedName
  | NominalInvalidIdentity
  | NominalInvalidIdPrefix
  | NominalUnsupportedRepresentation
  | NominalEmptyEnumRepresentation
  | NominalMissingInitialValue
  | NominalNameCollision
  | NominalBindingChanged
  | NominalFixturesChanged
  | NominalCanonicalTypeChanged
  | NominalInitialChanged
  | NominalRepresentationChanged
  | NominalIdDecoderTightened
  | -- ExecPlan 171 / IR-14: versioned prefix-bearing ID admission policy.
    IdDomainContractChanged
  | -- ExecPlan 159 / IR-13: @fields(Command)@ output authority.
    EventOutputCommandMismatch
  | AggregateEventlessStateChange
  | -- ExecPlan 178: language-4 integration contract TypeID admission.
    ContractInvalidTypeIdPrefix
  | ContractTypeIdDomainChanged
  | -- ExecPlan 180: accepted-but-unenforced spec surfaces.
    PublisherOrderingUnknown
  | PublisherBackoffInvalid
  | IntakeDedupePolicyUnknown
  | PublisherMaxAttemptsBelowMinimum
  | ContractSchemaVersionBelowMinimum
  | ReadModelVersionBelowMinimum
  | IntakeDecodeSchemaVersionBelowMinimum
  | AggregateDuplicateFieldName
  | ContractDuplicateFieldName
  | ContractFieldShadowsDiscriminator
  | TransitionDuplicateUnguarded
  | ContractDuplicateEvent
  | ContractDuplicateTopicAlias
  | AggregateDuplicateState
  | AggregateDuplicateRegister
  | NominalDuplicateDeclaration
  | EmitMapDuplicateCase
  | TransitionUnguardedSibling
  | RuntimeIdentityInvalid
  | RuntimeIdentityDuplicate
  | ContractTopicNameInvalid
  | ReadModelIdentifierInvalid
  | ReadModelDuplicateColumn
  | IntakeBindUnresolved
  | IntakeDedupeKeyUnresolved
  | IntakeEnvelopePolicyUnknown
  | IntakeDecodeSchemaVersionMismatch
  | ContractTopicAliasUnresolved
  | WireClauseUnsupported
  | -- ExecPlan 190: an unchanged semantic/external declaration now presents a
    -- different generated Haskell occurrence.
    GeneratedHaskellNameChanged
  | -- ExecPlan 192: resolved field wire identities are checked before lowering.
    FieldWireKeyCollision
  | FieldWireKeyInvalid
  | -- ExecPlan 192: changing an aggregate event field's resolved wire key
    -- changes the persisted event decode surface.
    EvtFieldWireKeyChanged
  | -- ExecPlan 193: a CI-required released language floor was not met.
    LanguageVersionBelowMinimum
  | -- ExecPlan 194: scaffold's empty-node refusals are reported by check at
    -- the owning declaration before planning begins.
    AggregateEmpty
  | ContractEmpty
  | -- ExecPlan 194: pure scaffold-planning gates share check's located,
    -- machine-readable diagnostic pipeline.
    GeneratedPathCollision
  | GeneratedImportCycle
  | BehaviorDerivationInvalid
  | BehaviorSourceAnchorMissing
  | BehaviorSourceAnchorInexact
  | BehaviorSourceAnchorCollision
  | ConformanceFactKeyCollision
  | GeneratedPlanningInvariantViolation
  | -- ExecPlan 197: accepted but currently inert spec surfaces are reported
    -- through the ordinary warning pipeline.
    IntakeBindFlagUnenforced
  | RmInlineSubscriptionIgnored
  | -- ExecPlan 197: process and router references close under language 4.
    ProcessKeyFieldUnknown
  | ProcessDispatchKeyUnresolved
  | ProcessBindingUnscoped
  | -- ExecPlan 197: remaining accepted surfaces close under language 4.
    WqPayloadTypeUnknown
  | WindowOutOfRange
  | TimerIdFieldNotCorrelation
  | AggProjectionKeyUnresolved
  | PublisherOutboxFieldUnresolved
  | RouterBenignInversion
  | -- ExecPlan 199: spellings the grammar accepts that no runtime implements.
    -- Each names one concrete runtime fact the declaration contradicts, warns on
    -- released languages below 4, and errors from language 4 on.
    DecodeBodyPostureUnsupported
  | DispatchOnAppendedUnsupported
  | TimerNotMineUnsupported
  | IntakeBindHeaderUnknown
  | -- ExecPlan 199: the surfaces ExecPlan 197 parked as descriptive-only, closed
    -- by checking the reference each one actually names.
    TimerDecodeStatusUnknown
  | TimerDeadLetterTextInvalid
  | PgmqFanoutFunctionInvalid
  | -- MasterPlan 35 / EP-1: candidate typed surfaces remain fail-closed until
    -- their complete lowering plans land.
    MappedQueueLoweringPending
  | MappedReadModelLoweringPending
  | RouterSelectionNotDeclarative
  | RouterSelectionCapabilityUnavailable
  | RouterSelectionIdentityEmpty
  | RouterSelectionVersionInvalid
  | RouterSelectionQueryUnknown
  | RouterSelectionQueryContractMissing
  | RouterSelectionQueryInputBindingInvalid
  | RouterSelectionQueryInputTypeMismatch
  | RouterSelectionQueryResultNotList
  | RouterSelectionQueryRowNotStructural
  | RouterSelectionExpressionRootUnknown
  | RouterSelectionExpressionFieldUnknown
  | RouterSelectionExpressionFieldOptional
  | RouterSelectionExpressionTypeMismatch
  | RouterSelectionPredicateNotBool
  | RouterSelectionRecipientNotText
  | RouterSelectionOperatorUnsupported
  | RouterSelectionRecipientLimitMissing
  | RouterSelectionRecipientLimitInvalid
  | RouterSelectionOrderUnsupported
  | RouterSelectionDedupeUnsupported
  | RouterSelectionFailureAckForbidden
  | RouterSelectionRedeliveryUnsupported
  | RouterSelectionPartialDispatchUnsupported
  | RouterSelectionTargetAmbiguous
  | RouterSelectionCommandUnknown
  | RouterSelectionCommandMappingDuplicate
  | RouterSelectionCommandMappingIncomplete
  | RouterSelectionCommandMappingTypeMismatch
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Which command pipeline can actually produce a given 'DiagnosticCode'.
--
-- The registry exists so a CI warning policy cannot silently name a code the
-- selected command never emits. Before ExecPlan 199, @keiro-dsl check --deny
-- EvtFieldWireKeyChanged@ was accepted and then matched nothing forever,
-- because that code is only reachable from @diff@'s cross-revision comparison.
data DiagnosticOrigin
  = -- | Reachable from @check@ on a single spec or a workspace. This includes
    -- the pure scaffold-planning gates that @check@ replays, and it is the
    -- default for any code not positively classified below.
    CheckDiagnostic
  | -- | Reachable only from the structural-coverage pass, which runs only when
    -- @--coverage-report@ is supplied.
    CoverageDiagnostic
  | -- | Reachable only from @diff@, which compares two revisions of a spec.
    -- Nothing in a single-revision @check@ can produce these.
    DiffDiagnostic
  | -- | Reachable only from the generated codec-comparison path, which no
    -- @check@ or @diff@ invocation runs.
    CodecCompareDiagnostic
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Classify a code by the pipeline that emits it.
--
-- Only codes proven non-@check@ are listed; everything else falls through to
-- 'CheckDiagnostic'. The default is deliberately the permissive one: a
-- misclassification here would reject a working CI invocation, whereas falling
-- through merely preserves the pre-199 behavior of accepting the code.
diagnosticOrigin :: DiagnosticCode -> DiagnosticOrigin
diagnosticOrigin diagnosticCode = case diagnosticCode of
  -- Structural coverage, reachable from `check --coverage-report`.
  CoverageOpaqueSurface -> CoverageDiagnostic
  CoverageOpaqueGateExceeded -> CoverageDiagnostic
  -- Coverage delta, computed only against a previous revision.
  CoverageOpaqueBoundaryAdded -> DiffDiagnostic
  -- Generated codec comparison.
  CodecCompareDifference -> CodecCompareDiagnostic
  CodecCompareCoverageGap -> CodecCompareDiagnostic
  CodecCompareInvalidInput -> CodecCompareDiagnostic
  -- Cross-revision evolution facts.
  AggFoldSurfaceChanged -> DiffDiagnostic
  AggGuardTightened -> DiffDiagnostic
  DomainOutcomeTypesChanged -> DiffDiagnostic
  DomainTransitionOutcomeChanged -> DiffDiagnostic
  CompatibilityStrengthened -> DiffDiagnostic
  ContractDiscriminatorChanged -> DiffDiagnostic
  ContractEventAdded -> DiffDiagnostic
  ContractEventRemoved -> DiffDiagnostic
  ContractFieldChanged -> DiffDiagnostic
  ContractSchemaVersionBumped -> DiffDiagnostic
  ContractSchemaVersionDecreased -> DiffDiagnostic
  ContractTopicAdded -> DiffDiagnostic
  ContractTopicChanged -> DiffDiagnostic
  ContractTypeIdDomainChanged -> DiffDiagnostic
  DeclarationAdded -> DiffDiagnostic
  DecodePostureChanged -> DiffDiagnostic
  DedupeIdentityChanged -> DiffDiagnostic
  DerivedIdentityChanged -> DiffDiagnostic
  DispatchRetargeted -> DiffDiagnostic
  EmitMappingChanged -> DiffDiagnostic
  EnumCtorAdded -> DiffDiagnostic
  EnumCtorRemoved -> DiffDiagnostic
  EnumWireSpellingChanged -> DiffDiagnostic
  EventRetirementAbandoned -> DiffDiagnostic
  EventUndeprecated -> DiffDiagnostic
  EvtFieldAddedWithoutBump -> DiffDiagnostic
  EvtFieldRemovedSameVersion -> DiffDiagnostic
  EvtFieldTypeChanged -> DiffDiagnostic
  EvtFieldWireKeyChanged -> DiffDiagnostic
  EvtRemovedNotDeprecated -> DiffDiagnostic
  EvtVersionDecreased -> DiffDiagnostic
  GeneratedHaskellNameChanged -> DiffDiagnostic
  IdDomainContractChanged -> DiffDiagnostic
  IdPrefixChanged -> DiffDiagnostic
  IntakePersistenceChanged -> DiffDiagnostic
  MappedArmAdded -> DiffDiagnostic
  MappedArmRemoved -> DiffDiagnostic
  MappedArmTagChanged -> DiffDiagnostic
  MappedBindingChanged -> DiffDiagnostic
  MappedCanonicalTypeChanged -> DiffDiagnostic
  MappedDeclAdded -> DiffDiagnostic
  MappedDeclRemoved -> DiffDiagnostic
  MappedDefaultChanged -> DiffDiagnostic
  MappedDefaultRemoved -> DiffDiagnostic
  MappedEnumSpellingChanged -> DiffDiagnostic
  MappedEnumValueAdded -> DiffDiagnostic
  MappedEnumValueRemoved -> DiffDiagnostic
  MappedFieldAddedNoDefault -> DiffDiagnostic
  MappedFieldAddedWithDefault -> DiffDiagnostic
  MappedFieldRemoved -> DiffDiagnostic
  MappedFieldTypeChanged -> DiffDiagnostic
  MappedFixturesChanged -> DiffDiagnostic
  MappedHaskellSourceChanged -> DiffDiagnostic
  MappedInitialChanged -> DiffDiagnostic
  MappedModeCrossed -> DiffDiagnostic
  MappedNullabilityChanged -> DiffDiagnostic
  MappedOpaqueCodecChanged -> DiffDiagnostic
  MappedPresenceChanged -> DiffDiagnostic
  MappedRecordConstructorChanged -> DiffDiagnostic
  MappedUnionEncodingChanged -> DiffDiagnostic
  MappedWireKeyChanged -> DiffDiagnostic
  NominalBindingChanged -> DiffDiagnostic
  NominalCanonicalTypeChanged -> DiffDiagnostic
  NominalFixturesChanged -> DiffDiagnostic
  NominalIdDecoderTightened -> DiffDiagnostic
  NominalInitialChanged -> DiffDiagnostic
  NominalRepresentationChanged -> DiffDiagnostic
  OwnershipMoved -> DiffDiagnostic
  ProcessDecideSurfaceChanged -> DiffDiagnostic
  ProcessInputChanged -> DiffDiagnostic
  ProcessTimerPayloadChanged -> DiffDiagnostic
  ProjectionChanged -> DiffDiagnostic
  PublisherPolicyChanged -> DiffDiagnostic
  QueueIdentityChanged -> DiffDiagnostic
  ReadModelConsistencyWeakened -> DiffDiagnostic
  ReadModelFeedChanged -> DiffDiagnostic
  ReadModelQueryInputChanged -> DiffDiagnostic
  ReadModelQueryResultChanged -> DiffDiagnostic
  ReadModelShapeChangedWithoutBump -> DiffDiagnostic
  ReadModelVersionDecreased -> DiffDiagnostic
  RouterDecideSurfaceChanged -> DiffDiagnostic
  RouterStableNameChanged -> DiffDiagnostic
  SourceLanguageDeclarationChanged -> DiffDiagnostic
  TimerWindowChanged -> DiffDiagnostic
  VersionBumped -> DiffDiagnostic
  WireSpecChanged -> DiffDiagnostic
  WorkflowBodyChanged -> DiffDiagnostic
  WorkflowContinueSeedChanged -> DiffDiagnostic
  WorkflowEvolutionGuardAdded -> DiffDiagnostic
  WorkflowPatchRemoved -> DiffDiagnostic
  WorkflowShapeChanged -> DiffDiagnostic
  WorkflowStableNameChanged -> DiffDiagnostic
  WorkspaceAuthorityChanged -> DiffDiagnostic
  WqGroupKeyChanged -> DiffDiagnostic
  WqOrderingChanged -> DiffDiagnostic
  WqPayloadFieldChanged -> DiffDiagnostic
  WqProvisionChanged -> DiffDiagnostic
  _ -> CheckDiagnostic

-- | A line-numbered, structured diagnostic.
data Diagnostic = Diagnostic
  { line :: !Int,
    severity :: !Severity,
    code :: !DiagnosticCode,
    relatedLocations :: ![(Int, Text)],
    message :: !Text
  }
  deriving stock (Eq, Show)

-- | Render a diagnostic in the conventional
-- @\<file\>:\<line\>: error[\<code\>]: \<message\>@ form.
renderDiagnostic :: FilePath -> Diagnostic -> Text
renderDiagnostic file d =
  T.intercalate "\n" (primary : notes)
  where
    primary =
      T.pack file
        <> ":"
        <> T.pack (show ((.line) d))
        <> ": "
        <> sev
        <> "["
        <> T.pack (show ((.code) d))
        <> "]: "
        <> (.message) d
    notes =
      [ "  " <> T.pack file <> ":" <> T.pack (show noteLine) <> ": note: " <> note
      | (noteLine, note) <- (.relatedLocations) d
      ]
    sev = case (.severity) d of Error -> "error"; Warning -> "warning"

-- | Error diagnostics produced when the effective source language is below a
-- CI-required released floor. A legacy source has no preamble, so line 1 is the
-- actionable location where one should be added.
minimumLanguageDiagnostics :: LanguageVersion -> SourceLanguage -> [Diagnostic]
minimumLanguageDiagnostics floorVersion sourceLanguage
  | effectiveVersion >= floorVersion = []
  | otherwise =
      [ Diagnostic
          { line = sourceLanguageLine sourceLanguage,
            severity = Error,
            code = LanguageVersionBelowMinimum,
            relatedLocations = [],
            message =
              "effective language version "
                <> languageVersionText effectiveVersion
                <> " ("
                <> sourceFormText sourceLanguage
                <> ") is below the required minimum "
                <> languageVersionText floorVersion
                <> "; declare `language keiro-dsl "
                <> languageVersionText floorVersion
                <> "`"
          }
      ]
  where
    effectiveVersion = effectiveLanguageVersion sourceLanguage
    sourceLanguageLine LegacyUnversioned = 1
    sourceLanguageLine DeclaredLanguage {languageVersionLoc = Loc lineNumber} = lineNumber

-- | Reserved wall-clock atom names. Sampling any of these inside a guard or
-- write breaks deterministic replay: TIME IS INJECTED, NOT SAMPLED.
clockAtoms :: Set Name
clockAtoms = Set.fromList ["now", "currentTime", "wallClock", "today", "utcNow"]

-- | Validate a whole service under its effective released semantic contract.
-- An empty list means valid. Current released versions share this policy, but
-- selecting it at this boundary prevents successor semantics from being lost.
validateService :: CheckedService -> [Diagnostic]
validateService service =
  validateCheckedSpec
    (checkedLanguageContract service)
    (checkedTypeGraph service)
    (checkedProjectionSupplies service)
    (checkedSpec service)

-- | Compatibility wrapper for callers that have only a normalized graph. It
-- explicitly selects legacy/version-1 semantics; production source/workspace
-- routes use 'validateService'.
validateSpec :: Spec -> [Diagnostic]
validateSpec = validateService . legacyCheckedService

validateCheckedSpec :: EffectiveLanguageContract -> Either (NE.NonEmpty TypeGraphError) TypeGraph -> ProjectionSupplyAnalysis -> Spec -> [Diagnostic]
validateCheckedSpec languageContract typeGraphResult supplyAnalysis spec =
  sortOn (.line) (validateNames languageContract typeGraphResult spec ++ validateMapped typeGraphResult spec ++ validateNominal languageContract spec ++ validateAggregateTypes typeGraphResult spec ++ specLevelRules languageContract supplyAnalysis spec ++ concatMap (validateNode languageContract typeGraphResult supplyAnalysis spec) ((.nodes) spec))

-- | Rules added before language 4 ships consult the effective semantic
-- contract, not the numeric source spelling. Versions 1 through 3 retain their
-- released acceptance; runtime semantics 3 is the unreleased tightening gate.
enforcesSpecSurfaceClosures :: EffectiveLanguageContract -> Bool
enforcesSpecSurfaceClosures languageContract =
  runtimeProfileHasCapability ((.runtimeProfile) languageContract) StrictSpecSurfaceValidation

hasProjectionCatalog :: EffectiveLanguageContract -> Bool
hasProjectionCatalog languageContract =
  runtimeProfileHasCapability ((.runtimeProfile) languageContract) ProjectionCatalogRuntime

hasSeparatedProjectionQueryPolicy :: EffectiveLanguageContract -> Bool
hasSeparatedProjectionQueryPolicy languageContract =
  runtimeProfileHasCapability ((.runtimeProfile) languageContract) SeparatedProjectionQueryPolicy

validateNominal :: EffectiveLanguageContract -> Spec -> [Diagnostic]
validateNominal languageContract spec = domainErrors <> resolutionErrors
  where
    domainErrors =
      [ mkErr (locLine ((.loc) declaration)) NominalInvalidIdPrefix $
          "id '" <> (.name) declaration <> "' has invalid TypeID prefix '" <> (.prefix) declaration <> "': " <> T.pack (show reason)
      | declaration <- (.ids) spec,
        Just _ <- [idDomainContractFor languageContract ((.prefix) declaration)],
        Just reason <- [TypeID.checkPrefix ((.prefix) declaration)]
      ]
    resolutionErrors = case Nominal.resolveNominalTypes spec of
      Right _ -> []
      Left errors -> map nominalTypeDiagnostic (NE.toList errors)

nominalTypeDiagnostic :: Nominal.NominalTypeError -> Diagnostic
nominalTypeDiagnostic nominalError = case nominalError of
  Nominal.NominalMissingIngredient name loc ingredient ->
    problem loc NominalMissingIngredient $ "nominal declaration '" <> name <> "' is missing required " <> ingredient <> " provenance"
  Nominal.NominalInvalidHaskellSource name loc ingredient ->
    problem loc NominalInvalidHaskellSource $ "nominal declaration '" <> name <> "' has an invalid Haskell " <> ingredient <> " name"
  Nominal.NominalInvalidQualifiedValue name loc ingredient value ->
    problem loc NominalInvalidQualifiedName $
      "nominal declaration '" <> name <> "' has invalid " <> ingredient <> " symbol '" <> value <> "'; expected a module path plus a lower-initial value"
  Nominal.NominalInvalidIdentity name loc ingredient value ->
    problem loc NominalInvalidIdentity $ "nominal declaration '" <> name <> "' has invalid " <> ingredient <> " '" <> value <> "'"
  Nominal.NominalInvalidIdPrefix name loc prefix detail ->
    problem loc NominalInvalidIdPrefix $ "id '" <> name <> "' has invalid TypeID prefix '" <> prefix <> "': " <> detail
  Nominal.NominalUnsupportedScalar name loc representation ->
    problem loc NominalUnsupportedRepresentation $
      "nominal scalar '" <> name <> "' uses unsupported representation '" <> representation <> "'; supported representations are Text, Int, Natural, Bool, and Time"
  Nominal.NominalEmptyEnum name loc ->
    problem loc NominalEmptyEnumRepresentation $ "enum '" <> name <> "' must declare at least one closed representation constructor"
  Nominal.NominalMissingRegisterInitial name loc registerName ->
    problem loc NominalMissingInitialValue $
      "consumer-owned nominal type '" <> name <> "' is used by register '" <> registerName <> "' and must name an initial symbol"
  Nominal.NominalDeclarationCollision name loc categories ->
    problem loc NominalNameCollision $ "declaration name '" <> name <> "' collides across " <> T.intercalate ", " categories
  where
    problem loc diagnosticCode detail = mkErr (locLine loc) diagnosticCode (detail <> "; GHC and conformance validate consumer function bodies")

-- | Resolve every direct aggregate type once at the earliest semantic gate.
validateAggregateTypes :: Either (NE.NonEmpty TypeGraphError) TypeGraph -> Spec -> [Diagnostic]
validateAggregateTypes typeGraphResult spec = case Nominal.resolveNominalTypes spec of
  Left _ -> []
  Right _ -> concatMap aggregateRules aggregates
  where
    symbols = aggregateSymbolsFromGraphResult typeGraphResult spec
    aggregates = [aggregate | NAggregate aggregate <- (.nodes) spec]

    aggregateRules aggregate =
      outcomeTypeRules aggregate
        ++ concatMap commandRules ((.commands) aggregate)
        ++ concatMap eventRules ((.events) aggregate)
        ++ concatMap registerRules ((.regs) aggregate)
        ++ concatMap (transitionRules aggregate) ((.transitions) aggregate)
      where
        commandRules command = concatMap (fieldRule aggregate CommandFieldUse) ((.fields) command)
        eventRules event = case (.body) event of
          EventFields fields -> concatMap (fieldRule aggregate EventFieldUse) fields
          EventFromCommand _ -> []
        registerRules register = case resolveAggregateType symbols ((.loc) register) RegisterUse ((.valueType) register) of
          Left typeError -> [aggregateTypeDiagnostic typeError]
          Right AggregateMapped {} -> []
          Right resolved -> case resolveRegisterInitial symbols ((.loc) register) resolved ((.initial) register) of
            Left initialError -> [aggregateTypeDiagnostic initialError]
            Right _ -> []

    fieldRule aggregate useSite field =
      either (pure . aggregateTypeDiagnostic) (const []) (inferAggregateFieldType symbols aggregate useSite field)

    outcomeTypeRules aggregate = case (.domainOutcomeTypes) aggregate of
      Nothing -> []
      Just declaration ->
        unresolved "rejection" ((.rejectionType) declaration)
          ++ unresolved "no-op" ((.noOpType) declaration)
        where
          unresolved label name = case resolveAggregateType symbols ((.outcomeTypesLoc) declaration) HaskellLoweringUse (TRef name) of
            Right _ -> []
            Left _ ->
              [ mkErr (locLine ((.outcomeTypesLoc) declaration)) DomainOutcomeTypeUnresolved $
                  "aggregate '" <> (.name) aggregate <> "' declares unknown or unsupported " <> label <> " outcome type '" <> name <> "'"
              ]

    transitionRules aggregate transition = ownershipRules ++ outcomeExpressionRules
      where
        environment = expressionEnvironmentFromGraphResult typeGraphResult spec aggregate transition
        ownershipRules = case (.implementation) transition of
          LegacyHoleImplementation ->
            concatMap (comparisonRule aggregate transition) (maybe [] comparisons ((.guard) transition))
          GeneratedImplementation ->
            maybe [] (expressionDiagnostics . resolveGuardExpr environment) ((.guard) transition)
              ++ concatMap (expressionDiagnostics . uncurry (resolveWriteExpr environment)) ((.writes) transition)
          HoleImplementation ->
            [ mkErr (locLine ((.loc) transition)) AggregateTransitionOwnershipConflict $
                "transition '"
                  <> (.source) transition
                  <> " -- "
                  <> (.command) transition
                  <> "' selects implementation hole and therefore cannot also declare guard or write clauses"
            | (.guard) transition /= Nothing || not (null ((.writes) transition))
            ]
        outcomeExpressionRules = case ((.domainOutcomeTypes) aggregate, (.outcome) transition) of
          (Just declaration, Just (OutcomeRejected expression _)) -> resolveReason "rejected" ((.rejectionType) declaration) expression
          (Just declaration, Just (OutcomeNoOp expression _)) -> resolveReason "no-op" ((.noOpType) declaration) expression
          _ -> []
        resolveReason label typeName expression =
          case resolveAggregateType symbols ((.outcomeTypesLoc) declaration) HaskellLoweringUse (TRef typeName) of
            Left _ -> []
            Right expected ->
              case resolveScalarExpr environment (ExpectScalarType expected) expression of
                Right _ -> []
                Left diagnostics -> map (outcomeExpressionDiagnostic label . id) (NE.toList diagnostics)
          where
            declaration = case (.domainOutcomeTypes) aggregate of
              Just value -> value
              Nothing -> error "unreachable: outcome reason without declaration"

    outcomeExpressionDiagnostic label diagnostic =
      mkErr
        (locLine ((.loc) diagnostic))
        ( if (.code) diagnostic `elem` [ScalarOperandTypeMismatch, ScalarBooleanOperandRequired]
            then DomainOutcomeReasonTypeMismatch
            else expressionCode ((.code) diagnostic)
        )
        ("typed " <> label <> " outcome reason is invalid: " <> (.message) diagnostic)

    expressionDiagnostics = either (map expressionDiagnostic . NE.toList) (const [])

    expressionDiagnostic diagnostic =
      mkErr
        (locLine ((.loc) diagnostic))
        (expressionCode ((.code) diagnostic))
        ((.message) diagnostic)

    expressionCode = \case
      ScalarRootUnknown -> AggregateExpressionRootUnknown
      ScalarRootAmbiguous -> AggregateExpressionRootAmbiguous
      ScalarPathInvalid -> AggregateExpressionPathInvalid
      ScalarPathUnsupported -> AggregateExpressionPathUnsupported
      ScalarLiteralNeedsType -> AggregateExpressionLiteralNeedsType
      ScalarLiteralInvalid -> AggregateExpressionLiteralInvalid
      ScalarOperandTypeMismatch -> AggregateExpressionOperandTypeMismatch
      ScalarOperatorUnsupported -> AggregateExpressionOperatorUnsupported
      ScalarBooleanOperandRequired -> AggregateExpressionBooleanRequired
      ScalarGuardBoolRequired -> AggregateExpressionGuardBoolRequired
      ScalarWriteTargetUnknown -> AggregateExpressionWriteTargetUnknown
      ScalarWriteTypeMismatch -> AggregateExpressionWriteTypeMismatch

    comparisonRule aggregate transition (operator, left, right) =
      case (expressionType aggregate transition left, expressionType aggregate transition right) of
        (Right leftType, Right rightType)
          | leftType /= rightType ->
              [ mkErr (locLine ((.loc) transition)) AggregateGuardTypeMismatch $
                  "comparison operands have different aggregate types '"
                    <> aggregateCanonicalName leftType
                    <> "' and '"
                    <> aggregateCanonicalName rightType
                    <> "'"
              ]
          | aggregateCapability useSite leftType == Unsupported ->
              [ mkErr (locLine ((.loc) transition)) AggregateGuardCapabilityUnsupported $
                  renderAggregateUseSite useSite
                    <> " is unsupported for aggregate type '"
                    <> aggregateCanonicalName leftType
                    <> "'"
              ]
          | otherwise -> []
        _ -> []
      where
        useSite = case operator of
          OpEq -> EqualityGuardUse
          OpNeq -> EqualityGuardUse
          OpLt -> OrderingGuardUse
          OpLe -> OrderingGuardUse
          OpGt -> OrderingGuardUse
          OpGe -> OrderingGuardUse

    expressionType aggregate transition expression = case expression of
      EAtom (ABool _) -> pure AggregateBool
      EAtom (AName name) -> atomType aggregate transition name
      EOr {} -> pure AggregateBool
      EAnd {} -> pure AggregateBool
      ECmp {} -> pure AggregateBool
      EAdd _ left _ -> expressionType aggregate transition left
      ESubtract _ left _ -> expressionType aggregate transition left
      EMultiply _ left _ -> expressionType aggregate transition left
      EPath loc _ path -> case path of
        name : _ -> atomType aggregate transition name
        [] -> Left (AggregateTypeError loc EqualityGuardUse (UnknownAggregateType "<empty-path>"))
      ELiteral _ literal -> case literal of
        LiteralBool {} -> pure AggregateBool
        LiteralText {} -> pure AggregateText
        LiteralIntegral {} -> Left (AggregateTypeError (exprLoc expression) EqualityGuardUse (UnknownAggregateType "<contextual-integral-literal>"))
        LiteralQualified typeName _ -> resolveAggregateType symbols (exprLoc expression) EqualityGuardUse (TRef typeName)
        LiteralId typeName _ -> resolveAggregateType symbols (exprLoc expression) EqualityGuardUse (TRef typeName)

    atomType aggregate transition name = case [register | register <- (.regs) aggregate, (.name) register == name] of
      register : _ -> resolveAggregateType symbols ((.loc) register) RegisterUse ((.valueType) register)
      [] -> case [field | command <- (.commands) aggregate, (.name) command == (.command) transition, field <- (.fields) command, (.name) field == name] of
        field : _ -> inferAggregateFieldType symbols aggregate CommandFieldUse field
        [] -> case [(.name) declaration | declaration <- (.enums) spec, name `elem` map fst ((.ctors) declaration)] of
          enumType : _ -> resolveAggregateType symbols ((.loc) transition) CommandFieldUse (TRef enumType)
          []
            | name `elem` map (.name) ((.states) aggregate) -> pure (AggregateVertex ((.name) aggregate <> "Vertex"))
            | Just rule <- firstMatching ((== name) . (.name)) ((.rules) spec) ->
                resolveAggregateType symbols ((.loc) rule) EqualityGuardUse (nameTypeExpr ((.codomain) rule))
            | otherwise -> Left (AggregateTypeError ((.loc) transition) EqualityGuardUse (UnknownAggregateType name))

    nameTypeExpr name = case name of
      "Text" -> TText
      "Int" -> TInt
      "Bool" -> TBool
      "Natural" -> TNatural
      "Time" -> TTime
      "UTCTime" -> TTime
      "Json" -> TJson
      _ -> TRef name

    comparisons expression = case expression of
      EOr left right -> comparisons left <> comparisons right
      EAnd left right -> comparisons left <> comparisons right
      ECmp operator left right -> (operator, left, right) : comparisons left <> comparisons right
      EAdd _ left right -> comparisons left <> comparisons right
      ESubtract _ left right -> comparisons left <> comparisons right
      EMultiply _ left right -> comparisons left <> comparisons right
      EPath {} -> []
      ELiteral {} -> []
      EAtom {} -> []

aggregateTypeDiagnostic :: AggregateTypeError -> Diagnostic
aggregateTypeDiagnostic aggregateError =
  mkErr (locLine ((.loc) aggregateError)) diagnosticCode diagnosticMessage
  where
    diagnosticCode = case (.reason) aggregateError of
      UnknownAggregateType {} -> AggregateTypeUnknown
      UnsupportedAggregateShape {} -> AggregateTypeUnsupportedAtUse
      UnsupportedAggregateCapability {} -> case (.useSite) aggregateError of
        EqualityGuardUse -> AggregateGuardCapabilityUnsupported
        OrderingGuardUse -> AggregateGuardCapabilityUnsupported
        _ -> AggregateTypeUnsupportedAtUse
      InvalidRegisterInitial {} -> AggregateRegisterInitialInvalid
    diagnosticMessage = case (.reason) aggregateError of
      UnknownAggregateType name ->
        "unknown aggregate type '" <> name <> "' at " <> renderAggregateUseSite ((.useSite) aggregateError)
      UnsupportedAggregateShape expression ->
        "direct aggregate type '"
          <> typeExprCanonicalName expression
          <> "' is unsupported at "
          <> renderAggregateUseSite ((.useSite) aggregateError)
          <> "; use a mapped structural declaration for Json or container shapes"
      UnsupportedAggregateCapability resolved ->
        renderAggregateUseSite ((.useSite) aggregateError)
          <> " is unsupported for aggregate type '"
          <> aggregateCanonicalName resolved
          <> "'"
      InvalidRegisterInitial resolved detail ->
        "invalid " <> aggregateCanonicalName resolved <> " register initial: " <> detail

renderAggregateUseSite :: AggregateUseSite -> Text
renderAggregateUseSite useSite = case useSite of
  CommandFieldUse -> "command field"
  EventFieldUse -> "event field"
  RegisterUse -> "register"
  EqualityGuardUse -> "equality guard"
  OrderingGuardUse -> "ordering guard"
  WholeValueWriteUse -> "whole-value write"
  CodecUse -> "JSON codec"
  SnapshotUse -> "snapshot"
  HarnessSampleUse -> "harness sample"
  HaskellLoweringUse -> "Haskell lowering"

-- | Validate consumer-owned mapped declarations without inspecting consumer
-- Haskell. Symbol-shaped facts are checked lexically here; GHC remains the
-- authority for whether the named packages, modules, values, types, and
-- instances actually exist with the promised types.
validateMapped :: Either (NE.NonEmpty TypeGraphError) TypeGraph -> Spec -> [Diagnostic]
validateMapped typeGraphResult spec =
  mappedLexicalRules spec
    ++ mappedIdentityRules spec
    ++ mappedConflictRules spec
    ++ case typeGraphResult of
      Left errors -> concatMap (typeGraphDiagnostic spec) (NE.toList errors)
      Right graph -> mappedGraphRules spec graph

typeGraphDiagnostic :: Spec -> TypeGraphError -> [Diagnostic]
typeGraphDiagnostic spec = \case
  TGDeclError name declarationError ->
    [ mkErr (mappedLine spec name) diagnosticCode $
        "mapped declaration '" <> name <> "': " <> declarationErrorMessage declarationError
    ]
    where
      diagnosticCode = case declarationError of
        MissingHaskellSource {} -> MappedMissingIngredient
        MissingStructuralBinding {} -> MappedMissingIngredient
        MissingStructuralBindingVersion {} -> MappedMissingIngredient
        MissingCanonicalType {} -> MappedMissingIngredient
        MissingFixtureCases {} -> MappedMissingIngredient
        MissingOpaqueCodecIdentity {} -> MappedMissingIngredient
        MissingOpaqueCodecVersion {} -> MappedMissingIngredient
        EmptyQualifiedValueName {} -> MappedInvalidHaskellName
        EmptyCanonicalTypeId {} -> MappedInvalidIdentity
        EmptyBindingVersion {} -> MappedInvalidIdentity
        EmptyCodecIdentity {} -> MappedInvalidIdentity
        EmptyCodecVersion {} -> MappedInvalidIdentity
  TGAmbiguousName name origins ->
    [ mkErr (mappedLine spec name) MappedAmbiguousName $
        "type name '" <> name <> "' is ambiguous across " <> T.intercalate ", " origins
    ]
  TGUnresolvedRef owner missing loc ->
    [ mkErr (locLine loc) MappedUnresolvedName $
        "mapped declaration '" <> owner <> "' references unresolved mapped type '" <> missing <> "'"
    ]
  TGUnresolvedConsumerRef owner missing loc ->
    [ mkErr (locLine loc) MappedUnresolvedName $
        owner <> " references unresolved mapped type '" <> missing <> "'"
    ]
  TGRecursive names ->
    [ mkErr (mappedLine spec (headOr "<mapped>" names)) MappedRecursiveType $
        "recursive structural mapping is unsupported: " <> T.intercalate " -> " (names <> take 1 names)
    ]

declarationErrorMessage :: MappedDeclError -> Text
declarationErrorMessage = \case
  MissingHaskellSource _ -> "missing complete haskell package/module/type ingredient"
  MissingStructuralBinding _ -> "missing binding ingredient; GHC will verify the named value and its type"
  MissingStructuralBindingVersion _ -> "missing binding-version ingredient"
  MissingCanonicalType _ -> "missing canonical-type ingredient"
  MissingFixtureCases _ -> "missing fixtures ingredient; GHC will verify the named FixtureCases value"
  MissingOpaqueCodecIdentity _ -> "missing opaque codec identity ingredient"
  MissingOpaqueCodecVersion _ -> "missing opaque codec version ingredient"
  EmptyQualifiedValueName _ -> "a binding, fixture, or initial symbol is empty; GHC will verify a syntactically valid qualified value"
  EmptyCanonicalTypeId _ -> "canonical-type must be non-empty"
  EmptyBindingVersion _ -> "binding-version must be non-empty"
  EmptyCodecIdentity _ -> "opaque codec identity must be non-empty"
  EmptyCodecVersion _ -> "opaque codec version must be non-empty"

mappedLine :: Spec -> Name -> Int
mappedLine spec name =
  maybe 1 (locLine . mappedLoc) (firstMatching ((== name) . mappedName) ((.mapped) spec))

mappedName :: MappedDecl -> Name
mappedName MappedStructural {msName = name} = name
mappedName MappedOpaque {moName = name} = name

mappedLoc :: MappedDecl -> Loc
mappedLoc MappedStructural {msLoc = loc} = loc
mappedLoc MappedOpaque {moLoc = loc} = loc

mappedHaskell :: MappedDecl -> Maybe HaskellSource
mappedHaskell MappedStructural {msHaskell = source} = source
mappedHaskell MappedOpaque {moHaskell = source} = source

mappedCanonical :: MappedDecl -> Maybe Text
mappedCanonical MappedStructural {msCanonical = canonical} = canonical
mappedCanonical MappedOpaque {} = Nothing

mappedLexicalRules :: Spec -> [Diagnostic]
mappedLexicalRules spec = concatMap declarationRules ((.mapped) spec)
  where
    declarationRules declaration =
      constructorRule "mapped declaration name" (mappedName declaration) declaration
        ++ maybe [] (haskellRules declaration) (mappedHaskell declaration)
        ++ qualifiedFacts declaration
        ++ shapeConstructorRules declaration

    haskellRules declaration source =
      [ invalid declaration $ "Haskell package '" <> (.package) source <> "' does not follow Cabal package-name grammar"
      | not (isCabalPackageName ((.package) source))
      ]
        ++ [ invalid declaration $ "Haskell module '" <> (.moduleName) source <> "' must be dot-separated Upper identifiers"
           | not (moduleNameSafe ((.moduleName) source))
           ]
        ++ [ invalid declaration $ "Haskell type '" <> (.valueType) source <> "' must be an Upper identifier"
           | not (constructorSafe ((.valueType) source))
           ]

    qualifiedFacts MappedStructural {msBinding = binding, msFixtures = fixtures, msInitial = initial, msLoc = loc} =
      concatMap (qualifiedRule loc) [("binding", binding), ("fixtures", fixtures), ("initial", initial)]
    qualifiedFacts MappedOpaque {moFixtures = fixtures, moInitial = initial, moLoc = loc} =
      concatMap (qualifiedRule loc) [("fixtures", fixtures), ("initial", initial)]

    qualifiedRule loc (category, value) = case value of
      Just symbol
        | not (T.null symbol) && not (qualifiedValueSafe symbol) ->
            [ mkErr (locLine loc) MappedInvalidHaskellName $
                category <> " symbol '" <> symbol <> "' must be a module path plus a lower-initial value; GHC will verify that it exists with the promised type"
            ]
      _ -> []

    shapeConstructorRules declaration = case declaration of
      MappedStructural {msShape = ShapeRecord constructor _ fields} ->
        constructorRule "record constructor" constructor declaration
          ++ [ invalidAt (wireFieldLoc field) $ "record selector '" <> (.haskell) field <> "' must be a lower-initial Haskell identifier"
             | field <- fields,
               not (lowerIdentifierSafe ((.haskell) field))
             ]
      MappedStructural {msShape = ShapeEnum entries} ->
        [ invalidAt ((.loc) entry) $ "enum constructor '" <> (.ctor) entry <> "' must be an Upper identifier"
        | entry <- entries,
          not (constructorSafe ((.ctor) entry))
        ]
      MappedStructural {msShape = ShapeUnion _ arms} ->
        [ invalidAt ((.loc) arm) $ "union constructor '" <> (.ctor) arm <> "' must be an Upper identifier"
        | arm <- arms,
          not (constructorSafe ((.ctor) arm))
        ]
      MappedOpaque {} -> []

    constructorRule category value declaration =
      [ invalid declaration $ category <> " '" <> value <> "' must be an Upper identifier"
      | not (constructorSafe value)
      ]
    invalid declaration detail = invalidAt (mappedLoc declaration) detail
    invalidAt loc detail =
      mkErr (locLine loc) MappedInvalidHaskellName (detail <> "; this is a syntax check only, and GHC will verify the consumer declaration")

mappedIdentityRules :: Spec -> [Diagnostic]
mappedIdentityRules spec =
  [ mkErr (locLine (mappedLoc declaration)) MappedInvalidIdentity $
      "mapped declaration '" <> mappedName declaration <> "' has an identity/version containing an ASCII control character"
  | declaration <- (.mapped) spec,
    value <- identityValues declaration,
    T.any asciiControl value
  ]
  where
    identityValues MappedStructural {msBindingVersion = bindingVersion, msCanonical = canonical} = present [bindingVersion, canonical]
    identityValues MappedOpaque {moCodecId = codecIdentity, moCodecVersion = codecVersion} = present [codecIdentity, codecVersion]
    present = foldr (maybe id (:)) []

mappedConflictRules :: Spec -> [Diagnostic]
mappedConflictRules spec = sourceCollisions ++ canonicalCollisions ++ packageCollisions
  where
    declarations = (.mapped) spec
    sourceFacts = [(declaration, source) | declaration <- declarations, source <- maybeToList (mappedHaskell declaration)]
    sourceCollisions =
      [ conflict declaration $
          "Haskell target '" <> (.moduleName) source <> "." <> (.valueType) source <> "' is claimed by more than one mapped declaration"
      | (declaration, source) <- duplicatesBy (\(_, value) -> ((.moduleName) value, (.valueType) value)) sourceFacts
      ]
    canonicalFacts = [(declaration, canonical) | declaration <- declarations, canonical <- maybeToList (mappedCanonical declaration), not (T.null canonical)]
    canonicalCollisions =
      [ conflict declaration $ "canonical-type '" <> canonical <> "' is claimed by more than one mapped declaration"
      | (declaration, canonical) <- duplicatesBy snd canonicalFacts
      ]
    moduleFacts = [(declaration, (.moduleName) source, (.package) source) | (declaration, source) <- sourceFacts]
    packageCollisions =
      [ conflict declaration $
          "Haskell module '" <> moduleName <> "' is declared from conflicting packages '" <> oldPackage <> "' and '" <> packageName <> "'"
      | (index, (declaration, moduleName, packageName)) <- zip [0 :: Int ..] moduleFacts,
        (_, oldModule, oldPackage) <- take index moduleFacts,
        oldModule == moduleName,
        oldPackage /= packageName
      ]
    conflict declaration detail = mkErr (locLine (mappedLoc declaration)) MappedImportConflict detail
    maybeToList = maybe [] pure

mappedGraphRules :: Spec -> TypeGraph -> [Diagnostic]
mappedGraphRules spec graph =
  concatMap declarationRules (Map.elems ((.declarations) graph))
    ++ mappedRegisterInitialRules spec graph
  where
    declarationRules =
      foldMappedDecl
        MappedDeclAlgebra
          { onStructuralDecl = \declaration shape ->
              foldMappedShape (shapeRules declaration) shape,
            onOpaqueDecl = const []
          }

    shapeRules declaration =
      MappedShapeAlgebra
        { onRecord = \_ _ fields ->
            [ mappedError ((.loc) field) MappedDuplicateFieldName declaration $
                "record selector '" <> (.haskell) field <> "' is declared more than once"
            | field <- duplicatesBy (.haskell) fields
            ]
              ++ [ mappedError ((.loc) field) MappedDuplicateWireKey declaration $
                     "record wire key '" <> (.key) field <> "' is declared more than once"
                 | field <- duplicatesBy (.key) fields
                 ]
              ++ [ mappedError ((.loc) field) MappedUnsupportedEncoding declaration "record wire keys must be non-empty"
                 | field <- fields,
                   T.null ((.key) field)
                 ]
              ++ concatMap (fieldRules declaration) fields,
          onEnum = \entries ->
            [ mappedError ((.loc) entry) MappedDuplicateArmName declaration $
                "enum constructor '" <> (.ctor) entry <> "' is declared more than once"
            | entry <- duplicatesBy (.ctor) entries
            ]
              ++ [ mappedError ((.loc) entry) MappedDuplicateWireTag declaration $
                     "enum wire spelling '" <> (.tag) entry <> "' is declared more than once"
                 | entry <- duplicatesBy (.tag) entries
                 ]
              ++ [ mappedError ((.loc) entry) MappedUnsupportedEncoding declaration "enum wire spellings must be non-empty"
                 | entry <- entries,
                   T.null ((.tag) entry)
                 ],
          onUnion = \encoding arms ->
            [ mappedError ((.loc) declaration) MappedUnsupportedEncoding declaration "tagged-object tag and contents keys must be distinct"
            | (.tagField) encoding == (.contentsField) encoding
            ]
              ++ [ mappedError ((.loc) declaration) MappedUnsupportedEncoding declaration "tagged-object tag and contents keys must be non-empty"
                 | T.null ((.tagField) encoding) || T.null ((.contentsField) encoding)
                 ]
              ++ [ mappedError ((.loc) arm) MappedDuplicateArmName declaration $
                     "union constructor '" <> (.ctor) arm <> "' is declared more than once"
                 | arm <- duplicatesBy (.ctor) arms
                 ]
              ++ [ mappedError ((.loc) arm) MappedDuplicateWireTag declaration $
                     "union wire tag '" <> (.tag) arm <> "' is declared more than once"
                 | arm <- duplicatesBy (.tag) arms
                 ]
              ++ [ mappedError ((.loc) arm) MappedUnsupportedEncoding declaration "union wire tags must be non-empty"
                 | arm <- arms,
                   T.null ((.tag) arm)
                 ]
              ++ concatMap (armRules declaration) arms
        }

    fieldRules declaration field =
      defaultRules declaration field
        ++ [ mappedError ((.loc) field) MappedNonInjectiveNullability declaration $
               "field '" <> (.haskell) field <> "' contains Optional around a null-capable Json, Optional, or opaque mapped value"
           | hasNonInjectiveOptional graph ((.valueType) field)
           ]

    armRules declaration arm =
      [ mappedError ((.loc) arm) MappedNonInjectiveNullability declaration $
          "union arm '" <> (.ctor) arm <> "' contains Optional around a null-capable Json, Optional, or opaque mapped value"
      | payload <- maybeToList ((.payload) arm),
        hasNonInjectiveOptional graph payload
      ]

    defaultRules declaration field = case ((.presence) field, (.onMissing) field) of
      (PRequired, Just _) -> [illTyped "required fields cannot declare on-missing"]
      (POptional, Nothing) ->
        [ mappedError ((.loc) field) MappedMissingIngredient declaration $
            "optional field '" <> (.haskell) field <> "' is missing its on-missing policy"
        ]
      (POptional, Just value)
        | not (defaultMatches graph ((.valueType) field) value) -> [illTyped "on-missing value does not match the field type or numeric bounds"]
      _ -> []
      where
        illTyped detail =
          mappedError ((.loc) field) MappedDefaultIllTyped declaration $
            "field '" <> (.haskell) field <> "': " <> detail

    mappedError loc diagnosticCode declaration detail =
      mkErr (locLine loc) diagnosticCode $
        "mapped declaration '" <> (.name) declaration <> "' " <> detail
    maybeToList = maybe [] pure

data DefaultType
  = DefaultText
  | DefaultInt
  | DefaultBool
  | DefaultNatural
  | DefaultOptional
  | DefaultList
  | DefaultMap
  | DefaultEnum !(Set Name)
  | DefaultOther

defaultMatches :: TypeGraph -> ResolvedTypeExpr -> OnMissing -> Bool
defaultMatches graph expression value = case (defaultType graph expression, value) of
  (DefaultText, OmText _) -> True
  (DefaultInt, OmInt integer) -> integer >= toInteger (minBound :: Int) && integer <= toInteger (maxBound :: Int)
  (DefaultBool, OmBool _) -> True
  (DefaultNatural, OmInt integer) -> integer >= 0
  (DefaultOptional, OmNull) -> True
  (DefaultList, OmEmptyList) -> True
  (DefaultMap, OmEmptyMap) -> True
  (DefaultEnum constructors, OmCtor constructor) -> constructor `Set.member` constructors
  _ -> False

defaultType :: TypeGraph -> ResolvedTypeExpr -> DefaultType
defaultType graph =
  foldTypeExpr
    TypeExprAlgebra
      { onText = DefaultText,
        onInt = DefaultInt,
        onInteger = DefaultInt,
        onBool = DefaultBool,
        onNatural = DefaultNatural,
        onTime = DefaultOther,
        onJson = DefaultOther,
        onOptional = const DefaultOptional,
        onList = const DefaultList,
        onMap = const DefaultMap,
        onRef = referencedDefaultType graph
      }

referencedDefaultType :: TypeGraph -> MappedKey -> DefaultType
referencedDefaultType graph key = case Map.lookup key ((.declarations) graph) of
  Nothing -> DefaultOther
  Just declaration ->
    foldMappedDecl
      MappedDeclAlgebra
        { onStructuralDecl = \_ shape ->
            foldMappedShape
              MappedShapeAlgebra
                { onRecord = \_ _ _ -> DefaultOther,
                  onEnum = DefaultEnum . Set.fromList . map (.ctor),
                  onUnion = \_ _ -> DefaultOther
                }
              shape,
          onOpaqueDecl = const DefaultOther
        }
      declaration

data NullabilityFacts = NullabilityFacts
  { topNull :: !Bool,
    badOptional :: !Bool
  }

hasNonInjectiveOptional :: TypeGraph -> ResolvedTypeExpr -> Bool
hasNonInjectiveOptional graph =
  (.badOptional)
    . foldTypeExpr
      TypeExprAlgebra
        { onText = nonNull,
          onInt = nonNull,
          onInteger = nonNull,
          onBool = nonNull,
          onNatural = nonNull,
          onTime = nonNull,
          onJson = nullable,
          onOptional = \child -> NullabilityFacts True ((.topNull) child || (.badOptional) child),
          onList = nestedNonNull,
          onMap = nestedNonNull,
          onRef = \key -> if mappedRefIsOpaque graph key then nullable else nonNull
        }
  where
    nonNull = NullabilityFacts False False
    nullable = NullabilityFacts True False
    nestedNonNull child = NullabilityFacts False ((.badOptional) child)

mappedRefIsOpaque :: TypeGraph -> MappedKey -> Bool
mappedRefIsOpaque graph key = case Map.lookup key ((.declarations) graph) of
  Nothing -> False
  Just declaration ->
    foldMappedDecl
      MappedDeclAlgebra
        { onStructuralDecl = \_ _ -> False,
          onOpaqueDecl = const True
        }
      declaration

mappedRegisterInitialRules :: Spec -> TypeGraph -> [Diagnostic]
mappedRegisterInitialRules spec graph =
  concatMap aggregateRules [aggregate | NAggregate aggregate <- (.nodes) spec]
  where
    aggregateRules aggregate = concatMap registerRule ((.regs) aggregate)
    registerRule register = case (.valueType) register of
      TRef typeName -> case Map.lookup (MappedKey typeName) ((.declarations) graph) of
        Nothing -> []
        Just declaration -> case (.initial) register of
          RegInitBare "initial"
            | mappedInitial declaration == Nothing ->
                [ mkErr (locLine ((.loc) register)) MappedMissingInitialValue $
                    "mapped register '" <> (.name) register <> "' requires declaration '" <> typeName <> "' to name an explicit initial value"
                ]
            | otherwise -> []
          _ ->
            [ mkErr (locLine ((.loc) register)) RegisterInitialOutOfScope $
                "mapped register '" <> (.name) register <> "' must use the bare initial token; the declaration-owned symbol is verified by GHC"
            ]
      _ -> []
    mappedInitial =
      foldMappedDecl
        MappedDeclAlgebra
          { onStructuralDecl = \declaration _ -> (.initial) declaration,
            onOpaqueDecl = (.initial)
          }

moduleNameSafe :: Text -> Bool
moduleNameSafe moduleName =
  not (null components) && all constructorSafe components
  where
    components = T.splitOn "." moduleName

qualifiedValueSafe :: Text -> Bool
qualifiedValueSafe qualified = case reverse (T.splitOn "." qualified) of
  value : reversedModule ->
    not (null reversedModule)
      && lowerIdentifierSafe value
      && all constructorSafe reversedModule
  [] -> False

lowerIdentifierSafe :: Text -> Bool
lowerIdentifierSafe name = case T.uncons name of
  Just (first, rest) -> asciiLower first && T.all asciiAlphaNumOrUnderscore rest && name `Set.notMember` HaskellName.haskellKeywords
  Nothing -> False

asciiControl :: Char -> Bool
asciiControl c = ord c < 32 || ord c == 127

firstMatching :: (a -> Bool) -> [a] -> Maybe a
firstMatching predicate = \case
  [] -> Nothing
  value : rest
    | predicate value -> Just value
    | otherwise -> firstMatching predicate rest

headOr :: a -> [a] -> a
headOr fallback = \case
  [] -> fallback
  value : _ -> value

-- | Check every logical name before a renderer can turn it into Haskell.  The
-- parser enforces the ASCII alphabet; 'HaskellName' owns word segmentation,
-- casing, keywords, and normalized collision keys.
validateNames :: EffectiveLanguageContract -> Either (NE.NonEmpty TypeGraphError) TypeGraph -> Spec -> [Diagnostic]
validateNames languageContract typeGraphResult spec =
  concat
    [ concatMap idNames ((.ids) spec),
      concatMap enumNames ((.enums) spec),
      concatMap nominalNames ((.nominalScalars) spec),
      concatMap nodeNames ((.nodes) spec),
      normalizedCollisions
    ]
  where
    idNames declaration =
      constructorName "id name" ((.name) declaration) ((.loc) declaration)

    enumNames declaration =
      constructorName "enum name" ((.name) declaration) ((.loc) declaration)
        ++ concatMap
          (\(ctor, _) -> constructorName ("constructor of enum '" <> (.name) declaration <> "'") ctor ((.loc) declaration))
          ((.ctors) declaration)

    nominalNames declaration =
      constructorName "nominal scalar name" ((.name) declaration) ((.loc) declaration)

    nodeNames = \case
      NAggregate aggregate -> aggregateNames aggregate
      NProcess process -> processNames process
      NRouter router -> routerNames router
      NContract contract ->
        pascalizedNodeName "contract" ((.name) contract) ((.loc) contract)
          ++ concatMap
            (\event -> constructorName "contract event name" ((.name) event) ((.loc) contract) ++ concatMap contractFieldName ((.fields) event))
            ((.events) contract)
      NIntake intake -> pascalizedNodeName "intake" ((.name) intake) ((.loc) intake)
      NEmit emitNode -> pascalizedNodeName "emit" ((.name) emitNode) ((.loc) emitNode)
      NPublisher publisher -> pascalizedNodeName "publisher" ((.name) publisher) ((.loc) publisher)
      NWorkqueue workqueue ->
        pascalizedNodeName "workqueue" ((.name) workqueue) ((.loc) workqueue)
          ++ constructorName "workqueue payload name" ((.payloadName) workqueue) ((.loc) workqueue)
          ++ concatMap (\field -> fieldNameRule "workqueue payload field" ((.name) field) ((.loc) workqueue)) ((.payload) workqueue)
      NPgmqDispatch dispatch -> pascalizedNodeName "dispatch" ((.name) dispatch) ((.loc) dispatch)
      NReadModel readModel -> pascalizedNodeName "readmodel" ((.name) readModel) ((.loc) readModel)
      NProjectionTarget target -> pascalizedNodeName "target" ((.name) target) ((.loc) target)
      NRebuildGroup groupNode -> pascalizedNodeName "rebuild group" ((.name) groupNode) ((.loc) groupNode)
      NProjectionRevision revision -> pascalizedNodeName "projection revision" ((.name) revision) ((.loc) revision)
      NExternalRead externalRead -> pascalizedNodeName "external read" (externalReadNodeIdentity externalRead) ((.loc) externalRead)
      NProjectionOwner owner -> pascalizedNodeName "projection owner" ((.name) owner) ((.loc) owner)
      NWorkflow workflow -> workflowNames workflow
      NOperation _ -> []

    aggregateNames aggregate =
      constructorName "aggregate name" ((.name) aggregate) ((.loc) aggregate)
        ++ concatMap
          (\register -> fieldNameRule "register name" ((.name) register) ((.loc) register))
          ((.regs) aggregate)
        ++ concatMap commandNames ((.commands) aggregate)
        ++ concatMap eventNames ((.events) aggregate)
        ++ maybe [] (\projection -> fieldNameRule "projection key" ((.key) projection) ((.loc) projection)) ((.projection) aggregate)
        ++ vertexCollisions aggregate
      where
        commandNames command =
          constructorName "command name" ((.name) command) ((.loc) command)
            ++ concatMap (aggregateFieldNameRule "command field") ((.fields) command)
        eventNames event =
          constructorName "event name" ((.name) event) ((.loc) event)
            ++ case (.body) event of
              EventFields fields -> concatMap (aggregateFieldNameRule "event field") fields
              EventFromCommand _ -> []

    processNames process =
      constructorName "process name" ((.id) process) ((.loc) process)
        ++ constructorName "process input name" ((.name) input) ((.loc) process)
        ++ concatMap (\field -> fieldNameRule "process input field" ((.name) field) ((.loc) process)) ((.fields) input)
        ++ concatMap (bindingName "advance field binding" ((.loc) process)) ((.advFields) ((.advance) handle))
        ++ concatMap dispatchBindings ((.dispatch) handle)
        ++ concatMap (bindingName "timer payload field binding" ((.loc) timer)) ((.payload) timer)
        ++ concatMap (bindingName "timer fire field binding" ((.loc) timer)) ((.fields) ((.fire) timer))
      where
        input = (.input) process
        handle = (.handle) process
        timer = (.timer) process
        dispatchBindings dispatch = concatMap (bindingName "dispatch field binding" ((.loc) dispatch)) ((.fields) dispatch)

    routerNames router =
      constructorName "router name" ((.id) router) ((.loc) router)
        ++ constructorName "router input name" ((.name) input) ((.loc) router)
        ++ concatMap (\field -> fieldNameRule "router input field" ((.name) field) ((.loc) router)) ((.fields) input)
        ++ concatMap (\field -> fieldNameRule "router resolve-row field" field ((.loc) resolve)) ((.row) resolve)
        ++ concatMap (bindingName "router dispatch field binding" ((.loc) dispatch)) ((.fields) dispatch)
      where
        input = (.input) router
        resolve = (.resolve) router
        dispatch = (.dispatch) router

    bindingName category anchor binding = fieldNameRule category ((.name) binding) anchor
    contractFieldName = contractFieldNameRule "contract field"

    aggregateFieldNameRule category field =
      case (.selector) field of
        Nothing -> fieldNameRule category ((.name) field) ((.loc) field)
        Just selector -> explicitFieldSelectorRule category ((.name) field) selector ((.loc) field)

    contractFieldNameRule category field =
      case (.selector) field of
        Nothing -> fieldNameRule category ((.name) field) ((.loc) field)
        Just selector -> explicitFieldSelectorRule category ((.name) field) selector ((.loc) field)

    explicitFieldSelectorRule category dslName selector anchor =
      case HaskellName.checkedLowerOccurrence site selector of
        Right _ -> []
        Left nameError -> [nameErrorDiagnostic (category <> " selector") nameError]
      where
        site =
          HaskellName.NameSite
            { HaskellName.kind = HaskellName.GeneratedFieldSite,
              HaskellName.logicalName = selector,
              HaskellName.owner = category <> ":" <> dslName,
              HaskellName.line = locLine anchor
            }

    constructorName category name anchor = checkedLogicalName HaskellName.GeneratedTypeSite category name anchor

    workflowNames workflow =
      constructorName "workflow name" ((.id) workflow) (workflowNodeLoc workflow)
        <> concat
          [ case HaskellName.deriveLowerHelperName HaskellName.LogicalWireWord "Await" site of
              Right _ -> []
              Left nameError -> [nameErrorDiagnostic "workflow await binding" nameError]
          | (label, loc) <- workflowAwaits ((.body) workflow),
            let site = workflowAwaitBindingSite workflow label loc
          ]

    pascalizedNodeName category name anchor = checkedLogicalName HaskellName.NodeModuleSite (category <> " name") name anchor

    fieldNameRule category name anchor = checkedLogicalName HaskellName.GeneratedFieldSite category name anchor

    checkedLogicalName kind category name anchor =
      case deriveAt HaskellName.LogicalIdentifier kind category name anchor of
        Right _ -> []
        Left nameError -> [nameErrorDiagnostic category nameError]

    deriveAt source kind category name anchor =
      HaskellName.deriveHaskellName source (nameSite kind category name anchor)

    nameSite kind category name anchor =
      HaskellName.NameSite
        { HaskellName.kind = kind,
          HaskellName.logicalName = name,
          HaskellName.owner = category <> ":" <> name,
          HaskellName.line = locLine anchor
        }

    nameErrorDiagnostic category = \case
      HaskellName.EmptyNameSegment site ->
        mkErr ((.line) site) IdentUnsafeNormalization $
          category <> " '" <> (.logicalName) site <> "' has an empty generated-Haskell word"
      HaskellName.UnsafeNameSeparator site reason ->
        mkErr ((.line) site) IdentUnsafeNormalization $
          category <> " '" <> (.logicalName) site <> "' cannot be normalized safely: " <> reason
      HaskellName.ReservedGeneratedOccurrence site occurrence ->
        mkErr ((.line) site) GeneratedOccurrenceReserved $
          category <> " '" <> (.logicalName) site <> "' normalizes to reserved Haskell occurrence '" <> occurrence <> "'"
      HaskellName.InvalidExplicitHaskellName site occurrence ->
        mkErr ((.line) site) IdentUnsafeNormalization $
          category <> " '" <> (.logicalName) site <> "' cannot become generated Haskell occurrence '" <> occurrence <> "'"
      collision@HaskellName.NormalizedNameCollision {} -> collisionDiagnostic collision

    normalizedCollisions = map collisionDiagnostic (HaskellName.detectNameCollisions collisionOccurrences)

    collisionOccurrences =
      nodeModuleOccurrences
        <> sharedTypeOccurrences
        <> concatMap aggregateFieldOccurrences aggregates
        <> concatMap aggregateHarnessOccurrences aggregates
        <> concatMap contractFieldOccurrences contracts
        <> concatMap workflowRuntimeOccurrences workflows

    aggregates = [aggregate | NAggregate aggregate <- (.nodes) spec]
    contracts = [contract | NContract contract <- (.nodes) spec]
    workflows = [workflow | NWorkflow workflow <- (.nodes) spec]

    contextSegment =
      case deriveAt HaskellName.LogicalWireWord HaskellName.ContextModuleSite "context" ((.context) spec) (Loc 1) of
        Right derived -> HaskellName.renderUpperCamelName ((.upperCamel) derived)
        Left _ -> (.context) spec

    nodeModuleOccurrences =
      [ HaskellName.plannedOccurrence contextSegment HaskellName.ModuleSpace "" rendered site
      | node <- (.nodes) spec,
        let (category, raw, anchor) = nodeNameAndLoc node,
        let site = nameSite HaskellName.NodeModuleSite category raw anchor,
        Right derived <- [HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site],
        let rendered = HaskellName.renderUpperCamelName ((.upperCamel) derived)
      ]

    sharedTypeOccurrences =
      [ HaskellName.plannedOccurrence ("Generated." <> contextSegment <> ".Nominals") HaskellName.TypeSpace "" rendered site
      | (category, raw, anchor) <-
          [("id", (.name) declaration, (.loc) declaration) | declaration <- (.ids) spec]
            <> [("enum", (.name) declaration, (.loc) declaration) | declaration <- (.enums) spec]
            <> [("nominal", (.name) declaration, (.loc) declaration) | declaration <- (.nominalScalars) spec],
        let site = nameSite HaskellName.GeneratedTypeSite category raw anchor,
        Right derived <- [HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site],
        let rendered = HaskellName.renderUpperCamelName ((.upperCamel) derived)
      ]

    aggregateFieldOccurrences aggregate = commandFields <> eventFields
      where
        targetModule = "Generated." <> contextSegment <> "." <> normalizedUpper "aggregate" ((.name) aggregate) ((.loc) aggregate) <> ".Domain"
        commandFields =
          [ fieldOccurrence targetModule ((.name) command) "command field" field
          | command <- (.commands) aggregate,
            field <- (.fields) command
          ]
        eventFields =
          [ fieldOccurrence targetModule ((.name) event) "event field" field
          | event <- (.events) aggregate,
            field <- eventFieldsFor aggregate event
          ]

    eventFieldsFor aggregate event =
      case (.body) event of
        EventFields fields -> fields
        EventFromCommand commandName ->
          [ field
          | command <- (.commands) aggregate,
            (.name) command == commandName,
            field <- (.fields) command
          ]

    -- The occurrence registered here must be the selector generation actually
    -- emits — 'resolveAggregateFieldIdentity', which falls back to the raw DSL
    -- name, not a camelized rendering of it. Registering the camelized form made
    -- the planner claim `foo_bar` "normalizes to" `fooBar`, which generation
    -- never does, and let two fields that generate distinct selectors be
    -- reported as colliding. A field whose raw name is not lowerCamelCase is
    -- still refused, by the generated-name audit that owns that rule and says so.
    fieldOccurrence targetModule scope category field =
      let identity = resolveAggregateFieldIdentity field
          site = nameSite HaskellName.GeneratedFieldSite category ((.dslName) identity) ((.loc) field)
       in HaskellName.plannedOccurrence targetModule HaskellName.FieldSpace scope ((.selector) identity) site

    aggregateHarnessOccurrences aggregate =
      transitionHelpers <> sampleConstants
      where
        transitionHelpers =
          concat
            [ [helperOccurrence "accept" ("accept" <> commandName) transition]
                <> [helperOccurrence "forward/replay" ("forwardReplay" <> commandName) transition | not (null ((.emits) transition))]
            | transition <- (.transitions) aggregate,
              (.source) transition == initialState,
              (.mode) transition == TmLive,
              let commandName = (.command) transition
            ]
        sampleConstants = map idSampleOccurrence generatedIds <> maybe [] (pure . timeSampleOccurrence) timeSample
        resolvedHarnessFields =
          [ (field, resolvedType)
          | (useSite, field) <- harnessFields aggregate,
            Right resolvedType <- [inferAggregateFieldType symbols aggregate useSite field]
          ]
        generatedIds =
          Map.elems . Map.fromList $
            [ ((.name) nominal, nominal)
            | (_, AggregateNominal nominal) <- resolvedHarnessFields,
              Nominal.GeneratedNominal <- [(.ownership) nominal],
              Nominal.IdRepresentation prefix <- [(.representation) nominal],
              idDomainContractFor languageContract prefix /= Nothing
            ]
        timeFields = [field | (field, AggregateTime) <- resolvedHarnessFields]
        timeSample = case filter ((== "observedAt") . (.name)) timeFields of
          field : _ -> Just ("sampleObservedAt", field)
          [] -> case timeFields of
            field : _ -> Just ("sampleTime", field)
            [] -> Nothing
        initialState = case (.states) aggregate of
          state : _ -> (.name) state
          [] -> ""
        symbols = aggregateSymbolsFromGraphResult typeGraphResult spec
        targetModule =
          "Generated."
            <> contextSegment
            <> "."
            <> normalizedUpper "aggregate" ((.name) aggregate) ((.loc) aggregate)
            <> ".Harness"
        helperOccurrence helperKind rendered transition =
          HaskellName.plannedOccurrence targetModule HaskellName.ValueSpace "" rendered site
          where
            site =
              HaskellName.NameSite
                { HaskellName.kind = HaskellName.GeneratedHelperSite,
                  HaskellName.logicalName = (.command) transition,
                  HaskellName.owner = "aggregate:" <> (.name) aggregate <> ":" <> helperKind <> ":line:" <> T.pack (show (locLine ((.loc) transition))),
                  HaskellName.line = locLine ((.loc) transition)
                }
        idSampleOccurrence nominal =
          HaskellName.plannedOccurrence targetModule HaskellName.ValueSpace "" ("sample" <> nominalName) site
          where
            nominalName = (.name) nominal
            loc = (.loc) nominal
            site =
              HaskellName.NameSite
                { HaskellName.kind = HaskellName.GeneratedHelperSite,
                  HaskellName.logicalName = nominalName,
                  HaskellName.owner = "aggregate:" <> (.name) aggregate <> ":sample-id:" <> nominalName,
                  HaskellName.line = locLine loc
                }
        timeSampleOccurrence (rendered, field) =
          HaskellName.plannedOccurrence targetModule HaskellName.ValueSpace "" rendered site
          where
            site =
              HaskellName.NameSite
                { HaskellName.kind = HaskellName.GeneratedHelperSite,
                  HaskellName.logicalName = (.name) field,
                  HaskellName.owner = "aggregate:" <> (.name) aggregate <> ":sample-time",
                  HaskellName.line = locLine ((.loc) field)
                }

    workflowRuntimeOccurrences workflow =
      [ HaskellName.plannedOccurrence targetModule HaskellName.ValueSpace "" rendered site
      | (label, loc) <- workflowAwaits ((.body) workflow),
        let site = workflowAwaitBindingSite workflow label loc,
        Right awaitName <- [HaskellName.deriveLowerHelperName HaskellName.LogicalWireWord "Await" site],
        let rendered = HaskellName.renderLowerCamelName awaitName
      ]
      where
        targetModule =
          "Generated."
            <> contextSegment
            <> "."
            <> normalizedUpper "workflow" ((.id) workflow) (workflowNodeLoc workflow)
            <> ".WorkflowRuntime"

    workflowAwaitBindingSite workflow label loc =
      HaskellName.NameSite
        { HaskellName.kind = HaskellName.GeneratedValueSite,
          HaskellName.logicalName = label,
          HaskellName.owner = "workflow:" <> (.id) workflow <> ":await:" <> label,
          HaskellName.line = locLine loc
        }

    workflowAwaits = concatMap go
      where
        go (WfAwait label _ loc) = [(label, loc)]
        go (WfPatch _ items _) = workflowAwaits items
        go _ = []

    harnessFields aggregate =
      [(CommandFieldUse, field) | command <- (.commands) aggregate, field <- (.fields) command]
        <> [ (EventFieldUse, field)
           | event <- (.events) aggregate,
             field <- eventFieldsFor aggregate event
           ]

    contractFieldOccurrences contract =
      [ contractFieldOccurrence targetModule ((.name) event <> "Data") field
      | event <- (.events) contract,
        field <- (.fields) event
      ]
      where
        targetModule =
          "Generated."
            <> contextSegment
            <> "."
            <> normalizedUpper "contract" ((.name) contract) ((.loc) contract)
            <> ".Contract"

    contractFieldOccurrence targetModule scope field =
      let identity = resolveContractFieldIdentity field
          site = nameSite HaskellName.GeneratedFieldSite "contract field" ((.dslName) identity) ((.loc) identity)
          rendered = case (.selector) field of
            Just selector -> selector
            Nothing -> case HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site of
              Right derived -> HaskellName.renderLowerCamelName ((.lowerCamel) derived)
              Left _ -> (.selector) identity
       in HaskellName.plannedOccurrence targetModule HaskellName.FieldSpace scope rendered site

    normalizedUpper category raw anchor =
      case deriveAt HaskellName.LogicalIdentifier HaskellName.GeneratedTypeSite category raw anchor of
        Right derived -> HaskellName.renderUpperCamelName ((.upperCamel) derived)
        Left _ -> raw

    nodeNameAndLoc = \case
      NAggregate value -> ("aggregate", (.name) value, (.loc) value)
      NProcess value -> ("process", (.id) value, (.loc) value)
      NRouter value -> ("router", (.id) value, (.loc) value)
      NContract value -> ("contract", (.name) value, (.loc) value)
      NIntake value -> ("intake", (.name) value, (.loc) value)
      NEmit value -> ("emit", (.name) value, (.loc) value)
      NPublisher value -> ("publisher", (.name) value, (.loc) value)
      NWorkqueue value -> ("workqueue", (.name) value, (.loc) value)
      NPgmqDispatch value -> ("dispatch", (.name) value, (.loc) value)
      NReadModel value -> ("readmodel", (.name) value, (.loc) value)
      NProjectionTarget value -> ("target", (.name) value, (.loc) value)
      NRebuildGroup value -> ("rebuild-group", (.name) value, (.loc) value)
      NProjectionRevision value -> ("projection-revision", (.name) value, (.loc) value)
      NExternalRead value -> ("external-read", externalReadNodeIdentity value, (.loc) value)
      NProjectionOwner value -> ("projection-owner", (.name) value, (.loc) value)
      NWorkflow value -> ("workflow", (.id) value, workflowNodeLoc value)
      NOperation value -> ("operation", (.name) value, (.loc) value)

    collisionDiagnostic (HaskellName.NormalizedNameCollision key sites) =
      case reverse (NE.toList sites) of
        primary : reversedEarlier ->
          Diagnostic
            { line = (.line) primary,
              severity = Error,
              code = GeneratedOccurrenceCollision,
              relatedLocations =
                [ ((.line) site, "'" <> (.logicalName) site <> "' also normalizes here")
                | site <- reverse reversedEarlier
                ],
              message =
                "logical declarations "
                  <> T.intercalate ", " ["'" <> (.logicalName) site <> "'" | site <- NE.toList sites]
                  <> " normalize to the same Haskell occurrence '"
                  <> (.name) key
                  <> "' in "
                  <> (.moduleName) key
                  <> " ("
                  <> T.pack (show ((.space) key))
                  <> ")"
            }
        [] -> mkErr 1 GeneratedOccurrenceCollision "internal error: normalized collision without source sites"
    collisionDiagnostic nameError = nameErrorDiagnostic "generated declaration" nameError

    vertexCollisions aggregate =
      [ mkErr (locLine ((.loc) aggregate)) VertexCtorCollision $
          "aggregate '"
            <> (.name) aggregate
            <> "' state '"
            <> (.name) state
            <> "' generates vertex constructor '"
            <> vertex
            <> "', which collides with "
            <> declarationKind
            <> " '"
            <> vertex
            <> "' in the generated Domain constructor namespace"
      | state <- (.states) aggregate,
        let vertex = normalizedUpper "aggregate" ((.name) aggregate) ((.loc) aggregate) <> normalizedUpper "state" ((.name) state) ((.loc) state),
        declarationKind <- collisionKinds aggregate vertex
      ]

    collisionKinds aggregate vertex =
      ["event" | vertex `elem` [normalizedUpper "event" ((.name) event) ((.loc) event) | event <- (.events) aggregate]]
        ++ ["command" | vertex `elem` [normalizedUpper "command" ((.name) command) ((.loc) command) | command <- (.commands) aggregate]]
        ++ ["enum constructor" | vertex `elem` [normalizedUpper "enum constructor" ctor ((.loc) enum) | enum <- (.enums) spec, (ctor, _) <- (.ctors) enum]]

-- Explicit consumer-owned Haskell references keep their spelling and use the
-- historical lexical check. Generated names never call this helper.
constructorSafe :: Name -> Bool
constructorSafe name = case T.uncons name of
  Just (first, rest) -> asciiUpper first && T.all asciiAlphaNumOrUnderscore rest
  Nothing -> False

asciiUpper :: Char -> Bool
asciiUpper c = c >= 'A' && c <= 'Z'

asciiLower :: Char -> Bool
asciiLower c = c >= 'a' && c <= 'z'

asciiAlphaNumOrUnderscore :: Char -> Bool
asciiAlphaNumOrUnderscore c = asciiUpper c || asciiLower c || (c >= '0' && c <= '9') || c == '_'

kafkaTopicError :: Text -> Maybe Text
kafkaTopicError topic
  | T.null topic = Just "is empty"
  | T.length topic > 249 = Just "is longer than Kafka's 249-character limit"
  | topic == "." || topic == ".." = Just "is reserved by Kafka"
  | Just illegal <- T.find (not . kafkaTopicCharacter) topic =
      Just ("contains character " <> T.pack (show illegal) <> "; use only ASCII letters, digits, '.', '_', or '-'")
  | otherwise = Nothing
  where
    kafkaTopicCharacter character = asciiAlphaNumOrUnderscore character || character == '.' || character == '-'

validPostgresIdentifier :: Text -> Bool
validPostgresIdentifier identifier =
  T.length identifier <= 63
    && case T.uncons identifier of
      Nothing -> False
      Just (firstCharacter, rest) ->
        (asciiLower firstCharacter || firstCharacter == '_')
          && T.all (\character -> asciiLower character || (character >= '0' && character <= '9') || character == '_') rest

-- | Rules over namespaces shared by the whole specification.
specLevelRules :: EffectiveLanguageContract -> ProjectionSupplyAnalysis -> Spec -> [Diagnostic]
specLevelRules languageContract supplyAnalysis spec = duplicateNodes ++ duplicateEnumMembers ++ duplicateIdPrefixes ++ duplicateDeclarations ++ runtimeIdentities ++ duplicateRuntimeIdentities ++ catalogRules ++ ruleDiagnostics
  where
    duplicateNodes =
      [ mkErr (locLine loc) DuplicateNodeName $
          "duplicate " <> kind <> " node name '" <> name <> "'"
      | node <- duplicatesBy nodeKey ((.nodes) spec),
        let (kind, name, loc) = nodeIdentity node
      ]
    nodeKey node = let (kind, name, _) = nodeIdentity node in (kind, name)
    duplicateEnumMembers = concatMap enumDuplicates ((.enums) spec)
    enumDuplicates e =
      [ mkErr (locLine ((.loc) e)) DuplicateEnumCtor $
          "enum '" <> (.name) e <> "' declares constructor '" <> ctor <> "' more than once"
      | (ctor, _) <- duplicatesBy fst ((.ctors) e)
      ]
        ++ [ mkErr (locLine ((.loc) e)) DuplicateEnumWire $
               "enum '" <> (.name) e <> "' declares wire spelling '" <> wire <> "' more than once"
           | (_, wire) <- duplicatesBy snd ((.ctors) e)
           ]
    duplicateIdPrefixes =
      [ mkErr (locLine ((.loc) d)) DuplicateIdPrefix $
          "id '" <> (.name) d <> "' reuses prefix '" <> (.prefix) d <> "'"
      | d <- duplicatesBy (.prefix) ((.ids) spec)
      ]
    duplicateDeclarations =
      [ mkErr (locLine loc) NominalDuplicateDeclaration $
          "duplicate " <> category <> " declaration '" <> name <> "'; the last declaration would silently replace the earlier one"
      | enforcesSpecSurfaceClosures languageContract,
        (category, name, loc) <- duplicatesBy (\(category, name, _) -> (category, name)) declarationOrigins
      ]
    declarationOrigins =
      [("id", (.name) value, (.loc) value) | value <- (.ids) spec]
        <> [("enum", (.name) value, (.loc) value) | value <- (.enums) spec]
        <> [("nominal scalar", (.name) value, (.loc) value) | value <- (.nominalScalars) spec]
        <> [("mapped", mappedName value, mappedLoc value) | value <- (.mapped) spec]
        <> [("rule", (.name) value, (.loc) value) | value <- (.rules) spec]
    runtimeIdentities =
      [ mkErr (locLine loc) RuntimeIdentityInvalid $
          kind <> " stable identity " <> T.pack (show identity) <> " " <> reason
      | enforcesSpecSurfaceClosures languageContract,
        (kind, identity, loc) <- stableIdentityOrigins,
        Just reason <- [stableIdentityError identity]
      ]
    duplicateRuntimeIdentities =
      [ mkErr (locLine loc) RuntimeIdentityDuplicate $
          kind <> " stable identity " <> T.pack (show identity) <> " is already used by another workflow, process, or router"
      | enforcesSpecSurfaceClosures languageContract,
        (kind, identity, loc) <- duplicatesBy (\(_, identity, _) -> identity) stableIdentityOrigins
      ]
    stableIdentityOrigins =
      [("workflow", (.stable) workflow, workflowNodeLoc workflow) | NWorkflow workflow <- (.nodes) spec]
        <> [("process", (.name) process, (.loc) process) | NProcess process <- (.nodes) spec]
        <> [("router", (.name) router, (.loc) router) | NRouter router <- (.nodes) spec]
    catalogRules
      | hasProjectionCatalog languageContract = validateProjectionCatalogFleet supplyAnalysis spec
      | otherwise = []
    ruleDiagnostics = concatMap (validateRule spec) ((.rules) spec)

nodeIdentity :: Node -> (Text, Name, Loc)
nodeIdentity (NAggregate a) = ("aggregate", (.name) a, (.loc) a)
nodeIdentity (NProcess p) = ("process", (.id) p, (.loc) p)
nodeIdentity (NRouter r) = ("router", (.id) r, (.loc) r)
nodeIdentity (NContract c) = ("contract", (.name) c, (.loc) c)
nodeIdentity (NIntake i) = ("intake", (.name) i, (.loc) i)
nodeIdentity (NEmit e) = ("emit", (.name) e, (.loc) e)
nodeIdentity (NPublisher p) = ("publisher", (.name) p, (.loc) p)
nodeIdentity (NWorkqueue w) = ("workqueue", (.name) w, (.loc) w)
nodeIdentity (NPgmqDispatch d) = ("dispatch", (.name) d, (.loc) d)
nodeIdentity (NReadModel r) = ("readmodel", (.name) r, (.loc) r)
nodeIdentity (NProjectionTarget target) = ("target", (.name) target, (.loc) target)
nodeIdentity (NRebuildGroup groupNode) = ("rebuild-group", (.name) groupNode, (.loc) groupNode)
nodeIdentity (NProjectionRevision revision) = ("projection-revision", (.name) revision, (.loc) revision)
nodeIdentity (NExternalRead externalRead) = ("external-read", externalReadNodeIdentity externalRead, (.loc) externalRead)
nodeIdentity (NProjectionOwner owner) = ("projection-owner", (.name) owner, (.loc) owner)
nodeIdentity (NWorkflow w) = ("workflow", (.id) w, workflowNodeLoc w)
nodeIdentity (NOperation o) = ("operation", (.name) o, (.loc) o)

validateNode :: EffectiveLanguageContract -> Either (NE.NonEmpty TypeGraphError) TypeGraph -> ProjectionSupplyAnalysis -> Spec -> Node -> [Diagnostic]
validateNode languageContract typeGraphResult _supplyAnalysis spec (NAggregate agg) = validateAggregate languageContract typeGraphResult spec agg
validateNode languageContract _typeGraphResult _supplyAnalysis spec (NProcess p) = validateProcess languageContract spec p
validateNode languageContract typeGraphResult _supplyAnalysis spec (NRouter router) = validateRouter languageContract typeGraphResult spec router
validateNode languageContract _typeGraphResult _supplyAnalysis _spec (NContract contract) = validateContract languageContract contract
validateNode languageContract _typeGraphResult _supplyAnalysis spec (NIntake i) = validateIntake languageContract i ++ intakeCoupling languageContract spec i
validateNode languageContract _typeGraphResult _supplyAnalysis spec (NEmit e) = validateEmit languageContract spec e
validateNode languageContract _typeGraphResult _supplyAnalysis spec (NPublisher p) = validatePublisher languageContract spec p
validateNode languageContract _typeGraphResult _supplyAnalysis _spec (NWorkqueue w) = validateWorkqueue languageContract w
validateNode languageContract _typeGraphResult _supplyAnalysis spec (NPgmqDispatch d) = validatePgmqDispatch languageContract spec d
validateNode languageContract _typeGraphResult supplyAnalysis spec (NReadModel readModel) = validateReadModel languageContract supplyAnalysis spec readModel
validateNode languageContract _typeGraphResult _supplyAnalysis _spec (NProjectionTarget target) = validateProjectionTarget languageContract target
validateNode languageContract _typeGraphResult _supplyAnalysis spec (NRebuildGroup groupNode) = validateRebuildGroup languageContract spec groupNode
validateNode languageContract _typeGraphResult _supplyAnalysis spec (NProjectionRevision revision) = validateProjectionRevision languageContract spec revision
validateNode languageContract _typeGraphResult _supplyAnalysis spec (NExternalRead externalRead) = validateExternalRead languageContract spec externalRead
validateNode languageContract _typeGraphResult supplyAnalysis spec (NProjectionOwner owner) = validateProjectionOwner languageContract supplyAnalysis spec owner
validateNode _languageContract _typeGraphResult _supplyAnalysis _spec (NWorkflow w) = validateWorkflow w
validateNode _languageContract _typeGraphResult _supplyAnalysis spec (NOperation o) = validateOperation spec o

validateContract :: EffectiveLanguageContract -> ContractNode -> [Diagnostic]
validateContract languageContract contract =
  emptyContract
    <> typeIdPrefixErrors
    <> schemaVersionFloor
    <> topicNames
    <> duplicateEvents
    <> duplicateTopicAliases
    <> duplicateFields
    <> discriminatorShadows
    <> fieldWireKeyRules
    <> unresolvedTopicAliases
  where
    emptyContract =
      [ mkErr (locLine ((.loc) contract)) ContractEmpty $
          "contract '"
            <> (.name) contract
            <> "' declares no events; scaffold cannot lower an empty contract -- declare at least one event"
      | null ((.events) contract)
      ]
    typeIdPrefixErrors =
      [ mkErr (locLine ((.loc) field)) ContractInvalidTypeIdPrefix $
          "contract '"
            <> (.name) contract
            <> "' event '"
            <> (.name) event
            <> "' field '"
            <> (.name) field
            <> "' has invalid TypeID prefix '"
            <> prefix
            <> "': "
            <> T.pack (show reason)
      | event <- (.events) contract,
        field <- (.fields) event,
        CTypeId prefix <- [(.valueType) field],
        Just _ <- [contractIdDomainContractFor languageContract prefix],
        Just reason <- [TypeID.checkPrefix prefix]
      ]
    schemaVersionFloor =
      [ mkErr (locLine ((.loc) contract)) ContractSchemaVersionBelowMinimum $
          "contract '" <> (.name) contract <> "' schemaVersion must be at least 1"
      | enforcesSpecSurfaceClosures languageContract,
        (.schemaVersion) contract < 1
      ]
    topicNames =
      [ mkErr (locLine ((.loc) contract)) ContractTopicNameInvalid $
          "contract '" <> (.name) contract <> "' topic alias '" <> alias <> "' has invalid Kafka topic " <> T.pack (show topic) <> ": " <> reason
      | (alias, topic) <- (.topics) contract,
        T.null topic || enforcesSpecSurfaceClosures languageContract,
        Just reason <- [kafkaTopicError topic]
      ]
    duplicateEvents =
      [ mkErr (locLine ((.loc) contract)) ContractDuplicateEvent $
          "contract '" <> (.name) contract <> "' declares event '" <> (.name) event <> "' more than once"
      | event <- duplicatesBy (.name) ((.events) contract)
      ]
    duplicateTopicAliases =
      [ mkErr (locLine ((.loc) contract)) ContractDuplicateTopicAlias $
          "contract '" <> (.name) contract <> "' declares topic alias '" <> alias <> "' more than once"
      | (alias, _) <- duplicatesBy fst ((.topics) contract)
      ]
    duplicateFields =
      [ mkErr (locLine ((.loc) field)) ContractDuplicateFieldName $
          "contract '" <> (.name) contract <> "' event '" <> (.name) event <> "' declares field '" <> (.name) field <> "' more than once"
      | event <- (.events) contract,
        field <- duplicatesBy (.name) ((.fields) event)
      ]
    discriminatorShadows =
      [ mkErr (locLine ((.loc) field)) ContractFieldShadowsDiscriminator $
          "contract '"
            <> (.name) contract
            <> "' event '"
            <> (.name) event
            <> "' field '"
            <> (.name) field
            <> "' shadows the payload discriminator"
      | enforcesSpecSurfaceClosures languageContract,
        event <- (.events) contract,
        field <- (.fields) event,
        (.wireKey) (resolveContractFieldIdentity field) == (.discriminator) contract
      ]
    fieldWireKeyRules =
      concat
        [ wireKeyRulesForRecord
            ("contract '" <> (.name) contract <> "' event '" <> (.name) event <> "'")
            (Just ((.discriminator) contract, "payload discriminator"))
            (map resolveContractFieldIdentity ((.fields) event))
        | event <- (.events) contract
        ]
    unresolvedTopicAliases =
      [ mkErr (locLine ((.loc) contract)) ContractTopicAliasUnresolved $
          "contract '" <> (.name) contract <> "' event '" <> (.name) event <> "' names undeclared topic alias '" <> (.topic) event <> "'"
      | enforcesSpecSurfaceClosures languageContract,
        event <- (.events) contract,
        (.topic) event `notElem` map fst ((.topics) contract)
      ]

-- | Workflow replay keys, patch guards, rotation, and injected inputs must be unambiguous.
validateWorkflow :: WorkflowNode -> [Diagnostic]
validateWorkflow w = duplicateLabels ++ sleepFields ++ patchDuplicates ++ patchIds ++ continuePositions ++ idField
  where
    inputFields = map (.name) ((.inputFields) w)
    labelledItems = workflowLabelledItems ((.body) w)
    patchItems = workflowPatchItems ((.body) w)
    duplicateLabels =
      [ mkErr (locLine (wfBodyLoc item)) WorkflowDuplicateLabel $
          "workflow '" <> (.id) w <> "' declares label '" <> label <> "' more than once; labels key deterministic replay, so a duplicate label replays the first occurrence's journaled result"
      | (label, item) <- duplicatesBy fst labelledItems
      ]
    sleepFields =
      [ mkErr (locLine loc) WorkflowSleepDelayUnresolved $
          "workflow '" <> (.id) w <> "' sleep '" <> label <> "' references undeclared input field '" <> delay <> "'"
      | WfSleep label delay loc <- map snd labelledItems,
        delay `notElem` inputFields
      ]
    patchDuplicates =
      [ mkErr (locLine loc) WorkflowPatchDuplicate $
          "workflow '" <> (.id) w <> "' declares patch id '" <> patchId <> "' more than once; patch decisions journal under one stable key"
      | (patchId, _, loc) <- duplicatesBy (\(patchId, _, _) -> patchId) patchItems
      ]
    patchIds =
      [ mkErr (locLine loc) WorkflowPatchIdInvalid $
          "workflow '" <> (.id) w <> "' patch id '" <> patchId <> "' contains ':'; the runtime reserves that separator for the patch journal-key prefix"
      | (patchId, _, loc) <- patchItems,
        ":" `T.isInfixOf` patchId
      ]
    continuePositions =
      [ mkErr (locLine loc) WorkflowContinueAsNewNotTerminal $
          "workflow '" <> (.id) w <> "' continueAsNew must be the last top-level body item and may not appear inside a patch"
      | (isTopLevelTerminal, loc) <- workflowContinueItems ((.body) w),
        not isTopLevelTerminal
      ]
    idField = case (.idField) w of
      Just field
        | field `notElem` inputFields ->
            [ mkErr (locLine (workflowNodeLoc w)) WorkflowIdFieldUnresolved $
                "workflow '" <> (.id) w <> "' derives its id from undeclared input field '" <> field <> "'"
            ]
      _ -> []

wfBodyLoc :: WfBodyItem -> Loc
wfBodyLoc (WfStep _ _ loc) = loc
wfBodyLoc (WfAwait _ _ loc) = loc
wfBodyLoc (WfSleep _ _ loc) = loc
wfBodyLoc (WfChild _ _ _ loc) = loc
wfBodyLoc (WfPatch _ _ loc) = loc
wfBodyLoc (WfContinueAsNew _ loc) = loc

workflowLabelledItems :: [WfBodyItem] -> [(Name, WfBodyItem)]
workflowLabelledItems = concatMap go
  where
    go item@(WfStep label _ _) = [(label, item)]
    go item@(WfAwait label _ _) = [(label, item)]
    go item@(WfSleep label _ _) = [(label, item)]
    go item@(WfChild label _ _ _) = [(label, item)]
    go (WfPatch _ items _) = workflowLabelledItems items
    go WfContinueAsNew {} = []

workflowPatchItems :: [WfBodyItem] -> [(Name, [WfBodyItem], Loc)]
workflowPatchItems = concatMap go
  where
    go (WfPatch patchId items loc) = (patchId, items, loc) : workflowPatchItems items
    go _ = []

-- | Pair every rotation with whether it is the final top-level item.
workflowContinueItems :: [WfBodyItem] -> [(Bool, Loc)]
workflowContinueItems items = topLevel ++ nested
  where
    topLevel =
      [ (index == length items - 1, loc)
      | (index, WfContinueAsNew _ loc) <- zip [0 ..] items
      ]
    nested =
      [ (False, loc)
      | WfPatch _ patchBody _ <- items,
        (_, loc) <- workflowContinueItems patchBody
      ]

-- | A top-level rule is a total, clock-free function over one declared enum.
validateRule :: Spec -> RuleDecl -> [Diagnostic]
validateRule spec rule = case [e | e <- (.enums) spec, (.name) e == (.domain) rule] of
  [] ->
    [ mkErr rl RuleDomainUnresolved $
        "rule '" <> (.name) rule <> "' has undeclared enum domain '" <> (.domain) rule <> "'"
    ]
  (domain : _) -> totality domain ++ unknownCases domain ++ bodyDiagnostics
  where
    rl = locLine ((.loc) rule)
    caseNames = map fst ((.cases) rule)
    allEnumCtors = Set.fromList [ctor | e <- (.enums) spec, (ctor, _) <- (.ctors) e]
    totality domain =
      let missing = [ctor | (ctor, _) <- (.ctors) domain, ctor `notElem` caseNames]
       in [ mkErr rl RuleNotTotal $
              "rule '" <> (.name) rule <> "' is not total over enum '" <> (.name) domain <> "'; missing cases {" <> T.intercalate ", " missing <> "}"
          | not (null missing)
          ]
    unknownCases domain =
      [ mkErr rl RuleCaseUnknownCtor $
          "rule '" <> (.name) rule <> "' has case '" <> ctor <> "' which is not a constructor of enum '" <> (.name) domain <> "'"
      | (ctor, _) <- (.cases) rule,
        ctor `notElem` map fst ((.ctors) domain)
      ]
    bodyDiagnostics = concatMap validateBody ((.cases) rule)
    validateBody (ctor, expr) =
      [ mkErr rl ClockSampled $
          "rule '" <> (.name) rule <> "' case '" <> ctor <> "' samples the wall clock via '" <> atom <> "'; rules must be deterministic"
      | atom <- dedup (exprNames expr),
        atom `Set.member` clockAtoms
      ]
        ++ [ mkErr rl GuardAtomOutOfScope $
               "atom '" <> atom <> "' in rule '" <> (.name) rule <> "' resolves to no enum constructor or boolean literal"
           | atom <- dedup (exprNames expr),
             atom `Set.notMember` clockAtoms,
             atom `Set.notMember` allEnumCtors
           ]

-- | Operation rules resolve command aggregates, stream fields, projections,
-- read models, workflow signal labels and value types, and run targets.
validateOperation :: Spec -> OperationNode -> [Diagnostic]
validateOperation spec o = case (.shape) o of
  CommandOp aggregate streamField _ projections ->
    aggregateRef aggregate streamField ++ projectionRefs projections
  QueryOp readModel _ _ consistency ->
    resolveReadModelRef QueryUnresolvedReadModel spec ((.loc) o) ("query operation '" <> (.name) o <> "'") readModel
      ++ [ mkErr ol QueryConsistencyInvalid $
             "query operation '" <> (.name) o <> "' has unknown consistency '" <> consistency <> "'; expected Strong, Eventual, or PositionWait"
         | consistency `notElem` (["Strong", "Eventual", "PositionWait"] :: [Name])
         ]
  SignalOp lbl wf _ _ valueType ->
    case lookupWorkflow wf of
      Nothing ->
        [mkErr ol AwaitSignalMismatch ("signal operation '" <> (.name) o <> "' targets undeclared workflow '" <> wf <> "'")]
      Just w -> case [(resultType, loc) | (_, WfAwait label resultType loc) <- workflowLabelledItems ((.body) w), label == lbl] of
        [] ->
          [ mkErr ol AwaitSignalMismatch $
              "signal '" <> lbl <> "' of " <> wf <> " has no matching 'await' (workflow declares awaits {" <> T.intercalate ", " (awaitLabels w) <> "}); the deterministic awakeable id will not match and the workflow will wait forever"
          ]
        ((resultType, _) : _)
          | valueType == resultType -> []
          | otherwise ->
              [ mkErr ol AwaitSignalValueMismatch $
                  "signal '" <> lbl <> "' of " <> wf <> " carries value type '" <> valueType <> "' but the await expects '" <> resultType <> "'"
              ]
  RunOp wf _ _ ->
    [ mkErr ol RunWorkflowUnresolved ("run operation '" <> (.name) o <> "' targets undeclared workflow '" <> wf <> "'")
    | wf `notElem` map (.id) workflows
    ]
  where
    ol = locLine ((.loc) o)
    workflows = [w | NWorkflow w <- (.nodes) spec]
    aggregates = [a | NAggregate a <- (.nodes) spec]
    projectionTables = [(.table) p | a <- aggregates, Just p <- [(.projection) a]]
    lookupWorkflow n = case [w | w <- workflows, (.id) w == n] of (w : _) -> Just w; [] -> Nothing
    awaitLabels w = [l | (_, WfAwait l _ _) <- workflowLabelledItems ((.body) w)]
    aggregateRef name streamField = case [a | a <- aggregates, (.name) a == name] of
      [] ->
        [ mkErr ol OperationUnresolvedRef $
            "command operation '" <> (.name) o <> "' targets undeclared aggregate '" <> name <> "'"
        ]
      (aggregate : _) ->
        [ mkErr ol OperationUnresolvedRef $
            "command operation '" <> (.name) o <> "' stream field '" <> streamField <> "' is not declared by any command of aggregate '" <> name <> "'"
        | streamField `notElem` [(.name) field | command <- (.commands) aggregate, field <- (.fields) command]
        ]
    projectionRefs projections =
      [ mkErr ol OperationUnresolvedRef $
          "command operation '" <> (.name) o <> "' references undeclared projection table '" <> projection <> "'"
      | projection <- projections,
        projection `notElem` projectionTables
      ]

-- | Resolve a named read-model node using the caller's diagnostic code.
resolveReadModelRef :: DiagnosticCode -> Spec -> Loc -> Text -> Name -> [Diagnostic]
resolveReadModelRef diagnosticCode spec diagnosticLoc context name =
  [ mkErr (locLine diagnosticLoc) diagnosticCode $
      context <> " references undeclared readmodel '" <> name <> "'"
  | name `notElem` [(.name) readModel | NReadModel readModel <- (.nodes) spec]
  ]

validateProjectionCatalogFleet :: ProjectionSupplyAnalysis -> Spec -> [Diagnostic]
validateProjectionCatalogFleet supplyAnalysis spec = physicalDuplicates <> groupOwnership <> projectionOwnership <> targetDependencies <> handlerOrders <> sourceOrdering <> supplyDiagnostics
  where
    targets = [target | NProjectionTarget target <- (.nodes) spec]
    groups = [groupNode | NRebuildGroup groupNode <- (.nodes) spec]
    owners = [owner | NProjectionOwner owner <- (.nodes) spec]
    physicalDuplicates =
      [ mkErr (locLine ((.loc) target)) CatalogPhysicalTargetDuplicate $
          "target '" <> (.name) target <> "' reuses physical table " <> (.schema) target <> "." <> (.table) target
      | target <- duplicatesBy (\target -> ((.schema) target, (.table) target)) targets
      ]
    targetClaims = [(targetName, (.name) groupNode, (.loc) groupNode) | groupNode <- groups, targetName <- (.targets) groupNode]
    groupOwnership =
      [ mkErr (locLine ((.loc) target)) CatalogTargetUnowned $
          "target '" <> (.name) target <> "' is not owned by any rebuild group"
      | target <- targets,
        null [() | (targetName, _, _) <- targetClaims, targetName == (.name) target]
      ]
        <> [ mkErr (locLine claimLoc) CatalogTargetMultiplyOwned $
               "target '" <> targetName <> "' is owned by more than one rebuild group"
           | (targetName, _, claimLoc) <- duplicatesBy (\(targetName, _, _) -> targetName) targetClaims
           ]
    projectionClaims = [(targetName, (.name) owner, (.loc) owner) | owner <- owners, targetName <- (.targets) owner]
    projectionOwnership =
      [ mkErr (locLine ((.loc) target)) CatalogTargetUnowned $
          "target '" <> (.name) target <> "' has no projection owner"
      | target <- targets,
        null [() | (targetName, _, _) <- projectionClaims, targetName == (.name) target]
      ]
        <> [ mkErr (locLine claimLoc) CatalogTargetMultiplyOwned $
               "target '" <> targetName <> "' is claimed by more than one projection owner"
           | (targetName, _, claimLoc) <- duplicatesBy (\(targetName, _, _) -> targetName) projectionClaims
           ]
    groupForTarget = Map.fromList [(targetName, groupName) | (targetName, groupName, _) <- targetClaims]
    targetDependencies =
      [ mkErr (locLine ((.loc) target)) CatalogTargetDependencyUnknown $
          "target '" <> (.name) target <> "' depends on undeclared target '" <> dependency <> "'"
      | target <- targets,
        dependency <- (.dependsOn) target,
        dependency `notElem` map (.name) targets
      ]
        <> [ mkErr (locLine ((.loc) target)) CatalogTargetDependencyOutsideGroup $
               "target '" <> (.name) target <> "' depends on target '" <> dependency <> "' in another rebuild group"
           | target <- targets,
             dependency <- (.dependsOn) target,
             Just ownerGroup <- [Map.lookup ((.name) target) groupForTarget],
             Just dependencyGroup <- [Map.lookup dependency groupForTarget],
             ownerGroup /= dependencyGroup
           ]
        <> [ mkErr (locLine ((.loc) target)) CatalogTargetDependencyCycle $
               "target dependency cycle includes '" <> (.name) target <> "'"
           | CyclicSCC cycleTargets <- stronglyConnComp [(target, (.name) target, (.dependsOn) target) | target <- targets],
             target <- cycleTargets
           ]
    handlerOrders =
      [ mkErr (locLine ((.loc) owner)) CatalogDuplicateHandlerOrder $
          "projection owner '" <> (.name) owner <> "' reuses handler order " <> T.pack (show ((.order) owner)) <> " in group '" <> (.group) owner <> "'"
      | owner <- duplicatesBy (\owner -> ((.group) owner, (.order) owner)) owners
      ]
    sourceOrdering =
      [ Diagnostic
          { line = locLine ((.loc) groupNode),
            severity = Error,
            code = CatalogAmbiguousSourceOrdering,
            relatedLocations =
              [ (locLine ((.loc) owner), "projection owner '" <> (.name) owner <> "' contributes " <> sourceScopeText owner <> " events")
              | owner <- groupOwners
              ],
            message =
              "rebuild group '"
                <> (.name) groupNode
                <> "' cannot combine an all-stream source with category-scoped sources; split them into separate rebuild groups"
          }
      | groupNode <- groups,
        let groupOwners = sortOn (.name) [owner | owner <- owners, (.group) owner == (.name) groupNode],
        any ownerUsesAllStreams groupOwners,
        any ownerUsesCategoryScope groupOwners
      ]
    ownerUsesAllStreams owner = CatalogAll `elem` (.sources) owner
    ownerUsesCategoryScope owner = any isCategoryScope ((.sources) owner)
    isCategoryScope CatalogAll = False
    isCategoryScope CatalogCategory {} = True
    isCategoryScope CatalogAggregate {} = True
    sourceScopeText owner
      | ownerUsesAllStreams owner = "all-stream"
      | otherwise = "category-scoped"
    supplyDiagnostics = concatMap projectionSupplyIssueDiagnostics ((.projectionSupplyIssues) supplyAnalysis)

projectionSupplyIssueDiagnostics :: ProjectionSupplyIssue -> [Diagnostic]
projectionSupplyIssueDiagnostics = \case
  SupplyObservedTargetsEmpty readModel ->
    [ mkErr (locLine ((.loc) readModel)) CatalogReadModelBindingMissing $
        "readmodel '" <> (.name) readModel <> "' must observe at least one target in its projection catalog group"
    ]
  SupplyObservedTargetUnknown readModel targetName ->
    [ mkErr (locLine ((.loc) readModel)) CatalogTargetUnknown $
        "readmodel '" <> (.name) readModel <> "' observes undeclared target '" <> targetName <> "'"
    ]
  SupplyObservedTargetOutsideGroup readModel targetName ->
    [ mkErr (locLine ((.loc) readModel)) CatalogReadModelTargetOutsideGroup $
        "readmodel '" <> (.name) readModel <> "' observes target '" <> targetName <> "' outside its bound group"
    ]
  SupplyObservedTargetWithoutOwner _ _ -> []
  SupplyObservedTargetWithMultipleOwners _ _ _ -> []
  SupplyOwnerGroupMismatch _ _ _ -> []
  SupplyQueryWithoutOwner readModel ->
    [ mkErr (locLine ((.loc) readModel)) CatalogReadModelSupplierMissing $
        "readmodel '" <> (.name) readModel <> "' does not resolve to one projection owner through its observed targets"
    ]
  SupplyQueryWithMultipleOwners readModel owners ->
    [ Diagnostic
        { line = locLine ((.loc) readModel),
          severity = Error,
          code = CatalogReadModelMultipleSuppliers,
          relatedLocations =
            [ (locLine ((.loc) owner), "projection owner '" <> (.name) owner <> "' supplies part of the observed target set")
            | owner <- sortOn (.name) owners
            ],
          message =
            "readmodel '"
              <> (.name) readModel
              <> "' spans several projection owners ("
              <> T.intercalate ", " (map (.name) (sortOn (.name) owners))
              <> "); split the query or declare one owner for the complete observed target set"
        }
    ]
  SupplyLegacyProjectionConflict readModel aggregate projection ->
    [ Diagnostic
        { line = locLine ((.loc) readModel),
          severity = Error,
          code = CatalogReadModelLegacyProjectionConflict,
          relatedLocations =
            [ ( locLine ((.loc) projection),
                "aggregate '" <> (.name) aggregate <> "' also names this readmodel in its legacy projection clause"
              )
            ],
          message =
            "catalog-bound readmodel '"
              <> (.name) readModel
              <> "' derives its supplier from projection-owner target ownership; remove the legacy aggregate projection clause"
        }
    ]

validateProjectionTarget :: EffectiveLanguageContract -> ProjectionTargetNode -> [Diagnostic]
validateProjectionTarget languageContract target =
  [ mkErr (locLine ((.loc) target)) ReadModelIdentifierInvalid $
      "target '" <> (.name) target <> "' " <> kind <> " " <> T.pack (show identifier) <> " is not a PostgreSQL unquoted identifier"
  | hasProjectionCatalog languageContract,
    (kind, identifier) <- [("schema", (.schema) target), ("table", (.table) target)],
    not (validPostgresIdentifier identifier)
  ]

validateRebuildGroup :: EffectiveLanguageContract -> Spec -> RebuildGroupNode -> [Diagnostic]
validateRebuildGroup languageContract spec groupNode
  | not (hasProjectionCatalog languageContract) = []
  | otherwise = emptyTargets <> unknownTargets <> invalidOrder
  where
    targetNames = [(.name) target | NProjectionTarget target <- (.nodes) spec]
    emptyTargets =
      [ mkErr (locLine ((.loc) groupNode)) CatalogGroupEmpty $
          "rebuild group '" <> (.name) groupNode <> "' must own at least one target"
      | null ((.targets) groupNode)
      ]
    unknownTargets =
      [ mkErr (locLine ((.loc) groupNode)) CatalogTargetUnknown $
          "rebuild group '" <> (.name) groupNode <> "' references undeclared target '" <> targetName <> "'"
      | targetName <- (.targets) groupNode,
        targetName `notElem` targetNames
      ]
    invalidOrder =
      [ mkErr (locLine ((.loc) groupNode)) CatalogGroupOrderMismatch $
          "rebuild group '" <> (.name) groupNode <> "' order must contain each owned target exactly once"
      | Set.fromList ((.order) groupNode) /= Set.fromList ((.targets) groupNode)
          || length ((.order) groupNode) /= Set.size (Set.fromList ((.order) groupNode))
          || length ((.targets) groupNode) /= Set.size (Set.fromList ((.targets) groupNode))
      ]

validateProjectionRevision :: EffectiveLanguageContract -> Spec -> ProjectionRevisionNode -> [Diagnostic]
validateProjectionRevision languageContract spec revisionNode
  | not (hasProjectionCatalog languageContract) = []
  | otherwise = noTargets <> unknownGroup <> unknownTargets <> duplicateTargets <> targetSetMismatch <> invalidIdentities <> invalidPromotionNames
  where
    declaredTargets = [(.name) target | NProjectionTarget target <- (.nodes) spec]
    matchingGroups = [groupNode | NRebuildGroup groupNode <- (.nodes) spec, (.name) groupNode == (.group) revisionNode]
    revisionTargets = (.targets) revisionNode
    revisionTargetNames = map (.target) revisionTargets
    noTargets =
      [ mkErr (locLine ((.loc) revisionNode)) CatalogRevisionNoTarget $
          "projection revision '" <> (.name) revisionNode <> "' must declare every target in its rebuild group"
      | null revisionTargets
      ]
    unknownGroup =
      [ mkErr (locLine ((.loc) revisionNode)) CatalogRevisionGroupUnknown $
          "projection revision '" <> (.name) revisionNode <> "' references undeclared rebuild group '" <> (.group) revisionNode <> "'"
      | null matchingGroups
      ]
    unknownTargets =
      [ mkErr (locLine ((.loc) revisionNode)) CatalogRevisionTargetUnknown $
          "projection revision '" <> (.name) revisionNode <> "' references undeclared target '" <> (.target) revisionTarget <> "'"
      | revisionTarget <- revisionTargets,
        (.target) revisionTarget `notElem` declaredTargets
      ]
    duplicateTargets =
      [ mkErr (locLine ((.loc) revisionNode)) CatalogRevisionDuplicateTarget $
          "projection revision '" <> (.name) revisionNode <> "' declares target '" <> targetName <> "' more than once"
      | targetName <- duplicatesBy id revisionTargetNames
      ]
    targetSetMismatch =
      [ mkErr (locLine ((.loc) revisionNode)) CatalogRevisionTargetSetMismatch $
          "projection revision '" <> (.name) revisionNode <> "' target set must equal rebuild group '" <> (.group) revisionNode <> "'"
      | groupNode : _ <- [matchingGroups],
        Set.fromList revisionTargetNames /= Set.fromList ((.targets) groupNode)
          || length revisionTargetNames /= Set.size (Set.fromList revisionTargetNames)
      ]
    invalidIdentities =
      [ mkErr (locLine ((.loc) revisionNode)) CatalogRevisionIdentityInvalid $
          "projection revision '" <> (.name) revisionNode <> "' target '" <> (.target) revisionTarget <> "' has invalid " <> identityKind <> " identity/version"
      | revisionTarget <- revisionTargets,
        (identityKind, identity, version) <-
          [ ("schema", (.schemaVersion) revisionTarget, 1),
            ("provisioner", (.provisioner) revisionTarget, (.provisionerVersion) revisionTarget),
            ("expected-shape", (.expectedShape) revisionTarget, 1),
            ("validator", (.validator) revisionTarget, (.validatorVersion) revisionTarget)
          ],
        T.null identity || T.strip identity /= identity || version <= 0
      ]
    invalidPromotionNames =
      [ mkErr (locLine ((.loc) revisionNode)) CatalogRevisionPromotionNameInvalid $
          "projection revision '" <> (.name) revisionNode <> "' target '" <> (.target) revisionTarget <> "' promotion names must be valid, unique PostgreSQL identifiers"
      | revisionTarget <- revisionTargets,
        let objects = (.promotionObjects) revisionTarget
            names = concat [[(.generationName) object, (.canonicalName) object] | object <- objects],
        any (not . validPostgresIdentifier) names
          || length names /= Set.size (Set.fromList names)
      ]

validateExternalRead :: EffectiveLanguageContract -> Spec -> ExternalReadNode -> [Diagnostic]
validateExternalRead languageContract spec externalRead
  | not (hasProjectionCatalog languageContract) = []
  | otherwise =
      invalidIdentity
        <> invalidVersion
        <> unknownQuery
        <> invalidTargetCardinality
        <> invalidCompatibility
        <> unknownRevisions
        <> revisionGroupMismatch
        <> invalidSurfaceGeneration
  where
    diagnosticLine = locLine ((.loc) externalRead)
    readModels = [readModel | NReadModel readModel <- (.nodes) spec]
    revisions = [revision | NProjectionRevision revision <- (.nodes) spec]
    matchingReadModels = [readModel | readModel <- readModels, (.name) readModel == (.queryModel) externalRead]
    matchingGroup = case matchingReadModels of
      readModel : _ -> (.group) readModel
      [] -> Nothing
    invalidIdentity =
      [ mkErr diagnosticLine CatalogExternalReadIdentityInvalid $
          "external-read '"
            <> (.name) externalRead
            <> "' requires lower-case PostgreSQL identifiers for its contract, result schema, and result type"
      | any
          (not . validPostgresIdentifier)
          [(.name) externalRead, (.resultSchema) externalRead, (.resultType) externalRead]
      ]
    invalidVersion =
      [ mkErr diagnosticLine CatalogExternalReadVersionInvalid $
          "external-read '" <> (.name) externalRead <> "' version must be at least 1"
      | (.version) externalRead <= 0
      ]
    unknownQuery =
      [ mkErr diagnosticLine CatalogExternalReadQueryUnknown $
          "external-read '" <> (.name) externalRead <> "' references undeclared readmodel '" <> (.queryModel) externalRead <> "'"
      | null matchingReadModels
      ]
    invalidTargetCardinality =
      [ mkErr diagnosticLine CatalogExternalReadTargetCardinalityInvalid $
          "external-read '"
            <> (.name) externalRead
            <> "' is the bounded all-row form and its readmodel must observe exactly one target"
      | readModel <- take 1 matchingReadModels,
        length ((.observedTargets) readModel) /= 1
      ]
    compatibleRevisions = (.compatibleRevisions) externalRead
    invalidCompatibility =
      [ mkErr diagnosticLine CatalogExternalReadCompatibilityInvalid $
          "external-read '" <> (.name) externalRead <> "' must name at least one compatible projection revision without duplicates"
      | null compatibleRevisions
          || length compatibleRevisions /= Set.size (Set.fromList compatibleRevisions)
      ]
    unknownRevisions =
      [ mkErr diagnosticLine CatalogExternalReadRevisionUnknown $
          "external-read '" <> (.name) externalRead <> "' references undeclared projection revision '" <> revisionName <> "'"
      | revisionName <- compatibleRevisions,
        revisionName `notElem` map (.name) revisions
      ]
    revisionGroupMismatch =
      [ mkErr diagnosticLine CatalogExternalReadRevisionGroupMismatch $
          "external-read '"
            <> (.name) externalRead
            <> "' binds readmodel group '"
            <> queryGroup
            <> "' but compatible revision '"
            <> revisionName
            <> "' belongs to group '"
            <> (.group) revision
            <> "'"
      | Just queryGroup <- [matchingGroup],
        revisionName <- compatibleRevisions,
        revision <- revisions,
        (.name) revision == revisionName,
        (.group) revision /= queryGroup
      ]
    invalidSurfaceGeneration =
      [ mkErr diagnosticLine CatalogExternalReadSurfaceGenerationInvalid $
          "external-read '" <> (.name) externalRead <> "' surface-generation must be at least 1"
      | (.surfaceGeneration) externalRead <= 0
      ]

validateProjectionOwner :: EffectiveLanguageContract -> ProjectionSupplyAnalysis -> Spec -> ProjectionOwnerNode -> [Diagnostic]
validateProjectionOwner languageContract supplyAnalysis spec owner
  | not (hasProjectionCatalog languageContract) = []
  | otherwise = noSources <> noTargets <> unknownGroup <> outsideGroup <> sourceRules <> identityRules <> checkpointRules <> asyncQueryBinding <> replayRules
  where
    groups = [groupNode | NRebuildGroup groupNode <- (.nodes) spec]
    targets = [target | NProjectionTarget target <- (.nodes) spec]
    aggregates = [(.name) aggregate | NAggregate aggregate <- (.nodes) spec]
    selectedGroupTargets = case [(.targets) groupNode | groupNode <- groups, (.name) groupNode == (.group) owner] of
      groupTargets : _ -> groupTargets
      [] -> []
    noSources =
      [mkErr (locLine ((.loc) owner)) CatalogProjectionNoSource ("projection owner '" <> (.name) owner <> "' must declare at least one source") | null ((.sources) owner)]
    noTargets =
      [mkErr (locLine ((.loc) owner)) CatalogProjectionNoTarget ("projection owner '" <> (.name) owner <> "' must declare at least one target") | null ((.targets) owner)]
    unknownGroup =
      [ mkErr (locLine ((.loc) owner)) CatalogGroupUnknown $
          "projection owner '" <> (.name) owner <> "' references undeclared rebuild group '" <> (.group) owner <> "'"
      | (.group) owner `notElem` map (.name) groups
      ]
    outsideGroup =
      [ mkErr (locLine ((.loc) owner)) CatalogProjectionTargetOutsideGroup $
          "projection owner '" <> (.name) owner <> "' writes target '" <> targetName <> "' outside group '" <> (.group) owner <> "'"
      | targetName <- (.targets) owner,
        targetName `notElem` selectedGroupTargets
      ]
    sourceRules =
      [ mkErr (locLine ((.loc) owner)) CatalogSourceUnresolved $
          "projection owner '" <> (.name) owner <> "' references undeclared aggregate source '" <> aggregateName <> "'"
      | CatalogAggregate aggregateName <- (.sources) owner,
        aggregateName `notElem` aggregates
      ]
        <> [ mkErr (locLine ((.loc) owner)) CatalogSourceOverlap $
               "projection owner '" <> (.name) owner <> "' must select exactly one typed replay source; split independent sources into separate owners"
           | length ((.sources) owner) > 1
           ]
        <> [ mkErr (locLine ((.loc) owner)) RuntimeIdentityInvalid $
               "projection owner '" <> (.name) owner <> "' category source " <> T.pack (show categoryName) <> " " <> reason
           | CatalogCategory categoryName <- (.sources) owner,
             Just reason <- [runtimeIdentityError False categoryName]
           ]
    identityRules = case (.delivery) owner of
      DeliverySubscription ->
        [ mkErr (locLine ((.loc) owner)) CatalogAsyncIdentityMissing $
            "projection owner '" <> (.name) owner <> "' with subscription delivery requires both subscription and dedup identities"
        | (.subscription) owner == Nothing || (.dedup) owner == Nothing
        ]
      DeliveryInline ->
        [ mkErr (locLine ((.loc) owner)) CatalogInlineIdentityUnexpected $
            "projection owner '" <> (.name) owner <> "' with inline delivery cannot declare subscription or dedup identities"
        | (.subscription) owner /= Nothing || (.dedup) owner /= Nothing
        ]
    checkpointRules = case (.delivery) owner of
      DeliverySubscription ->
        [ mkErr (locLine ((.loc) owner)) CatalogCheckpointPolicyMissing $
            "projection owner '" <> (.name) owner <> "' with subscription delivery requires exactly one checkpoint-on-missing policy"
        | null ((.checkpointOnMissing) owner)
        ]
          <> [ mkErr (locLine ((.loc) owner)) CatalogCheckpointPolicyDuplicate $
                 "projection owner '" <> (.name) owner <> "' declares checkpoint-on-missing more than once; choose exactly one of from-beginning, from-current-head, or fail"
             | length ((.checkpointOnMissing) owner) > 1
             ]
      DeliveryInline ->
        [ mkErr (locLine ((.loc) owner)) CatalogCheckpointPolicyUnexpected $
            "projection owner '" <> (.name) owner <> "' with inline delivery cannot declare checkpoint-on-missing because inline delivery has no durable subscription checkpoint"
        | not (null ((.checkpointOnMissing) owner))
        ]
    asyncQueryBinding =
      [ mkErr (locLine ((.loc) owner)) CatalogAsyncQueryBindingMissing $
          "projection owner '" <> (.name) owner <> "' has no query model in group '" <> (.group) owner <> "' observing one of its targets"
      | (.delivery) owner == DeliverySubscription,
        null
          [ ()
          | supply <- (.resolvedProjectionSupplies) supplyAnalysis,
            (.projectionOwner) supply == (.name) owner
          ]
      ]
    replayRules =
      [ mkErr (locLine ((.loc) owner)) CatalogClearTargetLiveOnly $
          "projection owner '" <> (.name) owner <> "' is live-only but writes a clear-before-replay target"
      | ProjectionLiveOnly _ <- [(.replay) owner],
        target <- targets,
        (.name) target `elem` (.targets) owner,
        (.reset) target == TargetClear
      ]
        <> [ mkErr (locLine ((.loc) owner)) CatalogCheckpointPolicyReplayUnsafe $
               "projection owner '" <> (.name) owner <> "' uses from-current-head for subscription '" <> fromMaybe "" ((.subscription) owner) <> "' while replayable target '" <> (.name) target <> "' is cleared before replay; use from-beginning or fail"
           | (.delivery) owner == DeliverySubscription,
             (.checkpointOnMissing) owner == [CheckpointFromCurrentHead],
             (.replay) owner == ProjectionReplayExplicit,
             target <- targets,
             (.name) target `elem` (.targets) owner,
             (.reset) target == TargetClear
           ]

-- | Validate captured identity, feed semantics, and the declared column surface.
validateReadModel :: EffectiveLanguageContract -> ProjectionSupplyAnalysis -> Spec -> ReadModelNode -> [Diagnostic]
validateReadModel languageContract supplyAnalysis spec readModel =
  shapeFixture ++ columnTypes ++ strongFeed ++ scopeMode ++ inlineSubscription ++ inlineReference ++ freshnessCapability ++ versionFloor ++ identifiers ++ runtimeIdentities ++ duplicateColumns ++ catalogBinding
  where
    readModelLine = locLine ((.loc) readModel)
    expectedShape = deriveShapeHash readModel
    shapeFixture =
      [ mkErr readModelLine RmShapeHashDrift $
          "readmodel '"
            <> (.name) readModel
            <> "': captured shape \""
            <> (.shape) readModel
            <> "\" does not match the declared columns (expected \""
            <> expectedShape
            <> "\"); update the fixture AND bump version if the table shape really changed"
      | (.shape) readModel /= expectedShape
      ]
    allowedColumnTypes = Set.fromList ["text", "int", "bigint", "bool", "timestamptz", "jsonb", "numeric"]
    columnTypes =
      [ mkErr readModelLine RmUnknownColumnType $
          "readmodel '" <> (.name) readModel <> "' column '" <> (.rmcName) columnDecl <> "' has unknown type '" <> (.rmcType) columnDecl <> "'"
      | columnDecl <- (.columns) readModel,
        (.rmcType) columnDecl `Set.notMember` allowedColumnTypes
      ]
    strongFeed =
      [ mkErr readModelLine RmStrongInlineOnly $
          "readmodel '"
            <> (.name) readModel
            <> "': consistency = Strong with feed = inline; an inline-only model has no subscription worker to advance the cursor a Strong read waits on. Use consistency = Eventual, or feed = subscription"
      | legacyReadModelFeed readModel == Just RmInline,
        legacyReadModelConsistency readModel == Just Strong
      ]
    scopeMode =
      [ mkErr readModelLine RmScopeWithoutStrong $
          "readmodel '" <> (.name) readModel <> "': scope is meaningful only with consistency = Strong"
      | legacyReadModelScope readModel /= Nothing,
        legacyReadModelConsistency readModel /= Just Strong
      ]
    inlineSubscription =
      [ Diagnostic
          { line = readModelLine,
            severity = Warning,
            code = RmInlineSubscriptionIgnored,
            relatedLocations = [],
            message = "readmodel '" <> (.name) readModel <> "': subscription override is ignored when feed = inline; remove it or select feed = subscription"
          }
      | legacyReadModelFeed readModel == Just RmInline,
        legacyReadModelSubscription readModel /= Nothing
      ]
    inlineReference
      | hasProjectionCatalog languageContract,
        (.group) readModel /= Nothing =
          []
      | otherwise =
          [ mkErr readModelLine RmInlineFeedUnreferenced $
              "readmodel '" <> (.name) readModel <> "' declares feed = inline but no aggregate projection references it"
          | legacyReadModelFeed readModel == Just RmInline,
            (.name) readModel `notElem` [(.table) projection | NAggregate aggregate <- (.nodes) spec, Just projection <- [(.projection) aggregate]]
          ]
    freshnessCapability
      | not (hasSeparatedProjectionQueryPolicy languageContract) = []
      | otherwise = case (.freshness) readModel of
          FreshnessImmediate -> []
          requested@(FreshnessWaitForHead requestedScope) ->
            case resolvedOwner of
              Nothing
                | not (null implicitProjectionOwners) ->
                    [ waitError
                        CatalogQueryWaitWithoutCompatibleCursor
                        requested
                        "implicit aggregate projection"
                        "inline"
                        []
                        "move the projection into a subscription projection-owner or use freshness = immediate"
                    ]
                | otherwise -> []
              Just owner ->
                case compatibleCursorCandidates requestedScope owner of
                  [] ->
                    [ waitError
                        CatalogQueryWaitWithoutCompatibleCursor
                        requested
                        ("projection-owner '" <> (.name) owner <> "'")
                        (deliveryText ((.delivery) owner))
                        (allCursorCandidates owner)
                        "use freshness = immediate or give the supplying owner one compatible subscription cursor"
                    ]
                  [_] -> []
                  candidates ->
                    [ waitError
                        CatalogQueryWaitWithAmbiguousCursor
                        requested
                        ("projection-owner '" <> (.name) owner <> "'")
                        (deliveryText ((.delivery) owner))
                        candidates
                        "leave exactly one compatible subscription cursor or use freshness = immediate"
                    ]
      where
        resolvedOwner = do
          ownerName <- case [ (.projectionOwner) supply
                            | supply <- (.resolvedProjectionSupplies) supplyAnalysis,
                              (.queryModel) supply == (.name) readModel
                            ] of
            [name] -> Just name
            _ -> Nothing
          case [owner | NProjectionOwner owner <- (.nodes) spec, (.name) owner == ownerName] of
            [owner] -> Just owner
            _ -> Nothing
        implicitProjectionOwners =
          [ aggregate
          | NAggregate aggregate <- (.nodes) spec,
            Just projection <- [(.projection) aggregate],
            (.table) projection == (.name) readModel
          ]
        compatibleCursorCandidates scope owner
          | (.delivery) owner /= DeliverySubscription = []
          | not (any (sourceReaches scope) ((.sources) owner)) = []
          | otherwise = allCursorCandidates owner
        allCursorCandidates owner = case (.subscription) owner of
          Just subscription -> [subscription]
          Nothing -> []
        sourceReaches RmEntireLog CatalogAll = True
        sourceReaches RmEntireLog _ = False
        sourceReaches (RmCategory _) CatalogAll = True
        sourceReaches (RmCategory wanted) (CatalogCategory actual) = wanted == actual
        sourceReaches (RmCategory wanted) (CatalogAggregate aggregateName) = wanted == lowerInitial aggregateName
        lowerInitial value = case T.uncons value of
          Nothing -> value
          Just (first, rest) -> T.cons (toLower first) rest
        deliveryText DeliveryInline = "inline"
        deliveryText DeliverySubscription = "subscription"
        freshnessText FreshnessImmediate = "immediate"
        freshnessText (FreshnessWaitForHead RmEntireLog) = "wait-for-head entire-log"
        freshnessText (FreshnessWaitForHead (RmCategory category)) = "wait-for-head category " <> T.pack (show category)
        waitError diagnosticCode requested ownerText delivery candidates remedy =
          mkErr readModelLine diagnosticCode $
            "readmodel '"
              <> (.name) readModel
              <> "' requests "
              <> freshnessText requested
              <> " but its supplying "
              <> ownerText
              <> " has delivery capabilities "
              <> delivery
              <> " and compatible cursor candidates "
              <> (if null candidates then "none" else T.intercalate ", " (sortOn id candidates))
              <> "; remedy: "
              <> remedy
    versionFloor =
      [ mkErr readModelLine ReadModelVersionBelowMinimum $
          "readmodel '" <> (.name) readModel <> "' version must be at least 1"
      | enforcesSpecSurfaceClosures languageContract,
        (.version) readModel < 1
      ]
    identifiers =
      [ mkErr readModelLine ReadModelIdentifierInvalid $
          "readmodel '" <> (.name) readModel <> "' " <> kind <> " " <> T.pack (show identifier) <> " is not a PostgreSQL unquoted identifier"
      | enforcesSpecSurfaceClosures languageContract,
        (kind, identifier) <-
          [ (kind, identifier)
          | (.group) readModel == Nothing,
            (kind, identifier) <- [("schema", (.schema) readModel), ("table", (.table) readModel)]
          ]
            <> [("column", (.rmcName) columnDecl) | columnDecl <- (.columns) readModel],
        not (validPostgresIdentifier identifier)
      ]
    runtimeIdentities =
      [ mkErr readModelLine RuntimeIdentityInvalid $
          "readmodel '" <> (.name) readModel <> "' subscription " <> T.pack (show subscription) <> " " <> reason
      | enforcesSpecSurfaceClosures languageContract,
        Just subscription <- [legacyReadModelSubscription readModel],
        Just reason <- [stableIdentityError subscription]
      ]
        ++ [ mkErr readModelLine RuntimeIdentityInvalid $
               "readmodel '" <> (.name) readModel <> "' scope category " <> T.pack (show category) <> " " <> reason
           | enforcesSpecSurfaceClosures languageContract,
             Just (RmCategory category) <- [readModelScopeForIdentity readModel],
             Just reason <- [runtimeIdentityError False category]
           ]
    readModelScopeForIdentity model = case (.supply) model of
      LegacyReadModelSupply {legacyScope} -> legacyScope
      OwnerDerivedSupply -> case (.freshness) model of
        FreshnessImmediate -> Nothing
        FreshnessWaitForHead scope -> Just scope
    duplicateColumns =
      [ mkErr readModelLine ReadModelDuplicateColumn $
          "readmodel '" <> (.name) readModel <> "' declares column '" <> (.rmcName) columnDecl <> "' more than once"
      | enforcesSpecSurfaceClosures languageContract,
        columnDecl <- duplicatesBy (.rmcName) ((.columns) readModel)
      ]
    catalogBinding
      | not (hasProjectionCatalog languageContract) = []
      | otherwise = missingGroup <> unknownGroup <> physicalOverride <> backingRequired <> backingUnobserved
      where
        groups = [groupNode | NRebuildGroup groupNode <- (.nodes) spec]
        missingGroup =
          [ mkErr readModelLine CatalogReadModelBindingMissing $
              "readmodel '" <> (.name) readModel <> "' must bind to a projection catalog group or be referenced by one legacy aggregate projection"
          | (.group) readModel == Nothing,
            null
              [ ()
              | NAggregate aggregate <- (.nodes) spec,
                Just projection <- [(.projection) aggregate],
                (.table) projection == (.name) readModel
              ]
          ]
        unknownGroup =
          [ mkErr readModelLine CatalogGroupUnknown $
              "readmodel '" <> (.name) readModel <> "' references undeclared rebuild group '" <> groupName <> "'"
          | Just groupName <- [(.group) readModel],
            groupName `notElem` map (.name) groups
          ]
        physicalOverride =
          [ mkErr readModelLine CatalogReadModelPhysicalOverride $
              "readmodel '"
                <> (.name) readModel
                <> "' binds to group '"
                <> groupName
                <> "' but declares explicit table/schema; physical coordinates belong to the target declaration — remove table/schema and name the intended target in 'targets' (and 'backing' when observing several)"
          | Just groupName <- [(.group) readModel],
            (.table) readModel /= "" || (.schema) readModel /= ""
          ]
        backingRequired =
          [ mkErr readModelLine CatalogReadModelBackingRequired $
              "readmodel '"
                <> (.name) readModel
                <> "' observes "
                <> T.pack (show (length ((.observedTargets) readModel)))
                <> " targets; name the physical backing target with 'backing = <target>'"
          | (.group) readModel /= Nothing,
            length ((.observedTargets) readModel) > 1,
            (.backingTarget) readModel == Nothing
          ]
        backingUnobserved =
          [ mkErr readModelLine CatalogReadModelBackingUnobserved $
              "readmodel '"
                <> (.name) readModel
                <> "' names backing target '"
                <> backingTarget
                <> "' but does not observe it"
          | Just backingTarget <- [(.backingTarget) readModel],
            backingTarget `notElem` (.observedTargets) readModel
          ]

-- | EP-5 workqueue rules: the captured physical name must match the queueRef
-- derivation; the disposition inversions (storeFailure transient => must retry;
-- decodeFailure poison => must dead-letter); and dlq=on requires a retry ceiling.
validateWorkqueue :: EffectiveLanguageContract -> WorkqueueNode -> [Diagnostic]
validateWorkqueue languageContract w = concat [divergence, completeness, duplicateRows, inversions, retryCeiling, orderingRules, groupKeyRules, payloadTypes, windows, provisionRules]
  where
    wl = locLine ((.loc) w)
    rows = (.disposition) w
    (derivedPhysical, derivedDlq, derivedTable) = derivedQueueTrio ((.logical) w)
    divergence =
      [ mkErr wl WqPhysicalDivergence $
          "workqueue '" <> (.name) w <> "': captured physical \"" <> (.physical) w <> "\" diverges from queueRef(\"" <> (.logical) w <> "\") = \"" <> derivedPhysical <> "\""
      | (.physical) w /= derivedPhysical
      ]
        ++ [ mkErr wl WqDlqDivergence $
               "workqueue '" <> (.name) w <> "': captured dlq \"" <> (.dlq) w <> "\" diverges from queueRef = \"" <> derivedDlq <> "\""
           | (.dlq) w /= derivedDlq
           ]
        ++ [ mkErr wl WqTableDivergence $
               "workqueue '" <> (.name) w <> "': captured table \"" <> (.table) w <> "\" diverges from queueRef table = \"" <> derivedTable <> "\""
           | (.table) w /= derivedTable
           ]
    requiredOutcomes = ["storeFailure", "commandRejected", "decodeFailure", "onCodecReject"]
    completeness =
      [ mkErr wl WqDispositionIncomplete $
          "workqueue '" <> (.name) w <> "' disposition table is missing outcome '" <> outcome <> "'"
      | outcome <- requiredOutcomes,
        outcome `notElem` map (.outcome) rows
      ]
    duplicateRows =
      [ mkErr (locLine ((.loc) row)) DispositionDuplicateOutcome $
          "workqueue '" <> (.name) w <> "' repeats disposition outcome '" <> (.outcome) row <> "'; the first row would shadow this row"
      | row <- duplicatesBy (.outcome) rows
      ]
    firstRow outcome = case [row | row <- rows, (.outcome) row == outcome] of
      (row : _) -> Just row
      [] -> Nothing
    isRetry row = case (.action) row of IRetry _ -> True; _ -> False
    isDeadLetter row = case (.action) row of IDeadLetter _ -> True; _ -> False
    inversions =
      [ mkErr (locLine ((.loc) row)) WqStoreFailureNotRetry ("workqueue '" <> (.name) w <> "': 'storeFailure' is transient and MUST retry, not dead-letter")
      | Just row <- [firstRow "storeFailure"],
        isDeadLetter row
      ]
        ++ [ mkErr (locLine ((.loc) row)) WqDecodeFailureNotDeadLetter ("workqueue '" <> (.name) w <> "': 'decodeFailure' is poison and MUST dead-letter, not retry")
           | Just row <- [firstRow "decodeFailure"],
             isRetry row
           ]
    retryCeiling =
      [ mkErr wl WqDlqWithoutCeiling ("workqueue '" <> (.name) w <> "': dlq=on requires maxRetries >= 1 (an absent ceiling never dead-letters)")
      | (.dlqOn) w && (.maxRetries) w < 1
      ]
    fifo = (.ordering) w /= WqUnordered
    orderingRules =
      [ mkErr wl WqGroupKeyMissing $
          "workqueue '" <> (.name) w <> "': FIFO delivery is per group, so ordering requires a 'group key' clause that makes enqueueToGroup deterministic"
      | fifo && (.groupKey) w == Nothing
      ]
        ++ [ mkErr wl WqGroupKeyWithoutFifo $
               "workqueue '" <> (.name) w <> "': a group key with unordered reads would be ignored; declare a FIFO ordering or remove the key"
           | not fifo && (.groupKey) w /= Nothing
           ]
    groupKeyRules = case (.groupKey) w of
      Nothing -> []
      Just groupKey ->
        case [field | field <- (.payload) w, (.name) field == (.field) groupKey] of
          [] ->
            [ mkErr wl WqGroupKeyUnresolved $
                "workqueue '" <> (.name) w <> "': group key field '" <> (.field) groupKey <> "' is not declared in its payload"
            ]
          field : _ ->
            [ mkErr wl WqGroupKeyUnresolved $
                "workqueue '" <> (.name) w <> "': group key via raw requires a text payload field, but '" <> (.field) groupKey <> "' has type '" <> queuePayloadTypeText ((.valueType) field) <> "'"
            | (.via) groupKey == "raw" && not (isDirectText ((.valueType) field))
            ]
              ++ [ mkErr wl WqGroupKeyUnresolved $
                     "workqueue '" <> (.name) w <> "': opaque group-key derivation '" <> (.via) groupKey <> "' requires a captured fixture"
                 | (.via) groupKey /= "raw" && (.fixture) groupKey == Nothing
                 ]
    payloadTypes =
      [ mkErr wl WqPayloadTypeUnknown $
          "workqueue '" <> (.name) w <> "' payload field '" <> (.name) field <> "' has unknown type '" <> queueScalarName scalar <> "'; expected text, int, or bool"
      | enforcesSpecSurfaceClosures languageContract,
        field <- (.payload) w,
        LegacyQueueScalar scalar@(QueueOther _) <- [(.valueType) field]
      ]
    isDirectText (LegacyQueueScalar QueueText) = True
    isDirectText (TypedQueueExpression TText) = True
    isDirectText _ = False
    queuePayloadTypeText (LegacyQueueScalar scalar) = queueScalarName scalar
    queuePayloadTypeText (TypedQueueExpression _) = "mapped expression"
    windows =
      windowRangeRule languageContract wl ("workqueue '" <> (.name) w <> "' delay") ((.delay) w)
        ++ concat
          [ windowRangeRule languageContract (locLine ((.loc) row)) ("workqueue '" <> (.name) w <> "' retry") window
          | row <- rows,
            IRetry window <- [(.action) row]
          ]
    provisionRules = case (.provision) w of
      WqStandard -> []
      WqUnlogged ->
        [ Diagnostic
            { line = wl,
              severity = Warning,
              code = WqUnloggedDurability,
              relatedLocations = [],
              message = "workqueue '" <> (.name) w <> "': provision unlogged is truncated to empty on a database crash; use it only for transient, regenerable work"
            }
        ]
      WqPartitioned interval retention ->
        [ mkErr wl WqPartitionSpecEmpty $
            "workqueue '" <> (.name) w <> "': partition interval and retention must be non-empty; they are create-time settings and the additive reconciler will not migrate an existing queue"
        | T.null interval || T.null retention
        ]

-- | EP-5 dispatch rule: the @enqueue to@ target must resolve to a declared workqueue.
validatePgmqDispatch :: EffectiveLanguageContract -> Spec -> PgmqDispatchNode -> [Diagnostic]
validatePgmqDispatch languageContract spec d = enqueueRef ++ dedupQueueRef ++ sourceReadModelRef ++ sourceReadModelField ++ dedupReadModelRef ++ dedupReadModelField ++ dedupKeyField ++ fanoutFunctionName
  where
    dl = locLine ((.loc) d)
    -- The top-level `dedup key` is the logical value being deduped. Its two
    -- physical locations are already checked against the seenIn read model and
    -- queue; the key itself comes from the source read model's row, so it must
    -- be one of that model's generated selectors — exactly the rule `source key`
    -- already obeys. ExecPlan 197 parked this as descriptive-only.
    dedupKeyField = case [readModel | NReadModel readModel <- (.nodes) spec, (.name) readModel == (.sourceReadModel) d] of
      [] -> []
      readModel : _ ->
        [ mkSurfaceRefusal languageContract dl DispatchReadModelFieldUnknown $
            "dispatch '"
              <> (.name) d
              <> "' dedup key '"
              <> (.dedupKey) d
              <> "' is not a generated logical selector for a column of source readmodel '"
              <> (.sourceReadModel) d
              <> "'"
        | (.dedupKey) d `notElem` map (logicalFieldSelector . (.rmcName)) ((.columns) readModel)
        ]

    -- `fanout body` names a hand-written function that expands one source row
    -- into queued jobs. A pgmq dispatch generates no module, so there is no
    -- typed namespace to resolve the name against — but a name that is not a
    -- legal Haskell value identifier cannot be the name of any function anyone
    -- could write, which is decidable here. ExecPlan 197 parked this too.
    fanoutFunctionName =
      [ mkSurfaceRefusal languageContract dl PgmqFanoutFunctionInvalid $
          "dispatch '"
            <> (.name) d
            <> "' fanout body '"
            <> (.fanoutBody) d
            <> "' cannot name a Haskell function; it must be a lowercase-initial identifier that is not a reserved word"
      | not (lowerIdentifierSafe ((.fanoutBody) d))
      ]
    workqueues = [w | NWorkqueue w <- (.nodes) spec]
    enqueueRef =
      [ mkErr dl DispatchEnqueueUnresolved ("dispatch '" <> (.name) d <> "' enqueues to undeclared workqueue '" <> (.enqueueTo) d <> "'")
      | (.enqueueTo) d `notElem` map (.name) workqueues
      ]
    dedupQueueRef = case [w | w <- workqueues, (.name) w == (.dedupQueue) d] of
      [] ->
        [ mkErr dl DispatchDedupQueueUnresolved $
            "dispatch '" <> (.name) d <> "' checks an undeclared dedup queue '" <> (.dedupQueue) d <> "'"
        ]
      (queue : _) ->
        [ mkErr dl DispatchDedupFieldUnresolved $
            "dispatch '" <> (.name) d <> "' dedup field '" <> (.dedupQueueField) d <> "' is not a payload wire field of queue '" <> (.dedupQueue) d <> "'"
        | (.dedupQueueField) d `notElem` map (.wire) ((.payload) queue)
        ]
    sourceReadModelRef =
      resolveReadModelRef DispatchReadModelUnresolved spec ((.loc) d) ("dispatch '" <> (.name) d <> "' source") ((.sourceReadModel) d)
    sourceReadModelField = case [readModel | NReadModel readModel <- (.nodes) spec, (.name) readModel == (.sourceReadModel) d] of
      [] -> []
      readModel : _ ->
        [ mkErr dl DispatchReadModelFieldUnknown $
            "dispatch '" <> (.name) d <> "' source key '" <> (.sourceKey) d <> "' is not a generated logical selector for a column of readmodel '" <> (.sourceReadModel) d <> "'"
        | enforcesSpecSurfaceClosures languageContract,
          (.sourceKey) d `notElem` map (logicalFieldSelector . (.rmcName)) ((.columns) readModel)
        ]
    dedupReadModelRef =
      resolveReadModelRef DispatchReadModelUnresolved spec ((.loc) d) ("dispatch '" <> (.name) d <> "' dedup") ((.dedupReadModel) d)
    dedupReadModelField = case [readModel | NReadModel readModel <- (.nodes) spec, (.name) readModel == (.dedupReadModel) d] of
      [] -> []
      (readModel : _) ->
        [ mkErr dl DispatchReadModelFieldUnknown $
            "dispatch '" <> (.name) d <> "' dedup field '" <> (.dedupReadModelField) d <> "' is not a declared column of readmodel '" <> (.dedupReadModel) d <> "'"
        | (.dedupReadModelField) d `notElem` map (.rmcName) ((.columns) readModel)
        ]

-- | The declared contracts in a spec, by name.
specContracts :: Spec -> [ContractNode]
specContracts spec = [c | NContract c <- (.nodes) spec]

-- | EP-4 cross-node coupling: an intake's contract/topic/accepted-events resolve.
intakeCoupling :: EffectiveLanguageContract -> Spec -> IntakeNode -> [Diagnostic]
intakeCoupling languageContract spec i = bindFlagWarnings ++ bindHeaderNames ++ contractCoupling
  where
    -- The Kafka inbox reconstructs an envelope from the canonical header names
    -- in "Keiro.Integration.Event"; nothing reads a spec-declared header. A row
    -- naming a canonical header is descriptive and true, so it stays silent. A
    -- row naming any other header reads like remapping and silently is not.
    bindHeaderNames =
      [ mkSurfaceRefusal languageContract (locLine ((.loc) i)) IntakeBindHeaderUnknown $
          "intake '"
            <> (.name) i
            <> "' binds '"
            <> (.field) binding
            <> "' from header "
            <> T.pack (show headerName)
            <> ", which is not one of keiro's canonical envelope headers; the Kafka inbox reads a fixed header set and cannot be remapped, so this row would not take effect. Use one of: "
            <> T.intercalate ", " (map (T.pack . show) canonicalEnvelopeHeaders)
      | binding <- (.binds) i,
        SrcHeader headerName <- [(.source) binding],
        headerName `notElem` canonicalEnvelopeHeaders
      ]
    contractCoupling = case lookupContract ((.contract) i) of
      Nothing ->
        [mkErr (locLine ((.loc) i)) IntakeUnresolvedContract ("intake '" <> (.name) i <> "' references undeclared contract '" <> (.contract) i <> "'")]
      Just c ->
        concat
          [ [ mkErr (locLine ((.loc) i)) IntakeUnresolvedContract ("intake '" <> (.name) i <> "' topic '" <> (.topic) i <> "' is not a topic of contract '" <> (.contract) i <> "'")
            | (.topic) i `notElem` map fst ((.topics) c)
            ],
            [ mkErr (locLine ((.loc) i)) IntakeUnresolvedContract ("intake '" <> (.name) i <> "' accepts event '" <> ev <> "' not declared in contract '" <> (.contract) i <> "'")
            | ev <- (.accept) i,
              ev `notElem` map (.name) ((.events) c)
            ],
            [ mkErr (locLine ((.loc) i)) TopicAffinityMismatch $
                "intake '" <> (.name) i <> "' subscribes to topic '" <> (.topic) i <> "' but accepted event '" <> (.name) event <> "' is declared on topic '" <> (.topic) event <> "'"
            | event <- (.events) c,
              (.name) event `elem` (.accept) i,
              (.topic) event /= (.topic) i
            ],
            [ mkErr (locLine ((.loc) i)) IntakeBindUnresolved $
                "intake '" <> (.name) i <> "' binds undeclared envelope or accepted-event field '" <> (.field) binding <> "'"
            | enforcesSpecSurfaceClosures languageContract,
              binding <- (.binds) i,
              (.field) binding `Set.notMember` resolvableFields c
            ],
            [ mkErr (locLine ((.loc) i)) IntakeDedupeKeyUnresolved $
                "intake '" <> (.name) i <> "' dedupe key '" <> (.dedupeKey) i <> "' is not an envelope or accepted-event field"
            | enforcesSpecSurfaceClosures languageContract,
              (.dedupeKey) i `Set.notMember` resolvableFields c
            ],
            [ mkErr (locLine ((.loc) i)) IntakeDecodeSchemaVersionMismatch $
                "intake '"
                  <> (.name) i
                  <> "' decode schemaVersion "
                  <> tInt ((.bodySchemaVersion) ((.decode) i))
                  <> " does not match contract '"
                  <> (.name) c
                  <> "' schemaVersion "
                  <> tInt ((.schemaVersion) c)
            | enforcesSpecSurfaceClosures languageContract,
              (.bodySchemaVersion) ((.decode) i) /= (.schemaVersion) c
            ]
          ]
    bindFlagWarnings =
      [ Diagnostic
          { line = locLine ((.loc) i),
            severity = Warning,
            code = IntakeBindFlagUnenforced,
            relatedLocations = [],
            message =
              "intake '"
                <> (.name) i
                <> "' bind for '"
                <> (.field) binding
                <> "' declares "
                <> bindFlagText binding
                <> ", but generated code does not consume envelope bindings"
          }
      | binding <- (.binds) i,
        (.required) binding || (.crossCheck) binding
      ]
    lookupContract n = case [c | c <- specContracts spec, (.name) c == n] of (c : _) -> Just c; [] -> Nothing
    resolvableFields contract =
      canonicalIntakeEnvelopeFields
        <> Set.fromList
          [ (.name) field
          | event <- (.events) contract,
            (.name) event `elem` (.accept) i,
            field <- (.fields) event
          ]
    bindFlagText binding = case ((.required) binding, (.crossCheck) binding) of
      (True, True) -> "'required' and 'cross-check body' flags"
      (True, False) -> "a 'required' flag"
      (False, True) -> "a 'cross-check body' flag"
      (False, False) -> "no enforcement flags"

-- Note: @derive … hole@ is mandatory emit grammar, so a per-emit warning about
-- it would fire on every emit node in every spec and carry no information. The
-- fact that an emit generates no module is reported once, per scaffold run, by
-- the report's inert-node line. See ExecPlan 199.
validateEmit :: EffectiveLanguageContract -> Spec -> EmitNode -> [Diagnostic]
validateEmit languageContract spec e = skipRule ++ duplicateCases ++ coupling
  where
    el = locLine ((.loc) e)
    skipRule =
      [ mkErr el EmitSkipMissing ("emit '" <> (.name) e <> "' map must end with an explicit '_ => skip' catch-all (hole-kind 7 optionality)")
      | not ((.skip) e)
      ]
    duplicateCases =
      [ mkErr (locLine ((.loc) row)) EmitMapDuplicateCase $
          "emit '" <> (.name) e <> "' repeats map discriminant '" <> (.value) row <> "'; the first row would shadow this row"
      | enforcesSpecSurfaceClosures languageContract,
        row <- duplicatesBy (.value) ((.map) e)
      ]
    coupling = case [c | c <- specContracts spec, (.name) c == (.contract) e] of
      [] -> [mkErr el EmitUnresolvedContract ("emit '" <> (.name) e <> "' references undeclared contract '" <> (.contract) e <> "'")]
      (c : _) ->
        [ mkErr el EmitUnresolvedContract ("emit '" <> (.name) e <> "' topic '" <> (.topic) e <> "' is not a topic of contract '" <> (.contract) e <> "'")
        | (.topic) e `notElem` map fst ((.topics) c)
        ]
          ++ [ mkErr (locLine ((.loc) r)) EmitUnresolvedContract ("emit '" <> (.name) e <> "' maps to event '" <> (.event) r <> "' not declared in contract '" <> (.contract) e <> "'")
             | r <- (.map) e,
               (.event) r `notElem` map (.name) ((.events) c)
             ]
          ++ [ mkErr (locLine ((.loc) row)) TopicAffinityMismatch $
                 "emit '" <> (.name) e <> "' publishes on topic '" <> (.topic) e <> "' but mapped event '" <> (.event) row <> "' is declared on topic '" <> (.topic) event <> "'"
             | row <- (.map) e,
               event <- (.events) c,
               (.name) event == (.event) row,
               (.topic) event /= (.topic) e
             ]

validatePublisher :: EffectiveLanguageContract -> Spec -> PublisherNode -> [Diagnostic]
validatePublisher languageContract spec p =
  unresolvedEmit ++ orderingVocabulary ++ backoffPolicy ++ attemptsFloor ++ outboxField ++ windows
  where
    publisherLine = locLine ((.loc) p)
    unresolvedEmit =
      [ mkErr publisherLine PublisherUnresolvedEmit ("publisher '" <> (.name) p <> "' references undeclared emit '" <> (.emit) p <> "'")
      | (.emit) p `notElem` [(.name) e | NEmit e <- (.nodes) spec]
      ]
    orderingVocabulary =
      [ mkErr publisherLine PublisherOrderingUnknown $
          "publisher '"
            <> (.name) p
            <> "' has unknown ordering '"
            <> (.ordering) p
            <> "'; expected PerKeyHeadOfLine, PerSourceStream, StopTheLine, or BestEffort"
      | (.ordering) p `Set.notMember` publisherOrderings
      ]
    backoffPolicy =
      [ mkErr publisherLine PublisherBackoffInvalid $
          "publisher '" <> (.name) p <> "' has an invalid " <> problem
      | Just problem <- [backoffProblemMaybe ((.backoff) p)]
      ]
    attemptsFloor =
      [ mkErr publisherLine PublisherMaxAttemptsBelowMinimum $
          "publisher '" <> (.name) p <> "' maxAttempts must be at least 1"
      | enforcesSpecSurfaceClosures languageContract,
        (.maxAttempts) p < 1
      ]
    outboxField = case [emitNode | NEmit emitNode <- (.nodes) spec, (.name) emitNode == (.emit) p] of
      [] -> []
      emitNode : _ ->
        [ mkErr publisherLine PublisherOutboxFieldUnresolved $
            "publisher '" <> (.name) p <> "' outboxId field '" <> (.outboxField) p <> "' is not messageId, idempotencyKey, or a field of an event mapped by emit '" <> (.emit) p <> "'"
        | enforcesSpecSurfaceClosures languageContract,
          (.outboxField) p `Set.notMember` allowedOutboxFields emitNode
        ]
    allowedOutboxFields emitNode =
      Set.fromList ("messageId" : "idempotencyKey" : mappedContractFields emitNode)
    mappedContractFields emitNode =
      [ (.dslName) (resolveContractFieldIdentity field)
      | contract <- specContracts spec,
        (.name) contract == (.contract) emitNode,
        event <- (.events) contract,
        (.name) event `elem` map (.event) ((.map) emitNode),
        field <- (.fields) event
      ]
    windows =
      windowRangeRule languageContract publisherLine ("publisher '" <> (.name) p <> "' backoff") ((.window) ((.backoff) p))
        ++ maybe [] (windowRangeRule languageContract publisherLine ("publisher '" <> (.name) p <> "' maximum backoff")) ((.max) ((.backoff) p))

publisherOrderings :: Set Name
publisherOrderings = Set.fromList ["PerKeyHeadOfLine", "PerSourceStream", "StopTheLine", "BestEffort"]

backoffProblemMaybe :: BackoffSpec -> Maybe Text
backoffProblemMaybe backoff = case (.kind) backoff of
  "constant" -> Nothing
  "exponential" -> case ((.max) backoff, (.multiplier) backoff) of
    (Just maximumWindow, Just multiplierText) ->
      case (validationWindowSeconds ((.window) backoff), validationWindowSeconds maximumWindow, readMaybe (T.unpack multiplierText) :: Maybe Double) of
        (Just initialSeconds, Just maximumSeconds, Just multiplier)
          | initialSeconds > 0 && maximumSeconds >= initialSeconds && multiplier >= 1 -> Nothing
        _ -> Just "exponential backoff; initial must be positive, max must be at least initial, and multiplier must be at least 1"
    _ -> Just "exponential backoff; both max and multiplier are required"
  other -> Just ("backoff kind '" <> other <> "'; expected constant or exponential")

validationWindowSeconds :: Text -> Maybe Int
validationWindowSeconds window = case T.unsnoc window of
  Just (digits, unit) -> do
    amount <- readMaybe (T.unpack digits)
    case unit of
      's' -> Just amount
      'm' -> Just (amount * 60)
      'h' -> Just (amount * 3600)
      _ -> Nothing
  Nothing -> Nothing

windowSecondsBounded :: Text -> Either Text Int
windowSecondsBounded window = case T.unsnoc window of
  Nothing -> Left "has no unit"
  Just (digits, unit) -> case readMaybe (T.unpack digits) :: Maybe Integer of
    Nothing -> Left "has invalid digits"
    Just amount -> case unitFactor unit of
      Nothing -> Left "has an unknown unit"
      Just factor
        | seconds > fromIntegral (maxBound :: Int) -> Left "exceeds the runtime Int seconds range"
        | otherwise -> Right (fromIntegral seconds)
        where
          seconds = amount * factor
  where
    unitFactor 's' = Just 1
    unitFactor 'm' = Just 60
    unitFactor 'h' = Just 3600
    unitFactor _ = Nothing

windowRangeRule :: EffectiveLanguageContract -> Int -> Text -> Text -> [Diagnostic]
windowRangeRule languageContract diagnosticLine context window =
  [ mkErr diagnosticLine WindowOutOfRange $
      context <> " window '" <> window <> "' " <> reason
  | enforcesSpecSurfaceClosures languageContract,
    Left reason <- [windowSecondsBounded window]
  ]

-- | EP-4 inbox disposition rules: the table must be complete over the seven
-- outcomes, and the three dangerous inversions must be stated the safe way.
validateIntake :: EffectiveLanguageContract -> IntakeNode -> [Diagnostic]
validateIntake languageContract i = concat [completeness, duplicateRows, inversions, dedupeVocabulary, decodeVersionFloor, envelopeVocabulary, decodePosture, windows]
  where
    il = locLine ((.loc) i)
    -- `decBodyStrict` reaches nothing but the pretty-printer: generated contract
    -- codecs decode every declared body field as required and admit no lenient
    -- mode, so `body strict` describes what happens and `body lenient` does not.
    decodePosture =
      [ mkSurfaceRefusal languageContract il DecodeBodyPostureUnsupported $
          "intake '"
            <> (.name) i
            <> "' declares 'body lenient', but generated contract codecs decode a body strictly: every declared field is required and no lenient fallback is emitted. Write 'body strict' to describe what runs"
      | not ((.bodyStrict) ((.decode) i))
      ]
    rows = (.disposition) i
    requiredOutcomes =
      ["processed", "duplicate", "inProgress", "previouslyFailed", "decodeFailed", "dedupeFailed", "storeFailed"]
    completeness =
      [ mkErr il DispositionIncomplete $
          "intake '" <> (.name) i <> "' disposition table is missing outcome '" <> o <> "'"
      | o <- requiredOutcomes,
        o `notElem` map (.outcome) rows
      ]
    duplicateRows =
      [ mkErr (locLine ((.loc) row)) DispositionDuplicateOutcome $
          "intake '" <> (.name) i <> "' repeats disposition outcome '" <> (.outcome) row <> "'; the first row would shadow this row"
      | row <- duplicatesBy (.outcome) rows
      ]
    windows =
      concat
        [ windowRangeRule languageContract (locLine ((.loc) row)) ("intake '" <> (.name) i <> "' retry") window
        | row <- rows,
          IRetry window <- [(.action) row]
        ]
    dedupeVocabulary =
      [ mkErr il IntakeDedupePolicyUnknown $
          "intake '"
            <> (.name) i
            <> "' has unknown dedupe policy '"
            <> (.dedupePolicy) i
            <> "'; expected PreferIntegrationMessageId, PreferSourceEventIdentity, or KafkaDeliveryIdentity"
      | (.dedupePolicy) i `Set.notMember` intakeDedupePolicies
      ]
    decodeVersionFloor =
      [ mkErr il IntakeDecodeSchemaVersionBelowMinimum $
          "intake '" <> (.name) i <> "' decode schemaVersion must be at least 1"
      | enforcesSpecSurfaceClosures languageContract,
        (.bodySchemaVersion) ((.decode) i) < 1
      ]
    envelopeVocabulary =
      [ mkErr il IntakeEnvelopePolicyUnknown $
          "intake '" <> (.name) i <> "' has unsupported envelope policy " <> T.pack (show ((.envelope) ((.decode) i))) <> "; expected \"strict-required lenient-optional\""
      | enforcesSpecSurfaceClosures languageContract,
        (.envelope) ((.decode) i) /= "strict-required lenient-optional"
      ]
    firstRow outcome = case [row | row <- rows, (.outcome) row == outcome] of
      (row : _) -> Just row
      [] -> Nothing
    isRetry row = case (.action) row of IRetry _ -> True; _ -> False
    inversions =
      [ mkErr (locLine ((.loc) row)) DispositionDuplicateRetry $
          "intake '" <> (.name) i <> "': a 'duplicate' redelivery must be ackOk (success), not retry"
      | Just row <- [firstRow "duplicate"],
        isRetry row
      ]
        ++ [ mkErr (locLine ((.loc) row)) DispositionPreviouslyFailedRetry $
               "intake '" <> (.name) i <> "': 'previouslyFailed' must dead-letter, not retry (a prior failure won't succeed on replay)"
           | Just row <- [firstRow "previouslyFailed"],
             isRetry row
           ]
        ++ [ mkErr (locLine ((.loc) row)) DispositionDecodeUnboundedRetry $
               "intake '" <> (.name) i <> "': 'decodeFailed' must dead-letter (terminal), not retry unboundedly"
           | Just row <- [firstRow "decodeFailed"],
             isRetry row
           ]

intakeDedupePolicies :: Set Name
intakeDedupePolicies = Set.fromList ["PreferIntegrationMessageId", "PreferSourceEventIdentity", "KafkaDeliveryIdentity"]

-- | The timer statuses a stored row can hold, mirroring @TimerStatus@ in
-- @keiro@'s "Keiro.Timer.Schema". keiro-dsl deliberately does not depend on the
-- runtime package, so the list is restated here; the conformance suite that does
-- depend on @keiro@ asserts the two agree.
runtimeTimerStatuses :: [Text]
runtimeTimerStatuses = ["Scheduled", "Firing", "Fired", "Cancelled", "Dead"]

-- | Every header name keiro's integration envelope actually uses on the wire,
-- taken from the runtime's own definitions in "Keiro.Integration.Event" rather
-- than restated here, so the two cannot drift apart.
canonicalEnvelopeHeaders :: [Text]
canonicalEnvelopeHeaders =
  [ Event.headerMessageId,
    Event.headerSource,
    Event.headerDestination,
    Event.headerEventType,
    Event.headerSchemaVersion,
    Event.headerContentType,
    Event.headerSchemaRegistry,
    Event.headerSchemaSubject,
    Event.headerSchemaVersionRef,
    Event.headerSchemaId,
    Event.headerSchemaFingerprint,
    Event.headerSourceEventId,
    Event.headerSourceGlobalPosition,
    Event.headerCausationId,
    Event.headerCorrelationId,
    Event.headerTraceParent,
    Event.headerTraceState,
    Event.headerOccurredAt,
    Event.headerAttributes
  ]

canonicalIntakeEnvelopeFields :: Set Name
canonicalIntakeEnvelopeFields =
  Set.fromList
    [ "messageId",
      "source",
      "destination",
      "key",
      "eventType",
      "schemaVersion",
      "contentType",
      "schemaReference",
      "sourceEventId",
      "sourceGlobalPosition",
      "payloadBytes",
      "occurredAt",
      "causationId",
      "correlationId",
      "traceContext",
      "attributes",
      "idempotencyKey"
    ]

-- | EP-3 rules for a process manager + its nested timer.
validateProcess :: EffectiveLanguageContract -> Spec -> ProcessNode -> [Diagnostic]
validateProcess languageContract spec p =
  concat [sagaCategoryRule, noWallClock, runtimeOwnedDispatchId, crossNodeCoupling, strictSurfaceResolution, timerCeiling, policyRules, ambiguityRule, benignInversions, onAppendedArms, notMineArm, decodeUnknownStatus, deadLetterText]
  where
    -- Generated dispatch code appends and then acks; `Keiro.ProcessManager` has
    -- no branch that retries or dead-letters a *successful* append. Only AckOk
    -- describes what runs.
    onAppendedArms =
      [ mkSurfaceRefusal languageContract (locLine ((.loc) d)) DispatchOnAppendedUnsupported $
          "dispatch to '"
            <> (.target) d
            <> "' maps on-appended => "
            <> dispText ((.onAppended) ((.disposition) d))
            <> ", but a successful append is always acked: no runtime path retries or dead-letters an event it just appended. Write 'on-appended AckOk'"
      | d <- (.dispatch) ((.handle) p),
        (.onAppended) ((.disposition) d) /= DAckOk
      ]

    -- `decode unknown-status => X` names the status a row that fails to decode
    -- is read as. X must be a status the timer table actually has.
    decodeUnknownStatus =
      [ mkSurfaceRefusal languageContract (locLine ((.loc) timer)) TimerDecodeStatusUnknown $
          "timer '"
            <> (.name) timer
            <> "' maps decode unknown-status => '"
            <> (.decodeUnknown) timer
            <> "', which is not a timer status; a stored timer row is one of: "
            <> T.intercalate ", " runtimeTimerStatuses
      | (.decodeUnknown) timer `notElem` runtimeTimerStatuses
      ]

    -- The dead-letter reason is a hand-owned obligation: `runTimerWorkerWith`
    -- composes its own message for the attempt ceiling, and the generated
    -- comment surfaces this text so an operator-written worker can pass it to
    -- `Keiro.Timer.deadLetterTimer`. Nothing can check what the prose says, but
    -- an empty or blank reason names no obligation at all.
    deadLetterText =
      [ mkSurfaceRefusal languageContract (locLine ((.loc) timer)) TimerDeadLetterTextInvalid $
          "timer '"
            <> (.name) timer
            <> "' declares a blank dead-letter reason; the reason is the hand-owned text an operator-written timer worker passes to Keiro.Timer.deadLetterTimer, so it must say something"
      | T.null (T.strip ((.deadLetter) timer))
      ]

    -- The timer worker marks a timer Fired only when the fire action returns the
    -- id of an event it appended (`Keiro.Timer.runTimerWorkerWith`). A not-mine
    -- dispatch produces no such id, so the row is left Firing and requeued on a
    -- later pass — which is exactly Retry. Fired is not reachable.
    notMineArm =
      [ mkSurfaceRefusal languageContract (locLine ((.loc) timer)) TimerNotMineUnsupported $
          "timer '"
            <> (.name) timer
            <> "' maps not-mine => Fired, but the timer worker marks a timer Fired only when the fire action returns the id of the event it appended; a dispatch that is not this timer's has no such id, so the row is requeued instead. Write 'not-mine Retry'"
      | (.notMine) ((.disposition) ((.fire) timer)) == OFired
      ]
    aggregates = [a | NAggregate a <- (.nodes) spec]
    aggNames = map (.name) aggregates
    projectionTables = [(.table) projection | aggregate <- aggregates, Just projection <- [(.projection) aggregate]]
    inputFields = map (.name) ((.fields) ((.input) p))
    timeFields = [(.name) f | f <- (.fields) ((.input) p), (.valueType) f == Just "Time"]
    timer = (.timer) p
    pl = locLine ((.loc) p)

    sagaCategoryRule =
      [ mkErr pl SagaCategoryIllegal $
          "saga category " <> T.pack (show ((.category) ((.saga) p))) <> " " <> reason
      | Just reason <- [sagaCategoryError ((.category) ((.saga) p))]
      ]

    -- TIME IS INJECTED, NOT SAMPLED: fireAt's field must be a declared :Time
    -- input field. (FireAtExpr has no clock-sampling constructor, so this is a
    -- field-resolution + typed-as-Time check.)
    noWallClock =
      let f = (.field) ((.fireAt) timer)
       in if f `notElem` inputFields
            then
              [ mkErr (locLine ((.loc) timer)) ProcessFireAtNotInjected $
                  "timer '" <> (.name) timer <> "' fireAt field '" <> f <> "' is not a field of input '" <> (.name) ((.input) p) <> "'"
              ]
            else
              [ mkErr (locLine ((.loc) timer)) ProcessFireAtNotInjected $
                  "timer '" <> (.name) timer <> "' fireAt references '" <> f <> "', which is not a declared :Time field of input '" <> (.name) ((.input) p) <> "'"
              | f `notElem` timeFields
              ]

    -- Dispatched (and fired) command ids are runtime-owned; no field binding may
    -- supply a commandId/id.
    runtimeOwnedDispatchId =
      [ mkErr pl ProcessDispatchIdSupplied $
          "advance command '" <> (.advCommand) advance <> "' supplies a runtime-owned id field '" <> (.name) binding <> "'; remove it"
      | let advance = (.advance) ((.handle) p),
        binding <- (.advFields) advance,
        (.name) binding `elem` (["commandId", "id"] :: [Name])
      ]
        ++ [ mkErr (locLine ((.loc) d)) ProcessDispatchIdSupplied $
               "dispatch to '" <> (.target) d <> "' supplies a runtime-owned id field '" <> (.name) b <> "'; remove it"
           | d <- (.dispatch) ((.handle) p),
             b <- (.fields) d,
             (.name) b `elem` (["commandId", "id"] :: [Name])
           ]
        ++ [ mkErr (locLine ((.loc) timer)) ProcessDispatchIdSupplied $
               "timer fire supplies a runtime-owned id field '" <> (.name) b <> "'; remove it"
           | b <- (.fields) ((.fire) timer),
             (.name) b `elem` (["commandId", "id"] :: [Name])
           ]

    -- Aggregate, command, field, timer, and projection references must resolve.
    crossNodeCoupling =
      [ mkErr pl ProcessUnresolvedRef ("saga '" <> (.agg) ((.saga) p) <> "' does not resolve to a declared aggregate")
      | (.agg) ((.saga) p) `notElem` aggNames
      ]
        ++ [ mkErr pl ProcessUnresolvedRef ("target '" <> (.target) p <> "' does not resolve to a declared aggregate")
           | (.target) p `notElem` aggNames
           ]
        ++ [ mkErr (locLine ((.loc) timer)) ProcessUnresolvedRef ("timer fire target '" <> (.target) ((.fire) timer) <> "' must be the saga or the target aggregate")
           | (.target) ((.fire) timer) `notElem` [(.agg) ((.saga) p), (.target) p]
           ]
        ++ resolveCommand pl "advance" ((.agg) ((.saga) p)) ((.advCommand) advance) ((.advFields) advance)
        ++ concatMap resolveDispatch ((.dispatch) ((.handle) p))
        ++ resolveCommand (locLine ((.loc) timer)) "timer fire" ((.target) fire) ((.command) fire) ((.fields) fire)
        ++ [ mkErr pl ProcessUnresolvedRef $
               "process '" <> (.id) p <> "' schedules undeclared timer '" <> (.schedule) ((.handle) p) <> "'; declared timer is '" <> (.name) timer <> "'"
           | (.schedule) ((.handle) p) /= (.name) timer
           ]
        ++ [ mkErr pl ProcessUnresolvedRef $
               "process '" <> (.id) p <> "' references undeclared projection table '" <> projection <> "'"
           | projection <- (.projections) p,
             projection `notElem` projectionTables
           ]
      where
        advance = (.advance) ((.handle) p)
        fire = (.fire) timer
        resolveDispatch dispatch =
          resolveCommand
            (locLine ((.loc) dispatch))
            "dispatch"
            ((.target) dispatch)
            ((.command) dispatch)
            ((.fields) dispatch)
        resolveCommand diagnosticLine context target command bindings = case lookupAggregate target of
          Nothing -> []
          Just aggregate -> case [decl | decl <- (.commands) aggregate, (.name) decl == command] of
            [] ->
              [ mkErr diagnosticLine ProcessUnresolvedRef $
                  context <> " command '" <> command <> "' is not declared by aggregate '" <> target <> "'"
              ]
            (declaration : _) ->
              [ mkErr diagnosticLine ProcessFieldBindingUnresolved $
                  context <> " command '" <> command <> "' binds undeclared target field '" <> (.name) binding <> "'"
              | binding <- bindings,
                (.name) binding `notElem` map (.name) ((.fields) declaration)
              ]
        lookupAggregate name = case [aggregate | aggregate <- aggregates, (.name) aggregate == name] of
          (aggregate : _) -> Just aggregate
          [] -> Nothing

    strictSurfaceResolution
      | not (enforcesSpecSurfaceClosures languageContract) = []
      | otherwise = correlateFieldRule ++ dispatchKeyRules ++ bindingScopeRules ++ idFieldRules ++ fireWindowRule

    correlateFieldRule =
      [ mkErr pl ProcessKeyFieldUnknown $
          "correlate references 'input." <> (.field) ((.correlate) p) <> "' but input '" <> (.name) ((.input) p) <> "' does not declare that field"
      | (.field) ((.correlate) p) `notElem` inputFields
      ]

    dispatchKeyRules =
      [ mkErr (locLine ((.loc) dispatch)) ProcessDispatchKeyUnresolved $
          "dispatch to '" <> (.target) dispatch <> "' uses unresolved key '" <> (.key) dispatch <> "'; expected correlationId or input.<declared-field>"
      | dispatch <- (.dispatch) ((.handle) p),
        not (processKeyInScope ((.key) dispatch))
      ]
        ++ [ mkErr (locLine ((.loc) timer)) ProcessDispatchKeyUnresolved $
               "timer fire to '" <> (.target) ((.fire) timer) <> "' uses unresolved key '" <> (.key) ((.fire) timer) <> "'; expected correlationId or input.<declared-field>"
           | not (processKeyInScope ((.key) ((.fire) timer)))
           ]

    processKeyInScope value =
      value == "correlationId"
        || case T.stripPrefix "input." value of
          Just field -> field `elem` inputFields
          Nothing -> False

    bindingScopeRules =
      bindingRules pl "advance" inputFields ((.advFields) ((.advance) ((.handle) p)))
        ++ concatMap
          (\dispatch -> bindingRules (locLine ((.loc) dispatch)) "dispatch" inputFields ((.fields) dispatch))
          ((.dispatch) ((.handle) p))
        ++ bindingRules
          (locLine ((.loc) timer))
          "timer fire"
          (inputFields <> map (.name) ((.payload) timer) <> ["timerId"])
          ((.fields) ((.fire) timer))

    bindingRules diagnosticLine context bareScope bindings =
      [ mkErr diagnosticLine ProcessBindingUnscoped $
          context <> " binding '" <> (.name) binding <> maybe "" ("=" <>) ((.value) binding) <> "' is outside the process input and timer scopes"
      | binding <- bindings,
        not (bindingInScope bareScope binding)
      ]

    bindingInScope bareScope binding = case (.value) binding of
      Nothing -> (.name) binding `elem` bareScope
      Just value
        | isQuoted value -> True
        | value == "timer.id" -> True
        | Just field <- T.stripPrefix "input." value -> field `elem` inputFields
        | otherwise -> value `elem` bareScope

    isQuoted value = T.length value >= 2 && T.head value == '"' && T.last value == '"'

    idFieldRules =
      [ mkErr (locLine ((.loc) timer)) TimerIdFieldNotCorrelation $
          "timer '" <> (.name) timer <> "' " <> context <> " derives from '" <> (.field) expression <> "'; only correlationId is implemented by generated runtime code"
      | (context, expression) <- [("id", (.id) timer), ("fired-event-id", (.firedEventId) ((.fire) timer))],
        (.field) expression /= "correlationId"
      ]

    fireWindowRule =
      windowRangeRule languageContract (locLine ((.loc) timer)) ("timer '" <> (.name) timer <> "' fireAt") ((.window) ((.fireAt) timer))

    timerCeiling =
      [ mkErr (locLine ((.loc) timer)) ProcessTimerCeilingInvalid $
          "timer '" <> (.name) timer <> "' max-attempts must be at least 1"
      | (.maxAttempts) timer < 1
      ]

    policyRules =
      policyConsistency
        ((.id) p)
        ((.loc) p)
        ((.rejected) p)
        [ ((.command) dispatch, (.loc) dispatch, (.disposition) dispatch)
        | dispatch <- (.dispatch) ((.handle) p)
        ]

    ambiguityRule =
      [ mkErr (locLine ((.loc) timer)) AmbiguousMarkedBenign $
          "timer '" <> (.name) timer <> "' maps on-ambiguous => Fired; CommandAmbiguous means multiple aggregate edges matched and is never a benign success. Use on-ambiguous Retry so the attempts ceiling dead-letters the definition bug"
      | (.onAmbiguous) ((.disposition) ((.fire) timer)) == OFired
      ]

    -- Surface the dangerous benign inversions the author confirmed (warnings).
    benignInversions =
      [ Diagnostic (locLine ((.loc) timer)) Warning ProcessBenignInversion [] $
          "timer '" <> (.name) timer <> "' maps on-reject => Fired (a CommandRejected is treated as benign success)"
      | (.onReject) ((.disposition) ((.fire) timer)) == OFired
      ]
        ++ [ Diagnostic (locLine ((.loc) d)) Warning ProcessBenignInversion [] $
               "dispatch to '" <> (.target) d <> "' maps on-duplicate => AckOk (a duplicate is treated as benign success)"
           | d <- (.dispatch) ((.handle) p),
             (.onDuplicate) ((.disposition) d) == DAckOk
           ]

-- | Explain why a process saga category is illegal.  The first four cases
-- mirror 'Keiro.Stream.category' without introducing a runtime dependency into
-- the toolchain library.  The final @:@ case is deliberately stricter because
-- that prefix is reserved for the @wf:<name>@ workflow stream family.
sagaCategoryError :: Text -> Maybe Text
sagaCategoryError = runtimeIdentityError False

stableIdentityError :: Text -> Maybe Text
stableIdentityError = runtimeIdentityError True

runtimeIdentityError :: Bool -> Text -> Maybe Text
runtimeIdentityError allowsHyphen identity
  | T.null identity = Just "is empty; use a non-empty stable name"
  | identity == "$all" = Just "is reserved by the event store; choose a service-owned stable name"
  | not allowsHyphen && T.isInfixOf "-" identity = Just "contains '-' (kiroku's category/id boundary); write compound categories in camelCase, for example \"hospitalSurge\""
  | Just illegal <- T.find (\character -> isSpace character || isControl character) identity =
      Just ("contains whitespace or control character " <> T.pack (show illegal) <> "; remove it and use camelCase")
  | T.isInfixOf ":" identity = Just "contains ':' which is reserved for runtime stream-family prefixes; choose a stable name without ':'"
  | otherwise = Nothing

-- | The generated lower-camel selector for a logical field or SQL column.
-- Read-model notation stores SQL names such as @responder_id@ while router
-- resolve rows and dispatch keys use the generated selector @responderId@.
logicalFieldSelector :: Text -> Text
logicalFieldSelector raw =
  case HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site of
    Right derived -> HaskellName.renderLowerCamelName ((.lowerCamel) derived)
    Left _ -> raw
  where
    site =
      HaskellName.NameSite
        { HaskellName.kind = HaskellName.GeneratedFieldSite,
          HaskellName.logicalName = raw,
          HaskellName.owner = "validation field resolution",
          HaskellName.line = 0
        }

-- | EP-108 rules for a stateless content-based router.
validateRouter :: EffectiveLanguageContract -> Either (NE.NonEmpty TypeGraphError) TypeGraph -> Spec -> RouterNode -> [Diagnostic]
validateRouter languageContract typeGraphResult spec router =
  concat
    [ references,
      keyField,
      bindingScope,
      commandReference,
      readModelReference,
      selectionChecks,
      policyRules,
      duplicateNotice,
      onAppendedArm
    ]
  where
    -- The process twin of this rule is in 'validateProcess'; both say the same
    -- thing because both runtimes do: a successful append is always acked.
    onAppendedArm =
      [ mkSurfaceRefusal languageContract dispatchLine DispatchOnAppendedUnsupported $
          "router dispatch '"
            <> (.command) dispatch
            <> "' maps on-appended => "
            <> dispText ((.onAppended) ((.disposition) dispatch))
            <> ", but a successful append is always acked: no runtime path retries or dead-letters an event it just appended. Write 'on-appended AckOk'"
      | (.onAppended) ((.disposition) dispatch) /= DAckOk
      ]
    aggregates = [aggregate | NAggregate aggregate <- (.nodes) spec]
    readModels = [readModel | NReadModel readModel <- (.nodes) spec]
    inputFields = map (.name) ((.fields) ((.input) router))
    resolvedFields = (.row) ((.resolve) router)
    dispatch = (.dispatch) router
    routerLine = locLine ((.loc) router)
    dispatchLine = locLine ((.loc) dispatch)

    targetAggregate = case [aggregate | aggregate <- aggregates, (.name) aggregate == (.target) router] of
      aggregate : _ -> Just aggregate
      [] -> Nothing

    projectionTables = [(.table) projection | aggregate <- aggregates, Just projection <- [(.projection) aggregate]]

    references =
      [ mkErr routerLine RouterUnresolvedRef $
          "router '" <> (.id) router <> "' targets aggregate '" <> (.target) router <> "' but no such aggregate is declared"
      | targetAggregate == Nothing
      ]
        ++ [ mkErr routerLine RouterUnresolvedRef $
               "router '" <> (.id) router <> "' references undeclared projection table '" <> projection <> "'"
           | projection <- (.projections) router,
             projection `notElem` projectionTables
           ]

    keyField = case (.source) ((.resolve) router) of
      ResolveDeclarative {} -> []
      _ ->
        [ mkErr routerLine RouterKeyFieldUnknown $
            "key references 'input." <> (.field) ((.key) router) <> "' but input '" <> (.name) ((.input) router) <> "' does not declare that field"
        | (.field) ((.key) router) `notElem` inputFields
        ]

    bindingScope = case (.source) ((.resolve) router) of
      ResolveDeclarative {} -> []
      _ ->
        [ mkErr dispatchLine RouterBindingUnscoped $
            "dispatch binding '" <> (.name) binding <> maybe "" ("=" <>) ((.value) binding) <> "' is outside the router input and resolve-row scopes"
        | binding <- (.fields) dispatch,
          not (bindingInScope binding)
        ]
      where
        bindingInScope binding = case (.value) binding of
          Nothing -> (.name) binding `elem` inputFields
          Just value
            | isQuoted value -> True
            | Just field <- T.stripPrefix "input." value -> field `elem` inputFields
            | Just field <- T.stripPrefix "resolved." value -> field `elem` resolvedFields
            | otherwise -> False
        isQuoted value = T.length value >= 2 && T.head value == '"' && T.last value == '"'

    commandReference = case targetAggregate of
      Nothing -> []
      Just aggregate -> case [command | command <- (.commands) aggregate, (.name) command == (.command) dispatch] of
        [] ->
          [ mkErr dispatchLine RouterCommandUnknown $
              "dispatch command '" <> (.command) dispatch <> "' is not declared by aggregate '" <> (.name) aggregate <> "'"
          ]
        command : _ ->
          [ mkErr dispatchLine RouterCommandUnknown $
              "dispatch command '" <> (.command) dispatch <> "' binds undeclared target field '" <> (.name) binding <> "'"
          | binding <- (.fields) dispatch,
            (.name) binding `notElem` map (.name) ((.fields) command)
          ]

    readModelReference = case (.source) ((.resolve) router) of
      ResolveHole -> []
      ResolveDeclarative {} -> []
      ResolveReadModel name ->
        case [readModel | readModel <- readModels, (.name) readModel == name] of
          [] ->
            [ mkErr (locLine ((.loc) ((.resolve) router))) RouterUnresolvedRef $
                "router '" <> (.id) router <> "' resolve names readmodel '" <> name <> "' but no such readmodel node is declared"
            ]
          readModel : _ ->
            [ mkErr (locLine ((.loc) ((.resolve) router))) RouterReadModelUnverified $
                "router '" <> (.id) router <> "' resolve row field '" <> column <> "' is not a declared column of readmodel '" <> name <> "'"
            | enforcesSpecSurfaceClosures languageContract,
              column <- (.row) ((.resolve) router),
              column `notElem` map (logicalFieldSelector . (.rmcName)) ((.columns) readModel)
            ]

    selectionChecks = case (.source) ((.resolve) router) of
      ResolveDeclarative {} -> case typeGraphResult of
        Left _ -> []
        Right graph -> case RouterSelection.checkRouterSelection languageContract graph spec router of
          Right _ -> []
          Left diagnostics -> map routerSelectionDiagnostic (NE.toList diagnostics)
      _ -> []

    policyRules =
      policyConsistency
        ((.id) router)
        ((.loc) router)
        ((.rejected) router)
        [((.command) dispatch, (.loc) dispatch, (.disposition) dispatch)]

    duplicateNotice =
      [ Diagnostic dispatchLine Warning RouterBenignInversion [] $
          "router dispatch '" <> (.command) dispatch <> "' maps on-duplicate => AckOk; Keiro.Router confirms the event id against the target stream before treating the duplicate as benign"
      | (.onDuplicate) ((.disposition) dispatch) == DAckOk
      ]

routerSelectionDiagnostic :: RouterSelection.RouterSelectionDiagnostic -> Diagnostic
routerSelectionDiagnostic diagnostic =
  mkErr
    (locLine ((.loc) diagnostic))
    (routerSelectionDiagnosticCode ((.code) diagnostic))
    ((.message) diagnostic)

routerSelectionDiagnosticCode :: RouterSelection.RouterSelectionDiagnosticCode -> DiagnosticCode
routerSelectionDiagnosticCode = \case
  RouterSelection.SelectionNotDeclarative -> RouterSelectionNotDeclarative
  RouterSelection.SelectionCapabilityUnavailable -> RouterSelectionCapabilityUnavailable
  RouterSelection.SelectionIdentityEmpty -> RouterSelectionIdentityEmpty
  RouterSelection.SelectionVersionInvalid -> RouterSelectionVersionInvalid
  RouterSelection.SelectionQueryUnknown -> RouterSelectionQueryUnknown
  RouterSelection.SelectionQueryContractMissing -> RouterSelectionQueryContractMissing
  RouterSelection.SelectionQueryInputBindingInvalid -> RouterSelectionQueryInputBindingInvalid
  RouterSelection.SelectionQueryInputTypeMismatch -> RouterSelectionQueryInputTypeMismatch
  RouterSelection.SelectionQueryResultNotList -> RouterSelectionQueryResultNotList
  RouterSelection.SelectionQueryRowNotStructural -> RouterSelectionQueryRowNotStructural
  RouterSelection.SelectionExpressionRootUnknown -> RouterSelectionExpressionRootUnknown
  RouterSelection.SelectionExpressionFieldUnknown -> RouterSelectionExpressionFieldUnknown
  RouterSelection.SelectionExpressionFieldOptional -> RouterSelectionExpressionFieldOptional
  RouterSelection.SelectionExpressionTypeMismatch -> RouterSelectionExpressionTypeMismatch
  RouterSelection.SelectionPredicateNotBool -> RouterSelectionPredicateNotBool
  RouterSelection.SelectionRecipientNotText -> RouterSelectionRecipientNotText
  RouterSelection.SelectionOperatorUnsupported -> RouterSelectionOperatorUnsupported
  RouterSelection.SelectionRecipientLimitMissing -> RouterSelectionRecipientLimitMissing
  RouterSelection.SelectionRecipientLimitInvalid -> RouterSelectionRecipientLimitInvalid
  RouterSelection.SelectionOrderUnsupported -> RouterSelectionOrderUnsupported
  RouterSelection.SelectionDedupeUnsupported -> RouterSelectionDedupeUnsupported
  RouterSelection.SelectionFailureAckForbidden -> RouterSelectionFailureAckForbidden
  RouterSelection.SelectionRedeliveryUnsupported -> RouterSelectionRedeliveryUnsupported
  RouterSelection.SelectionPartialDispatchUnsupported -> RouterSelectionPartialDispatchUnsupported
  RouterSelection.SelectionTargetAmbiguous -> RouterSelectionTargetAmbiguous
  RouterSelection.SelectionCommandUnknown -> RouterSelectionCommandUnknown
  RouterSelection.SelectionCommandMappingDuplicate -> RouterSelectionCommandMappingDuplicate
  RouterSelection.SelectionCommandMappingIncomplete -> RouterSelectionCommandMappingIncomplete
  RouterSelection.SelectionCommandMappingTypeMismatch -> RouterSelectionCommandMappingTypeMismatch

-- | Reconcile per-dispatch prose with the one node-level policy the runtime
-- actually applies to a rejection-class failure group.
policyConsistency :: Name -> Loc -> PolicyChoice -> [(Name, Loc, DispatchDisposition)] -> [Diagnostic]
policyConsistency nodeName nodeLoc rejectedPolicy dispatches = contradictions ++ divergent ++ unused ++ ambiguityWarning
  where
    contradictions =
      [ mkErr (locLine dispatchLoc) PolicyContradiction $
          "dispatch '" <> command <> "' declares on-failed DeadLetter, but node '" <> nodeName <> "' does not declare rejected => deadLetter; align the dispatch story with the node-level RejectedCommandPolicy"
      | (command, dispatchLoc, disposition) <- dispatches,
        DDeadLetter _ <- [(.onFailed) disposition],
        rejectedPolicy /= PolDeadLetter
      ]

    divergent = case dispatches of
      [] -> []
      (_, _, firstDisposition) : rest ->
        [ mkErr (locLine dispatchLoc) PolicyContradiction $
            "dispatch '" <> command <> "' has a different on-failed action from another dispatch in node '" <> nodeName <> "'; the runtime applies one RejectedCommandPolicy to the whole failure group"
        | (command, dispatchLoc, disposition) <- rest,
          not (sameFailureAction ((.onFailed) disposition) ((.onFailed) firstDisposition))
        ]

    unused =
      [ Diagnostic (locLine nodeLoc) Warning PolicyDeadLetterUnused [] $
          "node '" <> nodeName <> "' declares rejected => deadLetter but no dispatch on-failed arm says DeadLetter; the runtime policy is live, but the per-dispatch notation does not acknowledge it"
      | rejectedPolicy == PolDeadLetter,
        all (not . isDeadLetter . (.onFailed) . third) dispatches
      ]

    ambiguityWarning =
      [ Diagnostic (locLine nodeLoc) Warning AmbiguousFollowsRejectedPolicy [] $
          "node '" <> nodeName <> "' acknowledges rejection-class failures; CommandAmbiguous follows the same rejected policy, and a dead-letter errorClass is the durable witness of that definition bug"
      | rejectedPolicy `elem` [PolDeadLetter, PolSkip]
      ]

    third (_, _, value) = value
    sameFailureAction DDeadLetter {} DDeadLetter {} = True
    sameFailureAction left right = left == right
    isDeadLetter DDeadLetter {} = True
    isDeadLetter _ = False

validateAggregate :: EffectiveLanguageContract -> Either (NE.NonEmpty TypeGraphError) TypeGraph -> Spec -> Aggregate -> [Diagnostic]
validateAggregate languageContract typeGraphResult spec agg =
  concat
    [ emptyAggregate,
      duplicateMembers,
      declaredRefs,
      eventBodyRefs,
      outputMappingRules,
      registerInitialScope,
      reachability,
      terminalNoOutgoing,
      guardScope,
      clockFree,
      projectionKeyResolution,
      projectionSafety,
      statusMapTotality,
      evolutionRules,
      snapshotRules,
      replayOnlyRules,
      eventlessStateChangeRules,
      domainOutcomeRules,
      wirePolicyRules,
      fieldWireKeyRules
    ]
  where
    emptyAggregate =
      [ mkErr (locLine ((.loc) agg)) AggregateEmpty $
          "aggregate '"
            <> (.name) agg
            <> "' declares "
            <> renderMissing missingAggregateParts
            <> "; scaffold cannot lower an empty aggregate -- declare at least one command, one event, and one transition"
      | not (null missingAggregateParts)
      ]
    missingAggregateParts =
      [ label
      | (isMissing, label) <-
          [ (null ((.commands) agg), "no commands"),
            (null ((.events) agg), "no events"),
            (null ((.transitions) agg), "no transitions")
          ],
        isMissing
      ]
    renderMissing [] = ""
    renderMissing [onlyPart] = onlyPart
    renderMissing [firstPart, secondPart] = firstPart <> " and " <> secondPart
    renderMissing parts = T.intercalate ", " (init parts) <> ", and " <> last parts

    states = Set.fromList (map (.name) ((.states) agg))
    terminals = Set.fromList [(.name) s | s <- (.states) agg, (.terminal) s]
    commandFields :: Map Name [Name]
    commandFields = Map.fromList [((.name) c, map (.name) ((.fields) c)) | c <- (.commands) agg]
    commandNames = Map.keysSet commandFields
    eventNames = Set.fromList (map (.name) ((.events) agg))
    enumCtorNames = Set.fromList [c | e <- (.enums) spec, (c, _) <- (.ctors) e]
    ruleNames = Set.fromList (map (.name) ((.rules) spec))
    registerNames = Set.fromList (map (.name) ((.regs) agg))

    eventFieldsFor event =
      case (.body) event of
        EventFields fields -> fields
        EventFromCommand commandName ->
          [ field
          | command <- (.commands) agg,
            (.name) command == commandName,
            field <- (.fields) command
          ]

    fieldWireKeyRules =
      concat
        [ wireKeyRulesForRecord
            ("aggregate '" <> (.name) agg <> "' command '" <> (.name) command <> "'")
            Nothing
            (map resolveAggregateFieldIdentity ((.fields) command))
        | command <- (.commands) agg
        ]
        <> concat
          [ wireKeyRulesForRecord
              ("aggregate '" <> (.name) agg <> "' event '" <> (.name) event <> "'")
              (Just ("kind", "event envelope key"))
              (map resolveAggregateFieldIdentity (eventFieldsFor event))
          | event <- (.events) agg
          ]

    snapshotRules = case (.snapshot) agg of
      Nothing -> []
      Just snapshot ->
        [ mkErr (locLine ((.loc) snapshot)) SnapshotIntervalInvalid $
            "aggregate '" <> (.name) agg <> "': snapshot every requires an interval of at least 1; non-positive runtime intervals silently disable snapshots"
        | SnapEvery interval <- [(.policy) snapshot],
          interval < 1
        ]
          ++ [ mkErr (locLine ((.loc) snapshot)) SnapshotCodecFixtureInvalid $
                 "aggregate '" <> (.name) agg <> "': snapshot state-codec version must be at least 1 and shape-hash must be non-empty"
             | (.codecVersion) snapshot < 1 || T.null ((.shapeHash) snapshot)
             ]

    wirePolicyRules = case (.wire) agg of
      Just wire
        | enforcesSpecSurfaceClosures languageContract,
          (.kind) wire /= "ctorName" || (.fields) wire /= "camelCase" ->
            [ mkErr (locLine ((.loc) agg)) WireClauseUnsupported $
                "aggregate '"
                  <> (.name) agg
                  <> "' wire clause describes kind="
                  <> (.kind) wire
                  <> " fields="
                  <> (.fields) wire
                  <> "; generated bytes currently support only kind=ctorName fields=camelCase"
            ]
      _ -> []

    duplicateMembers =
      [ mkErr (locLine ((.loc) c)) DuplicateCommandName $
          "aggregate '" <> (.name) agg <> "' declares command '" <> (.name) c <> "' more than once"
      | c <- duplicatesBy (.name) ((.commands) agg)
      ]
        ++ [ mkErr (locLine ((.loc) e)) DuplicateEventName $
               "aggregate '" <> (.name) agg <> "' declares event '" <> (.name) e <> "' more than once"
           | e <- duplicatesBy (.name) ((.events) agg)
           ]
        ++ [ mkErr (locLine ((.loc) field)) AggregateDuplicateFieldName $
               "aggregate '" <> (.name) agg <> "' command '" <> (.name) command <> "' declares field '" <> (.name) field <> "' more than once"
           | command <- (.commands) agg,
             field <- duplicatesBy (.name) ((.fields) command)
           ]
        ++ [ mkErr (locLine ((.loc) field)) AggregateDuplicateFieldName $
               "aggregate '" <> (.name) agg <> "' event '" <> (.name) event <> "' declares field '" <> (.name) field <> "' more than once"
           | event <- (.events) agg,
             EventFields fields <- [(.body) event],
             field <- duplicatesBy (.name) fields
           ]
        ++ [ mkErr (locLine ((.loc) state)) AggregateDuplicateState $
               "aggregate '" <> (.name) agg <> "' declares state '" <> (.name) state <> "' more than once"
           | state <- duplicatesBy (.name) ((.states) agg)
           ]
        ++ [ mkErr (locLine ((.loc) register)) AggregateDuplicateRegister $
               "aggregate '" <> (.name) agg <> "' declares register '" <> (.name) register <> "' more than once"
           | enforcesSpecSurfaceClosures languageContract,
             register <- duplicatesBy (.name) ((.regs) agg)
           ]
        ++ [ mkErr (locLine ((.loc) transition)) TransitionDuplicateUnguarded $
               "aggregate '"
                 <> (.name) agg
                 <> "' has more than one live unguarded transition for '"
                 <> (.source) transition
                 <> " -- "
                 <> (.command) transition
                 <> "'; every matching command would be ambiguous"
           | group <- duplicateGroupsBy transitionKey unguardedTransitions,
             transition <- group
           ]
        ++ [ mkErr (locLine ((.loc) guarded)) TransitionUnguardedSibling $
               "aggregate '"
                 <> (.name) agg
                 <> "' guarded transition '"
                 <> (.source) guarded
                 <> " -- "
                 <> (.command) guarded
                 <> "' overlaps an unguarded sibling at line "
                 <> tInt (locLine ((.loc) unguarded))
           | enforcesSpecSurfaceClosures languageContract,
             guarded <- liveTransitions,
             (.guard) guarded /= Nothing,
             unguarded : _ <- [[candidate | candidate <- unguardedTransitions, transitionKey candidate == transitionKey guarded]]
           ]
    liveTransitions = [transition | transition <- (.transitions) agg, (.mode) transition == TmLive]
    unguardedTransitions = [transition | transition <- liveTransitions, (.guard) transition == Nothing]
    transitionKey transition = ((.source) transition, (.command) transition)

    eventBodyRefs =
      [ mkErr (locLine ((.loc) e)) UndeclaredCommand $
          "event '" <> (.name) e <> "' copies fields from undeclared command '" <> command <> "'"
      | e <- (.events) agg,
        EventFromCommand command <- [(.body) e],
        command `Set.notMember` commandNames
      ]

    outputMappingRules =
      [ mkErr (locLine ((.loc) transition)) EventOutputCommandMismatch $
          "transition '"
            <> (.source) transition
            <> " -- "
            <> consuming
            <> "' emits event '"
            <> eventName
            <> "' declared as fields("
            <> declared
            <> "); generated identity output is legal only when the transition consumes that same command"
      | transition <- (.transitions) agg,
        (emitIndex, eventName) <- zip [1 ..] ((.emits) transition),
        Left OutputCommandMismatch {declaredSourceCommand = declared, consumingTransitionCommand = consuming} <- [eventOutputMappingFromGraphResult typeGraphResult spec agg transition emitIndex eventName]
      ]

    registerInitialScope = concatMap checkRegisterInitial ((.regs) agg)
    checkRegisterInitial r = case [e | e <- (.enums) spec, TRef ((.name) e) == (.valueType) r] of
      (e : _) -> case (.binding) e of
        Just _ ->
          [ outOfScope r "declaration-owned symbol selected by" "initial"
          | regInitialBare r /= Just "initial"
          ]
        Nothing ->
          [ outOfScope r "constructor of enum" ((.name) e)
          | regInitialBare r `notElem` map (Just . fst) ((.ctors) e)
          ]
      []
        | (.valueType) r == TRef ((.name) agg <> "Vertex") ->
            [ outOfScope r "state of aggregate" ((.name) agg)
            | maybe True (`Set.notMember` states) (regInitialBare r)
            ]
        | Just identifier <- firstMatching (\declaration -> (.valueType) r == TRef ((.name) declaration)) ((.ids) spec) -> case (.binding) identifier of
            Just _ ->
              [ outOfScope r "declaration-owned symbol selected by" "initial"
              | regInitialBare r /= Just "initial"
              ]
            Nothing ->
              [ outOfScope r "literal" "placeholder"
              | regInitialBare r /= Just "placeholder"
              ]
        | otherwise -> []
    outOfScope r expected domain =
      mkErr (locLine ((.loc) r)) RegisterInitialOutOfScope $
        "register '" <> (.name) r <> "' initial '" <> renderRegInitial ((.initial) r) <> "' is not a " <> expected <> " '" <> domain <> "'"
    regInitialBare r = case (.initial) r of
      RegInitBare value -> Just value
      RegInitText _ -> Nothing
    renderRegInitial = \case
      RegInitBare value -> value
      RegInitText value -> value

    -- Rule 1: declared-reference for command / emit / goto / source.
    declaredRefs =
      concatMap transitionRefs ((.transitions) agg)
    transitionRefs t =
      [ mkErr (locLine ((.loc) t)) UndeclaredCommand $
          "transition references undeclared command '" <> (.command) t <> "'"
      | not ((.command) t `Set.member` commandNames)
      ]
        ++ [ mkErr (locLine ((.loc) t)) UndeclaredState $
               "transition source '" <> (.source) t <> "' is not a declared state"
           | not ((.source) t `Set.member` states)
           ]
        ++ [ mkErr (locLine ((.loc) t)) UndeclaredState $
               "transition goto '" <> (.goto) t <> "' is not a declared state"
           | not ((.goto) t `Set.member` states)
           ]
        ++ [ mkErr (locLine ((.loc) t)) UndeclaredEvent $
               "emit references undeclared event '" <> ev <> "'"
           | ev <- (.emits) t,
             not (ev `Set.member` eventNames)
           ]

    -- Rule 2: reachability of every non-terminal state from the initial state
    -- (the first state in the list).
    reachability = case map (.name) ((.states) agg) of
      [] -> []
      (initial : _) ->
        let reached = bfs (Set.singleton initial) [initial]
         in [ mkErr (locLine ((.loc) s)) UnreachableState $
                "state '" <> (.name) s <> "' is not reachable from the initial state '" <> initial <> "'"
            | s <- (.states) agg,
              not ((.terminal) s),
              not ((.name) s `Set.member` reached)
            ]
    edgesFrom src = [(.goto) t | t <- (.transitions) agg, (.source) t == src]
    bfs seen [] = seen
    bfs seen (x : xs) =
      let nexts = [n | n <- edgesFrom x, not (n `Set.member` seen)]
       in bfs (foldr Set.insert seen nexts) (xs ++ nexts)

    -- Rule 3: a terminal state has no outgoing transition.
    terminalNoOutgoing =
      [ mkErr (locLine ((.loc) t)) TerminalHasOutgoing $
          "terminal state '" <> (.source) t <> "' has an outgoing transition"
      | t <- (.transitions) agg,
        (.source) t `Set.member` terminals
      ]

    -- Rule 4: every atom in a guard or write Expr resolves to a register, a
    -- field of the transition's command, an enum constructor, a rule, or a bool.
    guardScope = concatMap transitionScope ((.transitions) agg)
    transitionScope t =
      let inScope =
            registerNames
              `Set.union` Set.fromList (Map.findWithDefault [] ((.command) t) commandFields)
              `Set.union` enumCtorNames
              `Set.union` ruleNames
              -- State names are constructors of the implicit vertex enum, so a
              -- @write reservationState := Held@ references a state legitimately.
              `Set.union` states
          exprs = maybe [] pure ((.guard) t) ++ map snd ((.writes) t)
          badAtoms =
            [ n
            | e <- exprs,
              n <- exprNames e,
              not (n `Set.member` clockAtoms), -- clock atoms reported separately
              not (n `Set.member` inScope)
            ]
          badTargets = [target | (target, _) <- (.writes) t, target `Set.notMember` registerNames]
       in [ mkErr (locLine ((.loc) t)) WriteTargetNotRegister $
              "write target '" <> target <> "' is not a register of aggregate '" <> (.name) agg <> "'"
          | target <- dedup badTargets
          ]
            ++ [ mkErr (locLine ((.loc) t)) GuardAtomOutOfScope $
                   "atom '" <> n <> "' in transition '" <> (.source) t <> " -- " <> (.command) t <> "' resolves to no register, command field, enum constructor, or rule"
               | n <- dedup badAtoms
               ]

    -- Rule 5 (cross-cutting): no guard or write Expr samples a wall clock.
    clockFree = concatMap transitionClock ((.transitions) agg)
    transitionClock t =
      let exprs = maybe [] pure ((.guard) t) ++ map snd ((.writes) t)
          sampled = [n | e <- exprs, n <- exprNames e, n `Set.member` clockAtoms]
       in [ mkErr (locLine ((.loc) t)) ClockSampled $
              "transition '" <> (.source) t <> " -- " <> (.command) t <> "' samples the wall clock via '" <> n <> "'; time must be an injected input field, not sampled"
          | n <- dedup sampled
          ]

    -- EP-107: a projection references a first-class read model when one exists.
    -- Legacy standalone projections remain legal, but are surfaced as warnings.
    projectionKeyResolution =
      [ mkErr (locLine ((.loc) projection)) AggProjectionKeyUnresolved $
          "projection '" <> (.table) projection <> "' key '" <> (.key) projection <> "' is not a register, command field, or event field of aggregate '" <> (.name) agg <> "'"
      | enforcesSpecSurfaceClosures languageContract,
        Just projection <- [(.projection) agg],
        (.key) projection `Set.notMember` projectionFields
      ]
    projectionFields =
      registerNames
        `Set.union` Set.fromList [(.dslName) (resolveAggregateFieldIdentity field) | command <- (.commands) agg, field <- (.fields) command]
        `Set.union` Set.fromList [(.dslName) (resolveAggregateFieldIdentity field) | event <- (.events) agg, field <- eventFieldsFor event]

    projectionSafety = case (.projection) agg of
      Nothing -> []
      Just projection -> case [readModel | NReadModel readModel <- (.nodes) spec, (.name) readModel == (.table) projection] of
        [] ->
          [ mkErr (locLine ((.loc) projection)) RmStrongInlineOnly $
              "projection '" <> (.table) projection <> "' declares consistency = Strong but has no readmodel node; a standalone projection is inline-only and has no subscription cursor"
          | (.consistency) projection == Just Strong
          ]
            ++ [ Diagnostic
                   { line = locLine ((.loc) projection),
                     severity = Warning,
                     code = RmProjectionWithoutNode,
                     relatedLocations = [],
                     message = "projection '" <> (.table) projection <> "' has no readmodel node; registration, schema identity, consistency, and rebuild helpers are unavailable"
                   }
               ]
        (readModel : _) ->
          [ mkErr (locLine ((.loc) projection)) RmConsistencyConflict $
              "projection '" <> (.table) projection <> "' declares consistency " <> T.pack (show projectionConsistency) <> " but its readmodel node declares " <> T.pack (show readModelConsistency)
          | Just projectionConsistency <- [(.consistency) projection],
            Just readModelConsistency <- [legacyReadModelConsistency readModel],
            projectionConsistency /= readModelConsistency
          ]

    -- Rule 6 (hole-kind 3, mapping): keys are exact event names, never suffixes;
    -- duplicates and dangling keys are errors, and non-partial maps are total.
    statusMapTotality = case (.projection) agg of
      Nothing -> []
      Just p ->
        let evs = map (.name) ((.events) agg)
            pairs = maybe [] (.pairs) ((.statusMap) p)
            keys = map fst pairs
            partial = maybe False (.partial) ((.statusMap) p)
            uncovered = [event | event <- evs, event `notElem` keys]
            dangling = [key | key <- keys, key `notElem` evs]
            duplicateKeys = map fst (duplicatesBy fst pairs)
         in [ mkErr (locLine ((.loc) p)) StatusMapDanglingKey $
                "projection '" <> (.table) p <> "' status-map key '" <> key <> "' is not an event name of aggregate '" <> (.name) agg <> "'"
            | key <- dangling
            ]
              ++ [ mkErr (locLine ((.loc) p)) StatusMapDuplicateKey $
                     "projection '" <> (.table) p <> "' repeats status-map key '" <> key <> "'"
                 | key <- duplicateKeys
                 ]
              ++ [ mkErr (locLine ((.loc) p)) StatusMapNotTotal $
                     "projection '" <> (.table) p <> "' status-map is not total over events {" <> T.intercalate ", " uncovered <> "}"
                 | not partial,
                   not (null evs),
                   not (null uncovered)
                 ]

    -- EP-2 evolution rules (single-spec; the diff path adds the cross-spec ones).
    evolutionRules =
      versionUpcasterRule
        ++ upcasterChainGapRule
        ++ deprecatedEmitRule
        ++ eventRetirementRules
        ++ wireVersionRule
    -- Only live transitions are the write path: a replay-only transition can
    -- never fire forward, so its emits exist purely to invert stored events —
    -- which is exactly where a deprecated event is allowed to remain
    -- (plan 143; supersedes the guarded-but-inert retained-edge pattern).
    liveEmittedNames = Set.fromList (concatMap (.emits) [t | t <- (.transitions) agg, (.mode) t == TmLive])
    replayEmittedNames = Set.fromList (concatMap (.emits) [t | t <- (.transitions) agg, (.mode) t == TmReplayOnly])
    maxEventVersion = maximum (1 : map (.version) ((.events) agg))
    upcasterSources =
      Set.fromList
        [ source
        | event <- (.events) agg,
          Just (source, _) <- [(.upcastFrom) event]
        ]

    -- A non-initial event version must carry a contiguous upcaster (from v-1).
    versionUpcasterRule =
      [ mkErr (locLine ((.loc) e)) EvtVersionMissingUpcaster $
          "event '" <> (.name) e <> "' version " <> tInt ((.version) e) <> " has no 'upcast from v" <> tInt ((.version) e - 1) <> "' clause"
      | e <- (.events) agg,
        (.version) e > 1,
        maybe True ((/= (.version) e - 1) . fst) ((.upcastFrom) e)
      ]

    -- Aggregate schema stamps are global, so every source version below the
    -- current maximum needs a permanent rung regardless of which event owns it.
    upcasterChainGapRule =
      [ mkErr (locLine ((.loc) agg)) UpcasterChainGap $
          "no event declares 'upcast from v"
            <> tInt missing
            <> "'; stored payloads stamped v"
            <> tInt missing
            <> " can never reach v"
            <> tInt maxEventVersion
            <> " (GapInUpcasterChain at hydration). A rung, once shipped, must exist forever — restore the upcaster for v"
            <> tInt missing
            <> " (re-declare it on the event whose shape changed at v"
            <> tInt (missing + 1)
            <> ")"
      | missing <- [1 .. maxEventVersion - 1],
        missing `Set.notMember` upcasterSources
      ]

    -- A deprecated event must have left the write path.
    deprecatedEmitRule =
      [ mkErr (locLine ((.loc) e)) DeprecatedEventStillEmitted $
          "deprecated event '" <> (.name) e <> "' is still emitted by a transition"
      | e <- (.events) agg,
        (.deprecated) e,
        (.name) e `Set.member` liveEmittedNames
      ]

    -- Retirement is a two-stage protocol. The pre-cutover marker keeps a live
    -- emitter. The deprecated stage removes that live emitter but retains a
    -- replay-only emitter until old payloads no longer need hydration.
    eventRetirementRules = concatMap eventRetirementRule ((.events) agg)
    eventRetirementRule event
      | (.retiring) event =
          [ mkErr (locLine ((.loc) event)) EventRetirementInProgress $
              "retiring event '" <> (.name) event <> "' has no live emitting transition; keep it emitting while streams are terminalized or truncated, or cut over to 'deprecated event' with a replay-only emitting transition"
          | (.name) event `Set.notMember` liveEmittedNames
          ]
            ++ [ Diagnostic
                   { line = locLine ((.loc) event),
                     severity = Warning,
                     code = EventRetirementInProgress,
                     relatedLocations = [],
                     message =
                       "event '" <> (.name) event <> "' is retiring: it stays fully live and replayable. Keep its live emitting transition until every affected stream is terminal or truncated; then flip it to 'deprecated event' and retain an equivalent replay-only emitting transition for as long as old payloads may be hydrated"
                   }
               | (.name) event `Set.member` liveEmittedNames
               ]
      | (.deprecated) event =
          [ Diagnostic
              { line = locLine ((.loc) event),
                severity = Warning,
                code = DeprecatedEventReplayHazard,
                relatedLocations = [],
                message =
                  "deprecated event '" <> (.name) event <> "' stays decodable but is not replayable: no replay-only transition emits it, so hydration of a live stream containing it fails with HydrationNoInvertingEdge. Restore an equivalent replay-only emitting transition, or terminalize/truncate every affected stream before deployment"
              }
          | any (not . (.terminal)) ((.states) agg),
            (.name) event `Set.notMember` replayEmittedNames
          ]
            ++ [ Diagnostic
                   { line = locLine ((.loc) event),
                     severity = Warning,
                     code = EventRetirementInProgress,
                     relatedLocations = [],
                     message =
                       "deprecated event '" <> (.name) event <> "' is off the live write path and remains replayable through a replay-only transition; retain that transition until every stream containing the event is terminal, truncated, or passes the replay audit"
                   }
               | (.name) event `Set.member` replayEmittedNames
               ]
      | otherwise = []

    -- The explicit `wire schemaVersion=` (if any) must equal the max event version.
    wireVersionRule = case (.wire) agg of
      Just w
        | (.schemaVersion) w /= maxEventVersion ->
            [ Diagnostic
                { line = locLine ((.loc) agg),
                  severity = Warning,
                  code = WireSchemaVersionMismatch,
                  relatedLocations = [],
                  message =
                    "wire schemaVersion=" <> tInt ((.schemaVersion) w) <> " does not match the maximum event version " <> tInt maxEventVersion
                }
            ]
      _ -> []

    -- Plan 143: replay-only transition discipline. A replay-only transition
    -- exists to invert stored events, so one that emits nothing is dead
    -- weight (error); one whose (source, command) pair has no live sibling
    -- means the command is fully retired at that state — legitimate, but the
    -- fuller procedure is event retirement (docs/plans/139), so warn.
    replayOnlyRules = concatMap replayOnlyRule ((.transitions) agg)
    replayOnlyRule t
      | (.mode) t /= TmReplayOnly = []
      | otherwise =
          [ mkErr (locLine ((.loc) t)) ReplayOnlyEmitsNothing $
              "replay-only transition '" <> (.source) t <> " -- " <> (.command) t <> "' emits no event; a replay-only transition exists to invert stored events and is dead weight without an emit"
          | null ((.emits) t)
          ]
            ++ [ Diagnostic
                   { line = locLine ((.loc) t),
                     severity = Warning,
                     code = ReplayOnlyCommandStillLive,
                     relatedLocations = [],
                     message =
                       "replay-only transition '" <> (.source) t <> " -- " <> (.command) t <> "' has no live sibling; command '" <> (.command) t <> "' is fully retired at state '" <> (.source) t <> "' — if the intent is to retire its events too, follow the event-retirement procedure (docs/plans/139)"
                   }
               | not (any (\sibling -> (.mode) sibling == TmLive && (.source) sibling == (.source) t && (.command) sibling == (.command) t) ((.transitions) agg))
               ]

    eventlessStateChangeRules =
      [ mkErr (locLine ((.loc) transition)) AggregateEventlessStateChange $
          "transition '"
            <> (.source) transition
            <> " -- "
            <> (.command) transition
            <> "' emits no event but changes "
            <> changeDescription transition
            <> "; event-sourced state changes require persisted evidence, while a no-op must keep both vertex and registers unchanged"
      | transition <- (.transitions) agg,
        null ((.emits) transition),
        (.source) transition /= (.goto) transition || not (null ((.writes) transition))
      ]
    changeDescription transition
      | (.source) transition /= (.goto) transition && not (null ((.writes) transition)) = "the target vertex and registers"
      | (.source) transition /= (.goto) transition = "the target vertex"
      | otherwise = "registers"

    domainOutcomeRules =
      declarationRules
        ++ concatMap transitionOutcomeRules ((.transitions) agg)
      where
        declarationRules =
          [ mkErr (locLine loc) DomainOutcomeDeclarationDuplicate $
              "aggregate '" <> (.name) agg <> "' declares domain-outcomes more than once"
          | loc <- (.domainOutcomeDuplicateLocs) agg
          ]
            ++ case (.domainOutcomeTypes) agg of
              Nothing ->
                [ mkErr (locLine (transitionOutcomeLoc outcome)) DomainOutcomeDeclarationMissing $
                    "transition '" <> (.source) transition <> " -- " <> (.command) transition <> "' declares an outcome but aggregate '" <> (.name) agg <> "' has no domain-outcomes declaration"
                | transition <- (.transitions) agg,
                  Just outcome <- [(.outcome) transition]
                ]
              Just _ -> []

        transitionOutcomeRules transition =
          [ mkErr (locLine loc) DomainOutcomeClauseDuplicate $
              "transition '" <> (.source) transition <> " -- " <> (.command) transition <> "' declares outcome more than once"
          | loc <- (.outcomeDuplicateLocs) transition
          ]
            ++ case ((.domainOutcomeTypes) agg, (.mode) transition, (.outcome) transition) of
              (Just _, TmLive, Nothing) ->
                [ mkErr (locLine ((.loc) transition)) DomainOutcomeClauseMissing $
                    "live transition '" <> (.source) transition <> " -- " <> (.command) transition <> "' is missing its required outcome clause"
                ]
              (Just _, TmReplayOnly, Just outcome) ->
                [ mkErr (locLine (transitionOutcomeLoc outcome)) DomainOutcomeReplayOnlyClause $
                    "replay-only transition '" <> (.source) transition <> " -- " <> (.command) transition <> "' cannot declare a forward command outcome"
                ]
              (Just _, TmLive, Just (OutcomeAccepted loc)) ->
                [ mkErr (locLine loc) DomainOutcomeAcceptedWithoutEvents $
                    "accepted transition '" <> (.source) transition <> " -- " <> (.command) transition <> "' must emit at least one event"
                | null ((.emits) transition)
                ]
              (Just _, TmLive, Just outcome@OutcomeRejected {}) -> silentRules outcome
              (Just _, TmLive, Just outcome@OutcomeNoOp {}) -> silentRules outcome
              _ -> []
          where
            silentRules outcome =
              [ mkErr (locLine (transitionOutcomeLoc outcome)) DomainOutcomeSilentEmits $
                  "silent transition '" <> (.source) transition <> " -- " <> (.command) transition <> "' cannot emit events"
              | not (null ((.emits) transition))
              ]
                ++ [ mkErr (locLine (transitionOutcomeLoc outcome)) DomainOutcomeSilentWrites $
                       "silent transition '" <> (.source) transition <> " -- " <> (.command) transition <> "' cannot write aggregate registers"
                   | not (null ((.writes) transition))
                   ]
                ++ [ mkErr (locLine (transitionOutcomeLoc outcome)) DomainOutcomeSilentStateChange $
                       "silent transition '" <> (.source) transition <> " -- " <> (.command) transition <> "' must preserve its source state"
                   | (.goto) transition /= (.source) transition
                   ]

-- | The validator's re-derivation of the live
-- 'Keiro.PGMQ.Runtime.queueRef' trio: physical queue, dead-letter queue, and
-- PGMQ backing table. Parity is pinned by the queue-runtime conformance suite.
derivedQueueTrio :: Text -> (Text, Text, Text)
derivedQueueTrio logical = (physical, physical <> "_dlq", "pgmq.q_" <> physical)
  where
    physical = physicalBase logical

physicalBase :: Text -> Text
physicalBase logical
  | T.length base <= 43 && not ("_dlq" `T.isSuffixOf` base) = base
  | otherwise = hashedBase logical base
  where
    base = sanitizeQueueName logical

sanitizeQueueName :: Text -> Text
sanitizeQueueName =
  ensureLeadingLetter
    . T.intercalate "_"
    . filter (not . T.null)
    . T.splitOn "_"
    . T.map toLegal
    . T.toLower
  where
    toLegal c
      | (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' = c
      | otherwise = '_'
    ensureLeadingLetter value = case T.uncons value of
      Nothing -> "q"
      Just (c, _)
        | c >= 'a' && c <= 'z' -> value
        | otherwise -> T.cons 'q' value

hashedBase :: Text -> Text -> Text
hashedBase logical base = prefix <> "_" <> fnv1a64Hex logical
  where
    trimmedPrefix = T.dropWhileEnd (== '_') (T.take 26 base)
    prefix
      | T.null trimmedPrefix = "q"
      | otherwise = trimmedPrefix

fnv1a64Hex :: Text -> Text
fnv1a64Hex logical = T.pack (replicate (16 - length rendered) '0' <> rendered)
  where
    rendered = showHex (T.foldl' step offset logical) ""
    offset :: Word64
    offset = 0xcbf29ce484222325
    prime :: Word64
    prime = 0x100000001b3
    step hash character = (hash `xor` fromIntegral (ord character)) * prime

tInt :: Int -> Text
tInt = T.pack . show

mkErr :: Int -> DiagnosticCode -> Text -> Diagnostic
mkErr l c m = Diagnostic {line = l, severity = Error, code = c, relatedLocations = [], message = m}

-- | A dispatch disposition as the author spelled it.
dispText :: Disp -> Text
dispText DAckOk = "AckOk"
dispText DRetry = "Retry"
dispText (DDeadLetter reason) = "DeadLetter " <> T.pack (show reason)

-- | A spec surface the grammar accepts but no runtime implements.
--
-- Released languages below 4 keep their acceptance and only warn, so an
-- existing source does not stop checking when it is pinned to an older
-- language. From language 4 — which promised strict spec-surface validation —
-- the same sentence is an error. The message never changes with the severity, so
-- an author reads one explanation before and after the tightening.
mkSurfaceRefusal :: EffectiveLanguageContract -> Int -> DiagnosticCode -> Text -> Diagnostic
mkSurfaceRefusal languageContract l c m =
  Diagnostic
    { line = l,
      severity = if enforcesSpecSurfaceClosures languageContract then Error else Warning,
      code = c,
      relatedLocations = [],
      message = m
    }

wireKeyRulesForRecord :: Text -> Maybe (Text, Text) -> [ResolvedFieldIdentity] -> [Diagnostic]
wireKeyRulesForRecord owner reservedKey fields = invalidKeys <> duplicateKeys <> reservedCollisions
  where
    -- Structural safety only. An alias exists to preserve a brownfield key that
    -- the current naming convention would reject, so checking alias *style*
    -- would defeat the feature. What is checked is that the key can be a key at
    -- all: a stray space or control character in `as "family "` ships a
    -- permanently mis-keyed public field that no later rename can fix without a
    -- wire break. See ADR 0021.
    invalidKeys = concatMap invalidKeyRule fields
    invalidKeyRule field
      | T.null key = [refuse "resolves to an empty wire key"]
      | key /= T.strip key =
          [ refuse
              ( "resolves to wire key "
                  <> T.pack (show key)
                  <> ", which has leading or trailing whitespace; the wire key is the exact bytes on the wire, so the surrounding space would be part of every encoded field name"
              )
          ]
      | Just offending <- firstMatching isControl (T.unpack key) =
          [ refuse
              ( "resolves to wire key "
                  <> T.pack (show key)
                  <> ", which contains the control character U+"
                  <> T.justifyRight 4 '0' (T.toUpper (T.pack (showHex (ord offending) "")))
              )
          ]
      | otherwise = []
      where
        key = (.wireKey) field
        refuse detail =
          mkErr (locLine ((.loc) field)) FieldWireKeyInvalid $
            owner <> " field '" <> (.dslName) field <> "' " <> detail
    duplicateKeys =
      [ Diagnostic
          { line = locLine ((.loc) field),
            severity = Error,
            code = FieldWireKeyCollision,
            relatedLocations = [(locLine ((.loc) earlier), "wire key '" <> (.wireKey) field <> "' is first declared here")],
            message = owner <> " fields resolve to duplicate wire key '" <> (.wireKey) field <> "'"
          }
      | (index, field) <- zip [0 :: Int ..] fields,
        earlier : _ <- [[candidate | candidate <- take index fields, (.wireKey) candidate == (.wireKey) field]]
      ]
    reservedCollisions =
      [ mkErr (locLine ((.loc) field)) FieldWireKeyCollision $
          owner
            <> " field '"
            <> (.dslName) field
            <> "' resolves to wire key '"
            <> key
            <> "', which collides with the "
            <> description
      | Just (key, description) <- [reservedKey],
        field <- fields,
        (.wireKey) field == key
      ]

locLine :: Loc -> Int
locLine = unLoc

-- | The 'AName' atom names occurring anywhere in an expression.
exprNames :: Expr -> [Name]
exprNames (EOr a b) = exprNames a ++ exprNames b
exprNames (EAnd a b) = exprNames a ++ exprNames b
exprNames (ECmp _ a b) = exprNames a ++ exprNames b
exprNames (EAdd _ a b) = exprNames a ++ exprNames b
exprNames (ESubtract _ a b) = exprNames a ++ exprNames b
exprNames (EMultiply _ a b) = exprNames a ++ exprNames b
exprNames (EPath _ _ (name : _)) = [name]
exprNames (EPath _ _ []) = []
exprNames ELiteral {} = []
exprNames (EAtom (AName n)) = [n]
exprNames (EAtom (ABool _)) = []

dedup :: (Ord a) => [a] -> [a]
dedup = Set.toList . Set.fromList

-- | Keep each occurrence after the first for a chosen key. Diagnostics are
-- anchored on the shadowing declaration rather than the declaration it shadows.
duplicatesBy :: (Eq key) => (a -> key) -> [a] -> [a]
duplicatesBy key xs =
  [ x
  | (index, x) <- zip [0 :: Int ..] xs,
    key x `elem` map key (take index xs)
  ]

-- | Return every source-ordered group whose selected key occurs at least
-- twice. New diagnostics that describe a relationship use this helper; the
-- older 'duplicatesBy' contract remains first-shadow only.
duplicateGroupsBy :: (Ord key) => (a -> key) -> [a] -> [[a]]
duplicateGroupsBy key values =
  filter ((> 1) . length) . Map.elems $
    Map.fromListWith (flip (<>)) [(key value, [value]) | value <- values]
