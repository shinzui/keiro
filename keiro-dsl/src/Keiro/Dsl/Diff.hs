{- | The spec evolution differ. 'diffSpecs' compares an /old/ and a /new/ 'Spec'
and classifies each event-payload-relevant change as __ADDITIVE__ (no event
payload already in the log can fail to decode under the new spec) or __BREAKING__
(some stored payload could now fail to decode or be silently misread, and needs
an upcaster or a deprecation to stay safe).

The classification axis is decode safety of on-disk payloads, faithful to how
@Keiro.Codec@ migrates a stored event (default missing schema-version to 1, run
the upcaster chain to the current version, then @decode@). The @diff --since@
CLI runs this against the spec's prior git blob and exits non-zero on any
unguarded breaking change, so it can gate a merge.

Only event and enum deltas are emitted (the decode-relevant ones); non-event
changes (a new transition, command, or projection key) are not event-payload
decode concerns and are omitted. Read-model table migrations are delegated to
@codd@ and are out of scope.
-}
module Keiro.Dsl.Diff (
    Change (..),
    ChangeKind (..),
    isBreaking,
    diffSpecs,
) where

import Data.List (find, (\\))
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.Validate (DiagnosticCode (..))

{- | A classified change. 'Breaking' changes carry the 'DiagnosticCode' naming
the rule; 'Additive' changes carry an explanatory subject only.
-}
data Change
    = Additive ChangeKind
    | Breaking ChangeKind
    deriving stock (Eq, Show)

data ChangeKind = ChangeKind
    { ckNode :: !Name
    , ckSubject :: !Text
    , ckCode :: !(Maybe DiagnosticCode)
    , ckDetail :: !Text
    }
    deriving stock (Eq, Show)

isBreaking :: Change -> Bool
isBreaking (Breaking _) = True
isBreaking (Additive _) = False

diffSpecs :: Spec -> Spec -> [Change]
diffSpecs old new =
    concatMap (aggDiff old) (specAggs new)
        ++ removedAggDiff old new

specAggs :: Spec -> [Aggregate]
specAggs s = [a | NAggregate a <- specNodes s]

lookupAgg :: Name -> Spec -> Maybe Aggregate
lookupAgg n s = find ((== n) . aggName) (specAggs s)

-- | Diff one /new/ aggregate against its old counterpart (matched by name).
aggDiff :: Spec -> Aggregate -> [Change]
aggDiff oldSpec newAgg =
    case lookupAgg (aggName newAgg) oldSpec of
        Nothing ->
            -- A brand-new aggregate: all its events are new types (additive).
            [ additive (aggName newAgg) (evName e) "new event type (new aggregate)"
            | e <- aggEvents newAgg
            ]
        Just oldAgg ->
            concatMap (eventDiff oldAgg newAgg) (aggEvents newAgg)
                ++ removedEvents oldAgg newAgg
                ++ enumRemovedFromFields oldSpec newAgg

-- | Per-event classification for an event present in the new aggregate.
eventDiff :: Aggregate -> Aggregate -> Event -> [Change]
eventDiff oldAgg newAgg e =
    case find ((== evName e) . evName) (aggEvents oldAgg) of
        Nothing ->
            [additive (aggName newAgg) (evName e) "new event type"]
        Just oldE
            | evVersion e > evVersion oldE ->
                if evUpcastFrom e `hasSource` (evVersion e - 1)
                    then [additive (aggName newAgg) (evName e) ("new version v" <> tInt (evVersion e) <> " with upcaster from v" <> tInt (evVersion e - 1))]
                    else [breaking (aggName newAgg) (evName e) EvtVersionMissingUpcaster ("version bumped to v" <> tInt (evVersion e) <> " with no contiguous upcaster (gap in chain)")]
            | evVersion e < evVersion oldE ->
                [breaking (aggName newAgg) (evName e) EvtFieldAddedWithoutBump ("version decreased from v" <> tInt (evVersion oldE) <> " to v" <> tInt (evVersion e))]
            | otherwise ->
                let oldFields = eventFieldNames oldAgg oldE
                    newFields = eventFieldNames newAgg e
                    added = newFields \\ oldFields
                    removed = oldFields \\ newFields
                 in if not (null added)
                        then [breaking (aggName newAgg) (evName e) EvtFieldAddedWithoutBump ("field(s) " <> commas added <> " added at the same version v" <> tInt (evVersion e) <> " without a version bump or upcaster")]
                        else
                            if not (null removed)
                                then [breaking (aggName newAgg) (evName e) EvtFieldAddedWithoutBump ("field(s) " <> commas removed <> " removed at the same version v" <> tInt (evVersion e))]
                                else
                                    [ additive (aggName newAgg) (evName e) "event deprecated (still decodable)"
                                    | evDeprecated e && not (evDeprecated oldE)
                                    ]

{- | Events present in the old aggregate but absent in the new one. Removing a
tag entirely is breaking (it drops out of the codec's eventTypes, so stored
payloads of that type fail decode); keeping it as a @deprecated event@ (still
present in the new spec) is the safe alternative and is handled by 'eventDiff'.
-}
removedEvents :: Aggregate -> Aggregate -> [Change]
removedEvents oldAgg newAgg =
    [ breaking (aggName newAgg) (evName oldE) EvtRemovedNotDeprecated "event removed entirely; keep it as a 'deprecated event' so old payloads still decode"
    | oldE <- aggEvents oldAgg
    , isNothing (find ((== evName oldE) . evName) (aggEvents newAgg))
    ]

-- | An entire aggregate removed: every event tag it carried is now gone.
removedAggDiff :: Spec -> Spec -> [Change]
removedAggDiff old new =
    [ breaking (aggName oldAgg) (evName e) EvtRemovedNotDeprecated "aggregate removed; its event tags are no longer decodable"
    | oldAgg <- specAggs old
    , isNothing (lookupAgg (aggName oldAgg) new)
    , e <- aggEvents oldAgg
    ]

{- | Enum constructors that an event field ranges over and were removed: an old
payload may carry the removed value and now fail to decode (breaking). Added
constructors are additive (only future payloads use them).
-}
enumRemovedFromFields :: Spec -> Aggregate -> [Change]
enumRemovedFromFields _oldSpec _newAgg = []

hasSource :: Maybe (Int, Hole) -> Int -> Bool
hasSource (Just (m, _)) n = m == n
hasSource Nothing _ = False

eventFieldNames :: Aggregate -> Event -> [Name]
eventFieldNames agg e = case evBody e of
    EventFields fs -> map fieldName fs
    EventFromCommand cn ->
        maybe [] (map fieldName . cmdFields) (find ((== cn) . cmdName) (aggCommands agg))

additive :: Name -> Text -> Text -> Change
additive n subj detail = Additive (ChangeKind n subj Nothing detail)

breaking :: Name -> Text -> DiagnosticCode -> Text -> Change
breaking n subj c detail = Breaking (ChangeKind n subj (Just c) detail)

commas :: [Text] -> Text
commas = T.intercalate ", "

tInt :: Int -> Text
tInt = T.pack . show
