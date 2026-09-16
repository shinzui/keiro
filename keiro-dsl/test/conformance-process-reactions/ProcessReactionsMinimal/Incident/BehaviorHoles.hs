-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ProcessReactionsMinimal.Incident.BehaviorHoles (behaviorWitnesses) where

import Generated.ProcessReactionsMinimal.Incident.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-b80bea9f8d7d40e8") -- IncidentOpen x EscalateIncident: live transition
  ]