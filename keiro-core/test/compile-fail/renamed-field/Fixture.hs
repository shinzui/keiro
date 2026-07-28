{-# LANGUAGE ImportQualifiedPost #-}

module Fixture where

import Domain qualified
import Keiro.Codec.Structural (StructuralBinding)
import Keiro.Codec.Structural.Generic (genericStructuralBinding)
import Shape qualified

binding :: StructuralBinding Domain.Item Shape.Item
binding = genericStructuralBinding
