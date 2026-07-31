{- | Stable runtime contract between consumer-owned nominal domain types and
Keiro-owned wire representations.

Stability: this module is a published integration point for consumer binding
modules and @keiro-dsl@ generated code. Its types and record field names are
stable within a major version. Additions are permitted; renames or semantic
changes require a major version bump and a coordinated @keiro-dsl@ release.

Both directions of a 'NominalBinding' are total. The generated codec remains
the only authority for JSON parsing and rendering. A consumer type whose
constructor rejects, normalizes, or identifies values of the representation is
refined rather than nominal and must not use this API.
-}
module Keiro.Codec.Nominal (
    NominalBinding (..),
    NominalFixture (..),
    NominalFixtureCases (..),
    nominalDomainRoundTrip,
    nominalRepresentationRoundTrip,
)
where

import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)

{- | A total isomorphism between a consumer-owned domain type and the complete
Keiro-owned representation used immediately inside the JSON wire boundary.
-}
data NominalBinding domain representation = NominalBinding
    { nominalToRepresentation :: !(domain -> representation)
    , nominalFromRepresentation :: !(representation -> domain)
    }

-- | One labelled consumer value and its expected generated-codec JSON value.
data NominalFixture domain = NominalFixture
    { nominalFixtureLabel :: !Text
    , nominalFixtureWire :: !Value
    , nominalFixtureDomain :: !domain
    }
    deriving stock (Eq, Show)

{- | A non-empty finite corpus used by generated conformance harnesses.

The corpus supplies evidence for the total binding contract; it does not prove
the laws for values outside the declared cases.
-}
newtype NominalFixtureCases domain = NominalFixtureCases
    { nominalFixtureCases :: NonEmpty (NominalFixture domain)
    }
    deriving stock (Eq, Show)

-- | Check that a consumer value survives conversion through its representation.
nominalDomainRoundTrip :: (Eq domain) => NominalBinding domain representation -> domain -> Bool
nominalDomainRoundTrip binding value =
    nominalFromRepresentation binding (nominalToRepresentation binding value) == value

-- | Check that a representation survives conversion through the consumer type.
nominalRepresentationRoundTrip :: (Eq representation) => NominalBinding domain representation -> representation -> Bool
nominalRepresentationRoundTrip binding representation =
    nominalToRepresentation binding (nominalFromRepresentation binding representation) == representation
