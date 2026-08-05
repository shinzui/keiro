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
    validateService,
    validateSpec,
    derivedQueueTrio,
    sagaCategoryError,
    nodeIdentity,
  )
where

import Data.Bits (xor)
import Data.Char (isControl, isSpace, ord)
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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
import Keiro.Dsl.ReadModelShape (deriveShapeHash)
import Keiro.Dsl.RuntimePackage (isCabalPackageName)
import Keiro.Dsl.SemanticContract (CheckedService (..), EffectiveLanguageContract, effectiveRuntimeProfile, legacyCheckedService)
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
  | -- EP-107 diff-only read-model evolution rules.
    ReadModelVersionDecreased
  | ReadModelShapeChangedWithoutBump
  | ReadModelFeedChanged
  | ReadModelConsistencyWeakened
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
  | ConformanceFactKeyCollision
  | GeneratedPlanningInvariantViolation
  | -- ExecPlan 197: accepted but currently inert spec surfaces are reported
    -- through the ordinary warning pipeline.
    IntakeBindFlagUnenforced
  | WqFieldOptionalUnsupported
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
        <> T.pack (show (line d))
        <> ": "
        <> sev
        <> "["
        <> T.pack (show (code d))
        <> "]: "
        <> message d
    notes =
      [ "  " <> T.pack file <> ":" <> T.pack (show noteLine) <> ": note: " <> note
      | (noteLine, note) <- relatedLocations d
      ]
    sev = case severity d of Error -> "error"; Warning -> "warning"

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
validateService service = validateCheckedSpec (checkedLanguageContract service) (checkedSpec service)

-- | Compatibility wrapper for callers that have only a normalized graph. It
-- explicitly selects legacy/version-1 semantics; production source/workspace
-- routes use 'validateService'.
validateSpec :: Spec -> [Diagnostic]
validateSpec = validateService . legacyCheckedService

validateCheckedSpec :: EffectiveLanguageContract -> Spec -> [Diagnostic]
validateCheckedSpec languageContract spec =
  sortOn line (validateNames languageContract spec ++ validateMapped spec ++ validateNominal languageContract spec ++ validateAggregateTypes spec ++ specLevelRules languageContract spec ++ concatMap (validateNode languageContract spec) (specNodes spec))

-- | Rules added before language 4 ships consult the effective semantic
-- contract, not the numeric source spelling. Versions 1 through 3 retain their
-- released acceptance; runtime semantics 3 is the unreleased tightening gate.
enforcesSpecSurfaceClosures :: EffectiveLanguageContract -> Bool
enforcesSpecSurfaceClosures languageContract =
  runtimeProfileHasCapability (effectiveRuntimeProfile languageContract) StrictSpecSurfaceValidation

