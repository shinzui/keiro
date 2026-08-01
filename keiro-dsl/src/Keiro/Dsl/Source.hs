{-# LANGUAGE NoFieldSelectors #-}

-- | Source locations used by the Keiro language frontend.
--
-- Offsets count tokens in the parsed 'Text' stream. Spans are half-open: the
-- end point is immediately after the final token owned by a construct.
module Keiro.Dsl.Source
  ( SourcePoint (..),
    mkSourcePoint,
    SourceSpan (..),
    mkSourceSpan,
    validSourceSpan,
    startLine,
    Located (..),
    mapLocated,
  )
where

import GHC.Generics (Generic)
import Prelude hiding (span)

-- | An exact position in a parsed source.
data SourcePoint = SourcePoint
  { offset :: !Int,
    line :: !Int,
    column :: !Int
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Construct a non-negative offset with one-based line and column values.
mkSourcePoint :: Int -> Int -> Int -> Maybe SourcePoint
mkSourcePoint offset line column
  | offset < 0 = Nothing
  | line < 1 = Nothing
  | column < 1 = Nothing
  | otherwise = Just SourcePoint {offset, line, column}

-- | A half-open source interval.
data SourceSpan = SourceSpan
  { source :: !FilePath,
    start :: !SourcePoint,
    end :: !SourcePoint
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Construct a span whose end does not precede its start.
mkSourceSpan :: FilePath -> SourcePoint -> SourcePoint -> Maybe SourceSpan
mkSourceSpan source start end
  | validPoints start end = Just SourceSpan {source, start, end}
  | otherwise = Nothing

-- | Check the ordering invariant even for a value built with the public
-- constructor.
validSourceSpan :: SourceSpan -> Bool
validSourceSpan SourceSpan {start, end} = validPoints start end

-- | Project the one-based starting line used by the legacy semantic 'Loc'.
startLine :: SourceSpan -> Int
startLine SourceSpan {start = SourcePoint {line}} = line

-- | A value together with the exact source syntax that owns it.
data Located a = Located
  { span :: !SourceSpan,
    value :: !a
  }
  deriving stock (Eq, Ord, Show, Functor, Generic)

mapLocated :: (a -> b) -> Located a -> Located b
mapLocated f Located {span, value} = Located {span, value = f value}

validPoints :: SourcePoint -> SourcePoint -> Bool
validPoints
  SourcePoint {offset = startOffset, line = startLineNumber, column = startColumn}
  SourcePoint {offset = endOffset, line = endLineNumber, column = endColumn} =
    startOffset <= endOffset
      && (startLineNumber, startColumn) <= (endLineNumber, endColumn)
