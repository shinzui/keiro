module Keiro.Dsl.AggregateGenerationPlan
  ( TransitionLayoutEntry (..),
    transitionLayout,
    groupTransitionLayoutBySource,
    transitionLayoutForSource,
  )
where

import Data.List (mapAccumL)
import Data.Map.Strict qualified as Map
import Keiro.Dsl.Grammar (Name, Transition (..))

data TransitionLayoutEntry = TransitionLayoutEntry
  { declarationIndex :: !Int,
    outgoingIndex :: !Int,
    transition :: !Transition
  }
  deriving stock (Eq, Show)

-- | Number each transition within its source state, in declaration order.
-- @outgoingIndex@ is the keiki edge index: the position of the transition's
-- edge in @edgesOut@ of its source state. The generated transducer builder,
-- the behavior source map and the topology export all use this one rule.
transitionLayout :: [Transition] -> [TransitionLayoutEntry]
transitionLayout transitions = snd (mapAccumL buildEntry Map.empty (zip [1 ..] transitions))
  where
    buildEntry counts (declarationIndex, transition) =
      let source = (.source) transition
          outgoingIndex = Map.findWithDefault 0 source counts
          counts' = Map.insert source (outgoingIndex + 1) counts
          entry = TransitionLayoutEntry declarationIndex outgoingIndex transition
       in (counts', entry)

groupTransitionLayoutBySource :: [TransitionLayoutEntry] -> [(Name, [TransitionLayoutEntry])]
groupTransitionLayoutBySource entries =
  [ (source, transitionLayoutForSource source entries)
  | source <- firstOccurrences (map ((.source) . (.transition)) entries)
  ]
  where
    firstOccurrences = foldl appendNew []
    appendNew seen value
      | value `elem` seen = seen
      | otherwise = seen ++ [value]

transitionLayoutForSource :: Name -> [TransitionLayoutEntry] -> [TransitionLayoutEntry]
transitionLayoutForSource source = filter ((== source) . (.source) . (.transition))