validateNominal :: EffectiveLanguageContract -> Spec -> [Diagnostic]
validateNominal languageContract spec = domainErrors <> resolutionErrors
  where
    domainErrors =
      [ mkErr (locLine (idLoc declaration)) NominalInvalidIdPrefix $
          "id '" <> idName declaration <> "' has invalid TypeID prefix '" <> idPrefix declaration <> "': " <> T.pack (show reason)
      | declaration <- specIds spec,
        Just _ <- [idDomainContractFor languageContract (idPrefix declaration)],
        Just reason <- [TypeID.checkPrefix (idPrefix declaration)]
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
validateAggregateTypes :: Spec -> [Diagnostic]
validateAggregateTypes spec = case Nominal.resolveNominalTypes spec of
  Left _ -> []
  Right _ -> concatMap aggregateRules aggregates
  where
    symbols = aggregateSymbols spec
    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]

    aggregateRules aggregate =
      concatMap commandRules (aggCommands aggregate)
        ++ concatMap eventRules (aggEvents aggregate)
        ++ concatMap registerRules (aggRegs aggregate)
        ++ concatMap (transitionRules aggregate) (aggTransitions aggregate)
      where
        commandRules command = concatMap (fieldRule aggregate CommandFieldUse) (cmdFields command)
        eventRules event = case evBody event of
          EventFields fields -> concatMap (fieldRule aggregate EventFieldUse) fields
          EventFromCommand _ -> []
        registerRules register = case resolveAggregateType symbols (regLoc register) RegisterUse (regType register) of
          Left typeError -> [aggregateTypeDiagnostic typeError]
          Right AggregateMapped {} -> []
          Right resolved -> case resolveRegisterInitial symbols (regLoc register) resolved (regInitial register) of
            Left initialError -> [aggregateTypeDiagnostic initialError]
            Right _ -> []

    fieldRule aggregate useSite field =
      either (pure . aggregateTypeDiagnostic) (const []) (inferAggregateFieldType symbols aggregate useSite field)

    transitionRules aggregate transition = case tImplementation transition of
      LegacyHoleImplementation ->
        concatMap (comparisonRule aggregate transition) (maybe [] comparisons (tGuard transition))
      GeneratedImplementation ->
        let environment = expressionEnvironment spec aggregate transition
         in maybe [] (expressionDiagnostics . resolveGuardExpr environment) (tGuard transition)
              ++ concatMap (expressionDiagnostics . uncurry (resolveWriteExpr environment)) (tWrites transition)
      HoleImplementation ->
        [ mkErr (locLine (tLoc transition)) AggregateTransitionOwnershipConflict $
            "transition '"
              <> tSource transition
              <> " -- "
              <> tCommand transition
              <> "' selects implementation hole and therefore cannot also declare guard or write clauses"
        | tGuard transition /= Nothing || not (null (tWrites transition))
        ]

    expressionDiagnostics = either (map expressionDiagnostic . NE.toList) (const [])

    expressionDiagnostic diagnostic =
      mkErr
        (locLine (expressionDiagnosticLoc diagnostic))
        (expressionCode (expressionDiagnosticCode diagnostic))
        (expressionDiagnosticMessage diagnostic)

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
              [ mkErr (locLine (tLoc transition)) AggregateGuardTypeMismatch $
                  "comparison operands have different aggregate types '"
                    <> aggregateCanonicalName leftType
                    <> "' and '"
                    <> aggregateCanonicalName rightType
                    <> "'"
              ]
          | aggregateCapability useSite leftType == Unsupported ->
              [ mkErr (locLine (tLoc transition)) AggregateGuardCapabilityUnsupported $
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

    atomType aggregate transition name = case [register | register <- aggRegs aggregate, regName register == name] of
      register : _ -> resolveAggregateType symbols (regLoc register) RegisterUse (regType register)
      [] -> case [field | command <- aggCommands aggregate, cmdName command == tCommand transition, field <- cmdFields command, aggregateFieldName field == name] of
        field : _ -> inferAggregateFieldType symbols aggregate CommandFieldUse field
        [] -> case [enumName declaration | declaration <- specEnums spec, name `elem` map fst (enumCtors declaration)] of
          enumType : _ -> resolveAggregateType symbols (tLoc transition) CommandFieldUse (TRef enumType)
          []
            | name `elem` map stName (aggStates aggregate) -> pure (AggregateVertex (aggName aggregate <> "Vertex"))
            | Just rule <- firstMatching ((== name) . ruleName) (specRules spec) ->
                resolveAggregateType symbols (ruleLoc rule) EqualityGuardUse (nameTypeExpr (ruleCodomain rule))
            | otherwise -> Left (AggregateTypeError (tLoc transition) EqualityGuardUse (UnknownAggregateType name))

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
  mkErr (locLine (aggregateTypeErrorLoc aggregateError)) diagnosticCode diagnosticMessage
  where
    diagnosticCode = case aggregateTypeErrorReason aggregateError of
      UnknownAggregateType {} -> AggregateTypeUnknown
      UnsupportedAggregateShape {} -> AggregateTypeUnsupportedAtUse
      UnsupportedAggregateCapability {} -> case aggregateTypeErrorUseSite aggregateError of
        EqualityGuardUse -> AggregateGuardCapabilityUnsupported
        OrderingGuardUse -> AggregateGuardCapabilityUnsupported
        _ -> AggregateTypeUnsupportedAtUse
      InvalidRegisterInitial {} -> AggregateRegisterInitialInvalid
    diagnosticMessage = case aggregateTypeErrorReason aggregateError of
      UnknownAggregateType name ->
        "unknown aggregate type '" <> name <> "' at " <> renderAggregateUseSite (aggregateTypeErrorUseSite aggregateError)
      UnsupportedAggregateShape expression ->
        "direct aggregate type '"
          <> typeExprCanonicalName expression
          <> "' is unsupported at "
          <> renderAggregateUseSite (aggregateTypeErrorUseSite aggregateError)
          <> "; use a mapped structural declaration for Json or container shapes"
      UnsupportedAggregateCapability resolved ->
        renderAggregateUseSite (aggregateTypeErrorUseSite aggregateError)
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
validateMapped :: Spec -> [Diagnostic]
validateMapped spec =
  mappedLexicalRules spec
    ++ mappedIdentityRules spec
    ++ mappedConflictRules spec
    ++ case resolveTypeGraph spec of
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
  maybe 1 (locLine . mappedLoc) (firstMatching ((== name) . mappedName) (specMapped spec))

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
mappedLexicalRules spec = concatMap declarationRules (specMapped spec)
  where
    declarationRules declaration =
      constructorRule "mapped declaration name" (mappedName declaration) declaration
        ++ maybe [] (haskellRules declaration) (mappedHaskell declaration)
        ++ qualifiedFacts declaration
        ++ shapeConstructorRules declaration

    haskellRules declaration source =
      [ invalid declaration $ "Haskell package '" <> hsPackage source <> "' does not follow Cabal package-name grammar"
      | not (isCabalPackageName (hsPackage source))
      ]
        ++ [ invalid declaration $ "Haskell module '" <> hsModule source <> "' must be dot-separated Upper identifiers"
           | not (moduleNameSafe (hsModule source))
           ]
        ++ [ invalid declaration $ "Haskell type '" <> hsType source <> "' must be an Upper identifier"
           | not (constructorSafe (hsType source))
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
          ++ [ invalidAt (wireFieldLoc field) $ "record selector '" <> wfHaskell field <> "' must be a lower-initial Haskell identifier"
             | field <- fields,
               not (lowerIdentifierSafe (wfHaskell field))
             ]
      MappedStructural {msShape = ShapeEnum entries} ->
        [ invalidAt (weLoc entry) $ "enum constructor '" <> weCtor entry <> "' must be an Upper identifier"
        | entry <- entries,
          not (constructorSafe (weCtor entry))
        ]
      MappedStructural {msShape = ShapeUnion _ arms} ->
        [ invalidAt (waLoc arm) $ "union constructor '" <> waCtor arm <> "' must be an Upper identifier"
        | arm <- arms,
          not (constructorSafe (waCtor arm))
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
  | declaration <- specMapped spec,
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
    declarations = specMapped spec
    sourceFacts = [(declaration, source) | declaration <- declarations, source <- maybeToList (mappedHaskell declaration)]
    sourceCollisions =
      [ conflict declaration $
          "Haskell target '" <> hsModule source <> "." <> hsType source <> "' is claimed by more than one mapped declaration"
      | (declaration, source) <- duplicatesBy (\(_, value) -> (hsModule value, hsType value)) sourceFacts
      ]
    canonicalFacts = [(declaration, canonical) | declaration <- declarations, canonical <- maybeToList (mappedCanonical declaration), not (T.null canonical)]
    canonicalCollisions =
      [ conflict declaration $ "canonical-type '" <> canonical <> "' is claimed by more than one mapped declaration"
      | (declaration, canonical) <- duplicatesBy snd canonicalFacts
      ]
    moduleFacts = [(declaration, hsModule source, hsPackage source) | (declaration, source) <- sourceFacts]
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
  concatMap declarationRules (Map.elems (tgDeclarations graph))
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
            [ mappedError (rwfLoc field) MappedDuplicateFieldName declaration $
                "record selector '" <> rwfHaskell field <> "' is declared more than once"
            | field <- duplicatesBy rwfHaskell fields
            ]
              ++ [ mappedError (rwfLoc field) MappedDuplicateWireKey declaration $
                     "record wire key '" <> rwfKey field <> "' is declared more than once"
                 | field <- duplicatesBy rwfKey fields
                 ]
              ++ [ mappedError (rwfLoc field) MappedUnsupportedEncoding declaration "record wire keys must be non-empty"
                 | field <- fields,
                   T.null (rwfKey field)
                 ]
              ++ concatMap (fieldRules declaration) fields,
          onEnum = \entries ->
            [ mappedError (weLoc entry) MappedDuplicateArmName declaration $
                "enum constructor '" <> weCtor entry <> "' is declared more than once"
            | entry <- duplicatesBy weCtor entries
            ]
              ++ [ mappedError (weLoc entry) MappedDuplicateWireTag declaration $
                     "enum wire spelling '" <> weTag entry <> "' is declared more than once"
                 | entry <- duplicatesBy weTag entries
                 ]
              ++ [ mappedError (weLoc entry) MappedUnsupportedEncoding declaration "enum wire spellings must be non-empty"
                 | entry <- entries,
                   T.null (weTag entry)
                 ],
          onUnion = \encoding arms ->
            [ mappedError (sdLoc declaration) MappedUnsupportedEncoding declaration "tagged-object tag and contents keys must be distinct"
            | ueTagField encoding == ueContentsField encoding
            ]
              ++ [ mappedError (sdLoc declaration) MappedUnsupportedEncoding declaration "tagged-object tag and contents keys must be non-empty"
                 | T.null (ueTagField encoding) || T.null (ueContentsField encoding)
                 ]
              ++ [ mappedError (rwaLoc arm) MappedDuplicateArmName declaration $
                     "union constructor '" <> rwaCtor arm <> "' is declared more than once"
                 | arm <- duplicatesBy rwaCtor arms
                 ]
              ++ [ mappedError (rwaLoc arm) MappedDuplicateWireTag declaration $
                     "union wire tag '" <> rwaTag arm <> "' is declared more than once"
                 | arm <- duplicatesBy rwaTag arms
                 ]
              ++ [ mappedError (rwaLoc arm) MappedUnsupportedEncoding declaration "union wire tags must be non-empty"
                 | arm <- arms,
                   T.null (rwaTag arm)
                 ]
              ++ concatMap (armRules declaration) arms
        }

    fieldRules declaration field =
      defaultRules declaration field
        ++ [ mappedError (rwfLoc field) MappedNonInjectiveNullability declaration $
               "field '" <> rwfHaskell field <> "' contains Optional around a null-capable Json, Optional, or opaque mapped value"
           | hasNonInjectiveOptional graph (rwfType field)
           ]

    armRules declaration arm =
      [ mappedError (rwaLoc arm) MappedNonInjectiveNullability declaration $
          "union arm '" <> rwaCtor arm <> "' contains Optional around a null-capable Json, Optional, or opaque mapped value"
      | payload <- maybeToList (rwaPayload arm),
        hasNonInjectiveOptional graph payload
      ]

    defaultRules declaration field = case (rwfPresence field, rwfOnMissing field) of
      (PRequired, Just _) -> [illTyped "required fields cannot declare on-missing"]
      (POptional, Nothing) ->
        [ mappedError (rwfLoc field) MappedMissingIngredient declaration $
            "optional field '" <> rwfHaskell field <> "' is missing its on-missing policy"
        ]
      (POptional, Just value)
        | not (defaultMatches graph (rwfType field) value) -> [illTyped "on-missing value does not match the field type or numeric bounds"]
      _ -> []
      where
        illTyped detail =
          mappedError (rwfLoc field) MappedDefaultIllTyped declaration $
            "field '" <> rwfHaskell field <> "': " <> detail

    mappedError loc diagnosticCode declaration detail =
      mkErr (locLine loc) diagnosticCode $
        "mapped declaration '" <> sdName declaration <> "' " <> detail
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
referencedDefaultType graph key = case Map.lookup key (tgDeclarations graph) of
  Nothing -> DefaultOther
  Just declaration ->
    foldMappedDecl
      MappedDeclAlgebra
        { onStructuralDecl = \_ shape ->
            foldMappedShape
              MappedShapeAlgebra
                { onRecord = \_ _ _ -> DefaultOther,
                  onEnum = DefaultEnum . Set.fromList . map weCtor,
                  onUnion = \_ _ -> DefaultOther
                }
              shape,
          onOpaqueDecl = const DefaultOther
        }
      declaration

data NullabilityFacts = NullabilityFacts
  { nfTopNull :: !Bool,
    nfBadOptional :: !Bool
  }

hasNonInjectiveOptional :: TypeGraph -> ResolvedTypeExpr -> Bool
hasNonInjectiveOptional graph =
  nfBadOptional
    . foldTypeExpr
      TypeExprAlgebra
        { onText = nonNull,
          onInt = nonNull,
          onInteger = nonNull,
          onBool = nonNull,
          onNatural = nonNull,
          onTime = nonNull,
          onJson = nullable,
          onOptional = \child -> NullabilityFacts True (nfTopNull child || nfBadOptional child),
          onList = nestedNonNull,
          onMap = nestedNonNull,
          onRef = \key -> if mappedRefIsOpaque graph key then nullable else nonNull
        }
  where
    nonNull = NullabilityFacts False False
    nullable = NullabilityFacts True False
    nestedNonNull child = NullabilityFacts False (nfBadOptional child)

mappedRefIsOpaque :: TypeGraph -> MappedKey -> Bool
mappedRefIsOpaque graph key = case Map.lookup key (tgDeclarations graph) of
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
  concatMap aggregateRules [aggregate | NAggregate aggregate <- specNodes spec]
  where
    aggregateRules aggregate = concatMap registerRule (aggRegs aggregate)
    registerRule register = case regType register of
      TRef typeName -> case Map.lookup (MappedKey typeName) (tgDeclarations graph) of
        Nothing -> []
        Just declaration -> case regInitial register of
          RegInitBare "initial"
            | mappedInitial declaration == Nothing ->
                [ mkErr (locLine (regLoc register)) MappedMissingInitialValue $
                    "mapped register '" <> regName register <> "' requires declaration '" <> typeName <> "' to name an explicit initial value"
                ]
            | otherwise -> []
          _ ->
            [ mkErr (locLine (regLoc register)) RegisterInitialOutOfScope $
                "mapped register '" <> regName register <> "' must use the bare initial token; the declaration-owned symbol is verified by GHC"
            ]
      _ -> []
    mappedInitial =
      foldMappedDecl
        MappedDeclAlgebra
          { onStructuralDecl = \declaration _ -> sdInitial declaration,
            onOpaqueDecl = odInitial
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
validateNames :: EffectiveLanguageContract -> Spec -> [Diagnostic]
validateNames languageContract spec =
  concat
    [ concatMap idNames (specIds spec),
      concatMap enumNames (specEnums spec),
      concatMap nominalNames (specNominalScalars spec),
      concatMap nodeNames (specNodes spec),
      normalizedCollisions
    ]
  where
    idNames declaration =
      constructorName "id name" (idName declaration) (idLoc declaration)

    enumNames declaration =
      constructorName "enum name" (enumName declaration) (enumLoc declaration)
        ++ concatMap
          (\(ctor, _) -> constructorName ("constructor of enum '" <> enumName declaration <> "'") ctor (enumLoc declaration))
          (enumCtors declaration)

    nominalNames declaration =
      constructorName "nominal scalar name" (nominalScalarName declaration) (nominalScalarLoc declaration)

    nodeNames = \case
      NAggregate aggregate -> aggregateNames aggregate
      NProcess process -> processNames process
      NRouter router -> routerNames router
      NContract contract ->
        pascalizedNodeName "contract" (ctrName contract) (ctrLoc contract)
          ++ concatMap
            (\event -> constructorName "contract event name" (ceName event) (ctrLoc contract) ++ concatMap contractFieldName (ceFields event))
            (ctrEvents contract)
      NIntake intake -> pascalizedNodeName "intake" (inkName intake) (inkLoc intake)
      NEmit emitNode -> pascalizedNodeName "emit" (emName emitNode) (emLoc emitNode)
      NPublisher publisher -> pascalizedNodeName "publisher" (pubName publisher) (pubLoc publisher)
      NWorkqueue workqueue ->
        pascalizedNodeName "workqueue" (wqName workqueue) (wqLoc workqueue)
          ++ constructorName "workqueue payload name" (wqPayloadName workqueue) (wqLoc workqueue)
          ++ concatMap (\field -> fieldNameRule "workqueue payload field" (wqfName field) (wqLoc workqueue)) (wqPayload workqueue)
      NPgmqDispatch dispatch -> pascalizedNodeName "dispatch" (pdName dispatch) (pdLoc dispatch)
      NReadModel readModel -> pascalizedNodeName "readmodel" (rmName readModel) (rmLoc readModel)
      NWorkflow workflow -> constructorName "workflow name" (wfId workflow) (workflowNodeLoc workflow)
      NOperation _ -> []

    aggregateNames aggregate =
      constructorName "aggregate name" (aggName aggregate) (aggLoc aggregate)
        ++ concatMap
          (\register -> fieldNameRule "register name" (regName register) (regLoc register))
          (aggRegs aggregate)
        ++ concatMap commandNames (aggCommands aggregate)
        ++ concatMap eventNames (aggEvents aggregate)
        ++ maybe [] (\projection -> fieldNameRule "projection key" (projKey projection) (projLoc projection)) (aggProjection aggregate)
        ++ vertexCollisions aggregate
      where
        commandNames command =
          constructorName "command name" (cmdName command) (cmdLoc command)
            ++ concatMap (aggregateFieldNameRule "command field") (cmdFields command)
        eventNames event =
          constructorName "event name" (evName event) (evLoc event)
            ++ case evBody event of
              EventFields fields -> concatMap (aggregateFieldNameRule "event field") fields
              EventFromCommand _ -> []

    processNames process =
      constructorName "process name" (procId process) (procLoc process)
        ++ constructorName "process input name" (inName input) (procLoc process)
        ++ concatMap (\field -> fieldNameRule "process input field" (fieldName field) (procLoc process)) (inFields input)
        ++ concatMap (bindingName "advance field binding" (procLoc process)) (advFields (hAdvance handle))
        ++ concatMap dispatchBindings (hDispatch handle)
        ++ concatMap (bindingName "timer payload field binding" (tmLoc timer)) (tmPayload timer)
        ++ concatMap (bindingName "timer fire field binding" (tmLoc timer)) (fireFields (tmFire timer))
      where
        input = procInput process
        handle = procHandle process
        timer = procTimer process
        dispatchBindings dispatch = concatMap (bindingName "dispatch field binding" (dispLoc dispatch)) (dispFields dispatch)

    routerNames router =
      constructorName "router name" (rtId router) (rtLoc router)
        ++ constructorName "router input name" (inName input) (rtLoc router)
        ++ concatMap (\field -> fieldNameRule "router input field" (fieldName field) (rtLoc router)) (inFields input)
        ++ concatMap (\field -> fieldNameRule "router resolve-row field" field (rvLoc resolve)) (rvRow resolve)
        ++ concatMap (bindingName "router dispatch field binding" (rdLoc dispatch)) (rdFields dispatch)
      where
        input = rtInput router
        resolve = rtResolve router
        dispatch = rtDispatch router

    bindingName category anchor binding = fieldNameRule category (fbName binding) anchor
    contractFieldName = contractFieldNameRule "contract field"

    aggregateFieldNameRule category field =
      case aggregateFieldSelector field of
        Nothing -> fieldNameRule category (aggregateFieldName field) (aggregateFieldLoc field)
        Just selector -> explicitFieldSelectorRule category (aggregateFieldName field) selector (aggregateFieldLoc field)

    contractFieldNameRule category field =
      case cfSelector field of
        Nothing -> fieldNameRule category (cfName field) (cfLoc field)
        Just selector -> explicitFieldSelectorRule category (cfName field) selector (cfLoc field)

    explicitFieldSelectorRule category dslName selector anchor =
      case HaskellName.checkedLowerOccurrence site selector of
        Right _ -> []
        Left nameError -> [nameErrorDiagnostic (category <> " selector") nameError]
      where
        site =
          HaskellName.NameSite
            { HaskellName.siteKind = HaskellName.GeneratedFieldSite,
              HaskellName.siteLogicalName = selector,
              HaskellName.siteOwner = category <> ":" <> dslName,
              HaskellName.siteLine = locLine anchor
            }

    constructorName category name anchor = checkedLogicalName HaskellName.GeneratedTypeSite category name anchor

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
        { HaskellName.siteKind = kind,
          HaskellName.siteLogicalName = name,
          HaskellName.siteOwner = category <> ":" <> name,
          HaskellName.siteLine = locLine anchor
        }

    nameErrorDiagnostic category = \case
      HaskellName.EmptyNameSegment site ->
        mkErr (HaskellName.siteLine site) IdentUnsafeNormalization $
          category <> " '" <> HaskellName.siteLogicalName site <> "' has an empty generated-Haskell word"
      HaskellName.UnsafeNameSeparator site reason ->
        mkErr (HaskellName.siteLine site) IdentUnsafeNormalization $
          category <> " '" <> HaskellName.siteLogicalName site <> "' cannot be normalized safely: " <> reason
      HaskellName.ReservedGeneratedOccurrence site occurrence ->
        mkErr (HaskellName.siteLine site) GeneratedOccurrenceReserved $
          category <> " '" <> HaskellName.siteLogicalName site <> "' normalizes to reserved Haskell occurrence '" <> occurrence <> "'"
      HaskellName.InvalidExplicitHaskellName site occurrence ->
        mkErr (HaskellName.siteLine site) IdentUnsafeNormalization $
          category <> " '" <> HaskellName.siteLogicalName site <> "' cannot become generated Haskell occurrence '" <> occurrence <> "'"
      collision@HaskellName.NormalizedNameCollision {} -> collisionDiagnostic collision

    normalizedCollisions = map collisionDiagnostic (HaskellName.detectNameCollisions collisionOccurrences)

    collisionOccurrences =
      nodeModuleOccurrences
        <> sharedTypeOccurrences
        <> concatMap aggregateFieldOccurrences aggregates
        <> concatMap aggregateHarnessOccurrences aggregates
        <> concatMap contractFieldOccurrences contracts

    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]
    contracts = [contract | NContract contract <- specNodes spec]

    contextSegment =
      case deriveAt HaskellName.LogicalWireWord HaskellName.ContextModuleSite "context" (specContext spec) (Loc 1) of
        Right derived -> HaskellName.renderUpperCamelName (HaskellName.upperCamel derived)
        Left _ -> specContext spec

    nodeModuleOccurrences =
      [ HaskellName.plannedOccurrence contextSegment HaskellName.ModuleSpace "" rendered site
      | node <- specNodes spec,
        let (category, raw, anchor) = nodeNameAndLoc node,
        let site = nameSite HaskellName.NodeModuleSite category raw anchor,
        Right derived <- [HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site],
        let rendered = HaskellName.renderUpperCamelName (HaskellName.upperCamel derived)
      ]

    sharedTypeOccurrences =
      [ HaskellName.plannedOccurrence ("Generated." <> contextSegment <> ".Nominals") HaskellName.TypeSpace "" rendered site
      | (category, raw, anchor) <-
          [("id", idName declaration, idLoc declaration) | declaration <- specIds spec]
            <> [("enum", enumName declaration, enumLoc declaration) | declaration <- specEnums spec]
            <> [("nominal", nominalScalarName declaration, nominalScalarLoc declaration) | declaration <- specNominalScalars spec],
        let site = nameSite HaskellName.GeneratedTypeSite category raw anchor,
        Right derived <- [HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site],
        let rendered = HaskellName.renderUpperCamelName (HaskellName.upperCamel derived)
      ]

    aggregateFieldOccurrences aggregate = commandFields <> eventFields
      where
        targetModule = "Generated." <> contextSegment <> "." <> normalizedUpper "aggregate" (aggName aggregate) (aggLoc aggregate) <> ".Domain"
        commandFields =
          [ fieldOccurrence targetModule (cmdName command) "command field" field
          | command <- aggCommands aggregate,
            field <- cmdFields command
          ]
        eventFields =
          [ fieldOccurrence targetModule (evName event) "event field" field
          | event <- aggEvents aggregate,
            field <- eventFieldsFor aggregate event
          ]

    eventFieldsFor aggregate event =
      case evBody event of
        EventFields fields -> fields
        EventFromCommand commandName ->
          [ field
          | command <- aggCommands aggregate,
            cmdName command == commandName,
            field <- cmdFields command
          ]

    fieldOccurrence targetModule scope category field =
      let raw = aggregateFieldName field
          site = nameSite HaskellName.GeneratedFieldSite category raw (aggregateFieldLoc field)
          rendered = case aggregateFieldSelector field of
            Just selector -> selector
            Nothing -> case HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site of
              Right derived -> HaskellName.renderLowerCamelName (HaskellName.lowerCamel derived)
              Left _ -> raw
       in HaskellName.plannedOccurrence targetModule HaskellName.FieldSpace scope rendered site

    aggregateHarnessOccurrences aggregate =
      transitionHelpers <> sampleConstants
      where
        transitionHelpers =
          concat
            [ [helperOccurrence "accept" ("accept" <> commandName) transition]
                <> [helperOccurrence "forward/replay" ("forwardReplay" <> commandName) transition | not (null (tEmits transition))]
            | transition <- aggTransitions aggregate,
              tSource transition == initialState,
              tMode transition == TmLive,
              let commandName = tCommand transition
            ]
        sampleConstants = map idSampleOccurrence generatedIds <> maybe [] (pure . timeSampleOccurrence) timeSample
        resolvedHarnessFields =
          [ (field, resolvedType)
          | (useSite, field) <- harnessFields aggregate,
            Right resolvedType <- [inferAggregateFieldType symbols aggregate useSite field]
          ]
        generatedIds =
          Map.elems . Map.fromList $
            [ (Nominal.resolvedNominalName nominal, nominal)
            | (_, AggregateNominal nominal) <- resolvedHarnessFields,
              Nominal.GeneratedNominal <- [Nominal.resolvedNominalOwnership nominal],
              Nominal.IdRepresentation prefix <- [Nominal.resolvedNominalRepresentation nominal],
              idDomainContractFor languageContract prefix /= Nothing
            ]
        timeFields = [field | (field, AggregateTime) <- resolvedHarnessFields]
        timeSample = case filter ((== "observedAt") . aggregateFieldName) timeFields of
          field : _ -> Just ("sampleObservedAt", field)
          [] -> case timeFields of
            field : _ -> Just ("sampleTime", field)
            [] -> Nothing
        initialState = case aggStates aggregate of
          state : _ -> stName state
          [] -> ""
        symbols = aggregateSymbols spec
        targetModule =
          "Generated."
            <> contextSegment
            <> "."
            <> normalizedUpper "aggregate" (aggName aggregate) (aggLoc aggregate)
            <> ".Harness"
        helperOccurrence helperKind rendered transition =
          HaskellName.plannedOccurrence targetModule HaskellName.ValueSpace "" rendered site
          where
            site =
              HaskellName.NameSite
                { HaskellName.siteKind = HaskellName.GeneratedHelperSite,
                  HaskellName.siteLogicalName = tCommand transition,
                  HaskellName.siteOwner = "aggregate:" <> aggName aggregate <> ":" <> helperKind <> ":line:" <> T.pack (show (locLine (tLoc transition))),
                  HaskellName.siteLine = locLine (tLoc transition)
                }
        idSampleOccurrence nominal =
          HaskellName.plannedOccurrence targetModule HaskellName.ValueSpace "" ("sample" <> nominalName) site
          where
            nominalName = Nominal.resolvedNominalName nominal
            nominalLoc = Nominal.resolvedNominalLoc nominal
            site =
              HaskellName.NameSite
                { HaskellName.siteKind = HaskellName.GeneratedHelperSite,
                  HaskellName.siteLogicalName = nominalName,
                  HaskellName.siteOwner = "aggregate:" <> aggName aggregate <> ":sample-id:" <> nominalName,
                  HaskellName.siteLine = locLine nominalLoc
                }
        timeSampleOccurrence (rendered, field) =
          HaskellName.plannedOccurrence targetModule HaskellName.ValueSpace "" rendered site
          where
            site =
              HaskellName.NameSite
                { HaskellName.siteKind = HaskellName.GeneratedHelperSite,
                  HaskellName.siteLogicalName = aggregateFieldName field,
                  HaskellName.siteOwner = "aggregate:" <> aggName aggregate <> ":sample-time",
                  HaskellName.siteLine = locLine (aggregateFieldLoc field)
                }

    harnessFields aggregate =
      [(CommandFieldUse, field) | command <- aggCommands aggregate, field <- cmdFields command]
        <> [ (EventFieldUse, field)
           | event <- aggEvents aggregate,
             field <- eventFieldsFor aggregate event
           ]

    contractFieldOccurrences contract =
      [ contractFieldOccurrence targetModule (ceName event <> "Data") field
      | event <- ctrEvents contract,
        field <- ceFields event
      ]
      where
        targetModule =
          "Generated."
            <> contextSegment
            <> "."
            <> normalizedUpper "contract" (ctrName contract) (ctrLoc contract)
            <> ".Contract"

    contractFieldOccurrence targetModule scope field =
      let identity = resolveContractFieldIdentity field
          site = nameSite HaskellName.GeneratedFieldSite "contract field" (fieldDslName identity) (fieldLoc identity)
          rendered = case cfSelector field of
            Just selector -> selector
            Nothing -> case HaskellName.deriveHaskellName HaskellName.LogicalIdentifier site of
              Right derived -> HaskellName.renderLowerCamelName (HaskellName.lowerCamel derived)
              Left _ -> fieldSelector identity
       in HaskellName.plannedOccurrence targetModule HaskellName.FieldSpace scope rendered site

    normalizedUpper category raw anchor =
      case deriveAt HaskellName.LogicalIdentifier HaskellName.GeneratedTypeSite category raw anchor of
        Right derived -> HaskellName.renderUpperCamelName (HaskellName.upperCamel derived)
        Left _ -> raw

    nodeNameAndLoc = \case
      NAggregate value -> ("aggregate", aggName value, aggLoc value)
      NProcess value -> ("process", procId value, procLoc value)
      NRouter value -> ("router", rtId value, rtLoc value)
      NContract value -> ("contract", ctrName value, ctrLoc value)
      NIntake value -> ("intake", inkName value, inkLoc value)
      NEmit value -> ("emit", emName value, emLoc value)
      NPublisher value -> ("publisher", pubName value, pubLoc value)
      NWorkqueue value -> ("workqueue", wqName value, wqLoc value)
      NPgmqDispatch value -> ("dispatch", pdName value, pdLoc value)
      NReadModel value -> ("readmodel", rmName value, rmLoc value)
      NWorkflow value -> ("workflow", wfId value, workflowNodeLoc value)
      NOperation value -> ("operation", opName value, opLoc value)

    collisionDiagnostic (HaskellName.NormalizedNameCollision key sites) =
      case reverse (NE.toList sites) of
        primary : reversedEarlier ->
          Diagnostic
            { line = HaskellName.siteLine primary,
              severity = Error,
              code = GeneratedOccurrenceCollision,
              relatedLocations =
                [ (HaskellName.siteLine site, "'" <> HaskellName.siteLogicalName site <> "' also normalizes here")
                | site <- reverse reversedEarlier
                ],
              message =
                "logical declarations "
                  <> T.intercalate ", " ["'" <> HaskellName.siteLogicalName site <> "'" | site <- NE.toList sites]
                  <> " normalize to the same Haskell occurrence '"
                  <> HaskellName.occurrenceName key
                  <> "' in "
                  <> HaskellName.occurrenceModule key
                  <> " ("
                  <> T.pack (show (HaskellName.occurrenceSpace key))
                  <> ")"
            }
        [] -> mkErr 1 GeneratedOccurrenceCollision "internal error: normalized collision without source sites"
    collisionDiagnostic nameError = nameErrorDiagnostic "generated declaration" nameError

    vertexCollisions aggregate =
      [ mkErr (locLine (aggLoc aggregate)) VertexCtorCollision $
          "aggregate '"
            <> aggName aggregate
            <> "' state '"
            <> stName state
            <> "' generates vertex constructor '"
            <> vertex
            <> "', which collides with "
            <> declarationKind
            <> " '"
            <> vertex
            <> "' in the generated Domain constructor namespace"
      | state <- aggStates aggregate,
        let vertex = normalizedUpper "aggregate" (aggName aggregate) (aggLoc aggregate) <> normalizedUpper "state" (stName state) (stLoc state),
        declarationKind <- collisionKinds aggregate vertex
      ]

    collisionKinds aggregate vertex =
      ["event" | vertex `elem` [normalizedUpper "event" (evName event) (evLoc event) | event <- aggEvents aggregate]]
        ++ ["command" | vertex `elem` [normalizedUpper "command" (cmdName command) (cmdLoc command) | command <- aggCommands aggregate]]
        ++ ["enum constructor" | vertex `elem` [normalizedUpper "enum constructor" ctor (enumLoc enum) | enum <- specEnums spec, (ctor, _) <- enumCtors enum]]

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
specLevelRules :: EffectiveLanguageContract -> Spec -> [Diagnostic]
specLevelRules languageContract spec = duplicateNodes ++ duplicateEnumMembers ++ duplicateIdPrefixes ++ duplicateDeclarations ++ runtimeIdentities ++ duplicateRuntimeIdentities ++ ruleDiagnostics
  where
    duplicateNodes =
      [ mkErr (locLine loc) DuplicateNodeName $
          "duplicate " <> kind <> " node name '" <> name <> "'"
      | node <- duplicatesBy nodeKey (specNodes spec),
        let (kind, name, loc) = nodeIdentity node
      ]
    nodeKey node = let (kind, name, _) = nodeIdentity node in (kind, name)
    duplicateEnumMembers = concatMap enumDuplicates (specEnums spec)
    enumDuplicates e =
      [ mkErr (locLine (enumLoc e)) DuplicateEnumCtor $
          "enum '" <> enumName e <> "' declares constructor '" <> ctor <> "' more than once"
      | (ctor, _) <- duplicatesBy fst (enumCtors e)
      ]
        ++ [ mkErr (locLine (enumLoc e)) DuplicateEnumWire $
               "enum '" <> enumName e <> "' declares wire spelling '" <> wire <> "' more than once"
           | (_, wire) <- duplicatesBy snd (enumCtors e)
           ]
    duplicateIdPrefixes =
      [ mkErr (locLine (idLoc d)) DuplicateIdPrefix $
          "id '" <> idName d <> "' reuses prefix '" <> idPrefix d <> "'"
      | d <- duplicatesBy idPrefix (specIds spec)
      ]
    duplicateDeclarations =
      [ mkErr (locLine loc) NominalDuplicateDeclaration $
          "duplicate " <> category <> " declaration '" <> name <> "'; the last declaration would silently replace the earlier one"
      | enforcesSpecSurfaceClosures languageContract,
        (category, name, loc) <- duplicatesBy (\(category, name, _) -> (category, name)) declarationOrigins
      ]
    declarationOrigins =
      [("id", idName value, idLoc value) | value <- specIds spec]
        <> [("enum", enumName value, enumLoc value) | value <- specEnums spec]
        <> [("nominal scalar", nominalScalarName value, nominalScalarLoc value) | value <- specNominalScalars spec]
        <> [("mapped", mappedName value, mappedLoc value) | value <- specMapped spec]
        <> [("rule", ruleName value, ruleLoc value) | value <- specRules spec]
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
      [("workflow", wfStable workflow, workflowNodeLoc workflow) | NWorkflow workflow <- specNodes spec]
        <> [("process", procName process, procLoc process) | NProcess process <- specNodes spec]
        <> [("router", rtName router, rtLoc router) | NRouter router <- specNodes spec]
    ruleDiagnostics = concatMap (validateRule spec) (specRules spec)

nodeIdentity :: Node -> (Text, Name, Loc)
nodeIdentity (NAggregate a) = ("aggregate", aggName a, aggLoc a)
nodeIdentity (NProcess p) = ("process", procId p, procLoc p)
nodeIdentity (NRouter r) = ("router", rtId r, rtLoc r)
nodeIdentity (NContract c) = ("contract", ctrName c, ctrLoc c)
nodeIdentity (NIntake i) = ("intake", inkName i, inkLoc i)
nodeIdentity (NEmit e) = ("emit", emName e, emLoc e)
nodeIdentity (NPublisher p) = ("publisher", pubName p, pubLoc p)
nodeIdentity (NWorkqueue w) = ("workqueue", wqName w, wqLoc w)
nodeIdentity (NPgmqDispatch d) = ("dispatch", pdName d, pdLoc d)
nodeIdentity (NReadModel r) = ("readmodel", rmName r, rmLoc r)
nodeIdentity (NWorkflow w) = ("workflow", wfId w, workflowNodeLoc w)
nodeIdentity (NOperation o) = ("operation", opName o, opLoc o)

validateNode :: EffectiveLanguageContract -> Spec -> Node -> [Diagnostic]
validateNode languageContract spec (NAggregate agg) = validateAggregate languageContract spec agg
validateNode languageContract spec (NProcess p) = validateProcess languageContract spec p
validateNode languageContract spec (NRouter router) = validateRouter languageContract spec router
validateNode languageContract _spec (NContract contract) = validateContract languageContract contract
validateNode languageContract spec (NIntake i) = validateIntake languageContract i ++ intakeCoupling languageContract spec i
validateNode languageContract spec (NEmit e) = validateEmit languageContract spec e
validateNode languageContract spec (NPublisher p) = validatePublisher languageContract spec p
validateNode languageContract _spec (NWorkqueue w) = validateWorkqueue languageContract w
validateNode languageContract spec (NPgmqDispatch d) = validatePgmqDispatch languageContract spec d
validateNode languageContract spec (NReadModel readModel) = validateReadModel languageContract spec readModel
validateNode _languageContract _spec (NWorkflow w) = validateWorkflow w
validateNode _languageContract spec (NOperation o) = validateOperation spec o

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
      [ mkErr (locLine (ctrLoc contract)) ContractEmpty $
          "contract '"
            <> ctrName contract
            <> "' declares no events; scaffold cannot lower an empty contract -- declare at least one event"
      | null (ctrEvents contract)
      ]
    typeIdPrefixErrors =
      [ mkErr (locLine (cfLoc field)) ContractInvalidTypeIdPrefix $
          "contract '"
            <> ctrName contract
            <> "' event '"
            <> ceName event
            <> "' field '"
            <> cfName field
            <> "' has invalid TypeID prefix '"
            <> prefix
            <> "': "
            <> T.pack (show reason)
      | event <- ctrEvents contract,
        field <- ceFields event,
        CTypeId prefix <- [cfType field],
        Just _ <- [contractIdDomainContractFor languageContract prefix],
        Just reason <- [TypeID.checkPrefix prefix]
      ]
    schemaVersionFloor =
      [ mkErr (locLine (ctrLoc contract)) ContractSchemaVersionBelowMinimum $
          "contract '" <> ctrName contract <> "' schemaVersion must be at least 1"
      | enforcesSpecSurfaceClosures languageContract,
        ctrSchemaVersion contract < 1
      ]
    topicNames =
      [ mkErr (locLine (ctrLoc contract)) ContractTopicNameInvalid $
          "contract '" <> ctrName contract <> "' topic alias '" <> alias <> "' has invalid Kafka topic " <> T.pack (show topic) <> ": " <> reason
      | (alias, topic) <- ctrTopics contract,
        T.null topic || enforcesSpecSurfaceClosures languageContract,
        Just reason <- [kafkaTopicError topic]
      ]
    duplicateEvents =
      [ mkErr (locLine (ctrLoc contract)) ContractDuplicateEvent $
          "contract '" <> ctrName contract <> "' declares event '" <> ceName event <> "' more than once"
      | event <- duplicatesBy ceName (ctrEvents contract)
      ]
    duplicateTopicAliases =
      [ mkErr (locLine (ctrLoc contract)) ContractDuplicateTopicAlias $
          "contract '" <> ctrName contract <> "' declares topic alias '" <> alias <> "' more than once"
      | (alias, _) <- duplicatesBy fst (ctrTopics contract)
      ]
    duplicateFields =
      [ mkErr (locLine (cfLoc field)) ContractDuplicateFieldName $
          "contract '" <> ctrName contract <> "' event '" <> ceName event <> "' declares field '" <> cfName field <> "' more than once"
      | event <- ctrEvents contract,
        field <- duplicatesBy cfName (ceFields event)
      ]
    discriminatorShadows =
      [ mkErr (locLine (cfLoc field)) ContractFieldShadowsDiscriminator $
          "contract '"
            <> ctrName contract
            <> "' event '"
            <> ceName event
            <> "' field '"
            <> cfName field
            <> "' shadows the payload discriminator"
      | enforcesSpecSurfaceClosures languageContract,
        event <- ctrEvents contract,
        field <- ceFields event,
        fieldWireKey (resolveContractFieldIdentity field) == ctrDiscriminator contract
      ]
    fieldWireKeyRules =
      concat
        [ wireKeyRulesForRecord
            ("contract '" <> ctrName contract <> "' event '" <> ceName event <> "'")
            (Just (ctrDiscriminator contract, "payload discriminator"))
            (map resolveContractFieldIdentity (ceFields event))
        | event <- ctrEvents contract
        ]
    unresolvedTopicAliases =
      [ mkErr (locLine (ctrLoc contract)) ContractTopicAliasUnresolved $
          "contract '" <> ctrName contract <> "' event '" <> ceName event <> "' names undeclared topic alias '" <> ceTopic event <> "'"
      | enforcesSpecSurfaceClosures languageContract,
        event <- ctrEvents contract,
        ceTopic event `notElem` map fst (ctrTopics contract)
      ]

-- | Workflow replay keys, patch guards, rotation, and injected inputs must be unambiguous.
validateWorkflow :: WorkflowNode -> [Diagnostic]
validateWorkflow w = duplicateLabels ++ sleepFields ++ patchDuplicates ++ patchIds ++ continuePositions ++ idField
  where
    inputFields = map fieldName (wfInputFields w)
    labelledItems = workflowLabelledItems (wfBody w)
    patchItems = workflowPatchItems (wfBody w)
    duplicateLabels =
      [ mkErr (locLine (wfBodyLoc item)) WorkflowDuplicateLabel $
          "workflow '" <> wfId w <> "' declares label '" <> label <> "' more than once; labels key deterministic replay, so a duplicate label replays the first occurrence's journaled result"
      | (label, item) <- duplicatesBy fst labelledItems
      ]
    sleepFields =
      [ mkErr (locLine loc) WorkflowSleepDelayUnresolved $
          "workflow '" <> wfId w <> "' sleep '" <> label <> "' references undeclared input field '" <> delay <> "'"
      | WfSleep label delay loc <- map snd labelledItems,
        delay `notElem` inputFields
      ]
    patchDuplicates =
      [ mkErr (locLine loc) WorkflowPatchDuplicate $
          "workflow '" <> wfId w <> "' declares patch id '" <> patchId <> "' more than once; patch decisions journal under one stable key"
      | (patchId, _, loc) <- duplicatesBy (\(patchId, _, _) -> patchId) patchItems
      ]
    patchIds =
      [ mkErr (locLine loc) WorkflowPatchIdInvalid $
          "workflow '" <> wfId w <> "' patch id '" <> patchId <> "' contains ':'; the runtime reserves that separator for the patch journal-key prefix"
      | (patchId, _, loc) <- patchItems,
        ":" `T.isInfixOf` patchId
      ]
    continuePositions =
      [ mkErr (locLine loc) WorkflowContinueAsNewNotTerminal $
          "workflow '" <> wfId w <> "' continueAsNew must be the last top-level body item and may not appear inside a patch"
      | (isTopLevelTerminal, loc) <- workflowContinueItems (wfBody w),
        not isTopLevelTerminal
      ]
    idField = case wfIdField w of
      Just field
        | field `notElem` inputFields ->
            [ mkErr (locLine (workflowNodeLoc w)) WorkflowIdFieldUnresolved $
                "workflow '" <> wfId w <> "' derives its id from undeclared input field '" <> field <> "'"
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
validateRule spec rule = case [e | e <- specEnums spec, enumName e == ruleDomain rule] of
  [] ->
    [ mkErr rl RuleDomainUnresolved $
        "rule '" <> ruleName rule <> "' has undeclared enum domain '" <> ruleDomain rule <> "'"
    ]
  (domain : _) -> totality domain ++ unknownCases domain ++ bodyDiagnostics
  where
    rl = locLine (ruleLoc rule)
    caseNames = map fst (ruleCases rule)
    allEnumCtors = Set.fromList [ctor | e <- specEnums spec, (ctor, _) <- enumCtors e]
    totality domain =
      let missing = [ctor | (ctor, _) <- enumCtors domain, ctor `notElem` caseNames]
       in [ mkErr rl RuleNotTotal $
              "rule '" <> ruleName rule <> "' is not total over enum '" <> enumName domain <> "'; missing cases {" <> T.intercalate ", " missing <> "}"
          | not (null missing)
          ]
    unknownCases domain =
      [ mkErr rl RuleCaseUnknownCtor $
          "rule '" <> ruleName rule <> "' has case '" <> ctor <> "' which is not a constructor of enum '" <> enumName domain <> "'"
      | (ctor, _) <- ruleCases rule,
        ctor `notElem` map fst (enumCtors domain)
      ]
    bodyDiagnostics = concatMap validateBody (ruleCases rule)
    validateBody (ctor, expr) =
      [ mkErr rl ClockSampled $
          "rule '" <> ruleName rule <> "' case '" <> ctor <> "' samples the wall clock via '" <> atom <> "'; rules must be deterministic"
      | atom <- dedup (exprNames expr),
        atom `Set.member` clockAtoms
      ]
        ++ [ mkErr rl GuardAtomOutOfScope $
               "atom '" <> atom <> "' in rule '" <> ruleName rule <> "' resolves to no enum constructor or boolean literal"
           | atom <- dedup (exprNames expr),
             atom `Set.notMember` clockAtoms,
             atom `Set.notMember` allEnumCtors
           ]

-- | Operation rules resolve command aggregates, stream fields, projections,
-- read models, workflow signal labels and value types, and run targets.
validateOperation :: Spec -> OperationNode -> [Diagnostic]
validateOperation spec o = case opShape o of
  CommandOp aggregate streamField _ projections ->
    aggregateRef aggregate streamField ++ projectionRefs projections
  QueryOp readModel _ _ consistency ->
    resolveReadModelRef QueryUnresolvedReadModel spec (opLoc o) ("query operation '" <> opName o <> "'") readModel
      ++ [ mkErr ol QueryConsistencyInvalid $
             "query operation '" <> opName o <> "' has unknown consistency '" <> consistency <> "'; expected Strong, Eventual, or PositionWait"
         | consistency `notElem` (["Strong", "Eventual", "PositionWait"] :: [Name])
         ]
  SignalOp lbl wf _ _ valueType ->
    case lookupWorkflow wf of
      Nothing ->
        [mkErr ol AwaitSignalMismatch ("signal operation '" <> opName o <> "' targets undeclared workflow '" <> wf <> "'")]
      Just w -> case [(resultType, loc) | (_, WfAwait label resultType loc) <- workflowLabelledItems (wfBody w), label == lbl] of
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
    [ mkErr ol RunWorkflowUnresolved ("run operation '" <> opName o <> "' targets undeclared workflow '" <> wf <> "'")
    | wf `notElem` map wfId workflows
    ]
  where
    ol = locLine (opLoc o)
    workflows = [w | NWorkflow w <- specNodes spec]
    aggregates = [a | NAggregate a <- specNodes spec]
    projectionTables = [projTable p | a <- aggregates, Just p <- [aggProjection a]]
    lookupWorkflow n = case [w | w <- workflows, wfId w == n] of (w : _) -> Just w; [] -> Nothing
    awaitLabels w = [l | (_, WfAwait l _ _) <- workflowLabelledItems (wfBody w)]
    aggregateRef name streamField = case [a | a <- aggregates, aggName a == name] of
      [] ->
        [ mkErr ol OperationUnresolvedRef $
            "command operation '" <> opName o <> "' targets undeclared aggregate '" <> name <> "'"
        ]
      (aggregate : _) ->
        [ mkErr ol OperationUnresolvedRef $
            "command operation '" <> opName o <> "' stream field '" <> streamField <> "' is not declared by any command of aggregate '" <> name <> "'"
        | streamField `notElem` [aggregateFieldName field | command <- aggCommands aggregate, field <- cmdFields command]
        ]
    projectionRefs projections =
      [ mkErr ol OperationUnresolvedRef $
          "command operation '" <> opName o <> "' references undeclared projection table '" <> projection <> "'"
      | projection <- projections,
        projection `notElem` projectionTables
      ]

-- | Resolve a named read-model node using the caller's diagnostic code.
resolveReadModelRef :: DiagnosticCode -> Spec -> Loc -> Text -> Name -> [Diagnostic]
resolveReadModelRef diagnosticCode spec diagnosticLoc context name =
  [ mkErr (locLine diagnosticLoc) diagnosticCode $
      context <> " references undeclared readmodel '" <> name <> "'"
  | name `notElem` [rmName readModel | NReadModel readModel <- specNodes spec]
  ]

-- | Validate captured identity, feed semantics, and the declared column surface.
validateReadModel :: EffectiveLanguageContract -> Spec -> ReadModelNode -> [Diagnostic]
validateReadModel languageContract spec readModel =
  shapeFixture ++ columnTypes ++ strongFeed ++ scopeMode ++ inlineSubscription ++ inlineReference ++ versionFloor ++ identifiers ++ runtimeIdentities ++ duplicateColumns
  where
    readModelLine = locLine (rmLoc readModel)
    expectedShape = deriveShapeHash readModel
    shapeFixture =
      [ mkErr readModelLine RmShapeHashDrift $
          "readmodel '"
            <> rmName readModel
            <> "': captured shape \""
            <> rmShape readModel
            <> "\" does not match the declared columns (expected \""
            <> expectedShape
            <> "\"); update the fixture AND bump version if the table shape really changed"
      | rmShape readModel /= expectedShape
      ]
    allowedColumnTypes = Set.fromList ["text", "int", "bigint", "bool", "timestamptz", "jsonb", "numeric"]
    columnTypes =
      [ mkErr readModelLine RmUnknownColumnType $
          "readmodel '" <> rmName readModel <> "' column '" <> rmcName columnDecl <> "' has unknown type '" <> rmcType columnDecl <> "'"
      | columnDecl <- rmColumns readModel,
        rmcType columnDecl `Set.notMember` allowedColumnTypes
      ]
    strongFeed =
      [ mkErr readModelLine RmStrongInlineOnly $
          "readmodel '"
            <> rmName readModel
            <> "': consistency = Strong with feed = inline; an inline-only model has no subscription worker to advance the cursor a Strong read waits on. Use consistency = Eventual, or feed = subscription"
      | rmFeed readModel == RmInline,
        rmConsistency readModel == Strong
      ]
    scopeMode =
      [ mkErr readModelLine RmScopeWithoutStrong $
          "readmodel '" <> rmName readModel <> "': scope is meaningful only with consistency = Strong"
      | rmScope readModel /= Nothing,
        rmConsistency readModel /= Strong
      ]
    inlineSubscription =
      [ Diagnostic
          { line = readModelLine,
            severity = Warning,
            code = RmInlineSubscriptionIgnored,
            relatedLocations = [],
            message = "readmodel '" <> rmName readModel <> "': subscription override is ignored when feed = inline; remove it or select feed = subscription"
          }
      | rmFeed readModel == RmInline,
        rmSubscription readModel /= Nothing
      ]
    inlineReference =
      [ mkErr readModelLine RmInlineFeedUnreferenced $
          "readmodel '" <> rmName readModel <> "' declares feed = inline but no aggregate projection references it"
      | rmFeed readModel == RmInline,
        rmName readModel `notElem` [projTable projection | NAggregate aggregate <- specNodes spec, Just projection <- [aggProjection aggregate]]
      ]
    versionFloor =
      [ mkErr readModelLine ReadModelVersionBelowMinimum $
          "readmodel '" <> rmName readModel <> "' version must be at least 1"
      | enforcesSpecSurfaceClosures languageContract,
        rmVersion readModel < 1
      ]
    identifiers =
      [ mkErr readModelLine ReadModelIdentifierInvalid $
          "readmodel '" <> rmName readModel <> "' " <> kind <> " " <> T.pack (show identifier) <> " is not a PostgreSQL unquoted identifier"
      | enforcesSpecSurfaceClosures languageContract,
        (kind, identifier) <-
          [("schema", rmSchema readModel), ("table", rmTable readModel)]
            <> [("column", rmcName columnDecl) | columnDecl <- rmColumns readModel],
        not (validPostgresIdentifier identifier)
      ]
    runtimeIdentities =
      [ mkErr readModelLine RuntimeIdentityInvalid $
          "readmodel '" <> rmName readModel <> "' subscription " <> T.pack (show subscription) <> " " <> reason
      | enforcesSpecSurfaceClosures languageContract,
        Just subscription <- [rmSubscription readModel],
        Just reason <- [stableIdentityError subscription]
      ]
        ++ [ mkErr readModelLine RuntimeIdentityInvalid $
               "readmodel '" <> rmName readModel <> "' scope category " <> T.pack (show category) <> " " <> reason
           | enforcesSpecSurfaceClosures languageContract,
             Just (RmCategory category) <- [rmScope readModel],
             Just reason <- [runtimeIdentityError False category]
           ]
    duplicateColumns =
      [ mkErr readModelLine ReadModelDuplicateColumn $
          "readmodel '" <> rmName readModel <> "' declares column '" <> rmcName columnDecl <> "' more than once"
      | enforcesSpecSurfaceClosures languageContract,
        columnDecl <- duplicatesBy rmcName (rmColumns readModel)
      ]

-- | EP-5 workqueue rules: the captured physical name must match the queueRef
-- derivation; the disposition inversions (storeFailure transient => must retry;
-- decodeFailure poison => must dead-letter); and dlq=on requires a retry ceiling.
validateWorkqueue :: EffectiveLanguageContract -> WorkqueueNode -> [Diagnostic]
validateWorkqueue languageContract w = concat [divergence, completeness, duplicateRows, inversions, retryCeiling, orderingRules, groupKeyRules, payloadTypes, windows, optionalFieldWarnings, provisionRules]
  where
    wl = locLine (wqLoc w)
    rows = wqDisposition w
    (derivedPhysical, derivedDlq, derivedTable) = derivedQueueTrio (wqLogical w)
    divergence =
      [ mkErr wl WqPhysicalDivergence $
          "workqueue '" <> wqName w <> "': captured physical \"" <> wqPhysical w <> "\" diverges from queueRef(\"" <> wqLogical w <> "\") = \"" <> derivedPhysical <> "\""
      | wqPhysical w /= derivedPhysical
      ]
        ++ [ mkErr wl WqDlqDivergence $
               "workqueue '" <> wqName w <> "': captured dlq \"" <> wqDlq w <> "\" diverges from queueRef = \"" <> derivedDlq <> "\""
           | wqDlq w /= derivedDlq
           ]
        ++ [ mkErr wl WqTableDivergence $
               "workqueue '" <> wqName w <> "': captured table \"" <> wqTable w <> "\" diverges from queueRef table = \"" <> derivedTable <> "\""
           | wqTable w /= derivedTable
           ]
    requiredOutcomes = ["storeFailure", "commandRejected", "decodeFailure", "onCodecReject"]
    completeness =
      [ mkErr wl WqDispositionIncomplete $
          "workqueue '" <> wqName w <> "' disposition table is missing outcome '" <> outcome <> "'"
      | outcome <- requiredOutcomes,
        outcome `notElem` map wqdOutcome rows
      ]
    duplicateRows =
      [ mkErr (locLine (wqdLoc row)) DispositionDuplicateOutcome $
          "workqueue '" <> wqName w <> "' repeats disposition outcome '" <> wqdOutcome row <> "'; the first row would shadow this row"
      | row <- duplicatesBy wqdOutcome rows
      ]
    firstRow outcome = case [row | row <- rows, wqdOutcome row == outcome] of
      (row : _) -> Just row
      [] -> Nothing
    isRetry row = case wqdAction row of IRetry _ -> True; _ -> False
    isDeadLetter row = case wqdAction row of IDeadLetter _ -> True; _ -> False
    inversions =
      [ mkErr (locLine (wqdLoc row)) WqStoreFailureNotRetry ("workqueue '" <> wqName w <> "': 'storeFailure' is transient and MUST retry, not dead-letter")
      | Just row <- [firstRow "storeFailure"],
        isDeadLetter row
      ]
        ++ [ mkErr (locLine (wqdLoc row)) WqDecodeFailureNotDeadLetter ("workqueue '" <> wqName w <> "': 'decodeFailure' is poison and MUST dead-letter, not retry")
           | Just row <- [firstRow "decodeFailure"],
             isRetry row
           ]
    retryCeiling =
      [ mkErr wl WqDlqWithoutCeiling ("workqueue '" <> wqName w <> "': dlq=on requires maxRetries >= 1 (an absent ceiling never dead-letters)")
      | wqDlqOn w && wqMaxRetries w < 1
      ]
    fifo = wqOrdering w /= WqUnordered
    orderingRules =
      [ mkErr wl WqGroupKeyMissing $
          "workqueue '" <> wqName w <> "': FIFO delivery is per group, so ordering requires a 'group key' clause that makes enqueueToGroup deterministic"
      | fifo && wqGroupKey w == Nothing
      ]
        ++ [ mkErr wl WqGroupKeyWithoutFifo $
               "workqueue '" <> wqName w <> "': a group key with unordered reads would be ignored; declare a FIFO ordering or remove the key"
           | not fifo && wqGroupKey w /= Nothing
           ]
    groupKeyRules = case wqGroupKey w of
      Nothing -> []
      Just groupKey ->
        case [field | field <- wqPayload w, wqfName field == gkField groupKey] of
          [] ->
            [ mkErr wl WqGroupKeyUnresolved $
                "workqueue '" <> wqName w <> "': group key field '" <> gkField groupKey <> "' is not declared in its payload"
            ]
          field : _ ->
            [ mkErr wl WqGroupKeyUnresolved $
                "workqueue '" <> wqName w <> "': group key via raw requires a text payload field, but '" <> gkField groupKey <> "' has type '" <> wqfType field <> "'"
            | gkVia groupKey == "raw" && wqfType field /= "text"
            ]
              ++ [ mkErr wl WqGroupKeyUnresolved $
                     "workqueue '" <> wqName w <> "': opaque group-key derivation '" <> gkVia groupKey <> "' requires a captured fixture"
                 | gkVia groupKey /= "raw" && gkFixture groupKey == Nothing
                 ]
    payloadTypes =
      [ mkErr wl WqPayloadTypeUnknown $
          "workqueue '" <> wqName w <> "' payload field '" <> wqfName field <> "' has unknown type '" <> wqfType field <> "'; expected text, int, or bool"
      | enforcesSpecSurfaceClosures languageContract,
        field <- wqPayload w,
        wqfType field `Set.notMember` Set.fromList ["text", "int", "bool"]
      ]
    windows =
      windowRangeRule languageContract wl ("workqueue '" <> wqName w <> "' delay") (wqDelay w)
        ++ concat
          [ windowRangeRule languageContract (locLine (wqdLoc row)) ("workqueue '" <> wqName w <> "' retry") window
          | row <- rows,
            IRetry window <- [wqdAction row]
          ]
    optionalFieldWarnings =
      [ Diagnostic
          { line = wl,
            severity = Warning,
            code = WqFieldOptionalUnsupported,
            relatedLocations = [],
            message = "workqueue '" <> wqName w <> "' payload field '" <> wqfName field <> "' omits 'required', but generated decoders currently require every payload field"
          }
      | field <- wqPayload w,
        not (wqfRequired field)
      ]
    provisionRules = case wqProvision w of
      WqStandard -> []
      WqUnlogged ->
        [ Diagnostic
            { line = wl,
              severity = Warning,
              code = WqUnloggedDurability,
              relatedLocations = [],
              message = "workqueue '" <> wqName w <> "': provision unlogged is truncated to empty on a database crash; use it only for transient, regenerable work"
            }
        ]
      WqPartitioned interval retention ->
        [ mkErr wl WqPartitionSpecEmpty $
            "workqueue '" <> wqName w <> "': partition interval and retention must be non-empty; they are create-time settings and the additive reconciler will not migrate an existing queue"
        | T.null interval || T.null retention
        ]

-- | EP-5 dispatch rule: the @enqueue to@ target must resolve to a declared workqueue.
validatePgmqDispatch :: EffectiveLanguageContract -> Spec -> PgmqDispatchNode -> [Diagnostic]
validatePgmqDispatch languageContract spec d = enqueueRef ++ dedupQueueRef ++ sourceReadModelRef ++ sourceReadModelField ++ dedupReadModelRef ++ dedupReadModelField
  where
    dl = locLine (pdLoc d)
    workqueues = [w | NWorkqueue w <- specNodes spec]
    enqueueRef =
      [ mkErr dl DispatchEnqueueUnresolved ("dispatch '" <> pdName d <> "' enqueues to undeclared workqueue '" <> pdEnqueueTo d <> "'")
      | pdEnqueueTo d `notElem` map wqName workqueues
      ]
    dedupQueueRef = case [w | w <- workqueues, wqName w == pdDedupQueue d] of
      [] ->
        [ mkErr dl DispatchDedupQueueUnresolved $
            "dispatch '" <> pdName d <> "' checks an undeclared dedup queue '" <> pdDedupQueue d <> "'"
        ]
      (queue : _) ->
        [ mkErr dl DispatchDedupFieldUnresolved $
            "dispatch '" <> pdName d <> "' dedup field '" <> pdDedupQueueField d <> "' is not a payload wire field of queue '" <> pdDedupQueue d <> "'"
        | pdDedupQueueField d `notElem` map wqfWire (wqPayload queue)
        ]
    sourceReadModelRef =
      resolveReadModelRef DispatchReadModelUnresolved spec (pdLoc d) ("dispatch '" <> pdName d <> "' source") (pdSourceReadModel d)
    sourceReadModelField = case [readModel | NReadModel readModel <- specNodes spec, rmName readModel == pdSourceReadModel d] of
      [] -> []
      readModel : _ ->
        [ mkErr dl DispatchReadModelFieldUnknown $
            "dispatch '" <> pdName d <> "' source key '" <> pdSourceKey d <> "' is not a generated logical selector for a column of readmodel '" <> pdSourceReadModel d <> "'"
        | enforcesSpecSurfaceClosures languageContract,
          pdSourceKey d `notElem` map (logicalFieldSelector . rmcName) (rmColumns readModel)
        ]
    dedupReadModelRef =
      resolveReadModelRef DispatchReadModelUnresolved spec (pdLoc d) ("dispatch '" <> pdName d <> "' dedup") (pdDedupReadModel d)
    dedupReadModelField = case [readModel | NReadModel readModel <- specNodes spec, rmName readModel == pdDedupReadModel d] of
      [] -> []
      (readModel : _) ->
        [ mkErr dl DispatchReadModelFieldUnknown $
            "dispatch '" <> pdName d <> "' dedup field '" <> pdDedupReadModelField d <> "' is not a declared column of readmodel '" <> pdDedupReadModel d <> "'"
        | pdDedupReadModelField d `notElem` map rmcName (rmColumns readModel)
        ]

-- | The declared contracts in a spec, by name.
specContracts :: Spec -> [ContractNode]
specContracts spec = [c | NContract c <- specNodes spec]

-- | EP-4 cross-node coupling: an intake's contract/topic/accepted-events resolve.
intakeCoupling :: EffectiveLanguageContract -> Spec -> IntakeNode -> [Diagnostic]
intakeCoupling languageContract spec i = bindFlagWarnings ++ bindHeaderNames ++ contractCoupling
  where
    -- The Kafka inbox reconstructs an envelope from the canonical header names
    -- in "Keiro.Integration.Event"; nothing reads a spec-declared header. A row
    -- naming a canonical header is descriptive and true, so it stays silent. A
    -- row naming any other header reads like remapping and silently is not.
    bindHeaderNames =
      [ mkSurfaceRefusal languageContract (locLine (inkLoc i)) IntakeBindHeaderUnknown $
          "intake '"
            <> inkName i
            <> "' binds '"
            <> brField binding
            <> "' from header "
            <> T.pack (show headerName)
            <> ", which is not one of keiro's canonical envelope headers; the Kafka inbox reads a fixed header set and cannot be remapped, so this row would not take effect. Use one of: "
            <> T.intercalate ", " (map (T.pack . show) canonicalEnvelopeHeaders)
      | binding <- inkBinds i,
        SrcHeader headerName <- [brSource binding],
        headerName `notElem` canonicalEnvelopeHeaders
      ]
    contractCoupling = case lookupContract (inkContract i) of
      Nothing ->
        [mkErr (locLine (inkLoc i)) IntakeUnresolvedContract ("intake '" <> inkName i <> "' references undeclared contract '" <> inkContract i <> "'")]
      Just c ->
        concat
          [ [ mkErr (locLine (inkLoc i)) IntakeUnresolvedContract ("intake '" <> inkName i <> "' topic '" <> inkTopic i <> "' is not a topic of contract '" <> inkContract i <> "'")
            | inkTopic i `notElem` map fst (ctrTopics c)
            ],
            [ mkErr (locLine (inkLoc i)) IntakeUnresolvedContract ("intake '" <> inkName i <> "' accepts event '" <> ev <> "' not declared in contract '" <> inkContract i <> "'")
            | ev <- inkAccept i,
              ev `notElem` map ceName (ctrEvents c)
            ],
            [ mkErr (locLine (inkLoc i)) TopicAffinityMismatch $
                "intake '" <> inkName i <> "' subscribes to topic '" <> inkTopic i <> "' but accepted event '" <> ceName event <> "' is declared on topic '" <> ceTopic event <> "'"
            | event <- ctrEvents c,
              ceName event `elem` inkAccept i,
              ceTopic event /= inkTopic i
            ],
            [ mkErr (locLine (inkLoc i)) IntakeBindUnresolved $
                "intake '" <> inkName i <> "' binds undeclared envelope or accepted-event field '" <> brField binding <> "'"
            | enforcesSpecSurfaceClosures languageContract,
              binding <- inkBinds i,
              brField binding `Set.notMember` resolvableFields c
            ],
            [ mkErr (locLine (inkLoc i)) IntakeDedupeKeyUnresolved $
                "intake '" <> inkName i <> "' dedupe key '" <> inkDedupeKey i <> "' is not an envelope or accepted-event field"
            | enforcesSpecSurfaceClosures languageContract,
              inkDedupeKey i `Set.notMember` resolvableFields c
            ],
            [ mkErr (locLine (inkLoc i)) IntakeDecodeSchemaVersionMismatch $
                "intake '"
                  <> inkName i
                  <> "' decode schemaVersion "
                  <> tInt (decBodySchemaVersion (inkDecode i))
                  <> " does not match contract '"
                  <> ctrName c
                  <> "' schemaVersion "
                  <> tInt (ctrSchemaVersion c)
            | enforcesSpecSurfaceClosures languageContract,
              decBodySchemaVersion (inkDecode i) /= ctrSchemaVersion c
            ]
          ]
    bindFlagWarnings =
      [ Diagnostic
          { line = locLine (inkLoc i),
            severity = Warning,
            code = IntakeBindFlagUnenforced,
            relatedLocations = [],
            message =
              "intake '"
                <> inkName i
                <> "' bind for '"
                <> brField binding
                <> "' declares "
                <> bindFlagText binding
                <> ", but generated code does not consume envelope bindings"
          }
      | binding <- inkBinds i,
        brRequired binding || brCrossCheck binding
      ]
    lookupContract n = case [c | c <- specContracts spec, ctrName c == n] of (c : _) -> Just c; [] -> Nothing
    resolvableFields contract =
      canonicalIntakeEnvelopeFields
        <> Set.fromList
          [ cfName field
          | event <- ctrEvents contract,
            ceName event `elem` inkAccept i,
            field <- ceFields event
          ]
    bindFlagText binding = case (brRequired binding, brCrossCheck binding) of
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
    el = locLine (emLoc e)
    skipRule =
      [ mkErr el EmitSkipMissing ("emit '" <> emName e <> "' map must end with an explicit '_ => skip' catch-all (hole-kind 7 optionality)")
      | not (emSkip e)
      ]
    duplicateCases =
      [ mkErr (locLine (emrLoc row)) EmitMapDuplicateCase $
          "emit '" <> emName e <> "' repeats map discriminant '" <> emrValue row <> "'; the first row would shadow this row"
      | enforcesSpecSurfaceClosures languageContract,
        row <- duplicatesBy emrValue (emMap e)
      ]
    coupling = case [c | c <- specContracts spec, ctrName c == emContract e] of
      [] -> [mkErr el EmitUnresolvedContract ("emit '" <> emName e <> "' references undeclared contract '" <> emContract e <> "'")]
      (c : _) ->
        [ mkErr el EmitUnresolvedContract ("emit '" <> emName e <> "' topic '" <> emTopic e <> "' is not a topic of contract '" <> emContract e <> "'")
        | emTopic e `notElem` map fst (ctrTopics c)
        ]
          ++ [ mkErr (locLine (emrLoc r)) EmitUnresolvedContract ("emit '" <> emName e <> "' maps to event '" <> emrEvent r <> "' not declared in contract '" <> emContract e <> "'")
             | r <- emMap e,
               emrEvent r `notElem` map ceName (ctrEvents c)
             ]
          ++ [ mkErr (locLine (emrLoc row)) TopicAffinityMismatch $
                 "emit '" <> emName e <> "' publishes on topic '" <> emTopic e <> "' but mapped event '" <> emrEvent row <> "' is declared on topic '" <> ceTopic event <> "'"
             | row <- emMap e,
               event <- ctrEvents c,
               ceName event == emrEvent row,
               ceTopic event /= emTopic e
             ]

validatePublisher :: EffectiveLanguageContract -> Spec -> PublisherNode -> [Diagnostic]
validatePublisher languageContract spec p =
  unresolvedEmit ++ orderingVocabulary ++ backoffPolicy ++ attemptsFloor ++ outboxField ++ windows
  where
    publisherLine = locLine (pubLoc p)
    unresolvedEmit =
      [ mkErr publisherLine PublisherUnresolvedEmit ("publisher '" <> pubName p <> "' references undeclared emit '" <> pubEmit p <> "'")
      | pubEmit p `notElem` [emName e | NEmit e <- specNodes spec]
      ]
    orderingVocabulary =
      [ mkErr publisherLine PublisherOrderingUnknown $
          "publisher '"
            <> pubName p
            <> "' has unknown ordering '"
            <> pubOrdering p
            <> "'; expected PerKeyHeadOfLine, PerSourceStream, StopTheLine, or BestEffort"
      | pubOrdering p `Set.notMember` publisherOrderings
      ]
    backoffPolicy =
      [ mkErr publisherLine PublisherBackoffInvalid $
          "publisher '" <> pubName p <> "' has an invalid " <> problem
      | Just problem <- [backoffProblemMaybe (pubBackoff p)]
      ]
    attemptsFloor =
      [ mkErr publisherLine PublisherMaxAttemptsBelowMinimum $
          "publisher '" <> pubName p <> "' maxAttempts must be at least 1"
      | enforcesSpecSurfaceClosures languageContract,
        pubMaxAttempts p < 1
      ]
    outboxField = case [emitNode | NEmit emitNode <- specNodes spec, emName emitNode == pubEmit p] of
      [] -> []
      emitNode : _ ->
        [ mkErr publisherLine PublisherOutboxFieldUnresolved $
            "publisher '" <> pubName p <> "' outboxId field '" <> pubOutboxField p <> "' is not messageId, idempotencyKey, or a field of an event mapped by emit '" <> pubEmit p <> "'"
        | enforcesSpecSurfaceClosures languageContract,
          pubOutboxField p `Set.notMember` allowedOutboxFields emitNode
        ]
    allowedOutboxFields emitNode =
      Set.fromList ("messageId" : "idempotencyKey" : mappedContractFields emitNode)
    mappedContractFields emitNode =
      [ fieldDslName (resolveContractFieldIdentity field)
      | contract <- specContracts spec,
        ctrName contract == emContract emitNode,
        event <- ctrEvents contract,
        ceName event `elem` map emrEvent (emMap emitNode),
        field <- ceFields event
      ]
    windows =
      windowRangeRule languageContract publisherLine ("publisher '" <> pubName p <> "' backoff") (boWindow (pubBackoff p))
        ++ maybe [] (windowRangeRule languageContract publisherLine ("publisher '" <> pubName p <> "' maximum backoff")) (boMax (pubBackoff p))

publisherOrderings :: Set Name
publisherOrderings = Set.fromList ["PerKeyHeadOfLine", "PerSourceStream", "StopTheLine", "BestEffort"]

backoffProblemMaybe :: BackoffSpec -> Maybe Text
backoffProblemMaybe backoff = case boKind backoff of
  "constant" -> Nothing
  "exponential" -> case (boMax backoff, boMultiplier backoff) of
    (Just maximumWindow, Just multiplierText) ->
      case (validationWindowSeconds (boWindow backoff), validationWindowSeconds maximumWindow, readMaybe (T.unpack multiplierText) :: Maybe Double) of
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
    il = locLine (inkLoc i)
    -- `decBodyStrict` reaches nothing but the pretty-printer: generated contract
    -- codecs decode every declared body field as required and admit no lenient
    -- mode, so `body strict` describes what happens and `body lenient` does not.
    decodePosture =
      [ mkSurfaceRefusal languageContract il DecodeBodyPostureUnsupported $
          "intake '"
            <> inkName i
            <> "' declares 'body lenient', but generated contract codecs decode a body strictly: every declared field is required and no lenient fallback is emitted. Write 'body strict' to describe what runs"
      | not (decBodyStrict (inkDecode i))
      ]
    rows = inkDisposition i
    requiredOutcomes =
      ["processed", "duplicate", "inProgress", "previouslyFailed", "decodeFailed", "dedupeFailed", "storeFailed"]
    completeness =
      [ mkErr il DispositionIncomplete $
          "intake '" <> inkName i <> "' disposition table is missing outcome '" <> o <> "'"
      | o <- requiredOutcomes,
        o `notElem` map drOutcome rows
      ]
    duplicateRows =
      [ mkErr (locLine (drLoc row)) DispositionDuplicateOutcome $
          "intake '" <> inkName i <> "' repeats disposition outcome '" <> drOutcome row <> "'; the first row would shadow this row"
      | row <- duplicatesBy drOutcome rows
      ]
    windows =
      concat
        [ windowRangeRule languageContract (locLine (drLoc row)) ("intake '" <> inkName i <> "' retry") window
        | row <- rows,
          IRetry window <- [drAction row]
        ]
    dedupeVocabulary =
      [ mkErr il IntakeDedupePolicyUnknown $
          "intake '"
            <> inkName i
            <> "' has unknown dedupe policy '"
            <> inkDedupePolicy i
            <> "'; expected PreferIntegrationMessageId, PreferSourceEventIdentity, or KafkaDeliveryIdentity"
      | inkDedupePolicy i `Set.notMember` intakeDedupePolicies
      ]
    decodeVersionFloor =
      [ mkErr il IntakeDecodeSchemaVersionBelowMinimum $
          "intake '" <> inkName i <> "' decode schemaVersion must be at least 1"
      | enforcesSpecSurfaceClosures languageContract,
        decBodySchemaVersion (inkDecode i) < 1
      ]
    envelopeVocabulary =
      [ mkErr il IntakeEnvelopePolicyUnknown $
          "intake '" <> inkName i <> "' has unsupported envelope policy " <> T.pack (show (decEnvelope (inkDecode i))) <> "; expected \"strict-required lenient-optional\""
      | enforcesSpecSurfaceClosures languageContract,
        decEnvelope (inkDecode i) /= "strict-required lenient-optional"
      ]
    firstRow outcome = case [row | row <- rows, drOutcome row == outcome] of
      (row : _) -> Just row
      [] -> Nothing
    isRetry row = case drAction row of IRetry _ -> True; _ -> False
    inversions =
      [ mkErr (locLine (drLoc row)) DispositionDuplicateRetry $
          "intake '" <> inkName i <> "': a 'duplicate' redelivery must be ackOk (success), not retry"
      | Just row <- [firstRow "duplicate"],
        isRetry row
      ]
        ++ [ mkErr (locLine (drLoc row)) DispositionPreviouslyFailedRetry $
               "intake '" <> inkName i <> "': 'previouslyFailed' must dead-letter, not retry (a prior failure won't succeed on replay)"
           | Just row <- [firstRow "previouslyFailed"],
             isRetry row
           ]
        ++ [ mkErr (locLine (drLoc row)) DispositionDecodeUnboundedRetry $
               "intake '" <> inkName i <> "': 'decodeFailed' must dead-letter (terminal), not retry unboundedly"
           | Just row <- [firstRow "decodeFailed"],
             isRetry row
           ]

intakeDedupePolicies :: Set Name
intakeDedupePolicies = Set.fromList ["PreferIntegrationMessageId", "PreferSourceEventIdentity", "KafkaDeliveryIdentity"]

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
  concat [sagaCategoryRule, noWallClock, runtimeOwnedDispatchId, crossNodeCoupling, strictSurfaceResolution, timerCeiling, policyRules, ambiguityRule, benignInversions, onAppendedArms, notMineArm]
  where
    -- Generated dispatch code appends and then acks; `Keiro.ProcessManager` has
    -- no branch that retries or dead-letters a *successful* append. Only AckOk
    -- describes what runs.
    onAppendedArms =
      [ mkSurfaceRefusal languageContract (locLine (dispLoc d)) DispatchOnAppendedUnsupported $
          "dispatch to '"
            <> dispTarget d
            <> "' maps on-appended => "
            <> dispText (onAppended (dispDisposition d))
            <> ", but a successful append is always acked: no runtime path retries or dead-letters an event it just appended. Write 'on-appended AckOk'"
      | d <- hDispatch (procHandle p),
        onAppended (dispDisposition d) /= DAckOk
      ]

    -- The timer worker marks a timer Fired only when the fire action returns the
    -- id of an event it appended (`Keiro.Timer.runTimerWorkerWith`). A not-mine
    -- dispatch produces no such id, so the row is left Firing and requeued on a
    -- later pass — which is exactly Retry. Fired is not reachable.
    notMineArm =
      [ mkSurfaceRefusal languageContract (locLine (tmLoc timer)) TimerNotMineUnsupported $
          "timer '"
            <> tmName timer
            <> "' maps not-mine => Fired, but the timer worker marks a timer Fired only when the fire action returns the id of the event it appended; a dispatch that is not this timer's has no such id, so the row is requeued instead. Write 'not-mine Retry'"
      | notMine (fireDisposition (tmFire timer)) == OFired
      ]
    aggregates = [a | NAggregate a <- specNodes spec]
    aggNames = map aggName aggregates
    projectionTables = [projTable projection | aggregate <- aggregates, Just projection <- [aggProjection aggregate]]
    inputFields = map fieldName (inFields (procInput p))
    timeFields = [fieldName f | f <- inFields (procInput p), fieldType f == Just "Time"]
    timer = procTimer p
    pl = locLine (procLoc p)

    sagaCategoryRule =
      [ mkErr pl SagaCategoryIllegal $
          "saga category " <> T.pack (show (sagaCategory (procSaga p))) <> " " <> reason
      | Just reason <- [sagaCategoryError (sagaCategory (procSaga p))]
      ]

    -- TIME IS INJECTED, NOT SAMPLED: fireAt's field must be a declared :Time
    -- input field. (FireAtExpr has no clock-sampling constructor, so this is a
    -- field-resolution + typed-as-Time check.)
    noWallClock =
      let f = faField (tmFireAt timer)
       in if f `notElem` inputFields
            then
              [ mkErr (locLine (tmLoc timer)) ProcessFireAtNotInjected $
                  "timer '" <> tmName timer <> "' fireAt field '" <> f <> "' is not a field of input '" <> inName (procInput p) <> "'"
              ]
            else
              [ mkErr (locLine (tmLoc timer)) ProcessFireAtNotInjected $
                  "timer '" <> tmName timer <> "' fireAt references '" <> f <> "', which is not a declared :Time field of input '" <> inName (procInput p) <> "'"
              | f `notElem` timeFields
              ]

    -- Dispatched (and fired) command ids are runtime-owned; no field binding may
    -- supply a commandId/id.
    runtimeOwnedDispatchId =
      [ mkErr pl ProcessDispatchIdSupplied $
          "advance command '" <> advCommand advance <> "' supplies a runtime-owned id field '" <> fbName binding <> "'; remove it"
      | let advance = hAdvance (procHandle p),
        binding <- advFields advance,
        fbName binding `elem` (["commandId", "id"] :: [Name])
      ]
        ++ [ mkErr (locLine (dispLoc d)) ProcessDispatchIdSupplied $
               "dispatch to '" <> dispTarget d <> "' supplies a runtime-owned id field '" <> fbName b <> "'; remove it"
           | d <- hDispatch (procHandle p),
             b <- dispFields d,
             fbName b `elem` (["commandId", "id"] :: [Name])
           ]
        ++ [ mkErr (locLine (tmLoc timer)) ProcessDispatchIdSupplied $
               "timer fire supplies a runtime-owned id field '" <> fbName b <> "'; remove it"
           | b <- fireFields (tmFire timer),
             fbName b `elem` (["commandId", "id"] :: [Name])
           ]

    -- Aggregate, command, field, timer, and projection references must resolve.
    crossNodeCoupling =
      [ mkErr pl ProcessUnresolvedRef ("saga '" <> sagaAgg (procSaga p) <> "' does not resolve to a declared aggregate")
      | sagaAgg (procSaga p) `notElem` aggNames
      ]
        ++ [ mkErr pl ProcessUnresolvedRef ("target '" <> procTarget p <> "' does not resolve to a declared aggregate")
           | procTarget p `notElem` aggNames
           ]
        ++ [ mkErr (locLine (tmLoc timer)) ProcessUnresolvedRef ("timer fire target '" <> fireTarget (tmFire timer) <> "' must be the saga or the target aggregate")
           | fireTarget (tmFire timer) `notElem` [sagaAgg (procSaga p), procTarget p]
           ]
        ++ resolveCommand pl "advance" (sagaAgg (procSaga p)) (advCommand advance) (advFields advance)
        ++ concatMap resolveDispatch (hDispatch (procHandle p))
        ++ resolveCommand (locLine (tmLoc timer)) "timer fire" (fireTarget fire) (fireCommand fire) (fireFields fire)
        ++ [ mkErr pl ProcessUnresolvedRef $
               "process '" <> procId p <> "' schedules undeclared timer '" <> hSchedule (procHandle p) <> "'; declared timer is '" <> tmName timer <> "'"
           | hSchedule (procHandle p) /= tmName timer
           ]
        ++ [ mkErr pl ProcessUnresolvedRef $
               "process '" <> procId p <> "' references undeclared projection table '" <> projection <> "'"
           | projection <- procProjections p,
             projection `notElem` projectionTables
           ]
      where
        advance = hAdvance (procHandle p)
        fire = tmFire timer
        resolveDispatch dispatch =
          resolveCommand
            (locLine (dispLoc dispatch))
            "dispatch"
            (dispTarget dispatch)
            (dispCommand dispatch)
            (dispFields dispatch)
        resolveCommand diagnosticLine context target command bindings = case lookupAggregate target of
          Nothing -> []
          Just aggregate -> case [decl | decl <- aggCommands aggregate, cmdName decl == command] of
            [] ->
              [ mkErr diagnosticLine ProcessUnresolvedRef $
                  context <> " command '" <> command <> "' is not declared by aggregate '" <> target <> "'"
              ]
            (declaration : _) ->
              [ mkErr diagnosticLine ProcessFieldBindingUnresolved $
                  context <> " command '" <> command <> "' binds undeclared target field '" <> fbName binding <> "'"
              | binding <- bindings,
                fbName binding `notElem` map aggregateFieldName (cmdFields declaration)
              ]
        lookupAggregate name = case [aggregate | aggregate <- aggregates, aggName aggregate == name] of
          (aggregate : _) -> Just aggregate
          [] -> Nothing

    strictSurfaceResolution
      | not (enforcesSpecSurfaceClosures languageContract) = []
      | otherwise = correlateFieldRule ++ dispatchKeyRules ++ bindingScopeRules ++ idFieldRules ++ fireWindowRule

    correlateFieldRule =
      [ mkErr pl ProcessKeyFieldUnknown $
          "correlate references 'input." <> corrField (procCorrelate p) <> "' but input '" <> inName (procInput p) <> "' does not declare that field"
      | corrField (procCorrelate p) `notElem` inputFields
      ]

    dispatchKeyRules =
      [ mkErr (locLine (dispLoc dispatch)) ProcessDispatchKeyUnresolved $
          "dispatch to '" <> dispTarget dispatch <> "' uses unresolved key '" <> dispKey dispatch <> "'; expected correlationId or input.<declared-field>"
      | dispatch <- hDispatch (procHandle p),
        not (processKeyInScope (dispKey dispatch))
      ]
        ++ [ mkErr (locLine (tmLoc timer)) ProcessDispatchKeyUnresolved $
               "timer fire to '" <> fireTarget (tmFire timer) <> "' uses unresolved key '" <> fireKey (tmFire timer) <> "'; expected correlationId or input.<declared-field>"
           | not (processKeyInScope (fireKey (tmFire timer)))
           ]

    processKeyInScope value =
      value == "correlationId"
        || case T.stripPrefix "input." value of
          Just field -> field `elem` inputFields
          Nothing -> False

    bindingScopeRules =
      bindingRules pl "advance" inputFields (advFields (hAdvance (procHandle p)))
        ++ concatMap
          (\dispatch -> bindingRules (locLine (dispLoc dispatch)) "dispatch" inputFields (dispFields dispatch))
          (hDispatch (procHandle p))
        ++ bindingRules
          (locLine (tmLoc timer))
          "timer fire"
          (inputFields <> map fbName (tmPayload timer) <> ["timerId"])
          (fireFields (tmFire timer))

    bindingRules diagnosticLine context bareScope bindings =
      [ mkErr diagnosticLine ProcessBindingUnscoped $
          context <> " binding '" <> fbName binding <> maybe "" ("=" <>) (fbValue binding) <> "' is outside the process input and timer scopes"
      | binding <- bindings,
        not (bindingInScope bareScope binding)
      ]

    bindingInScope bareScope binding = case fbValue binding of
      Nothing -> fbName binding `elem` bareScope
      Just value
        | isQuoted value -> True
        | value == "timer.id" -> True
        | Just field <- T.stripPrefix "input." value -> field `elem` inputFields
        | otherwise -> value `elem` bareScope

    isQuoted value = T.length value >= 2 && T.head value == '"' && T.last value == '"'

    idFieldRules =
      [ mkErr (locLine (tmLoc timer)) TimerIdFieldNotCorrelation $
          "timer '" <> tmName timer <> "' " <> context <> " derives from '" <> ideField expression <> "'; only correlationId is implemented by generated runtime code"
      | (context, expression) <- [("id", tmId timer), ("fired-event-id", fireFiredEventId (tmFire timer))],
        ideField expression /= "correlationId"
      ]

    fireWindowRule =
      windowRangeRule languageContract (locLine (tmLoc timer)) ("timer '" <> tmName timer <> "' fireAt") (faWindow (tmFireAt timer))

    timerCeiling =
      [ mkErr (locLine (tmLoc timer)) ProcessTimerCeilingInvalid $
          "timer '" <> tmName timer <> "' max-attempts must be at least 1"
      | tmMaxAttempts timer < 1
      ]

    policyRules =
      policyConsistency
        (procId p)
        (procLoc p)
        (procRejected p)
        [ (dispCommand dispatch, dispLoc dispatch, dispDisposition dispatch)
        | dispatch <- hDispatch (procHandle p)
        ]

    ambiguityRule =
      [ mkErr (locLine (tmLoc timer)) AmbiguousMarkedBenign $
          "timer '" <> tmName timer <> "' maps on-ambiguous => Fired; CommandAmbiguous means multiple aggregate edges matched and is never a benign success. Use on-ambiguous Retry so the attempts ceiling dead-letters the definition bug"
      | onAmbiguous (fireDisposition (tmFire timer)) == OFired
      ]

    -- Surface the dangerous benign inversions the author confirmed (warnings).
    benignInversions =
      [ Diagnostic (locLine (tmLoc timer)) Warning ProcessBenignInversion [] $
          "timer '" <> tmName timer <> "' maps on-reject => Fired (a CommandRejected is treated as benign success)"
      | onReject (fireDisposition (tmFire timer)) == OFired
      ]
        ++ [ Diagnostic (locLine (dispLoc d)) Warning ProcessBenignInversion [] $
               "dispatch to '" <> dispTarget d <> "' maps on-duplicate => AckOk (a duplicate is treated as benign success)"
           | d <- hDispatch (procHandle p),
             onDuplicate (dispDisposition d) == DAckOk
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
    Right derived -> HaskellName.renderLowerCamelName (HaskellName.lowerCamel derived)
    Left _ -> raw
  where
    site =
      HaskellName.NameSite
        { HaskellName.siteKind = HaskellName.GeneratedFieldSite,
          HaskellName.siteLogicalName = raw,
          HaskellName.siteOwner = "validation field resolution",
          HaskellName.siteLine = 0
        }

-- | EP-108 rules for a stateless content-based router.
validateRouter :: EffectiveLanguageContract -> Spec -> RouterNode -> [Diagnostic]
validateRouter languageContract spec router =
  concat
    [ references,
      keyField,
      bindingScope,
      commandReference,
      readModelReference,
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
            <> rdCommand dispatch
            <> "' maps on-appended => "
            <> dispText (onAppended (rdDisposition dispatch))
            <> ", but a successful append is always acked: no runtime path retries or dead-letters an event it just appended. Write 'on-appended AckOk'"
      | onAppended (rdDisposition dispatch) /= DAckOk
      ]
    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]
    readModels = [readModel | NReadModel readModel <- specNodes spec]
    inputFields = map fieldName (inFields (rtInput router))
    resolvedFields = rvRow (rtResolve router)
    dispatch = rtDispatch router
    routerLine = locLine (rtLoc router)
    dispatchLine = locLine (rdLoc dispatch)

    targetAggregate = case [aggregate | aggregate <- aggregates, aggName aggregate == rtTarget router] of
      aggregate : _ -> Just aggregate
      [] -> Nothing

    projectionTables = [projTable projection | aggregate <- aggregates, Just projection <- [aggProjection aggregate]]

    references =
      [ mkErr routerLine RouterUnresolvedRef $
          "router '" <> rtId router <> "' targets aggregate '" <> rtTarget router <> "' but no such aggregate is declared"
      | targetAggregate == Nothing
      ]
        ++ [ mkErr routerLine RouterUnresolvedRef $
               "router '" <> rtId router <> "' references undeclared projection table '" <> projection <> "'"
           | projection <- rtProjections router,
             projection `notElem` projectionTables
           ]

    keyField =
      [ mkErr routerLine RouterKeyFieldUnknown $
          "key references 'input." <> corrField (rtKey router) <> "' but input '" <> inName (rtInput router) <> "' does not declare that field"
      | corrField (rtKey router) `notElem` inputFields
      ]

    bindingScope =
      [ mkErr dispatchLine RouterBindingUnscoped $
          "dispatch binding '" <> fbName binding <> maybe "" ("=" <>) (fbValue binding) <> "' is outside the router input and resolve-row scopes"
      | binding <- rdFields dispatch,
        not (bindingInScope binding)
      ]
      where
        bindingInScope binding = case fbValue binding of
          Nothing -> fbName binding `elem` inputFields
          Just value
            | isQuoted value -> True
            | Just field <- T.stripPrefix "input." value -> field `elem` inputFields
            | Just field <- T.stripPrefix "resolved." value -> field `elem` resolvedFields
            | otherwise -> False
        isQuoted value = T.length value >= 2 && T.head value == '"' && T.last value == '"'

    commandReference = case targetAggregate of
      Nothing -> []
      Just aggregate -> case [command | command <- aggCommands aggregate, cmdName command == rdCommand dispatch] of
        [] ->
          [ mkErr dispatchLine RouterCommandUnknown $
              "dispatch command '" <> rdCommand dispatch <> "' is not declared by aggregate '" <> aggName aggregate <> "'"
          ]
        command : _ ->
          [ mkErr dispatchLine RouterCommandUnknown $
              "dispatch command '" <> rdCommand dispatch <> "' binds undeclared target field '" <> fbName binding <> "'"
          | binding <- rdFields dispatch,
            fbName binding `notElem` map aggregateFieldName (cmdFields command)
          ]

    readModelReference = case rvSource (rtResolve router) of
      ResolveHole -> []
      ResolveReadModel name ->
        case [readModel | readModel <- readModels, rmName readModel == name] of
          [] ->
            [ mkErr (locLine (rvLoc (rtResolve router))) RouterUnresolvedRef $
                "router '" <> rtId router <> "' resolve names readmodel '" <> name <> "' but no such readmodel node is declared"
            ]
          readModel : _ ->
            [ mkErr (locLine (rvLoc (rtResolve router))) RouterReadModelUnverified $
                "router '" <> rtId router <> "' resolve row field '" <> column <> "' is not a declared column of readmodel '" <> name <> "'"
            | enforcesSpecSurfaceClosures languageContract,
              column <- rvRow (rtResolve router),
              column `notElem` map (logicalFieldSelector . rmcName) (rmColumns readModel)
            ]

    policyRules =
      policyConsistency
        (rtId router)
        (rtLoc router)
        (rtRejected router)
        [(rdCommand dispatch, rdLoc dispatch, rdDisposition dispatch)]

    duplicateNotice =
      [ Diagnostic dispatchLine Warning RouterBenignInversion [] $
          "router dispatch '" <> rdCommand dispatch <> "' maps on-duplicate => AckOk; Keiro.Router confirms the event id against the target stream before treating the duplicate as benign"
      | onDuplicate (rdDisposition dispatch) == DAckOk
      ]

-- | Reconcile per-dispatch prose with the one node-level policy the runtime
-- actually applies to a rejection-class failure group.
policyConsistency :: Name -> Loc -> PolicyChoice -> [(Name, Loc, DispatchDisposition)] -> [Diagnostic]
policyConsistency nodeName nodeLoc rejectedPolicy dispatches = contradictions ++ divergent ++ unused ++ ambiguityWarning
  where
    contradictions =
      [ mkErr (locLine dispatchLoc) PolicyContradiction $
          "dispatch '" <> command <> "' declares on-failed DeadLetter, but node '" <> nodeName <> "' does not declare rejected => deadLetter; align the dispatch story with the node-level RejectedCommandPolicy"
      | (command, dispatchLoc, disposition) <- dispatches,
        DDeadLetter _ <- [onFailed disposition],
        rejectedPolicy /= PolDeadLetter
      ]

    divergent = case dispatches of
      [] -> []
      (_, _, firstDisposition) : rest ->
        [ mkErr (locLine dispatchLoc) PolicyContradiction $
            "dispatch '" <> command <> "' has a different on-failed action from another dispatch in node '" <> nodeName <> "'; the runtime applies one RejectedCommandPolicy to the whole failure group"
        | (command, dispatchLoc, disposition) <- rest,
          not (sameFailureAction (onFailed disposition) (onFailed firstDisposition))
        ]

    unused =
      [ Diagnostic (locLine nodeLoc) Warning PolicyDeadLetterUnused [] $
          "node '" <> nodeName <> "' declares rejected => deadLetter but no dispatch on-failed arm says DeadLetter; the runtime policy is live, but the per-dispatch notation does not acknowledge it"
      | rejectedPolicy == PolDeadLetter,
        all (not . isDeadLetter . onFailed . third) dispatches
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

validateAggregate :: EffectiveLanguageContract -> Spec -> Aggregate -> [Diagnostic]
validateAggregate languageContract spec agg =
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
      wirePolicyRules,
      fieldWireKeyRules
    ]
  where
    emptyAggregate =
      [ mkErr (locLine (aggLoc agg)) AggregateEmpty $
          "aggregate '"
            <> aggName agg
            <> "' declares "
            <> renderMissing missingAggregateParts
            <> "; scaffold cannot lower an empty aggregate -- declare at least one command, one event, and one transition"
      | not (null missingAggregateParts)
      ]
    missingAggregateParts =
      [ label
      | (isMissing, label) <-
          [ (null (aggCommands agg), "no commands"),
            (null (aggEvents agg), "no events"),
            (null (aggTransitions agg), "no transitions")
          ],
        isMissing
      ]
    renderMissing [] = ""
    renderMissing [onlyPart] = onlyPart
    renderMissing [firstPart, secondPart] = firstPart <> " and " <> secondPart
    renderMissing parts = T.intercalate ", " (init parts) <> ", and " <> last parts

    states = Set.fromList (map stName (aggStates agg))
    terminals = Set.fromList [stName s | s <- aggStates agg, stTerminal s]
    commandFields :: Map Name [Name]
    commandFields = Map.fromList [(cmdName c, map aggregateFieldName (cmdFields c)) | c <- aggCommands agg]
    commandNames = Map.keysSet commandFields
    eventNames = Set.fromList (map evName (aggEvents agg))
    enumCtorNames = Set.fromList [c | e <- specEnums spec, (c, _) <- enumCtors e]
    ruleNames = Set.fromList (map ruleName (specRules spec))
    registerNames = Set.fromList (map regName (aggRegs agg))

    eventFieldsFor event =
      case evBody event of
        EventFields fields -> fields
        EventFromCommand commandName ->
          [ field
          | command <- aggCommands agg,
            cmdName command == commandName,
            field <- cmdFields command
          ]

    fieldWireKeyRules =
      concat
        [ wireKeyRulesForRecord
            ("aggregate '" <> aggName agg <> "' command '" <> cmdName command <> "'")
            Nothing
            (map resolveAggregateFieldIdentity (cmdFields command))
        | command <- aggCommands agg
        ]
        <> concat
          [ wireKeyRulesForRecord
              ("aggregate '" <> aggName agg <> "' event '" <> evName event <> "'")
              (Just ("kind", "event envelope key"))
              (map resolveAggregateFieldIdentity (eventFieldsFor event))
          | event <- aggEvents agg
          ]

    snapshotRules = case aggSnapshot agg of
      Nothing -> []
      Just snapshot ->
        [ mkErr (locLine (snapLoc snapshot)) SnapshotIntervalInvalid $
            "aggregate '" <> aggName agg <> "': snapshot every requires an interval of at least 1; non-positive runtime intervals silently disable snapshots"
        | SnapEvery interval <- [snapPolicy snapshot],
          interval < 1
        ]
          ++ [ mkErr (locLine (snapLoc snapshot)) SnapshotCodecFixtureInvalid $
                 "aggregate '" <> aggName agg <> "': snapshot state-codec version must be at least 1 and shape-hash must be non-empty"
             | snapCodecVersion snapshot < 1 || T.null (snapShapeHash snapshot)
             ]

    wirePolicyRules = case aggWire agg of
      Just wire
        | enforcesSpecSurfaceClosures languageContract,
          wireKind wire /= "ctorName" || wireFields wire /= "camelCase" ->
            [ mkErr (locLine (aggLoc agg)) WireClauseUnsupported $
                "aggregate '"
                  <> aggName agg
                  <> "' wire clause describes kind="
                  <> wireKind wire
                  <> " fields="
                  <> wireFields wire
                  <> "; generated bytes currently support only kind=ctorName fields=camelCase"
            ]
      _ -> []

    duplicateMembers =
      [ mkErr (locLine (cmdLoc c)) DuplicateCommandName $
          "aggregate '" <> aggName agg <> "' declares command '" <> cmdName c <> "' more than once"
      | c <- duplicatesBy cmdName (aggCommands agg)
      ]
        ++ [ mkErr (locLine (evLoc e)) DuplicateEventName $
               "aggregate '" <> aggName agg <> "' declares event '" <> evName e <> "' more than once"
           | e <- duplicatesBy evName (aggEvents agg)
           ]
        ++ [ mkErr (locLine (aggregateFieldLoc field)) AggregateDuplicateFieldName $
               "aggregate '" <> aggName agg <> "' command '" <> cmdName command <> "' declares field '" <> aggregateFieldName field <> "' more than once"
           | command <- aggCommands agg,
             field <- duplicatesBy aggregateFieldName (cmdFields command)
           ]
        ++ [ mkErr (locLine (aggregateFieldLoc field)) AggregateDuplicateFieldName $
               "aggregate '" <> aggName agg <> "' event '" <> evName event <> "' declares field '" <> aggregateFieldName field <> "' more than once"
           | event <- aggEvents agg,
             EventFields fields <- [evBody event],
             field <- duplicatesBy aggregateFieldName fields
           ]
        ++ [ mkErr (locLine (stLoc state)) AggregateDuplicateState $
               "aggregate '" <> aggName agg <> "' declares state '" <> stName state <> "' more than once"
           | state <- duplicatesBy stName (aggStates agg)
           ]
        ++ [ mkErr (locLine (regLoc register)) AggregateDuplicateRegister $
               "aggregate '" <> aggName agg <> "' declares register '" <> regName register <> "' more than once"
           | enforcesSpecSurfaceClosures languageContract,
             register <- duplicatesBy regName (aggRegs agg)
           ]
        ++ [ mkErr (locLine (tLoc transition)) TransitionDuplicateUnguarded $
               "aggregate '"
                 <> aggName agg
                 <> "' has more than one live unguarded transition for '"
                 <> tSource transition
                 <> " -- "
                 <> tCommand transition
                 <> "'; every matching command would be ambiguous"
           | group <- duplicateGroupsBy transitionKey unguardedTransitions,
             transition <- group
           ]
        ++ [ mkErr (locLine (tLoc guarded)) TransitionUnguardedSibling $
               "aggregate '"
                 <> aggName agg
                 <> "' guarded transition '"
                 <> tSource guarded
                 <> " -- "
                 <> tCommand guarded
                 <> "' overlaps an unguarded sibling at line "
                 <> tInt (locLine (tLoc unguarded))
           | enforcesSpecSurfaceClosures languageContract,
             guarded <- liveTransitions,
             tGuard guarded /= Nothing,
             unguarded : _ <- [[candidate | candidate <- unguardedTransitions, transitionKey candidate == transitionKey guarded]]
           ]
    liveTransitions = [transition | transition <- aggTransitions agg, tMode transition == TmLive]
    unguardedTransitions = [transition | transition <- liveTransitions, tGuard transition == Nothing]
    transitionKey transition = (tSource transition, tCommand transition)

    eventBodyRefs =
      [ mkErr (locLine (evLoc e)) UndeclaredCommand $
          "event '" <> evName e <> "' copies fields from undeclared command '" <> command <> "'"
      | e <- aggEvents agg,
        EventFromCommand command <- [evBody e],
        command `Set.notMember` commandNames
      ]

    outputMappingRules =
      [ mkErr (locLine (tLoc transition)) EventOutputCommandMismatch $
          "transition '"
            <> tSource transition
            <> " -- "
            <> consuming
            <> "' emits event '"
            <> eventName
            <> "' declared as fields("
            <> declared
            <> "); generated identity output is legal only when the transition consumes that same command"
      | transition <- aggTransitions agg,
        (emitIndex, eventName) <- zip [1 ..] (tEmits transition),
        Left OutputCommandMismatch {declaredSourceCommand = declared, consumingTransitionCommand = consuming} <- [eventOutputMapping spec agg transition emitIndex eventName]
      ]

    registerInitialScope = concatMap checkRegisterInitial (aggRegs agg)
    checkRegisterInitial r = case [e | e <- specEnums spec, TRef (enumName e) == regType r] of
      (e : _) -> case enumBinding e of
        Just _ ->
          [ outOfScope r "declaration-owned symbol selected by" "initial"
          | regInitialBare r /= Just "initial"
          ]
        Nothing ->
          [ outOfScope r "constructor of enum" (enumName e)
          | regInitialBare r `notElem` map (Just . fst) (enumCtors e)
          ]
      []
        | regType r == TRef (aggName agg <> "Vertex") ->
            [ outOfScope r "state of aggregate" (aggName agg)
            | maybe True (`Set.notMember` states) (regInitialBare r)
            ]
        | Just identifier <- firstMatching (\declaration -> regType r == TRef (idName declaration)) (specIds spec) -> case idBinding identifier of
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
      mkErr (locLine (regLoc r)) RegisterInitialOutOfScope $
        "register '" <> regName r <> "' initial '" <> renderRegInitial (regInitial r) <> "' is not a " <> expected <> " '" <> domain <> "'"
    regInitialBare r = case regInitial r of
      RegInitBare value -> Just value
      RegInitText _ -> Nothing
    renderRegInitial = \case
      RegInitBare value -> value
      RegInitText value -> value

    -- Rule 1: declared-reference for command / emit / goto / source.
    declaredRefs =
      concatMap transitionRefs (aggTransitions agg)
    transitionRefs t =
      [ mkErr (locLine (tLoc t)) UndeclaredCommand $
          "transition references undeclared command '" <> tCommand t <> "'"
      | not (tCommand t `Set.member` commandNames)
      ]
        ++ [ mkErr (locLine (tLoc t)) UndeclaredState $
               "transition source '" <> tSource t <> "' is not a declared state"
           | not (tSource t `Set.member` states)
           ]
        ++ [ mkErr (locLine (tLoc t)) UndeclaredState $
               "transition goto '" <> tGoto t <> "' is not a declared state"
           | not (tGoto t `Set.member` states)
           ]
        ++ [ mkErr (locLine (tLoc t)) UndeclaredEvent $
               "emit references undeclared event '" <> ev <> "'"
           | ev <- tEmits t,
             not (ev `Set.member` eventNames)
           ]

    -- Rule 2: reachability of every non-terminal state from the initial state
    -- (the first state in the list).
    reachability = case map stName (aggStates agg) of
      [] -> []
      (initial : _) ->
        let reached = bfs (Set.singleton initial) [initial]
         in [ mkErr (locLine (stLoc s)) UnreachableState $
                "state '" <> stName s <> "' is not reachable from the initial state '" <> initial <> "'"
            | s <- aggStates agg,
              not (stTerminal s),
              not (stName s `Set.member` reached)
            ]
    edgesFrom src = [tGoto t | t <- aggTransitions agg, tSource t == src]
    bfs seen [] = seen
    bfs seen (x : xs) =
      let nexts = [n | n <- edgesFrom x, not (n `Set.member` seen)]
       in bfs (foldr Set.insert seen nexts) (xs ++ nexts)

    -- Rule 3: a terminal state has no outgoing transition.
    terminalNoOutgoing =
      [ mkErr (locLine (tLoc t)) TerminalHasOutgoing $
          "terminal state '" <> tSource t <> "' has an outgoing transition"
      | t <- aggTransitions agg,
        tSource t `Set.member` terminals
      ]

    -- Rule 4: every atom in a guard or write Expr resolves to a register, a
    -- field of the transition's command, an enum constructor, a rule, or a bool.
    guardScope = concatMap transitionScope (aggTransitions agg)
    transitionScope t =
      let inScope =
            registerNames
              `Set.union` Set.fromList (Map.findWithDefault [] (tCommand t) commandFields)
              `Set.union` enumCtorNames
              `Set.union` ruleNames
              -- State names are constructors of the implicit vertex enum, so a
              -- @write reservationState := Held@ references a state legitimately.
              `Set.union` states
          exprs = maybe [] pure (tGuard t) ++ map snd (tWrites t)
          badAtoms =
            [ n
            | e <- exprs,
              n <- exprNames e,
              not (n `Set.member` clockAtoms), -- clock atoms reported separately
              not (n `Set.member` inScope)
            ]
          badTargets = [target | (target, _) <- tWrites t, target `Set.notMember` registerNames]
       in [ mkErr (locLine (tLoc t)) WriteTargetNotRegister $
              "write target '" <> target <> "' is not a register of aggregate '" <> aggName agg <> "'"
          | target <- dedup badTargets
          ]
            ++ [ mkErr (locLine (tLoc t)) GuardAtomOutOfScope $
                   "atom '" <> n <> "' in transition '" <> tSource t <> " -- " <> tCommand t <> "' resolves to no register, command field, enum constructor, or rule"
               | n <- dedup badAtoms
               ]

    -- Rule 5 (cross-cutting): no guard or write Expr samples a wall clock.
    clockFree = concatMap transitionClock (aggTransitions agg)
    transitionClock t =
      let exprs = maybe [] pure (tGuard t) ++ map snd (tWrites t)
          sampled = [n | e <- exprs, n <- exprNames e, n `Set.member` clockAtoms]
       in [ mkErr (locLine (tLoc t)) ClockSampled $
              "transition '" <> tSource t <> " -- " <> tCommand t <> "' samples the wall clock via '" <> n <> "'; time must be an injected input field, not sampled"
          | n <- dedup sampled
          ]

    -- EP-107: a projection references a first-class read model when one exists.
    -- Legacy standalone projections remain legal, but are surfaced as warnings.
    projectionKeyResolution =
      [ mkErr (locLine (projLoc projection)) AggProjectionKeyUnresolved $
          "projection '" <> projTable projection <> "' key '" <> projKey projection <> "' is not a register, command field, or event field of aggregate '" <> aggName agg <> "'"
      | enforcesSpecSurfaceClosures languageContract,
        Just projection <- [aggProjection agg],
        projKey projection `Set.notMember` projectionFields
      ]
    projectionFields =
      registerNames
        `Set.union` Set.fromList [fieldDslName (resolveAggregateFieldIdentity field) | command <- aggCommands agg, field <- cmdFields command]
        `Set.union` Set.fromList [fieldDslName (resolveAggregateFieldIdentity field) | event <- aggEvents agg, field <- eventFieldsFor event]

    projectionSafety = case aggProjection agg of
      Nothing -> []
      Just projection -> case [readModel | NReadModel readModel <- specNodes spec, rmName readModel == projTable projection] of
        [] ->
          [ mkErr (locLine (projLoc projection)) RmStrongInlineOnly $
              "projection '" <> projTable projection <> "' declares consistency = Strong but has no readmodel node; a standalone projection is inline-only and has no subscription cursor"
          | projConsistency projection == Just Strong
          ]
            ++ [ Diagnostic
                   { line = locLine (projLoc projection),
                     severity = Warning,
                     code = RmProjectionWithoutNode,
                     relatedLocations = [],
                     message = "projection '" <> projTable projection <> "' has no readmodel node; registration, schema identity, consistency, and rebuild helpers are unavailable"
                   }
               ]
        (readModel : _) ->
          [ mkErr (locLine (projLoc projection)) RmConsistencyConflict $
              "projection '" <> projTable projection <> "' declares consistency " <> T.pack (show projectionConsistency) <> " but its readmodel node declares " <> T.pack (show (rmConsistency readModel))
          | Just projectionConsistency <- [projConsistency projection],
            projectionConsistency /= rmConsistency readModel
          ]

    -- Rule 6 (hole-kind 3, mapping): keys are exact event names, never suffixes;
    -- duplicates and dangling keys are errors, and non-partial maps are total.
    statusMapTotality = case aggProjection agg of
      Nothing -> []
      Just p ->
        let evs = map evName (aggEvents agg)
            pairs = maybe [] mapPairs (projStatusMap p)
            keys = map fst pairs
            partial = maybe False mapPartial (projStatusMap p)
            uncovered = [event | event <- evs, event `notElem` keys]
            dangling = [key | key <- keys, key `notElem` evs]
            duplicateKeys = map fst (duplicatesBy fst pairs)
         in [ mkErr (locLine (projLoc p)) StatusMapDanglingKey $
                "projection '" <> projTable p <> "' status-map key '" <> key <> "' is not an event name of aggregate '" <> aggName agg <> "'"
            | key <- dangling
            ]
              ++ [ mkErr (locLine (projLoc p)) StatusMapDuplicateKey $
                     "projection '" <> projTable p <> "' repeats status-map key '" <> key <> "'"
                 | key <- duplicateKeys
                 ]
              ++ [ mkErr (locLine (projLoc p)) StatusMapNotTotal $
                     "projection '" <> projTable p <> "' status-map is not total over events {" <> T.intercalate ", " uncovered <> "}"
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
    liveEmittedNames = Set.fromList (concatMap tEmits [t | t <- aggTransitions agg, tMode t == TmLive])
    replayEmittedNames = Set.fromList (concatMap tEmits [t | t <- aggTransitions agg, tMode t == TmReplayOnly])
    maxEventVersion = maximum (1 : map evVersion (aggEvents agg))
    upcasterSources =
      Set.fromList
        [ source
        | event <- aggEvents agg,
          Just (source, _) <- [evUpcastFrom event]
        ]

    -- A non-initial event version must carry a contiguous upcaster (from v-1).
    versionUpcasterRule =
      [ mkErr (locLine (evLoc e)) EvtVersionMissingUpcaster $
          "event '" <> evName e <> "' version " <> tInt (evVersion e) <> " has no 'upcast from v" <> tInt (evVersion e - 1) <> "' clause"
      | e <- aggEvents agg,
        evVersion e > 1,
        maybe True ((/= evVersion e - 1) . fst) (evUpcastFrom e)
      ]

    -- Aggregate schema stamps are global, so every source version below the
    -- current maximum needs a permanent rung regardless of which event owns it.
    upcasterChainGapRule =
      [ mkErr (locLine (aggLoc agg)) UpcasterChainGap $
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
      [ mkErr (locLine (evLoc e)) DeprecatedEventStillEmitted $
          "deprecated event '" <> evName e <> "' is still emitted by a transition"
      | e <- aggEvents agg,
        evDeprecated e,
        evName e `Set.member` liveEmittedNames
      ]

    -- Retirement is a two-stage protocol. The pre-cutover marker keeps a live
    -- emitter. The deprecated stage removes that live emitter but retains a
    -- replay-only emitter until old payloads no longer need hydration.
    eventRetirementRules = concatMap eventRetirementRule (aggEvents agg)
    eventRetirementRule event
      | evRetiring event =
          [ mkErr (locLine (evLoc event)) EventRetirementInProgress $
              "retiring event '" <> evName event <> "' has no live emitting transition; keep it emitting while streams are terminalized or truncated, or cut over to 'deprecated event' with a replay-only emitting transition"
          | evName event `Set.notMember` liveEmittedNames
          ]
            ++ [ Diagnostic
                   { line = locLine (evLoc event),
                     severity = Warning,
                     code = EventRetirementInProgress,
                     relatedLocations = [],
                     message =
                       "event '" <> evName event <> "' is retiring: it stays fully live and replayable. Keep its live emitting transition until every affected stream is terminal or truncated; then flip it to 'deprecated event' and retain an equivalent replay-only emitting transition for as long as old payloads may be hydrated"
                   }
               | evName event `Set.member` liveEmittedNames
               ]
      | evDeprecated event =
          [ Diagnostic
              { line = locLine (evLoc event),
                severity = Warning,
                code = DeprecatedEventReplayHazard,
                relatedLocations = [],
                message =
                  "deprecated event '" <> evName event <> "' stays decodable but is not replayable: no replay-only transition emits it, so hydration of a live stream containing it fails with HydrationNoInvertingEdge. Restore an equivalent replay-only emitting transition, or terminalize/truncate every affected stream before deployment"
              }
          | any (not . stTerminal) (aggStates agg),
            evName event `Set.notMember` replayEmittedNames
          ]
            ++ [ Diagnostic
                   { line = locLine (evLoc event),
                     severity = Warning,
                     code = EventRetirementInProgress,
                     relatedLocations = [],
                     message =
                       "deprecated event '" <> evName event <> "' is off the live write path and remains replayable through a replay-only transition; retain that transition until every stream containing the event is terminal, truncated, or passes the replay audit"
                   }
               | evName event `Set.member` replayEmittedNames
               ]
      | otherwise = []

    -- The explicit `wire schemaVersion=` (if any) must equal the max event version.
    wireVersionRule = case aggWire agg of
      Just w
        | wireSchemaVersion w /= maxEventVersion ->
            [ Diagnostic
                { line = locLine (aggLoc agg),
                  severity = Warning,
                  code = WireSchemaVersionMismatch,
                  relatedLocations = [],
                  message =
                    "wire schemaVersion=" <> tInt (wireSchemaVersion w) <> " does not match the maximum event version " <> tInt maxEventVersion
                }
            ]
      _ -> []

    -- Plan 143: replay-only transition discipline. A replay-only transition
    -- exists to invert stored events, so one that emits nothing is dead
    -- weight (error); one whose (source, command) pair has no live sibling
    -- means the command is fully retired at that state — legitimate, but the
    -- fuller procedure is event retirement (docs/plans/139), so warn.
    replayOnlyRules = concatMap replayOnlyRule (aggTransitions agg)
    replayOnlyRule t
      | tMode t /= TmReplayOnly = []
      | otherwise =
          [ mkErr (locLine (tLoc t)) ReplayOnlyEmitsNothing $
              "replay-only transition '" <> tSource t <> " -- " <> tCommand t <> "' emits no event; a replay-only transition exists to invert stored events and is dead weight without an emit"
          | null (tEmits t)
          ]
            ++ [ Diagnostic
                   { line = locLine (tLoc t),
                     severity = Warning,
                     code = ReplayOnlyCommandStillLive,
                     relatedLocations = [],
                     message =
                       "replay-only transition '" <> tSource t <> " -- " <> tCommand t <> "' has no live sibling; command '" <> tCommand t <> "' is fully retired at state '" <> tSource t <> "' — if the intent is to retire its events too, follow the event-retirement procedure (docs/plans/139)"
                   }
               | not (any (\sibling -> tMode sibling == TmLive && tSource sibling == tSource t && tCommand sibling == tCommand t) (aggTransitions agg))
               ]

    eventlessStateChangeRules =
      [ mkErr (locLine (tLoc transition)) AggregateEventlessStateChange $
          "transition '"
            <> tSource transition
            <> " -- "
            <> tCommand transition
            <> "' emits no event but changes "
            <> changeDescription transition
            <> "; event-sourced state changes require persisted evidence, while a no-op must keep both vertex and registers unchanged"
      | transition <- aggTransitions agg,
        null (tEmits transition),
        tSource transition /= tGoto transition || not (null (tWrites transition))
      ]
    changeDescription transition
      | tSource transition /= tGoto transition && not (null (tWrites transition)) = "the target vertex and registers"
      | tSource transition /= tGoto transition = "the target vertex"
      | otherwise = "registers"

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

-- | A spec surface the grammar accepts but no runtime implements.
--
-- Released languages below 4 keep their acceptance and only warn, so an
-- existing source does not stop checking when it is pinned to an older
-- language. From language 4 — which promised strict spec-surface validation —
-- the same sentence is an error. The message never changes with the severity, so
-- an author reads one explanation before and after the tightening.
-- | A dispatch disposition as the author spelled it.
dispText :: Disp -> Text
dispText DAckOk = "AckOk"
dispText DRetry = "Retry"
dispText (DDeadLetter reason) = "DeadLetter " <> T.pack (show reason)

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
    invalidKeys =
      [ mkErr (locLine (fieldLoc field)) FieldWireKeyInvalid $
          owner <> " field '" <> fieldDslName field <> "' resolves to an empty wire key"
      | field <- fields,
        T.null (fieldWireKey field)
      ]
    duplicateKeys =
      [ Diagnostic
          { line = locLine (fieldLoc field),
            severity = Error,
            code = FieldWireKeyCollision,
            relatedLocations = [(locLine (fieldLoc earlier), "wire key '" <> fieldWireKey field <> "' is first declared here")],
            message = owner <> " fields resolve to duplicate wire key '" <> fieldWireKey field <> "'"
          }
      | (index, field) <- zip [0 :: Int ..] fields,
        earlier : _ <- [[candidate | candidate <- take index fields, fieldWireKey candidate == fieldWireKey field]]
      ]
    reservedCollisions =
      [ mkErr (locLine (fieldLoc field)) FieldWireKeyCollision $
          owner
            <> " field '"
            <> fieldDslName field
            <> "' resolves to wire key '"
            <> key
            <> "', which collides with the "
            <> description
      | Just (key, description) <- [reservedKey],
        field <- fields,
        fieldWireKey field == key
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
