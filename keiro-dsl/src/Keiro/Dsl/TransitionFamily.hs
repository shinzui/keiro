-- | Deterministic, declaration-order-independent transition family comparison.
module Keiro.Dsl.TransitionFamily
  ( TransitionFamilyKey (..),
    TransitionFamilyDelta (..),
    transitionFamilyDeltas,
  )
where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Keiro.Dsl.CanonicalEncoding (canonicalTransition)
import Keiro.Dsl.Grammar (Name, Transition (..), TransitionMode (..))

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

transitionFamilies :: [Transition] -> Map.Map TransitionFamilyKey [Transition]
transitionFamilies =
  Map.fromListWith (<>)
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
