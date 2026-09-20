{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it. Fill each HOLE and run the generated harness.
module Conformance.BareContainers.Bindings (
    textMapFixtures
  , textMapBinding
  , textListFixtures
  , textListBinding
  , nestedIdsFixtures
  , nestedIdsBinding
  , initialMaybeText
  , maybeTextFixtures
  , maybeTextBinding
  , bareEnvelopeFixtures
  , bareEnvelopeBinding
) where

import Conformance.BareContainers.Domain (BareEnvelope, MaybeText, NestedIds, TextList, TextMap)
import Conformance.BareContainers.Domain qualified as Domain
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Generated.BareContainers.Nominals (ItemId, parseItemId)
import Generated.BareContainers.Structural.Shape.BareEnvelope qualified as ShapeBareEnvelope
import Generated.BareContainers.Structural.Shape.MaybeText qualified as ShapeMaybeText
import Generated.BareContainers.Structural.Shape.NestedIds qualified as ShapeNestedIds
import Generated.BareContainers.Structural.Shape.TextList qualified as ShapeTextList
import Generated.BareContainers.Structural.Shape.TextMap qualified as ShapeTextMap
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

textMapFixtures :: FixtureCases TextMap
textMapFixtures =
  FixtureCases
    ( ("empty", Domain.TextMap Map.empty)
        :| [("present", Domain.TextMap (Map.fromList [("alpha", "one"), ("beta", "two")]))]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
textMapBinding :: StructuralBinding TextMap ShapeTextMap.TextMapShape
textMapBinding =
  StructuralBinding
    { bindingToShape = \case
        Domain.TextMap value -> value,
      bindingFromShape = Domain.TextMap
    }

-- HOLE: provide deterministic labelled conformance fixtures for TextList
textListFixtures :: FixtureCases TextList
textListFixtures =
  FixtureCases
    ( ("empty", Domain.TextList [])
        :| [("ordered-duplicates", Domain.TextList ["b", "a", "a"])]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
textListBinding :: StructuralBinding TextList ShapeTextList.TextListShape
textListBinding =
  StructuralBinding
    { bindingToShape = \case
        Domain.TextList value -> value,
      bindingFromShape = Domain.TextList
    }

-- HOLE: provide deterministic labelled conformance fixtures for NestedIds
nestedIdsFixtures :: FixtureCases NestedIds
nestedIdsFixtures =
  FixtureCases
    ( ("empty", Domain.NestedIds [])
        :| [("null-and-present", Domain.NestedIds [Nothing, Just itemId])]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
nestedIdsBinding :: StructuralBinding NestedIds ShapeNestedIds.NestedIdsShape
nestedIdsBinding =
  StructuralBinding
    { bindingToShape = \case
        Domain.NestedIds value -> value,
      bindingFromShape = Domain.NestedIds
    }

-- HOLE: provide the initial register value for MaybeText
initialMaybeText :: MaybeText
initialMaybeText = Domain.MaybeText Nothing

-- HOLE: provide deterministic labelled conformance fixtures for MaybeText
maybeTextFixtures :: FixtureCases MaybeText
maybeTextFixtures =
  FixtureCases
    ( ("nothing", Domain.MaybeText Nothing)
        :| [("present", Domain.MaybeText (Just "x"))]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
maybeTextBinding :: StructuralBinding MaybeText ShapeMaybeText.MaybeTextShape
maybeTextBinding =
  StructuralBinding
    { bindingToShape = \case
        Domain.MaybeText value -> value,
      bindingFromShape = Domain.MaybeText
    }

-- HOLE: provide deterministic labelled conformance fixtures for BareEnvelope
bareEnvelopeFixtures :: FixtureCases BareEnvelope
bareEnvelopeFixtures =
  FixtureCases
    ( ("defaults", Domain.BareEnvelope initialMaybeText (Domain.TextList []) (Domain.TextMap Map.empty) (Domain.NestedIds []))
        :| [ ( "present",
               Domain.BareEnvelope
                 (Domain.MaybeText (Just "label"))
                 (Domain.TextList ["b", "a", "a"])
                 (Domain.TextMap (Map.fromList [("alpha", "one")]))
                 (Domain.NestedIds [Nothing, Just itemId])
             )
           ]
    )

-- HOLE: complete both total directions; wire policy remains in the generated codec.
bareEnvelopeBinding :: StructuralBinding BareEnvelope ShapeBareEnvelope.BareEnvelopeShape
bareEnvelopeBinding =
  StructuralBinding
    { bindingToShape = \case
        Domain.BareEnvelope optionalLabel labels attributes nestedIds ->
          ShapeBareEnvelope.BareEnvelope
            (bindingToShape maybeTextBinding optionalLabel)
            (bindingToShape textListBinding labels)
            (bindingToShape textMapBinding attributes)
            (bindingToShape nestedIdsBinding nestedIds),
      bindingFromShape = \case
        ShapeBareEnvelope.BareEnvelope optionalLabel labels attributes nestedIds ->
          Domain.BareEnvelope
            (bindingFromShape maybeTextBinding optionalLabel)
            (bindingFromShape textListBinding labels)
            (bindingFromShape textMapBinding attributes)
            (bindingFromShape nestedIdsBinding nestedIds)
    }

itemIdText :: Text
itemIdText = "item_01h455vb4pex5vsknk084sn02q"

itemId :: ItemId
itemId = case parseItemId itemIdText of
  Left reason -> error ("invalid committed ItemId fixture: " <> show reason)
  Right value -> value
