-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module SurgeDemo.Hospital.BehaviorHoles (behaviorWitnesses) where

import Generated.SurgeDemo.Hospital.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-4738b03b129c9778")
  , Pending (BehaviorKey "behavior-v1-8cc737e3759c26c7")
  ]