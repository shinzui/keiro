-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module ProcessReactionsMinimal.IncidentSaga.BehaviorHoles (behaviorWitnesses) where

import Generated.ProcessReactionsMinimal.IncidentSaga.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-d8d2518bf8eda97e") -- IncidentSagaOpen x RecordIncident: live transition
  ]