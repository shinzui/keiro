-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ProcessTimers.Incident.BehaviorHoles (behaviorWitnesses) where

import Generated.ProcessTimers.Incident.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-93455a87d5151176") -- IncidentOpen x RemindIncident: live transition
  , Pending (BehaviorKey "behavior-v1-b944c85b616b9349") -- IncidentOpen x EscalateIncident: live transition
  , Pending (BehaviorKey "behavior-v1-48ce258ccf64ef4e") -- IncidentEscalatedState x EscalateIncident: required rejection
  , Pending (BehaviorKey "behavior-v1-d66d007f74139a07") -- IncidentEscalatedState x RemindIncident: required rejection
  ]
