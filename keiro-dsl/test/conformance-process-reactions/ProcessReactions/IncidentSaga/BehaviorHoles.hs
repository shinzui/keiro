-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ProcessReactions.IncidentSaga.BehaviorHoles (behaviorWitnesses) where

import Generated.ProcessReactions.IncidentSaga.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-6b66722f9f2463d3") -- IncidentSagaOpen x RecordCritical: live transition
  , Pending (BehaviorKey "behavior-v1-825e6c1709cb63b4") -- IncidentSagaOpen x RecordRoutine: live transition
  ]