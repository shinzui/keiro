-- | Order-independent projection-owner resolution for catalog-bound query
-- models. Validation and generated consumers share this analysis so target
-- ownership never acquires a second, list-order-sensitive interpretation.
module Keiro.Dsl.ProjectionSupply
  ( ResolvedProjectionSupply (..),
    ProjectionSupplyIssue (..),
    ProjectionSupplyAnalysis (..),
    analyzeProjectionSupplies,
  )
where

import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Keiro.Dsl.Grammar

-- | One successfully resolved catalog-bound query model. Observed targets are
-- normalized by identity; source locations remain available for structured
-- diagnostics and generated evidence.
data ResolvedProjectionSupply = ResolvedProjectionSupply
  { queryModel :: !Name,
    projectionOwner :: !Name,
    rebuildGroup :: !Name,
    observedTargets :: !(NonEmpty Name),
    queryLoc :: !Loc,
    ownerLoc :: !Loc
  }
  deriving stock (Eq, Show)

-- | Structural failures found while deriving the relation. The public DSL
-- diagnostic layer decides which issue owns a user-facing diagnostic and which
-- is already covered by an earlier target/group declaration error.
data ProjectionSupplyIssue
  = SupplyObservedTargetsEmpty !ReadModelNode
  | SupplyObservedTargetUnknown !ReadModelNode !Name
  | SupplyObservedTargetOutsideGroup !ReadModelNode !Name
  | SupplyObservedTargetWithoutOwner !ReadModelNode !Name
  | SupplyObservedTargetWithMultipleOwners !ReadModelNode !Name ![ProjectionOwnerNode]
  | SupplyOwnerGroupMismatch !ReadModelNode !Name !ProjectionOwnerNode
  | SupplyQueryWithoutOwner !ReadModelNode
  | SupplyQueryWithMultipleOwners !ReadModelNode ![ProjectionOwnerNode]
  | SupplyLegacyProjectionConflict !ReadModelNode !Aggregate !ProjectionSpec
  deriving stock (Eq, Show)

data ProjectionSupplyAnalysis = ProjectionSupplyAnalysis
  { resolvedProjectionSupplies :: ![ResolvedProjectionSupply],
    projectionSupplyIssues :: ![ProjectionSupplyIssue]
  }
  deriving stock (Eq, Show)

analyzeProjectionSupplies :: Spec -> ProjectionSupplyAnalysis
analyzeProjectionSupplies spec =
  ProjectionSupplyAnalysis
    { resolvedProjectionSupplies = concatMap (fst . analyzeReadModel) catalogReadModels,
      projectionSupplyIssues = concatMap (snd . analyzeReadModel) catalogReadModels
    }
  where
    catalogReadModels =
      sortOn
        (.name)
        [ readModel
        | NReadModel readModel <- (.nodes) spec,
          (.group) readModel /= Nothing
        ]
    targetsByName =
      Map.fromList
        [ ((.name) target, target)
        | NProjectionTarget target <- (.nodes) spec
        ]
    groupsByTarget =
      Map.fromListWith
        (<>)
        [ (targetName, [(.name) groupNode])
        | NRebuildGroup groupNode <- (.nodes) spec,
          targetName <- (.targets) groupNode
        ]
    ownersByTarget =
      Map.fromListWith
        (<>)
        [ (targetName, [owner])
        | NProjectionOwner owner <- (.nodes) spec,
          targetName <- (.targets) owner
        ]
    legacyProjections =
      [ (aggregate, projection)
      | NAggregate aggregate <- (.nodes) spec,
        Just projection <- [(.projection) aggregate]
      ]

    analyzeReadModel readModel =
      (resolved, sortOn issueSortKey (legacyIssues <> structuralIssues))
      where
        observedTargets = sort (nub ((.observedTargets) readModel))
        queryGroup = maybe (error "catalog read model lost its group") id ((.group) readModel)
        legacyIssues =
          [ SupplyLegacyProjectionConflict readModel aggregate projection
          | (aggregate, projection) <- legacyProjections,
            (.table) projection == (.name) readModel
          ]
        targetIssues = concatMap (issuesForTarget readModel queryGroup) observedTargets
        structuralIssues
          | null observedTargets = [SupplyObservedTargetsEmpty readModel]
          | not (null targetIssues) = targetIssues
          | otherwise = case supplierOwners of
              [] -> [SupplyQueryWithoutOwner readModel]
              [owner] ->
                [ SupplyOwnerGroupMismatch readModel targetName owner
                | targetName <- observedTargets,
                  (.group) owner /= queryGroup
                ]
              owners -> [SupplyQueryWithMultipleOwners readModel owners]
        supplierOwners =
          sortOn (.name)
            . nubByOwner
            $ [ owner
              | targetName <- observedTargets,
                [owner] <- [Map.findWithDefault [] targetName ownersByTarget]
              ]
        resolved = case structuralIssues of
          [] -> case supplierOwners of
            [owner] ->
              [ ResolvedProjectionSupply
                  { queryModel = (.name) readModel,
                    projectionOwner = (.name) owner,
                    rebuildGroup = queryGroup,
                    observedTargets = case observedTargets of
                      target : rest -> target :| rest
                      [] -> error "resolved projection supply lost observed targets",
                    queryLoc = (.loc) readModel,
                    ownerLoc = (.loc) owner
                  }
              ]
            _ -> []
          _ -> []

    issuesForTarget readModel queryGroup targetName =
      case Map.lookup targetName targetsByName of
        Nothing -> [SupplyObservedTargetUnknown readModel targetName]
        Just _ ->
          groupIssues <> ownerIssues
      where
        groupIssues =
          [ SupplyObservedTargetOutsideGroup readModel targetName
          | Map.findWithDefault [] targetName groupsByTarget /= [queryGroup]
          ]
        ownerIssues = case sortOn (.name) (Map.findWithDefault [] targetName ownersByTarget) of
          [] -> [SupplyObservedTargetWithoutOwner readModel targetName]
          [_] -> []
          owners -> [SupplyObservedTargetWithMultipleOwners readModel targetName owners]

    nubByOwner = Map.elems . Map.fromList . map (\owner -> ((.name) owner, owner))

issueSortKey :: ProjectionSupplyIssue -> (Name, Int, Name)
issueSortKey = \case
  SupplyObservedTargetsEmpty readModel -> ((.name) readModel, 0, "")
  SupplyObservedTargetUnknown readModel targetName -> ((.name) readModel, 1, targetName)
  SupplyObservedTargetOutsideGroup readModel targetName -> ((.name) readModel, 2, targetName)
  SupplyObservedTargetWithoutOwner readModel targetName -> ((.name) readModel, 3, targetName)
  SupplyObservedTargetWithMultipleOwners readModel targetName _ -> ((.name) readModel, 4, targetName)
  SupplyOwnerGroupMismatch readModel targetName _ -> ((.name) readModel, 5, targetName)
  SupplyQueryWithoutOwner readModel -> ((.name) readModel, 6, "")
  SupplyQueryWithMultipleOwners readModel _ -> ((.name) readModel, 7, "")
  SupplyLegacyProjectionConflict readModel aggregate _ -> ((.name) readModel, 8, (.name) aggregate)
