-- | Advanced source-aware entry points for the Keiro DSL frontend.
--
-- Ordinary callers can continue to use "Keiro.Dsl.Parser". This module
-- exposes the located surface/lowering seam without exposing Megaparsec.
module Keiro.Dsl.Frontend
  ( FrontendFailure (..),
    renderFrontendFailure,
    LoweringFailureCode (..),
    LoweringFailure (..),
    renderLoweringFailure,
    parseSurfaceSource,
    lowerSurfaceSource,
  )
where

import Keiro.Dsl.Frontend.Internal
import Keiro.Dsl.Parser (parseSurfaceSource)
