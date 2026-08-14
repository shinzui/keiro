-- | A typed, closed-world declaration of a service's projection fleet.
--
-- A catalog keeps four identities separate:
--
-- * a query model is the typed read contract exposed to callers;
-- * a target is one application-owned PostgreSQL table;
-- * a rebuild group is the set of targets that move through one lifecycle;
-- * a projection is one ordered owner of one or more targets.
--
-- Construct a 'ProjectionCatalog', validate it with
-- 'validateProjectionCatalog', and pass only the resulting
-- 'ValidatedProjectionCatalog' to registration, replay, or operational code.
-- Validation is pure and accumulates deterministic diagnostics. It proves the
-- relationships declared in the supplied catalog; it cannot inspect arbitrary
-- SQL handlers or discover application tables that were not declared.
module Keiro.Projection.Catalog
  ( -- * Validated identities
    ProjectionId,
    TargetId,
    RebuildGroupId,
    SourceId,
    QueryModelId,
    SubscriptionId,
    DedupKeyId,
    ProjectionRevisionId,
    ExternalReadContractId,
    ExternalReadContractVersion (..),
    TargetGenerationId (..),
    TargetSchemaVersion (..),
    ClaimSite,
    CatalogIdentityError (..),
    mkProjectionId,
    mkTargetId,
    mkRebuildGroupId,
    mkSourceId,
    mkQueryModelId,
    mkSubscriptionId,
    mkDedupKeyId,
    mkProjectionRevisionId,
    mkExternalReadContractId,
    mkClaimSite,
    projectionIdText,
    targetIdText,
    rebuildGroupIdText,
    sourceIdText,
    queryModelIdText,
    subscriptionIdText,
    dedupKeyIdText,
    projectionRevisionIdText,
    externalReadContractIdText,
    externalReadContractVersionValue,
    claimSiteText,

    -- * Declarations
    QualifiedTable (..),
    PhysicalTargets,
    PhysicalTargetMapError (..),
    mkPhysicalTargets,
    physicalTargetMap,
    resolvePhysicalTarget,
    PromotionObjectKind (..),
    PromotionObjectName (..),
    TargetSchemaViolation (..),
    TargetSchemaEvidence (..),
    TargetProvisioningContext (..),
    TargetProvisioner (..),
    RevisionLiveDelivery (..),
    RevisionLiveHandler (..),
    RevisionReplayAdapter (..),
    RevisionVerification (..),
    StreamClearCount (..),
    StreamScopedReplay (..),
    ProjectionRevision (..),
    QualifiedFunction (..),
    QualifiedSqlType (..),
    SqlFunctionArgument (..),
    ExternalReadContract (..),
    externalReadFunctionName,
    TargetResetPolicy (..),
    TargetDeclaration (..),
    RebuildVerification (..),
    RebuildGroupDeclaration (..),
    SourceScope (..),
    SourceDeclaration (..),
    SubscriptionDeclaration (..),
    missingCheckpointPolicyText,
    DedupKeyDeclaration (..),
    QueryModelBinding (..),
    SomeQueryModelBinding (..),
    LiveOnlyReason (..),
    ReplayDecodeError (..),
    ReplayDecodeResult (..),
    ReplayAdapter (..),
    replayAdapterFromCodec,
    ProjectionReplayPolicy (..),
    ProjectionHandler (..),
    ProjectionDefinition (..),
    ProjectionSet (..),
    SomeProjectionSet (..),
    ProjectionCatalog (..),
    emptyProjectionCatalog,

    -- * Validation
    Validation (..),
    CatalogDiagnosticCode (..),
    CatalogDiagnostic (..),
    diagnosticCodeText,
    ValidatedProjectionCatalog,
    validateProjectionCatalog,
    useProjectionCatalog,
    useProjectionCatalogM,

    -- * Derived views
    CatalogInventory (..),
    InventorySource (..),
    InventoryTarget (..),
    InventoryGroup (..),
    InventoryProjection (..),
    InventoryQueryModel (..),
    InventoryQueryFreshness (..),
    InventoryQueryCursor (..),
    InventorySubscription (..),
    InventoryDedupKey (..),
    InventoryHandler (..),
    InventoryTargetProvisioner (..),
    InventoryRevisionHandler (..),
    InventoryStreamScopedReplay (..),
    InventoryProjectionRevision (..),
    ExternalReadContractKind (..),
    InventoryExternalReadContract (..),
    ProjectionHandlerCapability (..),
    ResolvedQuerySupply (..),
    CatalogFingerprint,
    catalogFingerprintText,
    GroupSliceFingerprint,
    groupSliceFingerprintText,
    CatalogEvolution (..),
    CatalogRegistration (..),
    AsyncProjectionRegistration (..),
    CatalogAsyncDedupSpec (..),
    ReplayAdapterMetadata (..),
    CatalogReplayAdapter,
    catalogReplayAdapterProjectionId,
    catalogReplayAdapterSourceId,
    catalogReplayAdapterGroupId,
    catalogReplayAdapterOrder,
    runCatalogReplayAdapter,
    typedInlineProjections,
    typedInlineProjectionsForGroup,
    typedProjectionRebuildGroups,
    asyncProjectionRebuildGroup,
    resolvedQuerySupplies,
    catalogInventory,
    catalogFingerprint,
    groupSliceFingerprint,
    catalogRegistrations,
    catalogProjectionRevisions,
    catalogProjectionRevision,
    catalogStreamScopedReplay,
    catalogExternalReadContracts,
    asyncProjectionRegistrations,
    catalogAsyncIdempotencyKeys,
    replayAdapterMetadata,
    catalogReplayAdapters,
    catalogRebuildVerifications,
    renderCatalogInventory,
    compareCatalogBaseline,

    -- * Explicit unmanaged compatibility boundary
    UnmanagedInlineProjections,
    unmanagedInlineProjections,
    getUnmanagedInlineProjections,
    UnmanagedAsyncProjection,
    unmanagedAsyncProjection,
    getUnmanagedAsyncProjection,
    UnmanagedReadModel,
    unmanagedReadModel,
    getUnmanagedReadModel,
  )
where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.UUID (UUID)
import Hasql.Transaction qualified as Tx
import Keiro.Codec (Codec (..), decodeRecorded)
import Keiro.Prelude
import Keiro.Projection.Catalog.Preimage (Preimage (..), hashPreimage)
import Keiro.Projection.Types (AsyncProjection, InlineProjection)
import Keiro.ReadModel
  ( HeadScope (..),
    QueryFreshness (..),
    ReadModel,
    readModelDefaultFreshness,
  )
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (..))
import Kiroku.Store.Types (CategoryName (..), EventId, RecordedEvent, StreamName)

newtype ProjectionId = ProjectionId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype TargetId = TargetId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype RebuildGroupId = RebuildGroupId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype SourceId = SourceId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype QueryModelId = QueryModelId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype SubscriptionId = SubscriptionId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype DedupKeyId = DedupKeyId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype ProjectionRevisionId = ProjectionRevisionId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype ExternalReadContractId = ExternalReadContractId Text
  deriving stock (Eq, Ord, Show, Generic)

newtype ExternalReadContractVersion = ExternalReadContractVersion Int
  deriving stock (Eq, Ord, Show, Generic)

newtype TargetGenerationId = TargetGenerationId UUID
  deriving stock (Eq, Ord, Show, Generic)

newtype TargetSchemaVersion = TargetSchemaVersion Text
  deriving stock (Eq, Ord, Show, Generic)

newtype ClaimSite = ClaimSite Text
  deriving stock (Eq, Ord, Show, Generic)

-- | A stable catalog identity was empty or contained surrounding whitespace.
data CatalogIdentityError
  = EmptyCatalogIdentity
  | CatalogIdentityHasSurroundingWhitespace !Text
  deriving stock (Eq, Ord, Show, Generic)

mkProjectionId :: Text -> Either CatalogIdentityError ProjectionId
mkProjectionId = mkIdentity ProjectionId

mkTargetId :: Text -> Either CatalogIdentityError TargetId
mkTargetId = mkIdentity TargetId

mkRebuildGroupId :: Text -> Either CatalogIdentityError RebuildGroupId
mkRebuildGroupId = mkIdentity RebuildGroupId

mkSourceId :: Text -> Either CatalogIdentityError SourceId
mkSourceId = mkIdentity SourceId

mkQueryModelId :: Text -> Either CatalogIdentityError QueryModelId
mkQueryModelId = mkIdentity QueryModelId

mkSubscriptionId :: Text -> Either CatalogIdentityError SubscriptionId
mkSubscriptionId = mkIdentity SubscriptionId

mkDedupKeyId :: Text -> Either CatalogIdentityError DedupKeyId
mkDedupKeyId = mkIdentity DedupKeyId

mkProjectionRevisionId :: Text -> Either CatalogIdentityError ProjectionRevisionId
mkProjectionRevisionId = mkIdentity ProjectionRevisionId

mkExternalReadContractId :: Text -> Either CatalogIdentityError ExternalReadContractId
mkExternalReadContractId = mkIdentity ExternalReadContractId

mkClaimSite :: Text -> Either CatalogIdentityError ClaimSite
mkClaimSite = mkIdentity ClaimSite

projectionIdText :: ProjectionId -> Text
projectionIdText (ProjectionId value) = value

targetIdText :: TargetId -> Text
targetIdText (TargetId value) = value

rebuildGroupIdText :: RebuildGroupId -> Text
rebuildGroupIdText (RebuildGroupId value) = value

sourceIdText :: SourceId -> Text
sourceIdText (SourceId value) = value

queryModelIdText :: QueryModelId -> Text
queryModelIdText (QueryModelId value) = value

subscriptionIdText :: SubscriptionId -> Text
subscriptionIdText (SubscriptionId value) = value

dedupKeyIdText :: DedupKeyId -> Text
dedupKeyIdText (DedupKeyId value) = value

projectionRevisionIdText :: ProjectionRevisionId -> Text
projectionRevisionIdText (ProjectionRevisionId value) = value

externalReadContractIdText :: ExternalReadContractId -> Text
externalReadContractIdText (ExternalReadContractId value) = value

externalReadContractVersionValue :: ExternalReadContractVersion -> Int
externalReadContractVersionValue (ExternalReadContractVersion value) = value

claimSiteText :: ClaimSite -> Text
claimSiteText (ClaimSite value) = value

mkIdentity :: (Text -> identity) -> Text -> Either CatalogIdentityError identity
mkIdentity constructor value
  | Text.null value = Left EmptyCatalogIdentity
  | Text.strip value /= value = Left (CatalogIdentityHasSurroundingWhitespace value)
  | otherwise = Right (constructor value)

