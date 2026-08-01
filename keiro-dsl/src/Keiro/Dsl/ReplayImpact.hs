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
    replayImpactServices,
    replayImpact,
    renderReplayImpact,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.List (delete, find)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Dsl.AggregateType
import Keiro.Dsl.FoldFingerprint (aggregateFoldSurfaceForService)
import Keiro.Dsl.Grammar
import Keiro.Dsl.NominalType
import Keiro.Dsl.PrettyPrint (renderTransition)
import Keiro.Dsl.SemanticContract (CheckedService (..), legacyCheckedService)
import Keiro.Dsl.TypeGraph (BindingVersion (..), CanonicalTypeId (..), MappedKey (..), QualifiedValueName (..), TypeGraph (..), resolveTypeGraph, wireFingerprint)

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

instance ToJSON AggregateImpact where
  toJSON impact =
    object
      [ "eventTypes" .= Set.toAscList (eventTypes impact),
        "includeSnapshotStreams" .= includeSnapshotStreams impact
      ]

instance ToJSON ReplayImpact where
  toJSON ReplayNeutral = object ["verdict" .= ("replay-neutral" :: Text)]
  toJSON (ReplayAffected aggregates) =
    object
      [ "verdict" .= ("affected" :: Text),
        "aggregates" .= aggregates
      ]

-- | Compute replay impact for every aggregate that existed under the old
-- effective semantic contract.
replayImpactServices :: CheckedService -> CheckedService -> ReplayImpact
replayImpactServices oldService newService =
  case Map.filter hasImpact impacts of
    filtered
      | Map.null filtered -> ReplayNeutral
      | otherwise -> ReplayAffected filtered
  where
    oldSpec = checkedSpec oldService
    newSpec = checkedSpec newService
    oldAggregates = [(aggName aggregate, aggregate) | NAggregate aggregate <- specNodes oldSpec]
    newAggregates = Map.fromList [(aggName aggregate, aggregate) | NAggregate aggregate <- specNodes newSpec]
    impacts =
      Map.fromList
        [ (name, maybe (removedAggregateImpact oldAggregate) (matchedAggregateImpact oldService newService oldAggregate) (Map.lookup name newAggregates))
        | (name, oldAggregate) <- oldAggregates
        ]

-- | Compatibility wrapper for graph-only callers. It explicitly compares both
-- sides under legacy/version-1 runtime semantics.
replayImpact :: Spec -> Spec -> ReplayImpact
replayImpact oldSpec newSpec =
  replayImpactServices (legacyCheckedService oldSpec) (legacyCheckedService newSpec)

hasImpact :: AggregateImpact -> Bool
hasImpact impact =
  not (Set.null (eventTypes impact))
    || includeSnapshotStreams impact

removedAggregateImpact :: Aggregate -> AggregateImpact
removedAggregateImpact aggregate =
  AggregateImpact
    { eventTypes = Set.fromList (evName <$> aggEvents aggregate),
      includeSnapshotStreams = True
    }

matchedAggregateImpact :: CheckedService -> CheckedService -> Aggregate -> Aggregate -> AggregateImpact
matchedAggregateImpact oldService newService oldAggregate newAggregate =
  AggregateImpact
    { eventTypes =
        decodeAffected
          <> transitionAffected
          <> if nonTransitionFoldChanged then oldEventTypes else Set.empty,
      includeSnapshotStreams = transitionFoldChanged || nonTransitionFoldChanged || mappedRegisterChanged
    }
  where
    oldSpec = checkedSpec oldService
    newSpec = checkedSpec newService
    oldEventTypes = Set.fromList (evName <$> aggEvents oldAggregate)
    decodeAffected = decodeSurfaceAffected oldSpec newSpec oldAggregate newAggregate
    mappedRegisterChanged =
      mappedRegisterSurface oldSpec oldAggregate
        /= mappedRegisterSurface newSpec newAggregate
    (transitionAffected, transitionFoldChanged) =
      changedTransitionEvents (aggTransitions oldAggregate) (aggTransitions newAggregate)
    nonTransitionFoldChanged =
      aggregateFoldSurfaceForService oldService oldAggregate
        /= aggregateFoldSurfaceForService
          newService
          newAggregate
            { aggTransitions = aggTransitions oldAggregate
            }

decodeSurfaceAffected :: Spec -> Spec -> Aggregate -> Aggregate -> Set Name
decodeSurfaceAffected oldSpec newSpec oldAggregate newAggregate =
  removedOrChanged <> wireAffected
  where
    newEvents = Map.fromList [(evName event, event) | event <- aggEvents newAggregate]
    removedOrChanged =
      Set.fromList
        [ evName oldEvent
        | oldEvent <- aggEvents oldAggregate,
          maybe True ((/= eventSurface oldSpec oldAggregate oldEvent) . eventSurface newSpec newAggregate) (Map.lookup (evName oldEvent) newEvents)
        ]
    wireAffected
      | aggWire oldAggregate == aggWire newAggregate = Set.empty
      | otherwise = Set.fromList (evName <$> aggEvents oldAggregate)

