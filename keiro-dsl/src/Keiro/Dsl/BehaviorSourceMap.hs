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
    BehaviorRequirement (..),
    RequirementOrigin (..),
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
  { code :: !BehaviorSourceFailureCode,
    key :: !BehaviorKey,
    origin :: !RequirementOrigin,
    aggregate :: !Text,
    state :: !Text,
    command :: !Text,
    sourceSubject :: !SourceSubject,
    span :: !(Maybe SourceSpan),
    message :: !Text
  }
  deriving stock (Eq, Show)

data BehaviorSourceEntry = BehaviorSourceEntry
  { key :: !BehaviorKey,
    file :: !FilePath,
    line :: !Int,
    column :: !Int
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
    duplicateFailures = concatMap duplicateKeyFailure (groupsOn (.key) requirements)
    duplicateKeyFailure duplicates@(first : _ : _) =
      [ BehaviorSourceFailure
          { code = BehaviorSourceAnchorCollision,
            key = (.key) first,
            origin = (.origin) first,
            aggregate = (.aggregate) first,
            state = (.source) first,
            command = (.command) first,
            sourceSubject = requirementSourceSubject ((.origin) first),
            span = Nothing,
            message =
              if Set.size (Set.fromList (map (.canonical) duplicates)) > 1
                then "behavior key identifies more than one canonical obligation"
                else "behavior key occurs more than once in the requirement inventory"
          }
      ]
    duplicateKeyFailure _ = []
    uniqueRequirements = [requirement | [requirement] <- groupsOn (.key) requirements]
    planned = map (planEntry sourceIndex) uniqueRequirements
    anchorFailures = [failure | Left failure <- planned]
    sortedEntries = sortOn (.key) [entry | Right entry <- planned]
    requirementKeys = Set.fromList (map (.key) requirements)
    entryKeys = Set.fromList (map (.key) sortedEntries)
    missingJoinFailures expected actual =
      [ BehaviorSourceFailure
          { code = BehaviorSourceAnchorMissing,
            key = (.key) requirement,
            origin = (.origin) requirement,
            aggregate = (.aggregate) requirement,
            state = (.source) requirement,
            command = (.command) requirement,
            sourceSubject = requirementSourceSubject ((.origin) requirement),
            span = Nothing,
            message = "behavior requirement is absent from the completed source-map join"
          }
      | requirement <- requirements,
        (.key) requirement `Set.member` (expected Set.\\ actual)
      ]

-- | Attach exact presentation data after a successful complete join. Unknown
-- keys are left unchanged so compatibility reports can remain explicitly
-- line-only; production paths call this only with 'planBehaviorSourceMap'
-- output, whose key-set equality has already been checked.
attachBehaviorSourceLocations :: [BehaviorSourceEntry] -> [BehaviorRequirement] -> [BehaviorRequirement]
attachBehaviorSourceLocations entries = map attach
  where
    byKey = Map.fromList [((.key) entry, entry) | entry <- entries]
    attach requirement = case Map.lookup ((.key) requirement) byKey of
      Nothing -> requirement
      Just entry ->
        replaceRequirementExactLocation
          ( Just
              BehaviorExactLocation
                { sourceFile = entry.file,
                  sourceLine = entry.line,
                  sourceColumn = entry.column
                }
          )
          requirement

    replaceRequirementExactLocation exactLocation requirement =
      BehaviorRequirement
        { key = requirement.key,
          origin = requirement.origin,
          kind = requirement.kind,
          evidence = requirement.evidence,
          guardCoverage = requirement.guardCoverage,
          context = requirement.context,
          aggregate = requirement.aggregate,
          source = requirement.source,
          command = requirement.command,
          target = requirement.target,
          mode = requirement.mode,
          events = requirement.events,
          outputs = requirement.outputs,
          domainOutcome = requirement.domainOutcome,
          location = requirement.location,
          exactLocation,
          owner = requirement.owner,
          canonical = requirement.canonical
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
          { key = (.key) requirement,
            file = source,
            line = line,
            column = column
          }
  where
    subject = requirementSourceSubject ((.origin) requirement)
    failure code sourceSpan message =
      BehaviorSourceFailure
        { code,
          key = (.key) requirement,
          origin = (.origin) requirement,
          aggregate = (.aggregate) requirement,
          state = (.source) requirement,
          command = (.command) requirement,
          sourceSubject = subject,
          span = sourceSpan,
          message
        }

requirementSourceSubject :: RequirementOrigin -> SourceSubject
requirementSourceSubject origin = case origin of
  TransitionRequirementOrigin aggregate ordinal -> AggregateTransitionSubject aggregate ordinal
  RejectionRequirementOrigin aggregate state -> AggregateStateSubject aggregate state

groupsOn :: (Ord key) => (value -> key) -> [value] -> [[value]]
groupsOn key = groupBy (\left right -> key left == key right) . sortOn key

failureSortKey :: BehaviorSourceFailure -> (BehaviorSourceFailureCode, BehaviorKey, RequirementOrigin)
failureSortKey BehaviorSourceFailure {code, key, origin} =
  (code, key, origin)
