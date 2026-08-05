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
  { layoutDeclarationIndex :: !Int,
    layoutOutgoingIndex :: !Int,
    layoutTransition :: !Transition
  }
  deriving stock (Eq, Show)

transitionLayout :: [Transition] -> [TransitionLayoutEntry]
transitionLayout transitions = snd (mapAccumL buildEntry Map.empty (zip [1 ..] transitions))
  where
    buildEntry counts (declarationIndex, transition) =
      let source = tSource transition
          outgoingIndex = Map.findWithDefault 0 source counts
          counts' = Map.insert source (outgoingIndex + 1) counts
          entry = TransitionLayoutEntry declarationIndex outgoingIndex transition
       in (counts', entry)

groupTransitionLayoutBySource :: [TransitionLayoutEntry] -> [(Name, [TransitionLayoutEntry])]
groupTransitionLayoutBySource entries =
  [ (source, transitionLayoutForSource source entries)
  | source <- firstOccurrences (map (tSource . layoutTransition) entries)
  ]
  where
    firstOccurrences = foldl appendNew []
    appendNew seen value
      | value `elem` seen = seen
      | otherwise = seen ++ [value]

transitionLayoutForSource :: Name -> [TransitionLayoutEntry] -> [TransitionLayoutEntry]
transitionLayoutForSource source = filter ((== source) . tSource . layoutTransition)