-- | An application-owned PostgreSQL table. Keiro treats both parts as opaque
-- identifiers and quotes them when later plans execute lifecycle SQL.
data QualifiedTable = QualifiedTable
  { schemaName :: !Text,
    tableName :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | A complete logical-target to physical-table binding supplied to every
-- revision handler. Construction is closed-world: missing and unexpected
-- targets are reported together before application SQL can run.
newtype PhysicalTargets = PhysicalTargets (Map TargetId QualifiedTable)
  deriving stock (Eq, Ord, Show, Generic)

data PhysicalTargetMapError
  = MissingPhysicalTarget !TargetId
  | UnexpectedPhysicalTarget !TargetId
  deriving stock (Eq, Ord, Show, Generic)

mkPhysicalTargets :: [TargetId] -> Map TargetId QualifiedTable -> Either (NonEmpty PhysicalTargetMapError) PhysicalTargets
mkPhysicalTargets expected supplied =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right (PhysicalTargets supplied)
    Just failures -> Left failures
  where
    expectedSet = Set.fromList expected
    suppliedSet = Map.keysSet supplied
    errors =
      [ MissingPhysicalTarget targetId
      | targetId <- Set.toAscList (expectedSet `Set.difference` suppliedSet)
      ]
        <> [ UnexpectedPhysicalTarget targetId
           | targetId <- Set.toAscList (suppliedSet `Set.difference` expectedSet)
           ]

physicalTargetMap :: PhysicalTargets -> Map TargetId QualifiedTable
physicalTargetMap (PhysicalTargets targets) = targets

resolvePhysicalTarget :: TargetId -> PhysicalTargets -> Maybe QualifiedTable
resolvePhysicalTarget targetId (PhysicalTargets targets) = Map.lookup targetId targets

data PromotionObjectKind
  = PromotionIndex
  | PromotionConstraint
  | PromotionOwnedSequence
  deriving stock (Eq, Ord, Show, Generic)

-- | One generation-local object name and the canonical serving name it must
-- receive during promotion. Declaration order is durable cutover identity.
data PromotionObjectName = PromotionObjectName
  { objectKind :: !PromotionObjectKind,
    generationName :: !Text,
    canonicalName :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data TargetSchemaViolation = TargetSchemaViolation
  { violationCode :: !Text,
    violationDetail :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | PostgreSQL evidence captured after provisioning and compared again under
-- cutover locks. The catalog snapshot is canonically rendered by the
-- application validator and intentionally remains opaque to Keiro.
data TargetSchemaEvidence = TargetSchemaEvidence
  { relationOid :: !Int64,
    observedShapeFingerprint :: !Text,
    observedPromotionObjects :: ![PromotionObjectName],
    catalogSnapshot :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data TargetProvisioningContext = TargetProvisioningContext
  { targetId :: !TargetId,
    generationId :: !TargetGenerationId,
    servingTable :: !QualifiedTable,
    stagingTable :: !QualifiedTable
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Application-owned schema provisioning and validation for one logical
-- target under one projection revision. A missing validator is representable
-- only so closed-world catalog validation can produce a stable diagnostic.
data TargetProvisioner = TargetProvisioner
  { provisionerId :: !Text,
    provisionerVersion :: !Int,
    schemaVersion :: !TargetSchemaVersion,
    expectedShapeId :: !Text,
    provisionTarget :: !(TargetProvisioningContext -> Tx.Transaction ()),
    validatorId :: !Text,
    validatorVersion :: !Int,
    validateTarget :: !(Maybe (TargetProvisioningContext -> Tx.Transaction (Either [TargetSchemaViolation] TargetSchemaEvidence))),
    promotionObjectNames :: ![PromotionObjectName]
  }
  deriving stock (Generic)

-- | The exact catalog delivery boundary implemented by one revision handler.
-- Revision selection may change physical SQL, but it must not turn an async
-- subscription effect into command-time work (or vice versa).
data RevisionLiveDelivery
  = RevisionInlineDelivery !ProjectionId !Text
  | RevisionSubscriptionDelivery !ProjectionId !SubscriptionId !DedupKeyId
  deriving stock (Eq, Ord, Show, Generic)

data RevisionLiveHandler = RevisionLiveHandler
  { handlerId :: !Text,
    handlerVersion :: !Int,
    delivery :: !RevisionLiveDelivery,
    requiredTargets :: ![TargetId],
    runRevisionLive :: !(PhysicalTargets -> RecordedEvent -> Tx.Transaction ())
  }
  deriving stock (Generic)

data RevisionReplayAdapter = RevisionReplayAdapter
  { adapterId :: !Text,
    adapterVersion :: !Int,
    requiredTargets :: ![TargetId],
    runRevisionReplay :: !(PhysicalTargets -> RecordedEvent -> Tx.Transaction (Either ReplayDecodeError Bool))
  }
  deriving stock (Generic)

data RevisionVerification = RevisionVerification
  { revisionVerificationId :: !Text,
    revisionVerificationVersion :: !Int,
    requiredTargets :: ![TargetId],
    runRevisionVerification :: !(PhysicalTargets -> Tx.Transaction (Either Text ()))
  }
  deriving stock (Generic)

-- | One target row-count observation returned by a stream-scoped clearer.
-- The runner requires exactly the targets declared by the policy so previews
-- and outcomes cannot silently omit a physical target.
data StreamClearCount = StreamClearCount
  { targetId :: !TargetId,
    clearedRows :: !Int64
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Application-owned row-per-stream repair policy for one projection under a
-- projection revision. Keiro owns the transaction, locks, history admission,
-- ordering, and deduplication backfill; the application owns row selection,
-- event decoding/application, and semantic verification.
data StreamScopedReplay = StreamScopedReplay
  { streamProjectionId :: !ProjectionId,
    streamOwnedTargets :: !(NonEmpty TargetId),
    clearerId :: !Text,
    clearerVersion :: !Int,
    clearStreamRows :: !(PhysicalTargets -> StreamName -> Tx.Transaction (Either Text [StreamClearCount])),
    streamReplayId :: !Text,
    streamReplayVersion :: !Int,
    replayStreamEvent :: !(PhysicalTargets -> RecordedEvent -> Tx.Transaction (Either ReplayDecodeError Bool)),
    streamVerificationId :: !Text,
    streamVerificationVersion :: !Int,
    verifyStreamRows :: !(PhysicalTargets -> StreamName -> Tx.Transaction (Either Text ())),
    affectedAsyncDedup :: ![DedupKeyId],
    claimSite :: !ClaimSite
  }
  deriving stock (Generic)

data ProjectionRevision = ProjectionRevision
  { revisionId :: !ProjectionRevisionId,
    rebuildGroup :: !RebuildGroupId,
    targetProvisioners :: !(Map TargetId TargetProvisioner),
    liveHandlers :: ![RevisionLiveHandler],
    replayAdapters :: ![RevisionReplayAdapter],
    revisionVerifications :: ![RevisionVerification],
    streamScopedReplays :: ![StreamScopedReplay],
    claimSite :: !ClaimSite
  }
  deriving stock (Generic)

-- | A fully qualified application-owned PostgreSQL function. Keiro quotes both
-- identifiers when generating a keyed wrapper and never accepts raw SQL here.
data QualifiedFunction = QualifiedFunction
  { functionSchema :: !Text,
    functionName :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | A fully qualified PostgreSQL type used in a public function signature.
-- Keeping schema and type names separate lets the SQL generator quote them
-- independently instead of interpolating an unchecked type expression.
data QualifiedSqlType = QualifiedSqlType
  { typeSchema :: !Text,
    typeName :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data SqlFunctionArgument = SqlFunctionArgument
  { argumentName :: !Text,
    argumentType :: !QualifiedSqlType
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | One versioned, privilege-enforced SQL read surface. The public function
-- name is derived from the contract identity and version so it cannot drift
-- from catalog identity. Keyed implementations remain application-owned;
-- Keiro owns only the guarded outer wrapper.
data ExternalReadContract
  = AllRowsExternalRead
      { readContractId :: !ExternalReadContractId,
        contractVersion :: !ExternalReadContractVersion,
        queryModelId :: !QueryModelId,
        resultContractType :: !QualifiedSqlType,
        resultShapeHash :: !Text,
        compatibleRevisions :: !(NonEmpty ProjectionRevisionId),
        surfaceGeneration :: !Int,
        claimSite :: !ClaimSite
      }
  | KeyedExternalRead
      { readContractId :: !ExternalReadContractId,
        contractVersion :: !ExternalReadContractVersion,
        queryModelId :: !QueryModelId,
        arguments :: ![SqlFunctionArgument],
        resultContractType :: !QualifiedSqlType,
        privateImplementation :: !QualifiedFunction,
        privateImplementationVersion :: !Int,
        resultShapeHash :: !Text,
        compatibleRevisions :: !(NonEmpty ProjectionRevisionId),
        surfaceGeneration :: !Int,
        claimSite :: !ClaimSite
      }
  deriving stock (Eq, Ord, Show, Generic)

-- | Stable public function name in @keiro_read@. Contract identifiers are
-- validated as lower-case SQL identifiers before this value reaches SQL.
externalReadFunctionName :: ExternalReadContract -> Text
externalReadFunctionName contract =
  externalReadContractIdText (contract ^. #readContractId)
    <> "_v"
    <> Text.pack (show (externalReadContractVersionValue (contract ^. #contractVersion)))

-- | How a target is prepared before replay. This is deliberately independent
-- from whether a projection handler is replay-safe.
data TargetResetPolicy
  = ClearBeforeReplay
  | PreserveAndReconcile
  deriving stock (Eq, Ord, Show, Generic)

data TargetDeclaration = TargetDeclaration
  { targetId :: !TargetId,
    qualifiedTable :: !QualifiedTable,
    resetPolicy :: !TargetResetPolicy,
    dependsOn :: ![TargetId],
    claimSite :: !ClaimSite
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | An application-owned, read-only proof run after replay and before
-- promotion. Identity and version are durable parts of the catalog contract;
-- the transaction closure is deliberately excluded from rendered inventory.
data RebuildVerification = RebuildVerification
  { verificationId :: !Text,
    verificationVersion :: !Text,
    verifyRebuild :: !(Tx.Transaction (Either Text ()))
  }
  deriving stock (Generic)

-- | Targets are listed in their declared deterministic preparation order.
-- Validation rejects an empty list, duplicates, unknown targets, and a list
-- inconsistent with target dependencies.
data RebuildGroupDeclaration = RebuildGroupDeclaration
  { rebuildGroupId :: !RebuildGroupId,
    orderedTargets :: ![TargetId],
    verificationHooks :: ![RebuildVerification],
    claimSite :: !ClaimSite
  }
  deriving stock (Generic)

data SourceScope
  = AllStreams
  | CategorySource !CategoryName
  deriving stock (Eq, Ord, Show, Generic)

-- | A source's codec fingerprint is stable application metadata, normally a
-- schema version plus the owning codec/fold identity. Function closures are
-- never included in catalog fingerprints.
data SourceDeclaration = SourceDeclaration
  { sourceId :: !SourceId,
    sourceScope :: !SourceScope,
    codecFingerprint :: !Text,
    claimSite :: !ClaimSite
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Catalog identity and startup lifecycle for one async subscription.
data SubscriptionDeclaration = SubscriptionDeclaration
  { subscriptionId :: !SubscriptionId,
    subscriptionName :: !Text,
    subscriptionSource :: !SourceId,
    -- | Kiroku policy used only when the exact durable member row is absent.
    checkpointOnMissing :: !MissingCheckpointPolicy,
    claimSite :: !ClaimSite
  }
  deriving stock (Eq, Show, Generic)

instance Ord SubscriptionDeclaration where
  compare left right =
    compare
      ( left ^. #subscriptionId,
        left ^. #subscriptionName,
        left ^. #subscriptionSource,
        missingCheckpointPolicyRank (left ^. #checkpointOnMissing),
        left ^. #claimSite
      )
      ( right ^. #subscriptionId,
        right ^. #subscriptionName,
        right ^. #subscriptionSource,
        missingCheckpointPolicyRank (right ^. #checkpointOnMissing),
        right ^. #claimSite
      )

-- | Stable runtime spelling used by fingerprints and operator reports.
missingCheckpointPolicyText :: MissingCheckpointPolicy -> Text
missingCheckpointPolicyText = \case
  FromBeginning -> "FromBeginning"
  FromCurrentHead -> "FromCurrentHead"
  FailIfMissing -> "FailIfMissing"

missingCheckpointPolicyRank :: MissingCheckpointPolicy -> Int
missingCheckpointPolicyRank = \case
  FromBeginning -> 0
  FromCurrentHead -> 1
  FailIfMissing -> 2

data DedupKeyDeclaration = DedupKeyDeclaration
  { dedupKeyId :: !DedupKeyId,
    dedupName :: !Text,
    claimSite :: !ClaimSite
  }
  deriving stock (Eq, Ord, Show, Generic)

data QueryModelBinding q r = QueryModelBinding
  { queryModelId :: !QueryModelId,
    readModel :: !(ReadModel q r),
    rebuildGroup :: !RebuildGroupId,
    observedTargets :: ![TargetId],
    claimSite :: !ClaimSite
  }
  deriving stock (Generic)

data SomeQueryModelBinding
  = forall q r. SomeQueryModelBinding (QueryModelBinding q r)

newtype LiveOnlyReason = LiveOnlyReason Text
  deriving stock (Eq, Ord, Show, Generic)

newtype ReplayDecodeError = ReplayDecodeError Text
  deriving stock (Eq, Ord, Show, Generic)

-- | A replay decoder is total over every event read from its declared source.
data ReplayDecodeResult event
  = ReplayIrrelevant
  | ReplayRelevant !event
  | ReplayDecodeFailure !ReplayDecodeError
  deriving stock (Eq, Show, Generic)

data ReplayAdapter event = ReplayAdapter
  { decodeForReplay :: !(RecordedEvent -> ReplayDecodeResult event),
    applyForReplay :: !(event -> RecordedEvent -> Tx.Transaction ())
  }
  deriving stock (Generic)

-- | Build a total replay adapter from the same authoritative codec used by the
-- event stream. Event types outside the codec are irrelevant; owned event types
-- that fail decoding are structured replay failures.
replayAdapterFromCodec ::
  Codec event ->
  (event -> RecordedEvent -> Tx.Transaction ()) ->
  ReplayAdapter event
replayAdapterFromCodec codec replayApply =
  ReplayAdapter
    { decodeForReplay = \recorded ->
        if recorded ^. #eventType `List.elem` NonEmpty.toList (codec ^. #eventTypes)
          then case decodeRecorded codec recorded of
            Left err -> ReplayDecodeFailure (ReplayDecodeError (Text.pack (show err)))
            Right event -> ReplayRelevant event
          else ReplayIrrelevant,
      applyForReplay = replayApply
    }

data ProjectionReplayPolicy event
  = Replayable !(ReplayAdapter event)
  | LiveOnly !LiveOnlyReason
  deriving stock (Generic)

-- | One projection definition may contain several explicitly ordered handlers.
-- This is composed ownership: the definition is still the single owner of all
-- its targets.
data ProjectionHandler event
  = InlineHandler !(InlineProjection event) !ClaimSite
  | AsyncHandler !AsyncProjection !SubscriptionId !DedupKeyId !ClaimSite
  deriving stock (Generic)

data ProjectionDefinition event = ProjectionDefinition
  { projectionId :: !ProjectionId,
    rebuildGroup :: !RebuildGroupId,
    ownedTargets :: !(NonEmpty TargetId),
    replayPolicy :: !(ProjectionReplayPolicy event),
    handlers :: !(NonEmpty (ProjectionHandler event)),
    claimSite :: !ClaimSite
  }
  deriving stock (Generic)

-- | A typed handle retained by the application. Passing this same value to
-- 'typedInlineProjections' preserves the event type without 'Typeable' casts.
data ProjectionSet event = ProjectionSet
  { projectionSource :: !SourceId,
    projectionDefinitions :: !(NonEmpty (ProjectionDefinition event)),
    claimSite :: !ClaimSite
  }
  deriving stock (Generic)

data SomeProjectionSet
  = forall event. SomeProjectionSet (ProjectionSet event)

data ProjectionCatalog = ProjectionCatalog
  { sources :: ![SourceDeclaration],
    targets :: ![TargetDeclaration],
    rebuildGroups :: ![RebuildGroupDeclaration],
    projectionRevisions :: ![ProjectionRevision],
    externalReadContracts :: ![ExternalReadContract],
    subscriptions :: ![SubscriptionDeclaration],
    dedupKeys :: ![DedupKeyDeclaration],
    queryModels :: ![SomeQueryModelBinding],
    projectionSets :: ![SomeProjectionSet]
  }
  deriving stock (Generic)

emptyProjectionCatalog :: ProjectionCatalog
emptyProjectionCatalog =
  ProjectionCatalog
    { sources = [],
      targets = [],
      rebuildGroups = [],
      projectionRevisions = [],
      externalReadContracts = [],
      subscriptions = [],
      dedupKeys = [],
      queryModels = [],
      projectionSets = []
    }

data Validation err value
  = Failure !err
  | Success !value
  deriving stock (Eq, Show, Generic)

data CatalogDiagnosticCode
  = DuplicateProjectionId
  | DuplicateProjectionRevisionId
  | DuplicateTargetId
  | DuplicateQualifiedTable
  | DuplicateRebuildGroupId
  | DuplicateSourceId
  | DuplicateQueryModelId
  | DuplicateQueryModelRegistryName
  | EmptyQueryObservedTargets
  | QueryModelWithoutSupplier
  | QueryModelWithMultipleSuppliers
  | QueryWaitWithoutCompatibleCursor
  | QueryWaitWithAmbiguousCursor
  | DuplicateSubscriptionId
  | DuplicateSubscriptionName
  | DuplicateDedupKeyId
  | DuplicateDedupName
  | DuplicateGroupTarget
  | UnknownSourceReference
  | UnknownTargetReference
  | UnknownGroupReference
  | UnknownTargetDependency
  | UnknownSubscriptionReference
  | UnknownDedupKeyReference
  | UnknownQueryModelReference
  | UnknownRevisionReference
  | UnknownTargetProvisioner
  | AsyncHandlerSubscriptionMismatch
  | AsyncHandlerDedupMismatch
  | TargetWithoutOwner
  | TargetWithMultipleOwners
  | ProjectionCrossesRebuildGroups
  | TargetDependencyCycle
  | TargetOrderViolatesDependency
  | EmptyRebuildGroup
  | QueryModelOutsideRebuildGroup
  | ClearTargetRequiresReplayableOwner
  | ReplayableClearTargetStartsAtCurrentHead
  | MixedResetGroupRequiresReplayAdapter
  | AmbiguousSourceOrdering
  | DuplicateRebuildVerificationId
  | InvalidRebuildVerificationIdentity
  | ProjectionRevisionWithoutLiveHandler
  | ProjectionRevisionWithoutReplayAdapter
  | ProjectionRevisionTargetSetDrift
  | ProjectionRevisionMissingSchemaValidation
  | ProjectionRevisionPhysicalTargetsNotTotal
  | ProjectionRevisionLiveCapabilityMismatch
  | ProjectionRevisionLiveTargetOwnershipMismatch
  | InvalidProjectionRevisionIdentity
  | DuplicateExternalReadContractVersion
  | DuplicateExternalReadFunctionName
  | UnknownExternalReadQueryModel
  | ExternalReadShapeMismatch
  | ExternalReadRevisionOwnershipMismatch
  | InvalidExternalReadContractIdentity
  | InvalidExternalReadSqlIdentifier
  | InvalidExternalReadSqlType
  | ExternalReadImplementationCollision
  | ExternalReadSurfaceGenerationRegression
  | ExternalReadImmutableSignatureDrift
  | DuplicateStreamScopedReplayProjection
  | UnknownStreamScopedReplayProjection
  | StreamScopedReplayGroupMismatch
  | StreamScopedReplayTargetSetMismatch
  | StreamScopedReplayDedupMismatch
  | InvalidStreamScopedReplayIdentity
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

diagnosticCodeText :: CatalogDiagnosticCode -> Text
diagnosticCodeText = \case
  DuplicateProjectionId -> "catalog.duplicate-projection-id"
  DuplicateProjectionRevisionId -> "catalog.duplicate-projection-revision-id"
  DuplicateTargetId -> "catalog.duplicate-target-id"
  DuplicateQualifiedTable -> "catalog.duplicate-qualified-table"
  DuplicateRebuildGroupId -> "catalog.duplicate-rebuild-group-id"
  DuplicateSourceId -> "catalog.duplicate-source-id"
  DuplicateQueryModelId -> "catalog.duplicate-query-model-id"
  DuplicateQueryModelRegistryName -> "catalog.duplicate-query-model-registry-name"
  EmptyQueryObservedTargets -> "catalog.query-model-empty-observed-targets"
  QueryModelWithoutSupplier -> "catalog.query-model-without-supplier"
  QueryModelWithMultipleSuppliers -> "catalog.query-model-with-multiple-suppliers"
  QueryWaitWithoutCompatibleCursor -> "catalog.query-wait-without-compatible-cursor"
  QueryWaitWithAmbiguousCursor -> "catalog.query-wait-with-ambiguous-cursor"
  DuplicateSubscriptionId -> "catalog.duplicate-subscription-id"
  DuplicateSubscriptionName -> "catalog.duplicate-subscription-name"
  DuplicateDedupKeyId -> "catalog.duplicate-dedup-key-id"
  DuplicateDedupName -> "catalog.duplicate-dedup-name"
  DuplicateGroupTarget -> "catalog.duplicate-group-target"
  UnknownSourceReference -> "catalog.unknown-source-reference"
  UnknownTargetReference -> "catalog.unknown-target-reference"
  UnknownGroupReference -> "catalog.unknown-group-reference"
  UnknownTargetDependency -> "catalog.unknown-target-dependency"
  UnknownSubscriptionReference -> "catalog.unknown-subscription-reference"
  UnknownDedupKeyReference -> "catalog.unknown-dedup-key-reference"
  UnknownQueryModelReference -> "catalog.unknown-query-model-reference"
  UnknownRevisionReference -> "catalog.unknown-revision-reference"
  UnknownTargetProvisioner -> "catalog.unknown-target-provisioner"
  AsyncHandlerSubscriptionMismatch -> "catalog.async-handler-subscription-mismatch"
  AsyncHandlerDedupMismatch -> "catalog.async-handler-dedup-mismatch"
  TargetWithoutOwner -> "catalog.target-without-owner"
  TargetWithMultipleOwners -> "catalog.target-with-multiple-owners"
  ProjectionCrossesRebuildGroups -> "catalog.projection-crosses-rebuild-groups"
  TargetDependencyCycle -> "catalog.target-dependency-cycle"
  TargetOrderViolatesDependency -> "catalog.target-order-violates-dependency"
  EmptyRebuildGroup -> "catalog.empty-rebuild-group"
  QueryModelOutsideRebuildGroup -> "catalog.query-model-outside-rebuild-group"
  ClearTargetRequiresReplayableOwner -> "catalog.clear-target-requires-replayable-owner"
  ReplayableClearTargetStartsAtCurrentHead -> "catalog.replayable-clear-target-starts-at-current-head"
  MixedResetGroupRequiresReplayAdapter -> "catalog.mixed-reset-group-requires-replay-adapter"
  AmbiguousSourceOrdering -> "catalog.ambiguous-source-ordering"
  DuplicateRebuildVerificationId -> "catalog.duplicate-rebuild-verification-id"
  InvalidRebuildVerificationIdentity -> "catalog.invalid-rebuild-verification-identity"
  ProjectionRevisionWithoutLiveHandler -> "catalog.projection-revision-without-live-handler"
  ProjectionRevisionWithoutReplayAdapter -> "catalog.projection-revision-without-replay-adapter"
  ProjectionRevisionTargetSetDrift -> "catalog.projection-revision-target-set-drift"
  ProjectionRevisionMissingSchemaValidation -> "catalog.projection-revision-missing-schema-validation"
  ProjectionRevisionPhysicalTargetsNotTotal -> "catalog.projection-revision-physical-targets-not-total"
  ProjectionRevisionLiveCapabilityMismatch -> "catalog.projection-revision-live-capability-mismatch"
  ProjectionRevisionLiveTargetOwnershipMismatch -> "catalog.projection-revision-live-target-ownership-mismatch"
  InvalidProjectionRevisionIdentity -> "catalog.invalid-projection-revision-identity"
  DuplicateExternalReadContractVersion -> "catalog.external-read-duplicate-contract-version"
  DuplicateExternalReadFunctionName -> "catalog.external-read-duplicate-function-name"
  UnknownExternalReadQueryModel -> "catalog.external-read-unknown-query-model"
  ExternalReadShapeMismatch -> "catalog.external-read-shape-mismatch"
  ExternalReadRevisionOwnershipMismatch -> "catalog.external-read-revision-ownership-mismatch"
  InvalidExternalReadContractIdentity -> "catalog.external-read-invalid-contract-identity"
  InvalidExternalReadSqlIdentifier -> "catalog.external-read-invalid-sql-identifier"
  InvalidExternalReadSqlType -> "catalog.external-read-invalid-sql-type"
  ExternalReadImplementationCollision -> "catalog.external-read-implementation-collision"
  ExternalReadSurfaceGenerationRegression -> "catalog.external-read-surface-generation-regression"
  ExternalReadImmutableSignatureDrift -> "catalog.external-read-immutable-signature-drift"
  DuplicateStreamScopedReplayProjection -> "catalog.stream-replay-duplicate-projection"
  UnknownStreamScopedReplayProjection -> "catalog.stream-replay-unknown-projection"
  StreamScopedReplayGroupMismatch -> "catalog.stream-replay-group-mismatch"
  StreamScopedReplayTargetSetMismatch -> "catalog.stream-replay-target-set-mismatch"
  StreamScopedReplayDedupMismatch -> "catalog.stream-replay-dedup-mismatch"
  InvalidStreamScopedReplayIdentity -> "catalog.stream-replay-invalid-identity"

data CatalogDiagnostic = CatalogDiagnostic
  { diagnosticCode :: !CatalogDiagnosticCode,
    diagnosticIdentity :: !Text,
    diagnosticSites :: ![ClaimSite],
    diagnosticMessage :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventorySource = InventorySource
  { sourceId :: !SourceId,
    sourceScope :: !SourceScope,
    codecFingerprint :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventoryTarget = InventoryTarget
  { targetId :: !TargetId,
    qualifiedTable :: !QualifiedTable,
    resetPolicy :: !TargetResetPolicy,
    dependsOn :: ![TargetId],
    owner :: !ProjectionId
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventoryGroup = InventoryGroup
  { rebuildGroupId :: !RebuildGroupId,
    orderedTargets :: ![TargetId],
    verifications :: ![(Text, Text)]
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventoryHandler
  = InventoryInlineHandler !Text
  | InventoryAsyncHandler !Text !SubscriptionId !DedupKeyId
  deriving stock (Eq, Ord, Show, Generic)

data InventoryProjection = InventoryProjection
  { projectionId :: !ProjectionId,
    sourceId :: !SourceId,
    rebuildGroupId :: !RebuildGroupId,
    ownedTargets :: ![TargetId],
    replayDisposition :: !Text,
    handlers :: ![InventoryHandler]
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventoryTargetProvisioner = InventoryTargetProvisioner
  { targetId :: !TargetId,
    provisionerId :: !Text,
    provisionerVersion :: !Int,
    schemaVersion :: !TargetSchemaVersion,
    expectedShapeId :: !Text,
    validatorId :: !Text,
    validatorVersion :: !Int,
    promotionObjectNames :: ![PromotionObjectName]
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventoryRevisionHandler = InventoryRevisionHandler
  { handlerId :: !Text,
    handlerVersion :: !Int,
    delivery :: !(Maybe RevisionLiveDelivery),
    requiredTargets :: ![TargetId]
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventoryStreamScopedReplay = InventoryStreamScopedReplay
  { projectionId :: !ProjectionId,
    ownedTargets :: ![TargetId],
    clearerId :: !Text,
    clearerVersion :: !Int,
    replayId :: !Text,
    replayVersion :: !Int,
    verificationId :: !Text,
    verificationVersion :: !Int,
    affectedAsyncDedup :: ![DedupKeyId]
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventoryProjectionRevision = InventoryProjectionRevision
  { revisionId :: !ProjectionRevisionId,
    rebuildGroupId :: !RebuildGroupId,
    targetProvisioners :: ![InventoryTargetProvisioner],
    liveHandlers :: ![InventoryRevisionHandler],
    replayAdapters :: ![InventoryRevisionHandler],
    verifications :: ![InventoryRevisionHandler],
    streamScopedReplays :: ![InventoryStreamScopedReplay]
  }
  deriving stock (Eq, Ord, Show, Generic)

data ExternalReadContractKind
  = InventoryAllRowsExternalRead
  | InventoryKeyedExternalRead
  deriving stock (Eq, Ord, Show, Generic)

data InventoryExternalReadContract = InventoryExternalReadContract
  { readContractId :: !ExternalReadContractId,
    contractVersion :: !ExternalReadContractVersion,
    queryModelId :: !QueryModelId,
    rebuildGroupId :: !RebuildGroupId,
    functionName :: !Text,
    contractKind :: !ExternalReadContractKind,
    arguments :: ![SqlFunctionArgument],
    resultContractType :: !QualifiedSqlType,
    privateImplementation :: !(Maybe QualifiedFunction),
    privateImplementationVersion :: !(Maybe Int),
    resultShapeHash :: !Text,
    compatibleRevisions :: !(NonEmpty ProjectionRevisionId),
    surfaceGeneration :: !Int
  }
  deriving stock (Eq, Ord, Show, Generic)

data InventoryQueryModel = InventoryQueryModel
  { queryModelId :: !QueryModelId,
    registryName :: !Text,
    version :: !Int,
    shapeHash :: !Text,
    rebuildGroupId :: !RebuildGroupId,
    observedTargets :: ![TargetId],
    freshness :: !InventoryQueryFreshness,
    cursor :: !(Maybe InventoryQueryCursor)
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Canonical query freshness. Position targets and polling durations are
-- per-call execution data, so the catalog records only the position-wait kind.
data InventoryQueryFreshness
  = InventoryImmediate
  | InventoryWaitForHead !HeadScope
  | InventoryWaitForPosition
  deriving stock (Eq, Ord, Show, Generic)

-- | The one durable cursor derived from the supplying projection, when that
-- projection exposes exactly one compatible subscription authority.
data InventoryQueryCursor = InventoryQueryCursor
  { subscriptionId :: !SubscriptionId,
    subscriptionName :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Operator-visible subscription identity, source, and absent-row policy.
data InventorySubscription = InventorySubscription
  { subscriptionId :: !SubscriptionId,
    subscriptionName :: !Text,
    sourceId :: !SourceId,
    checkpointOnMissing :: !MissingCheckpointPolicy
  }
  deriving stock (Eq, Show, Generic)

instance Ord InventorySubscription where
  compare left right =
    compare
      ( left ^. #subscriptionId,
        left ^. #subscriptionName,
        left ^. #sourceId,
        missingCheckpointPolicyRank (left ^. #checkpointOnMissing)
      )
      ( right ^. #subscriptionId,
        right ^. #subscriptionName,
        right ^. #sourceId,
        missingCheckpointPolicyRank (right ^. #checkpointOnMissing)
      )

data InventoryDedupKey = InventoryDedupKey
  { dedupKeyId :: !DedupKeyId,
    dedupName :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data CatalogInventory = CatalogInventory
  { inventorySources :: ![InventorySource],
    inventoryTargets :: ![InventoryTarget],
    inventoryGroups :: ![InventoryGroup],
    inventoryProjections :: ![InventoryProjection],
    inventoryProjectionRevisions :: ![InventoryProjectionRevision],
    inventoryExternalReadContracts :: ![InventoryExternalReadContract],
    inventoryQueryModels :: ![InventoryQueryModel],
    inventorySubscriptions :: ![InventorySubscription],
    inventoryDedupKeys :: ![InventoryDedupKey]
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | One live-handler capability retained by the supplying projection. This
-- normalized view contains identities and policies only; executable closures
-- stay in the original typed catalog.
data ProjectionHandlerCapability
  = InlineCapability
      { capabilityHandlerName :: !Text
      }
  | SubscriptionCapability
      { capabilityHandlerName :: !Text,
        capabilitySubscriptionId :: !SubscriptionId,
        capabilitySubscriptionName :: !Text,
        capabilitySourceId :: !SourceId,
        capabilityCheckpointOnMissing :: !MissingCheckpointPolicy,
        capabilityDedupKeyId :: !DedupKeyId,
        capabilityDedupName :: !Text
      }
  deriving stock (Eq, Show, Generic)

-- | The single catalog projection that supplies a typed query model. Target
-- ownership is authoritative: all observed targets must resolve to this owner
-- in the same rebuild group before validation succeeds.
data ResolvedQuerySupply = ResolvedQuerySupply
  { resolvedQueryModelId :: !QueryModelId,
    resolvedProjectionId :: !ProjectionId,
    resolvedRebuildGroupId :: !RebuildGroupId,
    resolvedObservedTargets :: !(NonEmpty TargetId),
    resolvedSourceId :: !SourceId,
    resolvedHandlerCapabilities :: !(NonEmpty ProjectionHandlerCapability),
    resolvedQueryFreshness :: !InventoryQueryFreshness,
    resolvedQueryCursor :: !(Maybe InventoryQueryCursor)
  }
  deriving stock (Eq, Show, Generic)

newtype CatalogFingerprint = CatalogFingerprint Text
  deriving stock (Eq, Ord, Show, Generic)

catalogFingerprintText :: CatalogFingerprint -> Text
catalogFingerprintText (CatalogFingerprint value) = value

-- | Identity of the catalog facts owned by one rebuild group.
newtype GroupSliceFingerprint = GroupSliceFingerprint Text
  deriving stock (Eq, Ord, Show, Generic)

groupSliceFingerprintText :: GroupSliceFingerprint -> Text
groupSliceFingerprintText (GroupSliceFingerprint value) = value

data ValidatedProjectionCatalog = ValidatedProjectionCatalog
  { originalCatalog :: !ProjectionCatalog,
    validatedInventory :: !CatalogInventory,
    validatedFingerprint :: !CatalogFingerprint,
    projectionFacts :: ![ProjectionFacts],
    validatedQuerySupplies :: ![ResolvedQuerySupply]
  }
  deriving stock (Generic)

data CatalogEvolution
  = SourceRemoved !SourceId
  | TargetRemoved !TargetId
  | RebuildGroupRemoved !RebuildGroupId
  | ProjectionRemoved !ProjectionId
  | ProjectionRevisionRemoved !ProjectionRevisionId
  | ExternalReadContractRemoved !ExternalReadContractId !ExternalReadContractVersion
  | QueryModelRemoved !QueryModelId
  | SubscriptionRemoved !SubscriptionId
  | DedupKeyRemoved !DedupKeyId
  | TargetOwnerChanged !TargetId !ProjectionId !ProjectionId
  | TargetGroupChanged !TargetId !RebuildGroupId !RebuildGroupId
  deriving stock (Eq, Ord, Show, Generic)

data CatalogRegistration = CatalogRegistration
  { queryModelId :: !QueryModelId,
    registryName :: !Text,
    version :: !Int,
    shapeHash :: !Text,
    rebuildGroupId :: !RebuildGroupId
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Runtime async registration projected from a validated catalog.
data AsyncProjectionRegistration = AsyncProjectionRegistration
  { projectionId :: !ProjectionId,
    projectionName :: !Text,
    subscriptionId :: !SubscriptionId,
    subscriptionName :: !Text,
    checkpointOnMissing :: !MissingCheckpointPolicy,
    dedupKeyId :: !DedupKeyId,
    dedupName :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance Ord AsyncProjectionRegistration where
  compare left right =
    compare
      ( left ^. #projectionId,
        left ^. #projectionName,
        left ^. #subscriptionId,
        left ^. #subscriptionName,
        missingCheckpointPolicyRank (left ^. #checkpointOnMissing),
        left ^. #dedupKeyId,
        left ^. #dedupName
      )
      ( right ^. #projectionId,
        right ^. #projectionName,
        right ^. #subscriptionId,
        right ^. #subscriptionName,
        missingCheckpointPolicyRank (right ^. #checkpointOnMissing),
        right ^. #dedupKeyId,
        right ^. #dedupName
      )

-- | One replayable async handler's redelivery identity. Promotion uses this
-- to re-seed dedup rows and advance the declared checkpoint for one rebuild
-- group. Membership matches rebuild preparation: every replayable definition
-- in the group, independent of target reset policy. Plan 256 consumes this
-- same view for versioned cutover.
data CatalogAsyncDedupSpec = CatalogAsyncDedupSpec
  { specDedupKeyId :: !DedupKeyId,
    specSubscriptionName :: !Text,
    specDedupName :: !Text,
    specSourceId :: !SourceId,
    specSourceScope :: !SourceScope,
    specIdempotencyKey :: !(RecordedEvent -> EventId)
  }
  deriving stock (Generic)

data ReplayAdapterMetadata = ReplayAdapterMetadata
  { projectionId :: !ProjectionId,
    sourceId :: !SourceId,
    rebuildGroupId :: !RebuildGroupId,
    replayable :: !Bool
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | One existential replay closure in deterministic catalog order. The event
-- type stays sealed inside this value, so the runner can route raw history
-- without weakening the typed live projection API.
data CatalogReplayAdapter
  = forall event.
    CatalogReplayAdapter
      !ProjectionId
      !SourceId
      !RebuildGroupId
      !Int
      !(ReplayAdapter event)

catalogReplayAdapterProjectionId :: CatalogReplayAdapter -> ProjectionId
catalogReplayAdapterProjectionId (CatalogReplayAdapter projectionId _ _ _ _) = projectionId

catalogReplayAdapterSourceId :: CatalogReplayAdapter -> SourceId
catalogReplayAdapterSourceId (CatalogReplayAdapter _ sourceId _ _ _) = sourceId

catalogReplayAdapterGroupId :: CatalogReplayAdapter -> RebuildGroupId
catalogReplayAdapterGroupId (CatalogReplayAdapter _ _ groupId _ _) = groupId

catalogReplayAdapterOrder :: CatalogReplayAdapter -> Int
catalogReplayAdapterOrder (CatalogReplayAdapter _ _ _ adapterOrder _) = adapterOrder

-- | Evaluate a raw event through one total adapter. @Right False@ is an
-- irrelevant event; @Right True@ means the replay transaction applied it.
runCatalogReplayAdapter ::
  CatalogReplayAdapter ->
  RecordedEvent ->
  Tx.Transaction (Either ReplayDecodeError Bool)
runCatalogReplayAdapter (CatalogReplayAdapter _ _ _ _ adapter) recorded =
  case (adapter ^. #decodeForReplay) recorded of
    ReplayIrrelevant -> pure (Right False)
    ReplayRelevant event -> do
      (adapter ^. #applyForReplay) event recorded
      pure (Right True)
    ReplayDecodeFailure decodeError -> pure (Left decodeError)

data ProjectionFacts = ProjectionFacts
  { factProjectionId :: !ProjectionId,
    factSourceId :: !SourceId,
    factGroupId :: !RebuildGroupId,
    factTargets :: ![TargetId],
    factReplayable :: !Bool,
    factHandlers :: ![HandlerFacts],
    factSite :: !ClaimSite
  }

data HandlerFacts
  = InlineFacts !Text !ClaimSite
  | AsyncFacts !Text !Text !Text !SubscriptionId !DedupKeyId !ClaimSite

data QueryFacts = QueryFacts
  { factQueryModelId :: !QueryModelId,
    factRegistryName :: !Text,
    factVersion :: !Int,
    factShapeHash :: !Text,
    factQueryGroup :: !RebuildGroupId,
    factObservedTargets :: ![TargetId],
    factQueryFreshness :: !QueryFreshness,
    factQuerySite :: !ClaimSite
  }

validateProjectionCatalog ::
  ProjectionCatalog ->
  Validation (NonEmpty CatalogDiagnostic) ValidatedProjectionCatalog
validateProjectionCatalog catalog =
  case NonEmpty.nonEmpty diagnostics of
    Just errors -> Failure errors
    Nothing ->
      let inventory = buildInventory catalog facts queryFacts
          querySupplies = buildResolvedQuerySupplies inventory
       in Success
            ValidatedProjectionCatalog
              { originalCatalog = catalog,
                validatedInventory = inventory,
                validatedFingerprint = fingerprintInventory inventory,
                projectionFacts = facts,
                validatedQuerySupplies = querySupplies
              }
  where
    facts = collectProjectionFacts (catalog ^. #projectionSets)
    queryFacts = collectQueryFacts (catalog ^. #queryModels)
    diagnostics =
      List.sort
        ( duplicateDiagnostics catalog facts queryFacts
            <> referenceDiagnostics catalog facts queryFacts
            <> ownershipDiagnostics catalog facts
            <> groupDiagnostics catalog facts queryFacts
            <> querySupplyDiagnostics catalog facts queryFacts
            <> queryFreshnessDiagnostics catalog facts queryFacts
            <> replayDiagnostics catalog facts
            <> sourceOrderingDiagnostics catalog facts
            <> verificationDiagnostics catalog
            <> projectionRevisionDiagnostics catalog facts
            <> streamScopedReplayDiagnostics catalog facts
            <> externalReadContractDiagnostics catalog queryFacts
        )

-- | Validate and invoke a consumer only on success. This is the pure boundary
-- used by startup code to ensure invalid catalogs trigger no registration or
-- rebuild callback.
useProjectionCatalog ::
  ProjectionCatalog ->
  (ValidatedProjectionCatalog -> result) ->
  Validation (NonEmpty CatalogDiagnostic) result
useProjectionCatalog catalog consume =
  case validateProjectionCatalog catalog of
    Failure errors -> Failure errors
    Success validated -> Success (consume validated)

-- | Monadic form of 'useProjectionCatalog'. The callback is not evaluated when
-- validation fails, so startup registration and rebuild effects stay behind the
-- validated boundary.
useProjectionCatalogM ::
  (Monad effect) =>
  ProjectionCatalog ->
  (ValidatedProjectionCatalog -> effect result) ->
  effect (Validation (NonEmpty CatalogDiagnostic) result)
useProjectionCatalogM catalog consume =
  case validateProjectionCatalog catalog of
    Failure errors -> pure (Failure errors)
    Success validated -> Success <$> consume validated

typedInlineProjections ::
  ValidatedProjectionCatalog ->
  ProjectionSet event ->
  [InlineProjection event]
typedInlineProjections validated projectionSet
  | projectionSetBelongs validated projectionSet =
      [ projection
      | definition <- NonEmpty.toList (projectionSet ^. #projectionDefinitions),
        handler <- NonEmpty.toList (definition ^. #handlers),
        InlineHandler projection _ <- [handler]
      ]
  | otherwise = []

-- | Typed compatibility handlers owned by one rebuild group. Revision-aware
-- writers use this only for a legacy group; version-managed groups dispatch
-- through the selected 'RevisionLiveHandler' instead.
typedInlineProjectionsForGroup ::
  ValidatedProjectionCatalog ->
  ProjectionSet event ->
  RebuildGroupId ->
  [InlineProjection event]
typedInlineProjectionsForGroup validated projectionSet wantedGroup
  | projectionSetBelongs validated projectionSet =
      [ projection
      | definition <- NonEmpty.toList (projectionSet ^. #projectionDefinitions),
        definition ^. #rebuildGroup == wantedGroup,
        handler <- NonEmpty.toList (definition ^. #handlers),
        InlineHandler projection _ <- [handler]
      ]
  | otherwise = []

-- | Distinct rebuild groups touched by the same validated typed source handle,
-- in stable lock order. A handle that does not belong to this catalog yields no
-- groups, matching 'typedInlineProjections'.
typedProjectionRebuildGroups ::
  ValidatedProjectionCatalog ->
  ProjectionSet event ->
  [RebuildGroupId]
typedProjectionRebuildGroups validated projectionSet
  | projectionSetBelongs validated projectionSet =
      List.sort
        . Set.toList
        . Set.fromList
        $ [ definition ^. #rebuildGroup
          | definition <- NonEmpty.toList (projectionSet ^. #projectionDefinitions)
          ]
  | otherwise = []

-- | Resolve one validated async handler to the group whose fence it must lock.
-- Both the stable projection ID and the existing physical projection name must
-- match, preventing a caller from pairing catalog metadata with another
-- handler closure.
asyncProjectionRebuildGroup ::
  ValidatedProjectionCatalog ->
  ProjectionId ->
  Text ->
  Maybe RebuildGroupId
asyncProjectionRebuildGroup validated wantedProjectionId wantedProjectionName = do
  registration <-
    List.find
      ( \entry ->
          entry ^. #projectionId == wantedProjectionId
            && entry ^. #projectionName == wantedProjectionName
      )
      (asyncProjectionRegistrations validated)
  projection <-
    List.find
      ((== registration ^. #projectionId) . (^. #projectionId))
      (validated ^. #validatedInventory . #inventoryProjections)
  pure (projection ^. #rebuildGroupId)

-- | Resolve every query model to its sole projection owner. Results are sorted
-- by query-model identity and are available only after whole-catalog
-- validation has established the ownership and rebuild-group invariants.
resolvedQuerySupplies :: ValidatedProjectionCatalog -> [ResolvedQuerySupply]
resolvedQuerySupplies = validatedQuerySupplies

projectionSetBelongs ::
  ValidatedProjectionCatalog ->
  ProjectionSet event ->
  Bool
projectionSetBelongs validated projectionSet =
  expectedIds `Set.isSubsetOf` validatedIds
  where
    expectedIds =
      Set.fromList
        [ definition ^. #projectionId
        | definition <- NonEmpty.toList (projectionSet ^. #projectionDefinitions)
        ]
    validatedIds =
      Set.fromList
        [ factProjectionId fact
        | fact <- validated ^. #projectionFacts,
          factSourceId fact == projectionSet ^. #projectionSource
        ]

catalogInventory :: ValidatedProjectionCatalog -> CatalogInventory
catalogInventory = validatedInventory

catalogFingerprint :: ValidatedProjectionCatalog -> CatalogFingerprint
catalogFingerprint = validatedFingerprint

-- | Fingerprint the catalog facts that preparation, replay, promotion, and
-- query transitions for one rebuild group depend on. Unrelated catalog slices
-- do not affect this identity.
groupSliceFingerprint ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  Maybe GroupSliceFingerprint
groupSliceFingerprint validated wantedGroup = do
  group <- List.find ((== wantedGroup) . (^. #rebuildGroupId)) (inventory ^. #inventoryGroups)
  pure
    . GroupSliceFingerprint
    . hashPreimage "slice-v6"
    $ PRecord
      "keiro/catalog-group-slice/v6"
      [ PText (rebuildGroupIdText wantedGroup),
        groupPreimage group,
        PList (targetPreimage <$> targets),
        PList (projectionPreimage <$> projections),
        PList (projectionRevisionPreimage <$> revisions),
        PList (externalReadContractPreimage <$> externalReadContracts),
        PList (sourcePreimage <$> sources),
        PList (queryPreimage <$> queries),
        PList (subscriptionPreimage <$> subscriptions),
        PList (dedupPreimage <$> dedupKeys)
      ]
  where
    inventory = catalogInventory validated
    groupTargets = maybe [] (^. #orderedTargets) $ List.find ((== wantedGroup) . (^. #rebuildGroupId)) (inventory ^. #inventoryGroups)
    targets =
      mapMaybe
        (\wanted -> List.find ((== wanted) . (^. #targetId)) (inventory ^. #inventoryTargets))
        groupTargets
    projections =
      filter
        ((== wantedGroup) . (^. #rebuildGroupId))
        (inventory ^. #inventoryProjections)
    revisions =
      filter
        ((== wantedGroup) . (^. #rebuildGroupId))
        (inventory ^. #inventoryProjectionRevisions)
    externalReadContracts =
      filter
        ((== wantedGroup) . (^. #rebuildGroupId))
        (inventory ^. #inventoryExternalReadContracts)
    sourceIds = Set.fromList (map (^. #sourceId) projections)
    sources = filter ((`Set.member` sourceIds) . (^. #sourceId)) (inventory ^. #inventorySources)
    queries =
      filter
        ((== wantedGroup) . (^. #rebuildGroupId))
        (inventory ^. #inventoryQueryModels)
    asyncHandlers =
      [ (subscriptionId, dedupId)
      | projection <- projections,
        InventoryAsyncHandler _ subscriptionId dedupId <- projection ^. #handlers
      ]
    subscriptionIds = Set.fromList (map fst asyncHandlers)
    dedupIds = Set.fromList (map snd asyncHandlers)
    subscriptions =
      filter
        ((`Set.member` subscriptionIds) . (^. #subscriptionId))
        (inventory ^. #inventorySubscriptions)
    dedupKeys =
      filter
        ((`Set.member` dedupIds) . (^. #dedupKeyId))
        (inventory ^. #inventoryDedupKeys)

catalogRegistrations :: ValidatedProjectionCatalog -> [CatalogRegistration]
catalogRegistrations validated =
  [ CatalogRegistration
      { queryModelId = binding ^. #queryModelId,
        registryName = binding ^. #registryName,
        version = binding ^. #version,
        shapeHash = binding ^. #shapeHash,
        rebuildGroupId = binding ^. #rebuildGroupId
      }
  | binding <- validated ^. #validatedInventory . #inventoryQueryModels
  ]

-- | Executable revision contracts from the validated catalog. Declaration
-- order is preserved; callers that need one identity should use
-- 'catalogProjectionRevision'.
catalogProjectionRevisions :: ValidatedProjectionCatalog -> [ProjectionRevision]
catalogProjectionRevisions validated =
  validated ^. #originalCatalog . #projectionRevisions

catalogProjectionRevision ::
  ValidatedProjectionCatalog ->
  ProjectionRevisionId ->
  Maybe ProjectionRevision
catalogProjectionRevision validated wanted =
  List.find ((== wanted) . (^. #revisionId)) (catalogProjectionRevisions validated)

-- | Resolve one validated stream-scoped policy from the exact projection
-- revision that currently serves a group.
catalogStreamScopedReplay ::
  ValidatedProjectionCatalog ->
  ProjectionRevisionId ->
  ProjectionId ->
  Maybe StreamScopedReplay
catalogStreamScopedReplay validated revisionId wantedProjection = do
  revision <- catalogProjectionRevision validated revisionId
  List.find
    ((== wantedProjection) . (^. #streamProjectionId))
    (revision ^. #streamScopedReplays)

-- | Runtime declarations retained behind the validated boundary. Results are
-- sorted so registration is independent of source declaration order.
catalogExternalReadContracts :: ValidatedProjectionCatalog -> [ExternalReadContract]
catalogExternalReadContracts validated =
  List.sort (validated ^. #originalCatalog . #externalReadContracts)

asyncProjectionRegistrations ::
  ValidatedProjectionCatalog ->
  [AsyncProjectionRegistration]
asyncProjectionRegistrations validated =
  List.sort
    [ AsyncProjectionRegistration
        { projectionId = factProjectionId projection,
          projectionName = projectionName,
          subscriptionId = subscriptionId,
          subscriptionName = subscription ^. #subscriptionName,
          checkpointOnMissing = subscription ^. #checkpointOnMissing,
          dedupKeyId = dedupKeyId,
          dedupName = dedupNameFor dedupKeyId
        }
    | projection <- validated ^. #projectionFacts,
      AsyncFacts projectionName _ _ subscriptionId dedupKeyId _ <- factHandlers projection,
      Just subscription <- [subscriptionFor subscriptionId]
    ]
  where
    inventory = validated ^. #validatedInventory
    subscriptionFor ref =
      List.find ((== ref) . (^. #subscriptionId)) (inventory ^. #inventorySubscriptions)
    dedupNameFor ref =
      fromMaybe
        ""
        ( List.lookup
            ref
            [ (entry ^. #dedupKeyId, entry ^. #dedupName)
            | entry <- inventory ^. #inventoryDedupKeys
            ]
        )

-- | Redelivery identities for replayable async definitions in one group,
-- preserving projection-set, definition, and handler declaration order.
catalogAsyncIdempotencyKeys ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  [CatalogAsyncDedupSpec]
catalogAsyncIdempotencyKeys validated wantedGroup =
  concatMap specsForSet (validated ^. #originalCatalog . #projectionSets)
  where
    inventory = validated ^. #validatedInventory

    specsForSet (SomeProjectionSet projectionSet) =
      [ CatalogAsyncDedupSpec
          { specDedupKeyId = dedupKeyId,
            specSubscriptionName = subscriptionNameFor subscriptionId,
            specDedupName = dedupNameFor dedupKeyId,
            specSourceId = sourceId,
            specSourceScope = sourceScopeFor sourceId,
            specIdempotencyKey = projection ^. #idempotencyKey
          }
      | definition <- NonEmpty.toList (projectionSet ^. #projectionDefinitions),
        definition ^. #rebuildGroup == wantedGroup,
        Replayable {} <- [definition ^. #replayPolicy],
        AsyncHandler projection subscriptionId dedupKeyId _ <-
          NonEmpty.toList (definition ^. #handlers)
      ]
      where
        sourceId = projectionSet ^. #projectionSource

    subscriptionNameFor ref =
      fromMaybe
        (error "catalogAsyncIdempotencyKeys: validated subscription missing from inventory")
        ( (^. #subscriptionName)
            <$> List.find
              ((== ref) . (^. #subscriptionId))
              (inventory ^. #inventorySubscriptions)
        )

    dedupNameFor ref =
      fromMaybe
        (error "catalogAsyncIdempotencyKeys: validated dedup key missing from inventory")
        ( (^. #dedupName)
            <$> List.find
              ((== ref) . (^. #dedupKeyId))
              (inventory ^. #inventoryDedupKeys)
        )

    sourceScopeFor ref =
      fromMaybe
        (error "catalogAsyncIdempotencyKeys: validated source missing from inventory")
        ( (^. #sourceScope)
            <$> List.find
              ((== ref) . (^. #sourceId))
              (inventory ^. #inventorySources)
        )

replayAdapterMetadata :: ValidatedProjectionCatalog -> [ReplayAdapterMetadata]
replayAdapterMetadata validated =
  List.sort
    [ ReplayAdapterMetadata
        { projectionId = factProjectionId fact,
          sourceId = factSourceId fact,
          rebuildGroupId = factGroupId fact,
          replayable = factReplayable fact
        }
    | fact <- validated ^. #projectionFacts
    ]

-- | Replayable definitions for one group, preserving projection-set and
-- definition declaration order. Live-only definitions are intentionally
-- absent from the replay fleet.
catalogReplayAdapters ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  [CatalogReplayAdapter]
catalogReplayAdapters validated wantedGroup =
  List.zipWith assignOrder [0 ..] unordered
  where
    unordered =
      concatMap adaptersForSet (validated ^. #originalCatalog . #projectionSets)

    adaptersForSet (SomeProjectionSet projectionSet) =
      [ CatalogReplayAdapter
          (definition ^. #projectionId)
          (projectionSet ^. #projectionSource)
          (definition ^. #rebuildGroup)
          0
          adapter
      | definition <- NonEmpty.toList (projectionSet ^. #projectionDefinitions),
        definition ^. #rebuildGroup == wantedGroup,
        Replayable adapter <- [definition ^. #replayPolicy]
      ]

    assignOrder adapterOrder (CatalogReplayAdapter projectionId sourceId groupId _ adapter) =
      CatalogReplayAdapter projectionId sourceId groupId adapterOrder adapter

catalogRebuildVerifications ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  [RebuildVerification]
catalogRebuildVerifications validated wantedGroup =
  concat
    [ group ^. #verificationHooks
    | group <- validated ^. #originalCatalog . #rebuildGroups,
      group ^. #rebuildGroupId == wantedGroup
    ]

renderCatalogInventory :: ValidatedProjectionCatalog -> Text
renderCatalogInventory = renderInventory . catalogInventory

compareCatalogBaseline :: CatalogInventory -> CatalogInventory -> [CatalogEvolution]
compareCatalogBaseline previous current =
  List.sort
    ( removedEntries SourceRemoved (^. #sourceId) (previous ^. #inventorySources) (current ^. #inventorySources)
        <> removedEntries TargetRemoved (^. #targetId) (previous ^. #inventoryTargets) (current ^. #inventoryTargets)
        <> removedEntries RebuildGroupRemoved (^. #rebuildGroupId) (previous ^. #inventoryGroups) (current ^. #inventoryGroups)
        <> removedEntries ProjectionRemoved (^. #projectionId) (previous ^. #inventoryProjections) (current ^. #inventoryProjections)
        <> removedEntries ProjectionRevisionRemoved (^. #revisionId) (previous ^. #inventoryProjectionRevisions) (current ^. #inventoryProjectionRevisions)
        <> removedEntries
          (uncurry ExternalReadContractRemoved)
          (\entry -> (entry ^. #readContractId, entry ^. #contractVersion))
          (previous ^. #inventoryExternalReadContracts)
          (current ^. #inventoryExternalReadContracts)
        <> removedEntries QueryModelRemoved (^. #queryModelId) (previous ^. #inventoryQueryModels) (current ^. #inventoryQueryModels)
        <> removedEntries SubscriptionRemoved (^. #subscriptionId) (previous ^. #inventorySubscriptions) (current ^. #inventorySubscriptions)
        <> removedEntries DedupKeyRemoved (^. #dedupKeyId) (previous ^. #inventoryDedupKeys) (current ^. #inventoryDedupKeys)
        <> ownerChanges
        <> groupChanges
    )
  where
    previousTargets = Map.fromList [(entry ^. #targetId, entry) | entry <- previous ^. #inventoryTargets]
    currentTargets = Map.fromList [(entry ^. #targetId, entry) | entry <- current ^. #inventoryTargets]
    ownerChanges =
      [ TargetOwnerChanged targetId (old ^. #owner) (new ^. #owner)
      | (targetId, old) <- Map.toList previousTargets,
        Just new <- [Map.lookup targetId currentTargets],
        old ^. #owner /= new ^. #owner
      ]
    previousGroups = targetGroups previous
    currentGroups = targetGroups current
    groupChanges =
      [ TargetGroupChanged targetId oldGroup newGroup
      | (targetId, oldGroup) <- Map.toList previousGroups,
        Just newGroup <- [Map.lookup targetId currentGroups],
        oldGroup /= newGroup
      ]

removedEntries ::
  (Ord key) =>
  (key -> evolution) ->
  (entry -> key) ->
  [entry] ->
  [entry] ->
  [evolution]
removedEntries constructor key previous current =
  [ constructor previousKey
  | previousEntry <- previous,
    let previousKey = key previousEntry,
    previousKey `Set.notMember` currentKeys
  ]
  where
    currentKeys = Set.fromList (map key current)

targetGroups :: CatalogInventory -> Map TargetId RebuildGroupId
targetGroups inventory =
  Map.fromList
    [ (targetId, group ^. #rebuildGroupId)
    | group <- inventory ^. #inventoryGroups,
      targetId <- group ^. #orderedTargets
    ]

duplicateDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [QueryFacts] -> [CatalogDiagnostic]
duplicateDiagnostics catalog facts queryFacts =
  duplicateBy DuplicateSourceId sourceIdText (^. #sourceId) (^. #claimSite) (catalog ^. #sources)
    <> duplicateBy DuplicateTargetId targetIdText (^. #targetId) (^. #claimSite) (catalog ^. #targets)
    <> duplicateBy DuplicateQualifiedTable renderQualifiedTable (^. #qualifiedTable) (^. #claimSite) (catalog ^. #targets)
    <> duplicateBy DuplicateRebuildGroupId rebuildGroupIdText (^. #rebuildGroupId) (^. #claimSite) (catalog ^. #rebuildGroups)
    <> duplicateBy DuplicateSubscriptionId subscriptionIdText (^. #subscriptionId) (^. #claimSite) (catalog ^. #subscriptions)
    <> duplicateBy DuplicateSubscriptionName (\value -> value) (^. #subscriptionName) (^. #claimSite) (catalog ^. #subscriptions)
    <> duplicateBy DuplicateDedupKeyId dedupKeyIdText (^. #dedupKeyId) (^. #claimSite) (catalog ^. #dedupKeys)
    <> duplicateBy DuplicateDedupName (\value -> value) (^. #dedupName) (^. #claimSite) (catalog ^. #dedupKeys)
    <> duplicateBy DuplicateProjectionId projectionIdText factProjectionId factSite facts
    <> duplicateBy DuplicateProjectionRevisionId projectionRevisionIdText (^. #revisionId) (^. #claimSite) (catalog ^. #projectionRevisions)
    <> duplicateBy
      DuplicateExternalReadContractVersion
      renderExternalReadContractKey
      externalReadContractKey
      (^. #claimSite)
      (catalog ^. #externalReadContracts)
    <> duplicateBy
      DuplicateExternalReadFunctionName
      id
      externalReadFunctionName
      (^. #claimSite)
      (catalog ^. #externalReadContracts)
    <> duplicateBy DuplicateQueryModelId queryModelIdText factQueryModelId factQuerySite queryFacts
    <> duplicateBy DuplicateQueryModelRegistryName (\value -> value) factRegistryName factQuerySite queryFacts
    <> concatMap duplicateTargetsInGroup (catalog ^. #rebuildGroups)

renderExternalReadContractKey :: (ExternalReadContractId, ExternalReadContractVersion) -> Text
renderExternalReadContractKey (contractId, version) =
  externalReadContractIdText contractId
    <> "/v"
    <> Text.pack (show (externalReadContractVersionValue version))

externalReadContractKey :: ExternalReadContract -> (ExternalReadContractId, ExternalReadContractVersion)
externalReadContractKey contract =
  (contract ^. #readContractId, contract ^. #contractVersion)

duplicateBy ::
  (Ord key) =>
  CatalogDiagnosticCode ->
  (key -> Text) ->
  (value -> key) ->
  (value -> ClaimSite) ->
  [value] ->
  [CatalogDiagnostic]
duplicateBy code renderKey key site values =
  [ diagnostic code (renderKey duplicateKey) sites "identity is declared more than once"
  | (duplicateKey, claims) <- Map.toList grouped,
    let sites = List.sort (List.nub (map site claims)),
    List.length claims > 1
  ]
  where
    grouped = Map.fromListWith (<>) [(key value, [value]) | value <- values]

duplicateTargetsInGroup :: RebuildGroupDeclaration -> [CatalogDiagnostic]
duplicateTargetsInGroup group =
  [ diagnostic
      DuplicateGroupTarget
      (targetIdText targetId)
      [group ^. #claimSite]
      ("target occurs more than once in rebuild group " <> rebuildGroupIdText (group ^. #rebuildGroupId))
  | targetId <- duplicates (group ^. #orderedTargets)
  ]

referenceDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [QueryFacts] -> [CatalogDiagnostic]
referenceDiagnostics catalog facts queryFacts =
  groupTargetReferences
    <> targetDependencies
    <> subscriptionSourceReferences
    <> projectionReferences
    <> queryReferences
  where
    sourceIds = Set.fromList [source ^. #sourceId | source <- catalog ^. #sources]
    targetIds = Set.fromList [target ^. #targetId | target <- catalog ^. #targets]
    groupIds = Set.fromList [group ^. #rebuildGroupId | group <- catalog ^. #rebuildGroups]
    subscriptionIds = Set.fromList [subscription ^. #subscriptionId | subscription <- catalog ^. #subscriptions]
    dedupIds = Set.fromList [key ^. #dedupKeyId | key <- catalog ^. #dedupKeys]
    subscriptionsById = Map.fromList [(subscription ^. #subscriptionId, subscription) | subscription <- catalog ^. #subscriptions]
    dedupById = Map.fromList [(key ^. #dedupKeyId, key) | key <- catalog ^. #dedupKeys]
    queriesByRegistryName = Map.fromList [(factRegistryName query, query) | query <- queryFacts]
    groupTargetReferences =
      [ diagnostic UnknownTargetReference (targetIdText targetId) [group ^. #claimSite] "rebuild group references an unknown target"
      | group <- catalog ^. #rebuildGroups,
        targetId <- group ^. #orderedTargets,
        targetId `Set.notMember` targetIds
      ]
    targetDependencies =
      [ diagnostic UnknownTargetDependency (targetIdText dependency) [target ^. #claimSite] ("target dependency is unknown for " <> targetIdText (target ^. #targetId))
      | target <- catalog ^. #targets,
        dependency <- target ^. #dependsOn,
        dependency `Set.notMember` targetIds
      ]
    subscriptionSourceReferences =
      [ diagnostic UnknownSourceReference (sourceIdText sourceId) [subscription ^. #claimSite] "subscription references an unknown source"
      | subscription <- catalog ^. #subscriptions,
        let sourceId = subscription ^. #subscriptionSource,
        sourceId `Set.notMember` sourceIds
      ]
    projectionReferences = concatMap projectionReference facts
    projectionReference fact =
      [ diagnostic UnknownSourceReference (sourceIdText (factSourceId fact)) [factSite fact] "projection set references an unknown source"
      | factSourceId fact `Set.notMember` sourceIds
      ]
        <> [ diagnostic UnknownGroupReference (rebuildGroupIdText (factGroupId fact)) [factSite fact] "projection references an unknown rebuild group"
           | factGroupId fact `Set.notMember` groupIds
           ]
        <> [ diagnostic UnknownTargetReference (targetIdText targetId) [factSite fact] ("projection references an unknown target: " <> projectionIdText (factProjectionId fact))
           | targetId <- factTargets fact,
             targetId `Set.notMember` targetIds
           ]
        <> concatMap (handlerReference fact) (factHandlers fact)
    handlerReference _ (InlineFacts _ _) = []
    handlerReference fact (AsyncFacts projectionName readModelName liveSubscriptionName subscriptionId dedupId site) =
      [ diagnostic UnknownSubscriptionReference (subscriptionIdText subscriptionId) [site] "async handler references an unknown subscription"
      | subscriptionId `Set.notMember` subscriptionIds
      ]
        <> [ diagnostic UnknownDedupKeyReference (dedupKeyIdText dedupId) [site] "async handler references an unknown dedup key"
           | dedupId `Set.notMember` dedupIds
           ]
        <> [ diagnostic UnknownQueryModelReference readModelName [site] "async handler references an unknown query-model registry name"
           | readModelName `Map.notMember` queriesByRegistryName
           ]
        <> [ diagnostic AsyncHandlerSubscriptionMismatch projectionName [site, subscription ^. #claimSite] "async handler subscription name or source differs from its catalog declaration"
           | Just subscription <- [Map.lookup subscriptionId subscriptionsById],
             subscription ^. #subscriptionName /= liveSubscriptionName
               || subscription ^. #subscriptionSource /= factSourceId fact
           ]
        <> [ diagnostic AsyncHandlerDedupMismatch projectionName [site, key ^. #claimSite] "async handler name must match its declared deduplication name"
           | Just key <- [Map.lookup dedupId dedupById],
             key ^. #dedupName /= projectionName
           ]
        <> [ diagnostic QueryModelOutsideRebuildGroup readModelName [site, factQuerySite query] "async handler's query model belongs to another rebuild group"
           | Just query <- [Map.lookup readModelName queriesByRegistryName],
             factQueryGroup query /= factGroupId fact
           ]
    queryReferences = concatMap queryReference queryFacts
    queryReference query =
      [ diagnostic UnknownGroupReference (rebuildGroupIdText (factQueryGroup query)) [factQuerySite query] "query model references an unknown rebuild group"
      | factQueryGroup query `Set.notMember` groupIds
      ]
        <> [ diagnostic UnknownTargetReference (targetIdText targetId) [factQuerySite query] "query model references an unknown target"
           | targetId <- factObservedTargets query,
             targetId `Set.notMember` targetIds
           ]

ownershipDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [CatalogDiagnostic]
ownershipDiagnostics catalog facts =
  concatMap targetOwnership (catalog ^. #targets)
  where
    targetOwnership target =
      case [fact | fact <- facts, target ^. #targetId `List.elem` factTargets fact] of
        [] ->
          [ diagnostic TargetWithoutOwner (targetIdText (target ^. #targetId)) [target ^. #claimSite] "declared target has no projection owner"
          ]
        [_] -> []
        owners ->
          [ diagnostic
              TargetWithMultipleOwners
              (targetIdText (target ^. #targetId))
              (map factSite owners)
              ( "target has multiple independent projection owners: "
                  <> Text.intercalate ", " (map (projectionIdText . factProjectionId) owners)
              )
          ]

groupDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [QueryFacts] -> [CatalogDiagnostic]
groupDiagnostics catalog facts queryFacts =
  emptyGroups
    <> groupMembership
    <> crossGroupProjections
    <> dependencyCycles
    <> dependencyOrder
    <> queryCoverage
  where
    groups = catalog ^. #rebuildGroups
    targets = catalog ^. #targets
    groupByTarget =
      Map.fromListWith
        (<>)
        [ (targetId, [group ^. #rebuildGroupId])
        | group <- groups,
          targetId <- group ^. #orderedTargets
        ]
    emptyGroups =
      [ diagnostic EmptyRebuildGroup (rebuildGroupIdText (group ^. #rebuildGroupId)) [group ^. #claimSite] "rebuild group must contain at least one target"
      | group <- groups,
        null (group ^. #orderedTargets)
      ]
    groupMembership =
      [ diagnostic
          ProjectionCrossesRebuildGroups
          (targetIdText (target ^. #targetId))
          (target ^. #claimSite : [group ^. #claimSite | group <- groups, target ^. #targetId `List.elem` group ^. #orderedTargets])
          "target must belong to exactly one rebuild group"
      | target <- targets,
        List.length (Map.findWithDefault [] (target ^. #targetId) groupByTarget) /= 1
      ]
    crossGroupProjections =
      [ diagnostic
          ProjectionCrossesRebuildGroups
          (projectionIdText (factProjectionId fact))
          [factSite fact]
          "one transactional projection may write targets from only its declared rebuild group"
      | fact <- facts,
        let targetGroupsForProjection =
              Set.fromList
                [ groupId
                | targetId <- factTargets fact,
                  groupId <- Map.findWithDefault [] targetId groupByTarget
                ],
        targetGroupsForProjection /= Set.singleton (factGroupId fact)
      ]
    dependencyCycles =
      [ diagnostic
          TargetDependencyCycle
          (Text.intercalate "," (List.sort (map (targetIdText . (^. #targetId)) cycleTargets)))
          (map (^. #claimSite) cycleTargets)
          "target dependencies contain a cycle"
      | CyclicSCC cycleTargets <- stronglyConnComp graph
      ]
    graph =
      [ (target, target ^. #targetId, filter (`Map.member` targetMap) (target ^. #dependsOn))
      | target <- targets
      ]
    targetMap = Map.fromList [(target ^. #targetId, target) | target <- targets]
    dependencyOrder = concatMap groupOrderDiagnostics groups
    groupOrderDiagnostics group =
      [ diagnostic
          TargetOrderViolatesDependency
          (targetIdText (target ^. #targetId))
          [target ^. #claimSite, group ^. #claimSite]
          ("dependency " <> targetIdText dependency <> " must precede target in rebuild group")
      | (position, targetId) <- List.zip [0 :: Int ..] (group ^. #orderedTargets),
        Just target <- [Map.lookup targetId targetMap],
        dependency <- target ^. #dependsOn,
        Just dependencyPosition <- [List.elemIndex dependency (group ^. #orderedTargets)],
        dependencyPosition >= position
      ]
    queryCoverage =
      [ diagnostic
          QueryModelOutsideRebuildGroup
          (queryModelIdText (factQueryModelId query))
          [factQuerySite query]
          "query model observes a target not covered by its rebuild group"
      | query <- queryFacts,
        let covered =
              Set.fromList
                [ targetId
                | group <- groups,
                  group ^. #rebuildGroupId == factQueryGroup query,
                  targetId <- group ^. #orderedTargets
                ],
        any (`Set.notMember` covered) (factObservedTargets query)
      ]

-- | Validate the relation later exposed by 'resolvedQuerySupplies'. Existing
-- declaration/reference/ownership diagnostics remain the primary errors for
-- malformed identities, so this layer stays quiet until those prerequisites
-- are individually valid.
querySupplyDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [QueryFacts] -> [CatalogDiagnostic]
querySupplyDiagnostics catalog facts queryFacts = concatMap diagnosticsForQuery queryFacts
  where
    declaredTargets = Set.fromList [target ^. #targetId | target <- catalog ^. #targets]
    declaredGroups = Set.fromList [group ^. #rebuildGroupId | group <- catalog ^. #rebuildGroups]
    ownersByTarget =
      Map.fromListWith
        (<>)
        [ (targetId, [fact])
        | fact <- facts,
          targetId <- factTargets fact
        ]
    groupsByTarget =
      Map.fromListWith
        (<>)
        [ (targetId, [group ^. #rebuildGroupId])
        | group <- catalog ^. #rebuildGroups,
          targetId <- group ^. #orderedTargets
        ]
    projectionCounts = Map.fromListWith (+) [(factProjectionId fact, 1 :: Int) | fact <- facts]
    queryCounts = Map.fromListWith (+) [(factQueryModelId query, 1 :: Int) | query <- queryFacts]

    diagnosticsForQuery query
      | Map.findWithDefault 0 (factQueryModelId query) queryCounts /= 1 = []
      | null targets =
          [ diagnostic
              EmptyQueryObservedTargets
              queryIdentity
              [factQuerySite query]
              "catalog-bound query model must observe at least one target"
          ]
      | not prerequisitesValid = []
      | otherwise =
          case List.sort (Set.toList supplierIds) of
            [] ->
              [ diagnostic
                  QueryModelWithoutSupplier
                  queryIdentity
                  [factQuerySite query]
                  "query model's observed targets do not resolve to one projection supplier"
              ]
            [_] -> []
            suppliers ->
              [ diagnostic
                  QueryModelWithMultipleSuppliers
                  queryIdentity
                  (factQuerySite query : map factSite supplierFacts)
                  ( "query model's observed targets span several projection suppliers: "
                      <> Text.intercalate ", " (map projectionIdText suppliers)
                  )
              ]
      where
        targets = factObservedTargets query
        queryIdentity = queryModelIdText (factQueryModelId query)
        targetOwners = [owners | targetId <- targets, let owners = Map.findWithDefault [] targetId ownersByTarget]
        supplierFacts = List.nubBy (\left right -> factProjectionId left == factProjectionId right) (concat targetOwners)
        supplierIds = Set.fromList (map factProjectionId supplierFacts)
        prerequisitesValid =
          factQueryGroup query `Set.member` declaredGroups
            && all (`Set.member` declaredTargets) targets
            && all ((== 1) . List.length) targetOwners
            && all
              ( \targetId ->
                  Map.findWithDefault [] targetId groupsByTarget == [factQueryGroup query]
              )
              targets
            && all
              ( \case
                  [owner] -> factGroupId owner == factQueryGroup query
                  _ -> False
              )
              targetOwners
            && all
              ( \case
                  [owner] -> Map.findWithDefault 0 (factProjectionId owner) projectionCounts == 1
                  _ -> False
              )
              targetOwners

data QueryCursorCandidate
  = QueryCursorCandidate
      !SubscriptionId
      !Text
      !SourceScope
      !ClaimSite
  deriving stock (Eq, Ord, Show)

-- | Validate only query policies that actually wait. Immediate queries remain
-- valid for inline, subscription, and composed owners; they merely expose no
-- per-call cursor when the owner has zero or several durable authorities.
queryFreshnessDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [QueryFacts] -> [CatalogDiagnostic]
queryFreshnessDiagnostics catalog facts = concatMap diagnosticsForQuery
  where
    diagnosticsForQuery query =
      case factQueryFreshness query of
        Immediate -> []
        requested ->
          case queryOwner facts query of
            Nothing -> []
            Just owner ->
              let allCandidates = queryCursorCandidates catalog owner
                  compatible = compatibleQueryCursors requested allCandidates
                  sites =
                    List.sort
                      . List.nub
                      $ factQuerySite query
                        : factSite owner
                        : map handlerClaimSite (factHandlers owner)
                  detail = cursorDiagnosticDetail requested owner allCandidates
               in case compatible of
                    [] ->
                      [ diagnostic
                          QueryWaitWithoutCompatibleCursor
                          (queryModelIdText (factQueryModelId query))
                          sites
                          ( "query wait has no compatible durable cursor; "
                              <> detail
                              <> "; remedy: use Immediate or give the supplying owner one compatible subscription"
                          )
                      ]
                    [_] -> []
                    _ ->
                      [ diagnostic
                          QueryWaitWithAmbiguousCursor
                          (queryModelIdText (factQueryModelId query))
                          sites
                          ( "query wait has several compatible durable cursors; "
                              <> detail
                              <> "; remedy: leave exactly one compatible subscription or use Immediate"
                          )
                      ]

queryOwner :: [ProjectionFacts] -> QueryFacts -> Maybe ProjectionFacts
queryOwner facts query =
  case List.nubBy
    (\left right -> factProjectionId left == factProjectionId right)
    [ fact
    | targetId <- factObservedTargets query,
      fact <- facts,
      targetId `List.elem` factTargets fact
    ] of
    [owner]
      | not (null (factObservedTargets query)),
        factGroupId owner == factQueryGroup query,
        all (`List.elem` factTargets owner) (factObservedTargets query) ->
          Just owner
    _ -> Nothing

queryCursorCandidates :: ProjectionCatalog -> ProjectionFacts -> [QueryCursorCandidate]
queryCursorCandidates catalog owner =
  List.nubBy sameCursor
    . List.sortOn candidateKey
    $ mapMaybe candidateFor (factHandlers owner)
  where
    subscriptionsById =
      Map.fromList
        [ (subscription ^. #subscriptionId, subscription)
        | subscription <- catalog ^. #subscriptions
        ]
    sourcesById =
      Map.fromList
        [ (source ^. #sourceId, source)
        | source <- catalog ^. #sources
        ]

    candidateFor (InlineFacts _ _) = Nothing
    candidateFor (AsyncFacts _ _ _ subscriptionId _ site) = do
      subscription <- Map.lookup subscriptionId subscriptionsById
      source <- Map.lookup (subscription ^. #subscriptionSource) sourcesById
      pure
        ( QueryCursorCandidate
            subscriptionId
            (subscription ^. #subscriptionName)
            (source ^. #sourceScope)
            site
        )

    candidateKey (QueryCursorCandidate subscriptionId name scope _) =
      (subscriptionId, name, scope)
    sameCursor left right = candidateKey left == candidateKey right

compatibleQueryCursors :: QueryFreshness -> [QueryCursorCandidate] -> [QueryCursorCandidate]
compatibleQueryCursors freshness =
  case freshness of
    Immediate -> id
    WaitForPosition _ -> id
    WaitForHead scope -> filter (headScopeReachable scope . candidateScope)
  where
    candidateScope (QueryCursorCandidate _ _ scope _) = scope

headScopeReachable :: HeadScope -> SourceScope -> Bool
headScopeReachable EntireVisibleLog AllStreams = True
headScopeReachable EntireVisibleLog CategorySource {} = False
headScopeReachable CategoryVisibleHead {} AllStreams = True
headScopeReachable (CategoryVisibleHead wanted) (CategorySource (CategoryName actual)) =
  wanted == actual

cursorDiagnosticDetail :: QueryFreshness -> ProjectionFacts -> [QueryCursorCandidate] -> Text
cursorDiagnosticDetail requested owner candidates =
  "query freshness="
    <> queryFreshnessText requested
    <> ", owner="
    <> projectionIdText (factProjectionId owner)
    <> ", delivery capabilities="
    <> Text.intercalate "," (map renderHandlerFact (factHandlers owner))
    <> ", cursor candidates="
    <> if null candidates
      then "none"
      else Text.intercalate "," (map renderCursorCandidate candidates)

queryFreshnessText :: QueryFreshness -> Text
queryFreshnessText Immediate = "immediate"
queryFreshnessText (WaitForHead scope) = "wait-for-head(" <> headScopeText scope <> ")"
queryFreshnessText WaitForPosition {} = "wait-for-position"

headScopeText :: HeadScope -> Text
headScopeText EntireVisibleLog = "entire-visible-log"
headScopeText (CategoryVisibleHead category) = "category-visible-head:" <> category

renderHandlerFact :: HandlerFacts -> Text
renderHandlerFact (InlineFacts name _) = "inline:" <> name
renderHandlerFact (AsyncFacts name _ _ subscriptionId _ _) =
  "subscription:" <> name <> "/" <> subscriptionIdText subscriptionId

renderCursorCandidate :: QueryCursorCandidate -> Text
renderCursorCandidate (QueryCursorCandidate subscriptionId name scope _) =
  subscriptionIdText subscriptionId
    <> "/"
    <> name
    <> "/"
    <> renderScope scope

handlerClaimSite :: HandlerFacts -> ClaimSite
handlerClaimSite (InlineFacts _ site) = site
handlerClaimSite (AsyncFacts _ _ _ _ _ site) = site

replayDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [CatalogDiagnostic]
replayDiagnostics catalog facts =
  clearRequiresReplay <> currentHeadAfterClear <> mixedGroupReplay
  where
    ownerFor targetId = List.find (\fact -> targetId `List.elem` factTargets fact) facts
    targets = catalog ^. #targets
    groups = catalog ^. #rebuildGroups
    targetMap = Map.fromList [(target ^. #targetId, target) | target <- targets]
    subscriptionsById = Map.fromList [(subscription ^. #subscriptionId, subscription) | subscription <- catalog ^. #subscriptions]
    clearRequiresReplay =
      [ diagnostic
          ClearTargetRequiresReplayableOwner
          (targetIdText (target ^. #targetId))
          [target ^. #claimSite, factSite owner]
          "a clear-before-replay target requires a replayable owner"
      | target <- targets,
        target ^. #resetPolicy == ClearBeforeReplay,
        Just owner <- [ownerFor (target ^. #targetId)],
        not (factReplayable owner)
      ]
    currentHeadAfterClear =
      [ diagnostic
          ReplayableClearTargetStartsAtCurrentHead
          (subscriptionIdText subscriptionId <> "/" <> targetIdText targetId)
          [subscription ^. #claimSite, target ^. #claimSite, handlerSite, factSite fact]
          ( "subscription "
              <> subscription ^. #subscriptionName
              <> " ("
              <> subscriptionIdText subscriptionId
              <> ") uses FromCurrentHead for replayable target "
              <> targetIdText targetId
              <> " with ClearBeforeReplay; seeding the current head would skip the history required to rebuild the cleared target"
          )
      | fact <- facts,
        factReplayable fact,
        AsyncFacts _ _ _ subscriptionId _ handlerSite <- factHandlers fact,
        Just subscription <- [Map.lookup subscriptionId subscriptionsById],
        subscription ^. #checkpointOnMissing == FromCurrentHead,
        targetId <- factTargets fact,
        Just target <- [Map.lookup targetId targetMap],
        target ^. #resetPolicy == ClearBeforeReplay
      ]
    mixedGroupReplay =
      [ diagnostic
          MixedResetGroupRequiresReplayAdapter
          (projectionIdText (factProjectionId owner))
          [group ^. #claimSite, factSite owner]
          "preserve-and-reconcile targets in a mixed group require explicit replay adapters"
      | group <- groups,
        let groupTargets = mapMaybeTarget group,
        any ((== ClearBeforeReplay) . (^. #resetPolicy)) groupTargets,
        any ((== PreserveAndReconcile) . (^. #resetPolicy)) groupTargets,
        target <- groupTargets,
        target ^. #resetPolicy == PreserveAndReconcile,
        Just owner <- [ownerFor (target ^. #targetId)],
        not (factReplayable owner)
      ]
    mapMaybeTarget group =
      [ target
      | targetId <- group ^. #orderedTargets,
        Just target <- [Map.lookup targetId targetMap]
      ]

sourceOrderingDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [CatalogDiagnostic]
sourceOrderingDiagnostics catalog facts =
  [ diagnostic
      AmbiguousSourceOrdering
      (rebuildGroupIdText groupId)
      (map factSite groupFacts)
      "one rebuild group cannot combine an all-stream source with category sources"
  | groupId <- Set.toList (Set.fromList (map factGroupId facts)),
    let groupFacts = filter ((== groupId) . factGroupId) facts,
    let scopes =
          [ source ^. #sourceScope
          | fact <- groupFacts,
            source <- catalog ^. #sources,
            source ^. #sourceId == factSourceId fact
          ],
    AllStreams `List.elem` scopes,
    any isCategory scopes
  ]
  where
    isCategory (CategorySource _) = True
    isCategory AllStreams = False

verificationDiagnostics :: ProjectionCatalog -> [CatalogDiagnostic]
verificationDiagnostics catalog = concatMap verificationGroupDiagnostics (catalog ^. #rebuildGroups)
  where
    verificationGroupDiagnostics group = duplicateIds group <> invalidIdentities group

    duplicateIds group =
      [ diagnostic
          DuplicateRebuildVerificationId
          verificationId
          [group ^. #claimSite]
          "verification identities must be unique within a rebuild group"
      | verificationId <- duplicates (map (^. #verificationId) (group ^. #verificationHooks))
      ]

    invalidIdentities group =
      [ diagnostic
          InvalidRebuildVerificationIdentity
          (hook ^. #verificationId)
          [group ^. #claimSite]
          "verification identity and version must be non-empty and have no surrounding whitespace"
      | hook <- group ^. #verificationHooks,
        invalid (hook ^. #verificationId) || invalid (hook ^. #verificationVersion)
      ]

    invalid value = Text.null value || Text.strip value /= value

projectionRevisionDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [CatalogDiagnostic]
projectionRevisionDiagnostics catalog facts =
  concatMap revisionDiagnostics revisions
  where
    revisions = catalog ^. #projectionRevisions
    groupsById =
      Map.fromList
        [ (group ^. #rebuildGroupId, group)
        | group <- catalog ^. #rebuildGroups
        ]
    declaredTargets = Set.fromList [target ^. #targetId | target <- catalog ^. #targets]

    revisionDiagnostics revision =
      unknownGroup
        <> unknownProvisioners
        <> targetSetDrift
        <> missingLive
        <> missingReplay
        <> missingValidation
        <> nonTotalMappings
        <> liveCapabilityMismatch
        <> liveTargetOwnershipMismatch
        <> invalidIdentities
      where
        revisionIdentity = projectionRevisionIdText (revision ^. #revisionId)
        site = revision ^. #claimSite
        provisionerEntries = Map.toAscList (revision ^. #targetProvisioners)
        provisionedTargets = Map.keysSet (revision ^. #targetProvisioners)
        maybeGroup = Map.lookup (revision ^. #rebuildGroup) groupsById
        expectedTargets =
          Set.fromList $ maybe [] (^. #orderedTargets) maybeGroup
        groupFacts = filter ((== revision ^. #rebuildGroup) . factGroupId) facts
        expectedLive = List.sort (concatMap factLiveDeliveries groupFacts)
        actualLive = List.sort (map (^. #delivery) (revision ^. #liveHandlers))
        expectedTargetsByDelivery =
          Map.fromList
            [ (deliveryCapability, Set.fromList (factTargets fact))
            | fact <- groupFacts,
              deliveryCapability <- factLiveDeliveries fact
            ]
        unknownGroup =
          [ diagnostic
              UnknownGroupReference
              (rebuildGroupIdText (revision ^. #rebuildGroup))
              [site]
              ("projection revision " <> revisionIdentity <> " references an unknown rebuild group")
          | isNothing maybeGroup
          ]
        unknownProvisioners =
          [ diagnostic
              UnknownTargetProvisioner
              (targetIdText targetId)
              [site]
              ("projection revision " <> revisionIdentity <> " supplies a provisioner for an unknown target")
          | (targetId, _) <- provisionerEntries,
            targetId `Set.notMember` declaredTargets
          ]
        targetSetDrift =
          [ diagnostic
              ProjectionRevisionTargetSetDrift
              revisionIdentity
              [site, group ^. #claimSite]
              ( "projection revision target set differs from rebuild group; expected="
                  <> renderTargetSet expectedTargets
                  <> ", supplied="
                  <> renderTargetSet provisionedTargets
              )
          | Just group <- [maybeGroup],
            provisionedTargets /= expectedTargets
          ]
        missingLive =
          [ diagnostic
              ProjectionRevisionWithoutLiveHandler
              revisionIdentity
              [site]
              "projection revision must supply at least one live handler"
          | null (revision ^. #liveHandlers)
          ]
        missingReplay =
          [ diagnostic
              ProjectionRevisionWithoutReplayAdapter
              revisionIdentity
              [site]
              "projection revision must supply at least one replay adapter"
          | null (revision ^. #replayAdapters)
          ]
        missingValidation =
          [ diagnostic
              ProjectionRevisionMissingSchemaValidation
              (revisionIdentity <> "/" <> targetIdText targetId)
              [site]
              "target provisioner must supply schema validation before replay or promotion"
          | (targetId, provisioner) <- provisionerEntries,
            isNothing (provisioner ^. #validateTarget)
          ]
        nonTotalMappings =
          [ diagnostic
              ProjectionRevisionPhysicalTargetsNotTotal
              (revisionIdentity <> "/" <> handlerIdentity)
              [site]
              ( "revision closure requires a non-total physical target set; expected="
                  <> renderTargetSet expectedTargets
                  <> ", required="
                  <> renderTargetSet required
              )
          | (handlerIdentity, requiredTargets) <- revisionRequirements revision,
            let required = Set.fromList requiredTargets,
            isJust maybeGroup,
            required /= expectedTargets
          ]
        liveCapabilityMismatch =
          [ diagnostic
              ProjectionRevisionLiveCapabilityMismatch
              revisionIdentity
              (site : map factSite groupFacts)
              ( "revision live deliveries differ from the catalog owners; expected="
                  <> renderLiveDeliveries expectedLive
                  <> ", supplied="
                  <> renderLiveDeliveries actualLive
              )
          | expectedLive /= actualLive
          ]
        liveTargetOwnershipMismatch =
          [ diagnostic
              ProjectionRevisionLiveTargetOwnershipMismatch
              (revisionIdentity <> "/" <> handler ^. #handlerId)
              (site : maybe [] (pure . factSite) (factForDelivery (handler ^. #delivery)))
              ( "revision live handler targets differ from its supplying projection; expected="
                  <> renderTargetSet owned
                  <> ", supplied="
                  <> renderTargetSet supplied
              )
          | handler <- revision ^. #liveHandlers,
            Just owned <- [Map.lookup (handler ^. #delivery) expectedTargetsByDelivery],
            let supplied = Set.fromList (handler ^. #requiredTargets),
            supplied /= owned
          ]
        invalidIdentities =
          [ diagnostic
              InvalidProjectionRevisionIdentity
              (revisionIdentity <> "/" <> identity)
              [site]
              "revision, provisioner, validator, handler, adapter, and verification identities must be non-empty and have no surrounding whitespace; numeric versions must be positive"
          | (identity, version) <- revisionIdentities revision,
            invalid identity || version < 1
          ]

    factLiveDeliveries fact =
      [ case handler of
          InlineFacts name _ -> RevisionInlineDelivery (factProjectionId fact) name
          AsyncFacts _ _ _ subscriptionId dedupId _ ->
            RevisionSubscriptionDelivery (factProjectionId fact) subscriptionId dedupId
      | handler <- factHandlers fact
      ]
    factForDelivery wanted =
      List.find (List.elem wanted . factLiveDeliveries) facts
    renderLiveDeliveries = Text.intercalate "," . map renderRevisionLiveDelivery
    invalid value = Text.null value || Text.strip value /= value
    renderTargetSet = Text.intercalate "," . map targetIdText . Set.toAscList

streamScopedReplayDiagnostics :: ProjectionCatalog -> [ProjectionFacts] -> [CatalogDiagnostic]
streamScopedReplayDiagnostics catalog facts =
  concatMap revisionDiagnostics (catalog ^. #projectionRevisions)
  where
    factsById = Map.fromList [(factProjectionId fact, fact) | fact <- facts]

    revisionDiagnostics revision =
      duplicatePolicies <> concatMap (policyDiagnostics revision) policies
      where
        policies = revision ^. #streamScopedReplays
        duplicatePolicies =
          [ diagnostic
              DuplicateStreamScopedReplayProjection
              ( projectionRevisionIdText (revision ^. #revisionId)
                  <> "/"
                  <> projectionIdText projectionId
              )
              (List.sort [policy ^. #claimSite | policy <- policies, policy ^. #streamProjectionId == projectionId])
              "a projection revision may declare at most one stream-scoped repair policy per projection"
          | projectionId <- duplicates (map (^. #streamProjectionId) policies)
          ]

    policyDiagnostics revision policy =
      case Map.lookup (policy ^. #streamProjectionId) factsById of
        Nothing ->
          [ diagnostic
              UnknownStreamScopedReplayProjection
              identity
              [policy ^. #claimSite, revision ^. #claimSite]
              "stream-scoped repair policy references a projection absent from the catalog"
          ]
            <> invalidIdentityDiagnostics
        Just fact ->
          policyGroupDiagnostics fact
            <> targetDiagnostics fact
            <> dedupDiagnostics fact
            <> invalidIdentityDiagnostics
      where
        identity =
          projectionRevisionIdText (revision ^. #revisionId)
            <> "/"
            <> projectionIdText (policy ^. #streamProjectionId)
        invalidIdentityDiagnostics =
          [ diagnostic
              InvalidStreamScopedReplayIdentity
              (identity <> "/" <> stableIdentity)
              [policy ^. #claimSite]
              "stream clearer, replay, and verification identities must be non-empty without surrounding whitespace and versions must be positive"
          | (stableIdentity, version) <-
              [ (policy ^. #clearerId, policy ^. #clearerVersion),
                (policy ^. #streamReplayId, policy ^. #streamReplayVersion),
                (policy ^. #streamVerificationId, policy ^. #streamVerificationVersion)
              ],
            Text.null stableIdentity || Text.strip stableIdentity /= stableIdentity || version < 1
          ]
        policyGroupDiagnostics fact =
          [ diagnostic
              StreamScopedReplayGroupMismatch
              identity
              [policy ^. #claimSite, factSite fact, revision ^. #claimSite]
              "stream-scoped repair projection and projection revision must own the same rebuild group"
          | factGroupId fact /= revision ^. #rebuildGroup
          ]
        targetDiagnostics fact =
          [ diagnostic
              StreamScopedReplayTargetSetMismatch
              identity
              [policy ^. #claimSite, factSite fact, revision ^. #claimSite]
              "stream-scoped repair targets must exactly match the projection-owned targets and be unique"
          | let supplied = NonEmpty.toList (policy ^. #streamOwnedTargets)
                suppliedSet = Set.fromList supplied
                expectedSet = Set.fromList (factTargets fact)
                revisionTargets = Map.keysSet (revision ^. #targetProvisioners),
            suppliedSet /= expectedSet
              || List.length supplied /= Set.size suppliedSet
              || not (suppliedSet `Set.isSubsetOf` revisionTargets)
          ]
        dedupDiagnostics fact =
          [ diagnostic
              StreamScopedReplayDedupMismatch
              identity
              [policy ^. #claimSite, factSite fact]
              "affected async dedup identities must exactly match the projection's async handlers and be unique"
          | let supplied = policy ^. #affectedAsyncDedup
                suppliedSet = Set.fromList supplied
                expectedSet =
                  Set.fromList
                    [ dedupId
                    | AsyncFacts _ _ _ _ dedupId _ <- factHandlers fact
                    ],
            suppliedSet /= expectedSet || List.length supplied /= Set.size suppliedSet
          ]

externalReadContractDiagnostics :: ProjectionCatalog -> [QueryFacts] -> [CatalogDiagnostic]
externalReadContractDiagnostics catalog queryFacts =
  concatMap contractDiagnostics contracts
    <> implementationCollisions
    <> immutableSignatureDrift
    <> surfaceGenerationRegressions
  where
    contracts = catalog ^. #externalReadContracts
    queriesById = Map.fromList [(factQueryModelId query, query) | query <- queryFacts]
    revisionsById =
      Map.fromList
        [ (revision ^. #revisionId, revision)
        | revision <- catalog ^. #projectionRevisions
        ]

    contractDiagnostics contract =
      identityDiagnostics contract
        <> sqlIdentifierDiagnostics contract
        <> sqlTypeDiagnostics contract
        <> queryDiagnostics contract
        <> revisionDiagnostics contract

    identityDiagnostics contract =
      [ diagnostic
          InvalidExternalReadContractIdentity
          (renderExternalReadContractKey (externalReadContractKey contract))
          [contract ^. #claimSite]
          "contract identity, version, surface generation, result shape, and implementation version must be valid positive immutable facts"
      | invalidIdentity contract
      ]

    invalidIdentity contract =
      invalidText (externalReadContractIdText (contract ^. #readContractId))
        || externalReadContractVersionValue (contract ^. #contractVersion) < 1
        || contract ^. #surfaceGeneration < 1
        || invalidText (contract ^. #resultShapeHash)
        || case contract of
          AllRowsExternalRead {} -> False
          KeyedExternalRead {privateImplementationVersion = implementationVersion} ->
            implementationVersion < 1

    sqlIdentifierDiagnostics contract =
      [ diagnostic
          InvalidExternalReadSqlIdentifier
          (renderExternalReadContractKey (externalReadContractKey contract) <> "/" <> identity)
          [contract ^. #claimSite]
          "generated SQL identifiers must be lower-case PostgreSQL identifiers containing only letters, digits, and underscores"
      | identity <- contractSqlIdentifiers contract,
        not (safeSqlIdentifier identity)
      ]

    sqlTypeDiagnostics contract =
      [ diagnostic
          InvalidExternalReadSqlType
          (renderExternalReadContractKey (externalReadContractKey contract) <> "/" <> renderQualifiedType sqlType)
          [contract ^. #claimSite]
          "SQL contract types must be represented by separately validated schema and type identifiers"
      | sqlType <- contractSqlTypes contract,
        not (safeQualifiedType sqlType)
      ]

    queryDiagnostics contract =
      case Map.lookup (contract ^. #queryModelId) queriesById of
        Nothing ->
          [ diagnostic
              UnknownExternalReadQueryModel
              (queryModelIdText (contract ^. #queryModelId))
              [contract ^. #claimSite]
              "external read contract references a query model absent from the catalog"
          ]
        Just query ->
          [ diagnostic
              ExternalReadShapeMismatch
              (renderExternalReadContractKey (externalReadContractKey contract))
              [contract ^. #claimSite, factQuerySite query]
              ( "external read result shape does not match query model; expected="
                  <> factShapeHash query
                  <> ", supplied="
                  <> contract ^. #resultShapeHash
              )
          | contract ^. #resultShapeHash /= factShapeHash query
          ]

    revisionDiagnostics contract =
      concatMap (oneRevision contract) (NonEmpty.toList (contract ^. #compatibleRevisions))

    oneRevision contract revisionId =
      case Map.lookup revisionId revisionsById of
        Nothing ->
          [ diagnostic
              UnknownRevisionReference
              ( externalReadContractIdText (contract ^. #readContractId)
                  <> "/"
                  <> projectionRevisionIdText revisionId
              )
              [contract ^. #claimSite]
              "external read contract references a projection revision absent from the catalog"
          ]
        Just revision ->
          case Map.lookup (contract ^. #queryModelId) queriesById of
            Nothing -> []
            Just query ->
              [ diagnostic
                  ExternalReadRevisionOwnershipMismatch
                  ( externalReadContractIdText (contract ^. #readContractId)
                      <> "/"
                      <> projectionRevisionIdText revisionId
                  )
                  [contract ^. #claimSite, revision ^. #claimSite, factQuerySite query]
                  "compatible revision must own the query model's rebuild group and every observed target"
              | revision ^. #rebuildGroup /= factQueryGroup query
                  || not
                    ( Set.fromList (factObservedTargets query)
                        `Set.isSubsetOf` Map.keysSet (revision ^. #targetProvisioners)
                    )
              ]

    implementationCollisions =
      [ diagnostic
          ExternalReadImplementationCollision
          (renderQualifiedFunction function)
          (List.sort (map (^. #claimSite) claims))
          "a private keyed implementation may be owned by only one external read contract and may not occupy keiro_read"
      | (function, claims) <- Map.toList implementations,
        List.length claims > 1 || function ^. #functionSchema == "keiro_read"
      ]
      where
        implementations =
          Map.fromListWith
            (<>)
            [ (implementation, [contract])
            | contract@KeyedExternalRead {privateImplementation = implementation} <- contracts
            ]

    immutableSignatureDrift =
      [ diagnostic
          ExternalReadImmutableSignatureDrift
          (renderExternalReadContractKey key)
          (List.sort (map (^. #claimSite) claims))
          "the same contract identity/version declares more than one immutable public SQL signature"
      | (key, claims) <- Map.toList contractsByKey,
        List.length (List.nub (map externalReadImmutableSignature claims)) > 1
      ]
      where
        contractsByKey = Map.fromListWith (<>) [(externalReadContractKey contract, [contract]) | contract <- contracts]

    surfaceGenerationRegressions =
      [ diagnostic
          ExternalReadSurfaceGenerationRegression
          ( externalReadContractIdText contractId
              <> "/v"
              <> Text.pack (show (externalReadContractVersionValue (later ^. #contractVersion)))
          )
          [earlier ^. #claimSite, later ^. #claimSite]
          "a later contract version cannot declare a lower surface generation"
      | (contractId, sameId) <- Map.toList contractsById,
        earlier <- sameId,
        later <- sameId,
        earlier ^. #contractVersion < later ^. #contractVersion,
        earlier ^. #surfaceGeneration > later ^. #surfaceGeneration
      ]
      where
        contractsById = Map.fromListWith (<>) [(contract ^. #readContractId, [contract]) | contract <- contracts]

    invalidText value = Text.null value || Text.strip value /= value

contractSqlIdentifiers :: ExternalReadContract -> [Text]
contractSqlIdentifiers contract =
  externalReadContractIdText (contract ^. #readContractId)
    : externalReadFunctionName contract
    : case contract of
      AllRowsExternalRead {} -> []
      KeyedExternalRead {privateImplementation = implementation, arguments = keyedArguments} ->
        implementation ^. #functionSchema
          : implementation ^. #functionName
          : map (^. #argumentName) keyedArguments

contractSqlTypes :: ExternalReadContract -> [QualifiedSqlType]
contractSqlTypes AllRowsExternalRead {resultContractType = resultType} = [resultType]
contractSqlTypes KeyedExternalRead {resultContractType = resultType, arguments = keyedArguments} = resultType : map (^. #argumentType) keyedArguments

safeSqlIdentifier :: Text -> Bool
safeSqlIdentifier value =
  case Text.uncons value of
    Nothing -> False
    Just (first, rest) ->
      lower first && Text.all (\character -> lower character || digit character || character == '_') rest
  where
    lower character = character >= 'a' && character <= 'z'
    digit character = character >= '0' && character <= '9'

safeQualifiedType :: QualifiedSqlType -> Bool
safeQualifiedType sqlType =
  safeSqlIdentifier (sqlType ^. #typeSchema)
    && safeSqlIdentifier (sqlType ^. #typeName)

renderQualifiedType :: QualifiedSqlType -> Text
renderQualifiedType sqlType = sqlType ^. #typeSchema <> "." <> sqlType ^. #typeName

renderQualifiedFunction :: QualifiedFunction -> Text
renderQualifiedFunction function = function ^. #functionSchema <> "." <> function ^. #functionName

externalReadImmutableSignature :: ExternalReadContract -> Preimage
externalReadImmutableSignature contract =
  PRecord
    "external-read-immutable-signature"
    [ PText (externalReadFunctionName contract),
      PText (queryModelIdText (contract ^. #queryModelId)),
      PText (contract ^. #resultShapeHash),
      qualifiedSqlTypePreimage (contract ^. #resultContractType),
      case contract of
        AllRowsExternalRead {} -> PRecord "all-rows" []
        KeyedExternalRead {arguments = keyedArguments} ->
          PRecord
            "keyed"
            [PList (sqlFunctionArgumentPreimage <$> keyedArguments)]
    ]

revisionRequirements :: ProjectionRevision -> [(Text, [TargetId])]
revisionRequirements revision =
  [ (adapter ^. #adapterId, adapter ^. #requiredTargets)
  | adapter <- revision ^. #replayAdapters
  ]
    <> [ (verification ^. #revisionVerificationId, verification ^. #requiredTargets)
       | verification <- revision ^. #revisionVerifications
       ]

revisionIdentities :: ProjectionRevision -> [(Text, Int)]
revisionIdentities revision =
  [ (projectionRevisionIdText (revision ^. #revisionId), 1)
  ]
    <> [ (provisioner ^. #provisionerId, provisioner ^. #provisionerVersion)
       | provisioner <- Map.elems (revision ^. #targetProvisioners)
       ]
    <> [ (targetSchemaVersionText (provisioner ^. #schemaVersion), 1)
       | provisioner <- Map.elems (revision ^. #targetProvisioners)
       ]
    <> [ (provisioner ^. #expectedShapeId, 1)
       | provisioner <- Map.elems (revision ^. #targetProvisioners)
       ]
    <> [ (provisioner ^. #validatorId, provisioner ^. #validatorVersion)
       | provisioner <- Map.elems (revision ^. #targetProvisioners)
       ]
    <> [ (name, 1)
       | provisioner <- Map.elems (revision ^. #targetProvisioners),
         promotionObject <- provisioner ^. #promotionObjectNames,
         name <- [promotionObject ^. #generationName, promotionObject ^. #canonicalName]
       ]
    <> [ (handler ^. #handlerId, handler ^. #handlerVersion)
       | handler <- revision ^. #liveHandlers
       ]
    <> [ (adapter ^. #adapterId, adapter ^. #adapterVersion)
       | adapter <- revision ^. #replayAdapters
       ]
    <> [ (verification ^. #revisionVerificationId, verification ^. #revisionVerificationVersion)
       | verification <- revision ^. #revisionVerifications
       ]

collectProjectionFacts :: [SomeProjectionSet] -> [ProjectionFacts]
collectProjectionFacts projectionSetEntries =
  [ ProjectionFacts
      { factProjectionId = definition ^. #projectionId,
        factSourceId = projectionSet ^. #projectionSource,
        factGroupId = definition ^. #rebuildGroup,
        factTargets = NonEmpty.toList (definition ^. #ownedTargets),
        factReplayable = case definition ^. #replayPolicy of
          Replayable _ -> True
          LiveOnly _ -> False,
        factHandlers = map handlerFacts (NonEmpty.toList (definition ^. #handlers)),
        factSite = definition ^. #claimSite
      }
  | SomeProjectionSet projectionSet <- projectionSetEntries,
    definition <- NonEmpty.toList (projectionSet ^. #projectionDefinitions)
  ]

handlerFacts :: ProjectionHandler event -> HandlerFacts
handlerFacts (InlineHandler projection site) =
  InlineFacts (projection ^. #name) site
handlerFacts (AsyncHandler projection subscriptionId dedupId site) =
  AsyncFacts
    (projection ^. #name)
    (projection ^. #readModelName)
    (projection ^. #subscriptionName)
    subscriptionId
    dedupId
    site

collectQueryFacts :: [SomeQueryModelBinding] -> [QueryFacts]
collectQueryFacts bindings =
  [ QueryFacts
      { factQueryModelId = binding ^. #queryModelId,
        factRegistryName = model ^. #name,
        factVersion = model ^. #version,
        factShapeHash = model ^. #shapeHash,
        factQueryGroup = binding ^. #rebuildGroup,
        factObservedTargets = binding ^. #observedTargets,
        factQueryFreshness = readModelDefaultFreshness model,
        factQuerySite = binding ^. #claimSite
      }
  | SomeQueryModelBinding binding <- bindings,
    let model = binding ^. #readModel
  ]

buildInventory :: ProjectionCatalog -> [ProjectionFacts] -> [QueryFacts] -> CatalogInventory
buildInventory catalog facts queryFacts =
  CatalogInventory
    { inventorySources =
        List.sort
          [ InventorySource (source ^. #sourceId) (source ^. #sourceScope) (source ^. #codecFingerprint)
          | source <- catalog ^. #sources
          ],
      inventoryTargets =
        List.sort
          [ InventoryTarget
              { targetId = target ^. #targetId,
                qualifiedTable = target ^. #qualifiedTable,
                resetPolicy = target ^. #resetPolicy,
                dependsOn = List.sort (target ^. #dependsOn),
                owner = ownerOf (target ^. #targetId)
              }
          | target <- catalog ^. #targets
          ],
      inventoryGroups =
        List.sort
          [ InventoryGroup
              { rebuildGroupId = group ^. #rebuildGroupId,
                orderedTargets = group ^. #orderedTargets,
                verifications =
                  [ (hook ^. #verificationId, hook ^. #verificationVersion)
                  | hook <- group ^. #verificationHooks
                  ]
              }
          | group <- catalog ^. #rebuildGroups
          ],
      inventoryProjections = List.sort (map inventoryProjection facts),
      inventoryProjectionRevisions =
        List.sort (map inventoryProjectionRevision (catalog ^. #projectionRevisions)),
      inventoryExternalReadContracts =
        List.sort
          [ inventoryExternalReadContract (factQueryGroup query) contract
          | contract <- catalog ^. #externalReadContracts,
            let query =
                  fromMaybe
                    (error "buildInventory: validated external read contract has no query model")
                    (List.find ((== contract ^. #queryModelId) . factQueryModelId) queryFacts)
          ],
      inventoryQueryModels =
        List.sort
          [ InventoryQueryModel
              { queryModelId = factQueryModelId query,
                registryName = factRegistryName query,
                version = factVersion query,
                shapeHash = factShapeHash query,
                rebuildGroupId = factQueryGroup query,
                observedTargets = List.sort (factObservedTargets query),
                freshness = inventoryQueryFreshness (factQueryFreshness query),
                cursor = resolvedInventoryCursor catalog owner (factQueryFreshness query)
              }
          | query <- queryFacts,
            let owner =
                  fromMaybe
                    (error "buildInventory: validated query has no projection owner")
                    (queryOwner facts query)
          ],
      inventorySubscriptions =
        List.sort
          [ InventorySubscription
              { subscriptionId = subscription ^. #subscriptionId,
                subscriptionName = subscription ^. #subscriptionName,
                sourceId = subscription ^. #subscriptionSource,
                checkpointOnMissing = subscription ^. #checkpointOnMissing
              }
          | subscription <- catalog ^. #subscriptions
          ],
      inventoryDedupKeys =
        List.sort
          [ InventoryDedupKey (key ^. #dedupKeyId) (key ^. #dedupName)
          | key <- catalog ^. #dedupKeys
          ]
    }
  where
    ownerOf targetId =
      case [factProjectionId fact | fact <- facts, targetId `List.elem` factTargets fact] of
        owner : _ -> owner
        [] -> error "buildInventory: validated target has no owner"

inventoryExternalReadContract :: RebuildGroupId -> ExternalReadContract -> InventoryExternalReadContract
inventoryExternalReadContract groupId contract =
  InventoryExternalReadContract
    { readContractId = contract ^. #readContractId,
      contractVersion = contract ^. #contractVersion,
      queryModelId = contract ^. #queryModelId,
      rebuildGroupId = groupId,
      functionName = externalReadFunctionName contract,
      contractKind = case contract of
        AllRowsExternalRead {} -> InventoryAllRowsExternalRead
        KeyedExternalRead {} -> InventoryKeyedExternalRead,
      arguments = case contract of
        AllRowsExternalRead {} -> []
        KeyedExternalRead {arguments = keyedArguments} -> keyedArguments,
      resultContractType = contract ^. #resultContractType,
      privateImplementation = case contract of
        AllRowsExternalRead {} -> Nothing
        KeyedExternalRead {privateImplementation = implementation} -> Just implementation,
      privateImplementationVersion = case contract of
        AllRowsExternalRead {} -> Nothing
        KeyedExternalRead {privateImplementationVersion = implementationVersion} -> Just implementationVersion,
      resultShapeHash = contract ^. #resultShapeHash,
      compatibleRevisions =
        NonEmpty.fromList (List.sort (NonEmpty.toList (contract ^. #compatibleRevisions))),
      surfaceGeneration = contract ^. #surfaceGeneration
    }

buildResolvedQuerySupplies :: CatalogInventory -> [ResolvedQuerySupply]
buildResolvedQuerySupplies inventory =
  List.sortOn
    (^. #resolvedQueryModelId)
    [ ResolvedQuerySupply
        { resolvedQueryModelId = query ^. #queryModelId,
          resolvedProjectionId = ownerId,
          resolvedRebuildGroupId = query ^. #rebuildGroupId,
          resolvedObservedTargets = requireNonEmpty "query observed targets" (query ^. #observedTargets),
          resolvedSourceId = projection ^. #sourceId,
          resolvedHandlerCapabilities =
            requireNonEmpty
              "projection handler capabilities"
              (map (handlerCapability projection) (projection ^. #handlers)),
          resolvedQueryFreshness = query ^. #freshness,
          resolvedQueryCursor = query ^. #cursor
        }
    | query <- inventory ^. #inventoryQueryModels,
      let ownerId = ownerForQuery query,
      let projection = requireLookup "query projection owner" ownerId projectionById
    ]
  where
    ownerByTarget =
      Map.fromList
        [ (target ^. #targetId, target ^. #owner)
        | target <- inventory ^. #inventoryTargets
        ]
    projectionById =
      Map.fromList
        [ (projection ^. #projectionId, projection)
        | projection <- inventory ^. #inventoryProjections
        ]
    subscriptionById =
      Map.fromList
        [ (subscription ^. #subscriptionId, subscription)
        | subscription <- inventory ^. #inventorySubscriptions
        ]
    dedupById =
      Map.fromList
        [ (dedupKey ^. #dedupKeyId, dedupKey)
        | dedupKey <- inventory ^. #inventoryDedupKeys
        ]

    ownerForQuery query =
      case Set.toList . Set.fromList $ map ownerForTarget (query ^. #observedTargets) of
        [ownerId] -> ownerId
        _ -> error "buildResolvedQuerySupplies: validated query does not have one owner"

    ownerForTarget targetId = requireLookup "observed target owner" targetId ownerByTarget

    handlerCapability projection = \case
      InventoryInlineHandler name ->
        InlineCapability
          { capabilityHandlerName = name
          }
      InventoryAsyncHandler name subscriptionId dedupKeyId ->
        let subscription = requireLookup "handler subscription" subscriptionId subscriptionById
            dedupKey = requireLookup "handler dedup key" dedupKeyId dedupById
         in SubscriptionCapability
              { capabilityHandlerName = name,
                capabilitySubscriptionId = subscriptionId,
                capabilitySubscriptionName = subscription ^. #subscriptionName,
                capabilitySourceId = projection ^. #sourceId,
                capabilityCheckpointOnMissing = subscription ^. #checkpointOnMissing,
                capabilityDedupKeyId = dedupKeyId,
                capabilityDedupName = dedupKey ^. #dedupName
              }

    requireLookup label key values =
      fromMaybe
        (error ("buildResolvedQuerySupplies: missing " <> label))
        (Map.lookup key values)

    requireNonEmpty label values =
      fromMaybe
        (error ("buildResolvedQuerySupplies: empty " <> label))
        (NonEmpty.nonEmpty values)

inventoryQueryFreshness :: QueryFreshness -> InventoryQueryFreshness
inventoryQueryFreshness Immediate = InventoryImmediate
inventoryQueryFreshness (WaitForHead scope) = InventoryWaitForHead scope
inventoryQueryFreshness WaitForPosition {} = InventoryWaitForPosition

resolvedInventoryCursor ::
  ProjectionCatalog ->
  ProjectionFacts ->
  QueryFreshness ->
  Maybe InventoryQueryCursor
resolvedInventoryCursor catalog owner freshness =
  case compatibleQueryCursors freshness (queryCursorCandidates catalog owner) of
    [QueryCursorCandidate subscriptionId name _ _] ->
      Just
        InventoryQueryCursor
          { subscriptionId = subscriptionId,
            subscriptionName = name
          }
    _ -> Nothing

inventoryProjection :: ProjectionFacts -> InventoryProjection
inventoryProjection fact =
  InventoryProjection
    { projectionId = factProjectionId fact,
      sourceId = factSourceId fact,
      rebuildGroupId = factGroupId fact,
      ownedTargets = List.sort (factTargets fact),
      replayDisposition = if factReplayable fact then "replayable" else "live-only",
      handlers = map inventoryHandler (factHandlers fact)
    }

inventoryHandler :: HandlerFacts -> InventoryHandler
inventoryHandler (InlineFacts name _) = InventoryInlineHandler name
inventoryHandler (AsyncFacts name _ _ subscriptionId dedupId _) =
  InventoryAsyncHandler name subscriptionId dedupId

inventoryProjectionRevision :: ProjectionRevision -> InventoryProjectionRevision
inventoryProjectionRevision revision =
  InventoryProjectionRevision
    { revisionId = revision ^. #revisionId,
      rebuildGroupId = revision ^. #rebuildGroup,
      targetProvisioners =
        [ InventoryTargetProvisioner
            { targetId = targetId,
              provisionerId = provisioner ^. #provisionerId,
              provisionerVersion = provisioner ^. #provisionerVersion,
              schemaVersion = provisioner ^. #schemaVersion,
              expectedShapeId = provisioner ^. #expectedShapeId,
              validatorId = provisioner ^. #validatorId,
              validatorVersion = provisioner ^. #validatorVersion,
              promotionObjectNames = provisioner ^. #promotionObjectNames
            }
        | (targetId, provisioner) <- Map.toAscList (revision ^. #targetProvisioners)
        ],
      liveHandlers =
        [ InventoryRevisionHandler
            (handler ^. #handlerId)
            (handler ^. #handlerVersion)
            (Just (handler ^. #delivery))
            (List.sort (handler ^. #requiredTargets))
        | handler <- revision ^. #liveHandlers
        ],
      replayAdapters =
        [ InventoryRevisionHandler
            (adapter ^. #adapterId)
            (adapter ^. #adapterVersion)
            Nothing
            (List.sort (adapter ^. #requiredTargets))
        | adapter <- revision ^. #replayAdapters
        ],
      verifications =
        [ InventoryRevisionHandler
            (verification ^. #revisionVerificationId)
            (verification ^. #revisionVerificationVersion)
            Nothing
            (List.sort (verification ^. #requiredTargets))
        | verification <- revision ^. #revisionVerifications
        ],
      streamScopedReplays =
        List.sort
          [ InventoryStreamScopedReplay
              { projectionId = policy ^. #streamProjectionId,
                ownedTargets = List.sort (NonEmpty.toList (policy ^. #streamOwnedTargets)),
                clearerId = policy ^. #clearerId,
                clearerVersion = policy ^. #clearerVersion,
                replayId = policy ^. #streamReplayId,
                replayVersion = policy ^. #streamReplayVersion,
                verificationId = policy ^. #streamVerificationId,
                verificationVersion = policy ^. #streamVerificationVersion,
                affectedAsyncDedup = List.sort (policy ^. #affectedAsyncDedup)
              }
          | policy <- revision ^. #streamScopedReplays
          ]
    }

fingerprintInventory :: CatalogInventory -> CatalogFingerprint
fingerprintInventory = CatalogFingerprint . hashPreimage "catalog-v7" . inventoryPreimage

inventoryPreimage :: CatalogInventory -> Preimage
inventoryPreimage inventory =
  PRecord
    "keiro/catalog-inventory/v7"
    [ PList (sourcePreimage <$> inventory ^. #inventorySources),
      PList (targetPreimage <$> inventory ^. #inventoryTargets),
      PList (groupPreimage <$> inventory ^. #inventoryGroups),
      PList (projectionPreimage <$> inventory ^. #inventoryProjections),
      PList (projectionRevisionPreimage <$> inventory ^. #inventoryProjectionRevisions),
      PList (externalReadContractPreimage <$> inventory ^. #inventoryExternalReadContracts),
      PList (queryPreimage <$> inventory ^. #inventoryQueryModels),
      PList (subscriptionPreimage <$> inventory ^. #inventorySubscriptions),
      PList (dedupPreimage <$> inventory ^. #inventoryDedupKeys)
    ]

sourcePreimage :: InventorySource -> Preimage
sourcePreimage source =
  PRecord
    "source"
    [ PText (sourceIdText (source ^. #sourceId)),
      PText (renderScope (source ^. #sourceScope)),
      PText (source ^. #codecFingerprint)
    ]

targetPreimage :: InventoryTarget -> Preimage
targetPreimage target =
  PRecord
    "target"
    [ PText (targetIdText (target ^. #targetId)),
      PText (target ^. #qualifiedTable . #schemaName),
      PText (target ^. #qualifiedTable . #tableName),
      PText (renderReset (target ^. #resetPolicy)),
      PList (PText . targetIdText <$> target ^. #dependsOn),
      PText (projectionIdText (target ^. #owner))
    ]

groupPreimage :: InventoryGroup -> Preimage
groupPreimage group =
  PRecord
    "group"
    [ PText (rebuildGroupIdText (group ^. #rebuildGroupId)),
      PList (PText . targetIdText <$> group ^. #orderedTargets),
      PList
        [ PRecord "verification" [PText verificationId, PText verificationVersion]
        | (verificationId, verificationVersion) <- group ^. #verifications
        ]
    ]

projectionPreimage :: InventoryProjection -> Preimage
projectionPreimage projection =
  PRecord
    "projection"
    [ PText (projectionIdText (projection ^. #projectionId)),
      PText (sourceIdText (projection ^. #sourceId)),
      PText (rebuildGroupIdText (projection ^. #rebuildGroupId)),
      PList (PText . targetIdText <$> projection ^. #ownedTargets),
      PText (projection ^. #replayDisposition),
      PList (handlerPreimage <$> projection ^. #handlers)
    ]

projectionRevisionPreimage :: InventoryProjectionRevision -> Preimage
projectionRevisionPreimage revision =
  PRecord
    "projection-revision"
    [ PText (projectionRevisionIdText (revision ^. #revisionId)),
      PText (rebuildGroupIdText (revision ^. #rebuildGroupId)),
      PList (targetProvisionerPreimage <$> revision ^. #targetProvisioners),
      PList (revisionHandlerPreimage "live-handler" <$> revision ^. #liveHandlers),
      PList (revisionHandlerPreimage "replay-adapter" <$> revision ^. #replayAdapters),
      PList (revisionHandlerPreimage "revision-verification" <$> revision ^. #verifications),
      PList (streamScopedReplayPreimage <$> revision ^. #streamScopedReplays)
    ]

streamScopedReplayPreimage :: InventoryStreamScopedReplay -> Preimage
streamScopedReplayPreimage policy =
  PRecord
    "stream-scoped-replay"
    [ PText (projectionIdText (policy ^. #projectionId)),
      PList (PText . targetIdText <$> policy ^. #ownedTargets),
      PText (policy ^. #clearerId),
      PText (Text.pack (show (policy ^. #clearerVersion))),
      PText (policy ^. #replayId),
      PText (Text.pack (show (policy ^. #replayVersion))),
      PText (policy ^. #verificationId),
      PText (Text.pack (show (policy ^. #verificationVersion))),
      PList (PText . dedupKeyIdText <$> policy ^. #affectedAsyncDedup)
    ]

targetProvisionerPreimage :: InventoryTargetProvisioner -> Preimage
targetProvisionerPreimage provisioner =
  PRecord
    "target-provisioner"
    [ PText (targetIdText (provisioner ^. #targetId)),
      PText (provisioner ^. #provisionerId),
      PText (Text.pack (show (provisioner ^. #provisionerVersion))),
      PText (targetSchemaVersionText (provisioner ^. #schemaVersion)),
      PText (provisioner ^. #expectedShapeId),
      PText (provisioner ^. #validatorId),
      PText (Text.pack (show (provisioner ^. #validatorVersion))),
      PList (promotionObjectPreimage <$> provisioner ^. #promotionObjectNames)
    ]

promotionObjectPreimage :: PromotionObjectName -> Preimage
promotionObjectPreimage object =
  PRecord
    "promotion-object"
    [ PText (promotionObjectKindText (object ^. #objectKind)),
      PText (object ^. #generationName),
      PText (object ^. #canonicalName)
    ]

revisionHandlerPreimage :: Text -> InventoryRevisionHandler -> Preimage
revisionHandlerPreimage tag handler =
  PRecord
    tag
    [ PText (handler ^. #handlerId),
      PText (Text.pack (show (handler ^. #handlerVersion))),
      maybe (PRecord "no-delivery" []) revisionLiveDeliveryPreimage (handler ^. #delivery),
      PList (PText . targetIdText <$> handler ^. #requiredTargets)
    ]

revisionLiveDeliveryPreimage :: RevisionLiveDelivery -> Preimage
revisionLiveDeliveryPreimage = \case
  RevisionInlineDelivery projectionId handlerName ->
    PRecord
      "inline-delivery"
      [PText (projectionIdText projectionId), PText handlerName]
  RevisionSubscriptionDelivery projectionId subscriptionId dedupId ->
    PRecord
      "subscription-delivery"
      [ PText (projectionIdText projectionId),
        PText (subscriptionIdText subscriptionId),
        PText (dedupKeyIdText dedupId)
      ]

externalReadContractPreimage :: InventoryExternalReadContract -> Preimage
externalReadContractPreimage contract =
  PRecord
    "external-read-contract"
    [ PText (externalReadContractIdText (contract ^. #readContractId)),
      PText (Text.pack (show (externalReadContractVersionValue (contract ^. #contractVersion)))),
      PText (queryModelIdText (contract ^. #queryModelId)),
      PText (rebuildGroupIdText (contract ^. #rebuildGroupId)),
      PText (contract ^. #functionName),
      PText
        ( case contract ^. #contractKind of
            InventoryAllRowsExternalRead -> "all-rows"
            InventoryKeyedExternalRead -> "keyed"
        ),
      PList (sqlFunctionArgumentPreimage <$> contract ^. #arguments),
      qualifiedSqlTypePreimage (contract ^. #resultContractType),
      maybe (PRecord "no-private-implementation" []) qualifiedFunctionPreimage (contract ^. #privateImplementation),
      maybe (PRecord "no-private-implementation-version" []) (PText . Text.pack . show) (contract ^. #privateImplementationVersion),
      PText (contract ^. #resultShapeHash),
      PList
        ( PText . projectionRevisionIdText
            <$> NonEmpty.toList (contract ^. #compatibleRevisions)
        ),
      PText (Text.pack (show (contract ^. #surfaceGeneration)))
    ]

sqlFunctionArgumentPreimage :: SqlFunctionArgument -> Preimage
sqlFunctionArgumentPreimage argument =
  PRecord
    "sql-function-argument"
    [ PText (argument ^. #argumentName),
      qualifiedSqlTypePreimage (argument ^. #argumentType)
    ]

qualifiedSqlTypePreimage :: QualifiedSqlType -> Preimage
qualifiedSqlTypePreimage sqlType =
  PRecord "qualified-sql-type" [PText (sqlType ^. #typeSchema), PText (sqlType ^. #typeName)]

qualifiedFunctionPreimage :: QualifiedFunction -> Preimage
qualifiedFunctionPreimage function =
  PRecord "qualified-function" [PText (function ^. #functionSchema), PText (function ^. #functionName)]

handlerPreimage :: InventoryHandler -> Preimage
handlerPreimage = \case
  InventoryInlineHandler name -> PRecord "inline" [PText name]
  InventoryAsyncHandler name subscriptionId dedupId ->
    PRecord
      "async"
      [ PText name,
        PText (subscriptionIdText subscriptionId),
        PText (dedupKeyIdText dedupId)
      ]

queryPreimage :: InventoryQueryModel -> Preimage
queryPreimage query =
  PRecord
    "query"
    [ PText (queryModelIdText (query ^. #queryModelId)),
      PText (query ^. #registryName),
      PText (Text.pack (show (query ^. #version))),
      PText (query ^. #shapeHash),
      PText (rebuildGroupIdText (query ^. #rebuildGroupId)),
      PList (PText . targetIdText <$> query ^. #observedTargets),
      inventoryFreshnessPreimage (query ^. #freshness),
      maybe (PRecord "no-cursor" []) inventoryCursorPreimage (query ^. #cursor)
    ]

inventoryFreshnessPreimage :: InventoryQueryFreshness -> Preimage
inventoryFreshnessPreimage InventoryImmediate = PRecord "immediate" []
inventoryFreshnessPreimage (InventoryWaitForHead scope) =
  PRecord "wait-for-head" [PText (headScopeText scope)]
inventoryFreshnessPreimage InventoryWaitForPosition = PRecord "wait-for-position" []

inventoryCursorPreimage :: InventoryQueryCursor -> Preimage
inventoryCursorPreimage queryCursor =
  PRecord
    "durable-cursor"
    [ PText (subscriptionIdText (queryCursor ^. #subscriptionId)),
      PText (queryCursor ^. #subscriptionName)
    ]

subscriptionPreimage :: InventorySubscription -> Preimage
subscriptionPreimage subscription =
  PRecord
    "subscription"
    [ PText (subscriptionIdText (subscription ^. #subscriptionId)),
      PText (subscription ^. #subscriptionName),
      PText (sourceIdText (subscription ^. #sourceId)),
      PText (missingCheckpointPolicyText (subscription ^. #checkpointOnMissing))
    ]

dedupPreimage :: InventoryDedupKey -> Preimage
dedupPreimage key =
  PRecord
    "dedup"
    [ PText (dedupKeyIdText (key ^. #dedupKeyId)),
      PText (key ^. #dedupName)
    ]

-- | Render the inventory for operators. This human-readable text is not the
-- fingerprint preimage; identity uses the canonical tree encoding above.
renderInventory :: CatalogInventory -> Text
renderInventory inventory =
  Text.unlines
    ( map renderSource (inventory ^. #inventorySources)
        <> map renderTarget (inventory ^. #inventoryTargets)
        <> map renderGroup (inventory ^. #inventoryGroups)
        <> map renderProjection (inventory ^. #inventoryProjections)
        <> map renderProjectionRevision (inventory ^. #inventoryProjectionRevisions)
        <> map renderExternalReadContract (inventory ^. #inventoryExternalReadContracts)
        <> map renderQuery (inventory ^. #inventoryQueryModels)
        <> map renderSubscription (inventory ^. #inventorySubscriptions)
        <> map renderDedup (inventory ^. #inventoryDedupKeys)
    )
  where
    renderSource :: InventorySource -> Text
    renderSource source =
      Text.intercalate
        "|"
        [ "source",
          sourceIdText (source ^. #sourceId),
          renderScope (source ^. #sourceScope),
          source ^. #codecFingerprint
        ]
    renderTarget :: InventoryTarget -> Text
    renderTarget target =
      Text.intercalate
        "|"
        [ "target",
          targetIdText (target ^. #targetId),
          target ^. (#qualifiedTable . #schemaName),
          target ^. (#qualifiedTable . #tableName),
          renderReset (target ^. #resetPolicy),
          commaSeparated targetIdText (target ^. #dependsOn),
          projectionIdText (target ^. #owner)
        ]
    renderGroup :: InventoryGroup -> Text
    renderGroup group =
      Text.intercalate
        "|"
        [ "group",
          rebuildGroupIdText (group ^. #rebuildGroupId),
          commaSeparated targetIdText (group ^. #orderedTargets),
          Text.intercalate
            ","
            [ verificationId <> "@" <> verificationVersion
            | (verificationId, verificationVersion) <- group ^. #verifications
            ]
        ]
    renderProjection :: InventoryProjection -> Text
    renderProjection projection =
      Text.intercalate
        "|"
        [ "projection",
          projectionIdText (projection ^. #projectionId),
          sourceIdText (projection ^. #sourceId),
          rebuildGroupIdText (projection ^. #rebuildGroupId),
          commaSeparated targetIdText (projection ^. #ownedTargets),
          projection ^. #replayDisposition,
          Text.intercalate "," (map renderHandler (projection ^. #handlers))
        ]
    renderProjectionRevision :: InventoryProjectionRevision -> Text
    renderProjectionRevision revision =
      Text.intercalate
        "|"
        [ "projection-revision",
          projectionRevisionIdText (revision ^. #revisionId),
          rebuildGroupIdText (revision ^. #rebuildGroupId),
          Text.intercalate "," (map renderTargetProvisioner (revision ^. #targetProvisioners)),
          Text.intercalate "," (map (renderRevisionHandler "live") (revision ^. #liveHandlers)),
          Text.intercalate "," (map (renderRevisionHandler "replay") (revision ^. #replayAdapters)),
          Text.intercalate "," (map (renderRevisionHandler "verify") (revision ^. #verifications))
        ]
    renderExternalReadContract :: InventoryExternalReadContract -> Text
    renderExternalReadContract contract =
      Text.intercalate
        "|"
        [ "external-read-contract",
          externalReadContractIdText (contract ^. #readContractId),
          Text.pack (show (externalReadContractVersionValue (contract ^. #contractVersion))),
          queryModelIdText (contract ^. #queryModelId),
          rebuildGroupIdText (contract ^. #rebuildGroupId),
          contract ^. #functionName,
          case contract ^. #contractKind of
            InventoryAllRowsExternalRead -> "all-rows"
            InventoryKeyedExternalRead -> "keyed",
          Text.intercalate "," (map renderArgument (contract ^. #arguments)),
          renderQualifiedType (contract ^. #resultContractType),
          maybe "-" renderQualifiedFunction (contract ^. #privateImplementation),
          maybe "-" (Text.pack . show) (contract ^. #privateImplementationVersion),
          contract ^. #resultShapeHash,
          Text.intercalate
            ","
            (map projectionRevisionIdText (NonEmpty.toList (contract ^. #compatibleRevisions))),
          Text.pack (show (contract ^. #surfaceGeneration))
        ]
    renderArgument :: SqlFunctionArgument -> Text
    renderArgument argument = argument ^. #argumentName <> ":" <> renderQualifiedType (argument ^. #argumentType)
    renderQuery :: InventoryQueryModel -> Text
    renderQuery query =
      Text.intercalate
        "|"
        [ "query",
          queryModelIdText (query ^. #queryModelId),
          query ^. #registryName,
          Text.pack (show (query ^. #version)),
          query ^. #shapeHash,
          rebuildGroupIdText (query ^. #rebuildGroupId),
          commaSeparated targetIdText (query ^. #observedTargets),
          renderInventoryFreshness (query ^. #freshness),
          maybe "no-cursor" renderInventoryCursor (query ^. #cursor)
        ]
    renderSubscription :: InventorySubscription -> Text
    renderSubscription subscription =
      Text.intercalate
        "|"
        [ "subscription",
          subscriptionIdText (subscription ^. #subscriptionId),
          subscription ^. #subscriptionName,
          sourceIdText (subscription ^. #sourceId),
          missingCheckpointPolicyText (subscription ^. #checkpointOnMissing)
        ]
    renderDedup :: InventoryDedupKey -> Text
    renderDedup key =
      Text.intercalate
        "|"
        ["dedup", dedupKeyIdText (key ^. #dedupKeyId), key ^. #dedupName]

renderInventoryFreshness :: InventoryQueryFreshness -> Text
renderInventoryFreshness InventoryImmediate = "immediate"
renderInventoryFreshness (InventoryWaitForHead scope) =
  "wait-for-head:" <> headScopeText scope
renderInventoryFreshness InventoryWaitForPosition = "wait-for-position"

renderInventoryCursor :: InventoryQueryCursor -> Text
renderInventoryCursor queryCursor =
  "cursor:"
    <> subscriptionIdText (queryCursor ^. #subscriptionId)
    <> "/"
    <> queryCursor ^. #subscriptionName

renderScope :: SourceScope -> Text
renderScope AllStreams = "$all"
renderScope (CategorySource (CategoryName category)) = "category:" <> category

renderReset :: TargetResetPolicy -> Text
renderReset ClearBeforeReplay = "clear-before-replay"
renderReset PreserveAndReconcile = "preserve-and-reconcile"

renderQualifiedTable :: QualifiedTable -> Text
renderQualifiedTable table = table ^. #schemaName <> "." <> table ^. #tableName

renderHandler :: InventoryHandler -> Text
renderHandler (InventoryInlineHandler name) = "inline:" <> name
renderHandler (InventoryAsyncHandler name subscriptionId dedupId) =
  Text.intercalate ":" ["async", name, subscriptionIdText subscriptionId, dedupKeyIdText dedupId]

renderTargetProvisioner :: InventoryTargetProvisioner -> Text
renderTargetProvisioner provisioner =
  Text.intercalate
    "@"
    [ targetIdText (provisioner ^. #targetId),
      provisioner ^. #provisionerId <> ":" <> Text.pack (show (provisioner ^. #provisionerVersion)),
      targetSchemaVersionText (provisioner ^. #schemaVersion),
      provisioner ^. #expectedShapeId,
      provisioner ^. #validatorId <> ":" <> Text.pack (show (provisioner ^. #validatorVersion)),
      Text.intercalate ";" (map renderPromotionObject (provisioner ^. #promotionObjectNames))
    ]

renderRevisionHandler :: Text -> InventoryRevisionHandler -> Text
renderRevisionHandler kind handler =
  Text.intercalate
    ":"
    [ kind,
      handler ^. #handlerId,
      Text.pack (show (handler ^. #handlerVersion)),
      maybe "-" renderRevisionLiveDelivery (handler ^. #delivery),
      commaSeparated targetIdText (handler ^. #requiredTargets)
    ]

renderRevisionLiveDelivery :: RevisionLiveDelivery -> Text
renderRevisionLiveDelivery = \case
  RevisionInlineDelivery projectionId handlerName ->
    Text.intercalate "/" ["inline", projectionIdText projectionId, handlerName]
  RevisionSubscriptionDelivery projectionId subscriptionId dedupId ->
    Text.intercalate
      "/"
      [ "subscription",
        projectionIdText projectionId,
        subscriptionIdText subscriptionId,
        dedupKeyIdText dedupId
      ]

renderPromotionObject :: PromotionObjectName -> Text
renderPromotionObject object =
  Text.intercalate
    ":"
    [ promotionObjectKindText (object ^. #objectKind),
      object ^. #generationName,
      object ^. #canonicalName
    ]

promotionObjectKindText :: PromotionObjectKind -> Text
promotionObjectKindText PromotionIndex = "index"
promotionObjectKindText PromotionConstraint = "constraint"
promotionObjectKindText PromotionOwnedSequence = "owned-sequence"

targetSchemaVersionText :: TargetSchemaVersion -> Text
targetSchemaVersionText (TargetSchemaVersion value) = value

commaSeparated :: (value -> Text) -> [value] -> Text
commaSeparated render = Text.intercalate "," . map render

diagnostic :: CatalogDiagnosticCode -> Text -> [ClaimSite] -> Text -> CatalogDiagnostic
diagnostic code identity sites message =
  CatalogDiagnostic
    { diagnosticCode = code,
      diagnosticIdentity = identity,
      diagnosticSites = List.sort (List.nub sites),
      diagnosticMessage = message
    }

duplicates :: (Ord value) => [value] -> [value]
duplicates =
  map NonEmpty.head
    . filter ((> 1) . NonEmpty.length)
    . NonEmpty.group
    . List.sort

newtype UnmanagedInlineProjections event
  = UnmanagedInlineProjections [InlineProjection event]

-- | Mark an existing hand-maintained inline list as outside catalog validation.
unmanagedInlineProjections :: [InlineProjection event] -> UnmanagedInlineProjections event
unmanagedInlineProjections = UnmanagedInlineProjections

getUnmanagedInlineProjections :: UnmanagedInlineProjections event -> [InlineProjection event]
getUnmanagedInlineProjections (UnmanagedInlineProjections projections) = projections

newtype UnmanagedAsyncProjection
  = UnmanagedAsyncProjection AsyncProjection

-- | Mark a legacy async projection as outside catalog validation.
unmanagedAsyncProjection :: AsyncProjection -> UnmanagedAsyncProjection
unmanagedAsyncProjection = UnmanagedAsyncProjection

getUnmanagedAsyncProjection :: UnmanagedAsyncProjection -> AsyncProjection
getUnmanagedAsyncProjection (UnmanagedAsyncProjection projection) = projection

newtype UnmanagedReadModel q r
  = UnmanagedReadModel (ReadModel q r)

-- | Mark a legacy read model as outside catalog validation.
unmanagedReadModel :: ReadModel q r -> UnmanagedReadModel q r
unmanagedReadModel = UnmanagedReadModel

getUnmanagedReadModel :: UnmanagedReadModel q r -> ReadModel q r
getUnmanagedReadModel (UnmanagedReadModel model) = model
