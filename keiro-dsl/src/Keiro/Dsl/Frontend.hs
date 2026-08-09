-- | Advanced source-aware entry points for the Keiro DSL frontend.
--
-- Ordinary callers can continue to use "Keiro.Dsl.Parser". This module owns
-- the located surface/lowering seam without exposing Megaparsec.
--
-- A source-aware caller parses once, inspects exact half-open spans, and then
-- lowers into the same 'Keiro.Dsl.LanguageVersion.ParsedSource' returned by
-- the compatibility facade:
--
-- @
-- case parseSurfaceSource "orders.keiro" input of
--   Left failure -> renderFrontendFailure failure
--   Right surface ->
--     case lowerSurfaceSource surface of
--       Left loweringFailure -> renderLoweringFailure loweringFailure
--       Right _parsed -> "ready for semantic checking"
-- @
--
-- Pattern matching on 'Keiro.Dsl.Source.SourceSpan' exposes source name,
-- token offsets, and one-based line/column points. The surface tree does not
-- retain comments or whitespace; canonical pretty printing is therefore not
-- a lossless source formatter.
module Keiro.Dsl.Frontend
  ( FrontendContext (..),
    frontendLanguageVersion,
    frontendSupportsFeature,
    FrontendPhase (..),
    FrontendErrorCode (..),
    frontendErrorCodeText,
    FrontendFailure (..),
    renderFrontendFailure,
    LoweringFailureCode (..),
    LoweringFailure (..),
    renderLoweringFailure,
    frontendFailureFromLowering,
    parseSurfaceSource,
    lowerSurfaceDocument,
    lowerSurfaceSource,
  )
where

import Keiro.Dsl.Frontend.Internal
import Keiro.Dsl.Parser.Document (parseSurfaceSource)
