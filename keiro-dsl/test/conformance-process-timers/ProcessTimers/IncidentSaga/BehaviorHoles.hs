-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ProcessTimers.IncidentSaga.BehaviorHoles (behaviorWitnesses) where

import Generated.ProcessTimers.IncidentSaga.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-af16dd42cbccd576") -- IncidentSagaOpen x RecordIncident: live transition
  ]