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
        command = commandFor requirement.commandName,
        expected = case requirement.kind of
          RequiredRejection -> Rejects RejectNoMatchingEdge
          LiveTransition -> Emits (eventFor requirement.commandName :| [])
          ReplayTransition -> error "fixture has no replay-only transitions"
      }

    commandFor "Match" = Match (MatchData PipelineScope (Request PipelineScope))
    commandFor "Differ" = Differ (DifferData DiagnosticScope (Request DiagnosticScope))
    commandFor "EqRight" = EqRight (EqRightData PipelineScope (Request PipelineScope))
    commandFor "EqLeft" = EqLeft (EqLeftData PipelineScope (Request PipelineScope))
    commandFor "NeRight" = NeRight (NeRightData PipelineScope (Request PipelineScope))
    commandFor "NeLeft" = NeLeft (NeLeftData PipelineScope (Request PipelineScope))
    commandFor "Self" = Self (SelfData PipelineScope (Request PipelineScope))
    commandFor _ = error "unknown fixture command"
    eventFor "Match" = matched
    eventFor "Differ" = Differed (DifferedData DiagnosticScope (Request DiagnosticScope))
    eventFor "EqRight" = EqRightAccepted (EqRightAcceptedData PipelineScope (Request PipelineScope))
    eventFor "EqLeft" = EqLeftAccepted (EqLeftAcceptedData PipelineScope (Request PipelineScope))
    eventFor "NeRight" = NeRightAccepted (NeRightAcceptedData PipelineScope (Request PipelineScope))
    eventFor "NeLeft" = NeLeftAccepted (NeLeftAcceptedData PipelineScope (Request PipelineScope))
    eventFor "Self" = SelfAccepted (SelfAcceptedData PipelineScope (Request PipelineScope))
    eventFor _ = error "unknown fixture event"
