-- | Deterministic, declaration-order-independent transition family comparison.
module Keiro.Dsl.TransitionFamily
  ( TransitionFamilyKey (..),
    TransitionFamilyDelta (..),
    ReplayBodyKey (..),
    ReplayBodyStatus (..),
    ReplayBodyDelta (..),
    transitionFamilyDeltas,
    replayBodyKey,
    replayBodyDeltas,
    guardAlternatives,
    guardUnion,
    guardImplies,
    unionPreserved,
  )
where

import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Dsl.CanonicalEncoding (canonicalExpr, canonicalTransition)
import Keiro.Dsl.Grammar
  ( Atom (..),
    Expr (..),
    Name,
    ScalarLiteral (..),
    Transition (..),
    TransitionMode (..),
    noLoc,
  )

-- | The structural identity shared by ordinary diff and replay-impact analysis.
data TransitionFamilyKey = TransitionFamilyKey
  { familyMode :: !TransitionMode,
    familySource :: !Name,
    familyCommand :: !Name
  }
  deriving stock (Eq, Show)

instance Ord TransitionFamilyKey where
  compare left right =
    compare
      (modeRank ((.familyMode) left), (.familySource) left, (.familyCommand) left)
      (modeRank ((.familyMode) right), (.familySource) right, (.familyCommand) right)

-- | The exact old and new remainders after duplicate-aware cancellation.
data TransitionFamilyDelta = TransitionFamilyDelta
  { familyKey :: !TransitionFamilyKey,
    oldRemainder :: ![Transition],
    newRemainder :: ![Transition]
  }
  deriving stock (Eq, Show)

-- | Frozen replay behavior within one family, excluding guard, mode, location,
-- and forward-only outcomes.
newtype ReplayBodyKey = ReplayBodyKey {unReplayBodyKey :: Text}
  deriving stock (Eq, Ord, Show)

-- | Directional classification of the complete old and new guard unions for
-- one replay body.
data ReplayBodyStatus
  = ReplayBodyPreserved
  | ReplayBodyChanged
  | ReplayBodyRemoved
  | ReplayBodyAdded
  deriving stock (Eq, Ord, Show)

-- | One affected replay body. Presence is represented by the member lists;
-- within a present body, an absent guard means the Boolean constant true.
data ReplayBodyDelta = ReplayBodyDelta
  { bodyFamilyKey :: !TransitionFamilyKey,
    bodyKey :: !ReplayBodyKey,
    oldBodyMembers :: ![Transition],
    newBodyMembers :: ![Transition],
    bodyStatus :: !ReplayBodyStatus
  }
  deriving stock (Eq, Show)

-- | Partition transitions into ordered families and cancel exact canonical
-- matches as a multiset. Fully cancelled families remain in the result.
transitionFamilyDeltas :: [Transition] -> [Transition] -> [TransitionFamilyDelta]
transitionFamilyDeltas oldTransitions newTransitions =
  [ let (oldRemainder, newRemainder) =
          cancelExact
            (Map.findWithDefault [] key oldFamilies)
            (Map.findWithDefault [] key newFamilies)
     in TransitionFamilyDelta {familyKey = key, oldRemainder, newRemainder}
  | key <- Set.toAscList (Map.keysSet oldFamilies <> Map.keysSet newFamilies)
  ]
  where
    oldFamilies = transitionFamilies oldTransitions
    newFamilies = transitionFamilies newTransitions

-- | Classify complete guard unions for replay bodies selected by an emitting
-- exact remainder. Cancelled siblings remain members of the recovered body.
replayBodyDeltas :: [Transition] -> [Transition] -> [ReplayBodyDelta]
replayBodyDeltas oldTransitions newTransitions =
  concatMap classifyFamily (transitionFamilyDeltas oldTransitions newTransitions)
  where
    oldFamilies = transitionFamilies oldTransitions
    newFamilies = transitionFamilies newTransitions

    classifyFamily familyDelta =
      [ let oldMembers = membersFor key body oldFamilies
            newMembers = membersFor key body newFamilies
         in ReplayBodyDelta
              { bodyFamilyKey = key,
                bodyKey = body,
                oldBodyMembers = oldMembers,
                newBodyMembers = newMembers,
                bodyStatus = classifyBody oldMembers newMembers
              }
      | body <- affectedBodies familyDelta
      ]
      where
        key = (.familyKey) familyDelta

    affectedBodies familyDelta =
      Set.toAscList . Set.fromList $
        [ replayBodyKey transition
        | transition <- (.oldRemainder) familyDelta <> (.newRemainder) familyDelta,
          not (null transition.emits)
        ]

    membersFor family body families =
      sortOn
        canonicalTransition
        [ transition
        | transition <- Map.findWithDefault [] family families,
          replayBodyKey transition == body
        ]

    classifyBody [] (_ : _) = ReplayBodyAdded
    classifyBody (_ : _) [] = ReplayBodyRemoved
    classifyBody oldMembers newMembers
      | Just oldGuards <- NE.nonEmpty (map (.guard) oldMembers),
        Just newGuards <- NE.nonEmpty (map (.guard) newMembers),
        unionPreserved oldGuards newGuards =
          ReplayBodyPreserved
      | otherwise = ReplayBodyChanged

