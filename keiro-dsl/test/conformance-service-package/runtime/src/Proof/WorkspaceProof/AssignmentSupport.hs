module Proof.WorkspaceProof.AssignmentSupport (emptyPropertyValues, propertyValuesCases) where

import Proof.WorkspaceProof.AssignmentDomain (PropertyValues (..))
import Data.Map.Strict qualified as Map
import Data.List.NonEmpty (NonEmpty (..))
import Keiro.Codec.Structural (FixtureCases (..))

emptyPropertyValues :: PropertyValues
emptyPropertyValues = PropertyValues Map.empty

propertyValuesCases :: FixtureCases PropertyValues
propertyValuesCases = FixtureCases (("empty", emptyPropertyValues) :| [("one", PropertyValues (Map.singleton "colour" "blue"))])
