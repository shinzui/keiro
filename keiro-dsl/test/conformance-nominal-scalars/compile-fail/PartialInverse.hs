module PartialInverse where

import Keiro.Codec.Nominal (NominalBinding (..))

-- This file is expected not to type-check: a refined/partial inverse is not a
-- total NominalBinding. The compile-fail gate invokes GHC with -fno-code.
partialInverse :: NominalBinding Int Int
partialInverse =
    NominalBinding
        { nominalToRepresentation = id
        , nominalFromRepresentation = \value -> Left ("refined rejection", value)
        }
