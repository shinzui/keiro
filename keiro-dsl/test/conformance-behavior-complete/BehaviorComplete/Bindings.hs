{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

-- This is a HAND-OWNED consumer binding skeleton. keiro-dsl creates it once
-- and never overwrites it. Fill each HOLE and run the generated harness.
module BehaviorComplete.Bindings
  ( startPayloadCases,
    startPayloadBinding,
  )
where

import BehaviorComplete.Domain qualified
import Data.List.NonEmpty (NonEmpty (..))
import Generated.BehaviorComplete.Structural.Shape.StartPayload qualified
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

startPayloadCases :: FixtureCases BehaviorComplete.Domain.StartPayload
startPayloadCases =
  FixtureCases
    ( ("without-note", BehaviorComplete.Domain.StartPayload "first" Nothing)
        :| [("with-note", BehaviorComplete.Domain.StartPayload "second" (Just "present"))]
    )

startPayloadBinding :: StructuralBinding BehaviorComplete.Domain.StartPayload Generated.BehaviorComplete.Structural.Shape.StartPayload.StartPayloadShape
startPayloadBinding =
  StructuralBinding
    { bindingToShape = \case
        BehaviorComplete.Domain.StartPayload labelValue noteValue -> Generated.BehaviorComplete.Structural.Shape.StartPayload.StartPayload labelValue noteValue,
      bindingFromShape = \case
        Generated.BehaviorComplete.Structural.Shape.StartPayload.StartPayload labelValue noteValue -> BehaviorComplete.Domain.StartPayload labelValue noteValue
    }
