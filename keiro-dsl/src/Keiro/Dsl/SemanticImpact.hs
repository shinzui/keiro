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
    semanticImpact,
    aggregateMappedRoots,
    aggregateMappedClosure,
    mappedDeclarationConsumers,
    serviceMappedInventory,
  )
where

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
