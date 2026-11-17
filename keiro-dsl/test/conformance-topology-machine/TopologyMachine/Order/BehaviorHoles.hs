-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module TopologyMachine.Order.BehaviorHoles (behaviorWitnesses) where

import Generated.TopologyMachine.Order.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-002dd349c9f95c03") -- OrderOpen x PlaceOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-339bb773d33d1cd9") -- OrderOpen x ShipOrder: live transition
  , Pending (BehaviorKey "behavior-v1-364d670a2b00ba7a") -- OrderDone x CloseOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-4703c81ac84fd269") -- OrderInTransit x AmendOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-4ad1b28167914e12") -- OrderOpen x CloseOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-4c06e1818180b41a") -- OrderDraft x AmendOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-4c3acea05eae1527") -- OrderInTransit x CloseOrder: live transition
  , Pending (BehaviorKey "behavior-v1-5b1cf802887be9da") -- OrderDone x NoteOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-681e78594be5e34d") -- OrderDraft x PlaceOrder: live transition
  , Pending (BehaviorKey "behavior-v1-6dc85069e4d4aeaf") -- OrderDone x AmendOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-820d02611d3fe202") -- OrderOpen x NoteOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-86aedf6e0162577f") -- OrderDraft x CloseOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-acb73cfddfb6ec54") -- OrderDone x ShipOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-b3bf157ed703ffaf") -- OrderDraft x ShipOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-bba7be6454e48fd5") -- OrderOpen x AmendOrder: live transition
  , Pending (BehaviorKey "behavior-v1-c193804300699444") -- OrderInTransit x NoteOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-cd039e17dcc38865") -- OrderInTransit x PlaceOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-cf6a23ed42e4970a") -- OrderOpen x CloseOrder: replay-only transition
  , Pending (BehaviorKey "behavior-v1-e07448f38133b7e0") -- OrderDraft x NoteOrder: live transition
  , Pending (BehaviorKey "behavior-v1-ec060a2c3596b1c2") -- OrderInTransit x ShipOrder: required rejection
  , Pending (BehaviorKey "behavior-v1-ed926b1ef15794db") -- OrderDone x PlaceOrder: required rejection
  ]