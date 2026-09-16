-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ProcessReactions.Incident.BehaviorHoles (behaviorWitnesses) where

import Generated.ProcessReactions.Incident.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-4126b087f05aadf6") -- IncidentOpen x EscalateIncident: live transition
  ]