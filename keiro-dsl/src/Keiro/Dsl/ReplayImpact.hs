-- | Stored-data replay impact for a specification diff.
--
-- The ordinary differ classifies compatibility across every persisted surface.
-- This module answers a narrower deployment question: can the candidate binary
-- interpret an already-stored aggregate log differently?
--
-- The result is deliberately conservative. New aggregates, events, and
-- transitions are replay-neutral because no old log depends on them. A removed
-- or changed old transition affects the event types emitted by either side, and
-- a decode-surface change affects that event type directly. Snapshot-bearing
-- streams are included whenever the fold itself can change.
module Keiro.Dsl.ReplayImpact
  ( AggregateImpact (..),
    ReplayImpact (..),
    CatalogReplayImpact (..),
    replayImpactServices,
    catalogReplayImpactServices,
    renderReplayImpact,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Foldable (traverse_)
import Data.List (delete, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Dsl.AggregateType
import Keiro.Dsl.CanonicalEncoding (canonicalExpr, canonicalTransition)
import Keiro.Dsl.FieldIdentity (ResolvedFieldIdentity (..), resolveAggregateFieldIdentity)
import Keiro.Dsl.FoldFingerprint (FoldSurfaceError, aggregateFoldSurfaceForService)
import Keiro.Dsl.Grammar
import Keiro.Dsl.NominalType
import Keiro.Dsl.ProjectionMappedImpact qualified as ProjectionImpact
import Keiro.Dsl.SemanticContract (CheckedService, checkedSpec, checkedTypeGraph)
import Keiro.Dsl.SemanticImpact (semanticImpact)
import Keiro.Dsl.TypeGraph (BindingVersion (..), CanonicalTypeId (..), DerivedMappedConsumer (..), MappedKey (..), QualifiedValueName (..), TypeGraph (..), TypeGraphError, wireFingerprint)

-- | The smallest conservative audit input for one aggregate.
data AggregateImpact = AggregateImpact
  { eventTypes :: !(Set Name),
    includeSnapshotStreams :: !Bool
  }
  deriving stock (Eq, Show)

-- | A deploy either preserves replay or carries per-aggregate audit inputs.
data ReplayImpact
  = ReplayNeutral
  | ReplayAffected !(Map Name AggregateImpact)
  deriving stock (Eq, Show)

-- | Projection-catalog replay impact is reported beside aggregate-fold impact
-- so existing aggregate audit consumers retain their released JSON shape.
data CatalogReplayImpact
  = CatalogReplayNeutral
  | CatalogReplayAffected
      { affectedGroups :: !(Set Name),
        affectedTargets :: !(Set Name),
        affectedSources :: !(Set Text),
        affectedAdapters :: !(Set Name),
        invalidatesRunningFingerprint :: !Bool
      }
  deriving stock (Eq, Show)

instance ToJSON AggregateImpact where
  toJSON impact =
    object
      [ "eventTypes" .= Set.toAscList ((.eventTypes) impact),
        "includeSnapshotStreams" .= (.includeSnapshotStreams) impact
      ]

instance ToJSON ReplayImpact where
  toJSON ReplayNeutral = object ["verdict" .= ("replay-neutral" :: Text)]
  toJSON (ReplayAffected aggregates) =
    object
      [ "verdict" .= ("affected" :: Text),
        "aggregates" .= aggregates
      ]

instance ToJSON CatalogReplayImpact where
  toJSON CatalogReplayNeutral = object ["verdict" .= ("catalog-replay-neutral" :: Text)]
  toJSON impact@CatalogReplayAffected {} =
    object
      [ "verdict" .= ("catalog-replay-affected" :: Text),
        "groups" .= Set.toAscList ((.affectedGroups) impact),
        "targets" .= Set.toAscList ((.affectedTargets) impact),
        "sources" .= Set.toAscList ((.affectedSources) impact),
        "adapters" .= Set.toAscList ((.affectedAdapters) impact),
        "invalidatesRunningFingerprint" .= (.invalidatesRunningFingerprint) impact
      ]

catalogReplayImpactServices :: CheckedService -> CheckedService -> CatalogReplayImpact
catalogReplayImpactServices oldService newService
  | Set.null groups && Set.null targets && Set.null sources && Set.null adapters = CatalogReplayNeutral
  | otherwise =
      CatalogReplayAffected
        { affectedGroups = groups,
          affectedTargets = targets,
          affectedSources = sources,
          affectedAdapters = adapters,
          invalidatesRunningFingerprint = True
        }
  where
    oldSpec = checkedSpec oldService
    newSpec = checkedSpec newService
    oldTargets = Map.fromList [((.name) target, target) | NProjectionTarget target <- (.nodes) oldSpec]
    newTargets = Map.fromList [((.name) target, target) | NProjectionTarget target <- (.nodes) newSpec]
    oldGroups = Map.fromList [((.name) groupNode, groupNode) | NRebuildGroup groupNode <- (.nodes) oldSpec]
    newGroups = Map.fromList [((.name) groupNode, groupNode) | NRebuildGroup groupNode <- (.nodes) newSpec]
    oldOwners = Map.fromList [((.name) owner, owner) | NProjectionOwner owner <- (.nodes) oldSpec]
    newOwners = Map.fromList [((.name) owner, owner) | NProjectionOwner owner <- (.nodes) newSpec]
    changedTargetNames = changedKeys oldTargets newTargets
    changedGroupNames = changedKeys oldGroups newGroups
    changedOwnerNames = changedKeys oldOwners newOwners
    changedOwners = mapMaybe (`Map.lookup` oldOwners) (Set.toList changedOwnerNames) <> mapMaybe (`Map.lookup` newOwners) (Set.toList changedOwnerNames)
    changedGroups = mapMaybe (`Map.lookup` oldGroups) (Set.toList changedGroupNames) <> mapMaybe (`Map.lookup` newGroups) (Set.toList changedGroupNames)
    groups = changedGroupNames <> Set.fromList (map (.group) changedOwners) <> groupsContainingChangedTargets <> inheritedGroups
    targets = changedTargetNames <> Set.fromList (concatMap (.targets) changedOwners <> concatMap (.targets) changedGroups) <> inheritedTargets
    sources = Set.fromList (map renderSource (concatMap (.sources) changedOwners)) <> inheritedSources
    adapters = changedOwnerNames <> inheritedAdapters
    groupsContainingChangedTargets =
      Set.fromList
        [ (.name) groupNode
        | groupNode <- Map.elems oldGroups <> Map.elems newGroups,
          any (`Set.member` changedTargetNames) ((.targets) groupNode)
        ]
    changedKeys oldMap newMap =
      Set.fromList
        [ key
        | key <- Set.toList (Map.keysSet oldMap <> Map.keysSet newMap),
          Map.lookup key oldMap /= Map.lookup key newMap
        ]
    renderSource CatalogAll = "all"
    renderSource (CatalogCategory categoryName) = "category:" <> categoryName
    renderSource (CatalogAggregate aggregateName) = "aggregate:" <> aggregateName

    -- A mapped wire change below an aggregate event changes the generated
    -- aggregate-source fingerprint even when the catalog declarations are
    -- byte-identical. Only explicitly replayable aggregate owners invalidate
    -- catalog replay state; live-only owners remain operationally visible in
    -- projection reporting but are excluded from this replay audit.
    (inheritedGroups, inheritedTargets, inheritedSources, inheritedAdapters) =
      foldMap mappedSourceImpact changedMappedCatalogConsumers
    changedMappedCatalogConsumers =
      [ (derived, oldOperation, newOperation)
      | derived@CatalogProjectionConsumer {} <- Set.toAscList (Map.keysSet oldMappedOperations <> Map.keysSet newMappedOperations),
        let oldOperation = Map.lookup derived oldMappedOperations,
        let newOperation = Map.lookup derived newMappedOperations,
        operationFingerprint oldOperation /= operationFingerprint newOperation,
        maybe False operationReplayable oldOperation || maybe False operationReplayable newOperation
      ]
    oldMappedOperations = maybe Map.empty (.operations) (projectionImpactFor oldService)
    newMappedOperations = maybe Map.empty (.operations) (projectionImpactFor newService)
    projectionImpactFor service = case checkedTypeGraph service of
      Left _ -> Nothing
      Right graph -> Just (ProjectionImpact.projectionMappedImpact service (semanticImpact graph))
    operationFingerprint = fmap (\(ProjectionImpact.ProjectionOperationalImpact _ _ _ _ _ fingerprint) -> fingerprint)
    operationReplayable (ProjectionImpact.ProjectionOperationalImpact _ _ _ _ canReplay _) = canReplay
    mappedSourceImpact
      ( CatalogProjectionConsumer owner aggregate,
        oldOperation,
        newOperation
        ) =
        ( groupsFor oldOperation <> groupsFor newOperation,
          targetsFor oldOperation <> targetsFor newOperation,
          Set.singleton ("aggregate:" <> aggregate),
          Set.singleton owner
        )
    mappedSourceImpact (AggregateInlineProjectionConsumer {}, _, _) = mempty
    groupsFor = maybe Set.empty (maybe Set.empty Set.singleton . operationGroup)
    targetsFor = maybe Set.empty operationTargets
    operationGroup (ProjectionImpact.ProjectionOperationalImpact _ groupName _ _ _ _) = groupName
    operationTargets (ProjectionImpact.ProjectionOperationalImpact _ _ targetNames _ _ _) = targetNames

-- | Compute replay impact for every aggregate that existed under the old
-- effective semantic contract.
replayImpactServices :: CheckedService -> CheckedService -> Either FoldSurfaceError ReplayImpact
replayImpactServices oldService newService = do
  traverse_ (aggregateFoldSurfaceForService oldService . snd) oldAggregates
  traverse_ (aggregateFoldSurfaceForService newService . snd) (Map.toList newAggregates)
  resolvedImpacts <-
    traverse
      (\(name, oldAggregate) -> fmap ((,) name) (maybe (pure (removedAggregateImpact oldAggregate)) (matchedAggregateImpact oldService newService oldContext newContext oldAggregate) (Map.lookup name newAggregates)))
      oldAggregates
  pure $ case Map.filter hasImpact (Map.fromList resolvedImpacts) of
    filtered
      | Map.null filtered -> ReplayNeutral
      | otherwise -> ReplayAffected filtered
  where
    oldSpec = checkedSpec oldService
    newSpec = checkedSpec newService
    oldGraphResult = checkedTypeGraph oldService
    newGraphResult = checkedTypeGraph newService
    oldSymbols = aggregateSymbolsFromGraphResult oldGraphResult oldSpec
    newSymbols = aggregateSymbolsFromGraphResult newGraphResult newSpec
    oldContext = ReplaySurfaceContext oldSpec oldGraphResult oldSymbols
    newContext = ReplaySurfaceContext newSpec newGraphResult newSymbols
    oldAggregates = [((.name) aggregate, aggregate) | NAggregate aggregate <- (.nodes) ((.spec) oldContext)]
    newAggregates = Map.fromList [((.name) aggregate, aggregate) | NAggregate aggregate <- (.nodes) ((.spec) newContext)]

data ReplaySurfaceContext = ReplaySurfaceContext
  { spec :: !Spec,
    graphResult :: Either (NE.NonEmpty TypeGraphError) TypeGraph,
    symbols :: AggregateSymbols
  }

hasImpact :: AggregateImpact -> Bool
hasImpact impact =
  not (Set.null ((.eventTypes) impact))
    || (.includeSnapshotStreams) impact

removedAggregateImpact :: Aggregate -> AggregateImpact
removedAggregateImpact aggregate =
  AggregateImpact
    { eventTypes = Set.fromList ((.name) <$> (.events) aggregate),
      includeSnapshotStreams = True
    }

matchedAggregateImpact :: CheckedService -> CheckedService -> ReplaySurfaceContext -> ReplaySurfaceContext -> Aggregate -> Aggregate -> Either FoldSurfaceError AggregateImpact
matchedAggregateImpact oldService newService oldContext newContext oldAggregate newAggregate = do
  oldSurface <- aggregateFoldSurfaceForService oldService oldAggregate
  newNonTransitionSurface <-
    aggregateFoldSurfaceForService
      newService
      (replaceAggregateTransitions oldAggregate.transitions newAggregate)
  let nonTransitionFoldChanged = oldSurface /= newNonTransitionSurface
  pure
    AggregateImpact
      { eventTypes =
          decodeAffected
            <> transitionAffected
            <> if nonTransitionFoldChanged then oldEventTypes else Set.empty,
        includeSnapshotStreams = transitionFoldChanged || nonTransitionFoldChanged || mappedRegisterChanged
      }
  where
    oldEventTypes = Set.fromList ((.name) <$> (.events) oldAggregate)
    decodeAffected = decodeSurfaceAffected oldContext newContext oldAggregate newAggregate
    mappedRegisterChanged =
      mappedRegisterSurface oldContext oldAggregate
        /= mappedRegisterSurface newContext newAggregate
    (transitionAffected, transitionFoldChanged) =
      changedTransitionEvents ((.transitions) oldAggregate) ((.transitions) newAggregate)

decodeSurfaceAffected :: ReplaySurfaceContext -> ReplaySurfaceContext -> Aggregate -> Aggregate -> Set Name
decodeSurfaceAffected oldContext newContext oldAggregate newAggregate =
  removedOrChanged <> wireAffected
  where
    newEvents = Map.fromList [((.name) event, event) | event <- (.events) newAggregate]
    removedOrChanged =
      Set.fromList
        [ (.name) oldEvent
        | oldEvent <- (.events) oldAggregate,
          maybe True ((/= eventSurface oldContext oldAggregate oldEvent) . eventSurface newContext newAggregate) (Map.lookup ((.name) oldEvent) newEvents)
        ]
    wireAffected
      | (.wire) oldAggregate == (.wire) newAggregate = Set.empty
      | otherwise = Set.fromList ((.name) <$> (.events) oldAggregate)

eventDecodeSurface :: Aggregate -> Event -> (Int, Maybe (Int, Hole), [(Name, Text, Maybe TypeExpr)])
eventDecodeSurface aggregate event =
  ( (.version) event,
    (.upcastFrom) event,
    [ ((.dslName) identity, (.wireKey) identity, (.valueType) field)
    | field <- eventFields aggregate event,
      let identity = resolveAggregateFieldIdentity field
    ]
  )

eventSurface :: ReplaySurfaceContext -> Aggregate -> Event -> ((Int, Maybe (Int, Hole), [(Name, Text, Maybe TypeExpr)]), [(Name, Text)])
eventSurface context aggregate event =
  (eventDecodeSurface aggregate event, mappedFieldSurface context aggregate event)

mappedFieldSurface :: ReplaySurfaceContext -> Aggregate -> Event -> [(Name, Text)]
mappedFieldSurface context aggregate event = mapped <> nominal
  where
    mapped = case (.graphResult) context of
      Left _ -> []
      Right graph ->
        [ ((.name) field, wireFingerprint graph typeName)
        | field <- eventFields aggregate event,
          TRef typeName <- maybeToList ((.valueType) field),
          Map.member (MappedKey typeName) ((.declarations) graph)
        ]
    symbols = (.symbols) context
    nominal =
      [ ((.name) field, nominalSurface resolved)
      | field <- eventFields aggregate event,
        Right (AggregateNominal resolved) <- [inferAggregateFieldType symbols aggregate EventFieldUse field]
      ]

mappedRegisterSurface :: ReplaySurfaceContext -> Aggregate -> [(Name, Name, Text)]
mappedRegisterSurface context aggregate = mapped <> nominal
  where
    mapped = case (.graphResult) context of
      Left _ -> []
      Right graph ->
        [ ((.name) register, typeName, wireFingerprint graph typeName)
        | register <- (.regs) aggregate,
          TRef typeName <- [(.valueType) register],
          Map.member (MappedKey typeName) ((.declarations) graph)
        ]
    symbols = (.symbols) context
    nominal =
      [ ((.name) register, (.name) resolved, nominalSurface resolved)
      | register <- (.regs) aggregate,
        Right (AggregateNominal resolved) <- [resolveAggregateType symbols ((.loc) register) RegisterUse ((.valueType) register)]
      ]

nominalSurface :: ResolvedNominalType -> Text
nominalSurface nominal =
  nominalRepresentationSurface ((.representation) nominal)
    <> case (.ownership) nominal of
      GeneratedNominal -> "|ownership=generated"
      ConsumerNominal binding ->
        Text.concat
          [ "|ownership=consumer",
            "|canonical=" <> (.unCanonicalTypeId) ((.canonical) binding),
            "|binding=" <> (.unQualifiedValueName) ((.binding) binding),
            "|binding-version=" <> (.unBindingVersion) ((.bindingVersion) binding),
            "|initial=" <> maybe "(none)" (.unQualifiedValueName) ((.initial) binding)
          ]

nominalRepresentationSurface :: NominalRepresentation -> Text
nominalRepresentationSurface representation = case representation of
  IdRepresentation prefix -> "id:" <> prefix
  EnumRepresentation constructors -> "enum:" <> Text.intercalate "," [constructor <> "=" <> wire | (constructor, wire) <- NE.toList constructors]
  ScalarRepresentation scalar -> case scalar of
    NominalText -> "scalar:Text"
    NominalInt -> "scalar:Int"
    NominalNatural -> "scalar:Natural"
    NominalBool -> "scalar:Bool"
    NominalTime -> "scalar:Time"

eventFields :: Aggregate -> Event -> [AggregateField]
eventFields aggregate event = case (.body) event of
  EventFields fields -> fields
  EventFromCommand commandName ->
    concat [(.fields) command | command <- (.commands) aggregate, (.name) command == commandName]

maybeToList :: Maybe a -> [a]
maybeToList = maybe [] pure

changedTransitionEvents :: [Transition] -> [Transition] -> (Set Name, Bool)
changedTransitionEvents oldTransitions newTransitions =
  foldl'
    (\(affected, changed) key -> let (groupAffected, groupChanged) = compareGroup key in (affected <> groupAffected, changed || groupChanged))
    (Set.empty, False)
    (Set.toAscList allKeys)
  where
    oldGroups = transitionGroups oldTransitions
    newGroups = transitionGroups newTransitions
    allKeys = Map.keysSet oldGroups <> Map.keysSet newGroups
    compareGroup key =
      let (afterExactOld, afterExactNew) = cancelExact (Map.findWithDefault [] key oldGroups) (Map.findWithDefault [] key newGroups)
          (remainingOld, remainingNew) = cancelLoosenings afterExactOld afterExactNew
          sortedOld = sortOn transitionSortKey remainingOld
          sortedNew = sortOn transitionSortKey remainingNew
          (pairedOld, unpairedOld) = splitAt (length sortedNew) sortedOld
          pairedNew = take (length pairedOld) sortedNew
          pairedEvents = Set.unions [emittedBy old <> emittedBy new | (old, new) <- zip pairedOld pairedNew]
          removedEvents = Set.unions (map emittedBy unpairedOld)
          changed = not (null pairedOld) || not (null unpairedOld)
       in (pairedEvents <> removedEvents, changed)

    transitionGroups =
      Map.fromListWith (<>)
        . map (\transition -> (transitionIdentity transition, [transition]))
    transitionIdentity transition =
      ( modeKey ((.mode) transition),
        (.source) transition,
        (.command) transition
      )
    modeKey TmLive = "live" :: Text
    modeKey TmReplayOnly = "replay-only"
    transitionSortKey transition =
      (maybe "" canonicalExpr ((.guard) transition), canonicalTransition transition)
    emittedBy = Set.fromList . (.emits)

-- | Remove byte-identical transitions as a multiset. Sorting makes duplicate
-- cancellation independent of declaration order.
cancelExact :: [Transition] -> [Transition] -> ([Transition], [Transition])
cancelExact oldTransitions newTransitions = go sortedOld sortedNew [] []
  where
    sortedOld = sortOn canonicalTransition oldTransitions
    sortedNew = sortOn canonicalTransition newTransitions
    go [] remainingNew unmatchedOld unmatchedNew = (reverse unmatchedOld, reverse unmatchedNew <> remainingNew)
    go remainingOld [] unmatchedOld unmatchedNew = (reverse unmatchedOld <> remainingOld, reverse unmatchedNew)
    go old@(oldTransition : remainingOld) new@(newTransition : remainingNew) unmatchedOld unmatchedNew =
      case compare (canonicalTransition oldTransition) (canonicalTransition newTransition) of
        LT -> go remainingOld new (oldTransition : unmatchedOld) unmatchedNew
        EQ -> go remainingOld remainingNew unmatchedOld unmatchedNew
        GT -> go old remainingNew unmatchedOld (newTransition : unmatchedNew)

-- | Deterministically cancel every provable guard-only loosening. At each step
-- the lexicographically smallest canonical pair wins, so ambiguous siblings do
-- not inherit declaration-order semantics.
cancelLoosenings :: [Transition] -> [Transition] -> ([Transition], [Transition])
cancelLoosenings oldTransitions newTransitions =
  case sortOn looseningPairKey candidates of
    [] -> (oldTransitions, newTransitions)
    (oldTransition, newTransition) : _ ->
      cancelLoosenings (delete oldTransition oldTransitions) (delete newTransition newTransitions)
  where
    candidates =
      [ (oldTransition, newTransition)
      | oldTransition <- oldTransitions,
        newTransition <- newTransitions,
        guardOnlyLoosening oldTransition newTransition
      ]
    looseningPairKey (oldTransition, newTransition) =
      ( maybe "" canonicalExpr ((.guard) oldTransition),
        canonicalTransition oldTransition,
        maybe "" canonicalExpr ((.guard) newTransition),
        canonicalTransition newTransition
      )

-- | A syntactically provable loosening preserves every old transition match.
--
-- Unknown shapes return 'False', deliberately over-approximating impact. The
-- recognized fragment proves @old => new@ through equality, true/false,
-- conjunction elimination, and disjunction introduction.
guardOnlyLoosening :: Transition -> Transition -> Bool
guardOnlyLoosening oldTransition newTransition =
  replaceTransitionGuard newTransition.guard oldTransition == newTransition
    && guardImplies oldTransition.guard newTransition.guard

replaceAggregateTransitions :: [Transition] -> Aggregate -> Aggregate
replaceAggregateTransitions transitions aggregate =
  Aggregate
    { name = aggregate.name,
      regs = aggregate.regs,
      states = aggregate.states,
      commands = aggregate.commands,
      events = aggregate.events,
      transitions,
      domainOutcomeTypes = aggregate.domainOutcomeTypes,
      domainOutcomeDuplicateLocs = aggregate.domainOutcomeDuplicateLocs,
      wire = aggregate.wire,
      projection = aggregate.projection,
      snapshot = aggregate.snapshot,
      loc = aggregate.loc
    }

replaceTransitionGuard :: Maybe Expr -> Transition -> Transition
replaceTransitionGuard guard transition =
  Transition
    { source = transition.source,
      command = transition.command,
      implementation = transition.implementation,
      guard,
      writes = transition.writes,
      emits = transition.emits,
      outcome = transition.outcome,
      outcomeDuplicateLocs = transition.outcomeDuplicateLocs,
      goto = transition.goto,
      mode = transition.mode,
      loc = transition.loc
    }

guardImplies :: Maybe Expr -> Maybe Expr -> Bool
guardImplies _ Nothing = True
guardImplies Nothing (Just _) = False
guardImplies (Just oldGuard) (Just newGuard) = implies oldGuard newGuard
  where
    implies old new
      | old == new = True
    implies (EAtom (ABool False)) _ = True
    implies _ (EAtom (ABool True)) = True
    implies (EAnd left right) new = implies left new || implies right new
    implies old (EOr left right) = implies old left || implies old right
    implies _ _ = False

renderReplayImpact :: ReplayImpact -> Text
renderReplayImpact ReplayNeutral =
  "replay-neutral: stored-data replay is unchanged by this diff"
renderReplayImpact (ReplayAffected aggregates) =
  "replay-affected: run the candidate binary's targeted replay audit for "
    <> Text.intercalate
      "; "
      [ aggregateName
          <> " events=["
          <> Text.intercalate "," (Set.toAscList ((.eventTypes) impact))
          <> "] snapshots="
          <> if (.includeSnapshotStreams) impact then "yes" else "no"
      | (aggregateName, impact) <- Map.toAscList aggregates
      ]
