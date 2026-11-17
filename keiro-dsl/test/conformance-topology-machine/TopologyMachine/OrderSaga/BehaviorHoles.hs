-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module TopologyMachine.OrderSaga.BehaviorHoles (behaviorWitnesses) where

import Generated.TopologyMachine.OrderSaga.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-8592eed35edbc505") -- OrderSagaWaiting x FinishRequest: required rejection
  , Pending (BehaviorKey "behavior-v1-d9f622535671546c") -- OrderSagaRequested x RecordRequest: live transition
  , Pending (BehaviorKey "behavior-v1-edb42bb9533e3443") -- OrderSagaWaiting x RecordRequest: live transition
  , Pending (BehaviorKey "behavior-v1-f281427a09b33c8d") -- OrderSagaRequested x FinishRequest: live transition
  ]