{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it. Fill each HOLE and run the generated harness.
module Conformance.StructuralTextSets.Bindings (
    initialTextLabels
  , textLabelsFixtures
  , textLabelsBinding
  , maybeTextLabelsFixtures
  , maybeTextLabelsBinding
  , labelEnvelopeFixtures
  , labelEnvelopeBinding
) where

import Conformance.StructuralTextSets.Domain (LabelEnvelope, MaybeTextLabels, TextLabels)
import Conformance.StructuralTextSets.Domain qualified as Domain
import Generated.StructuralTextSets.Structural.Shape.LabelEnvelope qualified as ShapeLabelEnvelope
import Generated.StructuralTextSets.Structural.Shape.MaybeTextLabels qualified as ShapeMaybeTextLabels
import Generated.StructuralTextSets.Structural.Shape.TextLabels qualified as ShapeTextLabels
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

-- HOLE: provide the initial register value for TextLabels
initialTextLabels :: TextLabels
initialTextLabels = Domain.TextLabels Set.empty

-- HOLE: provide deterministic labelled conformance fixtures for TextLabels
textLabelsFixtures :: FixtureCases TextLabels
textLabelsFixtures =
  FixtureCases
    ( ("empty", initialTextLabels)
        :| [ ("ordinary", Domain.TextLabels (Set.fromList ["a", "b"])),
             ("code-point-order", Domain.TextLabels (Set.fromList ["\x10000", "\xE000", "ä", "a\x0308", "a", "A"]))
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
textLabelsBinding :: StructuralBinding TextLabels ShapeTextLabels.TextLabelsShape
textLabelsBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.TextLabels value -> value
    , bindingFromShape = \case
      value -> Domain.TextLabels value
    }

-- HOLE: provide deterministic labelled conformance fixtures for MaybeTextLabels
maybeTextLabelsFixtures :: FixtureCases MaybeTextLabels
maybeTextLabelsFixtures =
  FixtureCases
    ( ("absent", Domain.MaybeTextLabels Nothing)
        :| [ ("present-empty", Domain.MaybeTextLabels (Just Set.empty)),
             ("present", Domain.MaybeTextLabels (Just (Set.fromList ["a", "b"])))
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
maybeTextLabelsBinding :: StructuralBinding MaybeTextLabels ShapeMaybeTextLabels.MaybeTextLabelsShape
maybeTextLabelsBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.MaybeTextLabels value -> value
    , bindingFromShape = \case
      value -> Domain.MaybeTextLabels value
    }

-- HOLE: provide deterministic labelled conformance fixtures for LabelEnvelope
labelEnvelopeFixtures :: FixtureCases LabelEnvelope
labelEnvelopeFixtures =
  FixtureCases
    ( ( "empty-branches",
        Domain.LabelEnvelope
          Set.empty
          Nothing
          (Domain.MaybeTextLabels Nothing)
          [Set.empty]
          (Map.fromList [("empty", Set.empty)])
      )
        :| [ ( "nested",
               Domain.LabelEnvelope
                 (Set.fromList ["b", "a"])
                 (Just (Set.fromList ["z", "y"]))
                 (Domain.MaybeTextLabels (Just (Set.fromList ["named", "optional"])))
                 [Set.fromList ["second", "first"], Set.fromList ["singleton"]]
                 (Map.fromList [("unicode", Set.fromList ["\x10000", "\xE000", "a\x0308", "ä"])])
             )
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
labelEnvelopeBinding :: StructuralBinding LabelEnvelope ShapeLabelEnvelope.LabelEnvelopeShape
labelEnvelopeBinding =
  StructuralBinding
    { bindingToShape = \case
      Domain.LabelEnvelope primaryValue optionalLabelsValue namedOptionalValue sequenceValue labelledValue ->
        ShapeLabelEnvelope.LabelEnvelope
          primaryValue
          optionalLabelsValue
          (bindingToShape maybeTextLabelsBinding namedOptionalValue)
          sequenceValue
          labelledValue
    , bindingFromShape = \case
      ShapeLabelEnvelope.LabelEnvelope primaryValue optionalLabelsValue namedOptionalValue sequenceValue labelledValue ->
        Domain.LabelEnvelope
          primaryValue
          optionalLabelsValue
          (bindingFromShape maybeTextLabelsBinding namedOptionalValue)
          sequenceValue
          labelledValue
    }
