-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module SkelRouter.MyService.Page.BehaviorHoles (behaviorWitnesses) where

import SkelRouter.Generated.MyService.Page.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-333c07acc3005e8f") -- PageDelivered x SendPage: required rejection (spec line 19)
  , Pending (BehaviorKey "behavior-v1-75972c0c000e2777") -- PagePending x SendPage: live transition (spec line 24)
  ]
