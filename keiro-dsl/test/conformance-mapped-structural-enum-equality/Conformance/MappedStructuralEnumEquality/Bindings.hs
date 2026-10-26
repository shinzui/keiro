module Conformance.MappedStructuralEnumEquality.Bindings where

import Conformance.MappedStructuralEnumEquality.Domain qualified as Domain
import Data.List.NonEmpty (NonEmpty (..))
import Generated.MappedStructuralEnumEquality.Structural.Shape.RequiredScope qualified as Scope
import Generated.MappedStructuralEnumEquality.Structural.Shape.Request qualified as Request
import Keiro.Codec.Structural (FixtureCases (..), StructuralBinding (..))

requiredScopeBinding :: StructuralBinding Domain.RequiredScope Scope.RequiredScopeShape
requiredScopeBinding = StructuralBinding toShape fromShape
  where
    toShape Domain.PipelineScope = Scope.PipelineScope
    toShape Domain.DiagnosticScope = Scope.DiagnosticScope
    fromShape Scope.PipelineScope = Domain.PipelineScope
    fromShape Scope.DiagnosticScope = Domain.DiagnosticScope

requiredScopeFixtures :: FixtureCases Domain.RequiredScope
requiredScopeFixtures = FixtureCases (("pipeline", Domain.PipelineScope) :| [("diagnostic", Domain.DiagnosticScope)])

initialScope :: Domain.RequiredScope
initialScope = Domain.PipelineScope

requestBinding :: StructuralBinding Domain.Request Request.RequestShape
requestBinding = StructuralBinding
  (\(Domain.Request scope) -> Request.Request (bindingToShape requiredScopeBinding scope))
  (\(Request.Request scope) -> Domain.Request (bindingFromShape requiredScopeBinding scope))

requestFixtures :: FixtureCases Domain.Request
requestFixtures = FixtureCases (("pipeline", Domain.Request Domain.PipelineScope) :| [("diagnostic", Domain.Request Domain.DiagnosticScope)])
