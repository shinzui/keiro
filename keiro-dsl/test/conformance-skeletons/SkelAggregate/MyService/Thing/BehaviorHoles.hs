-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module SkelAggregate.MyService.Thing.BehaviorHoles (behaviorWitnesses) where

import SkelAggregate.Generated.MyService.Thing.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-9879aa7cdadb6004")
  , Pending (BehaviorKey "behavior-v1-c1b356b00484077a")
  ]