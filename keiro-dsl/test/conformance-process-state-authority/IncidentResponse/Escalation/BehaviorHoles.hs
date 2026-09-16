-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module IncidentResponse.Escalation.BehaviorHoles (behaviorWitnesses) where

import Generated.IncidentResponse.Escalation.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-2144226ce8222855") -- EscalationOpen x NoteRaised: live transition
  , Pending (BehaviorKey "behavior-v1-65795e7a28345559") -- EscalationOpen x NoteAcknowledged: live transition
  , Pending (BehaviorKey "behavior-v1-00b0b13023eea6f8") -- EscalationOpen x NoteIgnored: typed no-op transition
  , Pending (BehaviorKey "behavior-v1-3d0e024503e32404") -- EscalationOpen x ActivateDormant: live transition
  , Pending (BehaviorKey "behavior-v1-75011409d18e29c3") -- EscalationDormant x NoteRaised: required rejection
  , Pending (BehaviorKey "behavior-v1-16209316858bb8c3") -- EscalationDormant x NoteAcknowledged: required rejection
  , Pending (BehaviorKey "behavior-v1-eecae8fa281fddcf") -- EscalationDormant x NoteIgnored: required rejection
  , Pending (BehaviorKey "behavior-v1-8f58f8301e7a66f3") -- EscalationDormant x ActivateDormant: required rejection
  ]
