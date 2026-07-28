{- | Stable runtime contract between consumer-owned domain types and
Keiro-generated structural wire shapes.

Stability: this module is a published integration point for consumer binding
modules and @keiro-dsl@ generated code. Its types and record field names are
stable within a major version. Additions are permitted; renames or semantic
changes require a major version bump and a coordinated @keiro-dsl@ release.

The generated codec is the single authority for the wire schema. A consumer
'Data.Aeson.ToJSON' or 'Data.Aeson.FromJSON' instance may delegate to that
generated codec through a binding, but Keiro never delegates structural
encoding to a consumer instance.
-}
module Keiro.Codec.Structural (
    StructuralBinding (..),
    FixtureCases (..),
    bindingDomainRoundTrip,
    bindingShapeRoundTrip,
    encodeViaBinding,
    decodeViaBinding,
)
where

import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)

{- | A total construction and destruction boundary between a consumer-owned
type and its declared structural shape.

Consumer invariants must be represented by the shape. If converting a valid
shape into the consumer type can fail, the declaration is not structural and
must use Keiro's opaque mapping mode instead.
-}
data StructuralBinding a shape = StructuralBinding
    { bindingToShape :: !(a -> shape)
    , bindingFromShape :: !(shape -> a)
    }

{- | Deterministic, labelled consumer values used by generated conformance
harnesses.

The generator checks these cases against every declared union and nullable
branch. Values are never invented through @Arbitrary@ or @Default@. Generated
harnesses also reject empty or duplicate labels so failures keep a stable
identity.
-}
newtype FixtureCases a = FixtureCases
    { fixtureCases :: NonEmpty (Text, a)
    }
    deriving stock (Eq, Show)

-- | Check that a consumer value survives conversion through its shape.
bindingDomainRoundTrip :: (Eq a) => StructuralBinding a shape -> a -> Bool
bindingDomainRoundTrip binding value =
    bindingFromShape binding (bindingToShape binding value) == value

-- | Check that every declared shape survives conversion through the consumer type.
bindingShapeRoundTrip :: (Eq shape) => StructuralBinding a shape -> shape -> Bool
bindingShapeRoundTrip binding shape =
    bindingToShape binding (bindingFromShape binding shape) == shape

{- | Encode a consumer value by first converting it to the generated shape.

This is the sanctioned delegation direction for a consumer-owned JSON
instance: the generated shape encoder remains the wire authority.
-}
encodeViaBinding :: StructuralBinding a shape -> (shape -> Value) -> a -> Value
encodeViaBinding binding encodeShape = encodeShape . bindingToShape binding

{- | Decode the generated shape and then apply the binding's total constructor.

All failure comes from parsing JSON into the generated shape. Applying the
binding introduces no hidden semantic rejection.
-}
decodeViaBinding ::
    StructuralBinding a shape ->
    (Value -> Either Text shape) ->
    Value ->
    Either Text a
decodeViaBinding binding decodeShape value =
    bindingFromShape binding <$> decodeShape value
