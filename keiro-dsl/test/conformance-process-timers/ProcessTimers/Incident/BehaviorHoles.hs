-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ProcessTimers.Incident.BehaviorHoles (behaviorWitnesses) where

import Generated.ProcessTimers.Incident.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-93455a87d5151176") -- IncidentOpen x RemindIncident: live transition
  , Pending (BehaviorKey "behavior-v1-f87ad8e553a0b610") -- IncidentOpen x EscalateIncident: live transition
  ]