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
    MappedQueryPosition (..),
    RouterSelectionPosition (..),
    MappedConsumer (..),
    MappedRootKind (..),
    MappedRoot (..),
    MappedRootEvidence (..),
    MappedConsequence (..),
    SemanticImpact (..),
    SemanticImpactSnapshot (..),
    MappedImpactDelta (..),
    SemanticImpactReport (..),
    semanticImpact,
    semanticImpactForService,
    semanticImpactSnapshot,
    diffSemanticImpact,
    mappedImpactForDeclarations,
    semanticImpactReport,
    mappedConsumerIdentity,
    mappedRootKindIdentity,
    mappedConsequenceIdentity,
    mappedSurfaceFactValues,
    aggregateMappedRoots,
    aggregateMappedClosure,
    mappedDeclarationConsumers,
    serviceMappedInventory,
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
import Keiro.Dsl.RouterSelection
import Keiro.Dsl.SemanticContract (CheckedService, checkedLanguageContract, checkedSpec)
import Keiro.Dsl.TypeGraph

-- | A checked generated consumer of mapped declarations. Projection consumers
-- are derived from an aggregate event authority rather than owning another
-- source type expression.
data MappedQueryPosition
  = MappedQueryInput
  | MappedQueryResult
  deriving stock (Eq, Ord, Show, Generic)

data RouterSelectionPosition
  = SelectionQueryInput
  | SelectionPredicate
  | SelectionRecipient
  | SelectionCommandField !Name
  deriving stock (Eq, Ord, Show, Generic)

data MappedConsumer
  = AggregateConsumer !Name
  | WorkqueueConsumer !Name
  | ReadModelQueryConsumer !Name !MappedQueryPosition
  | RouterSelectionConsumer !Name !RouterSelectionPosition
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
  | MappedRouterSelectionQueryInputRoot
  | MappedRouterSelectionPredicateRoot
  | MappedRouterSelectionRecipientRoot
  | MappedRouterSelectionCommandFieldRoot
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

