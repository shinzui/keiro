-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module TransferRouting.Hospital.BehaviorHoles (behaviorWitnesses) where

import Generated.TransferRouting.Hospital.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-8c1612ae6464bb11")
  ]