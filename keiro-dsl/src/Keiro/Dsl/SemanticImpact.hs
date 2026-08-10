{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Checked semantic dependency impact for mapped declarations.
--
-- This module answers which aggregates can consume a mapped declaration. It
-- does not classify wire compatibility and it does not claim that finite
-- conformance fixtures prove a consumer binding for all values. Both the roots
-- and transitive declaration edges come from a resolved 'TypeGraph', so callers
-- must not reconstruct this relation from a raw specification.
module Keiro.Dsl.SemanticImpact
  ( MappedConsumer (..),
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
    aggregateMappedRoots,
    aggregateMappedClosure,
    mappedDeclarationConsumers,
    serviceMappedInventory,
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar (Name)
import Keiro.Dsl.TypeGraph

-- | A checked consumer of mapped declarations. The current checked graph has
-- aggregate consumers only; service-wide conformance is represented separately
-- by 'impactServiceDeclarations' so it never makes an aggregate closure global.
newtype MappedConsumer = AggregateConsumer Name
  deriving stock (Eq, Ord, Show, Generic)

-- | The complete mapped root vocabulary represented by 'UseSite'. Snapshot
-- impact follows 'RegisterRoot' because snapshots cache aggregate registers.
-- Queues, public contracts, read models, and projections do not yet carry
-- mapped 'TypeExpr' roots and are intentionally absent.
data MappedRootKind
  = MappedCommandFieldRoot
  | MappedEventFieldRoot
  | MappedRegisterRoot
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
    impactAggregateDeclarations :: !(Map MappedConsumer (Set MappedKey)),
    impactDeclarationConsumers :: !(Map MappedKey (Set MappedConsumer)),
    impactServiceDeclarations :: !(Set MappedKey)
  }
  deriving stock (Eq, Show, Generic)

-- | Durable, source-independent evidence for the mapped consumer graph. The
-- map contains every service declaration, including declarations with no
-- aggregate consumer. The explicit service inventory makes the declaration
-- ownership boundary visible and leaves room for future non-aggregate roots.
data SemanticImpactSnapshot = SemanticImpactSnapshot
  { snapshotMappedConsumers :: !(Map MappedKey (Set MappedConsumer)),
    snapshotServiceInventory :: !(Set MappedKey)
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
                   "consumers" .= map consumerName (Set.toAscList declarationConsumers)
                 ]
             | (declaration, declarationConsumers) <- Map.toAscList (snapshotMappedConsumers snapshot)
             ],
        "serviceInventory" .= map unMappedKey (Set.toAscList (snapshotServiceInventory snapshot))
      ]

instance FromJSON SemanticImpactSnapshot where
  parseJSON = withObject "SemanticImpactSnapshot" $ \fields -> do
    declarations <- fields .: "declarations" >>= traverse parseDeclaration
    inventoryNames <- fields .: "serviceInventory"
    let declarationNames = map fst declarations
        inventoryKeys = map MappedKey inventoryNames
        declarationMap = Map.fromList declarations
        inventory = Set.fromList inventoryKeys
    unless (distinct declarationNames) (fail "duplicate semantic-impact declaration")
    unless (distinct inventoryKeys) (fail "duplicate semantic-impact service inventory declaration")
    unless (Map.keysSet declarationMap == inventory) (fail "semantic-impact declarations and service inventory differ")
    pure
      SemanticImpactSnapshot
        { snapshotMappedConsumers = declarationMap,
          snapshotServiceInventory = inventory
        }
    where
      parseDeclaration = withObject "SemanticImpactDeclaration" $ \row -> do
        declarationName <- row .: "declaration"
        consumerNames <- row .: "consumers"
        let aggregateConsumers = map AggregateConsumer consumerNames
        unless (distinct aggregateConsumers) (fail "duplicate semantic-impact aggregate consumer")
        pure (MappedKey declarationName, Set.fromList aggregateConsumers)
      distinct values = length values == Set.size (Set.fromList values)

instance ToJSON MappedImpactDelta where
  toJSON delta =
    object
      [ "declaration" .= unMappedKey (impactDeclaration delta),
        "previousConsumers" .= map consumerName (Set.toAscList (impactPreviousConsumers delta)),
        "currentConsumers" .= map consumerName (Set.toAscList (impactCurrentConsumers delta)),
        "serviceConformance" .= impactServiceConformance delta
      ]

instance FromJSON MappedImpactDelta where
  parseJSON = withObject "MappedImpactDelta" $ \fields -> do
    declaration <- MappedKey <$> fields .: "declaration"
    previousNames <- fields .: "previousConsumers"
    currentNames <- fields .: "currentConsumers"
    serviceConformance <- fields .: "serviceConformance"
    let previous = map AggregateConsumer previousNames
        current = map AggregateConsumer currentNames
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
      impactAggregateDeclarations = aggregateDeclarations,
      impactDeclarationConsumers = declarationConsumers,
      impactServiceDeclarations = serviceDeclarations
    }
  where
    roots = sort (map mappedRootFromUseSite (tgUseSites graph))
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
      snapshotServiceInventory = impactServiceDeclarations impact
    }

-- | Compare only consumer and service-inventory membership. A declaration's
-- schema may change while these sets remain equal; differ/scaffold callers use
-- 'mappedImpactForDeclarations' with their authoritative changed-key set for
-- that case.
diffSemanticImpact :: SemanticImpactSnapshot -> SemanticImpactSnapshot -> [MappedImpactDelta]
diffSemanticImpact previous current =
  [ delta
  | delta <- mappedImpactForDeclarations allDeclarations previous current,
    impactPreviousConsumers delta /= impactCurrentConsumers delta
      || serviceMember previous (impactDeclaration delta) /= serviceMember current (impactDeclaration delta)
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

consumerName :: MappedConsumer -> Name
consumerName (AggregateConsumer aggregate) = aggregate

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