-- | A source-independent, surface-tagged path from one generated consumer to
-- one declaration. Unlike 'MappedRoot', this also represents transitive paths
-- and therefore is suitable for durable ledgers and exact conformance facts.
data MappedRootEvidence = MappedRootEvidence
  { evidenceConsumer :: !MappedConsumer,
    evidenceRootKind :: !MappedRootKind,
    evidencePath :: !Text,
    evidenceOperation :: !(Maybe Text)
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Orthogonal consequences of a mapped declaration. These deliberately do
-- not collapse persisted history, API/build impact, or projection rebuilds
-- into one severity.
data MappedConsequence
  = MappedConsumerBuild !MappedConsumer
  | MappedPrivateEventHistory !Name
  | MappedSnapshotHydration !Name
  | MappedWorkqueueHistory !Name
  | MappedQueryApi !Name !MappedQueryPosition
  | MappedRouterSelectionBuild !Name
  | MappedRouterSelectionCoordinationReview !Name
  | MappedProjectionHandlerReview !DerivedMappedConsumer
  | MappedProjectionRebuild !DerivedMappedConsumer !Name
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
    impactDeclarationEvidence :: !(Map MappedKey (Set MappedRootEvidence)),
    impactDeclarationConsequences :: !(Map MappedKey (Set MappedConsequence)),
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
    snapshotMappedEvidence :: !(Maybe (Map MappedKey (Set MappedRootEvidence))),
    snapshotMappedConsequences :: !(Maybe (Map MappedKey (Set MappedConsequence))),
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
    impactPreviousEvidence :: !(Maybe (Set MappedRootEvidence)),
    impactCurrentEvidence :: !(Maybe (Set MappedRootEvidence)),
    impactPreviousConsequences :: !(Maybe (Set MappedConsequence)),
    impactCurrentConsequences :: !(Maybe (Set MappedConsequence)),
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
    object $
      [ "declarations"
          .= [ object
                 ( [ "declaration" .= unMappedKey declaration,
                     "consumers" .= map mappedConsumerIdentity (Set.toAscList declarationConsumers),
                     "identity" .= Map.findWithDefault "" declaration (snapshotDeclarationIdentities snapshot)
                   ]
                     <> maybe [] (\evidence -> ["consumerEvidence" .= Set.toAscList (Map.findWithDefault Set.empty declaration evidence)]) (snapshotMappedEvidence snapshot)
                     <> maybe [] (\consequences -> ["consequences" .= Set.toAscList (Map.findWithDefault Set.empty declaration consequences)]) (snapshotMappedConsequences snapshot)
                 )
             | (declaration, declarationConsumers) <- Map.toAscList (snapshotMappedConsumers snapshot)
             ],
        "serviceInventory" .= map unMappedKey (Set.toAscList (snapshotServiceInventory snapshot))
      ]
        <> [ "mappedSurfaceEvidenceVersion" .= (1 :: Int)
           | isJust (snapshotMappedEvidence snapshot)
               || isJust (snapshotMappedConsequences snapshot)
           ]

instance FromJSON SemanticImpactSnapshot where
  parseJSON = withObject "SemanticImpactSnapshot" $ \fields -> do
    declarations <- fields .: "declarations" >>= traverse parseDeclaration
    inventoryNames <- fields .: "serviceInventory"
    surfaceEvidenceVersion <- (fields .:? "mappedSurfaceEvidenceVersion" :: Parser (Maybe Int))
    let declarationNames = [declaration | (declaration, _, _, _, _) <- declarations]
        inventoryKeys = map MappedKey inventoryNames
        declarationMap = Map.fromList [(declaration, declarationConsumers) | (declaration, declarationConsumers, _, _, _) <- declarations]
        declarationIdentities = Map.fromList [(declaration, identity) | (declaration, _, identity, _, _) <- declarations]
        evidenceRows = [(declaration, value) | (declaration, _, _, value, _) <- declarations]
        consequenceRows = [(declaration, value) | (declaration, _, _, _, value) <- declarations]
        inventory = Set.fromList inventoryKeys
    unless (distinct declarationNames) (fail "duplicate semantic-impact declaration")
    unless (distinct inventoryKeys) (fail "duplicate semantic-impact service inventory declaration")
    unless (Map.keysSet declarationMap == inventory) (fail "semantic-impact declarations and service inventory differ")
    unless (Map.keysSet declarationIdentities == inventory) (fail "semantic-impact declaration identities and service inventory differ")
    parsedEvidence <- completeOptionalRows "consumer evidence" evidenceRows
    parsedConsequences <- completeOptionalRows "consequences" consequenceRows
    (evidence, consequences) <- case surfaceEvidenceVersion of
      Nothing -> do
        unless (isJust parsedEvidence == isJust parsedConsequences) (fail "semantic-impact root evidence and consequences must be present together")
        pure (parsedEvidence, parsedConsequences)
      Just 1 -> do
        currentEvidence <- requireCurrentRows "consumer evidence" parsedEvidence declarationMap
        currentConsequences <- requireCurrentRows "consequences" parsedConsequences declarationMap
        pure (Just currentEvidence, Just currentConsequences)
      Just version -> fail ("unsupported semantic-impact mappedSurfaceEvidenceVersion: " <> show version)
    unless (maybe True (evidenceAgrees declarationMap) evidence) (fail "semantic-impact consumer evidence and consumer inventory differ")
    unless (maybe True (consequencesAgree declarationMap) consequences) (fail "semantic-impact consequences and consumer inventory differ")
    pure
      SemanticImpactSnapshot
        { snapshotMappedConsumers = declarationMap,
          snapshotMappedEvidence = evidence,
          snapshotMappedConsequences = consequences,
          snapshotServiceInventory = inventory,
          snapshotDeclarationIdentities = declarationIdentities
        }
    where
      parseDeclaration = withObject "SemanticImpactDeclaration" $ \row -> do
        declarationName <- row .: "declaration"
        consumerNames <- row .: "consumers"
        identity <- row .: "identity"
        evidence <- row .:? "consumerEvidence"
        consequences <- row .:? "consequences"
        consumers <- traverse parseConsumerName consumerNames
        unless (distinct consumers) (fail "duplicate semantic-impact consumer")
        maybe (pure ()) (\values -> unless (distinct values) (fail "duplicate semantic-impact consumer evidence")) evidence
        maybe (pure ()) (\values -> unless (distinct values) (fail "duplicate semantic-impact consequence")) consequences
        unless (not (T.null identity)) (fail "empty semantic-impact declaration identity")
        pure (MappedKey declarationName, Set.fromList consumers, identity, Set.fromList <$> evidence, Set.fromList <$> consequences)
      distinct values = length values == Set.size (Set.fromList values)
      evidenceAgrees consumers evidence =
        and
          [ Set.map evidenceConsumer (Map.findWithDefault Set.empty declaration evidence) == declarationConsumers
              && all operationAgrees (Set.toList (Map.findWithDefault Set.empty declaration evidence))
          | (declaration, declarationConsumers) <- Map.toList consumers
          ]
      operationAgrees evidence = case evidenceRootKind evidence of
        MappedProjectionEventRoot -> maybe False (not . T.null) (evidenceOperation evidence)
        _ -> evidenceOperation evidence == Nothing
      consequencesAgree consumers consequences =
        and
          [ Set.fromList
              [ consumer
              | MappedConsumerBuild consumer <- Set.toList (Map.findWithDefault Set.empty declaration consequences)
              ]
              == declarationConsumers
          | (declaration, declarationConsumers) <- Map.toList consumers
          ]
      completeOptionalRows label rows
        | all (maybe True (const False) . snd) rows = pure Nothing
        | all (maybe False (const True) . snd) rows = pure (Just (Map.fromList [(key, value) | (key, Just value) <- rows]))
        | otherwise = fail ("semantic-impact " <> label <> " is present for only part of the service inventory")
      requireCurrentRows label rows declarations
        | Map.null declarations = pure (maybe Map.empty id rows)
        | otherwise = maybe (fail ("semantic-impact " <> label <> " is absent from a versioned current snapshot")) pure rows

instance ToJSON MappedRootEvidence where
  toJSON evidence =
    object
      [ "consumer" .= mappedConsumerIdentity (evidenceConsumer evidence),
        "surface" .= mappedRootKindIdentity (evidenceRootKind evidence),
        "path" .= evidencePath evidence,
        "operation" .= evidenceOperation evidence
      ]

instance FromJSON MappedRootEvidence where
  parseJSON = withObject "MappedRootEvidence" $ \fields ->
    MappedRootEvidence
      <$> (fields .: "consumer" >>= parseConsumerName)
      <*> (fields .: "surface" >>= parseMappedRootKind)
      <*> fields .: "path"
      <*> fields .:? "operation"

instance ToJSON MappedConsequence where
  toJSON consequence = case consequence of
    MappedConsumerBuild consumer -> object ["kind" .= ("consumer-build" :: Text), "consumer" .= mappedConsumerIdentity consumer]
    MappedPrivateEventHistory aggregate -> object ["kind" .= ("private-event-history" :: Text), "aggregate" .= aggregate]
    MappedSnapshotHydration aggregate -> object ["kind" .= ("snapshot-hydration" :: Text), "aggregate" .= aggregate]
    MappedWorkqueueHistory workqueue -> object ["kind" .= ("workqueue-history" :: Text), "workqueue" .= workqueue]
    MappedQueryApi readModel position -> object ["kind" .= ("query-api" :: Text), "readModel" .= readModel, "position" .= mappedQueryPositionIdentity position]
    MappedRouterSelectionBuild router -> object ["kind" .= ("router-selection-build" :: Text), "router" .= router]
    MappedRouterSelectionCoordinationReview router -> object ["kind" .= ("router-selection-coordination-review" :: Text), "router" .= router]
    MappedProjectionHandlerReview consumer -> object ["kind" .= ("projection-handler-review" :: Text), "consumer" .= mappedConsumerIdentity (DerivedProjectionConsumer consumer)]
    MappedProjectionRebuild consumer groupName -> object ["kind" .= ("projection-rebuild" :: Text), "consumer" .= mappedConsumerIdentity (DerivedProjectionConsumer consumer), "group" .= groupName]

instance FromJSON MappedConsequence where
  parseJSON = withObject "MappedConsequence" $ \fields -> do
    kind <- fields .: "kind"
    case (kind :: Text) of
      "consumer-build" -> MappedConsumerBuild <$> (fields .: "consumer" >>= parseConsumerName)
      "private-event-history" -> MappedPrivateEventHistory <$> fields .: "aggregate"
      "snapshot-hydration" -> MappedSnapshotHydration <$> fields .: "aggregate"
      "workqueue-history" -> MappedWorkqueueHistory <$> fields .: "workqueue"
      "query-api" -> MappedQueryApi <$> fields .: "readModel" <*> (fields .: "position" >>= parseMappedQueryPosition)
      "router-selection-build" -> MappedRouterSelectionBuild <$> fields .: "router"
      "router-selection-coordination-review" -> MappedRouterSelectionCoordinationReview <$> fields .: "router"
      "projection-handler-review" -> MappedProjectionHandlerReview <$> (fields .: "consumer" >>= parseDerivedConsumer)
      "projection-rebuild" -> MappedProjectionRebuild <$> (fields .: "consumer" >>= parseDerivedConsumer) <*> fields .: "group"
      _ -> fail "unknown semantic-impact consequence kind"

instance ToJSON MappedImpactDelta where
  toJSON delta =
    object
      [ "declaration" .= unMappedKey (impactDeclaration delta),
        "previousConsumers" .= map mappedConsumerIdentity (Set.toAscList (impactPreviousConsumers delta)),
        "currentConsumers" .= map mappedConsumerIdentity (Set.toAscList (impactCurrentConsumers delta)),
        "previousConsumerEvidence" .= fmap Set.toAscList (impactPreviousEvidence delta),
        "currentConsumerEvidence" .= fmap Set.toAscList (impactCurrentEvidence delta),
        "previousConsequences" .= fmap Set.toAscList (impactPreviousConsequences delta),
        "currentConsequences" .= fmap Set.toAscList (impactCurrentConsequences delta),
        "serviceConformance" .= impactServiceConformance delta
      ]

instance FromJSON MappedImpactDelta where
  parseJSON = withObject "MappedImpactDelta" $ \fields -> do
    declaration <- MappedKey <$> fields .: "declaration"
    previousNames <- fields .: "previousConsumers"
    currentNames <- fields .: "currentConsumers"
    previousEvidence <- fields .:? "previousConsumerEvidence"
    currentEvidence <- fields .:? "currentConsumerEvidence"
    previousConsequences <- fields .:? "previousConsequences"
    currentConsequences <- fields .:? "currentConsequences"
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
          impactPreviousEvidence = Set.fromList <$> previousEvidence,
          impactCurrentEvidence = Set.fromList <$> currentEvidence,
          impactPreviousConsequences = Set.fromList <$> previousConsequences,
          impactCurrentConsequences = Set.fromList <$> currentConsequences,
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
      impactUsePaths = pathsByDeclaration,
      impactAggregateDeclarations = aggregateDeclarations,
      impactDeclarationConsumers = declarationConsumers,
      impactDeclarationEvidence = declarationEvidence,
      impactDeclarationConsequences = Map.map (Set.unions . map consequencesForEvidence . Set.toAscList) declarationEvidence,
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
    pathsByDeclaration = Map.fromSet (sort . usePaths graph . unMappedKey) serviceDeclarations
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
    declarationEvidence =
      Map.mapWithKey
        (\_ paths -> Set.fromList (concatMap evidenceForPath paths))
        pathsByDeclaration
    evidenceForPath usePath =
      let directRoot = mappedRootFromUseSite (upRoot usePath)
          direct =
            MappedRootEvidence
              { evidenceConsumer = mappedRootConsumer directRoot,
                evidenceRootKind = mappedRootKind directRoot,
                evidencePath = renderUsePath usePath,
                evidenceOperation = Nothing
              }
          projections =
            [ MappedRootEvidence
                { evidenceConsumer = DerivedProjectionConsumer derived,
                  evidenceRootKind = MappedProjectionEventRoot,
                  evidencePath = renderUsePath usePath,
                  evidenceOperation = Map.lookup derived (tgProjectionOperationalIdentities graph)
                }
            | aggregate <- maybeToList (eventAuthority usePath),
              derived <- tgDerivedMappedConsumers graph,
              derivedAuthority derived == aggregate
            ]
       in direct : projections
    consequencesForEvidence = consequencesForMappedEvidence graph

-- | Add the checked declarative selection consumers to the ordinary type-graph
-- projection. The parser AST is intentionally absent: every expression path and
-- query root comes from 'CheckedRouterSelection'.
semanticImpactForService :: CheckedService -> TypeGraph -> SemanticImpact
semanticImpactForService service graph =
  base
    { impactRoots = sort (impactRoots base <> map selectionEvidenceRoot extraEvidence),
      impactAggregateDeclarations = Map.unionWith Set.union (impactAggregateDeclarations base) declarationsByConsumer,
      impactDeclarationConsumers = Map.unionWith Set.union (impactDeclarationConsumers base) consumersByDeclaration,
      impactDeclarationEvidence = Map.unionWith Set.union (impactDeclarationEvidence base) evidenceByDeclaration,
      impactDeclarationConsequences = Map.unionWith Set.union (impactDeclarationConsequences base) consequencesByDeclaration
    }
  where
    base = semanticImpact graph
    extraEvidence = concatMap checkedRouterEvidence checkedSelections
    checkedSelections =
      [ (rtId router, checked)
      | NRouter router <- specNodes (checkedSpec service),
        ResolveDeclarative {} <- [rvSource (rtResolve router)],
        let checked = case checkRouterSelection (checkedLanguageContract service) graph (checkedSpec service) router of
              Right value -> value
              Left failures -> error ("validated declarative router selection did not check: " <> show failures)
      ]
    declarationsByConsumer =
      Map.fromListWith
        Set.union
        [ (mappedRootConsumer root, declarationClosure graph (mappedRootDeclaration root))
        | SelectionEvidence root _ <- extraEvidence
        ]
    consumersByDeclaration =
      Map.fromListWith
        Set.union
        [ (declaration, Set.singleton (mappedRootConsumer root))
        | SelectionEvidence root _ <- extraEvidence,
          declaration <- Set.toList (declarationClosure graph (mappedRootDeclaration root))
        ]
    evidenceByDeclaration =
      Map.fromListWith
        Set.union
        [ ( declaration,
            Set.singleton
              MappedRootEvidence
                { evidenceConsumer = mappedRootConsumer root,
                  evidenceRootKind = mappedRootKind root,
                  evidencePath = path,
                  evidenceOperation = Nothing
                }
          )
        | SelectionEvidence root path <- extraEvidence,
          declaration <- Set.toList (declarationClosure graph (mappedRootDeclaration root))
        ]
    consequencesByDeclaration =
      Map.map
        (Set.unions . map (consequencesForMappedEvidence graph) . Set.toAscList)
        evidenceByDeclaration

data SelectionEvidence = SelectionEvidence
  { selectionEvidenceRoot :: !MappedRoot,
    selectionEvidencePath :: !Text
  }

checkedRouterEvidence :: (Name, CheckedRouterSelection) -> [SelectionEvidence]
checkedRouterEvidence (router, selection) = queryInputEvidence <> expressionEvidence
  where
    queryInputEvidence =
      [ selectionEvidence router SelectionQueryInput MappedRouterSelectionQueryInputRoot site ("router " <> router <> " selection query input")
      | site@RootReadModelQueryInput {} <- checkedUseSites selection
      ]
    expressionEvidence =
      checkedExpressionEvidence router selection SelectionPredicate MappedRouterSelectionPredicateRoot "predicate" (checkedPredicate selection)
        <> checkedExpressionEvidence router selection SelectionRecipient MappedRouterSelectionRecipientRoot "recipient" (checkedRecipient selection)
        <> concat
          [ checkedExpressionEvidence router selection (SelectionCommandField field) MappedRouterSelectionCommandFieldRoot ("command field " <> field) expression
          | (field, expression) <- Map.toAscList (checkedCommandFields selection)
          ]

checkedExpressionEvidence :: Name -> CheckedRouterSelection -> RouterSelectionPosition -> MappedRootKind -> Text -> CheckedScalarExpr -> [SelectionEvidence]
checkedExpressionEvidence router selection position rootKind label expression =
  [ selectionEvidence router position rootKind site ("router " <> router <> " selection " <> label <> " " <> renderCheckedPath root segments)
  | (root, segments@(_ : _)) <- checkedScalarPaths expression,
    site <- selectionRootSites root selection
  ]

selectionEvidence :: Name -> RouterSelectionPosition -> MappedRootKind -> UseSite -> Text -> SelectionEvidence
selectionEvidence router position rootKind site path =
  SelectionEvidence
    { selectionEvidenceRoot =
        MappedRoot
          { mappedRootConsumer = RouterSelectionConsumer router position,
            mappedRootKind = rootKind,
            mappedRootUseSite = site,
            mappedRootDeclaration = useSiteDeclaration site
          },
      selectionEvidencePath = path
    }

selectionRootSites :: SelectionRoot -> CheckedRouterSelection -> [UseSite]
selectionRootSites root selection =
  [ site
  | site <- checkedUseSites selection,
    case (root, site) of
      (SelectionInput, RootReadModelQueryInput {}) -> True
      (SelectionRow, RootReadModelQueryResult {}) -> True
      _ -> False
  ]

checkedScalarPaths :: CheckedScalarExpr -> [(SelectionRoot, [CheckedSelectionPathSegment])]
checkedScalarPaths expression = case checkedScalarNode expression of
  CheckedPath root segments -> [(root, segments)]
  CheckedTextLiteral _ -> []
  CheckedIntegralLiteral _ -> []
  CheckedBoolLiteral _ -> []
  CheckedCompare _ left right -> checkedScalarPaths left <> checkedScalarPaths right
  CheckedAnd left right -> checkedScalarPaths left <> checkedScalarPaths right
  CheckedOr left right -> checkedScalarPaths left <> checkedScalarPaths right

renderCheckedPath :: SelectionRoot -> [CheckedSelectionPathSegment] -> Text
renderCheckedPath root segments =
  rootLabel <> T.concat ["." <> checkedPathField segment <> wireLabel segment | segment <- segments]
  where
    rootLabel = case root of SelectionInput -> "input"; SelectionRow -> "row"
    wireLabel segment
      | checkedPathField segment == checkedPathWireKey segment = ""
      | otherwise = " as '" <> checkedPathWireKey segment <> "'"

useSiteDeclaration :: UseSite -> MappedKey
useSiteDeclaration = \case
  RootCommandField _ _ _ declaration -> declaration
  RootEventField _ _ _ declaration -> declaration
  RootRegister _ _ declaration -> declaration
  RootWorkqueueField _ _ declaration -> declaration
  RootReadModelQueryInput _ declaration -> declaration
  RootReadModelQueryResult _ declaration -> declaration

consequencesForMappedEvidence :: TypeGraph -> MappedRootEvidence -> Set MappedConsequence
consequencesForMappedEvidence graph evidence =
  Set.fromList (MappedConsumerBuild (evidenceConsumer evidence) : surfaceConsequences)
  where
    surfaceConsequences = case evidenceRootKind evidence of
      MappedCommandFieldRoot -> []
      MappedEventFieldRoot -> case evidenceConsumer evidence of
        AggregateConsumer aggregate -> [MappedPrivateEventHistory aggregate]
        _ -> []
      MappedRegisterRoot -> case evidenceConsumer evidence of
        AggregateConsumer aggregate -> [MappedSnapshotHydration aggregate]
        _ -> []
      MappedWorkqueueFieldRoot -> case evidenceConsumer evidence of
        WorkqueueConsumer workqueue -> [MappedWorkqueueHistory workqueue]
        _ -> []
      MappedReadModelQueryInputRoot -> case evidenceConsumer evidence of
        ReadModelQueryConsumer readModel MappedQueryInput -> [MappedQueryApi readModel MappedQueryInput]
        _ -> []
      MappedReadModelQueryResultRoot -> case evidenceConsumer evidence of
        ReadModelQueryConsumer readModel MappedQueryResult -> [MappedQueryApi readModel MappedQueryResult]
        _ -> []
      MappedRouterSelectionQueryInputRoot -> selectionConsequences
      MappedRouterSelectionPredicateRoot -> selectionConsequences
      MappedRouterSelectionRecipientRoot -> selectionConsequences
      MappedRouterSelectionCommandFieldRoot -> selectionConsequences
      MappedProjectionEventRoot -> case evidenceConsumer evidence of
        DerivedProjectionConsumer derived ->
          MappedProjectionHandlerReview derived
            : [MappedProjectionRebuild derived groupName | groupName <- maybeToList (Map.lookup derived (tgReplayableProjectionGroups graph))]
        _ -> []
    selectionConsequences = case evidenceConsumer evidence of
      RouterSelectionConsumer router _ -> [MappedRouterSelectionBuild router, MappedRouterSelectionCoordinationReview router]
      _ -> []

-- | Freeze the checked dependency projection in canonical map/set form.
semanticImpactSnapshot :: SemanticImpact -> SemanticImpactSnapshot
semanticImpactSnapshot impact =
  SemanticImpactSnapshot
    { snapshotMappedConsumers = impactDeclarationConsumers impact,
      snapshotMappedEvidence = Just (impactDeclarationEvidence impact),
      snapshotMappedConsequences = Just (impactDeclarationConsequences impact),
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
      || impactPreviousEvidence delta /= impactCurrentEvidence delta
      || impactPreviousConsequences delta /= impactCurrentConsequences delta
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
        impactPreviousEvidence = snapshotEvidence previous declaration,
        impactCurrentEvidence = snapshotEvidence current declaration,
        impactPreviousConsequences = snapshotConsequences previous declaration,
        impactCurrentConsequences = snapshotConsequences current declaration,
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

snapshotEvidence :: SemanticImpactSnapshot -> MappedKey -> Maybe (Set MappedRootEvidence)
snapshotEvidence snapshot declaration = (Map.findWithDefault Set.empty declaration) <$> snapshotMappedEvidence snapshot

snapshotConsequences :: SemanticImpactSnapshot -> MappedKey -> Maybe (Set MappedConsequence)
snapshotConsequences snapshot declaration = (Map.findWithDefault Set.empty declaration) <$> snapshotMappedConsequences snapshot

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
mappedConsumerIdentity (ReadModelQueryConsumer readModel position) =
  "read-model-query:" <> readModel <> ":" <> mappedQueryPositionIdentity position
mappedConsumerIdentity (RouterSelectionConsumer router position) =
  "router-selection:" <> router <> ":" <> routerSelectionPositionIdentity position
mappedConsumerIdentity (DerivedProjectionConsumer (AggregateInlineProjectionConsumer aggregate projection)) =
  "aggregate-projection:" <> aggregate <> ":" <> projection
mappedConsumerIdentity (DerivedProjectionConsumer (CatalogProjectionConsumer owner aggregate)) =
  "catalog-projection:" <> owner <> ":" <> aggregate

parseConsumerName :: (MonadFail m) => Text -> m MappedConsumer
parseConsumerName raw = case T.splitOn ":" raw of
  ["workqueue", workqueue] -> pure (WorkqueueConsumer workqueue)
  ["read-model", readModel] -> pure (ReadModelQueryConsumer readModel MappedQueryInput)
  ["read-model-query", readModel, position] -> ReadModelQueryConsumer readModel <$> parseMappedQueryPosition position
  ["router-selection", router, "query-input"] -> pure (RouterSelectionConsumer router SelectionQueryInput)
  ["router-selection", router, "predicate"] -> pure (RouterSelectionConsumer router SelectionPredicate)
  ["router-selection", router, "recipient"] -> pure (RouterSelectionConsumer router SelectionRecipient)
  ["router-selection", router, "command-field", field] -> pure (RouterSelectionConsumer router (SelectionCommandField field))
  ["aggregate-projection", aggregate, projection] ->
    pure (DerivedProjectionConsumer (AggregateInlineProjectionConsumer aggregate projection))
  ["catalog-projection", owner, aggregate] ->
    pure (DerivedProjectionConsumer (CatalogProjectionConsumer owner aggregate))
  [_] -> pure (AggregateConsumer raw)
  _ -> fail "invalid semantic-impact consumer identity"

parseDerivedConsumer :: (MonadFail m) => Text -> m DerivedMappedConsumer
parseDerivedConsumer raw = do
  consumer <- parseConsumerName raw
  case consumer of
    DerivedProjectionConsumer derived -> pure derived
    _ -> fail "semantic-impact projection consequence names a non-projection consumer"

mappedQueryPositionIdentity :: MappedQueryPosition -> Text
mappedQueryPositionIdentity MappedQueryInput = "input"
mappedQueryPositionIdentity MappedQueryResult = "result"

parseMappedQueryPosition :: (MonadFail m) => Text -> m MappedQueryPosition
parseMappedQueryPosition "input" = pure MappedQueryInput
parseMappedQueryPosition "result" = pure MappedQueryResult
parseMappedQueryPosition _ = fail "unknown semantic-impact read-model query position"

routerSelectionPositionIdentity :: RouterSelectionPosition -> Text
routerSelectionPositionIdentity SelectionQueryInput = "query-input"
routerSelectionPositionIdentity SelectionPredicate = "predicate"
routerSelectionPositionIdentity SelectionRecipient = "recipient"
routerSelectionPositionIdentity (SelectionCommandField field) = "command-field:" <> field

mappedRootKindIdentity :: MappedRootKind -> Text
mappedRootKindIdentity MappedCommandFieldRoot = "aggregate-command"
mappedRootKindIdentity MappedEventFieldRoot = "private-event-payload"
mappedRootKindIdentity MappedRegisterRoot = "snapshot-register"
mappedRootKindIdentity MappedWorkqueueFieldRoot = "workqueue-payload"
mappedRootKindIdentity MappedReadModelQueryInputRoot = "read-model-query-input"
mappedRootKindIdentity MappedReadModelQueryResultRoot = "read-model-query-result"
mappedRootKindIdentity MappedRouterSelectionQueryInputRoot = "router-selection-query-input"
mappedRootKindIdentity MappedRouterSelectionPredicateRoot = "router-selection-predicate"
mappedRootKindIdentity MappedRouterSelectionRecipientRoot = "router-selection-recipient"
mappedRootKindIdentity MappedRouterSelectionCommandFieldRoot = "router-selection-command-field"
mappedRootKindIdentity MappedProjectionEventRoot = "projection-event-consumer"

parseMappedRootKind :: (MonadFail m) => Text -> m MappedRootKind
parseMappedRootKind "aggregate-command" = pure MappedCommandFieldRoot
parseMappedRootKind "private-event-payload" = pure MappedEventFieldRoot
parseMappedRootKind "snapshot-register" = pure MappedRegisterRoot
parseMappedRootKind "workqueue-payload" = pure MappedWorkqueueFieldRoot
parseMappedRootKind "read-model-query-input" = pure MappedReadModelQueryInputRoot
parseMappedRootKind "read-model-query-result" = pure MappedReadModelQueryResultRoot
parseMappedRootKind "router-selection-query-input" = pure MappedRouterSelectionQueryInputRoot
parseMappedRootKind "router-selection-predicate" = pure MappedRouterSelectionPredicateRoot
parseMappedRootKind "router-selection-recipient" = pure MappedRouterSelectionRecipientRoot
parseMappedRootKind "router-selection-command-field" = pure MappedRouterSelectionCommandFieldRoot
parseMappedRootKind "projection-event-consumer" = pure MappedProjectionEventRoot
parseMappedRootKind _ = fail "unknown semantic-impact root surface"

mappedConsequenceIdentity :: MappedConsequence -> Text
mappedConsequenceIdentity consequence = case consequence of
  MappedConsumerBuild consumer -> "consumer-build:" <> mappedConsumerIdentity consumer
  MappedPrivateEventHistory aggregate -> "private-event-history:" <> aggregate
  MappedSnapshotHydration aggregate -> "snapshot-hydration:" <> aggregate
  MappedWorkqueueHistory workqueue -> "workqueue-history:" <> workqueue
  MappedQueryApi readModel position -> "query-api:" <> readModel <> ":" <> mappedQueryPositionIdentity position
  MappedRouterSelectionBuild router -> "router-selection-build:" <> router
  MappedRouterSelectionCoordinationReview router -> "router-selection-coordination-review:" <> router
  MappedProjectionHandlerReview consumer -> "projection-handler-review:" <> mappedConsumerIdentity (DerivedProjectionConsumer consumer)
  MappedProjectionRebuild consumer groupName -> "projection-rebuild:" <> mappedConsumerIdentity (DerivedProjectionConsumer consumer) <> ":" <> groupName

-- | Stable expected-fact inventory for the generated service facade. The key
-- contains the surface, typed consumer, declaration, and complete mapped path;
-- the value carries the consequence set, so stale or misattributed evidence is
-- rejected by the existing exact-set conformance package comparison.
mappedSurfaceFactValues :: SemanticImpact -> [(Text, Text)]
mappedSurfaceFactValues impact =
  [ ( T.intercalate
        "/"
        [ "mapped-surface",
          mappedRootKindIdentity (evidenceRootKind evidence),
          mappedConsumerIdentity (evidenceConsumer evidence),
          unMappedKey declaration,
          evidencePath evidence
        ],
      T.intercalate "," (map mappedConsequenceIdentity (Set.toAscList consequences))
        <> maybe "" (";projection-operation:" <>) (evidenceOperation evidence)
    )
  | (declaration, evidenceValues) <- Map.toAscList (impactDeclarationEvidence impact),
    evidence <- Set.toAscList evidenceValues,
    let consequences = Map.findWithDefault Set.empty declaration (impactDeclarationConsequences impact)
  ]

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
    { mappedRootConsumer = ReadModelQueryConsumer readModel MappedQueryInput,
      mappedRootKind = MappedReadModelQueryInputRoot,
      mappedRootUseSite = site,
      mappedRootDeclaration = declaration
    }
mappedRootFromUseSite site@(RootReadModelQueryResult readModel declaration) =
  MappedRoot
    { mappedRootConsumer = ReadModelQueryConsumer readModel MappedQueryResult,
      mappedRootKind = MappedReadModelQueryResultRoot,
      mappedRootUseSite = site,
      mappedRootDeclaration = declaration
    }

eventAuthority :: UsePath -> Maybe Name
eventAuthority UsePath {upRoot = RootEventField aggregate _ _ _} = Just aggregate
eventAuthority _ = Nothing

maybeToList :: Maybe value -> [value]
maybeToList = maybe [] pure
