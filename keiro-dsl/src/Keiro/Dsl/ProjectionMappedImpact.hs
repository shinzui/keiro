{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Projection dependencies inherited from authoritative aggregate event
-- roots. This module never invents a projection type expression: it projects
-- the checked mapped-event graph onto the existing inline/catalog ownership
-- graph and keeps SQL effects explicitly operational rather than typed.
module Keiro.Dsl.ProjectionMappedImpact
  ( ProjectionMappedRoot (..),
    ProjectionOperationalImpact (..),
    UnsupportedProjectionImpact (..),
    ProjectionMappedImpact (..),
    projectionMappedImpact,
    projectionMappedImpactForService,
    projectionConsumersFor,
    projectionOperationsFor,
    projectionAggregateSourceFingerprint,
    renderProjectionMappedImpact,
  )
where

import Data.List (find, nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
import Keiro.Dsl.ReadModelShape (fnv1a64)
import Keiro.Dsl.SemanticContract (CheckedService (..))
import Keiro.Dsl.SemanticImpact
import Keiro.Dsl.TypeGraph

-- | One complete inherited event path for one derived projection consumer and
-- one declaration in the event root's transitive mapped closure.
data ProjectionMappedRoot = ProjectionMappedRoot
  { consumer :: !DerivedMappedConsumer,
    declaration :: !MappedKey,
    path :: !UsePath
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Operational effects related to a typed projection consumer. Targets and
-- observing query models do not become Haskell type consumers: unrestricted
-- handler SQL prevents that stronger claim.
data ProjectionOperationalImpact = ProjectionOperationalImpact
  { consumer :: !DerivedMappedConsumer,
    group :: !(Maybe Name),
    targets :: !(Set Name),
    readModels :: !(Set Name),
    replayable :: !Bool,
    sourceFingerprint :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | A category/all-history owner participates in catalog operations but has
-- no single mapped event type. Keeping the whole operational relation makes
-- that unsupported typed boundary visible without attaching a fake key.
data UnsupportedProjectionImpact = UnsupportedProjectionImpact
  { source :: !UnsupportedProjectionSource,
    group :: !Name,
    targets :: !(Set Name),
    readModels :: !(Set Name),
    replayable :: !Bool
  }
  deriving stock (Eq, Ord, Show, Generic)

data ProjectionMappedImpact = ProjectionMappedImpact
  { roots :: ![ProjectionMappedRoot],
    consumers :: !(Map MappedKey (Set DerivedMappedConsumer)),
    operations :: !(Map DerivedMappedConsumer ProjectionOperationalImpact),
    unsupported :: ![UnsupportedProjectionImpact]
  }
  deriving stock (Eq, Show, Generic)

-- | Join checked mapped-event paths to inline/catalog projection ownership.
-- Command, register, queue, and query roots are excluded by construction.
projectionMappedImpact :: CheckedService -> SemanticImpact -> ProjectionMappedImpact
projectionMappedImpact service semantic =
  ProjectionMappedImpact
    { roots = mappedRoots,
      consumers =
        Map.fromListWith
          Set.union
          [ (declarationKey, Set.singleton derived)
          | ProjectionMappedRoot derived declarationKey _ <- mappedRoots
          ],
      operations = Map.fromList [(derived, operation) | operation@(ProjectionOperationalImpact derived _ _ _ _ _) <- operational],
      unsupported = sort (mapMaybeUnsupported unsupportedSources)
    }
  where
    spec = checkedSpec service
    derivedConsumers =
      Set.fromList
        [ derived
        | mappedConsumers <- Map.elems (impactDeclarationConsumers semantic),
          DerivedProjectionConsumer derived <- Set.toList mappedConsumers
        ]
    mappedRoots =
      sort . nub $
        [ ProjectionMappedRoot derived declarationKey usePath
        | (declarationKey, usePathValues) <- Map.toAscList (impactUsePaths semantic),
          usePath <- usePathValues,
          aggregate <- maybeToList (eventAuthority usePath),
          derived <- Set.toAscList derivedConsumers,
          derivedAuthority derived == aggregate
        ]
    operational =
      mapMaybeOperation
        (Set.toAscList (Set.fromList [derived | ProjectionMappedRoot derived _ _ <- mappedRoots]))
    unsupportedSources = impactUnsupportedProjectionSources semantic

    mapMaybeOperation = foldr (maybe id (:) . operationFor spec) []
    mapMaybeUnsupported = foldr (maybe id (:) . unsupportedFor spec) []

-- | Resolve and project a checked service without making callers reconstruct
-- the shared type graph. A failed resolution remains explicit even though the
-- scaffold admission gate normally prevents it from reaching report creation.
projectionMappedImpactForService :: CheckedService -> Maybe ProjectionMappedImpact
projectionMappedImpactForService service = case resolveTypeGraph (checkedSpec service) of
  Left _ -> Nothing
  Right graph -> Just (projectionMappedImpact service (semanticImpact graph))

projectionConsumersFor :: ProjectionMappedImpact -> MappedKey -> Set DerivedMappedConsumer
projectionConsumersFor impact declarationKey = Map.findWithDefault Set.empty declarationKey (consumers impact)

projectionOperationsFor :: ProjectionMappedImpact -> MappedKey -> [ProjectionOperationalImpact]
projectionOperationsFor impact declarationKey =
  [ operation
  | derived <- Set.toAscList (projectionConsumersFor impact declarationKey),
    operation <- maybeToList (Map.lookup derived (operations impact))
  ]

-- | Stable source metadata for generated aggregate codecs. Existing aggregate
-- sources with no mapped event roots keep their historical byte exactly. A
-- mapped event root adds a digest over its complete root spelling and
-- transitive wire authority; command/register/query-only mappings are absent.
projectionAggregateSourceFingerprint :: Spec -> Name -> Text
projectionAggregateSourceFingerprint spec aggregate =
  case resolveTypeGraph spec of
    Left _ -> base
    Right graph ->
      case eventRows graph of
        [] -> base
        rows -> base <> "/mapped-" <> fnv1a64 (T.intercalate "\n" rows)
  where
    base = "aggregate:" <> aggregate <> "/generated-codec/v1"
    eventRows graph =
      sort
        [ renderUsePath (UsePath site (useSiteSegments graph site))
            <> "|wire="
            <> wireFingerprint graph (unMappedKey declarationKey)
        | site@(RootEventField authority _ _ declarationKey) <- tgUseSites graph,
          authority == aggregate
        ]

-- | Human-readable typed and operational projection evidence. Complete event
-- roots are shown independently from groups, targets, observing read models,
-- replay policy, and source fingerprints so SQL is never presented as a type
-- dependency. Category/all boundaries remain explicit and untyped.
renderProjectionMappedImpact :: ProjectionMappedImpact -> [Text]
renderProjectionMappedImpact impact
  | Map.null (consumers impact) && null (unsupported impact) = []
  | otherwise =
      ["projection mapped impact:"]
        <> concatMap renderDeclaration (Map.toAscList (consumers impact))
        <> renderUnsupported (unsupported impact)
  where
    renderDeclaration (declarationKey, derivedConsumers) =
      ["  " <> unMappedKey declarationKey]
        <> concatMap (renderConsumer declarationKey) (Set.toAscList derivedConsumers)
    renderConsumer declarationKey derived =
      [ "    " <> mappedConsumerIdentity (DerivedProjectionConsumer derived),
        "      inherited event roots: " <> renderSet (Set.fromList (pathsFor declarationKey derived))
      ]
        <> maybe [] (pure . ("      operation: " <>) . renderOperation) (Map.lookup derived (operations impact))
    pathsFor declarationKey derived =
      [ renderUsePath inheritedPath
      | ProjectionMappedRoot candidate declaration inheritedPath <- roots impact,
        candidate == derived,
        declaration == declarationKey
      ]
    renderOperation (ProjectionOperationalImpact _ groupName targetNames observerNames canReplay fingerprint) =
      "group="
        <> maybe "(inline)" id groupName
        <> "; targets="
        <> renderSet targetNames
        <> "; read-models="
        <> renderSet observerNames
        <> "; replayable="
        <> yesNo canReplay
        <> "; source-fingerprint="
        <> fingerprint
    renderUnsupported [] = []
    renderUnsupported boundaries =
      ["  unsupported typed sources:"] <> concatMap renderBoundary boundaries
    renderBoundary (UnsupportedProjectionImpact boundary groupName targetNames observerNames canReplay) =
      [ "    " <> renderBoundaryName boundary,
        "      operation: group="
          <> groupName
          <> "; targets="
          <> renderSet targetNames
          <> "; read-models="
          <> renderSet observerNames
          <> "; replayable="
          <> yesNo canReplay
          <> "; mapped-key=(unsupported heterogeneous source)"
      ]
    renderBoundaryName (UnsupportedCatalogCategory owner categoryName) =
      "catalog-category:" <> owner <> ":" <> categoryName
    renderBoundaryName (UnsupportedCatalogAll owner) = "catalog-all:" <> owner
    renderSet values = case Set.toAscList values of
      [] -> "(none)"
      names -> T.intercalate ", " names
    yesNo True = "yes"
    yesNo False = "no"

operationFor :: Spec -> DerivedMappedConsumer -> Maybe ProjectionOperationalImpact
operationFor spec derived = case derived of
  AggregateInlineProjectionConsumer aggregate projection ->
    Just
      ProjectionOperationalImpact
        { consumer = derived,
          group = Nothing,
          targets = Set.singleton projection,
          readModels = Set.fromList [rmName readModel | readModel <- readModelNodes spec, rmName readModel == projection],
          replayable = False,
          sourceFingerprint = projectionAggregateSourceFingerprint spec aggregate
        }
  CatalogProjectionConsumer ownerName aggregate -> do
    owner <- find ((== ownerName) . poName) (projectionOwners spec)
    pure
      ProjectionOperationalImpact
        { consumer = derived,
          group = Just (poGroup owner),
          targets = Set.fromList (poTargets owner),
          readModels = observingReadModels spec owner,
          replayable = isReplayable owner,
          sourceFingerprint = projectionAggregateSourceFingerprint spec aggregate
        }

unsupportedFor :: Spec -> UnsupportedProjectionSource -> Maybe UnsupportedProjectionImpact
unsupportedFor spec boundary = do
  owner <- find ((== unsupportedOwner boundary) . poName) (projectionOwners spec)
  pure
    UnsupportedProjectionImpact
      { source = boundary,
        group = poGroup owner,
        targets = Set.fromList (poTargets owner),
        readModels = observingReadModels spec owner,
        replayable = isReplayable owner
      }

observingReadModels :: Spec -> ProjectionOwnerNode -> Set Name
observingReadModels spec owner =
  Set.fromList
    [ rmName readModel
    | readModel <- readModelNodes spec,
      rmGroup readModel == Just (poGroup owner),
      not (Set.disjoint (Set.fromList (rmObservedTargets readModel)) (Set.fromList (poTargets owner)))
    ]

eventAuthority :: UsePath -> Maybe Name
eventAuthority UsePath {upRoot = RootEventField aggregate _ _ _} = Just aggregate
eventAuthority _ = Nothing

derivedAuthority :: DerivedMappedConsumer -> Name
derivedAuthority (AggregateInlineProjectionConsumer aggregate _) = aggregate
derivedAuthority (CatalogProjectionConsumer _ aggregate) = aggregate

unsupportedOwner :: UnsupportedProjectionSource -> Name
unsupportedOwner (UnsupportedCatalogCategory owner _) = owner
unsupportedOwner (UnsupportedCatalogAll owner) = owner

projectionOwners :: Spec -> [ProjectionOwnerNode]
projectionOwners spec = [owner | NProjectionOwner owner <- specNodes spec]

readModelNodes :: Spec -> [ReadModelNode]
readModelNodes spec = [readModel | NReadModel readModel <- specNodes spec]

isReplayable :: ProjectionOwnerNode -> Bool
isReplayable owner = case poReplay owner of
  ProjectionReplayExplicit -> True
  ProjectionLiveOnly _ -> False

maybeToList :: Maybe value -> [value]
maybeToList = maybe [] pure
