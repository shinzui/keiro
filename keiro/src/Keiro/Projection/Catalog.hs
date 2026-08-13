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
    ClaimSite,
    CatalogIdentityError (..),
    mkProjectionId,
    mkTargetId,
    mkRebuildGroupId,
    mkSourceId,
    mkQueryModelId,
    mkSubscriptionId,
    mkDedupKeyId,
    mkClaimSite,
    projectionIdText,
    targetIdText,
    rebuildGroupIdText,
    sourceIdText,
    queryModelIdText,
    subscriptionIdText,
    dedupKeyIdText,
    claimSiteText,

    -- * Declarations
    QualifiedTable (..),
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
    typedProjectionRebuildGroups,
    asyncProjectionRebuildGroup,
    resolvedQuerySupplies,
    catalogInventory,
    catalogFingerprint,
    groupSliceFingerprint,
    catalogRegistrations,
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
import Kiroku.Store.Types (CategoryName (..), EventId, RecordedEvent)

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
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

diagnosticCodeText :: CatalogDiagnosticCode -> Text
diagnosticCodeText = \case
  DuplicateProjectionId -> "catalog.duplicate-projection-id"
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
  { specSubscriptionName :: !Text,
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
    . hashPreimage "slice-v2"
    $ PRecord
      "keiro/catalog-group-slice/v2"
      [ PText (rebuildGroupIdText wantedGroup),
        groupPreimage group,
        PList (targetPreimage <$> targets),
        PList (projectionPreimage <$> projections),
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
          { specSubscriptionName = subscriptionNameFor subscriptionId,
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
    <> duplicateBy DuplicateQueryModelId queryModelIdText factQueryModelId factQuerySite queryFacts
    <> duplicateBy DuplicateQueryModelRegistryName (\value -> value) factRegistryName factQuerySite queryFacts
    <> concatMap duplicateTargetsInGroup (catalog ^. #rebuildGroups)

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

fingerprintInventory :: CatalogInventory -> CatalogFingerprint
fingerprintInventory = CatalogFingerprint . hashPreimage "catalog-v3" . inventoryPreimage

inventoryPreimage :: CatalogInventory -> Preimage
inventoryPreimage inventory =
  PRecord
    "keiro/catalog-inventory/v3"
    [ PList (sourcePreimage <$> inventory ^. #inventorySources),
      PList (targetPreimage <$> inventory ^. #inventoryTargets),
      PList (groupPreimage <$> inventory ^. #inventoryGroups),
      PList (projectionPreimage <$> inventory ^. #inventoryProjections),
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
