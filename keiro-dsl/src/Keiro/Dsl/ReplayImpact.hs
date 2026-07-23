{- | Stored-data replay impact for a specification diff.

The ordinary differ classifies compatibility across every persisted surface.
This module answers a narrower deployment question: can the candidate binary
interpret an already-stored aggregate log differently?

The result is deliberately conservative. New aggregates, events, and
transitions are replay-neutral because no old log depends on them. A removed
or changed old transition affects the event types emitted by either side, and
a decode-surface change affects that event type directly. Snapshot-bearing
streams are included whenever the fold itself can change.
-}
module Keiro.Dsl.ReplayImpact (
    AggregateImpact (..),
    ReplayImpact (..),
    replayImpact,
    renderReplayImpact,
) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.List (delete, find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Dsl.FoldFingerprint (aggregateFoldSurface)
import Keiro.Dsl.Grammar
import Keiro.Dsl.PrettyPrint (renderTransition)

-- | The smallest conservative audit input for one aggregate.
data AggregateImpact = AggregateImpact
    { eventTypes :: !(Set Name)
    , includeSnapshotStreams :: !Bool
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
            [ "eventTypes" .= Set.toAscList (eventTypes impact)
            , "includeSnapshotStreams" .= includeSnapshotStreams impact
            ]

instance ToJSON ReplayImpact where
    toJSON ReplayNeutral = object ["verdict" .= ("replay-neutral" :: Text)]
    toJSON (ReplayAffected aggregates) =
        object
            [ "verdict" .= ("affected" :: Text)
            , "aggregates" .= aggregates
            ]

-- | Compute replay impact for every aggregate that existed in the old spec.
replayImpact :: Spec -> Spec -> ReplayImpact
replayImpact oldSpec newSpec =
    case Map.filter hasImpact impacts of
        filtered
            | Map.null filtered -> ReplayNeutral
            | otherwise -> ReplayAffected filtered
  where
    oldAggregates = [(aggName aggregate, aggregate) | NAggregate aggregate <- specNodes oldSpec]
    newAggregates = Map.fromList [(aggName aggregate, aggregate) | NAggregate aggregate <- specNodes newSpec]
    impacts =
        Map.fromList
            [ (name, maybe (removedAggregateImpact oldAggregate) (matchedAggregateImpact oldSpec newSpec oldAggregate) (Map.lookup name newAggregates))
            | (name, oldAggregate) <- oldAggregates
            ]

hasImpact :: AggregateImpact -> Bool
hasImpact impact =
    not (Set.null (eventTypes impact))
        || includeSnapshotStreams impact

removedAggregateImpact :: Aggregate -> AggregateImpact
removedAggregateImpact aggregate =
    AggregateImpact
        { eventTypes = Set.fromList (evName <$> aggEvents aggregate)
        , includeSnapshotStreams = True
        }

matchedAggregateImpact :: Spec -> Spec -> Aggregate -> Aggregate -> AggregateImpact
matchedAggregateImpact oldSpec newSpec oldAggregate newAggregate =
    AggregateImpact
        { eventTypes =
            decodeAffected
                <> transitionAffected
                <> if nonTransitionFoldChanged then oldEventTypes else Set.empty
        , includeSnapshotStreams = transitionFoldChanged || nonTransitionFoldChanged
        }
  where
    oldEventTypes = Set.fromList (evName <$> aggEvents oldAggregate)
    decodeAffected = decodeSurfaceAffected oldAggregate newAggregate
    (transitionAffected, transitionFoldChanged) =
        changedTransitionEvents (aggTransitions oldAggregate) (aggTransitions newAggregate)
    nonTransitionFoldChanged =
        aggregateFoldSurface oldSpec oldAggregate
            /= aggregateFoldSurface
                newSpec
                newAggregate
                    { aggTransitions = aggTransitions oldAggregate
                    }

decodeSurfaceAffected :: Aggregate -> Aggregate -> Set Name
decodeSurfaceAffected oldAggregate newAggregate =
    removedOrChanged <> wireAffected
  where
    newEvents = Map.fromList [(evName event, event) | event <- aggEvents newAggregate]
    removedOrChanged =
        Set.fromList
            [ evName oldEvent
            | oldEvent <- aggEvents oldAggregate
            , maybe True ((/= eventDecodeSurface oldEvent) . eventDecodeSurface) (Map.lookup (evName oldEvent) newEvents)
            ]
    wireAffected
        | aggWire oldAggregate == aggWire newAggregate = Set.empty
        | otherwise = Set.fromList (evName <$> aggEvents oldAggregate)

eventDecodeSurface :: Event -> (EventBody, Int, Maybe (Int, Hole))
eventDecodeSurface event =
    (evBody event, evVersion event, evUpcastFrom event)

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

{- | A syntactically provable loosening preserves every old transition match.

Unknown shapes return 'False', deliberately over-approximating impact. The
recognized fragment proves @old => new@ through equality, true/false,
conjunction elimination, and disjunction introduction.
-}
guardOnlyLoosening :: Transition -> Transition -> Bool
guardOnlyLoosening oldTransition newTransition =
    oldTransition{tGuard = tGuard newTransition} == newTransition
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
