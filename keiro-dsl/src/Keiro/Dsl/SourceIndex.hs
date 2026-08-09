{-# LANGUAGE NoFieldSelectors #-}

-- | Exact source provenance for semantic aggregate subjects.
--
-- The index deliberately lives beside 'Keiro.Dsl.Grammar.Spec'. Source
-- movement must not participate in semantic equality, fingerprints, diffs, or
-- generated output.
module Keiro.Dsl.SourceIndex
  ( TransitionOrdinal (..),
    SourceSubject (..),
    SourcePositionQuality (..),
    SemanticSourceIndex,
    ParsedSourceDocument (..),
    SourceIndexFailureCode (..),
    SourceIndexFailure (..),
    semanticSourceSubjects,
    exactSemanticSourceIndex,
    compatibilitySemanticSourceIndex,
    repathSemanticSourceIndex,
    unionSemanticSourceIndexes,
    emptySemanticSourceIndex,
    semanticSourceEntries,
    lookupSourceSpan,
  )
where

import Data.List (find, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Keiro.Dsl.Grammar
  ( Aggregate (..),
    Loc (..),
    Name,
    Node (..),
    Spec (..),
    StateDecl (..),
    Transition (..),
  )
import Keiro.Dsl.LanguageVersion (ParsedSource)
import Keiro.Dsl.Source (SourcePoint (..), SourceSpan (..))

newtype TransitionOrdinal = TransitionOrdinal Int
  deriving stock (Eq, Ord, Show, Generic)

-- | A syntax subject whose location may change without changing semantics.
data SourceSubject
  = AggregateStateSubject !Name !Name
  | AggregateTransitionSubject !Name !TransitionOrdinal
  deriving stock (Eq, Ord, Show, Generic)

-- | Whether a position came from exact parsing or from a compatibility
-- projection over line-only semantic values.
data SourcePositionQuality
  = ExactSourcePosition
  | CompatibilityLineOnly
  deriving stock (Eq, Ord, Show, Generic)

data IndexedSourcePosition = IndexedSourcePosition
  { quality :: !SourcePositionQuality,
    span :: !SourceSpan
  }
  deriving stock (Eq, Show, Generic)

newtype SemanticSourceIndex = SemanticSourceIndex
  { positions :: Map SourceSubject IndexedSourcePosition
  }
  deriving stock (Eq, Show, Generic)

-- | The semantic parse result and its independently comparable source index.
data ParsedSourceDocument = ParsedSourceDocument
  { documentParsedSource :: !ParsedSource,
    documentSourceIndex :: !SemanticSourceIndex
  }
  deriving stock (Eq, Show, Generic)

data SourceIndexFailureCode
  = DuplicateSourceSubject
  | MissingSourceSubject
  | UnexpectedSourceSubject
  | SourceIndexFileMismatch
  deriving stock (Eq, Ord, Show, Generic)

data SourceIndexFailure = SourceIndexFailure
  { failureCode :: !SourceIndexFailureCode,
    failureSubject :: !(Maybe SourceSubject),
    failureSpan :: !(Maybe SourceSpan),
    failureMessage :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The complete aggregate state and transition subject inventory of a
-- semantic graph, in semantic source order.
semanticSourceSubjects :: Spec -> [SourceSubject]
semanticSourceSubjects spec = concatMap aggregateSubjects aggregates
  where
    aggregates = [aggregate | NAggregate aggregate <- specNodes spec]
    aggregateSubjects aggregate =
      [ AggregateStateSubject (aggName aggregate) (stName state)
      | state <- aggStates aggregate
      ]
        <> [ AggregateTransitionSubject (aggName aggregate) (TransitionOrdinal ordinal)
           | (ordinal, _) <- zip [0 ..] (aggTransitions aggregate)
           ]

-- | Construct a complete exact index for one parsed file. The expected
-- inventory comes from the just-lowered semantic graph, so missing and stale
-- surface anchors are refused at the lowering boundary.
exactSemanticSourceIndex ::
  FilePath ->
  [SourceSubject] ->
  [(SourceSubject, SourceSpan)] ->
  Either SourceIndexFailure SemanticSourceIndex
exactSemanticSourceIndex source expected entries = do
  case find ((/= source) . sourceOf . snd) entries of
    Just (subject, sourceSpan) ->
      Left
        SourceIndexFailure
          { failureCode = SourceIndexFileMismatch,
            failureSubject = Just subject,
            failureSpan = Just sourceSpan,
            failureMessage = "source-index span belongs to a different source file"
          }
    Nothing -> pure ()
  checkedIndex ExactSourcePosition expected entries
  where
    sourceOf SourceSpan {source = spanSource} = spanSource

-- | Derive an explicitly line-only index for a compatibility 'Spec'. The
-- synthetic column is never advertised as exact.
compatibilitySemanticSourceIndex :: FilePath -> Spec -> Either SourceIndexFailure SemanticSourceIndex
compatibilitySemanticSourceIndex source spec =
  checkedIndex CompatibilityLineOnly expected entries
  where
    expected = semanticSourceSubjects spec
    entries = concatMap aggregateEntries [aggregate | NAggregate aggregate <- specNodes spec]
    aggregateEntries aggregate =
      [ (AggregateStateSubject (aggName aggregate) (stName state), lineSpan (stLoc state))
      | state <- aggStates aggregate
      ]
        <> [ (AggregateTransitionSubject (aggName aggregate) (TransitionOrdinal ordinal), lineSpan (tLoc transition))
           | (ordinal, transition) <- zip [0 ..] (aggTransitions aggregate)
           ]
    lineSpan (Loc lineNumber) =
      SourceSpan
        { source,
          start = point,
          end = point
        }
      where
        point = SourcePoint {offset = 0, line = max 1 lineNumber, column = 1}

-- | Replace the one source name in an index after checking the caller's
-- expected name. Workspace composition uses this to turn loader paths into
-- canonical manifest-relative member paths without relocating points.
repathSemanticSourceIndex ::
  FilePath ->
  FilePath ->
  SemanticSourceIndex ->
  Either SourceIndexFailure SemanticSourceIndex
repathSemanticSourceIndex expected replacement (SemanticSourceIndex index) =
  case find ((/= expected) . sourceOf . spanOf . snd) (Map.toAscList index) of
    Just (subject, position) ->
      Left
        SourceIndexFailure
          { failureCode = SourceIndexFileMismatch,
            failureSubject = Just subject,
            failureSpan = Just (spanOf position),
            failureMessage = "source-index span does not match the workspace member source path"
          }
    Nothing ->
      Right
        ( SemanticSourceIndex
            (Map.map replaceSource index)
        )
  where
    spanOf IndexedSourcePosition {span = sourceSpan} = sourceSpan
    sourceOf SourceSpan {source} = source
    replaceSource position@IndexedSourcePosition {span = sourceSpan} =
      position {span = sourceSpan {source = replacement}}

-- | Union complete member indices, refusing any duplicate semantic subject.
unionSemanticSourceIndexes :: [SemanticSourceIndex] -> Either SourceIndexFailure SemanticSourceIndex
unionSemanticSourceIndexes indexes =
  checkedIndexWithPositions
    [ (subject, position)
    | SemanticSourceIndex index <- indexes,
      (subject, position) <- Map.toAscList index
    ]

emptySemanticSourceIndex :: SemanticSourceIndex
emptySemanticSourceIndex = SemanticSourceIndex Map.empty

semanticSourceEntries :: SemanticSourceIndex -> [(SourceSubject, SourcePositionQuality, SourceSpan)]
semanticSourceEntries (SemanticSourceIndex index) =
  [ (subject, quality, sourceSpan)
  | (subject, IndexedSourcePosition {quality, span = sourceSpan}) <- Map.toAscList index
  ]

lookupSourceSpan :: SourceSubject -> SemanticSourceIndex -> Maybe (SourcePositionQuality, SourceSpan)
lookupSourceSpan subject (SemanticSourceIndex index) = do
  IndexedSourcePosition {quality, span = sourceSpan} <- Map.lookup subject index
  pure (quality, sourceSpan)

checkedIndex ::
  SourcePositionQuality ->
  [SourceSubject] ->
  [(SourceSubject, SourceSpan)] ->
  Either SourceIndexFailure SemanticSourceIndex
checkedIndex quality expected entries = do
  index <- checkedIndexWithPositions [(subject, IndexedSourcePosition {quality, span = sourceSpan}) | (subject, sourceSpan) <- entries]
  let actualSubjects = Set.fromList [subject | (subject, _, _) <- semanticSourceEntries index]
      expectedSubjects = Set.fromList expected
  case Set.lookupMin (actualSubjects Set.\\ expectedSubjects) of
    Just subject ->
      Left
        SourceIndexFailure
          { failureCode = UnexpectedSourceSubject,
            failureSubject = Just subject,
            failureSpan = snd <$> find ((== subject) . fst) entries,
            failureMessage = "source index contains a subject absent from the semantic graph"
          }
    Nothing -> pure ()
  case Set.lookupMin (expectedSubjects Set.\\ actualSubjects) of
    Just subject ->
      Left
        SourceIndexFailure
          { failureCode = MissingSourceSubject,
            failureSubject = Just subject,
            failureSpan = Nothing,
            failureMessage = "semantic graph subject has no source-index entry"
          }
    Nothing -> Right index

checkedIndexWithPositions ::
  [(SourceSubject, IndexedSourcePosition)] ->
  Either SourceIndexFailure SemanticSourceIndex
checkedIndexWithPositions entries =
  case firstDuplicate (sort (map fst entries)) of
    Just duplicate ->
      Left
        SourceIndexFailure
          { failureCode = DuplicateSourceSubject,
            failureSubject = Just duplicate,
            failureSpan = spanOf <$> find ((== duplicate) . fst) entries,
            failureMessage = "source index contains more than one entry for a semantic subject"
          }
    Nothing -> Right (SemanticSourceIndex (Map.fromList entries))
  where
    firstDuplicate values = fst <$> find (uncurry (==)) (zip values (drop 1 values))
    spanOf (_, IndexedSourcePosition {span = sourceSpan}) = sourceSpan
