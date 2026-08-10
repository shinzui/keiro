{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Checked semantic dependency impact for mapped declarations.
--
-- This module answers which aggregates can consume a mapped declaration. It
-- does not classify wire compatibility and it does not claim that finite
-- conformance fixtures prove a consumer binding for all values. Both the roots
-- and transitive declaration edges come from a resolved 'TypeGraph', so callers
-- must not reconstruct this relation from a raw specification.
module Keiro.Dsl.SemanticImpact
  ( DerivedMappedConsumer (..),
    UnsupportedProjectionSource (..),
    MappedConsumer (..),
    MappedRootKind (..),
    MappedRoot (..),
    SemanticImpact (..),
    SemanticImpactSnapshot (..),
    MappedImpactDelta (..),
    SemanticImpactReport (..),
    semanticImpact,
    semanticImpactSnapshot,
    diffSemanticImpact,
    mappedImpactForDeclarations,
    semanticImpactReport,
    mappedConsumerIdentity,
    aggregateMappedRoots,
    aggregateMappedClosure,
    mappedDeclarationConsumers,
    serviceMappedInventory,
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar (HaskellSource (..), Name, WireEnum (..))
import Keiro.Dsl.TypeGraph

-- | A checked generated consumer of mapped declarations. Projection consumers
-- are derived from an aggregate event authority rather than owning another
-- source type expression.
data MappedConsumer
  = AggregateConsumer !Name
  | WorkqueueConsumer !Name
  | ReadModelConsumer !Name
  | DerivedProjectionConsumer !DerivedMappedConsumer
  deriving stock (Eq, Ord, Show, Generic)

-- | The complete candidate mapped root vocabulary. Snapshot impact follows
-- 'MappedRegisterRoot' because snapshots cache aggregate registers; the other
-- kinds are distinct consumer-build or persisted-queue surfaces.
data MappedRootKind
  = MappedCommandFieldRoot
  | MappedEventFieldRoot
  | MappedRegisterRoot
  | MappedWorkqueueFieldRoot
  | MappedReadModelQueryInputRoot
  | MappedReadModelQueryResultRoot
  | MappedProjectionEventRoot
  deriving stock (Eq, Ord, Show, Generic)

-- | One checked aggregate root before transitive declaration expansion.
data MappedRoot = MappedRoot
  { mappedRootConsumer :: !MappedConsumer,
    mappedRootKind :: !MappedRootKind,
    mappedRootUseSite :: !UseSite,
    mappedRootDeclaration :: !MappedKey
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | One deterministic dependency projection over a checked 'TypeGraph'.
--
-- 'impactAggregateDeclarations' contains the union of every root declaration
-- and everything transitively reachable from it for each aggregate.
-- 'impactDeclarationConsumers' contains every service declaration, mapping an
-- intentionally unused declaration to the empty set. The service inventory is
-- declaration ownership for conformance; it is not another aggregate consumer.
data SemanticImpact = SemanticImpact
  { impactRoots :: ![MappedRoot],
    impactUsePaths :: !(Map MappedKey [UsePath]),
    impactAggregateDeclarations :: !(Map MappedConsumer (Set MappedKey)),
    impactDeclarationConsumers :: !(Map MappedKey (Set MappedConsumer)),
    impactServiceDeclarations :: !(Set MappedKey),
    impactDeclarationIdentities :: !(Map MappedKey Text),
    impactUnsupportedProjectionSources :: ![UnsupportedProjectionSource]
  }
  deriving stock (Eq, Show, Generic)

-- | Durable, source-independent evidence for the mapped consumer graph and
-- declaration identities. The map contains every service declaration,
-- including declarations with no aggregate consumer. The explicit service
-- inventory makes the declaration ownership boundary visible and leaves room
-- for future non-aggregate roots.
data SemanticImpactSnapshot = SemanticImpactSnapshot
  { snapshotMappedConsumers :: !(Map MappedKey (Set MappedConsumer)),
    snapshotServiceInventory :: !(Set MappedKey),
    snapshotDeclarationIdentities :: !(Map MappedKey Text)
  }
  deriving stock (Eq, Show, Generic)

-- | One declaration's before/after consumer explanation. Compatibility and
-- generated-file writes deliberately remain outside this type.
data MappedImpactDelta = MappedImpactDelta
  { impactDeclaration :: !MappedKey,
    impactPreviousConsumers :: !(Set MappedConsumer),
    impactCurrentConsumers :: !(Set MappedConsumer),
    impactServiceConformance :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | Scaffold-facing evidence for the declarations whose mapping identities
-- changed. A missing previous snapshot means legacy history, not an empty old
-- graph; callers can still report the checked current consumers honestly.
data SemanticImpactReport = SemanticImpactReport
  { semanticReportPrevious :: !(Maybe SemanticImpactSnapshot),
    semanticReportCurrent :: !SemanticImpactSnapshot,
    semanticReportDeclarations :: ![MappedKey],
    semanticReportDeltas :: ![MappedImpactDelta]
  }
  deriving stock (Eq, Show, Generic)

-- JSON uses arrays rather than object keys so the on-disk representation does
-- not depend on aeson's map-key encoding. Parsers reject duplicate declaration
-- and consumer identities and require the two inventory projections to agree.
instance ToJSON SemanticImpactSnapshot where
  toJSON snapshot =
    object
      [ "declarations"
          .= [ object
                 [ "declaration" .= unMappedKey declaration,
                   "consumers" .= map mappedConsumerIdentity (Set.toAscList declarationConsumers),
                   "identity" .= Map.findWithDefault "" declaration (snapshotDeclarationIdentities snapshot)
                 ]
             | (declaration, declarationConsumers) <- Map.toAscList (snapshotMappedConsumers snapshot)
             ],
        "serviceInventory" .= map unMappedKey (Set.toAscList (snapshotServiceInventory snapshot))
      ]

instance FromJSON SemanticImpactSnapshot where
  parseJSON = withObject "SemanticImpactSnapshot" $ \fields -> do
    declarations <- fields .: "declarations" >>= traverse parseDeclaration
    inventoryNames <- fields .: "serviceInventory"
    let declarationNames = [declaration | (declaration, _, _) <- declarations]
        inventoryKeys = map MappedKey inventoryNames
        declarationMap = Map.fromList [(declaration, declarationConsumers) | (declaration, declarationConsumers, _) <- declarations]
        declarationIdentities = Map.fromList [(declaration, identity) | (declaration, _, identity) <- declarations]
        inventory = Set.fromList inventoryKeys
    unless (distinct declarationNames) (fail "duplicate semantic-impact declaration")
    unless (distinct inventoryKeys) (fail "duplicate semantic-impact service inventory declaration")
    unless (Map.keysSet declarationMap == inventory) (fail "semantic-impact declarations and service inventory differ")
    unless (Map.keysSet declarationIdentities == inventory) (fail "semantic-impact declaration identities and service inventory differ")
    pure
      SemanticImpactSnapshot
        { snapshotMappedConsumers = declarationMap,
          snapshotServiceInventory = inventory,
          snapshotDeclarationIdentities = declarationIdentities
        }
    where
      parseDeclaration = withObject "SemanticImpactDeclaration" $ \row -> do
        declarationName <- row .: "declaration"
        consumerNames <- row .: "consumers"
        identity <- row .: "identity"
        consumers <- traverse parseConsumerName consumerNames
        unless (distinct consumers) (fail "duplicate semantic-impact consumer")
        unless (not (T.null identity)) (fail "empty semantic-impact declaration identity")
        pure (MappedKey declarationName, Set.fromList consumers, identity)
      distinct values = length values == Set.size (Set.fromList values)

instance ToJSON MappedImpactDelta where
  toJSON delta =
    object
      [ "declaration" .= unMappedKey (impactDeclaration delta),
        "previousConsumers" .= map mappedConsumerIdentity (Set.toAscList (impactPreviousConsumers delta)),
        "currentConsumers" .= map mappedConsumerIdentity (Set.toAscList (impactCurrentConsumers delta)),
        "serviceConformance" .= impactServiceConformance delta
      ]

instance FromJSON MappedImpactDelta where
  parseJSON = withObject "MappedImpactDelta" $ \fields -> do
    declaration <- MappedKey <$> fields .: "declaration"
    previousNames <- fields .: "previousConsumers"
    currentNames <- fields .: "currentConsumers"
    serviceConformance <- fields .: "serviceConformance"
    previous <- traverse parseConsumerName previousNames
    current <- traverse parseConsumerName currentNames
    unless (distinct previous) (fail "duplicate previous semantic-impact consumer")
    unless (distinct current) (fail "duplicate current semantic-impact consumer")
    pure
      MappedImpactDelta
        { impactDeclaration = declaration,
          impactPreviousConsumers = Set.fromList previous,
          impactCurrentConsumers = Set.fromList current,
          impactServiceConformance = serviceConformance
        }
    where
      distinct values = length values == Set.size (Set.fromList values)

-- | Derive the single mapped-consumer dependency model from a checked graph.
-- Lists and query projections are sorted so source declaration and aggregate
-- order cannot affect the result.
semanticImpact :: TypeGraph -> SemanticImpact
semanticImpact graph =
  SemanticImpact
    { impactRoots = roots,
      impactUsePaths = Map.fromSet (sort . usePaths graph . unMappedKey) serviceDeclarations,
      impactAggregateDeclarations = aggregateDeclarations,
      impactDeclarationConsumers = declarationConsumers,
      impactServiceDeclarations = serviceDeclarations,
      impactDeclarationIdentities = Map.mapWithKey (declarationIdentity graph) (tgDeclarations graph),
      impactUnsupportedProjectionSources = tgUnsupportedProjectionSources graph
    }
  where
    directRoots = map mappedRootFromUseSite (tgUseSites graph)
    roots = sort (directRoots <> concatMap derivedRoots (tgDerivedMappedConsumers graph))
    derivedRoots consumer =
      [ MappedRoot
          { mappedRootConsumer = DerivedProjectionConsumer consumer,
            mappedRootKind = MappedProjectionEventRoot,
            mappedRootUseSite = site,
            mappedRootDeclaration = declaration
          }
      | site@(RootEventField aggregate _ _ declaration) <- tgUseSites graph,
        aggregate == derivedAuthority consumer
      ]
    aggregateDeclarations =
      Map.fromListWith
        Set.union
        [ (mappedRootConsumer root, declarationClosure graph (mappedRootDeclaration root))
        | root <- roots
        ]
    serviceDeclarations = Map.keysSet (tgDeclarations graph)
    declarationConsumers =
      Map.unionWith
        Set.union
        (Map.fromSet (const Set.empty) serviceDeclarations)
        ( Map.fromListWith
            Set.union
            [ (declaration, Set.singleton consumer)
            | (consumer, declarations) <- Map.toList aggregateDeclarations,
              declaration <- Set.toList declarations
            ]
        )

-- | Freeze the checked dependency projection in canonical map/set form.
semanticImpactSnapshot :: SemanticImpact -> SemanticImpactSnapshot
semanticImpactSnapshot impact =
  SemanticImpactSnapshot
    { snapshotMappedConsumers = impactDeclarationConsumers impact,
      snapshotServiceInventory = impactServiceDeclarations impact,
      snapshotDeclarationIdentities = impactDeclarationIdentities impact
    }

-- | Compare consumer membership, service-inventory membership, and canonical
-- source-independent declaration identities.
diffSemanticImpact :: SemanticImpactSnapshot -> SemanticImpactSnapshot -> [MappedImpactDelta]
diffSemanticImpact previous current =
  [ delta
  | delta <- mappedImpactForDeclarations allDeclarations previous current,
    impactPreviousConsumers delta /= impactCurrentConsumers delta
      || serviceMember previous (impactDeclaration delta) /= serviceMember current (impactDeclaration delta)
      || declarationIdentityAt previous (impactDeclaration delta) /= declarationIdentityAt current (impactDeclaration delta)
  ]
  where
    allDeclarations = Set.toAscList (snapshotServiceInventory previous <> snapshotServiceInventory current)

-- | Explain an authoritative set of changed mapped declarations. Keys are
-- sorted and deduplicated; a key absent from both inventories is ignored.
mappedImpactForDeclarations :: [MappedKey] -> SemanticImpactSnapshot -> SemanticImpactSnapshot -> [MappedImpactDelta]
mappedImpactForDeclarations declarations previous current =
  [ MappedImpactDelta
      { impactDeclaration = declaration,
        impactPreviousConsumers = snapshotConsumers previous declaration,
        impactCurrentConsumers = snapshotConsumers current declaration,
        impactServiceConformance = serviceMember previous declaration || serviceMember current declaration
      }
  | declaration <- Set.toAscList (Set.fromList declarations),
    serviceMember previous declaration || serviceMember current declaration
  ]

-- | Build the typed scaffold explanation. With legacy history the delta list
-- stays empty because the missing old row is unknown rather than empty.
semanticImpactReport :: Maybe SemanticImpactSnapshot -> SemanticImpactSnapshot -> [MappedKey] -> SemanticImpactReport
semanticImpactReport previous current declarations =
  SemanticImpactReport
    { semanticReportPrevious = previous,
      semanticReportCurrent = current,
      semanticReportDeclarations = canonicalDeclarations,
      semanticReportDeltas = maybe [] (\old -> mappedImpactForDeclarations canonicalDeclarations old current) previous
    }
  where
    canonicalDeclarations = Set.toAscList (Set.fromList declarations)

snapshotConsumers :: SemanticImpactSnapshot -> MappedKey -> Set MappedConsumer
snapshotConsumers snapshot declaration = Map.findWithDefault Set.empty declaration (snapshotMappedConsumers snapshot)

serviceMember :: SemanticImpactSnapshot -> MappedKey -> Bool
serviceMember snapshot declaration = declaration `Set.member` snapshotServiceInventory snapshot

declarationIdentityAt :: SemanticImpactSnapshot -> MappedKey -> Maybe Text
declarationIdentityAt snapshot declaration = Map.lookup declaration (snapshotDeclarationIdentities snapshot)

-- | Canonical identity for mapped declaration facts that 'MappedDiff' treats
-- as changes. Source locations and declaration order are deliberately absent.
declarationIdentity :: TypeGraph -> MappedKey -> ResolvedMappedDecl -> Text
declarationIdentity graph key declaration =
  T.intercalate "\x1f" $ case declaration of
    ResolvedStructural structural shape -> structuralParts structural shape
    ResolvedOpaque opaque -> opaqueParts opaque
  where
    structuralParts structural shape =
      [ "structural",
        sourceIdentity (sdHaskell structural),
        unQualifiedValueName (sdBinding structural),
        unBindingVersion (sdBindingVersion structural),
        unCanonicalTypeId (sdCanonical structural),
        unQualifiedValueName (sdFixtures structural),
        maybe "" unQualifiedValueName (sdInitial structural),
        wireFingerprint graph (unMappedKey key),
        structuralPresentation shape
      ]
    opaqueParts opaque =
      [ "opaque",
        sourceIdentity (odHaskell opaque),
        unCodecIdentity (odCodecIdentity opaque),
        unCodecVersion (odCodecVersion opaque),
        unQualifiedValueName (odFixtures opaque),
        maybe "" unQualifiedValueName (odInitial opaque),
        wireFingerprint graph (unMappedKey key)
      ]
    sourceIdentity source = T.intercalate ":" [hsPackage source, hsModule source, hsType source]
    structuralPresentation (RRecord constructor _ fields) =
      "record:" <> constructor <> ":" <> T.intercalate "," [rwfHaskell field <> "=" <> rwfKey field | field <- sortOn rwfKey fields]
    structuralPresentation (REnum entries) =
      "enum:" <> T.intercalate "," [weCtor entry <> "=" <> weTag entry | entry <- sortOn weTag entries]
    structuralPresentation (RUnion _ arms) =
      "union:" <> T.intercalate "," [rwaTag arm | arm <- sortOn rwaTag arms]

mappedConsumerIdentity :: MappedConsumer -> Name
mappedConsumerIdentity (AggregateConsumer aggregate) = aggregate
mappedConsumerIdentity (WorkqueueConsumer workqueue) = "workqueue:" <> workqueue
mappedConsumerIdentity (ReadModelConsumer readModel) = "read-model:" <> readModel
mappedConsumerIdentity (DerivedProjectionConsumer (AggregateInlineProjectionConsumer aggregate projection)) =
  "aggregate-projection:" <> aggregate <> ":" <> projection
mappedConsumerIdentity (DerivedProjectionConsumer (CatalogProjectionConsumer owner aggregate)) =
  "catalog-projection:" <> owner <> ":" <> aggregate

parseConsumerName :: (MonadFail m) => Text -> m MappedConsumer
parseConsumerName raw = case T.splitOn ":" raw of
  ["workqueue", workqueue] -> pure (WorkqueueConsumer workqueue)
  ["read-model", readModel] -> pure (ReadModelConsumer readModel)
  ["aggregate-projection", aggregate, projection] ->
    pure (DerivedProjectionConsumer (AggregateInlineProjectionConsumer aggregate projection))
  ["catalog-projection", owner, aggregate] ->
    pure (DerivedProjectionConsumer (CatalogProjectionConsumer owner aggregate))
  [_] -> pure (AggregateConsumer raw)
  _ -> fail "invalid semantic-impact consumer identity"

derivedAuthority :: DerivedMappedConsumer -> Name
derivedAuthority (AggregateInlineProjectionConsumer aggregate _) = aggregate
derivedAuthority (CatalogProjectionConsumer _ aggregate) = aggregate

-- | Return the checked roots owned by one aggregate in stable order.
aggregateMappedRoots :: SemanticImpact -> Name -> [MappedRoot]
aggregateMappedRoots impact aggregate =
  [ root
  | root <- impactRoots impact,
    mappedRootConsumer root == AggregateConsumer aggregate
  ]

-- | Return one aggregate's transitive mapped declaration closure in stable
-- declaration-key order.
aggregateMappedClosure :: SemanticImpact -> Name -> [MappedKey]
aggregateMappedClosure impact aggregate =
  maybe [] Set.toAscList (Map.lookup (AggregateConsumer aggregate) (impactAggregateDeclarations impact))

-- | Return every aggregate that can consume a declaration in stable order.
-- Unknown and intentionally unused declarations both have no consumers; use
-- 'serviceMappedInventory' to distinguish whether a declaration exists.
mappedDeclarationConsumers :: SemanticImpact -> MappedKey -> [MappedConsumer]
mappedDeclarationConsumers impact declaration =
  maybe [] Set.toAscList (Map.lookup declaration (impactDeclarationConsumers impact))

-- | Return every checked declaration, including declarations with no current
-- aggregate consumer, in stable order.
serviceMappedInventory :: SemanticImpact -> [MappedKey]
serviceMappedInventory = Set.toAscList . impactServiceDeclarations

declarationClosure :: TypeGraph -> MappedKey -> Set MappedKey
declarationClosure graph root =
  Set.insert root (Map.findWithDefault Set.empty root (tgReachability graph))

mappedRootFromUseSite :: UseSite -> MappedRoot
mappedRootFromUseSite site@(RootCommandField aggregate _ _ declaration) =
  MappedRoot
    { mappedRootConsumer = AggregateConsumer aggregate,
      mappedRootKind = MappedCommandFieldRoot,
      mappedRootUseSite = site,
      mappedRootDeclaration = declaration
    }
mappedRootFromUseSite site@(RootEventField aggregate _ _ declaration) =
  MappedRoot
    { mappedRootConsumer = AggregateConsumer aggregate,
      mappedRootKind = MappedEventFieldRoot,
      mappedRootUseSite = site,
      mappedRootDeclaration = declaration
    }
mappedRootFromUseSite site@(RootRegister aggregate _ declaration) =
  MappedRoot
    { mappedRootConsumer = AggregateConsumer aggregate,
      mappedRootKind = MappedRegisterRoot,
      mappedRootUseSite = site,
      mappedRootDeclaration = declaration
    }
mappedRootFromUseSite site@(RootWorkqueueField workqueue _ declaration) =
  MappedRoot
    { mappedRootConsumer = WorkqueueConsumer workqueue,
      mappedRootKind = MappedWorkqueueFieldRoot,
      mappedRootUseSite = site,
      mappedRootDeclaration = declaration
    }
mappedRootFromUseSite site@(RootReadModelQueryInput readModel declaration) =
  MappedRoot
    { mappedRootConsumer = ReadModelConsumer readModel,
      mappedRootKind = MappedReadModelQueryInputRoot,
      mappedRootUseSite = site,
      mappedRootDeclaration = declaration
    }
mappedRootFromUseSite site@(RootReadModelQueryResult readModel declaration) =
  MappedRoot
    { mappedRootConsumer = ReadModelConsumer readModel,
      mappedRootKind = MappedReadModelQueryResultRoot,
      mappedRootUseSite = site,
      mappedRootDeclaration = declaration
    }
