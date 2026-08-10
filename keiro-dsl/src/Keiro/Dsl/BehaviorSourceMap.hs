-- | Join source-stable behavior requirements to exact, independently stored
-- source provenance. The resulting rows are suitable for deterministic
-- context-level generation; failures are complete and contain no write plan.
module Keiro.Dsl.BehaviorSourceMap
  ( BehaviorSourceFailureCode (..),
    BehaviorSourceFailure (..),
    BehaviorSourceEntry (..),
    planBehaviorSourceMap,
    attachBehaviorSourceLocations,
  )
where

import Data.List (groupBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Dsl.BehaviorCoverage
  ( BehaviorExactLocation (..),
    BehaviorKey,
    BehaviorRequirement,
    RequirementOrigin (..),
    requirementAggregate,
    requirementCanonical,
    requirementCommand,
    requirementExactLocation,
    requirementKey,
    requirementOrigin,
    requirementSource,
  )
import Keiro.Dsl.Source (SourcePoint (..), SourceSpan (..))
import Keiro.Dsl.SourceIndex
  ( SemanticSourceIndex,
    SourcePositionQuality (..),
    SourceSubject (..),
    lookupSourceSpan,
  )

data BehaviorSourceFailureCode
  = BehaviorSourceAnchorMissing
  | BehaviorSourceAnchorInexact
  | BehaviorSourceAnchorCollision
  deriving stock (Eq, Ord, Show)

data BehaviorSourceFailure = BehaviorSourceFailure
  { failureCode :: !BehaviorSourceFailureCode,
    failureKey :: !BehaviorKey,
    failureOrigin :: !RequirementOrigin,
    failureAggregate :: !Text,
    failureState :: !Text,
    failureCommand :: !Text,
    failureSourceSubject :: !SourceSubject,
    failureSpan :: !(Maybe SourceSpan),
    failureMessage :: !Text
  }
  deriving stock (Eq, Show)

data BehaviorSourceEntry = BehaviorSourceEntry
  { behaviorSourceKey :: !BehaviorKey,
    behaviorSourceFile :: !FilePath,
    behaviorSourceLine :: !Int,
    behaviorSourceColumn :: !Int
  }
  deriving stock (Eq, Ord, Show)

-- | Resolve every requirement exactly once. Duplicate keys are rejected even
-- when their canonical text matches, because a generated lookup must be a
-- total one-to-one join rather than a lossy 'Map.fromList'.
planBehaviorSourceMap ::
  [BehaviorRequirement] ->
  SemanticSourceIndex ->
  Either [BehaviorSourceFailure] [BehaviorSourceEntry]
planBehaviorSourceMap requirements sourceIndex =
  case duplicateFailures <> anchorFailures of
    []
      | entryKeys == requirementKeys -> Right sortedEntries
      | otherwise -> Left (missingJoinFailures requirementKeys entryKeys)
    failures -> Left (sortOn failureSortKey failures)
  where
    duplicateFailures = concatMap duplicateKeyFailure (groupsOn requirementKey requirements)
    duplicateKeyFailure duplicates@(first : _ : _) =
      [ BehaviorSourceFailure
          { failureCode = BehaviorSourceAnchorCollision,
            failureKey = requirementKey first,
            failureOrigin = requirementOrigin first,
            failureAggregate = requirementAggregate first,
            failureState = requirementSource first,
            failureCommand = requirementCommand first,
            failureSourceSubject = requirementSourceSubject (requirementOrigin first),
            failureSpan = Nothing,
            failureMessage =
              if Set.size (Set.fromList (map requirementCanonical duplicates)) > 1
                then "behavior key identifies more than one canonical obligation"
                else "behavior key occurs more than once in the requirement inventory"
          }
      ]
    duplicateKeyFailure _ = []
    uniqueRequirements = [requirement | [requirement] <- groupsOn requirementKey requirements]
    planned = map (planEntry sourceIndex) uniqueRequirements
    anchorFailures = [failure | Left failure <- planned]
    sortedEntries = sortOn behaviorSourceKey [entry | Right entry <- planned]
    requirementKeys = Set.fromList (map requirementKey requirements)
    entryKeys = Set.fromList (map behaviorSourceKey sortedEntries)
    missingJoinFailures expected actual =
      [ BehaviorSourceFailure
          { failureCode = BehaviorSourceAnchorMissing,
            failureKey = requirementKey requirement,
            failureOrigin = requirementOrigin requirement,
            failureAggregate = requirementAggregate requirement,
            failureState = requirementSource requirement,
            failureCommand = requirementCommand requirement,
            failureSourceSubject = requirementSourceSubject (requirementOrigin requirement),
            failureSpan = Nothing,
            failureMessage = "behavior requirement is absent from the completed source-map join"
          }
      | requirement <- requirements,
        requirementKey requirement `Set.member` (expected Set.\\ actual)
      ]

-- | Attach exact presentation data after a successful complete join. Unknown
-- keys are left unchanged so compatibility reports can remain explicitly
-- line-only; production paths call this only with 'planBehaviorSourceMap'
-- output, whose key-set equality has already been checked.
attachBehaviorSourceLocations :: [BehaviorSourceEntry] -> [BehaviorRequirement] -> [BehaviorRequirement]
attachBehaviorSourceLocations entries = map attach
  where
    byKey = Map.fromList [(behaviorSourceKey entry, entry) | entry <- entries]
    attach requirement = case Map.lookup (requirementKey requirement) byKey of
      Nothing -> requirement
      Just entry ->
        requirement
          { requirementExactLocation =
              Just
                BehaviorExactLocation
                  { exactSourceFile = behaviorSourceFile entry,
                    exactSourceLine = behaviorSourceLine entry,
                    exactSourceColumn = behaviorSourceColumn entry
                  }
          }

planEntry :: SemanticSourceIndex -> BehaviorRequirement -> Either BehaviorSourceFailure BehaviorSourceEntry
planEntry sourceIndex requirement =
  case lookupSourceSpan subject sourceIndex of
    Nothing -> Left (failure BehaviorSourceAnchorMissing Nothing "behavior source subject is absent from the semantic source index")
    Just (CompatibilityLineOnly, sourceSpan) ->
      Left (failure BehaviorSourceAnchorInexact (Just sourceSpan) "behavior source subject has only a compatibility line, not an exact position")
    Just (ExactSourcePosition, SourceSpan {source, start = SourcePoint {line, column}}) ->
      Right
        BehaviorSourceEntry
          { behaviorSourceKey = requirementKey requirement,
            behaviorSourceFile = source,
            behaviorSourceLine = line,
            behaviorSourceColumn = column
          }
  where
    subject = requirementSourceSubject (requirementOrigin requirement)
    failure failureCode failureSpan failureMessage =
      BehaviorSourceFailure
        { failureCode,
          failureKey = requirementKey requirement,
          failureOrigin = requirementOrigin requirement,
          failureAggregate = requirementAggregate requirement,
          failureState = requirementSource requirement,
          failureCommand = requirementCommand requirement,
          failureSourceSubject = subject,
          failureSpan,
          failureMessage
        }

requirementSourceSubject :: RequirementOrigin -> SourceSubject
requirementSourceSubject origin = case origin of
  TransitionRequirementOrigin aggregate ordinal -> AggregateTransitionSubject aggregate ordinal
  RejectionRequirementOrigin aggregate state -> AggregateStateSubject aggregate state

groupsOn :: (Ord key) => (value -> key) -> [value] -> [[value]]
groupsOn key = groupBy (\left right -> key left == key right) . sortOn key

failureSortKey :: BehaviorSourceFailure -> (BehaviorSourceFailureCode, BehaviorKey, RequirementOrigin)
failureSortKey BehaviorSourceFailure {failureCode, failureKey, failureOrigin} =
  (failureCode, failureKey, failureOrigin)
