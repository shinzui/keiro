-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module IncidentResponse.Escalation.BehaviorHoles (behaviorWitnesses) where

import Generated.IncidentResponse.Escalation.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-3c9a2793ee857505") -- EscalationOpen x NoteRaised: live transition
  , Pending (BehaviorKey "behavior-v1-bb2577aace70f171") -- EscalationOpen x NoteAcknowledged: live transition
  ]