eventDecodeSurface :: Event -> (EventBody, Int, Maybe (Int, Hole))
eventDecodeSurface event =
  (evBody event, evVersion event, evUpcastFrom event)

eventSurface :: Spec -> Aggregate -> Event -> ((EventBody, Int, Maybe (Int, Hole)), [(Name, Text)])
eventSurface spec aggregate event =
  (eventDecodeSurface event, mappedFieldSurface spec aggregate event)

mappedFieldSurface :: Spec -> Aggregate -> Event -> [(Name, Text)]
mappedFieldSurface spec aggregate event = mapped <> nominal
  where
    mapped = case resolveTypeGraph spec of
      Left _ -> []
      Right graph ->
        [ (aggregateFieldName field, wireFingerprint graph typeName)
        | field <- eventFields aggregate event,
          TRef typeName <- maybeToList (aggregateFieldType field),
          Map.member (MappedKey typeName) (tgDeclarations graph)
        ]
    symbols = aggregateSymbols spec
    nominal =
      [ (aggregateFieldName field, nominalSurface resolved)
      | field <- eventFields aggregate event,
        Right (AggregateNominal resolved) <- [inferAggregateFieldType symbols aggregate EventFieldUse field]
      ]

mappedRegisterSurface :: Spec -> Aggregate -> [(Name, Name, Text)]
mappedRegisterSurface spec aggregate = mapped <> nominal
  where
    mapped = case resolveTypeGraph spec of
      Left _ -> []
      Right graph ->
        [ (regName register, typeName, wireFingerprint graph typeName)
        | register <- aggRegs aggregate,
          TRef typeName <- [regType register],
          Map.member (MappedKey typeName) (tgDeclarations graph)
        ]
    symbols = aggregateSymbols spec
    nominal =
      [ (regName register, resolvedNominalName resolved, nominalSurface resolved)
      | register <- aggRegs aggregate,
        Right (AggregateNominal resolved) <- [resolveAggregateType symbols (regLoc register) RegisterUse (regType register)]
      ]

nominalSurface :: ResolvedNominalType -> Text
nominalSurface nominal =
  nominalRepresentationSurface (resolvedNominalRepresentation nominal)
    <> case resolvedNominalOwnership nominal of
      GeneratedNominal -> "|ownership=generated"
      ConsumerNominal binding ->
        Text.concat
          [ "|ownership=consumer",
            "|canonical=" <> unCanonicalTypeId (consumerNominalCanonical binding),
            "|binding=" <> unQualifiedValueName (consumerNominalBinding binding),
            "|binding-version=" <> unBindingVersion (consumerNominalBindingVersion binding),
            "|initial=" <> maybe "(none)" unQualifiedValueName (consumerNominalInitial binding)
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
eventFields aggregate event = case evBody event of
  EventFields fields -> fields
  EventFromCommand commandName ->
    concat [cmdFields command | command <- aggCommands aggregate, cmdName command == commandName]

maybeToList :: Maybe a -> [a]
maybeToList = maybe [] pure

changedTransitionEvents :: [Transition] -> [Transition] -> (Set Name, Bool)
changedTransitionEvents oldTransitions newTransitions =
  go oldTransitions newTransitions Set.empty False
  where
    go [] _ affected changed = (affected, changed)
    go (oldTransition : remainingOld) remainingNew affected changed =
      case find (sameSurface oldTransition) remainingNew of
        Just exact ->
          go remainingOld (delete exact remainingNew) affected changed
        Nothing ->
          case find (sameIdentity oldTransition) remainingNew of
            Just candidate
              | guardOnlyLoosening oldTransition candidate ->
                  go remainingOld (delete candidate remainingNew) affected changed
              | otherwise ->
                  go
                    remainingOld
                    (delete candidate remainingNew)
                    (affected <> emittedBy oldTransition <> emittedBy candidate)
                    True
            Nothing ->
              go
                remainingOld
                remainingNew
                (affected <> emittedBy oldTransition)
                True

    sameSurface left right = renderTransition left == renderTransition right
    sameIdentity left right =
      tMode left == tMode right
        && tSource left == tSource right
        && tCommand left == tCommand right
    emittedBy = Set.fromList . tEmits

-- | A syntactically provable loosening preserves every old transition match.
--
-- Unknown shapes return 'False', deliberately over-approximating impact. The
-- recognized fragment proves @old => new@ through equality, true/false,
-- conjunction elimination, and disjunction introduction.
guardOnlyLoosening :: Transition -> Transition -> Bool
guardOnlyLoosening oldTransition newTransition =
  oldTransition {tGuard = tGuard newTransition} == newTransition
    && guardImplies (tGuard oldTransition) (tGuard newTransition)

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
          <> Text.intercalate "," (Set.toAscList (eventTypes impact))
          <> "] snapshots="
          <> if includeSnapshotStreams impact then "yes" else "no"
      | (aggregateName, impact) <- Map.toAscList aggregates
      ]
