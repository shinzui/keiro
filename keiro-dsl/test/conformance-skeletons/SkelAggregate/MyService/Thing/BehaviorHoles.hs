-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module SkelAggregate.MyService.Thing.BehaviorHoles (behaviorWitnesses) where

import SkelAggregate.Generated.MyService.Thing.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-9879aa7cdadb6004") -- ThingDone x DoThing: required rejection (spec line 9)
  , Pending (BehaviorKey "behavior-v1-c1b356b00484077a") -- ThingPending x DoThing: live transition (spec line 14)
  ]