-- | Derive a body key through the frozen transition encoding rather than a
-- second expression or transition renderer.
replayBodyKey :: Transition -> ReplayBodyKey
replayBodyKey transition =
  ReplayBodyKey . canonicalTransition $
    Transition
      { source = transition.source,
        command = transition.command,
        implementation = transition.implementation,
        guard = Nothing,
        writes = transition.writes,
        emits = transition.emits,
        outcome = Nothing,
        outcomeDuplicateLocs = [],
        goto = transition.goto,
        mode = TmLive,
        loc = noLoc
      }

-- | Canonical, comparison-local alternatives for a present guard union.
-- 'Nothing' represents true and absorbs every other alternative.
guardAlternatives :: NonEmpty (Maybe Expr) -> NonEmpty (Maybe Expr)
guardAlternatives guards
  | any isTrueGuard guards = Nothing :| []
  | otherwise =
      case NE.nonEmpty (map Just normalized) of
        Just alternatives -> alternatives
        Nothing -> Nothing :| []
  where
    normalized =
      Map.elems . Map.fromList $
        [ (canonicalExpr alternative, alternative)
        | alternative <- concatMap (maybe [] flattenOr) (NE.toList guards)
        ]

    flattenOr (EOr left right) = flattenOr left <> flattenOr right
    flattenOr expression = [expression]

-- | Build the normalized union. The result is 'Nothing' exactly when the
-- union is true; explicit false remains an ordinary alternative.
guardUnion :: NonEmpty (Maybe Expr) -> Maybe Expr
guardUnion guards =
  case guardAlternatives guards of
    Nothing :| [] -> Nothing
    Just first :| rest -> Just (foldr1 EOr (first : mapMaybe id rest))
    _ -> Nothing

-- | Prove that every old alternative remains accepted by the new union.
unionPreserved :: NonEmpty (Maybe Expr) -> NonEmpty (Maybe Expr) -> Bool
unionPreserved oldGuards newGuards =
  canonicalUnion oldAlternatives == canonicalUnion newAlternatives
    || all (`guardImplies` newUnion) oldAlternatives
  where
    oldAlternatives = NE.toList (guardAlternatives oldGuards)
    newAlternatives = NE.toList (guardAlternatives newGuards)
    newUnion = guardUnion newGuards
    canonicalUnion = maybe "" canonicalExpr . guardUnion . NE.fromList

-- | A deliberately small implication fragment used by diff and replay impact.
-- Unknown shapes return false so analysis stays conservative.
guardImplies :: Maybe Expr -> Maybe Expr -> Bool
guardImplies _ Nothing = True
guardImplies Nothing (Just newGuard) = isTrueExpr newGuard
guardImplies (Just oldGuard) (Just newGuard) = implies oldGuard newGuard
  where
    implies old new
      | old == new = True
    implies old _ | isFalseExpr old = True
    implies _ new | isTrueExpr new = True
    implies (EAnd left right) new = implies left new || implies right new
    implies old (EOr left right) = implies old left || implies old right
    implies _ _ = False

isTrueGuard :: Maybe Expr -> Bool
isTrueGuard Nothing = True
isTrueGuard (Just expression) = isTrueExpr expression

isTrueExpr :: Expr -> Bool
isTrueExpr (EAtom (ABool True)) = True
isTrueExpr (ELiteral _ (LiteralBool True)) = True
isTrueExpr _ = False

isFalseExpr :: Expr -> Bool
isFalseExpr (EAtom (ABool False)) = True
isFalseExpr (ELiteral _ (LiteralBool False)) = True
isFalseExpr _ = False

transitionFamilies :: [Transition] -> Map.Map TransitionFamilyKey [Transition]
transitionFamilies =
  Map.fromListWith (flip (<>))
    . map (\transition -> (transitionFamilyKey transition, [transition]))

transitionFamilyKey :: Transition -> TransitionFamilyKey
transitionFamilyKey transition =
  TransitionFamilyKey
    { familyMode = transition.mode,
      familySource = transition.source,
      familyCommand = transition.command
    }

modeRank :: TransitionMode -> Int
modeRank TmLive = 0
modeRank TmReplayOnly = 1

cancelExact :: [Transition] -> [Transition] -> ([Transition], [Transition])
cancelExact oldTransitions newTransitions = go sortedOld sortedNew [] []
  where
    sortedOld = sortOn canonicalTransition oldTransitions
    sortedNew = sortOn canonicalTransition newTransitions
    go [] remainingNew unmatchedOld unmatchedNew =
      (reverse unmatchedOld, reverse unmatchedNew <> remainingNew)
    go remainingOld [] unmatchedOld unmatchedNew =
      (reverse unmatchedOld <> remainingOld, reverse unmatchedNew)
    go old@(oldTransition : remainingOld) new@(newTransition : remainingNew) unmatchedOld unmatchedNew =
      case compare (canonicalTransition oldTransition) (canonicalTransition newTransition) of
        LT -> go remainingOld new (oldTransition : unmatchedOld) unmatchedNew
        EQ -> go remainingOld remainingNew unmatchedOld unmatchedNew
        GT -> go old remainingNew unmatchedOld (newTransition : unmatchedNew)
