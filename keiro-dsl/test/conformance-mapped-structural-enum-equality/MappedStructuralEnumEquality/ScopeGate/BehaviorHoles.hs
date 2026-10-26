module MappedStructuralEnumEquality.ScopeGate.BehaviorHoles (behaviorWitnesses) where

import Conformance.MappedStructuralEnumEquality.Domain
import Data.List.NonEmpty (NonEmpty (..))
import Generated.MappedStructuralEnumEquality.ScopeGate.BehaviorContract
import Generated.MappedStructuralEnumEquality.ScopeGate.Domain

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses = map witness behaviorRequirements
  where
    matched = Matched (MatchedData PipelineScope (Request PipelineScope))
    witness requirement = LiveWitness
      { key = requirement.key,
        history = if requirement.source == ScopeGateDone then [matched] else [],
        command = if requirement.commandName == "Match" then Match (MatchData PipelineScope (Request PipelineScope)) else Differ (DifferData DiagnosticScope (Request DiagnosticScope)),
        expected = case requirement.kind of
          RequiredRejection -> Rejects RejectNoMatchingEdge
          LiveTransition -> Emits ((if requirement.commandName == "Match" then matched else Differed (DifferedData DiagnosticScope (Request DiagnosticScope))) :| [])
          ReplayTransition -> error "fixture has no replay-only transitions"
      }
