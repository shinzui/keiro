-- Consumer-owned behavioral witnesses. Created once; never overwritten.
module HospitalCapacity.Surge.BehaviorHoles (behaviorWitnesses) where

import Generated.HospitalCapacity.Surge.BehaviorContract

behaviorWitnesses :: [BehaviorWitness]
behaviorWitnesses =
  [ Pending (BehaviorKey "behavior-v1-5198a253324042e6")
  , Pending (BehaviorKey "behavior-v1-6721e0b61aa38780")
  ]