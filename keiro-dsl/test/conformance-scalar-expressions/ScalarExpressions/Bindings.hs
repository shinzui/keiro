{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it. Fill each HOLE and run the generated harness.
module ScalarExpressions.Bindings (
    initialLimits
  , limitsCases
  , limitsBinding
) where

import Generated.AggregateScalarExpressions.Structural.Shape.Limits qualified
import Data.List.NonEmpty (NonEmpty (..))
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))
import ScalarExpressions.Domain qualified

-- HOLE: provide the initial register value for Limits
initialLimits :: ScalarExpressions.Domain.Limits
initialLimits = ScalarExpressions.Domain.Limits 0 5

-- HOLE: provide deterministic labelled conformance fixtures for Limits
limitsCases :: FixtureCases ScalarExpressions.Domain.Limits
limitsCases =
  FixtureCases
    ( ("initial", initialLimits)
        :| [ ("expanded", ScalarExpressions.Domain.Limits 2 13)
           , ("negative-minimum", ScalarExpressions.Domain.Limits (-3) 8)
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
limitsBinding :: StructuralBinding ScalarExpressions.Domain.Limits Generated.AggregateScalarExpressions.Structural.Shape.Limits.LimitsShape
limitsBinding =
  StructuralBinding
    { bindingToShape = \case
      ScalarExpressions.Domain.Limits minimumValue ceilingValue -> Generated.AggregateScalarExpressions.Structural.Shape.Limits.Limits minimumValue ceilingValue
    , bindingFromShape = \case
      Generated.AggregateScalarExpressions.Structural.Shape.Limits.Limits minimumValue ceilingValue -> ScalarExpressions.Domain.Limits minimumValue ceilingValue
    }
