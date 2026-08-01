-- | Advanced source-aware entry points for the Keiro DSL frontend.
--
-- Ordinary callers can continue to use "Keiro.Dsl.Parser". This module
-- exposes the located surface/lowering seam without exposing Megaparsec.
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
    lowerSurfaceSource,
  )
where

import Keiro.Dsl.Frontend.Internal
import Keiro.Dsl.Parser (parseSurfaceSource)
